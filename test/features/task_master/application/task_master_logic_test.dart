import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/hlc.dart';
import 'package:frelocator/features/task_master/application/task_master_logic.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';

void main() {
  group('mergeCategories', () {
    final mustDoCategories = <TaskCategory>[
      TaskCategory(id: 'm1', name: '仕事'),
      TaskCategory(id: 'm2', name: '家事'),
    ];
    final wantToDoCategories = <TaskCategory>[
      TaskCategory(id: 'w1', name: '趣味'),
    ];

    test('keeps shorter list', () {
      final result = mergeCategories(
        mustDoCategories: mustDoCategories,
        wantToDoCategories: wantToDoCategories,
        strategy: CategoryMergeStrategy.keepShorter,
      );

      expect(result.map((category) => category.id), <String>['w1']);
    });

    test('keeps must-do list', () {
      final result = mergeCategories(
        mustDoCategories: mustDoCategories,
        wantToDoCategories: wantToDoCategories,
        strategy: CategoryMergeStrategy.keepMustDo,
      );

      expect(result.map((category) => category.id), <String>['m1', 'm2']);
    });
  });

  test('deleting a category clears task references', () {
    final state = TaskMasterStateData.initial().copyWith(
      tasks: <TaskMaster>[
        TaskMaster(
          id: 't1',
          title: '洗濯',
          kind: TaskKind.mustDo,
          priority: 3,
          createdAt: DateTime(2026, 4, 18),
          updatedAt: DateTime(2026, 4, 18),
          categoryId: 'must-housework',
        ),
      ],
    );

    final result = deleteCategoryFromState(
      state,
      kind: TaskKind.mustDo,
      categoryId: 'must-housework',
      clock: Hlc.parse('1-0-test'),
      now: DateTime.utc(2026),
    );

    expect(result.tasks.single.categoryId, isNull);
    expect(
      result.mustDoCategories.any(
        (category) => category.id == 'must-housework',
      ),
      isFalse,
    );
  });

  test('duplicate category names are rejected', () {
    expect(
      () => validateCategoryNameUniqueness(
        category: TaskCategory(id: 'want-hobby-2', name: '趣味'),
        categories: <TaskCategory>[
          TaskCategory(id: 'want-hobby', name: '趣味'),
        ],
      ),
      throwsA(isA<TaskMasterValidationException>()),
    );
  });
}
