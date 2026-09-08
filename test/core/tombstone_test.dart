import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/hlc.dart';
import 'package:frelocator/core/sync_meta.dart';
import 'package:frelocator/core/tombstone.dart';

void main() {
  test('serializes as an id plus meta with deletedAt', () {
    final t = Tombstone(
      id: 'task-1',
      meta: SyncMeta.stamp(
        Hlc.parse('1-0-a'),
        DateTime.utc(2026),
      ).tombstone(Hlc.parse('2-0-a'), DateTime.utc(2026, 1, 2)),
    );
    final json = t.toJson();
    expect(json['id'], 'task-1');
    expect(json['deletedAt'], '2026-01-02T00:00:00.000Z');
    expect(Tombstone.fromJson(json).meta.clock, Hlc.parse('2-0-a'));
  });

  test('splitDeleted separates live records from tombstones', () {
    final raw = <dynamic>[
      {
        'id': 'a',
        'name': 'x',
        'clock': '1-0-d',
        'updatedAt': '2026-01-01T00:00:00.000Z',
        'deletedAt': null,
        'migrated': false,
      },
      {
        'id': 'b',
        'clock': '2-0-d',
        'updatedAt': '2026-01-01T00:00:00.000Z',
        'deletedAt': '2026-01-01T00:00:00.000Z',
        'migrated': false,
      },
      'garbage',
    ];
    final split = splitDeleted(raw, strict: false);
    expect(split.live.map((e) => e['id']), ['a']);
    expect(split.tombstones.map((t) => t.id), ['b']);
  });

  test('strict mode throws on unparsable entries', () {
    expect(
      () => splitDeleted(<dynamic>['garbage'], strict: true),
      throwsFormatException,
    );
  });
}
