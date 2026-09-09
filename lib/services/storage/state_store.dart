import 'dart:async';

import '../../features/daily_plan/domain/daily_plan_models.dart';
import '../../features/task_master/domain/task_models.dart';
import '../sync/conflict_record.dart';
import '../sync/sync_document.dart';

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
  Future<void> writeAll(
    TaskMasterStateData tasks,
    DailyPlanStateData plans, {
    List<ConflictRecord>? conflicts,
  }) async {
    final previous = await readTaskMaster();
    await writeTaskMaster(tasks);
    try {
      await writeDailyPlan(plans);
    } catch (_) {
      await writeTaskMaster(previous);
      rethrow;
    }
    // Null means "leave the records alone", which is what every caller that
    // only knows about tasks and plans wants.
    if (conflicts != null) await writeConflicts(conflicts);
  }

  /// Reads the document, hands it to [fn], and writes back what comes out — as
  /// one step, so nothing that landed in between is lost.
  ///
  /// Read-modify-write is the shape every conflict resolution has: it needs the
  /// *current* document (the record, and the live entity the decision is
  /// measured against) and it writes a document derived from it. Doing that as
  /// a separate read and a separate write means an edit landing between the two
  /// — MCP on the hub's file, another tab's push, a repository save — is
  /// silently overwritten by a document that never saw it.
  ///
  /// Returning null from [fn] means "nothing to write"; the store is left
  /// untouched and the document as read comes back.
  ///
  /// The default implementation is the honest one for a store that cannot do
  /// better than reading every key and writing every key. `FileBackedStore`
  /// overrides it to run under its cross-process lock and `HubBackedStore` to
  /// fold the change into the snapshot it is about to push, both of which make
  /// it genuinely atomic.
  Future<SyncDocument> updateDocument(
    FutureOr<SyncDocument?> Function(SyncDocument document) fn,
  ) async {
    final current = SyncDocument(
      exportedAt: DateTime.now().toUtc(),
      deviceId: '',
      taskMaster: await readTaskMaster(),
      dailyPlan: await readDailyPlan(),
      conflicts: await readConflicts(),
    );
    final next = await fn(current);
    if (next == null) return current;
    await writeAll(next.taskMaster, next.dailyPlan, conflicts: next.conflicts);
    return next;
  }

  /// Conflict records (Plan 3b) kept beside the payload.
  ///
  /// The default is empty rather than abstract: a store that has nowhere to put
  /// them simply never shows any, and every caller still compiles.
  Future<List<ConflictRecord>> readConflicts() async => const <ConflictRecord>[];

  /// No default: every store in this app has somewhere to put the records, and
  /// a silent no-op here would let [writeAll] report success while dropping
  /// every record the merge just wrote. A store that genuinely cannot keep them
  /// has to say so out loud.
  Future<void> writeConflicts(List<ConflictRecord> conflicts) async {
    throw UnimplementedError(
      '$runtimeType cannot store conflict records; override writeConflicts',
    );
  }

  /// True when something other than this store changed the backing data.
  Future<bool> changedSinceLastRead() async => false;
  String? get lastWarning => null;
}
