import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/daily_plan_models.dart';

final dailyPlanRepositoryProvider = Provider<DailyPlanRepository>((ref) {
  return DailyPlanRepository();
});

class DailyPlanRepository {
  static const _storageKey = 'daily_plan_state_v1';

  Future<SharedPreferences>? _preferences;

  /// Resolves the shared preferences instance once and reuses it, instead of
  /// awaiting `getInstance()` on every read and write.
  Future<SharedPreferences> _prefs() {
    return _preferences ??= SharedPreferences.getInstance();
  }

  Future<DailyPlanStateData> load() async {
    final preferences = await _prefs();
    final rawState = preferences.getString(_storageKey);
    if (rawState == null || rawState.isEmpty) {
      return DailyPlanStateData.initial();
    }
    return DailyPlanStateData.decode(rawState);
  }

  Future<void> save(DailyPlanStateData state) async {
    final preferences = await _prefs();
    await preferences.setString(_storageKey, state.encode());
  }
}
