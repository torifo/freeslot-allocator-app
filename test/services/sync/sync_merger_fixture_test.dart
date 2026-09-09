import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/services/sync/conflict_record.dart';
import 'package:frelocator/services/sync/sync_document.dart';
import 'package:frelocator/services/sync/sync_merger.dart';

void main() {
  final dir = Directory('test/fixtures/sync_merge');
  final manifest =
      (jsonDecode(File('${dir.path}/manifest.json').readAsStringSync()) as List)
          .cast<String>();

  for (final name in manifest) {
    final fixture =
        jsonDecode(File('${dir.path}/$name').readAsStringSync())
            as Map<String, dynamic>;
    test(fixture['name'] as String, () {
      final a = SyncDocument.fromJson(
        fixture['a'] as Map<String, dynamic>,
        strict: true,
      );
      final b = SyncDocument.fromJson(
        fixture['b'] as Map<String, dynamic>,
        strict: true,
      );
      final expected = fixture['expected'] as Map<String, dynamic>;

      // A fixture with no `options` merges exactly as it did before Plan 3b:
      // detection is off, and that is what keeps the first eight cases honest.
      final options = fixture['options'] as Map<String, dynamic>?;
      final lastAgreedAt = DateTime.tryParse(
        options?['lastAgreedAt'] as String? ?? '',
      )?.toUtc();
      final detectedBy = options?['detectedBy'] as String?;
      final detectedAt = DateTime.tryParse(
        options?['detectedAt'] as String? ?? '',
      )?.toUtc();

      final ab = SyncMerger.merge(
        a,
        b,
        lastAgreedAt: lastAgreedAt,
        detectedBy: detectedBy,
        detectedAt: detectedAt,
      );
      final ba = SyncMerger.merge(
        b,
        a,
        lastAgreedAt: lastAgreedAt,
        detectedBy: detectedBy,
        detectedAt: detectedAt,
      );

      expect(
        normalize(ab.document.taskMaster.toJson()),
        normalize(expected['taskMaster']),
      );
      expect(
        normalize(ab.document.dailyPlan.toJson()),
        normalize(expected['dailyPlan']),
      );
      expect(
        normalize(ba.document.toJson()['taskMaster']),
        normalize(ab.document.toJson()['taskMaster']),
        reason: 'commutative',
      );
      expect(
        normalize(ba.document.toJson()['dailyPlan']),
        normalize(ab.document.toJson()['dailyPlan']),
        reason: 'commutative',
      );
      expect(ba.warnings, ab.warnings, reason: 'commutative warnings');
      expect(
        ab.warnings,
        (fixture['expectedWarnings'] as List?)?.cast<String>() ?? <String>[],
      );

      final again = SyncMerger.merge(
        ab.document,
        b,
        lastAgreedAt: lastAgreedAt,
        detectedBy: detectedBy,
        detectedAt: detectedAt,
      );
      expect(
        normalize(again.document.toJson()['taskMaster']),
        normalize(ab.document.toJson()['taskMaster']),
        reason: 'idempotent',
      );
      expect(
        normalize(again.document.toJson()['dailyPlan']),
        normalize(ab.document.toJson()['dailyPlan']),
        reason: 'idempotent',
      );

      // Nothing is ever dropped: every id either side held survives the merge,
      // live or as a tombstone (design B-2). Applied to every fixture, old
      // ones included, so a new case gets the guard for free.
      final before = <String>{
        ...idsOf(fixture['a'] as Map<String, dynamic>),
        ...idsOf(fixture['b'] as Map<String, dynamic>),
      };
      expect(
        idsOf(ab.document.toJson()).containsAll(before),
        isTrue,
        reason: 'merge never drops an id (live or tombstoned)',
      );
      expect(idsOf(ba.document.toJson()).containsAll(before), isTrue);

      // Detection is not commutative in the id — swapping the arguments swaps
      // which side is `hub` — but the set of entities in conflict is.
      expect(
        ab.conflicts.map((c) => c.entityId).toList()..sort(),
        ba.conflicts.map((c) => c.entityId).toList()..sort(),
      );
      final expectedConflicts = fixture['expectedConflicts'] as List?;
      if (expectedConflicts != null) {
        expect(
          ab.document.conflicts.map(brief).toList(),
          expectedConflicts.map((e) => normalize(e)).toList(),
        );
      } else {
        expect(ab.document.conflicts, isEmpty);
      }
      final expectedDetected = fixture['expectedDetectedIds'] as List?;
      if (expectedDetected != null) {
        expect(ab.conflicts.map((c) => c.id).toList(), expectedDetected.cast<String>());
      }
    });
  }
}

/// Every entity id a document JSON holds, live or tombstoned.
Set<String> idsOf(Map<String, dynamic> doc) {
  final out = <String>{};
  for (final key in const ['taskMaster', 'dailyPlan']) {
    final section = doc[key];
    if (section is! Map) continue;
    for (final dynamic value in section.values) {
      if (value is! List) continue;
      for (final dynamic entry in value) {
        if (entry is Map && entry['id'] is String) out.add(entry['id'] as String);
      }
    }
  }
  return out;
}

/// The subset of a conflict record the fixtures pin; snapshots are checked elsewhere.
Map<String, dynamic> brief(ConflictRecord c) => <String, dynamic>{
  'id': c.id,
  'entityType': c.entityType,
  'entityId': c.entityId,
  'winner': <String, dynamic>{
    'side': c.winner.side,
    'deviceId': c.winner.deviceId,
    'clock': c.winner.clock,
  },
  'loser': <String, dynamic>{
    'side': c.loser.side,
    'deviceId': c.loser.deviceId,
    'clock': c.loser.clock,
  },
  'resolution': c.resolution,
};

/// Sorts every entity array by id so order differences do not fail the test.
dynamic normalize(dynamic value) {
  if (value is Map) {
    return <String, dynamic>{
      for (final e in value.entries) e.key.toString(): normalize(e.value),
    };
  }
  if (value is List) {
    final items = value.map(normalize).toList();
    if (items.every((i) => i is Map && i['id'] != null)) {
      items.sort(
        (x, y) => ((x as Map)['id'] as String).compareTo(
          ((y as Map)['id'] as String),
        ),
      );
    }
    return items;
  }
  return value;
}
