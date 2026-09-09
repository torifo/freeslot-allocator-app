import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/features/daily_plan/domain/daily_plan_models.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';
import 'package:frelocator/services/storage/prefs_state_store.dart';
import 'package:frelocator/services/sync/conflict_record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/conflict_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('a store that has never seen a conflict reports none, not a failure', () async {
    final store = PrefsStateStore();
    expect(await store.readConflicts(), isEmpty);
    // And the payload keys are untouched by a build that records nothing, so
    // the encoding stays byte-identical to the one before Plan 3b.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefsStateStore.conflictKey), isNull);
  });

  test('conflict records round-trip through their own key', () async {
    final store = PrefsStateStore();
    final open = conflictFixture(entityId: 'tsk-1');
    final closed = conflictFixture(entityId: 'tsk-2', resolution: 'hub');
    await store.writeConflicts(<ConflictRecord>[open, closed]);

    final read = await store.readConflicts();
    expect(read.map((c) => c.id).toList(), <String>[open.id, closed.id]);
    expect(read.first.winner.snapshot['title'], 'PC の版');
    expect(read.first.loser.snapshot['title'], 'スマホの版');
    expect(read.last.resolution, 'hub');
    expect(read.last.resolvedBy, 'hub-0000');
    // The record's own clock survives, which is what lets a resolution beat the
    // detection the next time two devices meet.
    expect(read.first.meta.clock.toString(), open.meta.clock.toString());
  });

  test('writing an empty list removes the key rather than storing "[]"', () async {
    final store = PrefsStateStore();
    await store.writeConflicts(<ConflictRecord>[conflictFixture(entityId: 'tsk-1')]);
    await store.writeConflicts(const <ConflictRecord>[]);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefsStateStore.conflictKey), isNull);
    expect(await store.readConflicts(), isEmpty);
  });

  test('a conflicts key holding something other than a list reads as none', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PrefsStateStore.conflictKey: jsonEncode(<String, dynamic>{'not': 'a list'}),
    });
    expect(await PrefsStateStore().readConflicts(), isEmpty);
  });

  test('writeAll stores all three parts, and null leaves the records alone', () async {
    final store = PrefsStateStore();
    final record = conflictFixture(entityId: 'tsk-1');
    await store.writeAll(
      TaskMasterStateData.initial().copyWith(shareCategories: true),
      DailyPlanStateData.initial(),
      conflicts: <ConflictRecord>[record],
    );
    expect((await store.readTaskMaster()).shareCategories, isTrue);
    expect((await store.readConflicts()).single.id, record.id);

    // No `conflicts` argument means "this caller only knows about tasks and
    // plans", not "there are none".
    await store.writeAll(
      TaskMasterStateData.initial().copyWith(shareCategories: false),
      DailyPlanStateData.initial(),
    );
    expect((await store.readTaskMaster()).shareCategories, isFalse);
    expect((await store.readConflicts()).single.id, record.id);
  });
}
