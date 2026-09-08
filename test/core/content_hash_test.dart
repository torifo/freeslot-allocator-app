import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/content_hash.dart';

void main() {
  test('ignores key order and sync meta keys', () {
    final a = contentHash({'name': '仕事', 'id': 'c1', 'clock': '1-0-a', 'updatedAt': 'x'});
    final b = contentHash({'id': 'c1', 'name': '仕事', 'clock': '9-9-b', 'deletedAt': null, 'migrated': true});
    expect(a, b);
    expect(a, hasLength(64));
  });

  test('changes when content changes', () {
    expect(contentHash({'id': 'c1', 'name': 'a'}), isNot(contentHash({'id': 'c1', 'name': 'b'})));
  });
}
