import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/features/daily_plan/domain/daily_plan_models.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';
import 'package:frelocator/services/sync/conflict_record.dart';
import 'package:frelocator/services/sync/sync_document.dart';

Map<String, dynamic> _recordJson() => <String, dynamic>{
  'id': 'cf-0000000000000000',
  'entityType': 'task',
  'entityId': 'tsk-1',
  'detectedAt': '2026-09-09T02:00:00.000Z',
  'detectedBy': 'hub-macos',
  'winner': <String, dynamic>{
    'side': 'hub',
    'deviceId': 'hub-macos',
    'clock': '10-0-hub-macos',
    'updatedAt': '2026-09-09T01:00:00.000Z',
    'snapshot': <String, dynamic>{'id': 'tsk-1', 'title': 'x'},
  },
  'loser': <String, dynamic>{
    'side': 'device',
    'deviceId': 'android-1',
    'clock': '9-0-android-1',
    'updatedAt': '2026-09-09T00:00:00.000Z',
    'snapshot': <String, dynamic>{
      'id': 'tsk-1',
      'clock': '9-0-android-1',
      'updatedAt': '2026-09-09T00:00:00.000Z',
      'deletedAt': '2026-09-09T00:00:00.000Z',
    },
  },
  'resolution': null,
  'resolvedAt': null,
  'resolvedBy': null,
  'clock': '11-0-hub-macos',
  'updatedAt': '2026-09-09T02:00:00.000Z',
  'deletedAt': null,
  'migrated': false,
};

SyncDocument _emptyDocument({List<ConflictRecord> conflicts = const []}) =>
    SyncDocument(
      exportedAt: DateTime.utc(2026, 9, 9),
      deviceId: 'android-1',
      taskMaster: TaskMasterStateData(
        tasks: const [],
        mustDoCategories: const [],
        wantToDoCategories: const [],
        shareCategories: false,
      ),
      dailyPlan: DailyPlanStateData(
        plans: const [],
        slots: const [],
        assignments: const [],
      ),
      conflicts: conflicts,
    );

