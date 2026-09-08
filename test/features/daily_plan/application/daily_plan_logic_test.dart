import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/features/daily_plan/application/daily_plan_logic.dart';
import 'package:frelocator/features/daily_plan/domain/daily_plan_models.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';

void main() {
  group('validateFreeTimeSlot', () {
    test('allows cross-midnight slots', () {
      final slot = FreeTimeSlot(
        id: 'slot-1',
        dailyPlanId: 'plan-1',
        startAt: DateTime(2026, 4, 18, 21),
        endAt: DateTime(2026, 4, 19, 0, 30),
      );

      expect(() => validateFreeTimeSlot(slot), returnsNormally);
    });
  });

  group('validateAssignment', () {
    final slot = FreeTimeSlot(
      id: 'slot-1',
      dailyPlanId: 'plan-1',
      startAt: DateTime(2026, 4, 18, 21),
      endAt: DateTime(2026, 4, 19, 0, 30),
    );

    test('rejects assignments outside the slot range', () {
      final assignment = SlotTaskAssignment(
        id: 'a1',
        dailyPlanId: 'plan-1',
        slotId: 'slot-1',
        taskId: 'task-1',
        taskTitle: '読書',
        taskKind: TaskKind.wantToDo,
        startAt: DateTime(2026, 4, 18, 20, 55),
        endAt: DateTime(2026, 4, 18, 21, 15),
        sortOrder: 0,
      );

      expect(
        () => validateAssignment(
          assignment: assignment,
          slot: slot,
          existingAssignments: const <SlotTaskAssignment>[],
        ),
        throwsA(isA<DailyPlanValidationException>()),
      );
    });

    test('rejects overlapping assignments', () {
      final existing = SlotTaskAssignment(
        id: 'a1',
        dailyPlanId: 'plan-1',
        slotId: 'slot-1',
        taskId: 'task-1',
        taskTitle: '洗濯',
        taskKind: TaskKind.mustDo,
        startAt: DateTime(2026, 4, 18, 21),
        endAt: DateTime(2026, 4, 18, 21, 30),
        sortOrder: 0,
      );
      final next = SlotTaskAssignment(
        id: 'a2',
        dailyPlanId: 'plan-1',
        slotId: 'slot-1',
        taskId: 'task-2',
        taskTitle: '片付け',
        taskKind: TaskKind.mustDo,
        startAt: DateTime(2026, 4, 18, 21, 20),
        endAt: DateTime(2026, 4, 18, 21, 50),
        sortOrder: 1,
      );

      expect(
        () => validateAssignment(
          assignment: next,
          slot: slot,
          existingAssignments: <SlotTaskAssignment>[existing],
        ),
        throwsA(isA<DailyPlanValidationException>()),
      );
    });
  });

  test('normalizeAssignmentsForSlot rebuilds sortOrder in time order', () {
    final normalized = normalizeAssignmentsForSlot(<SlotTaskAssignment>[
      SlotTaskAssignment(
        id: 'late',
        dailyPlanId: 'plan-1',
        slotId: 'slot-1',
        taskId: 'task-2',
        taskTitle: '読書',
        taskKind: TaskKind.wantToDo,
        startAt: DateTime(2026, 4, 18, 22),
        endAt: DateTime(2026, 4, 18, 22, 20),
        sortOrder: 0,
      ),
      SlotTaskAssignment(
        id: 'early',
        dailyPlanId: 'plan-1',
        slotId: 'slot-1',
        taskId: 'task-1',
        taskTitle: '洗濯',
        taskKind: TaskKind.mustDo,
        startAt: DateTime(2026, 4, 18, 21),
        endAt: DateTime(2026, 4, 18, 21, 20),
        sortOrder: 5,
      ),
    ]);

    expect(normalized.map((item) => item.id), <String>['early', 'late']);
    expect(normalized.map((item) => item.sortOrder), <int>[0, 1]);
  });

  test('moveAssignmentToSlotEnd appends the assignment to the target slot', () {
    final targetSlot = FreeTimeSlot(
      id: 'slot-2',
      dailyPlanId: 'plan-1',
      startAt: DateTime(2026, 4, 19, 9),
      endAt: DateTime(2026, 4, 19, 11),
    );
    final existing = SlotTaskAssignment(
      id: 'existing',
      dailyPlanId: 'plan-1',
      slotId: 'slot-2',
      taskId: 'task-1',
      taskTitle: '朝の支度',
      taskKind: TaskKind.mustDo,
      startAt: DateTime(2026, 4, 19, 9),
      endAt: DateTime(2026, 4, 19, 9, 30),
      sortOrder: 0,
    );
    final assignment = SlotTaskAssignment(
      id: 'moved',
      dailyPlanId: 'plan-1',
      slotId: 'slot-1',
      taskId: 'task-2',
      taskTitle: '読書',
      taskKind: TaskKind.wantToDo,
      startAt: DateTime(2026, 4, 18, 21),
      endAt: DateTime(2026, 4, 18, 21, 20),
      sortOrder: 0,
    );

    final moved = moveAssignmentToSlotEnd(
      assignment: assignment,
      targetSlot: targetSlot,
      existingAssignments: <SlotTaskAssignment>[existing],
    );

    expect(moved.slotId, 'slot-2');
    expect(moved.startAt, DateTime(2026, 4, 19, 9, 30));
    expect(moved.endAt, DateTime(2026, 4, 19, 9, 50));
  });

  test(
    'moveAssignmentToSlotPosition inserts before a task and shifts later items',
    () {
      final targetSlot = FreeTimeSlot(
        id: 'slot-2',
        dailyPlanId: 'plan-1',
        startAt: DateTime(2026, 4, 19, 9),
        endAt: DateTime(2026, 4, 19, 11),
      );
      final early = SlotTaskAssignment(
        id: 'early',
        dailyPlanId: 'plan-1',
        slotId: 'slot-2',
        taskId: 'task-1',
        taskTitle: '朝食',
        taskKind: TaskKind.mustDo,
        startAt: DateTime(2026, 4, 19, 9),
        endAt: DateTime(2026, 4, 19, 9, 30),
        sortOrder: 0,
      );
      final late = SlotTaskAssignment(
        id: 'late',
        dailyPlanId: 'plan-1',
        slotId: 'slot-2',
        taskId: 'task-2',
        taskTitle: '掃除',
        taskKind: TaskKind.mustDo,
        startAt: DateTime(2026, 4, 19, 9, 30),
        endAt: DateTime(2026, 4, 19, 10),
        sortOrder: 1,
      );
      final moved = SlotTaskAssignment(
        id: 'moved',
        dailyPlanId: 'plan-1',
        slotId: 'slot-1',
        taskId: 'task-3',
        taskTitle: '読書',
        taskKind: TaskKind.wantToDo,
        startAt: DateTime(2026, 4, 18, 21),
        endAt: DateTime(2026, 4, 18, 21, 20),
        sortOrder: 0,
      );

      final reordered = moveAssignmentToSlotPosition(
        assignment: moved,
        targetSlot: targetSlot,
        existingAssignments: <SlotTaskAssignment>[early, late],
        beforeAssignmentId: late.id,
      );

      expect(reordered.map((item) => item.id), <String>[
        'early',
        'moved',
        'late',
      ]);
      expect(reordered[1].startAt, DateTime(2026, 4, 19, 9, 30));
      expect(reordered[1].endAt, DateTime(2026, 4, 19, 9, 50));
      expect(reordered[2].startAt, DateTime(2026, 4, 19, 9, 50));
      expect(reordered[2].endAt, DateTime(2026, 4, 19, 10, 20));
    },
  );

  test('shiftDateTimeByDays keeps the time while moving the date', () {
    final shifted = shiftDateTimeByDays(DateTime(2026, 4, 18, 23, 45), 3);

    expect(shifted, DateTime(2026, 4, 21, 23, 45));
  });

  group('resolveTimelineWindow', () {
    FreeTimeSlot slot(DateTime start, DateTime end) => FreeTimeSlot(
      id: 'slot-${start.millisecondsSinceEpoch}',
      dailyPlanId: 'plan-1',
      startAt: start,
      endAt: end,
    );

    final defaultStart = DateTime(2026, 4, 18, 12);
    final defaultEnd = DateTime(2026, 4, 19, 12);

    test('keeps the default window when there are no slots', () {
      final window = resolveTimelineWindow(
        defaultStart: defaultStart,
        defaultEnd: defaultEnd,
        slots: const <FreeTimeSlot>[],
      );

      expect(window.start, defaultStart);
      expect(window.end, defaultEnd);
    });

    test('extends the start down to the hour of an earlier morning slot', () {
      final window = resolveTimelineWindow(
        defaultStart: defaultStart,
        defaultEnd: defaultEnd,
        slots: [slot(DateTime(2026, 4, 18, 9, 30), DateTime(2026, 4, 18, 11))],
      );

      expect(window.start, DateTime(2026, 4, 18, 9));
      expect(window.end, defaultEnd);
    });

    test('extends the end up to the hour after a late slot', () {
      final window = resolveTimelineWindow(
        defaultStart: defaultStart,
        defaultEnd: defaultEnd,
        slots: [slot(DateTime(2026, 4, 19, 11), DateTime(2026, 4, 19, 13, 15))],
      );

      expect(window.start, defaultStart);
      expect(window.end, DateTime(2026, 4, 19, 14));
    });

    test('does not round up an end that already sits on the hour', () {
      final window = resolveTimelineWindow(
        defaultStart: defaultStart,
        defaultEnd: defaultEnd,
        slots: [slot(DateTime(2026, 4, 19, 11), DateTime(2026, 4, 19, 13))],
      );

      expect(window.end, DateTime(2026, 4, 19, 13));
    });

    test('also covers assignments that fall outside the slot list', () {
      final window = resolveTimelineWindow(
        defaultStart: defaultStart,
        defaultEnd: defaultEnd,
        slots: const <FreeTimeSlot>[],
        assignments: [
          SlotTaskAssignment(
            id: 'a1',
            dailyPlanId: 'plan-1',
            slotId: 'slot-1',
            taskId: 'task-1',
            taskTitle: '朝の作業',
            taskKind: TaskKind.mustDo,
            startAt: DateTime(2026, 4, 18, 8, 45),
            endAt: DateTime(2026, 4, 18, 9, 30),
            sortOrder: 0,
          ),
        ],
      );

      expect(window.start, DateTime(2026, 4, 18, 8));
      expect(window.end, defaultEnd);
    });
  });

  group('nextHalfHourBoundary', () {
    test('keeps a time already on a boundary', () {
      expect(
        nextHalfHourBoundary(DateTime(2026, 4, 18, 9, 30)),
        DateTime(2026, 4, 18, 9, 30),
      );
    });

    test('rounds up to the next boundary', () {
      expect(
        nextHalfHourBoundary(DateTime(2026, 4, 18, 9, 1)),
        DateTime(2026, 4, 18, 9, 30),
      );
      expect(
        nextHalfHourBoundary(DateTime(2026, 4, 18, 9, 45)),
        DateTime(2026, 4, 18, 10),
      );
    });

    test('rounds up when only seconds have passed the boundary', () {
      expect(
        nextHalfHourBoundary(DateTime(2026, 4, 18, 9, 30, 1)),
        DateTime(2026, 4, 18, 10),
      );
    });

    test('rolls into the next day at the end of it', () {
      expect(
        nextHalfHourBoundary(DateTime(2026, 4, 18, 23, 40)),
        DateTime(2026, 4, 19),
      );
    });
  });

  group('defaultFreeSlotRange', () {
    final today = DateTime(2026, 4, 18);

    test('is one hour long from the next boundary on the day being planned', () {
      final range = defaultFreeSlotRange(DateTime(2026, 4, 18, 9, 12), today);
      expect(range.start, DateTime(2026, 4, 18, 9, 30));
      expect(range.end, DateTime(2026, 4, 18, 10, 30));
    });

    test('opens at 09:00 on any day but today', () {
      // 「次の 30 分」 is a statement about now, and now is not on the day being
      // planned: a slot at 23:30 tonight is nonsense on next Tuesday
      // (M-1).
      final range = defaultFreeSlotRange(
        DateTime(2026, 4, 18, 22, 40),
        DateTime(2026, 4, 21),
      );
      expect(range.start, DateTime(2026, 4, 21, 9));
      expect(range.end, DateTime(2026, 4, 21, 10));

      final past = defaultFreeSlotRange(
        DateTime(2026, 4, 18, 9, 12),
        DateTime(2026, 4, 10),
      );
      expect(past.start, DateTime(2026, 4, 10, 9));
      expect(past.end, DateTime(2026, 4, 10, 10));
    });

    test('stays on the day being planned at the end of it', () {
      // The boundary itself rolls into tomorrow; the dialog only reads the
      // clock times, so a start of 00:00 would silently be this morning.
      final range = defaultFreeSlotRange(DateTime(2026, 4, 18, 23, 40), today);
      expect(range.start, DateTime(2026, 4, 18, 23));
      expect(range.end, DateTime(2026, 4, 18, 23, 59));
    });

    test('gives up the full hour rather than the day when it is nearly over', () {
      final range = defaultFreeSlotRange(DateTime(2026, 4, 18, 22, 45), today);
      expect(range.start, DateTime(2026, 4, 18, 23));
      expect(range.end, DateTime(2026, 4, 18, 23, 59));
    });

    test('never starts in the past on the day being planned', () {
      for (final minute in <int>[0, 1, 29, 30, 31, 59]) {
        final now = DateTime(2026, 4, 18, 14, minute);
        final range = defaultFreeSlotRange(now, today);
        expect(range.start.isBefore(now), isFalse, reason: '\$now');
        expect(range.end.isAfter(range.start), isTrue, reason: '\$now');
      }
    });
  });

  group('followingEndMinutes', () {
    test('leaves the end alone while the start is still before it', () {
      expect(
        followingEndMinutes(
          previousStartMinutes: 9 * 60,
          previousEndMinutes: 11 * 60,
          newStartMinutes: 10 * 60,
        ),
        11 * 60,
      );
    });

    test('carries the previous length when the start passes the end', () {
      expect(
        followingEndMinutes(
          previousStartMinutes: 9 * 60,
          previousEndMinutes: 10 * 60,
          newStartMinutes: 14 * 60,
        ),
        15 * 60,
      );
    });

    test('falls back to an hour when there was no length', () {
      expect(
        followingEndMinutes(
          previousStartMinutes: 9 * 60,
          previousEndMinutes: 9 * 60,
          newStartMinutes: 20 * 60,
        ),
        21 * 60,
      );
    });

    test('may push the end into the next day', () {
      expect(
        followingEndMinutes(
          previousStartMinutes: 60,
          previousEndMinutes: 180,
          newStartMinutes: 23 * 60,
        ),
        25 * 60,
      );
    });
  });

  group('assignmentEndForEstimate', () {
    final slotEnd = DateTime(2026, 4, 18, 18);

    test('uses the task estimate', () {
      expect(
        assignmentEndForEstimate(
          start: DateTime(2026, 4, 18, 13),
          estimatedMinutes: 90,
          slotEnd: slotEnd,
        ),
        DateTime(2026, 4, 18, 14, 30),
      );
    });

    test('falls back to 30 minutes when the task has no estimate', () {
      expect(
        assignmentEndForEstimate(
          start: DateTime(2026, 4, 18, 13),
          estimatedMinutes: 0,
          slotEnd: slotEnd,
        ),
        DateTime(2026, 4, 18, 13, 30),
      );
    });

    test('never runs past the slot', () {
      expect(
        assignmentEndForEstimate(
          start: DateTime(2026, 4, 18, 17, 30),
          estimatedMinutes: 240,
          slotEnd: slotEnd,
        ),
        slotEnd,
      );
    });

    test('clamps a start that is already at or past the end of the slot', () {
      // The old guard gave up here and handed back start + estimate, an
      // assignment sitting outside the slot it belongs to (M-2).
      expect(
        assignmentEndForEstimate(
          start: slotEnd,
          estimatedMinutes: 30,
          slotEnd: slotEnd,
        ),
        slotEnd,
      );
      expect(
        assignmentEndForEstimate(
          start: DateTime(2026, 4, 18, 19),
          estimatedMinutes: 30,
          slotEnd: slotEnd,
        ),
        slotEnd,
      );
    });
  });

  group('remainingFreeMinutes', () {
    test('subtracts the assigned minutes', () {
      expect(remainingFreeMinutes(freeMinutes: 180, assignedMinutes: 45), 135);
    });

    test('clamps an over-booked day at zero', () {
      expect(remainingFreeMinutes(freeMinutes: 60, assignedMinutes: 200), 0);
    });
  });

  group('formatHoursMinutes', () {
    test('says it the way a person would', () {
      // 「0 時間 45 分」 and 「1 時間 0 分」 are what a clock says, not what a
      // reader says (I-5).
      const cases = <int, String>{
        0: '0 分',
        45: '45 分',
        60: '1 時間',
        90: '1 時間 30 分',
        150: '2 時間 30 分',
        1500: '25 時間',
        -5: '0 分',
      };
      cases.forEach((minutes, expected) {
        expect(formatHoursMinutes(minutes), expected, reason: '\$minutes');
      });
    });
  });
}
