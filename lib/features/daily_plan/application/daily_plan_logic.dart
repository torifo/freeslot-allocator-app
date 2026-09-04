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

void validateFreeTimeSlotAgainstPlan({
  required FreeTimeSlot slot,
  required Iterable<FreeTimeSlot> existingSlots,
}) {
  validateFreeTimeSlot(slot);
  for (final current in existingSlots) {
    if (current.id == slot.id) {
      continue;
    }
    final overlaps =
        slot.startAt.isBefore(current.endAt) &&
        slot.endAt.isAfter(current.startAt);
    if (overlaps) {
      throw const DailyPlanValidationException('自由時間枠どうしが重複しています。');
    }
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

DateTime shiftDateTimeByDays(DateTime value, int days) {
  return value.add(Duration(days: days));
}

List<SlotTaskAssignment> moveAssignmentToSlotPosition({
  required SlotTaskAssignment assignment,
  required FreeTimeSlot targetSlot,
  required List<SlotTaskAssignment> existingAssignments,
  String? beforeAssignmentId,
}) {
  final remainingAssignments = existingAssignments
      .where((item) => item.id != assignment.id)
      .toList();
  final insertIndex = beforeAssignmentId == null
      ? remainingAssignments.length
      : remainingAssignments.indexWhere(
          (item) => item.id == beforeAssignmentId,
        );

  if (insertIndex < 0) {
    throw const DailyPlanValidationException('移動先の位置が見つかりません。');
  }

  final prefix = remainingAssignments.take(insertIndex).toList();
  final suffix = remainingAssignments.skip(insertIndex);
  final ordered = <SlotTaskAssignment>[
    ...prefix,
    assignment.copyWith(
      dailyPlanId: targetSlot.dailyPlanId,
      slotId: targetSlot.id,
    ),
    ...suffix,
  ];

  final normalized = <SlotTaskAssignment>[];
  var cursor = targetSlot.startAt;
  for (final current in ordered) {
    final previous = normalized.lastOrNull;
    if (previous != null) {
      cursor = previous.endAt;
    }
    final rebuilt = current.copyWith(
      dailyPlanId: targetSlot.dailyPlanId,
      slotId: targetSlot.id,
      startAt: cursor,
      endAt: cursor.add(Duration(minutes: current.durationMinutes)),
    );
    normalized.add(rebuilt);
  }

  for (final current in normalized) {
    validateAssignment(
      assignment: current,
      slot: targetSlot,
      existingAssignments: normalized,
    );
  }

  return normalizeAssignmentsForSlot(normalized);
}

SlotTaskAssignment moveAssignmentToSlotEnd({
  required SlotTaskAssignment assignment,
  required FreeTimeSlot targetSlot,
  required List<SlotTaskAssignment> existingAssignments,
}) {
  return moveAssignmentToSlotPosition(
    assignment: assignment,
    targetSlot: targetSlot,
    existingAssignments: existingAssignments,
  ).last;
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

/// The time range rendered by the daily plan timeline.
class TimelineWindow {
  const TimelineWindow({required this.start, required this.end});

  final DateTime start;
  final DateTime end;

  @override
  bool operator ==(Object other) =>
      other is TimelineWindow && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'TimelineWindow($start, $end)';
}

DateTime _floorToHour(DateTime value) =>
    DateTime(value.year, value.month, value.day, value.hour);

DateTime _ceilToHour(DateTime value) {
  final floored = _floorToHour(value);
  return floored == value ? floored : floored.add(const Duration(hours: 1));
}

/// Expands the view mode's default window so that every slot (and every
/// assignment inside it) stays fully visible. Slots starting before the
/// default start would otherwise render above the clipped timeline card, and
/// slots ending after the default end would be cut off.
TimelineWindow resolveTimelineWindow({
  required DateTime defaultStart,
  required DateTime defaultEnd,
  required Iterable<FreeTimeSlot> slots,
  Iterable<SlotTaskAssignment> assignments = const <SlotTaskAssignment>[],
}) {
  var start = defaultStart;
  var end = defaultEnd;

  void include(DateTime from, DateTime to) {
    final flooredStart = _floorToHour(from);
    final ceiledEnd = _ceilToHour(to);
    if (flooredStart.isBefore(start)) {
      start = flooredStart;
    }
    if (ceiledEnd.isAfter(end)) {
      end = ceiledEnd;
    }
  }

  for (final slot in slots) {
    include(slot.startAt, slot.endAt);
  }
  for (final assignment in assignments) {
    include(assignment.startAt, assignment.endAt);
  }

  return TimelineWindow(start: start, end: end);
}
