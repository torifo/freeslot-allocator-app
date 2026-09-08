import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:meta/meta.dart';

import 'lan_sync_types.dart';
import 'sync_progress.dart';
import 'sync_settings.dart';

export 'lan_sync_types.dart';

final lanSyncClientProvider = Provider<LanSyncClient>((ref) => LanSyncClient());

/// HTTPS client that trusts exactly one certificate: the hub's, by SHA-256
/// fingerprint.
///
/// The hub's certificate is self-signed and its SANs (`frelocator-hub.local`,
/// `localhost`, `127.0.0.1`) never match the LAN IP the phone dials, so
/// hostname verification is bypassed on purpose — the pin is the whole of the
/// authentication. [badCertificateCallback] therefore accepts *only* when the
/// presented certificate hashes to the pinned fingerprint; there is no
/// "accept anything" path, not even in debug builds.
class LanSyncClient {
  LanSyncClient({this.allowInsecureForTest = false, this.timeout = const Duration(seconds: 3)});

  /// Test-only: talk plain HTTP so a `HttpServer.bind` fixture can answer.
  final bool allowInsecureForTest;
  final Duration timeout;

  /// A pin is a SHA-256 digest and nothing else; anything of another shape is
  /// a corrupted or half-written setting, never something to trust.
  static final RegExp _pinShape = RegExp(r'^[0-9A-F]{64}$');

  /// How many times [badCertificateCallback] ran. Tests read it to prove that
  /// the pin really is on the path for *every* certificate, including one the
  /// platform would have accepted by itself.
  @visibleForTesting
  int certificateChecks = 0;

  /// The hub can take a while to merge a large document; only the connect and
  /// the small requests use the short [timeout].
  Duration get _syncTimeout => timeout * 10;

  IOClient _client(String? expectedFingerprint) {
    // Every request below sets `followRedirects = false`: the hub never
    // redirects, so a 3xx can only be an attempt to move us off the pinned
    // host, and it is surfaced as an error rather than followed.
    //
    // `withTrustedRoots: false` is the pin's teeth. With the platform trust
    // store in play, `badCertificateCallback` only runs for certificates the
    // OS has already rejected, so a publicly-signed certificate on a rebound
    // LAN address would sail past the pin unexamined. An empty context means
    // every certificate is "untrusted" and therefore every certificate is
    // handed to the callback.
    final io = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = timeout
      ..badCertificateCallback = (X509Certificate cert, String host, int port) {
        certificateChecks += 1;
        final expected = _normalizedPin(expectedFingerprint);
        if (expected == null) return false;
        return fingerprintMatches(
          sha256Hex: sha256.convert(cert.der).toString(),
          expected: expected,
        );
      };
    return IOClient(io);
  }

  /// Returns the pin in comparison form, or null when it is not a SHA-256
  /// digest (missing, truncated, or carrying anything but hex).
  static String? _normalizedPin(String? raw) {
    if (raw == null) return null;
    final normalized = raw.replaceAll(RegExp(r'[\s:]'), '').toUpperCase();
    return _pinShape.hasMatch(normalized) ? normalized : null;
  }

  /// The pairing settings must name a host and carry a token before any
  /// authenticated call; without them there is nothing to talk to.
  void _requirePaired(SyncSettings s) {
    if (s.host == null || s.host!.isEmpty || s.token == null || s.token!.isEmpty) {
      throw SyncHttpException(0, 'not_paired', syncErrorMessage('not_paired'));
    }
  }

  Uri _uri(String host, int port, String path, [Map<String, String>? query]) => Uri(
    scheme: allowInsecureForTest ? 'http' : 'https',
    host: host,
    port: port,
    path: path,
    queryParameters: query,
  );

