import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../features/daily_plan/domain/daily_plan_models.dart';
import '../../features/task_master/domain/task_models.dart';
import '../sync/conflict_record.dart';
import 'state_store.dart';

/// Existing shared_preferences-backed store (Android, web).
class PrefsStateStore extends StateStore {
  // Keys kept for backward compatibility; the encoded payload is v2.
  static const taskKey = 'task_master_state_v1';
  static const planKey = 'daily_plan_state_v1';

  /// Its own key rather than a field of the two payloads: a conflict record
  /// belongs to neither half, and a separate key keeps the existing encodings
  /// byte-identical for a build that never records one.
  static const conflictKey = 'sync_conflicts_v1';

  Future<SharedPreferences>? _prefs;
  Future<SharedPreferences> _get() => _prefs ??= SharedPreferences.getInstance();

  @override
  Future<TaskMasterStateData> readTaskMaster() async {
    final raw = (await _get()).getString(taskKey);
    return raw == null || raw.isEmpty
        ? TaskMasterStateData.initial()
        : TaskMasterStateData.decode(raw);
  }

  @override
  Future<void> writeTaskMaster(TaskMasterStateData state) async =>
      (await _get()).setString(taskKey, state.encode());

  @override
  Future<DailyPlanStateData> readDailyPlan() async {
    final raw = (await _get()).getString(planKey);
    return raw == null || raw.isEmpty
        ? DailyPlanStateData.initial()
        : DailyPlanStateData.decode(raw);
  }

  @override
  Future<void> writeDailyPlan(DailyPlanStateData state) async =>
      (await _get()).setString(planKey, state.encode());

  @override
  Future<List<ConflictRecord>> readConflicts() async {
    final raw = (await _get()).getString(conflictKey);
    if (raw == null || raw.isEmpty) return const <ConflictRecord>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const <ConflictRecord>[];
    return <ConflictRecord>[
      for (final dynamic entry in decoded)
        if (entry is Map<String, dynamic>) ConflictRecord.fromJson(entry),
    ];
  }

  @override
  Future<void> writeConflicts(List<ConflictRecord> conflicts) async {
    final p = await _get();
    if (conflicts.isEmpty) {
      await p.remove(conflictKey);
      return;
    }
    await p.setString(
      conflictKey,
      jsonEncode(conflicts.map((c) => c.toJson()).toList()),
    );
  }

  /// Encodes all three parts *before* touching any key, so a document that
  /// cannot be serialised is rejected while the stored data is still intact;
  /// a failure during the second write rolls the first one back.
  @override
  Future<void> writeAll(
    TaskMasterStateData tasks,
    DailyPlanStateData plans, {
    List<ConflictRecord>? conflicts,
  }) async {
    final encodedTasks = tasks.encode();
    final encodedPlans = plans.encode();
    // Encoded here rather than inside `writeConflicts` below: a record this
    // build cannot serialise would otherwise be discovered only after both
    // payload keys had already been overwritten.
    final encodedConflicts = conflicts == null || conflicts.isEmpty
        ? null
        : jsonEncode(conflicts.map((c) => c.toJson()).toList());
    final p = await _get();
    final previousTasks = p.getString(taskKey);
    await p.setString(taskKey, encodedTasks);
    try {
      await p.setString(planKey, encodedPlans);
    } catch (_) {
      if (previousTasks == null) {
        await p.remove(taskKey);
      } else {
        await p.setString(taskKey, previousTasks);
      }
      rethrow;
    }
    if (conflicts == null) return;
    if (encodedConflicts == null) {
      await p.remove(conflictKey);
    } else {
      await p.setString(conflictKey, encodedConflicts);
    }
  }
}
