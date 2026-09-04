import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/daily_plan/data/daily_plan_repository.dart';
import '../features/daily_plan/domain/daily_plan_models.dart';
import '../features/task_master/data/task_master_repository.dart';
import '../features/task_master/domain/task_models.dart';

final appDataServiceProvider = Provider<AppDataService>((ref) {
  return AppDataService(
    taskRepo: ref.read(taskMasterRepositoryProvider),
    dailyPlanRepo: ref.read(dailyPlanRepositoryProvider),
  );
});

class AppDataService {
  const AppDataService({required this.taskRepo, required this.dailyPlanRepo});

  final TaskMasterRepository taskRepo;
  final DailyPlanRepository dailyPlanRepo;

  static const _schemaVersion = 1;

  Future<Map<String, dynamic>> exportAll() async {
    final taskState = await taskRepo.load();
    final dailyPlanState = await dailyPlanRepo.load();
    return {
      'version': _schemaVersion,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'task_master': taskState.toJson(),
      'daily_plan': dailyPlanState.toJson(),
    };
  }

  Future<void> importAll(Map<String, dynamic> data) async {
    final taskState = TaskMasterStateData.fromJson(
      data['task_master'] as Map<String, dynamic>,
    );
    final dailyPlanState = DailyPlanStateData.fromJson(
      data['daily_plan'] as Map<String, dynamic>,
    );
    await taskRepo.save(taskState);
    await dailyPlanRepo.save(dailyPlanState);
  }
}