  Future<PairResult> pair(
    PairingInfo info, {
    required String deviceId,
    required String deviceName,
  }) async {
    final json = await _post(
      _uri(info.host, info.port, '/pair'),
      <String, dynamic>{'code': info.code, 'deviceId': deviceId, 'name': deviceName},
      fingerprint: info.fingerprint,
    );
    // The hub is trusted to be well-behaved, but a proxy, a captive portal or
    // a partially-written response is not: check the shape before casting, so
    // a surprise becomes `corrupt` instead of an unhandled TypeError.
    final token = json['token'];
    final hubDeviceId = json['hubDeviceId'];
    final fingerprint = json['fingerprint'];
    if (token is! String || hubDeviceId is! String || fingerprint is! String) {
      throw SyncHttpException(0, 'corrupt', syncErrorMessage('corrupt'));
    }
    return PairResult(
      token: token,
      hubDeviceId: hubDeviceId,
      fingerprint: fingerprint.toUpperCase(),
    );
  }

  Future<Map<String, dynamic>> health(SyncSettings s) async {
    _requirePaired(s);
    return _get(_uri(s.host!, s.port, '/health'), s);
  }

  /// `GET /sync` — the hub's document without sending ours.
  Future<Map<String, dynamic>> fetch(SyncSettings s) async {
    _requirePaired(s);
    final json = await _get(_uri(s.host!, s.port, '/sync'), s);
    final document = json['document'];
    if (document is! Map<String, dynamic>) {
      throw SyncHttpException(0, 'corrupt', syncErrorMessage('corrupt'));
    }
    return document;
  }

  Future<SyncResponse> sync(
    SyncSettings s,
    Map<String, dynamic> document, {
    String mode = 'merge',
    SyncProgressController? progress,
  }) async {
    _requirePaired(s);
    final body = utf8.encode(jsonEncode(document));
    progress?.stage(SyncStage.sending, totalBytes: body.length);
    // A fresh client per call: a 413 arrives with `Connection: close` because
    // the hub answers without draining the body, so the socket underneath must
    // never be carried into the next attempt.
    final client = _client(s.fingerprint);
    // Cancel means "stop now": closing the client tears down the socket the
    // request is riding on, rather than waiting for the hub to finish.
    void abortIfCancelled() {
      if (progress?.isCancelled ?? false) client.close();
    }

    progress?.addListener(abortIfCancelled);
    // Flipped as soon as the exchange is over, so a feeder that is still
    // mid-loop stops reporting bytes for a request that already failed.
    var feeding = true;
    Future<void>? feeder;
    try {
      final request =
          http.StreamedRequest('POST', _uri(s.host!, s.port, '/sync', {'mode': mode}))
            ..headers['authorization'] = 'Bearer ${s.token}'
            ..headers['content-type'] = 'application/json'
            ..followRedirects = false
            ..contentLength = body.length;
      // Feed in chunks so the progress panel can show sent bytes.
      feeder = () async {
        const chunk = 16 * 1024;
        try {
          for (var i = 0; i < body.length; i += chunk) {
            if (!feeding || (progress?.isCancelled ?? false)) break;
            final end = (i + chunk < body.length) ? i + chunk : body.length;
            request.sink.add(body.sublist(i, end));
            progress?.bytes(end);
            await Future<void>.delayed(Duration.zero);
          }
        } finally {
          await request.sink.close();
        }
      }();
      final streamed = await client.send(request).timeout(
        _syncTimeout,
        onTimeout: () => throw const SyncHttpException(0, 'timeout', 'PC からの応答がありません'),
      );
      progress?.stage(SyncStage.waitingHub);
      final bytes = <int>[];
      // The headers arriving says nothing about the body arriving: a hub that
      // stalls mid-response must not hold the panel open forever.
      await for (final part in streamed.stream.timeout(_syncTimeout)) {
        bytes.addAll(part);
        progress?.received(bytes.length);
        if (progress?.value.stage == SyncStage.waitingHub) {
          progress?.stage(SyncStage.receiving);
        }
      }
      final json = _decode(streamed.statusCode, utf8.decode(bytes));
      final responseDocument = json['document'];
      final summary = json['summary'];
      final warnings = json['warnings'];
      if (responseDocument is! Map<String, dynamic> ||
          (summary != null && summary is! Map<String, dynamic>) ||
          (warnings != null && warnings is! List)) {
        throw SyncHttpException(0, 'corrupt', syncErrorMessage('corrupt'));
      }
      return SyncResponse(
        document: responseDocument,
        summary: SyncSummary.fromJson(
          (summary as Map<String, dynamic>?) ?? const <String, dynamic>{},
        ),
        warnings:
            (warnings as List?)?.whereType<String>().toList(growable: false) ?? const <String>[],
      );
    } catch (error) {
      _rethrowAsSync(error, progress);
    } finally {
      feeding = false;
      // Awaiting the feeder here is what actually stops it: an orphaned
      // `unawaited` loop would keep pushing `progress.bytes` long after a 413.
      try {
        await feeder;
      } catch (_) {
        // The feeder's own failure is never the interesting one — the request
        // result (or the error already in flight) is.
      }
      progress?.removeListener(abortIfCancelled);
      client.close();
    }
  }

