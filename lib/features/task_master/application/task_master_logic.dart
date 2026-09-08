import '../../../core/hlc.dart';
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

TaskMasterStateData enableSharedCategories(
  TaskMasterStateData state,
  CategoryMergeStrategy strategy,
) {
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
    if (previousCategory == null) {
      return task.copyWith(clearCategory: true);
    }

    final matchedCategory = mergedCategories
        .where((category) => category.name == previousCategory.name)
        .firstOrNull;
    return matchedCategory == null
        ? task.copyWith(clearCategory: true)
        : task.copyWith(categoryId: matchedCategory.id);
  }).toList();

  return state.copyWith(
    tasks: normalizedTasks,
    mustDoCategories: mergedCategories,
    wantToDoCategories: mergedCategories,
    shareCategories: true,
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
