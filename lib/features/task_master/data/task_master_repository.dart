import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/task_models.dart';

final taskMasterRepositoryProvider = Provider<TaskMasterRepository>((ref) {
  return TaskMasterRepository();
});

class TaskMasterRepository {
  static const _storageKey = 'task_master_state_v1';

  Future<SharedPreferences>? _preferences;

  /// Resolves the shared preferences instance once and reuses it, instead of
  /// awaiting `getInstance()` on every read and write.
  Future<SharedPreferences> _prefs() {
    return _preferences ??= SharedPreferences.getInstance();
  }

  Future<TaskMasterStateData> load() async {
    final preferences = await _prefs();
    final rawState = preferences.getString(_storageKey);
    if (rawState == null || rawState.isEmpty) {
      return TaskMasterStateData.initial();
    }
    return TaskMasterStateData.decode(rawState);
  }

  Future<void> save(TaskMasterStateData state) async {
    final preferences = await _prefs();
    await preferences.setString(_storageKey, state.encode());
  }
}
