import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/services/sync/lan_sync_client.dart';
import 'package:frelocator/services/sync/sync_settings.dart';

/// Strips the PEM armour and hashes the DER the way the hub prints its
/// fingerprint, so the test never has to carry a hard-coded hex string that
/// silently rots when the fixture is regenerated.
String fingerprintOf(String pem) {
  final body = pem
      .split('\n')
      .where((line) => !line.startsWith('-----'))
      .join()
      .replaceAll(RegExp(r'\s'), '');
  return sha256.convert(base64.decode(body)).toString().toUpperCase();
}

void main() {
  final certPem = File('test/fixtures/tls/hub_cert.pem').readAsStringSync();
  final keyPem = File('test/fixtures/tls/hub_key.pem').readAsStringSync();
  final goodPin = fingerprintOf(certPem);

  // The whole point of `withTrustedRoots: false`: this makes the test process
  // trust the fixture certificate the way a real device trusts a public CA. A
  // plain `HttpClient()` would then accept the hub without ever consulting the
  // pin (the SANs cover 127.0.0.1), so every assertion below that still sees a
  // rejection proves the callback is on the path for *every* certificate.
  setUpAll(() {
    SecurityContext.defaultContext.setTrustedCertificatesBytes(
      utf8.encode(certPem),
    );
  });

  HttpServer? server;

  Future<void> serve({int status = 200, String? redirectTo}) async {
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(certPem))
      ..usePrivateKeyBytes(utf8.encode(keyPem));
    final bound = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    server = bound;
    bound.listen((req) async {
      if (redirectTo != null) {
        req.response.statusCode = 302;
        req.response.headers.set(HttpHeaders.locationHeader, redirectTo);
        await req.response.close();
        return;
      }
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'ok': true, 'schema': 2}));
      await req.response.close();
    });
  }

  tearDown(() async {
    await server?.close(force: true);
    server = null;
  });

  SyncSettings settingsWith(String pin) => SyncSettings(
    host: '127.0.0.1',
    port: server!.port,
    fingerprint: pin,
    token: 't' * 64,
    hubDeviceId: 'hub',
  );

  test('the pinned certificate is accepted and the pin is actually consulted', () async {
    await serve();
    final client = LanSyncClient();
    final r = await client.health(settingsWith(goodPin));
    expect(r['ok'], isTrue);
    expect(
      client.certificateChecks,
      greaterThan(0),
      reason: 'withTrustedRoots:false must route every certificate through the pin, '
          'even one the platform trust store would accept on its own',
    );
  });

  test('a trusted certificate with the wrong pin is still rejected', () async {
    await serve();
    final client = LanSyncClient();
    await expectLater(
      client.health(settingsWith('CD' * 32)),
      throwsA(isA<SyncHttpException>().having((e) => e.code, 'code', 'certificate')),
    );
  });

  test('a fingerprint that is not 64 hex characters never matches', () async {
    await serve();
    final client = LanSyncClient();
    for (final bad in <String>['', 'AB', 'ZZ' * 32, '${'AB' * 32}AB']) {
      await expectLater(
        client.health(settingsWith(bad)),
        throwsA(isA<SyncHttpException>().having((e) => e.code, 'code', 'certificate')),
        reason: 'rejected pin: "$bad"',
      );
    }
  });

  test('sync over TLS with the right pin round-trips', () async {
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(certPem))
      ..usePrivateKeyBytes(utf8.encode(keyPem));
    final bound = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    server = bound;
    bound.listen((req) async {
      await utf8.decoder.bind(req).join();
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({
          'document': {'version': 2},
          'summary': {'added': 1, 'updated': 0, 'deleted': 0, 'removed': 0, 'warnings': 0},
          'warnings': <String>[],
        }),
      );
      await req.response.close();
    });
    final client = LanSyncClient();
    final r = await client.sync(settingsWith(goodPin), {'version': 2});
    expect(r.summary.added, 1);
  });

  test('the client never follows a redirect away from the pinned hub', () async {
    await serve(redirectTo: 'https://example.invalid/sync');
    final client = LanSyncClient();
    await expectLater(
      client.health(settingsWith(goodPin)),
      throwsA(isA<SyncHttpException>().having((e) => e.status, 'status', 302)),
    );
  });
}
