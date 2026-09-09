import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/device_clock.dart';
import '../features/daily_plan/data/daily_plan_repository.dart';
import '../features/task_master/data/task_master_repository.dart';
import 'storage/state_store.dart';
import 'sync/sync_document.dart';

final appDataServiceProvider = Provider<AppDataService>((ref) {
  return AppDataService(
    taskRepo: ref.read(taskMasterRepositoryProvider),
    dailyPlanRepo: ref.read(dailyPlanRepositoryProvider),
    store: ref.read(stateStoreProvider),
    deviceClock: ref.read(deviceClockProvider),
  );
});

class AppDataService {
  const AppDataService({
    required this.taskRepo,
    required this.dailyPlanRepo,
    required this.store,
    required this.deviceClock,
  });

  final TaskMasterRepository taskRepo;
  final DailyPlanRepository dailyPlanRepo;

  /// The store both repositories sit on. An import has to reach it directly:
  /// going through the two repositories would be two separate writes.
  final StateStore store;
  final DeviceClock deviceClock;

  Future<SyncDocument> exportDocument() async {
    return SyncDocument(
      exportedAt: DateTime.now().toUtc(),
      deviceId: deviceClock.deviceId,
      taskMaster: await taskRepo.load(),
      dailyPlan: await dailyPlanRepo.load(),
      conflicts: await store.readConflicts(),
    );
  }

  Future<Map<String, dynamic>> exportAll() async =>
      (await exportDocument()).toJson();

  /// Replaces local state with [document] as a single commit. Callers that
  /// merge must do so before calling this (see SyncMerger).
  ///
  /// Tasks and daily plans are two halves of one document — an assignment
  /// refers to a task by id — so a half-applied import is not "most of the
  /// sync", it is a broken database. [StateStore.writeAll] is what makes it
  /// all-or-nothing.
  /// [document.conflicts] replaces whatever was stored rather than being
  /// merged into it: every caller here has already taken the union (the hub's
  /// answer, or `SyncMerger`), so anything missing from it is missing on
  /// purpose.
  Future<void> importDocument(SyncDocument document) => store.writeAll(
    document.taskMaster,
    document.dailyPlan,
    conflicts: document.conflicts,
  );

  Future<void> importAll(Map<String, dynamic> data) =>
      importDocument(SyncDocument.fromJson(data, strict: true));
}
