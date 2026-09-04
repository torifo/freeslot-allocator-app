import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frelocator/features/daily_plan/application/daily_plan_controller.dart';
import 'package:frelocator/features/daily_plan/data/daily_plan_repository.dart';
import 'package:frelocator/features/daily_plan/application/daily_plan_logic.dart';
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

    test(
      'can duplicate only selected assignments within a chosen slot',
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
          targetDate: DateTime(2026, 4, 21),
          sourceSlotIds: const <String>['slot-source-1'],
          sourceAssignmentIds: const <String>['assignment-source-2'],
          includeAssignments: true,
        );

        final state = container.read(dailyPlanControllerProvider).requireValue;
        final targetPlan = state.planForDate(DateTime(2026, 4, 21))!;
        final targetAssignments = state.assignments
            .where((item) => item.dailyPlanId == targetPlan.id)
            .toList();

        expect(targetAssignments.map((item) => item.taskTitle), <String>['散歩']);
        expect(targetAssignments.single.startAt, DateTime(2026, 4, 21, 7, 30));
        expect(targetAssignments.single.endAt, DateTime(2026, 4, 21, 8));
      },
    );

    test(
      'rejects duplicating a slot into an overlapping target slot',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'daily_plan_state_v1': _sampleState().encode(),
        });
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await container.read(dailyPlanControllerProvider.future);
        final notifier = container.read(dailyPlanControllerProvider.notifier);

        expect(
          () => notifier.duplicatePlan(
            sourceDate: DateTime(2026, 4, 18),
            targetDate: DateTime(2026, 4, 20),
            sourceSlotIds: const <String>['slot-source-overlap'],
            includeAssignments: false,
          ),
          throwsA(isA<DailyPlanValidationException>()),
        );
      },
    );
  });

  group('upsertSlot', () {
    test('rejects overlapping slots within the same daily plan', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'daily_plan_state_v1': _sampleState().encode(),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(dailyPlanControllerProvider.future);
      final notifier = container.read(dailyPlanControllerProvider.notifier);

      expect(
        () => notifier.upsertSlot(
          FreeTimeSlot(
            id: 'slot-overlap',
            dailyPlanId: 'plan-target',
            startAt: DateTime(2026, 4, 20, 9, 30),
            endAt: DateTime(2026, 4, 20, 10, 30),
            label: '重複枠',
          ),
        ),
        throwsA(isA<DailyPlanValidationException>()),
      );
    });
  });

  group('persistence failures', () {
    test('leaves the published state unchanged when saving throws', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = ProviderContainer(
        overrides: [
          dailyPlanRepositoryProvider.overrideWithValue(
            _FailingDailyPlanRepository(_sampleState()),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(dailyPlanControllerProvider.future);
      final notifier = container.read(dailyPlanControllerProvider.notifier);
      final before = container.read(dailyPlanControllerProvider).requireValue;

      await expectLater(
        notifier.upsertSlot(
          FreeTimeSlot(
            id: 'slot-new',
            dailyPlanId: 'plan-target',
            startAt: DateTime(2026, 4, 20, 14),
            endAt: DateTime(2026, 4, 20, 15),
            label: '追加枠',
          ),
        ),
        throwsA(isA<StateError>()),
      );

      final after = container.read(dailyPlanControllerProvider).requireValue;
      expect(identical(after, before), isTrue);
      expect(after.slots.map((item) => item.id), isNot(contains('slot-new')));
    });
  });

  group('mutations before the state is ready', () {
    test('report a Japanese validation error instead of crashing', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = ProviderContainer(
        overrides: [
          dailyPlanRepositoryProvider.overrideWithValue(
            _UnloadableDailyPlanRepository(),
          ),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(dailyPlanControllerProvider.notifier);

      // While the initial load is still in flight.
      await expectLater(
        notifier.deleteSlot('slot-1'),
        throwsA(
          isA<DailyPlanValidationException>().having(
            (error) => error.message,
            'message',
            'データの読み込みが完了していません。',
          ),
        ),
      );

      await expectLater(
        container.read(dailyPlanControllerProvider.future),
        throwsA(isA<StateError>()),
      );

      // And once the load has failed.
      await expectLater(
        notifier.deleteSlot('slot-1'),
        throwsA(isA<DailyPlanValidationException>()),
      );
    });
  });
}

class _UnloadableDailyPlanRepository extends DailyPlanRepository {
  @override
  Future<DailyPlanStateData> load() async {
    throw StateError('storage unavailable');
  }
}

class _FailingDailyPlanRepository extends DailyPlanRepository {
  _FailingDailyPlanRepository(this._state);

  final DailyPlanStateData _state;

  @override
  Future<DailyPlanStateData> load() async => _state;

  @override
  Future<void> save(DailyPlanStateData state) async {
    throw StateError('storage unavailable');
  }
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
        id: 'slot-source-overlap',
        dailyPlanId: sourcePlan.id,
        startAt: DateTime(2026, 4, 18, 9, 30),
        endAt: DateTime(2026, 4, 18, 10, 30),
        label: '重複候補',
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
        slotId: 'slot-source-1',
        taskId: 'task-4',
        taskTitle: '散歩',
        taskKind: TaskKind.wantToDo,
        startAt: DateTime(2026, 4, 18, 7, 30),
        endAt: DateTime(2026, 4, 18, 8),
        sortOrder: 1,
      ),
      SlotTaskAssignment(
        id: 'assignment-source-3',
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