void main() {
  test('conflictId matches the TypeScript rule byte for byte', () {
    // tools/hub/test/model.conflicts.test.ts pins the very same string.
    expect(
      conflictId('tsk-1', '10-0-hub-macos', '9-2-android-3f2a'),
      'cf-e47c5a64e1b598dd',
    );
    expect(
      conflictId('tsk-1', '10-0-hub-macos', '9-2-android-3f2a'),
      matches(RegExp(r'^cf-[0-9a-f]{16}$')),
    );
    // Swapping the two clocks is a different conflict.
    expect(
      conflictId('tsk-1', '9-2-android-3f2a', '10-0-hub-macos'),
      isNot(conflictId('tsk-1', '10-0-hub-macos', '9-2-android-3f2a')),
    );
    expect(
      conflictId('tsk-2', '10-0-hub-macos', '9-2-android-3f2a'),
      isNot(conflictId('tsk-1', '10-0-hub-macos', '9-2-android-3f2a')),
    );
  });

  test('fromJson is strict about the load-bearing fields and lenient elsewhere', () {
    final json = <String, dynamic>{..._recordJson(), 'futureField': {'kept': true}};
    final record = ConflictRecord.fromJson(json, strict: true);
    expect(record.entityId, 'tsk-1');
    expect(record.winner.deviceId, 'hub-macos');
    expect(record.loser.isDeleted, isTrue);
    expect(record.isOpen, isTrue);
    // Unknown keys round-trip (same mechanism as SyncMeta.extra).
    expect(record.toJson()['futureField'], <String, dynamic>{'kept': true});
    expect(
      () => ConflictRecord.fromJson({...json, 'id': 42}, strict: true),
      throwsFormatException,
    );
    expect(
      () => ConflictRecord.fromJson({...json, 'winner': 'x'}, strict: true),
      throwsFormatException,
    );
    // Unknown entityType / resolution values are kept verbatim.
    final future = ConflictRecord.fromJson(
      {...json, 'entityType': 'zzz', 'resolution': 'zzz'},
      strict: true,
    );
    expect(future.entityType, 'zzz');
    expect(future.resolution, 'zzz');
    expect(future.isOpen, isFalse);
  });

  test('toJson emits exactly the keys the TypeScript record carries', () {
    expect(
      ConflictRecord.fromJson(_recordJson(), strict: true).toJson().keys.toSet(),
      {...ConflictRecord.jsonKeys, 'clock', 'updatedAt', 'deletedAt', 'migrated'},
    );
  });

  test('an empty conflicts list is omitted from toJson entirely', () {
    expect(_emptyDocument().toJson().containsKey('conflicts'), isFalse);
    final withOne = _emptyDocument(
      conflicts: [ConflictRecord.fromJson(_recordJson(), strict: true)],
    );
    expect((withOne.toJson()['conflicts'] as List), hasLength(1));
  });

  test('a v2 document without conflicts round-trips unchanged', () {
    final json = _emptyDocument().toJson();
    final again = SyncDocument.fromJson(json, strict: true).toJson();
    expect(again, json);
    expect(again.containsKey('conflicts'), isFalse);
    expect(json['version'], 2);
  });

  test('a side keeps keys a newer build wrote, and puts them back where it found them', () {
    final json = _recordJson();
    (json['winner'] as Map<String, dynamic>)['confidence'] = 0.8;
    (json['winner'] as Map<String, dynamic>)['note'] = 'from a newer build';
    final record = ConflictRecord.fromJson(json, strict: true);
    expect(record.winner.extra, {'confidence': 0.8, 'note': 'from a newer build'});
    // Round trip: an unknown key must survive the phone, or syncing through an
    // older build would silently delete what a newer one recorded.
    expect(record.toJson()['winner'], json['winner']);
    expect(record.loser.extra, isEmpty);
  });

  test('detectedBy is omitted rather than written empty, matching the optional TS field', () {
    final json = _recordJson()..remove('detectedBy');
    final record = ConflictRecord.fromJson(json, strict: true);
    expect(record.detectedBy, '');
    expect(record.toJson().containsKey('detectedBy'), isFalse);
    // With a value it is written as usual.
    expect(ConflictRecord.fromJson(_recordJson(), strict: true).toJson()['detectedBy'], 'hub-macos');
  });

  test('copyWith reopens a record only when asked to clear the resolution', () {
    final resolved = ConflictRecord.fromJson(_recordJson(), strict: true)
        .copyWith(resolution: 'hub', resolvedAt: 'x', resolvedBy: 'y');
    // A null argument cannot say "clear this": it reads as "leave it alone".
    expect(resolved.copyWith(resolution: null).resolution, 'hub');
    final reopened = resolved.copyWith(clearResolution: true);
    expect(reopened.resolution, isNull);
    expect(reopened.resolvedAt, isNull);
    expect(reopened.resolvedBy, isNull);
    expect(reopened.isOpen, isTrue);
  });

  test('sideOfDevice labels by device id prefix, and the browser counts as PC', () {
    expect(sideOfDevice('hub-macos'), 'hub');
    expect(sideOfDevice('web-abcd'), 'web');
    expect(sideOfDevice('android-1'), 'device');
    expect(sideOfDevice('unknown'), 'device');
    expect(isPcSide('hub'), isTrue);
    expect(isPcSide('web'), isTrue);
    expect(isPcSide('device'), isFalse);
  });

  test('a document with conflicts round-trips them', () {
    final json = _emptyDocument(
      conflicts: [ConflictRecord.fromJson(_recordJson(), strict: true)],
    ).toJson();
    final again = SyncDocument.fromJson(json, strict: true);
    expect(again.conflicts.single.id, 'cf-0000000000000000');
    expect(again.toJson(), json);
  });
}
