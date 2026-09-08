import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/hlc.dart';

void main() {
  group('Hlc', () {
    test('parses and serializes the canonical string form', () {
      final hlc = Hlc.parse('1725760000000-3-android-ab12');
      expect(hlc.physical, 1725760000000);
      expect(hlc.counter, 3);
      expect(hlc.deviceId, 'android-ab12');
      expect(hlc.toString(), '1725760000000-3-android-ab12');
    });

    test('compares by physical, then counter, then deviceId', () {
      final a = Hlc(physical: 10, counter: 0, deviceId: 'b');
      final b = Hlc(physical: 10, counter: 1, deviceId: 'a');
      final c = Hlc(physical: 11, counter: 0, deviceId: 'a');
      final d = Hlc(physical: 10, counter: 0, deviceId: 'a');
      expect(a.compareTo(b) < 0, isTrue);
      expect(b.compareTo(c) < 0, isTrue);
      expect(d.compareTo(a) < 0, isTrue);
      expect(a.compareTo(Hlc.parse('10-0-b')), 0);
    });

    test('migrated sentinel sorts before any real clock', () {
      expect(Hlc.migrated.compareTo(Hlc(physical: 1, counter: 0, deviceId: 'x')) < 0, isTrue);
      expect(Hlc.migrated.toString(), '0-0-migrated');
    });
  });

  group('HlcClock', () {
    test('never goes backwards when wall clock regresses', () {
      var now = 1000;
      final clock = HlcClock(deviceId: 'dev', now: () => now);
      final first = clock.next();
      now = 900;
      final second = clock.next();
      expect(second.compareTo(first) > 0, isTrue);
      expect(second.physical, 1000);
      expect(second.counter, 1);
    });

    test('advances past an observed remote clock', () {
      final clock = HlcClock(deviceId: 'dev', now: () => 1000);
      clock.observe(Hlc(physical: 5000, counter: 2, deviceId: 'other'));
      final next = clock.next();
      expect(next.physical, 5000);
      expect(next.counter, 3);
      expect(next.deviceId, 'dev');
    });
  });
}
