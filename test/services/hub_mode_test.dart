import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/device_clock.dart';
import 'package:frelocator/services/hub_mode/hub_mode.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the non-web build never enters hub mode', () {
    // Android / macOS / tests take the stub half of the conditional export, so
    // this branch is provably dead there — no `dart:js_interop` code ships in
    // the AAB or the .app.
    expect(readHubMode(), isNull);
  });

  test('the stub keeps every browser seam inert', () {
    expect(readWebId(), isNull);
    saveWebId('00112233445566aa');
    expect(readWebId(), isNull);
    expect(readOrigin(), isNull);
    expect(documentVisible(), isTrue);
    addVisibilityListener((_) => fail('the stub must never call back'));
    setUnloadGuard(() => fail('the stub must never call back'));
  });

  test('a minted web id is 16 lowercase hex characters', () {
    for (var i = 0; i < 20; i++) {
      expect(randomWebId(), matches(RegExp(r'^[0-9a-f]{16}$')));
    }
    expect(randomWebId(), isNot(randomWebId()));
  });

  test('HubMode carries the injected config as-is', () {
    const hub = HubMode(base: '/abc/app/', api: '/abc/api/', hubDeviceId: 'hub-macos', dataFile: '/tmp/data.json');
    expect(hub.api, '/abc/api/');
    expect(hub.schema, 2);
  });

  test('hub mode stamps this browser\'s records with the web id', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const webId = '00112233445566aa';
    final clock = await DeviceClock.load(deviceId: 'web-$webId');
    // The record provenance the app writes has to be the same `deviceId` the
    // store pushes, or the hub attributes this browser's edits to a device
    // that never sent anything.
    expect(clock.deviceId, 'web-$webId');
    final prefs = await SharedPreferences.getInstance();
    // Nothing but the HLC is persisted: the id is derived from the web id the
    // browser already keeps, so a stored copy could only ever disagree.
    expect(prefs.getString('sync_device_id'), isNull);
  });
}
