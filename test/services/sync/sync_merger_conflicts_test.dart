import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/services/sync/conflict_record.dart';
import 'package:frelocator/services/sync/sync_document.dart';
import 'package:frelocator/services/sync/sync_merger.dart';

final agreed = DateTime.utc(2026, 9, 9);
final detectedAt = DateTime.utc(2026, 9, 9, 3);
const detectedBy = 'hub-macos';

Map<String, dynamic> task(String title, String clock, String updatedAt) => <String, dynamic>{
  'id': 'tsk-1', 'title': title, 'kind': 'must_do', 'priority': 3,
  'createdAt': '2026-09-01T00:00:00.000Z', 'memo': '', 'categoryId': null,
  'estimatedMinutes': 0, 'clock': clock, 'updatedAt': updatedAt,
  'deletedAt': null, 'migrated': false,
};

SyncDocument doc(
  String deviceId,
  List<Map<String, dynamic>> tasks, {
  Map<String, dynamic>? settings,
  List<Map<String, dynamic>>? conflicts,
}) => SyncDocument.fromJson(<String, dynamic>{
  'version': 2,
  'exportedAt': '2026-09-08T00:00:00.000Z',
  'deviceId': deviceId,
  'taskMaster': <String, dynamic>{
    'tasks': tasks,
    'mustDoCategories': <dynamic>[],
    'wantToDoCategories': <dynamic>[],
    'settings': settings ??
        <String, dynamic>{
          'shareCategories': false, 'clock': '0-0-migrated',
          'updatedAt': '1970-01-01T00:00:00.000Z', 'deletedAt': null, 'migrated': true,
        },
  },
  'dailyPlan': <String, dynamic>{
    'plans': <dynamic>[], 'slots': <dynamic>[], 'assignments': <dynamic>[],
  },
  'conflicts': ?conflicts,
}, strict: true);

final hub = task('hub edit', '20-0-hub-macos', '2026-09-09T02:00:00.000Z');
final device = task('device edit', '15-0-android-1', '2026-09-09T01:00:00.000Z');

MergeResult mergeWith(
  SyncDocument a,
  SyncDocument b, {
  DateTime? lastAgreedAt,
}) => SyncMerger.merge(
  a,
  b,
  lastAgreedAt: lastAgreedAt ?? agreed,
  detectedBy: detectedBy,
  detectedAt: detectedAt,
);

