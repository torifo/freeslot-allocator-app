import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/device_clock.dart';
import '../features/daily_plan/data/daily_plan_repository.dart';
import '../features/task_master/data/task_master_repository.dart';
import 'sync/sync_document.dart';

final appDataServiceProvider = Provider<AppDataService>((ref) {
  return AppDataService(
    taskRepo: ref.read(taskMasterRepositoryProvider),
    dailyPlanRepo: ref.read(dailyPlanRepositoryProvider),
    deviceClock: ref.read(deviceClockProvider),
  );
});

class AppDataService {
  const AppDataService({
    required this.taskRepo,
    required this.dailyPlanRepo,
    required this.deviceClock,
  });

  final TaskMasterRepository taskRepo;
  final DailyPlanRepository dailyPlanRepo;
  final DeviceClock deviceClock;

  Future<SyncDocument> exportDocument() async {
    return SyncDocument(
      exportedAt: DateTime.now().toUtc(),
      deviceId: deviceClock.deviceId,
      taskMaster: await taskRepo.load(),
      dailyPlan: await dailyPlanRepo.load(),
    );
  }

  Future<Map<String, dynamic>> exportAll() async =>
      (await exportDocument()).toJson();

  /// Replaces local state with [document]. Callers that merge must do so
  /// before calling this (see SyncMerger).
  Future<void> importDocument(SyncDocument document) async {
    await taskRepo.save(document.taskMaster);
    await dailyPlanRepo.save(document.dailyPlan);
  }

  Future<void> importAll(Map<String, dynamic> data) =>
      importDocument(SyncDocument.fromJson(data, strict: true));
}
