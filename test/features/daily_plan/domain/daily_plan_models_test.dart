import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/features/daily_plan/domain/daily_plan_models.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';

void main() {
  group('durationMinutes', () {
    test('never goes negative when endAt precedes startAt', () {
      final slot = FreeTimeSlot(
        id: 'slot-1',
        dailyPlanId: 'plan-1',
        startAt: DateTime(2026, 9, 4, 10),
        endAt: DateTime(2026, 9, 4, 9),
      );
      final assignment = SlotTaskAssignment(
        id: 'assignment-1',
        dailyPlanId: 'plan-1',
        slotId: 'slot-1',
        taskId: 'task-1',
        taskTitle: '洗濯',
        taskKind: TaskKind.mustDo,
        startAt: DateTime(2026, 9, 4, 10),
        endAt: DateTime(2026, 9, 4, 9, 30),
        sortOrder: 0,
      );

      expect(slot.durationMinutes, 0);
      expect(assignment.durationMinutes, 0);
    });
  });

  group('DailyPlanStateData.decode', () {
    test('falls back to an empty state for a corrupt payload', () {
      expect(DailyPlanStateData.decode('{not json').plans, isEmpty);
      expect(DailyPlanStateData.decode('[]').slots, isEmpty);
    });

    test('skips corrupt entries and keeps the valid ones', () {
      final source = jsonEncode(<String, dynamic>{
        'plans': <dynamic>[
          <String, dynamic>{
            'id': 'plan-ok',
            'date': '2026-09-04T00:00:00.000',
            'createdAt': '2026-09-04T08:00:00.000',
            'updatedAt': '2026-09-04T08:00:00.000',
          },
          <String, dynamic>{'id': 'plan-broken', 'date': 'not-a-date'},
          'garbage',
        ],
        'slots': <dynamic>[
          <String, dynamic>{'id': 'slot-broken'},
        ],
      });

      final state = DailyPlanStateData.decode(source);

      expect(state.plans.map((item) => item.id), <String>['plan-ok']);
      expect(state.slots, isEmpty);
      expect(state.assignments, isEmpty);
    });
  });

  group('TaskMasterStateData.decode', () {
    test('falls back to the default state for a corrupt payload', () {
      final state = TaskMasterStateData.decode('}{');
      expect(state.tasks, isEmpty);
      expect(state.mustDoCategories, isNotEmpty);
    });

    test('skips corrupt tasks and keeps the valid ones', () {
      final source = jsonEncode(<String, dynamic>{
        'tasks': <dynamic>[
          <String, dynamic>{
            'id': 'task-ok',
            'title': '請求',
            'kind': 'must_do',
            'priority': 3,
            'createdAt': '2026-09-04T08:00:00.000',
            'updatedAt': '2026-09-04T08:00:00.000',
          },
          <String, dynamic>{'id': 'task-broken', 'title': '壊れた'},
        ],
        'mustDoCategories': <dynamic>[],
        'wantToDoCategories': <dynamic>[],
        'shareCategories': false,
      });

      final state = TaskMasterStateData.decode(source);

      expect(state.tasks.map((task) => task.id), <String>['task-ok']);
    });
  });

  group('state lists', () {
    test('are unmodifiable so callers cannot corrupt shared state', () {
      final state = DailyPlanStateData.initial();
      expect(
        () => state.plans.add(
          DailyPlan(
            id: 'plan-1',
            date: DateTime(2026, 9, 4),
            createdAt: DateTime(2026, 9, 4),
            updatedAt: DateTime(2026, 9, 4),
          ),
        ),
        throwsUnsupportedError,
      );
      expect(
        () => TaskMasterStateData.initial().mustDoCategories.clear(),
        throwsUnsupportedError,
      );
    });
  });
}