void main() {
  test('does not detect anything when lastAgreedAt is absent', () {
    expect(SyncMerger.merge(doc('a', [hub]), doc('b', [device])).conflicts, isEmpty);
    expect(
      SyncMerger.merge(
        doc('a', [hub]),
        doc('b', [device]),
        detectedBy: detectedBy,
        detectedAt: detectedAt,
      ).conflicts,
      isEmpty,
    );
  });

  test('does not detect when the two sides hold identical content', () {
    final other = <String, dynamic>{
      ...hub, 'clock': '19-0-android-1', 'updatedAt': '2026-09-09T01:59:00.000Z',
    };
    expect(mergeWith(doc('a', [hub]), doc('b', [other])).conflicts, isEmpty);
  });

  test('uses max(updatedAt, clock.physical) so a lagging wall clock still counts', () {
    final physical = DateTime.utc(2026, 9, 9, 1).millisecondsSinceEpoch;
    final lagging = task('device edit', '$physical-0-android-1', '2025-01-01T00:00:00.000Z');
    expect(mergeWith(doc('a', [hub]), doc('b', [lagging])).conflicts, hasLength(1));
  });

  test('compares with >= so a change exactly at lastAgreedAt is a conflict', () {
    final at = agreed.toIso8601String();
    expect(
      mergeWith(
        doc('a', [task('hub edit', '20-0-hub-macos', at)]),
        doc('b', [task('device edit', '15-0-android-1', at)]),
      ).conflicts,
      hasLength(1),
    );
  });

  test('records the winner, the loser and the whole losing snapshot', () {
    final conflict = mergeWith(doc('a', [hub]), doc('b', [device])).conflicts.single;
    expect(conflict.id, conflictId('tsk-1', '20-0-hub-macos', '15-0-android-1'));
    expect(conflict.entityType, 'task');
    expect(conflict.winner.side, 'hub');
    expect(conflict.winner.deviceId, 'hub-macos');
    expect(conflict.loser.side, 'device');
    expect(conflict.loser.deviceId, 'android-1');
    expect(conflict.loser.snapshot, device);
    expect(conflict.detectedBy, detectedBy);
    expect(conflict.detectedAt, '2026-09-09T03:00:00.000Z');
    expect(conflict.resolution, isNull);
    expect(conflict.meta.clock.toString(), '20-0-hub-macos');
  });

  test('labels each side by its device id, not by which argument carried it', () {
    // The phone calls `merge(mine, theirs)`, so the PC's version is argument B
    // here. An argument-position label would read inverted on the phone — the
    // one screen where the user actually chooses between the two.
    final swapped = mergeWith(doc('b', [device]), doc('a', [hub])).conflicts.single;
    expect(swapped.winner.side, 'hub');
    expect(swapped.winner.deviceId, 'hub-macos');
    expect(swapped.loser.side, 'device');
    expect(swapped.loser.deviceId, 'android-1');
  });

  test('calls a version the hub-served browser wrote a `web` side', () {
    final web = task('browser edit', '25-0-web-abcd', '2026-09-09T02:30:00.000Z');
    final conflict = mergeWith(doc('a', [web]), doc('b', [device])).conflicts.single;
    expect(conflict.winner.side, 'web');
    expect(isPcSide(conflict.winner.side), isTrue, reason: 'the browser is 「PC 版」 too');
    expect(conflict.loser.side, 'device');
  });

  test('the snapshot is a copy, so a later edit cannot rewrite the record', () {
    final live = Map<String, dynamic>.from(hub);
    final conflict = mergeWith(doc('a', [live]), doc('b', [device])).conflicts.single;
    live['title'] = 'edited afterwards';
    expect(conflict.winner.snapshot['title'], 'hub edit');
  });

  test('records a delete against an edit, keeping the tombstone shape', () {
    final tomb = <String, dynamic>{
      'id': 'tsk-1', 'clock': '18-0-android-1',
      'updatedAt': '2026-09-09T01:30:00.000Z',
      'deletedAt': '2026-09-09T01:30:00.000Z', 'migrated': false,
    };
    final conflict = mergeWith(doc('a', [hub]), doc('b', [tomb])).conflicts.single;
    expect(conflict.loser.snapshot, tomb);
    expect(conflict.loser.isDeleted, isTrue);
    expect(conflict.winner.snapshot, hub);
  });

  test('treats settings as entityId "settings"', () {
    final conflict = mergeWith(
      doc('a', [], settings: <String, dynamic>{
        'shareCategories': false, 'clock': '20-0-hub-macos',
        'updatedAt': '2026-09-09T02:00:00.000Z', 'deletedAt': null, 'migrated': false,
      }),
      doc('b', [], settings: <String, dynamic>{
        'shareCategories': true, 'clock': '15-0-android-1',
        'updatedAt': '2026-09-09T01:00:00.000Z', 'deletedAt': null, 'migrated': false,
      }),
    ).conflicts.single;
    expect(conflict.entityId, 'settings');
    expect(conflict.entityType, 'settings');
    expect(conflict.id, conflictId('settings', '20-0-hub-macos', '15-0-android-1'));
  });

  test('re-detecting the same pair is idempotent', () {
    final first = mergeWith(doc('a', [hub]), doc('b', [device]));
    final again = SyncMerger.merge(
      first.document,
      doc('b', [device]),
      lastAgreedAt: agreed,
      detectedBy: detectedBy,
      detectedAt: DateTime.utc(2026, 9, 9, 4),
    );
    expect(again.document.conflicts, hasLength(1));
    expect(again.document.conflicts.single.detectedAt, '2026-09-09T03:00:00.000Z');
  });

  test('unions existing records by id, letting the larger clock win', () {
    final base = mergeWith(doc('a', [hub]), doc('b', [device])).document.conflicts.single.toJson();
    final resolved = <String, dynamic>{
      ...base, 'resolution': 'device', 'resolvedAt': '2026-09-09T05:00:00.000Z',
      'resolvedBy': 'android-1', 'clock': '99-0-android-1',
    };
    final out = mergeWith(
      doc('a', [hub], conflicts: [base]),
      doc('b', [device], conflicts: [resolved]),
    );
    expect(out.document.conflicts, hasLength(1));
    expect(out.document.conflicts.single.resolution, 'device');
    expect(out.conflicts, isEmpty);
  });

  test('marks a conflict superseded when a later edit overwrote both sides', () {
    final later = task('a later edit', '40-0-hub-macos', '2026-09-09T02:30:00.000Z');
    final open = mergeWith(doc('a', [hub]), doc('b', [device])).document.conflicts.single.toJson();
    final out = mergeWith(doc('a', [later], conflicts: [open]), doc('b', [later]));
    expect(out.document.conflicts.single.resolution, 'superseded');
    expect(out.document.conflicts.single.resolvedBy, detectedBy);
    expect(out.document.conflicts.single.resolvedAt, '2026-09-09T03:00:00.000Z');
  });

  test('a merge with nothing to record leaves the key out of the JSON', () {
    final out = mergeWith(doc('a', []), doc('b', []));
    expect(out.document.conflicts, isEmpty);
    expect(out.document.toJson().containsKey('conflicts'), isFalse);
  });
}
