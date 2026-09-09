import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/device_clock.dart';
import 'package:frelocator/features/daily_plan/data/daily_plan_repository.dart';
import 'package:frelocator/features/daily_plan/domain/daily_plan_models.dart';
import 'package:frelocator/features/task_master/data/task_master_repository.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';
import 'package:frelocator/services/app_data_service.dart';
import 'package:frelocator/services/storage/prefs_state_store.dart';
import 'package:frelocator/services/storage/state_store.dart';
import 'package:frelocator/services/sync/conflict_record.dart';
import 'package:frelocator/services/sync/sync_document.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A store that lets the daily-plan half of a write fail on demand, which is
/// the failure an import must survive without leaving half of itself behind.
class _FlakyStore extends StateStore {
  _FlakyStore(this.inner);

  final StateStore inner;
  bool failPlans = false;

  @override
  Future<TaskMasterStateData> readTaskMaster() => inner.readTaskMaster();

  @override
  Future<void> writeTaskMaster(TaskMasterStateData state) => inner.writeTaskMaster(state);

  @override
  Future<DailyPlanStateData> readDailyPlan() => inner.readDailyPlan();

  @override
  Future<void> writeDailyPlan(DailyPlanStateData state) async {
    if (failPlans) throw StateError('disk full');
    return inner.writeDailyPlan(state);
  }

  // Delegated rather than left to the base class: `StateStore.writeConflicts`
  // refuses by default, so a store that swallowed the records would be caught
  // here instead of silently dropping them.
  @override
  Future<List<ConflictRecord>> readConflicts() => inner.readConflicts();

  @override
  Future<void> writeConflicts(List<ConflictRecord> conflicts) =>
      inner.writeConflicts(conflicts);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> task(String id) => <String, dynamic>{
    'id': id,
    'title': id,
    'kind': 'must_do',
    'priority': 3,
    'createdAt': '2026-01-01T00:00:00.000Z',
    'updatedAt': '2026-01-01T00:00:00.000Z',
    'memo': '',
    'categoryId': null,
    'estimatedMinutes': 0,
    'clock': '1000-0-me',
    'deletedAt': null,
    'migrated': false,
  };

  Future<({AppDataService data, _FlakyStore store})> make() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final store = _FlakyStore(PrefsStateStore());
    final clock = await DeviceClock.load(platformPrefix: 'test', now: () => 1000);
    return (
      data: AppDataService(
        taskRepo: TaskMasterRepository(store),
        dailyPlanRepo: DailyPlanRepository(store),
        store: store,
        deviceClock: clock,
      ),
      store: store,
    );
  }

  test('importDocument lands tasks and plans together', () async {
    final made = await make();
    final base = await made.data.exportDocument();
    await made.data.importDocument(
      base.copyWith(
        taskMaster: base.taskMaster.copyWith(
          tasks: [TaskMaster.fromJson(task('kept'))],
        ),
      ),
    );
    expect((await made.data.taskRepo.load()).tasks.single.id, 'kept');
  });

  test('a failure saving the plans leaves the tasks exactly as they were', () async {
    final made = await make();
    final base = await made.data.exportDocument();
    await made.data.importDocument(
      base.copyWith(
        taskMaster: base.taskMaster.copyWith(
          tasks: [TaskMaster.fromJson(task('original'))],
        ),
      ),
    );

    made.store.failPlans = true;
    final doomed = base.copyWith(
      taskMaster: base.taskMaster.copyWith(
        tasks: [TaskMaster.fromJson(task('half-applied'))],
      ),
    );
    await expectLater(made.data.importDocument(doomed), throwsA(isA<StateError>()));

    expect(
      (await made.data.taskRepo.load()).tasks.single.id,
      'original',
      reason: 'a half-applied import would leave plans pointing at tasks that '
          'were never written',
    );
  });

  test('exportAll round-trips through importDocument', () async {
    final made = await make();
    final base = await made.data.exportDocument();
    await made.data.importDocument(
      base.copyWith(
        taskMaster: base.taskMaster.copyWith(tasks: [TaskMaster.fromJson(task('a'))]),
      ),
    );
    final snapshot = await made.data.exportAll();
    await made.data.importDocument(
      base.copyWith(
        taskMaster: base.taskMaster.copyWith(tasks: [TaskMaster.fromJson(task('b'))]),
      ),
    );
    expect((await made.data.taskRepo.load()).tasks.single.id, 'b');
    await made.data.importDocument(SyncDocument.fromJson(snapshot, strict: true));
    expect((await made.data.taskRepo.load()).tasks.single.id, 'a');
  });
}
