import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

      final ab = SyncMerger.merge(a, b);
      final ba = SyncMerger.merge(b, a);

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

      final again = SyncMerger.merge(ab.document, b);
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
    });
  }
}

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
