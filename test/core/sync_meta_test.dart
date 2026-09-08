import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/hlc.dart';
import 'package:frelocator/core/sync_meta.dart';

void main() {
  test('fromJson fills v1 defaults when meta keys are absent', () {
    final meta = SyncMeta.fromJson(<String, dynamic>{'id': 'x', 'name': 'y'});
    expect(meta.clock, Hlc.migrated);
    expect(meta.updatedAt, DateTime.utc(1970));
    expect(meta.deletedAt, isNull);
    expect(meta.migrated, isTrue);
    expect(meta.extra, isEmpty);
  });

  test('round-trips v2 keys and keeps unknown keys in extra', () {
    final json = <String, dynamic>{
      'id': 'x',
      'clock': '10-2-dev',
      'updatedAt': '2026-09-08T01:00:00.000Z',
      'deletedAt': '2026-09-08T02:00:00.000Z',
      'migrated': false,
      'futureField': 42,
    };
    final meta = SyncMeta.fromJson(json, knownKeys: const {'id'});
    expect(meta.clock, Hlc.parse('10-2-dev'));
    expect(meta.deletedAt, DateTime.utc(2026, 9, 8, 2));
    expect(meta.extra, {'futureField': 42});
    final out = <String, dynamic>{'id': 'x'}..addAll(meta.toJson());
    expect(out['clock'], '10-2-dev');
    expect(out['updatedAt'], '2026-09-08T01:00:00.000Z');
    expect(out['deletedAt'], '2026-09-08T02:00:00.000Z');
    expect(out['migrated'], false);
    expect(out['futureField'], 42);
  });

  test('stamp produces a live, non-migrated meta', () {
    final meta = SyncMeta.stamp(Hlc.parse('5-0-dev'), DateTime.utc(2026, 1, 1));
    expect(meta.isDeleted, isFalse);
    expect(meta.migrated, isFalse);
    expect(meta.tombstone(Hlc.parse('6-0-dev'), DateTime.utc(2026, 1, 2)).isDeleted, isTrue);
  });
}
