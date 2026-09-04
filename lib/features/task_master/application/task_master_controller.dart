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

  /// Returns the loaded state, or throws a user-facing validation error when a
  /// mutation is attempted while the state is still loading or has failed.
  TaskMasterStateData get _current {
    final snapshot = state;
    if (!snapshot.hasValue) {
      throw const TaskMasterValidationException('データの読み込みが完了していません。');
    }
    return snapshot.value as TaskMasterStateData;
  }

  Future<void> addOrUpdateTask(TaskMaster task) async {
    final current = _current;
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
    final current = _current;
    final tasks = current.tasks.where((task) => task.id != id).toList();
    await _persist(current.copyWith(tasks: tasks));
  }

  Future<void> reorderTasks({
    required TaskKind kind,
    required List<String> orderedIds,
  }) async {
    final current = _current;
    final tasksOfKind = current.tasks
        .where((task) => task.kind == kind)
        .toList();
    if (tasksOfKind.length <= 1) {
      return;
    }

    final taskById = <String, TaskMaster>{
      for (final task in tasksOfKind) task.id: task,
    };
    final orderedTasks = <TaskMaster>[
      for (final id in orderedIds)
        if (taskById.containsKey(id)) taskById[id]!,
      for (final task in tasksOfKind)
        if (!orderedIds.contains(task.id)) task,
    ];
    final now = DateTime.now();
    final reorderedTasks = <TaskMaster>[
      for (var index = 0; index < orderedTasks.length; index += 1)
        orderedTasks[index].copyWith(
          priority: orderedTasks.length - index,
          updatedAt: now,
        ),
    ];
    final others = current.tasks.where((task) => task.kind != kind).toList();
    await _persist(
      current.copyWith(tasks: _sortTasks([...others, ...reorderedTasks])),
    );
  }

  Future<void> upsertCategory({
    required TaskKind kind,
    required TaskCategory category,
  }) async {
    final current = _current;
    final mustDo = List<TaskCategory>.from(current.mustDoCategories);
    final wantToDo = List<TaskCategory>.from(current.wantToDoCategories);

    void updateList(List<TaskCategory> categories) {
      validateCategoryNameUniqueness(
        category: category,
        categories: categories,
      );
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
    final current = _current;
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
    final current = _current;
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

  /// Publishes the new state immediately so consecutive mutations build on
  /// the latest value, then writes to storage. If the save fails the previous
  /// state is restored so the UI never shows data that was not persisted.
  Future<void> _persist(TaskMasterStateData next) async {
    final previous = state;
    state = AsyncData(next);
    try {
      await _repository.save(next);
    } catch (_) {
      state = previous;
      rethrow;
    }
  }

  List<TaskMaster> _sortTasks(List<TaskMaster> tasks) {
    final next = List<TaskMaster>.from(tasks);
    next.sort((a, b) {
      final kindCompare = a.kind.index.compareTo(b.kind.index);
      if (kindCompare != 0) {
        return kindCompare;
      }
      final priorityCompare = b.priority.compareTo(a.priority);
      if (priorityCompare != 0) {
        return priorityCompare;
      }
      return a.title.compareTo(b.title);
    });
    return next;
  }
}
