import '../../../core/hlc.dart';
import '../../../core/tombstone.dart';
import '../domain/task_models.dart';

class TaskMasterValidationException implements Exception {
  const TaskMasterValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

List<TaskCategory> mergeCategories({
  required List<TaskCategory> mustDoCategories,
  required List<TaskCategory> wantToDoCategories,
  required CategoryMergeStrategy strategy,
}) {
  final mustDo = List<TaskCategory>.from(mustDoCategories);
  final wantToDo = List<TaskCategory>.from(wantToDoCategories);

  switch (strategy) {
    case CategoryMergeStrategy.keepShorter:
      return (mustDo.length <= wantToDo.length ? mustDo : wantToDo)
          .map((category) => category.copyWith())
          .toList();
    case CategoryMergeStrategy.keepLonger:
      return (mustDo.length >= wantToDo.length ? mustDo : wantToDo)
          .map((category) => category.copyWith())
          .toList();
    case CategoryMergeStrategy.keepMustDo:
      return mustDo.map((category) => category.copyWith()).toList();
    case CategoryMergeStrategy.keepWantToDo:
      return wantToDo.map((category) => category.copyWith()).toList();
  }
}

void validateCategoryNameUniqueness({
  required TaskCategory category,
  required Iterable<TaskCategory> categories,
}) {
  final duplicated = categories.any(
    (item) => item.id != category.id && item.name == category.name,
  );
  if (duplicated) {
    throw const TaskMasterValidationException('同じ名前のカテゴリがすでに存在します。');
  }
}

/// Collapses both category lists into one shared list.
///
/// Every category dropped from a list is tombstoned in that list's graveyard,
/// every category newly joining a list is stamped so peers see the change, and
/// only tasks whose `categoryId` actually moved are touched.
TaskMasterStateData enableSharedCategories(
  TaskMasterStateData state,
  CategoryMergeStrategy strategy, {
  required Hlc clock,
  required DateTime now,
}) {
  final mergedCategories = mergeCategories(
    mustDoCategories: state.mustDoCategories,
    wantToDoCategories: state.wantToDoCategories,
    strategy: strategy,
  );

  final mergedIds = mergedCategories.map((category) => category.id).toSet();

  final normalizedTasks = state.tasks.map((task) {
    if (task.categoryId == null || mergedIds.contains(task.categoryId)) {
      return task;
    }
    final previousCategories = task.kind == TaskKind.mustDo
        ? state.mustDoCategories
        : state.wantToDoCategories;
    final previousCategory = previousCategories
        .where((category) => category.id == task.categoryId)
        .firstOrNull;
    final matchedCategory = previousCategory == null
        ? null
        : mergedCategories
              .where((category) => category.name == previousCategory.name)
              .firstOrNull;
    final moved = matchedCategory == null
        ? task.copyWith(clearCategory: true)
        : task.copyWith(categoryId: matchedCategory.id);
    return moved.copyWith(updatedAt: now, meta: task.meta.touch(clock, now));
  }).toList();

  return state.copyWith(
    tasks: normalizedTasks,
    mustDoCategories: _adoptCategories(
      state.mustDoCategories,
      mergedCategories,
      clock,
      now,
    ),
    wantToDoCategories: _adoptCategories(
      state.wantToDoCategories,
      mergedCategories,
      clock,
      now,
    ),
    deletedMustDoCategories: graveyardAfterMerge(
      state.deletedMustDoCategories,
      state.mustDoCategories,
      mergedIds,
      clock,
      now,
    ),
    deletedWantToDoCategories: graveyardAfterMerge(
      state.deletedWantToDoCategories,
      state.wantToDoCategories,
      mergedIds,
      clock,
      now,
    ),
    shareCategories: true,
  );
}

/// Rebuilds one category list as [next], stamping only the entries that were
/// not already in [previous] so untouched categories keep their clock.
List<TaskCategory> _adoptCategories(
  List<TaskCategory> previous,
  List<TaskCategory> next,
  Hlc clock,
  DateTime now,
) {
  final previousById = <String, TaskCategory>{
    for (final category in previous) category.id: category,
  };
  return next.map((category) {
    final existing = previousById[category.id];
    return existing ??
        category.copyWith(meta: category.meta.touch(clock, now));
  }).toList();
}

/// Tombstones every category of [previous] that [keptIds] discards, and drops
/// tombstones whose id came back to life.
List<Tombstone> graveyardAfterMerge(
  List<Tombstone> graveyard,
  List<TaskCategory> previous,
  Set<String> keptIds,
  Hlc clock,
  DateTime now,
) {
  return <Tombstone>[
    ...withoutTombstonesFor(graveyard, keptIds),
    for (final category in previous)
      if (!keptIds.contains(category.id))
        Tombstone(id: category.id, meta: category.meta.tombstone(clock, now)),
  ];
}

/// Mirrors [source] into a list that currently holds [previous], stamping only
/// the entries that are new to it. Used when shared categories are turned off.
List<TaskCategory> mirrorCategories({
  required List<TaskCategory> previous,
  required List<TaskCategory> source,
  required Hlc clock,
  required DateTime now,
}) {
  return _adoptCategories(
    previous,
    source.map((category) => category.copyWith()).toList(),
    clock,
    now,
  );
}

TaskMasterStateData deleteCategoryFromState(
  TaskMasterStateData state, {
  required TaskKind kind,
  required String categoryId,
  required Hlc clock,
  required DateTime now,
}) {
  final mustDo = List<TaskCategory>.from(state.mustDoCategories);
  final wantToDo = List<TaskCategory>.from(state.wantToDoCategories);
  final deletedMustDo = List<Tombstone>.from(state.deletedMustDoCategories);
  final deletedWantToDo = List<Tombstone>.from(
    state.deletedWantToDoCategories,
  );

  void remove(List<TaskCategory> list, List<Tombstone> graveyard) {
    final index = list.indexWhere((category) => category.id == categoryId);
    if (index < 0) {
      return;
    }
    graveyard.add(
      Tombstone(id: categoryId, meta: list[index].meta.tombstone(clock, now)),
    );
    list.removeAt(index);
  }

  if (state.shareCategories || kind == TaskKind.mustDo) {
    remove(mustDo, deletedMustDo);
  }
  if (state.shareCategories || kind == TaskKind.wantToDo) {
    remove(wantToDo, deletedWantToDo);
  }

  final tasks = state.tasks.map((task) {
    return task.categoryId == categoryId
        ? task.copyWith(
            clearCategory: true,
            updatedAt: now,
            meta: task.meta.touch(clock, now),
          )
        : task;
  }).toList();

  return state.copyWith(
    tasks: tasks,
    mustDoCategories: mustDo,
    wantToDoCategories: wantToDo,
    deletedMustDoCategories: deletedMustDo,
    deletedWantToDoCategories: deletedWantToDo,
  );
}

TaskMaster sanitizeTaskAgainstCategories(
  TaskMaster task,
  TaskMasterStateData state,
) {
  final allowedIds = state
      .categoriesFor(task.kind)
      .map((category) => category.id)
      .toSet();
  if (task.categoryId == null || allowedIds.contains(task.categoryId)) {
    return task;
  }
  return task.copyWith(clearCategory: true);
}
