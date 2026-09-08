import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/hlc.dart';
import 'package:frelocator/features/task_master/application/task_master_controller.dart';
import 'package:frelocator/features/task_master/application/task_master_logic.dart';
import 'package:frelocator/features/task_master/data/task_master_repository.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';
import 'package:frelocator/services/storage/prefs_state_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/test_container.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reorderTasks', () {
    test(
      'renumbers priorities by visible order within the same kind',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'task_master_state_v1': _sampleState().encode(),
        });
        final container = await testContainer();
        addTearDown(container.dispose);

        await container.read(taskMasterControllerProvider.future);
        final notifier = container.read(taskMasterControllerProvider.notifier);

        await notifier.reorderTasks(
          kind: TaskKind.mustDo,
          orderedIds: const <String>['must-2', 'must-1', 'must-3'],
        );

        final state = container.read(taskMasterControllerProvider).requireValue;
        final mustDoTasks = state.tasks
            .where((task) => task.kind == TaskKind.mustDo)
            .toList();

        expect(mustDoTasks.map((task) => task.id), <String>[
          'must-2',
          'must-1',
          'must-3',
        ]);
        expect(mustDoTasks.map((task) => task.priority), <int>[3, 2, 1]);
        expect(state.tasks.first.kind, TaskKind.mustDo);
        expect(state.tasks.last.kind, TaskKind.wantToDo);
      },
    );
  });

  group('persistence failures', () {
    test('leaves the published state unchanged when saving throws', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = await testContainer(
        overrides: [
          taskMasterRepositoryProvider.overrideWithValue(
            _FailingTaskMasterRepository(_sampleState()),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(taskMasterControllerProvider.future);
      final notifier = container.read(taskMasterControllerProvider.notifier);
      final before = container.read(taskMasterControllerProvider).requireValue;

      await expectLater(
        notifier.deleteTask('must-1'),
        throwsA(isA<StateError>()),
      );

      final after = container.read(taskMasterControllerProvider).requireValue;
      expect(identical(after, before), isTrue);
      expect(after.tasks.map((task) => task.id), contains('must-1'));
    });
  });

  group('mutations before the state is ready', () {
    test('report a Japanese validation error instead of crashing', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = await testContainer(
        overrides: [
          taskMasterRepositoryProvider.overrideWithValue(
            _UnloadableTaskMasterRepository(),
          ),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(taskMasterControllerProvider.notifier);

      // While the initial load is still in flight.
      await expectLater(
        notifier.deleteTask('must-1'),
        throwsA(
          isA<TaskMasterValidationException>().having(
            (error) => error.message,
            'message',
            'データの読み込みが完了していません。',
          ),
        ),
      );

      await expectLater(
        container.read(taskMasterControllerProvider.future),
        throwsA(isA<StateError>()),
      );

      // And once the load has failed.
      await expectLater(
        notifier.deleteTask('must-1'),
        throwsA(isA<TaskMasterValidationException>()),
      );
    });
  });


  group('tombstone / live id coexistence', () {
    test('re-adding a deleted task drops its tombstone', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'task_master_state_v1': _sampleState().encode(),
      });
      final container = await testContainer(now: () => 1000);
      addTearDown(container.dispose);
      await container.read(taskMasterControllerProvider.future);
      final notifier = container.read(taskMasterControllerProvider.notifier);

      await notifier.deleteTask('must-1');
      await notifier.addOrUpdateTask(
        TaskMaster(
          id: 'must-1',
          title: '請求(再登録)',
          kind: TaskKind.mustDo,
          priority: 3,
          createdAt: DateTime(2026, 5, 1, 10),
          updatedAt: DateTime(2026, 5, 1, 10),
        ),
      );

      final state = container.read(taskMasterControllerProvider).requireValue;
      expect(state.deletedTasks, isEmpty);
      expect(state.tasks.where((t) => t.id == 'must-1'), hasLength(1));
      expect(
        (state.toJson()['tasks'] as List)
            .where((dynamic item) => (item as Map)['id'] == 'must-1'),
        hasLength(1),
      );
    });

    test('re-adding a deleted category drops its tombstone', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'task_master_state_v1': _sampleState().encode(),
      });
      final container = await testContainer(now: () => 1000);
      addTearDown(container.dispose);
      await container.read(taskMasterControllerProvider.future);
      final notifier = container.read(taskMasterControllerProvider.notifier);

      await notifier.deleteCategory(
        kind: TaskKind.mustDo,
        categoryId: 'must-work',
      );
      await notifier.upsertCategory(
        kind: TaskKind.mustDo,
        category: TaskCategory(id: 'must-work', name: '仕事'),
      );

      final state = container.read(taskMasterControllerProvider).requireValue;
      expect(state.deletedMustDoCategories, isEmpty);
      expect(state.mustDoCategories.map((c) => c.id), contains('must-work'));
    });
  });

  group('serialized mutations', () {
    test('concurrent addOrUpdateTask calls do not lose updates', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = await testContainer(now: () => 1000);
      addTearDown(container.dispose);
      await container.read(taskMasterControllerProvider.future);
      final notifier = container.read(taskMasterControllerProvider.notifier);

      TaskMaster build(String id) => TaskMaster(
        id: id,
        title: id,
        kind: TaskKind.mustDo,
        priority: 3,
        createdAt: DateTime(2026, 5, 1, 10),
        updatedAt: DateTime(2026, 5, 1, 10),
      );

      final a = notifier.addOrUpdateTask(build('a'));
      final b = notifier.addOrUpdateTask(build('b'));
      await Future.wait(<Future<void>>[a, b]);

      final state = container.read(taskMasterControllerProvider).requireValue;
      expect(state.tasks.map((t) => t.id), containsAll(<String>['a', 'b']));
    });
  });

  group('tombstones', () {
    test('deleteTask moves the task into deletedTasks with a newer clock', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'task_master_state_v1': _sampleState().encode(),
      });
      final container = await testContainer(now: () => 1000);
      addTearDown(container.dispose);
      await container.read(taskMasterControllerProvider.future);
      final notifier = container.read(taskMasterControllerProvider.notifier);

      await notifier.deleteTask('must-1');

      final state = container.read(taskMasterControllerProvider).requireValue;
      expect(state.tasks.any((t) => t.id == 'must-1'), isFalse);
      expect(state.deletedTasks.single.id, 'must-1');
      expect(state.deletedTasks.single.meta.isDeleted, isTrue);
      expect(state.deletedTasks.single.meta.clock.deviceId, startsWith('test-'));
    });

    test('addOrUpdateTask stamps a fresh clock from the device', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = await testContainer(now: () => 1000);
      addTearDown(container.dispose);
      await container.read(taskMasterControllerProvider.future);
      final notifier = container.read(taskMasterControllerProvider.notifier);

      await notifier.addOrUpdateTask(
        TaskMaster(
          id: 'new',
          title: 'x',
          kind: TaskKind.mustDo,
          priority: 3,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      final task = container
          .read(taskMasterControllerProvider)
          .requireValue
          .tasks
          .singleWhere((t) => t.id == 'new');
      expect(task.meta.migrated, isFalse);
      expect(task.meta.clock.physical, 1000);
    });

    test('mutation chain survives a validation failure', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'task_master_state_v1': _sampleState().encode(),
      });
      final container = await testContainer(now: () => 1000);
      addTearDown(container.dispose);
      await container.read(taskMasterControllerProvider.future);
      final notifier = container.read(taskMasterControllerProvider.notifier);

      // Duplicate name: the mutation body throws after being queued.
      await expectLater(
        notifier.upsertCategory(
          kind: TaskKind.mustDo,
          category: TaskCategory(id: 'must-other', name: '仕事'),
        ),
        throwsA(isA<TaskMasterValidationException>()),
      );

      await notifier.upsertCategory(
        kind: TaskKind.mustDo,
        category: TaskCategory(id: 'must-admin', name: '雑務'),
      );

      final state = container.read(taskMasterControllerProvider).requireValue;
      expect(state.mustDoCategories.map((c) => c.id), contains('must-admin'));
      expect(state.mustDoCategories.map((c) => c.id), isNot(contains('must-other')));
    });

    test('turning sharing off tombstones want-to-do categories the must-do list drops', () async {
      // Sharing is on but the lists diverged (e.g. a peer added a category to
      // only one of them); mirroring must not silently swallow the extra.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'task_master_state_v1': TaskMasterStateData(
          tasks: const <TaskMaster>[],
          mustDoCategories: <TaskCategory>[
            TaskCategory(id: 'shared-work', name: '仕事'),
          ],
          wantToDoCategories: <TaskCategory>[
            TaskCategory(id: 'shared-work', name: '仕事'),
            TaskCategory(id: 'want-only', name: '趣味'),
          ],
          shareCategories: true,
        ).encode(),
      });
      final container = await testContainer(now: () => 1000);
      addTearDown(container.dispose);
      await container.read(taskMasterControllerProvider.future);

      await container
          .read(taskMasterControllerProvider.notifier)
          .setShareCategories(enabled: false);

      final state = container.read(taskMasterControllerProvider).requireValue;
      expect(state.wantToDoCategories.map((c) => c.id), <String>['shared-work']);
      final tombstone = state.deletedWantToDoCategories.singleWhere(
        (item) => item.id == 'want-only',
      );
      expect(tombstone.meta.isDeleted, isTrue);
      expect(tombstone.meta.clock, isNot(Hlc.migrated));
    });

    test('enabling shared categories stamps the dropped category tombstone', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'task_master_state_v1': _shareableState().encode(),
      });
      final container = await testContainer(now: () => 1000);
      addTearDown(container.dispose);
      await container.read(taskMasterControllerProvider.future);
      final notifier = container.read(taskMasterControllerProvider.notifier);

      await notifier.setShareCategories(
        enabled: true,
        strategy: CategoryMergeStrategy.keepMustDo,
      );

      final state = container.read(taskMasterControllerProvider).requireValue;
      final tombstone = state.deletedWantToDoCategories.singleWhere(
        (item) => item.id == 'want-hobby',
      );
      expect(tombstone.meta.isDeleted, isTrue);
      expect(tombstone.meta.clock, isNot(Hlc.migrated));
      expect(tombstone.meta.clock.deviceId, startsWith('test-'));
    });

    test('deleteCategory tombstones the category and detaches tasks with a new clock', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'task_master_state_v1': _sampleState().encode(),
      });
      final container = await testContainer(now: () => 1000);
      addTearDown(container.dispose);
      await container.read(taskMasterControllerProvider.future);
      await container
          .read(taskMasterControllerProvider.notifier)
          .deleteCategory(kind: TaskKind.mustDo, categoryId: 'must-work');
      final state = container.read(taskMasterControllerProvider).requireValue;
      expect(state.mustDoCategories.any((c) => c.id == 'must-work'), isFalse);
      expect(state.deletedMustDoCategories.single.id, 'must-work');
    });
  });
}

