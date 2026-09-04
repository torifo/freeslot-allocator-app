import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frelocator/features/task_master/application/task_master_controller.dart';
import 'package:frelocator/features/task_master/application/task_master_logic.dart';
import 'package:frelocator/features/task_master/data/task_master_repository.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reorderTasks', () {
    test(
      'renumbers priorities by visible order within the same kind',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'task_master_state_v1': _sampleState().encode(),
        });
        final container = ProviderContainer();
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
      final container = ProviderContainer(
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
      final container = ProviderContainer(
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
}

class _UnloadableTaskMasterRepository extends TaskMasterRepository {
  @override
  Future<TaskMasterStateData> load() async {
    throw StateError('storage unavailable');
  }
}

class _FailingTaskMasterRepository extends TaskMasterRepository {
  _FailingTaskMasterRepository(this._state);

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
    mustDoCategories: const <TaskCategory>[],
    wantToDoCategories: const <TaskCategory>[],
    shareCategories: false,
  );
}
