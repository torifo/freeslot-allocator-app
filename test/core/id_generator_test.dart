import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/id_generator.dart';

void main() {
  group('generateId', () {
    test('embeds prefix, timestamp, device fragment and random suffix', () {
      final id = generateId('slot', deviceId: 'android-ab12cd34');
      expect(id, matches(RegExp(r'^slot-\d+-ab12-[0-9a-f]{6}$')));
    });

    test('falls back to "loc0" without a device id', () {
      expect(generateId('task'), matches(RegExp(r'^task-\d+-loc0-[0-9a-f]{6}$')));
    });

    test('does not collide when called rapidly in a tight loop', () {
      final ids = <String>{
        for (var index = 0; index < 5000; index += 1) generateId('assignment', deviceId: 'x-1234'),
      };
      expect(ids.length, 5000);
    });

    test('pads a short device id fragment', () {
      expect(deviceFragment('abc'), 'abc0');
    });
  });
}
