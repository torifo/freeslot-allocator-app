import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/services/sync/invariant_checker.dart';
import 'package:frelocator/services/sync/sync_document.dart';

void main() {
  final dir = Directory('test/fixtures/sync_invariants');
  final manifest =
      (jsonDecode(File('${dir.path}/manifest.json').readAsStringSync()) as List)
          .cast<String>();
  for (final name in manifest) {
    final fixture =
        jsonDecode(File('${dir.path}/$name').readAsStringSync())
            as Map<String, dynamic>;
    test(fixture['name'] as String, () {
      final doc = SyncDocument.fromJson(
        fixture['document'] as Map<String, dynamic>,
        strict: true,
      );
      final violations = InvariantChecker.check(doc);
      expect(
        violations.map((v) => v.code).toList(),
        (fixture['expectedCodes'] as List).cast<String>(),
      );
      for (final violation in violations) {
        expect(violation.message, isNotEmpty);
      }
    });
  }
}
