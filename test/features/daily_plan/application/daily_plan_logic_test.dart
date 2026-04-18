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
}
