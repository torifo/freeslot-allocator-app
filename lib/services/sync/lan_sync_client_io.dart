import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

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

  /// The hub can take a while to merge a large document; only the connect and
  /// the small requests use the short [timeout].
  Duration get _syncTimeout => timeout * 10;

  IOClient _client(String? expectedFingerprint) {
    final io = HttpClient()
      ..connectionTimeout = timeout
      ..badCertificateCallback = (X509Certificate cert, String host, int port) {
        if (expectedFingerprint == null || expectedFingerprint.isEmpty) return false;
        return fingerprintMatches(
          sha256Hex: sha256.convert(cert.der).toString(),
          expected: expectedFingerprint,
        );
      };
    return IOClient(io);
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
    return PairResult(
      token: json['token'] as String,
      hubDeviceId: json['hubDeviceId'] as String,
      fingerprint: (json['fingerprint'] as String).toUpperCase(),
    );
  }

  Future<Map<String, dynamic>> health(SyncSettings s) =>
      _get(_uri(s.host!, s.port, '/health'), s);

  /// `GET /sync` — the hub's document without sending ours.
  Future<Map<String, dynamic>> fetch(SyncSettings s) async =>
      (await _get(_uri(s.host!, s.port, '/sync'), s))['document'] as Map<String, dynamic>;

  Future<SyncResponse> sync(
    SyncSettings s,
    Map<String, dynamic> document, {
    String mode = 'merge',
    SyncProgressController? progress,
  }) async {
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
    try {
      final request =
          http.StreamedRequest('POST', _uri(s.host!, s.port, '/sync', {'mode': mode}))
            ..headers['authorization'] = 'Bearer ${s.token}'
            ..headers['content-type'] = 'application/json'
            ..contentLength = body.length;
      // Feed in chunks so the progress panel can show sent bytes.
      unawaited(() async {
        const chunk = 16 * 1024;
        try {
          for (var i = 0; i < body.length; i += chunk) {
            if (progress?.isCancelled ?? false) break;
            final end = (i + chunk < body.length) ? i + chunk : body.length;
            request.sink.add(body.sublist(i, end));
            progress?.bytes(end);
            await Future<void>.delayed(Duration.zero);
          }
        } finally {
          await request.sink.close();
        }
      }());
      final streamed = await client.send(request).timeout(
        _syncTimeout,
        onTimeout: () => throw const SyncHttpException(0, 'timeout', 'PC からの応答がありません'),
      );
      progress?.stage(SyncStage.waitingHub);
      final bytes = <int>[];
      await for (final part in streamed.stream) {
        bytes.addAll(part);
        progress?.received(bytes.length);
        if (progress?.value.stage == SyncStage.waitingHub) {
          progress?.stage(SyncStage.receiving);
        }
      }
      final json = _decode(streamed.statusCode, utf8.decode(bytes));
      return SyncResponse(
        document: json['document'] as Map<String, dynamic>,
        summary: SyncSummary.fromJson(json['summary'] as Map<String, dynamic>? ?? const {}),
        warnings: (json['warnings'] as List?)?.cast<String>() ?? const <String>[],
      );
    } catch (error) {
      _rethrowAsSync(error, progress);
    } finally {
      progress?.removeListener(abortIfCancelled);
      client.close();
    }
  }

  Future<Map<String, dynamic>> _get(Uri uri, SyncSettings s) async {
    final client = _client(s.fingerprint);
    try {
      final r = await client
          .get(uri, headers: {'authorization': 'Bearer ${s.token}'})
          .timeout(timeout);
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
      final r = await client
          .post(uri, headers: {'content-type': 'application/json'}, body: jsonEncode(body))
          .timeout(timeout);
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
