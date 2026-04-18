import '../domain/task_models.dart';

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
}) {
  final mustDoCategories = List<TaskCategory>.from(state.mustDoCategories);
  final wantToDoCategories = List<TaskCategory>.from(state.wantToDoCategories);

  if (state.shareCategories || kind == TaskKind.mustDo) {
    mustDoCategories.removeWhere((category) => category.id == categoryId);
  }
  if (state.shareCategories || kind == TaskKind.wantToDo) {
    wantToDoCategories.removeWhere((category) => category.id == categoryId);
  }

  final tasks = state.tasks.map((task) {
    return task.categoryId == categoryId
        ? task.copyWith(clearCategory: true, updatedAt: DateTime.now())
        : task;
  }).toList();

  return state.copyWith(
    tasks: tasks,
    mustDoCategories: mustDoCategories,
    wantToDoCategories: wantToDoCategories,
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
