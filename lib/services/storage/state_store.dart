import '../../features/daily_plan/domain/daily_plan_models.dart';
import '../../features/task_master/domain/task_models.dart';

/// Where app state lives. Two implementations: shared_preferences (Android,
/// web) and a JSON file shared with the hub (macOS).
abstract class StateStore {
  Future<TaskMasterStateData> readTaskMaster();
  Future<void> writeTaskMaster(TaskMasterStateData state);
  Future<DailyPlanStateData> readDailyPlan();
  Future<void> writeDailyPlan(DailyPlanStateData state);

  /// True when something other than this store changed the backing data.
  Future<bool> changedSinceLastRead() async => false;
  String? get lastWarning => null;
}
