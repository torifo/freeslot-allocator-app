import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/daily_plan_models.dart';

final dailyPlanRepositoryProvider = Provider<DailyPlanRepository>((ref) {
  return DailyPlanRepository();
});

class DailyPlanRepository {
  static const _storageKey = 'daily_plan_state_v1';

  Future<DailyPlanStateData> load() async {
    final preferences = await SharedPreferences.getInstance();
    final rawState = preferences.getString(_storageKey);
    if (rawState == null || rawState.isEmpty) {
      return DailyPlanStateData.initial();
    }
    return DailyPlanStateData.decode(rawState);
  }

  Future<void> save(DailyPlanStateData state) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_storageKey, state.encode());
  }
}
