import '../../daily_plan/domain/daily_plan_models.dart';
import '../../task_master/domain/task_models.dart';

List<SlotTaskAssignment> assignmentsOverlappingRange(
  Iterable<SlotTaskAssignment> assignments, {
  required DateTime start,
  required DateTime end,
}) {
  final items = assignments.where((item) {
    return item.startAt.isBefore(end) && item.endAt.isAfter(start);
  }).toList()..sort((a, b) => a.startAt.compareTo(b.startAt));
  return items;
}

int overlapMinutesInRange(
  SlotTaskAssignment assignment, {
  required DateTime start,
  required DateTime end,
}) {
  final overlapStart = assignment.startAt.isAfter(start)
      ? assignment.startAt
      : start;
  final overlapEnd = assignment.endAt.isBefore(end) ? assignment.endAt : end;
  if (!overlapStart.isBefore(overlapEnd)) {
    return 0;
  }
  return overlapEnd.difference(overlapStart).inMinutes;
}

int totalAssignedMinutes(
  Iterable<SlotTaskAssignment> assignments, {
  required DateTime start,
  required DateTime end,
}) {
  return assignments.fold<int>(
    0,
    (sum, item) => sum + overlapMinutesInRange(item, start: start, end: end),
  );
}

int estimatedMinutesForAssignments(
  Iterable<SlotTaskAssignment> assignments,
  Iterable<TaskMaster> tasks,
) {
  final tasksById = <String, TaskMaster>{
    for (final task in tasks) task.id: task,
  };
  return assignments.fold<int>(0, (sum, item) {
    return sum + (tasksById[item.taskId]?.estimatedMinutes ?? 0);
  });
}

Map<String, int> categoryTotals(
  Iterable<SlotTaskAssignment> assignments, {
  required DateTime start,
  required DateTime end,
  required Iterable<TaskMaster> tasks,
  required Iterable<TaskCategory> categories,
}) {
  final tasksById = <String, TaskMaster>{
    for (final task in tasks) task.id: task,
  };
  final categoriesById = <String, TaskCategory>{
    for (final category in categories) category.id: category,
  };
  final totals = <String, int>{};

  for (final item in assignments) {
    final minutes = overlapMinutesInRange(item, start: start, end: end);
    if (minutes == 0) {
      continue;
    }

    final currentTask = tasksById[item.taskId];
    final currentCategory = currentTask?.categoryId == null
        ? null
        : categoriesById[currentTask!.categoryId!];
    final label = currentCategory?.name ?? item.categoryName ?? '未分類';
    totals.update(label, (value) => value + minutes, ifAbsent: () => minutes);
  }

  final entries = totals.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return Map<String, int>.fromEntries(entries);
}

DateTime weekStart(DateTime anchorDate) {
  final date = DateTime(anchorDate.year, anchorDate.month, anchorDate.day);
  return date.subtract(Duration(days: date.weekday - DateTime.monday));
}
