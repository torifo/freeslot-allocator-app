import 'package:frelocator/services/sync/conflict_record.dart';

/// A task as the two sides recorded it. Shaped exactly like the merger's
/// snapshot: the whole entity, meta included.
Map<String, dynamic> conflictTask(String id, String title, String clock) => <String, dynamic>{
  'id': id, 'title': title, 'kind': 'must_do', 'priority': 3,
  'createdAt': '2026-01-01T00:00:00.000Z', 'updatedAt': '2026-02-01T00:00:00.000Z',
  'memo': '', 'categoryId': null, 'estimatedMinutes': 0,
  'clock': clock, 'deletedAt': null, 'migrated': false,
};

const String conflictHubClock = '3000-0-hub-0000';
const String conflictPhoneClock = '2000-0-android-1';

/// One record shaped the way the merger writes it, for the storage tests that
/// only care that a record survives a round trip whole.
ConflictRecord conflictFixture({
  required String entityId,
  String? resolution,
  String entityType = 'task',
  Map<String, dynamic>? winner,
  Map<String, dynamic>? loser,
}) {
  final w = winner ?? conflictTask(entityId, 'PC の版', conflictHubClock);
  final l = loser ?? conflictTask(entityId, 'スマホの版', conflictPhoneClock);
  return ConflictRecord.fromJson(<String, dynamic>{
    'id': conflictId(entityId, w['clock'] as String, l['clock'] as String),
    'entityType': entityType,
    'entityId': entityId,
    'detectedAt': '2026-02-03T00:00:00.000Z',
    'detectedBy': 'android-1',
    'winner': <String, dynamic>{
      'side': 'hub', 'deviceId': 'hub-0000', 'clock': w['clock'],
      'updatedAt': w['updatedAt'], 'snapshot': w,
    },
    'loser': <String, dynamic>{
      'side': 'device', 'deviceId': 'android-1', 'clock': l['clock'],
      'updatedAt': l['updatedAt'], 'snapshot': l,
    },
    'resolution': resolution,
    'resolvedAt': resolution == null ? null : '2026-02-04T00:00:00.000Z',
    'resolvedBy': resolution == null ? null : 'hub-0000',
    'clock': w['clock'],
    'updatedAt': '2026-02-03T00:00:00.000Z',
    'deletedAt': null,
    'migrated': false,
  });
}
