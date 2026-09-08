import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/hlc.dart';
import 'package:frelocator/core/sync_meta.dart';
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

  group('enableSharedCategories', () {
    TaskMasterStateData sample() {
      final now = DateTime(2026, 4, 18);
      return TaskMasterStateData.initial().copyWith(
        tasks: <TaskMaster>[
          TaskMaster(
            id: 't-want',
            title: 'ギター',
            kind: TaskKind.wantToDo,
            priority: 3,
            createdAt: now,
            updatedAt: now,
            categoryId: 'want-hobby',
            meta: SyncMeta.stamp(Hlc.parse('1-0-dev'), DateTime.utc(2026)),
          ),
          TaskMaster(
            id: 't-must',
            title: '請求',
            kind: TaskKind.mustDo,
            priority: 3,
            createdAt: now,
            updatedAt: now,
            categoryId: 'must-work',
            meta: SyncMeta.stamp(Hlc.parse('1-0-dev'), DateTime.utc(2026)),
          ),
        ],
      );
    }

    test('tombstones discarded categories and touches only remapped tasks', () {
      final before = sample();
      final result = enableSharedCategories(
        before,
        CategoryMergeStrategy.keepMustDo,
        clock: Hlc.parse('9-0-dev'),
        now: DateTime.utc(2026, 9, 8),
      );

      expect(
        result.deletedWantToDoCategories.map((item) => item.id),
        contains('want-hobby'),
      );
      expect(
        result.deletedWantToDoCategories.every((item) => item.meta.isDeleted),
        isTrue,
      );
      expect(
        result.wantToDoCategories.map((c) => c.id),
        result.mustDoCategories.map((c) => c.id),
      );

      final want = result.tasks.singleWhere((t) => t.id == 't-want');
      final must = result.tasks.singleWhere((t) => t.id == 't-must');
      expect(want.categoryId, isNull);
      expect(want.meta.clock.compareTo(Hlc.parse('1-0-dev')), greaterThan(0));
      expect(must.meta.clock, Hlc.parse('1-0-dev'));

      // Newly mirrored categories are stamped on the list they join.
      expect(
        result.wantToDoCategories
            .every((c) => c.meta.clock == Hlc.parse('9-0-dev')),
        isTrue,
      );
      expect(
        result.mustDoCategories.every((c) => c.meta.clock == Hlc.migrated),
        isTrue,
      );
    });
  });
}
