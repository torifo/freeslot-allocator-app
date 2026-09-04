import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/id_generator.dart';

void main() {
  group('generateId', () {
    test('keeps the prefix and appends a timestamp and random suffix', () {
      final id = generateId('slot');
      expect(id, matches(RegExp(r'^slot-\d+-[0-9a-f]{6}$')));
    });

    test('does not collide when called rapidly in a tight loop', () {
      final ids = <String>{
        for (var index = 0; index < 5000; index += 1) generateId('assignment'),
      };
      expect(ids.length, 5000);
    });
  });
}
