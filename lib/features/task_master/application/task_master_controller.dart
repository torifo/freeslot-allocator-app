import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/task_master_repository.dart';
import '../domain/task_models.dart';
import 'task_master_logic.dart';

final taskMasterControllerProvider =
    AsyncNotifierProvider<TaskMasterController, TaskMasterStateData>(
      TaskMasterController.new,
    );

class TaskMasterController extends AsyncNotifier<TaskMasterStateData> {
  TaskMasterRepository get _repository =>
      ref.read(taskMasterRepositoryProvider);

  @override
  Future<TaskMasterStateData> build() async {
    return _repository.load();
  }

  Future<void> addOrUpdateTask(TaskMaster task) async {
    final current = state.requireValue;
    final sanitizedTask = sanitizeTaskAgainstCategories(task, current);
    final index = current.tasks.indexWhere((item) => item.id == task.id);
    final tasks = List<TaskMaster>.from(current.tasks);

    if (index >= 0) {
      tasks[index] = sanitizedTask;
    } else {
      tasks.add(sanitizedTask);
    }

    await _persist(current.copyWith(tasks: _sortTasks(tasks)));
  }

  Future<void> deleteTask(String id) async {
    final current = state.requireValue;
    final tasks = current.tasks.where((task) => task.id != id).toList();
    await _persist(current.copyWith(tasks: tasks));
  }

  Future<void> upsertCategory({
    required TaskKind kind,
    required TaskCategory category,
  }) async {
    final current = state.requireValue;
    final mustDo = List<TaskCategory>.from(current.mustDoCategories);
    final wantToDo = List<TaskCategory>.from(current.wantToDoCategories);

    void updateList(List<TaskCategory> categories) {
      final index = categories.indexWhere((item) => item.id == category.id);
      if (index >= 0) {
        categories[index] = category;
      } else {
        categories.add(category);
      }
      categories.sort((a, b) => a.name.compareTo(b.name));
    }

    if (current.shareCategories) {
      updateList(mustDo);
      wantToDo
        ..clear()
        ..addAll(mustDo.map((item) => item.copyWith()));
    } else if (kind == TaskKind.mustDo) {
      updateList(mustDo);
    } else {
      updateList(wantToDo);
    }

    await _persist(
      current.copyWith(mustDoCategories: mustDo, wantToDoCategories: wantToDo),
    );
  }

  Future<void> deleteCategory({
    required TaskKind kind,
    required String categoryId,
  }) async {
    final current = state.requireValue;
    final updated = deleteCategoryFromState(
      current,
      kind: kind,
      categoryId: categoryId,
    );
    await _persist(updated);
  }

  Future<void> setShareCategories({
    required bool enabled,
    CategoryMergeStrategy strategy = CategoryMergeStrategy.keepLonger,
  }) async {
    final current = state.requireValue;
    if (enabled == current.shareCategories) {
      return;
    }

    if (enabled) {
      await _persist(enableSharedCategories(current, strategy));
      return;
    }

    final mirroredCategories = current.mustDoCategories
        .map((item) => item.copyWith())
        .toList();
    await _persist(
      current.copyWith(
        mustDoCategories: mirroredCategories,
        wantToDoCategories: mirroredCategories
            .map((item) => item.copyWith())
            .toList(),
        shareCategories: false,
      ),
    );
  }

  Future<void> _persist(TaskMasterStateData next) async {
    state = AsyncData(next);
    await _repository.save(next);
  }

  List<TaskMaster> _sortTasks(List<TaskMaster> tasks) {
    final next = List<TaskMaster>.from(tasks);
    next.sort((a, b) {
      final priorityCompare = b.priority.compareTo(a.priority);
      if (priorityCompare != 0) {
        return priorityCompare;
      }
      return a.title.compareTo(b.title);
    });
    return next;
  }
}
