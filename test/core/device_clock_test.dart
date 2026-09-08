import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/device_clock.dart';
import 'package:frelocator/core/hlc.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('creates and persists a device id with platform prefix', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final clock = await DeviceClock.load(platformPrefix: 'test');
    expect(clock.deviceId, matches(RegExp(r'^test-[0-9a-f]{8}$')));
    final again = await DeviceClock.load(platformPrefix: 'test');
    expect(again.deviceId, clock.deviceId);
  });

  test('persists the last issued clock so restarts stay monotonic', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final clock = await DeviceClock.load(platformPrefix: 'test', now: () => 100);
    final issued = await clock.next();
    final reloaded = await DeviceClock.load(platformPrefix: 'test', now: () => 50);
    final later = await reloaded.next();
    expect(later.compareTo(issued) > 0, isTrue);
  });

  test('observe folds remote clocks', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final clock = await DeviceClock.load(platformPrefix: 'test', now: () => 100);
    await clock.observe(Hlc.parse('900-0-other'));
    expect((await clock.next()).physical, 900);
  });
}
