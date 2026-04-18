import '../domain/daily_plan_models.dart';

class DailyPlanValidationException implements Exception {
  const DailyPlanValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

void validateFreeTimeSlot(FreeTimeSlot slot) {
  if (!slot.startAt.isBefore(slot.endAt)) {
    throw const DailyPlanValidationException('自由時間枠は開始より後に終了する必要があります。');
  }
  if (slot.durationMinutes < 1) {
    throw const DailyPlanValidationException('自由時間枠は1分以上で設定してください。');
  }
}

List<FreeTimeSlot> sortSlots(Iterable<FreeTimeSlot> slots) {
  final items = slots.toList();
  items.sort((a, b) => a.startAt.compareTo(b.startAt));
  return items;
}

List<SlotTaskAssignment> normalizeAssignmentsForSlot(
  Iterable<SlotTaskAssignment> assignments,
) {
  final items = assignments.toList()
    ..sort((a, b) {
      final startCompare = a.startAt.compareTo(b.startAt);
      if (startCompare != 0) {
        return startCompare;
      }
      final endCompare = a.endAt.compareTo(b.endAt);
      if (endCompare != 0) {
        return endCompare;
      }
      return a.sortOrder.compareTo(b.sortOrder);
    });

  return items
      .asMap()
      .entries
      .map((entry) => entry.value.copyWith(sortOrder: entry.key))
      .toList();
}

void validateAssignment({
  required SlotTaskAssignment assignment,
  required FreeTimeSlot slot,
  required List<SlotTaskAssignment> existingAssignments,
}) {
  if (!assignment.startAt.isBefore(assignment.endAt)) {
    throw const DailyPlanValidationException('予定は開始より後に終了する必要があります。');
  }
  if (assignment.durationMinutes < 1) {
    throw const DailyPlanValidationException('予定は1分以上で設定してください。');
  }
  if (assignment.startAt.isBefore(slot.startAt) ||
      assignment.endAt.isAfter(slot.endAt)) {
    throw const DailyPlanValidationException('予定は自由時間枠の範囲内に収めてください。');
  }

  for (final current in existingAssignments) {
    if (current.id == assignment.id) {
      continue;
    }
    final overlaps =
        assignment.startAt.isBefore(current.endAt) &&
        assignment.endAt.isAfter(current.startAt);
    if (overlaps) {
      throw const DailyPlanValidationException('同じ自由時間枠の予定が重複しています。');
    }
  }
}
