import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/services/sync/lan_sync_client.dart';
import 'package:frelocator/services/sync/sync_progress.dart';
import 'package:frelocator/services/sync/sync_settings.dart';

typedef Route = FutureOr<Map<String, dynamic>> Function(HttpRequest req, String body);

void main() {
  HttpServer? server;
  late List<HttpRequest> seen;
  late List<String> bodies;

  Future<void> serve(Map<String, Route> routes) async {
    final bound = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server = bound;
    seen = <HttpRequest>[];
    bodies = <String>[];
    bound.listen((req) async {
      seen.add(req);
      final body = await utf8.decoder.bind(req).join();
      bodies.add(body);
      final handler = routes['${req.method} ${req.uri.path}'];
      if (handler == null) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final result = await handler(req, body);
      final status = result['_status'] as int? ?? 200;
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      if (status == 413) req.response.headers.set(HttpHeaders.connectionHeader, 'close');
      req.response.write(jsonEncode(Map.of(result)..remove('_status')));
      await req.response.close();
    });
  }

  tearDown(() async {
    await server?.close(force: true);
    server = null;
  });

  SyncSettings settings() => SyncSettings(
    host: '127.0.0.1',
    port: server!.port,
    fingerprint: 'AB' * 32,
    token: 't' * 64,
    hubDeviceId: 'hub',
  );

  Map<String, dynamic> okSync() => <String, dynamic>{
    'document': <String, dynamic>{
      'version': 2,
      'exportedAt': '2026-01-01T00:00:00.000Z',
      'deviceId': 'hub',
      'taskMaster': <String, dynamic>{},
      'dailyPlan': <String, dynamic>{},
    },
    'summary': <String, dynamic>{
      'added': 1,
      'updated': 0,
      'deleted': 0,
      'removed': 2,
      'warnings': 0,
    },
    'warnings': <String>[],
  };

  test('pair posts code and device, returns token and fingerprint', () async {
    await serve({
      'POST /pair': (req, body) => {
        'token': 'x' * 64,
        'hubDeviceId': 'hub-macos',
        'fingerprint': 'ab' * 32,
      },
    });
    final client = LanSyncClient(allowInsecureForTest: true);
    final r = await client.pair(
      PairingInfo(
        host: '127.0.0.1',
        port: server!.port,
        fingerprint: 'AB' * 32,
        code: 'K7Q2M9XZ',
      ),
      deviceId: 'android-1',
      deviceName: 'Pixel',
    );
    expect(r.token, 'x' * 64);
    expect(r.hubDeviceId, 'hub-macos');
    expect(r.fingerprint, 'AB' * 32, reason: 'normalized to upper case');
    expect(seen.single.headers.value('authorization'), isNull);
    expect(jsonDecode(bodies.single), {
      'code': 'K7Q2M9XZ',
      'deviceId': 'android-1',
      'name': 'Pixel',
    });
  });

  test('pairing_code_expired surfaces as a 403 SyncHttpException', () async {
    await serve({
      'POST /pair': (req, body) => {
        '_status': 403,
        'error': {'code': 'pairing_code_expired', 'message': 'pairing code expired'},
      },
    });
    final client = LanSyncClient(allowInsecureForTest: true);
    await expectLater(
      client.pair(
        PairingInfo(host: '127.0.0.1', port: server!.port, fingerprint: 'AB' * 32, code: 'x'),
        deviceId: 'd',
        deviceName: 'n',
      ),
      throwsA(
        isA<SyncHttpException>()
            .having((e) => e.status, 'status', 403)
            .having((e) => e.code, 'code', 'pairing_code_expired'),
      ),
    );
  });

  test('health sends the bearer token and returns the hub identity', () async {
    await serve({
      'GET /health': (req, body) => {
        'ok': true,
        'hubDeviceId': 'hub',
        'fingerprint': 'AB' * 32,
        'version': 2,
        'schema': 2,
        'serverTime': '2026-01-01T00:00:00.000Z',
      },
    });
    final client = LanSyncClient(allowInsecureForTest: true);
    final r = await client.health(settings());
    expect(r['ok'], isTrue);
    expect(r['schema'], 2);
    expect(seen.single.headers.value('authorization'), 'Bearer ${'t' * 64}');
  });

  test('sync sends bearer token and mode, reports progress and parses the result', () async {
    await serve({'POST /sync': (req, body) => okSync()});
    final progress = SyncProgressController();
    progress.start(SyncKind.lan);
    final client = LanSyncClient(allowInsecureForTest: true);
    final r = await client.sync(settings(), {
      'version': 2,
      'payload': 'x' * 5000,
    }, progress: progress);
    expect(r.summary.added, 1);
    expect(r.summary.removed, 2, reason: 'the hub reports removed as well');
    expect(r.document['deviceId'], 'hub');
    expect(progress.value.sentBytes, greaterThan(5000));
    expect(progress.value.stage, SyncStage.receiving);
    expect(seen.single.headers.value('authorization'), 'Bearer ${'t' * 64}');
    expect(seen.single.uri.queryParameters['mode'], 'merge');
  });

  test('sync forwards the replace mode on the query string', () async {
    await serve({'POST /sync': (req, body) => okSync()});
    final client = LanSyncClient(allowInsecureForTest: true);
    await client.sync(settings(), {'version': 2}, mode: 'take_phone');
    expect(seen.single.uri.queryParameters['mode'], 'take_phone');
  });

  test('sync sends the document bytes verbatim', () async {
    await serve({'POST /sync': (req, body) => okSync()});
    final client = LanSyncClient(allowInsecureForTest: true);
    final document = <String, dynamic>{
      'version': 2,
      'exportedAt': '2026-01-01T00:00:00.000Z',
      'big': List<String>.filled(400, 'y' * 40),
    };
    await client.sync(settings(), document);
    expect(jsonDecode(bodies.single), document);
  });

  test('maps error responses to SyncHttpException with code', () async {
    await serve({
      'POST /sync': (req, body) => {
        '_status': 409,
        'error': {'code': 'purged_before', 'message': 'choose'},
      },
    });
    final client = LanSyncClient(allowInsecureForTest: true);
    await expectLater(
      client.sync(settings(), {'version': 2}),
      throwsA(
        isA<SyncHttpException>()
            .having((e) => e.status, 'status', 409)
            .having((e) => e.code, 'code', 'purged_before')
            .having((e) => e.message, 'message', 'choose')
            .having((e) => e.retriable, 'retriable', isFalse),
      ),
    );
  });

  test('413 is reported as fatal and the client does not reuse the socket', () async {
    await serve({
      'POST /sync': (req, body) => {
        '_status': 413,
        'error': {'code': 'payload_too_large', 'message': 'too big'},
      },
    });
    final client = LanSyncClient(allowInsecureForTest: true);
    for (var i = 0; i < 2; i++) {
      await expectLater(
        client.sync(settings(), {'version': 2}),
        throwsA(
          isA<SyncHttpException>()
              .having((e) => e.status, 'status', 413)
              .having((e) => e.code, 'code', 'payload_too_large')
              .having((e) => e.retriable, 'retriable', isFalse),
        ),
      );
    }
    expect(seen, hasLength(2), reason: 'a fresh connection per attempt, no retry loop');
  });

  test('network failures are retriable, protocol failures are not', () async {
    await serve({
      'POST /sync': (req, body) => {
        '_status': 401,
        'error': {'code': 'unauthorized', 'message': 'nope'},
      },
    });
    final client = LanSyncClient(allowInsecureForTest: true);
    try {
      await client.sync(settings(), {'version': 2});
      fail('expected a SyncHttpException');
    } on SyncHttpException catch (e) {
      expect(e.status, 401);
      expect(e.retriable, isFalse);
    }
    const unreachable = SyncHttpException(0, 'unreachable', 'x');
    expect(unreachable.retriable, isTrue);
    expect(const SyncHttpException(0, 'timeout', 'x').retriable, isTrue);
  });

  test('unreachable host fails fast with code unreachable', () async {
    final client = LanSyncClient(
      allowInsecureForTest: true,
      timeout: const Duration(milliseconds: 300),
    );
    await expectLater(
      client.health(const SyncSettings(host: '127.0.0.1', port: 1, fingerprint: 'x', token: 'y')),
      throwsA(isA<SyncHttpException>().having((e) => e.code, 'code', 'unreachable')),
    );
  });

  test('cancel aborts the in-flight request', () async {
    final completer = Completer<void>();
    await serve({
      'POST /sync': (req, body) async {
        await completer.future;
        return okSync();
      },
    });
    final progress = SyncProgressController();
    progress.start(SyncKind.lan);
    final client = LanSyncClient(allowInsecureForTest: true, timeout: const Duration(seconds: 30));
    final pending = client.sync(settings(), {'version': 2, 'payload': 'z' * 2000}, progress: progress);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    progress.cancel();
    await expectLater(
      pending,
      throwsA(isA<SyncHttpException>().having((e) => e.code, 'code', 'cancelled')),
    );
    completer.complete();
  });

  test('fingerprint verification', () {
    expect(fingerprintMatches(sha256Hex: 'ab' * 32, expected: 'AB' * 32), isTrue);
    expect(fingerprintMatches(sha256Hex: 'ab' * 32, expected: 'CD' * 32), isFalse);
    expect(
      fingerprintMatches(sha256Hex: 'ab' * 32, expected: List.filled(32, 'AB').join(':')),
      isTrue,
      reason: 'colon-separated fingerprints are accepted',
    );
    expect(fingerprintMatches(sha256Hex: 'ab' * 32, expected: ''), isFalse);
    expect(fingerprintMatches(sha256Hex: '', expected: 'AB' * 32), isFalse);
    expect(
      fingerprintMatches(sha256Hex: 'ab' * 32, expected: 'AB' * 31),
      isFalse,
      reason: 'a prefix must not match',
    );
  });
}
