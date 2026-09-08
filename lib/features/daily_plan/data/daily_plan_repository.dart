import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/storage/state_store.dart';
import '../../task_master/data/task_master_repository.dart' show stateStoreProvider;
import '../domain/daily_plan_models.dart';

final dailyPlanRepositoryProvider = Provider<DailyPlanRepository>((ref) {
  return DailyPlanRepository(ref.read(stateStoreProvider));
});

class DailyPlanRepository {
  DailyPlanRepository(this._store);

  final StateStore _store;

  Future<DailyPlanStateData> load() => _store.readDailyPlan();

  Future<void> save(DailyPlanStateData state) => _store.writeDailyPlan(state);
}
