import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/device_clock.dart';
import '../../../core/sync_meta.dart';
import '../../../core/tombstone.dart';
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

  DeviceClock get _device => ref.read(deviceClockProvider);

  /// Serializes mutations. Every public mutation reads `_current` inside the
  /// queued body, so two calls that were fired without an `await` between them
  /// cannot both build on the same stale snapshot and lose one another.
  Future<void> _chain = Future<void>.value();

  Future<T> _mutate<T>(Future<T> Function() body) {
    final result = _chain.then((_) => body());
    // The chain must survive a failed mutation, but the failure still has to
    // reach the caller, so only the chain's copy swallows it.
    _chain = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Issues a fresh clock and folds it into [previous], or starts a new meta.
  Future<SyncMeta> _stamp(SyncMeta? previous) async {
    final clock = await _device.next();
    final now = DateTime.now().toUtc();
    return previous == null
        ? SyncMeta.stamp(clock, now)
        : previous.touch(clock, now);
  }

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

  Future<void> addOrUpdateTask(TaskMaster task) =>
      _mutate(() => _addOrUpdateTask(task));

  Future<void> _addOrUpdateTask(TaskMaster task) async {
    final current = _current;
    final index = current.tasks.indexWhere((item) => item.id == task.id);
    final previousMeta = index >= 0 ? current.tasks[index].meta : null;
    final stampedMeta = await _stamp(previousMeta);
    final sanitizedTask = sanitizeTaskAgainstCategories(
      task,
      current,
    ).copyWith(meta: stampedMeta, updatedAt: stampedMeta.updatedAt);
    final tasks = List<TaskMaster>.from(current.tasks);

    if (index >= 0) {
      tasks[index] = sanitizedTask;
    } else {
      tasks.add(sanitizedTask);
    }

    await _persist(
      current.copyWith(
        tasks: _sortTasks(tasks),
        // Re-adding a deleted id must retire its tombstone, or the record
        // would be both live and deleted in the same payload.
        deletedTasks: withoutTombstonesFor(current.deletedTasks, <String>[
          task.id,
        ]),
      ),
    );
  }

  Future<void> deleteTask(String id) => _mutate(() => _deleteTask(id));

  Future<void> _deleteTask(String id) async {
    final current = _current;
    final target = current.tasks.where((task) => task.id == id).firstOrNull;
    if (target == null) {
      return;
    }
    final clock = await _device.next();
    final tombstone = Tombstone(
      id: id,
      meta: target.meta.tombstone(clock, DateTime.now().toUtc()),
    );
    await _persist(
      current.copyWith(
        tasks: current.tasks.where((task) => task.id != id).toList(),
        deletedTasks: <Tombstone>[...current.deletedTasks, tombstone],
      ),
    );
  }

  Future<void> reorderTasks({
    required TaskKind kind,
    required List<String> orderedIds,
  }) {
    return _mutate(() => _reorderTasks(kind: kind, orderedIds: orderedIds));
  }

  Future<void> _reorderTasks({
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
    final reorderedTasks = <TaskMaster>[];
    for (var index = 0; index < orderedTasks.length; index += 1) {
      final meta = await _stamp(orderedTasks[index].meta);
      reorderedTasks.add(
        orderedTasks[index].copyWith(
          priority: orderedTasks.length - index,
          updatedAt: meta.updatedAt,
          meta: meta,
        ),
      );
    }
    final others = current.tasks.where((task) => task.kind != kind).toList();
    await _persist(
      current.copyWith(tasks: _sortTasks([...others, ...reorderedTasks])),
    );
  }

  Future<void> upsertCategory({
    required TaskKind kind,
    required TaskCategory category,
  }) {
    return _mutate(() => _upsertCategory(kind: kind, category: category));
  }

  Future<void> _upsertCategory({
    required TaskKind kind,
    required TaskCategory category,
  }) async {
    final current = _current;
    final mustDo = List<TaskCategory>.from(current.mustDoCategories);
    final wantToDo = List<TaskCategory>.from(current.wantToDoCategories);
    final previous = <TaskCategory>[...mustDo, ...wantToDo]
        .where((item) => item.id == category.id)
        .firstOrNull;
    final stamped = category.copyWith(meta: await _stamp(previous?.meta));

    void updateList(List<TaskCategory> categories) {
      validateCategoryNameUniqueness(
        category: stamped,
        categories: categories,
      );
      final index = categories.indexWhere((item) => item.id == stamped.id);
      if (index >= 0) {
        categories[index] = stamped;
      } else {
        categories.add(stamped);
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
      current.copyWith(
        mustDoCategories: mustDo,
        wantToDoCategories: wantToDo,
        deletedMustDoCategories: withoutTombstonesFor(
          current.deletedMustDoCategories,
          mustDo.map((item) => item.id),
        ),
        deletedWantToDoCategories: withoutTombstonesFor(
          current.deletedWantToDoCategories,
          wantToDo.map((item) => item.id),
        ),
      ),
    );
  }

  Future<void> deleteCategory({
    required TaskKind kind,
    required String categoryId,
  }) {
    return _mutate(() => _deleteCategory(kind: kind, categoryId: categoryId));
  }

  Future<void> _deleteCategory({
    required TaskKind kind,
    required String categoryId,
  }) async {
    final current = _current;
    final updated = deleteCategoryFromState(
      current,
      kind: kind,
      categoryId: categoryId,
      clock: await _device.next(),
      now: DateTime.now().toUtc(),
    );
    await _persist(updated);
  }

  Future<void> setShareCategories({
    required bool enabled,
    CategoryMergeStrategy strategy = CategoryMergeStrategy.keepLonger,
  }) {
    return _mutate(
      () => _setShareCategories(enabled: enabled, strategy: strategy),
    );
  }

  Future<void> _setShareCategories({
    required bool enabled,
    CategoryMergeStrategy strategy = CategoryMergeStrategy.keepLonger,
  }) async {
    final current = _current;
    if (enabled == current.shareCategories) {
      return;
    }

    final clock = await _device.next();
    final now = DateTime.now().toUtc();
    final settingsMeta = current.settingsMeta.touch(clock, now);

    if (enabled) {
      await _persist(
        enableSharedCategories(
          current,
          strategy,
          clock: clock,
          now: now,
        ).copyWith(settingsMeta: settingsMeta),
      );
      return;
    }

    // Turning sharing off snapshots the must-do list into both lists; only the
    // entries that are new to a list are stamped.
    final mustDo = current.mustDoCategories;
    final wantToDo = mirrorCategories(
      previous: current.wantToDoCategories,
      source: mustDo,
      clock: clock,
      now: now,
    );
    await _persist(
      current.copyWith(
        mustDoCategories: mustDo,
        wantToDoCategories: wantToDo,
        deletedWantToDoCategories: withoutTombstonesFor(
          current.deletedWantToDoCategories,
          wantToDo.map((item) => item.id),
        ),
        shareCategories: false,
        settingsMeta: settingsMeta,
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
