import '../../features/daily_plan/domain/daily_plan_models.dart';
import '../../features/task_master/domain/task_models.dart';

/// Where app state lives. Two implementations: shared_preferences (Android,
/// web) and a JSON file shared with the hub (macOS).
abstract class StateStore {
  Future<TaskMasterStateData> readTaskMaster();
  Future<void> writeTaskMaster(TaskMasterStateData state);
  Future<DailyPlanStateData> readDailyPlan();
  Future<void> writeDailyPlan(DailyPlanStateData state);

  /// Writes both halves of the document as one commit.
  ///
  /// An import replaces tasks *and* daily plans; landing only the first half
  /// leaves plans pointing at tasks that no longer exist, which no later merge
  /// can untangle. The default implementation cannot make two
  /// shared_preferences keys change atomically, so it does the next best
  /// thing: it keeps the previous tasks and puts them back if the plans fail,
  /// leaving the store exactly as it was found. Stores that can do better
  /// (see `FileBackedStore`, which holds one file under one lock) override
  /// this with a genuine single write.
  Future<void> writeAll(TaskMasterStateData tasks, DailyPlanStateData plans) async {
    final previous = await readTaskMaster();
    await writeTaskMaster(tasks);
    try {
      await writeDailyPlan(plans);
    } catch (_) {
      await writeTaskMaster(previous);
      rethrow;
    }
  }

  /// True when something other than this store changed the backing data.
  Future<bool> changedSinceLastRead() async => false;
  String? get lastWarning => null;
}
