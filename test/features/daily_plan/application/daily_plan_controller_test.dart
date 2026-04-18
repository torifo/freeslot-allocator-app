import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frelocator/features/daily_plan/application/daily_plan_controller.dart';
import 'package:frelocator/features/daily_plan/domain/daily_plan_models.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('duplicatePlan', () {
    test(
      'can append only selected slots without copying assignments',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'daily_plan_state_v1': _sampleState().encode(),
        });
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await container.read(dailyPlanControllerProvider.future);
        final notifier = container.read(dailyPlanControllerProvider.notifier);

        await notifier.duplicatePlan(
          sourceDate: DateTime(2026, 4, 18),
          targetDate: DateTime(2026, 4, 20),
          sourceSlotIds: const <String>['slot-source-1'],
          includeAssignments: false,
        );

        final state = container.read(dailyPlanControllerProvider).requireValue;
        final targetPlan = state.planForDate(DateTime(2026, 4, 20))!;
        final targetSlots = state.slotsForPlan(targetPlan.id);
        final targetAssignments = state.assignments
            .where((item) => item.dailyPlanId == targetPlan.id)
            .toList();

        expect(
          targetSlots.map((item) => item.label),
          containsAll(<String>['既存枠', '朝活']),
        );
        expect(targetSlots.length, 2);
        expect(targetAssignments.map((item) => item.taskTitle), <String>[
          '既存予定',
        ]);
      },
    );

    test(
      'can replace existing plan with selected slots and assignments',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'daily_plan_state_v1': _sampleState().encode(),
        });
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await container.read(dailyPlanControllerProvider.future);
        final notifier = container.read(dailyPlanControllerProvider.notifier);

        await notifier.duplicatePlan(
          sourceDate: DateTime(2026, 4, 18),
          targetDate: DateTime(2026, 4, 20),
          sourceSlotIds: const <String>['slot-source-2'],
          includeAssignments: true,
          replaceExisting: true,
        );

        final state = container.read(dailyPlanControllerProvider).requireValue;
        final targetPlan = state.planForDate(DateTime(2026, 4, 20))!;
        final targetSlots = state.slotsForPlan(targetPlan.id);
        final targetAssignments = state.assignments
            .where((item) => item.dailyPlanId == targetPlan.id)
            .toList();

        expect(targetSlots.map((item) => item.label), <String>['夜']);
        expect(targetAssignments.map((item) => item.taskTitle), <String>['読書']);
        expect(targetAssignments.single.startAt, DateTime(2026, 4, 20, 20));
      },
    );
  });
}

DailyPlanStateData _sampleState() {
  final sourcePlan = DailyPlan(
    id: 'plan-source',
    date: DateTime(2026, 4, 18),
    createdAt: DateTime(2026, 4, 18, 8),
    updatedAt: DateTime(2026, 4, 18, 8),
  );
  final targetPlan = DailyPlan(
    id: 'plan-target',
    date: DateTime(2026, 4, 20),
    createdAt: DateTime(2026, 4, 20, 8),
    updatedAt: DateTime(2026, 4, 20, 8),
  );

  return DailyPlanStateData(
    plans: <DailyPlan>[sourcePlan, targetPlan],
    slots: <FreeTimeSlot>[
      FreeTimeSlot(
        id: 'slot-source-1',
        dailyPlanId: sourcePlan.id,
        startAt: DateTime(2026, 4, 18, 7),
        endAt: DateTime(2026, 4, 18, 8),
        label: '朝活',
      ),
      FreeTimeSlot(
        id: 'slot-source-2',
        dailyPlanId: sourcePlan.id,
        startAt: DateTime(2026, 4, 18, 20),
        endAt: DateTime(2026, 4, 18, 21),
        label: '夜',
      ),
      FreeTimeSlot(
        id: 'slot-target-1',
        dailyPlanId: targetPlan.id,
        startAt: DateTime(2026, 4, 20, 9),
        endAt: DateTime(2026, 4, 20, 10),
        label: '既存枠',
      ),
    ],
    assignments: <SlotTaskAssignment>[
      SlotTaskAssignment(
        id: 'assignment-source-1',
        dailyPlanId: sourcePlan.id,
        slotId: 'slot-source-1',
        taskId: 'task-1',
        taskTitle: '洗濯',
        taskKind: TaskKind.mustDo,
        startAt: DateTime(2026, 4, 18, 7),
        endAt: DateTime(2026, 4, 18, 7, 30),
        sortOrder: 0,
      ),
      SlotTaskAssignment(
        id: 'assignment-source-2',
        dailyPlanId: sourcePlan.id,
        slotId: 'slot-source-2',
        taskId: 'task-2',
        taskTitle: '読書',
        taskKind: TaskKind.wantToDo,
        startAt: DateTime(2026, 4, 18, 20),
        endAt: DateTime(2026, 4, 18, 20, 30),
        sortOrder: 0,
      ),
      SlotTaskAssignment(
        id: 'assignment-target-1',
        dailyPlanId: targetPlan.id,
        slotId: 'slot-target-1',
        taskId: 'task-3',
        taskTitle: '既存予定',
        taskKind: TaskKind.mustDo,
        startAt: DateTime(2026, 4, 20, 9),
        endAt: DateTime(2026, 4, 20, 9, 30),
        sortOrder: 0,
      ),
    ],
  );
}
