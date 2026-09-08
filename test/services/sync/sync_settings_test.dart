import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/services/sync/sync_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('round-trips settings and reports pairing state', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final store = SyncSettingsStore();
    expect((await store.load()).isPaired, isFalse);
    final s = SyncSettings(
      host: '192.168.1.10',
      port: 47820,
      fingerprint: 'AB' * 32,
      token: 'f' * 64,
      hubDeviceId: 'hub-macos',
      deviceName: 'Pixel 8',
      lastSyncAt: null,
    );
    await store.save(s);
    final back = await store.load();
    expect(back.isPaired, isTrue);
    expect(back.baseUrl, 'https://192.168.1.10:47820');
    await store.save(back.copyWith(lastSyncAt: DateTime.utc(2026, 9, 9)));
    expect((await store.load()).lastSyncAt, DateTime.utc(2026, 9, 9));
    await store.clear();
    expect((await store.load()).isPaired, isFalse);
  });

  test('parses a pairing URL', () {
    final p = PairingInfo.parse(
      'frelocator://pair?host=192.168.1.10&port=47820&fp=${'AB' * 32}&code=K7Q2M9XZ',
    );
    expect(p.host, '192.168.1.10');
    expect(p.port, 47820);
    expect(p.fingerprint, 'AB' * 32);
    expect(p.code, 'K7Q2M9XZ');
    expect(() => PairingInfo.parse('https://example.com'), throwsFormatException);
    expect(
      () => PairingInfo.parse('frelocator://pair?host=x&port=1&fp=short&code=1'),
      throwsFormatException,
    );
  });

  test('a port outside 1..65535 is not a usable pairing QR', () {
    String qr(String port) =>
        'frelocator://pair?host=192.168.1.20&port=$port&fp=${'AB' * 32}&code=K7Q2M9XZ';
    expect(() => PairingInfo.parse(qr('0')), throwsFormatException);
    expect(() => PairingInfo.parse(qr('65536')), throwsFormatException);
    expect(() => PairingInfo.parse(qr('-1')), throwsFormatException);
    expect(PairingInfo.parse(qr('1')).port, 1);
    expect(PairingInfo.parse(qr('65535')).port, 65535);
  });
}