  Future<Map<String, dynamic>> _get(Uri uri, SyncSettings s) async {
    final client = _client(s.fingerprint);
    try {
      final request = http.Request('GET', uri)
        ..headers['authorization'] = 'Bearer ${s.token}'
        ..followRedirects = false;
      final streamed = await client.send(request).timeout(timeout);
      final r = await http.Response.fromStream(streamed).timeout(timeout);
      return _decode(r.statusCode, r.body);
    } catch (error) {
      _rethrowAsSync(error, null);
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _post(
    Uri uri,
    Map<String, dynamic> body, {
    required String fingerprint,
  }) async {
    final client = _client(fingerprint);
    try {
      final request = http.Request('POST', uri)
        ..headers['content-type'] = 'application/json'
        ..followRedirects = false
        ..body = jsonEncode(body);
      final streamed = await client.send(request).timeout(timeout);
      final r = await http.Response.fromStream(streamed).timeout(timeout);
      return _decode(r.statusCode, r.body);
    } catch (error) {
      _rethrowAsSync(error, null);
    } finally {
      client.close();
    }
  }

  /// Turns every transport failure into a [SyncHttpException] the UI can map.
  Never _rethrowAsSync(Object error, SyncProgressController? progress) {
    if (error is SyncHttpException) throw error;
    // A cancelled request fails as a broken socket; report the cause, not the
    // symptom, so the panel does not tell the user the PC is unreachable.
    if (progress?.isCancelled ?? false) {
      throw const SyncHttpException(0, 'cancelled', '同期を中止しました');
    }
    if (error is HandshakeException || error is TlsException) {
      throw SyncHttpException(0, 'certificate', '証明書が一致しません: $error');
    }
    if (error is SocketException) {
      throw SyncHttpException(0, 'unreachable', error.message);
    }
    if (error is TimeoutException) {
      throw const SyncHttpException(0, 'timeout', 'PC に接続できません');
    }
    if (error is http.ClientException) {
      throw SyncHttpException(0, 'unreachable', error.message);
    }
    if (error is HttpException) {
      throw SyncHttpException(0, 'unreachable', error.message);
    }
    if (error is FormatException) {
      throw SyncHttpException(0, 'corrupt', error.message);
    }
    // A shape we did not expect in the hub's JSON surfaces as a cast or a
    // missing member; that is corrupt data, not a dead network, and calling it
    // `unreachable` would send the user to check their Wi-Fi for nothing.
    if (error is TypeError || error is NoSuchMethodError) {
      throw SyncHttpException(0, 'corrupt', syncErrorMessage('corrupt'));
    }
    throw SyncHttpException(0, 'unreachable', '$error');
  }

  Map<String, dynamic> _decode(int status, String body) {
    final Map<String, dynamic> json;
    try {
      json = body.isEmpty ? <String, dynamic>{} : jsonDecode(body) as Map<String, dynamic>;
    } on FormatException {
      throw SyncHttpException(status, 'corrupt', 'PC の応答が JSON ではありません');
    }
    if (status >= 200 && status < 300) return json;
    final err = json['error'];
    final map = err is Map<String, dynamic> ? err : const <String, dynamic>{};
    throw SyncHttpException(
      status,
      map['code'] as String? ?? 'http_$status',
      map['message'] as String? ?? 'HTTP $status',
    );
  }
}
