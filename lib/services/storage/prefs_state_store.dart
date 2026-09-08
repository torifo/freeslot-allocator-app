import 'package:shared_preferences/shared_preferences.dart';

import '../../features/daily_plan/domain/daily_plan_models.dart';
import '../../features/task_master/domain/task_models.dart';
import 'state_store.dart';

/// Existing shared_preferences-backed store (Android, web).
class PrefsStateStore extends StateStore {
  // Keys kept for backward compatibility; the encoded payload is v2.
  static const taskKey = 'task_master_state_v1';
  static const planKey = 'daily_plan_state_v1';

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
}