class _UnloadableTaskMasterRepository extends TaskMasterRepository {
  _UnloadableTaskMasterRepository() : super(PrefsStateStore());

  @override
  Future<TaskMasterStateData> load() async {
    throw StateError('storage unavailable');
  }
}

class _FailingTaskMasterRepository extends TaskMasterRepository {
  _FailingTaskMasterRepository(this._state) : super(PrefsStateStore());

  final TaskMasterStateData _state;

  @override
  Future<TaskMasterStateData> load() async => _state;

  @override
  Future<void> save(TaskMasterStateData state) async {
    throw StateError('storage unavailable');
  }
}

TaskMasterStateData _sampleState() {
  final now = DateTime(2026, 5, 1, 10);
  return TaskMasterStateData(
    tasks: <TaskMaster>[
      TaskMaster(
        id: 'must-1',
        title: '請求',
        kind: TaskKind.mustDo,
        priority: 3,
        createdAt: now,
        updatedAt: now,
      ),
      TaskMaster(
        id: 'must-2',
        title: '洗濯',
        kind: TaskKind.mustDo,
        priority: 2,
        createdAt: now,
        updatedAt: now,
      ),
      TaskMaster(
        id: 'must-3',
        title: '返信',
        kind: TaskKind.mustDo,
        priority: 1,
        createdAt: now,
        updatedAt: now,
      ),
      TaskMaster(
        id: 'want-1',
        title: '読書',
        kind: TaskKind.wantToDo,
        priority: 5,
        createdAt: now,
        updatedAt: now,
      ),
    ],
    mustDoCategories: <TaskCategory>[
      TaskCategory(id: 'must-work', name: '仕事'),
    ],
    wantToDoCategories: const <TaskCategory>[],
    shareCategories: false,
  );
}

TaskMasterStateData _shareableState() {
  return TaskMasterStateData(
    tasks: const <TaskMaster>[],
    mustDoCategories: <TaskCategory>[TaskCategory(id: 'must-work', name: '仕事')],
    wantToDoCategories: <TaskCategory>[TaskCategory(id: 'want-hobby', name: '趣味')],
    shareCategories: false,
  );
}
