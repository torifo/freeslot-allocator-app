import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/device_clock.dart';
import '../../../services/storage/file_backed_store.dart';
import '../../../services/storage/prefs_state_store.dart';
import '../../../services/storage/state_store.dart';
import '../domain/task_models.dart';

/// One store instance shared by both repositories (the file store keeps a
/// single document, so both must go through the same lock and cache).
final stateStoreProvider = Provider<StateStore>((ref) {
  if (!kIsWeb && Platform.isMacOS) {
    return FileBackedStore(
      directory: FileBackedStore.defaultDirectory(),
      deviceId: ref.read(deviceClockProvider).deviceId,
    );
  }
  return PrefsStateStore();
});

final taskMasterRepositoryProvider = Provider<TaskMasterRepository>((ref) {
  return TaskMasterRepository(ref.read(stateStoreProvider));
});

class TaskMasterRepository {
  TaskMasterRepository(this._store);

  final StateStore _store;

  Future<TaskMasterStateData> load() => _store.readTaskMaster();

  Future<void> save(TaskMasterStateData state) => _store.writeTaskMaster(state);
}
