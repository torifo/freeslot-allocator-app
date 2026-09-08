import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/features/daily_plan/domain/daily_plan_models.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';
import 'package:frelocator/features/weekly_report/application/weekly_report_logic.dart';

void main() {
  test('assignmentsOverlappingRange keeps items crossing the boundary', () {
    final assignments = <SlotTaskAssignment>[
      SlotTaskAssignment(
        id: 'a1',
        dailyPlanId: 'plan-1',
        slotId: 'slot-1',
        taskId: 'task-1',
        taskTitle: '深夜読書',
        taskKind: TaskKind.wantToDo,
        startAt: DateTime(2026, 4, 19, 23, 30),
        endAt: DateTime(2026, 4, 20, 0, 30),
        sortOrder: 0,
      ),
    ];

    final result = assignmentsOverlappingRange(
      assignments,
      start: DateTime(2026, 4, 20),
      end: DateTime(2026, 4, 27),
    );

    expect(result.map((item) => item.id), <String>['a1']);
  });

  test('totalAssignedMinutes counts only the overlapped duration', () {
    final assignments = <SlotTaskAssignment>[
      SlotTaskAssignment(
        id: 'a1',
        dailyPlanId: 'plan-1',
        slotId: 'slot-1',
        taskId: 'task-1',
        taskTitle: '深夜読書',
        taskKind: TaskKind.wantToDo,
        startAt: DateTime(2026, 4, 19, 23, 30),
        endAt: DateTime(2026, 4, 20, 0, 30),
        sortOrder: 0,
      ),
    ];

    final minutes = totalAssignedMinutes(
      assignments,
      start: DateTime(2026, 4, 20),
      end: DateTime(2026, 4, 27),
    );

    expect(minutes, 30);
  });

  test(
    'estimatedMinutesForAssignments sums estimates per scheduled assignment',
    () {
      final assignments = <SlotTaskAssignment>[
        SlotTaskAssignment(
          id: 'a1',
          dailyPlanId: 'plan-1',
          slotId: 'slot-1',
          taskId: 'task-1',
          taskTitle: '読書',
          taskKind: TaskKind.wantToDo,
          startAt: DateTime(2026, 4, 20, 21),
          endAt: DateTime(2026, 4, 20, 21, 30),
          sortOrder: 0,
        ),
        SlotTaskAssignment(
          id: 'a2',
          dailyPlanId: 'plan-1',
          slotId: 'slot-1',
          taskId: 'task-1',
          taskTitle: '読書',
          taskKind: TaskKind.wantToDo,
          startAt: DateTime(2026, 4, 21, 21),
          endAt: DateTime(2026, 4, 21, 21, 30),
          sortOrder: 1,
        ),
      ];
      final tasks = <TaskMaster>[
        TaskMaster(
          id: 'task-1',
          title: '読書',
          kind: TaskKind.wantToDo,
          priority: 3,
          createdAt: DateTime(2026, 4, 20, 8),
          updatedAt: DateTime(2026, 4, 20, 8),
          estimatedMinutes: 30,
        ),
      ];

      expect(estimatedMinutesForAssignments(assignments, tasks), 60);
    },
  );

  test(
    'categoryTotals prefers the latest category name from current task state',
    () {
      final assignments = <SlotTaskAssignment>[
        SlotTaskAssignment(
          id: 'a1',
          dailyPlanId: 'plan-1',
          slotId: 'slot-1',
          taskId: 'task-1',
          taskTitle: '読書',
          taskKind: TaskKind.wantToDo,
          startAt: DateTime(2026, 4, 20, 21),
          endAt: DateTime(2026, 4, 20, 21, 30),
          sortOrder: 0,
          categoryId: 'want-hobby',
          categoryName: '趣味(旧)',
        ),
      ];
      final tasks = <TaskMaster>[
        TaskMaster(
          id: 'task-1',
          title: '読書',
          kind: TaskKind.wantToDo,
          priority: 3,
          createdAt: DateTime(2026, 4, 20, 8),
          updatedAt: DateTime(2026, 4, 20, 8),
          categoryId: 'want-hobby',
        ),
      ];
      final categories = <TaskCategory>[
        TaskCategory(id: 'want-hobby', name: '趣味(新)'),
      ];

      final totals = categoryTotals(
        assignments,
        start: DateTime(2026, 4, 20),
        end: DateTime(2026, 4, 27),
        tasks: tasks,
        categories: categories,
      );

      expect(totals.keys, <String>['趣味(新)']);
      expect(totals.values, <int>[30]);
    },
  );
}
