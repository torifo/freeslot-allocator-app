import '../../../core/hlc.dart';
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

/// Renumbers `sortOrder` to the slot's time order.
///
/// A renumbering is a real change that peers must see, so an entry whose
/// `sortOrder` actually moves is stamped with [clock]/[now] when both are
/// given. Entries that keep their position keep their meta untouched.
List<SlotTaskAssignment> normalizeAssignmentsForSlot(
  Iterable<SlotTaskAssignment> assignments, {
  Hlc? clock,
  DateTime? now,
}) {
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

  return items.asMap().entries.map((entry) {
    final item = entry.value;
    if (item.sortOrder == entry.key) {
      return item;
    }
    return item.copyWith(
      sortOrder: entry.key,
      meta: clock != null && now != null ? item.meta.touch(clock, now) : null,
    );
  }).toList();
}

DateTime shiftDateTimeByDays(DateTime value, int days) {
  return value.add(Duration(days: days));
}

List<SlotTaskAssignment> moveAssignmentToSlotPosition({
  required SlotTaskAssignment assignment,
  required FreeTimeSlot targetSlot,
  required List<SlotTaskAssignment> existingAssignments,
  String? beforeAssignmentId,
  Hlc? clock,
  DateTime? now,
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

  return normalizeAssignmentsForSlot(normalized, clock: clock, now: now);
}

SlotTaskAssignment moveAssignmentToSlotEnd({
  required SlotTaskAssignment assignment,
  required FreeTimeSlot targetSlot,
  required List<SlotTaskAssignment> existingAssignments,
  Hlc? clock,
  DateTime? now,
}) {
  return moveAssignmentToSlotPosition(
    assignment: assignment,
    targetSlot: targetSlot,
    existingAssignments: existingAssignments,
    clock: clock,
    now: now,
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

// ── Dialog defaults and follow-up maths ───────────────────────
//
// Kept here rather than in the dialogs so the arithmetic the walkthrough found
// wrong (negative durations, an end time that ignores the task's estimate) can
// be tested without pumping a widget.

/// The next 30-minute boundary at or after [now].
///
/// A `now` that is already exactly on a boundary is that boundary; anything
/// past it (even by a second) rounds up, so the default never starts in the
/// past.
DateTime nextHalfHourBoundary(DateTime now) {
  final truncated = DateTime(now.year, now.month, now.day, now.hour, now.minute);
  final remainder = truncated.minute % 30;
  if (remainder == 0 && truncated.isAtSameMomentAs(now)) {
    return truncated;
  }
  return truncated.add(Duration(minutes: 30 - remainder));
}

/// The free-time slot a user most likely wants when they tap 追加: the next
/// half hour on [planDate], one hour long.
///
/// 「次の 30 分」 only means anything on the day the user is actually living
/// through: on any other day the default is a plain 09:00–10:00, rather than
/// tonight's clock time stamped onto next Tuesday (M-1). Late in the evening
/// the range is squeezed into 23:00–23:59 instead of rolling into the day
/// after — the dialog reads clock times only, so a start of 00:30 would
/// silently mean this morning, in the past.
({DateTime start, DateTime end}) defaultFreeSlotRange(
  DateTime now,
  DateTime planDate,
) {
  final day = dateOnly(planDate);
  final lateStart = day.add(const Duration(hours: 23));
  final lateEnd = day.add(const Duration(hours: 23, minutes: 59));
  if (!dateOnly(now).isAtSameMomentAs(day)) {
    return (
      start: day.add(const Duration(hours: 9)),
      end: day.add(const Duration(hours: 10)),
    );
  }
  final start = nextHalfHourBoundary(now);
  if (!dateOnly(start).isAtSameMomentAs(day) || !start.isBefore(lateStart)) {
    return (start: lateStart, end: lateEnd);
  }
  return (start: start, end: start.add(const Duration(hours: 1)));
}

/// Where the end of a slot has to move when its start is dragged past it.
///
/// Minutes are counted from midnight of the plan's own day, so an end on the
/// following day is simply 1440 or more. The slot keeps the length it had; a
/// slot with no length yet (a fresh one, or one already broken) gets an hour.
int followingEndMinutes({
  required int previousStartMinutes,
  required int previousEndMinutes,
  required int newStartMinutes,
}) {
  if (newStartMinutes < previousEndMinutes) {
    return previousEndMinutes;
  }
  final previousLength = previousEndMinutes - previousStartMinutes;
  return newStartMinutes + (previousLength > 0 ? previousLength : 60);
}

/// The end time an assignment should get when its source task is chosen.
///
/// The task's own estimate is the point of recording it; a task with no
/// estimate falls back to half an hour. Never runs past the slot it lives in.
DateTime assignmentEndForEstimate({
  required DateTime start,
  required int estimatedMinutes,
  required DateTime slotEnd,
}) {
  final minutes = estimatedMinutes > 0 ? estimatedMinutes : 30;
  final end = start.add(Duration(minutes: minutes));
  // Including a start already at or past the slot's end: the doc says never
  // past the slot, and the old guard quietly made an exception of the one case
  // where the result was furthest outside it (M-2).
  return end.isAfter(slotEnd) ? slotEnd : end;
}

/// Free minutes that nothing has been assigned to yet. Never negative: an
/// over-booked day is 「残り 0 分」, not a minus sign the user has to decode.
int remainingFreeMinutes({
  required int freeMinutes,
  required int assignedMinutes,
}) {
  final remaining = freeMinutes - assignedMinutes;
  return remaining < 0 ? 0 : remaining;
}

/// 「2 時間 30 分」 — the shape used for every duration the user reads.
///
/// The empty half is dropped: under an hour is 「45 分」 and a whole number of
/// hours is 「1 時間」, because 「0 時間 45 分」 and 「1 時間 0 分」 are how a clock
/// counts, not how anyone says it (I-5). Nothing at all is still 「0 分」.
String formatHoursMinutes(int minutes) {
  final safe = minutes < 0 ? 0 : minutes;
  final hours = safe ~/ 60;
  final remainder = safe % 60;
  if (hours == 0) return '$remainder 分';
  if (remainder == 0) return '$hours 時間';
  return '$hours 時間 $remainder 分';
}
