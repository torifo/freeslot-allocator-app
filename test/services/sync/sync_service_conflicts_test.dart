import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/device_clock.dart';
import 'package:frelocator/features/daily_plan/data/daily_plan_repository.dart';
import 'package:frelocator/features/task_master/data/task_master_repository.dart';
import 'package:frelocator/services/app_data_service.dart';
import 'package:frelocator/features/daily_plan/domain/daily_plan_models.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';
import 'package:frelocator/services/storage/prefs_state_store.dart';
import 'package:frelocator/services/storage/state_store.dart';
import 'package:frelocator/services/sync/conflict_record.dart';
import 'package:frelocator/services/sync/conflict_resolver.dart';
import 'package:frelocator/services/sync/sync_document.dart';
import 'package:frelocator/services/sync/lan_sync_client.dart';
import 'package:frelocator/services/sync/sync_progress.dart';
import 'package:frelocator/services/sync/sync_service.dart';
import 'package:frelocator/services/sync/sync_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnusedClient extends LanSyncClient {
  _UnusedClient() : super(allowInsecureForTest: true);

  @override
  Future<SyncResponse> sync(
    SyncSettings s,
    Map<String, dynamic> document, {
    String mode = 'merge',
    SyncProgressController? progress,
  }) async => throw StateError('unused');
}

Map<String, dynamic> _task(String title, String clock, String updatedAt) => <String, dynamic>{
  'id': 'tsk-1', 'title': title, 'kind': 'must_do', 'priority': 3,
  'createdAt': '2026-01-01T00:00:00.000Z', 'updatedAt': updatedAt, 'memo': '',
  'categoryId': null, 'estimatedMinutes': 0, 'clock': clock,
  'deletedAt': null, 'migrated': false,
};

/// A store where an edit has landed since the caller last read: the plain read
/// path does not see it, [updateDocument] does.
///
/// That is the window a resolution used to be decided in — export the document,
/// transform it, import it back — and anything that landed inside it was
/// overwritten by a document that had never seen it. The real stores close the
/// window for real (`FileBackedStore` under its cross-process lock,
/// `HubBackedStore` inside the snapshot it is about to push); this one makes the
/// window observable.
class _RacingStore extends StateStore {
  _RacingStore(this._inner);

  final StateStore _inner;

  /// Applied once, to the document [updateDocument] hands the caller.
  SyncDocument Function(SyncDocument)? landed;

  @override
  Future<TaskMasterStateData> readTaskMaster() => _inner.readTaskMaster();

  @override
  Future<void> writeTaskMaster(TaskMasterStateData state) =>
      _inner.writeTaskMaster(state);

  @override
  Future<DailyPlanStateData> readDailyPlan() => _inner.readDailyPlan();

  @override
  Future<void> writeDailyPlan(DailyPlanStateData state) =>
      _inner.writeDailyPlan(state);

  @override
  Future<List<ConflictRecord>> readConflicts() => _inner.readConflicts();

  @override
  Future<void> writeConflicts(List<ConflictRecord> conflicts) =>
      _inner.writeConflicts(conflicts);

  @override
  Future<void> writeAll(
    TaskMasterStateData tasks,
    DailyPlanStateData plans, {
    List<ConflictRecord>? conflicts,
  }) => _inner.writeAll(tasks, plans, conflicts: conflicts);

  @override
  Future<SyncDocument> updateDocument(
    FutureOr<SyncDocument?> Function(SyncDocument document) fn,
  ) => _inner.updateDocument((document) {
    final change = landed;
    landed = null;
    return fn(change == null ? document : change(document));
  });
}

Map<String, dynamic> _record() {
  final winner = _task('PC の版', '3000-0-hub-0000', '2026-02-01T00:00:00.000Z');
  final loser = _task('スマホの版', '2000-0-android-1', '2026-02-01T00:00:00.000Z');
  return <String, dynamic>{
    'id': conflictId('tsk-1', '3000-0-hub-0000', '2000-0-android-1'),
    'entityType': 'task',
    'entityId': 'tsk-1',
    'detectedAt': '2026-02-02T00:00:00.000Z',
    'detectedBy': 'android-1',
    'winner': <String, dynamic>{
      'side': 'hub', 'deviceId': 'hub-0000', 'clock': winner['clock'],
      'updatedAt': winner['updatedAt'], 'snapshot': winner,
    },
    'loser': <String, dynamic>{
      'side': 'device', 'deviceId': 'android-1', 'clock': loser['clock'],
      'updatedAt': loser['updatedAt'], 'snapshot': loser,
    },
    'resolution': null, 'resolvedAt': null, 'resolvedBy': null,
    'clock': winner['clock'], 'updatedAt': '2026-02-02T00:00:00.000Z',
    'deletedAt': null, 'migrated': false,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SyncService> make({DateTime? lastSyncAt}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final store = PrefsStateStore();
    final clock = await DeviceClock.load(platformPrefix: 'test', now: () => 1000);
    final data = AppDataService(
      taskRepo: TaskMasterRepository(store),
      dailyPlanRepo: DailyPlanRepository(store),
      store: store,
      deviceClock: clock,
    );
    final settingsStore = SyncSettingsStore();
    await settingsStore.save(
      SyncSettings(
        host: 'h', port: 1, fingerprint: 'AB' * 32, token: 't', hubDeviceId: 'hub',
        lastSyncAt: lastSyncAt,
      ),
    );
    return SyncService(
      client: _UnusedClient(),
      data: data,
      settingsStore: settingsStore,
      deviceClock: clock,
      discover: () async => null,
    );
  }

  test('SyncSummary carries conflicts and defaults it to zero from the wire', () {
    const summary = SyncSummary(added: 0, updated: 0, deleted: 0, warnings: 0);
    expect(summary.conflicts, 0);
    expect(
      SyncSummary.fromJson(<String, dynamic>{'added': 1, 'conflicts': 3}).conflicts,
      3,
    );
    // A hub that predates Plan 3b sends no `conflicts` key at all.
    expect(SyncSummary.fromJson(<String, dynamic>{'added': 1}).conflicts, 0);
  });

  test('applyReceived counts the conflicts it detected and shows them on the progress', () async {
    final service = await make(lastSyncAt: DateTime.utc(2026, 1, 1));
    final local = await service.data.exportDocument();
    final localJson = local.toJson();
    (localJson['taskMaster'] as Map<String, dynamic>)['tasks'] = <Map<String, dynamic>>[
      _task('local edit', '3000-0-local', '2026-02-01T00:00:00.000Z'),
    ];
    await service.data.importAll(localJson);

    final incoming = local.toJson();
    (incoming['taskMaster'] as Map<String, dynamic>)['tasks'] = <Map<String, dynamic>>[
      _task('other edit', '2000-0-other', '2026-02-02T00:00:00.000Z'),
    ];

    final progress = SyncProgressController();
    progress.start(SyncKind.qr);
    final applied = await service.applyReceived(incoming, progress: progress) as SyncApplied;
    expect(applied.summary.conflicts, 1);
    expect(progress.value.summary?.conflicts, 1);
    // Detection never blocks the apply: the HLC winner is still stored.
    expect((await service.data.taskRepo.load()).tasks.single.title, 'local edit');
  });

  test('applyReceived detects nothing before the first successful sync', () async {
    final service = await make();
    final local = await service.data.exportDocument();
    final localJson = local.toJson();
    (localJson['taskMaster'] as Map<String, dynamic>)['tasks'] = <Map<String, dynamic>>[
      _task('local edit', '3000-0-local', '2026-02-01T00:00:00.000Z'),
    ];
    await service.data.importAll(localJson);

    final incoming = local.toJson();
    (incoming['taskMaster'] as Map<String, dynamic>)['tasks'] = <Map<String, dynamic>>[
      _task('other edit', '2000-0-other', '2026-02-02T00:00:00.000Z'),
    ];
    final applied = await service.applyReceived(incoming) as SyncApplied;
    expect(applied.summary.conflicts, 0);
  });

  test('a write landing between the read and the write of a resolution survives', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final store = _RacingStore(PrefsStateStore());
    final clock = await DeviceClock.load(platformPrefix: 'test', now: () => 1000);
    final data = AppDataService(
      taskRepo: TaskMasterRepository(store),
      dailyPlanRepo: DailyPlanRepository(store),
      store: store,
      deviceClock: clock,
    );
    final settingsStore = SyncSettingsStore();
    await settingsStore.save(
      SyncSettings(host: 'h', port: 1, fingerprint: 'AB' * 32, token: 't', hubDeviceId: 'hub'),
    );
    final service = SyncService(
      client: _UnusedClient(),
      data: data,
      settingsStore: settingsStore,
      deviceClock: clock,
      discover: () async => null,
    );

    final base = await data.exportDocument();
    final json = base.toJson();
    (json['taskMaster'] as Map<String, dynamic>)['tasks'] = <Map<String, dynamic>>[
      _task('PC の版', '3000-0-hub-0000', '2026-02-01T00:00:00.000Z'),
    ];
    json['conflicts'] = <Map<String, dynamic>>[_record()];
    await data.importAll(json);

    // The edit that lands in the window: another task, written by whoever else
    // holds this document — MCP on the hub's file, another tab, a repository
    // save on the phone.
    store.landed = (document) => document.copyWith(
      taskMaster: document.taskMaster.copyWith(
        tasks: <TaskMaster>[
          ...document.taskMaster.tasks,
          TaskMaster.fromJson(_task('その間に入った版', '2500-0-other', '2026-02-01T12:00:00.000Z')
            ..['id'] = 'tsk-2'),
        ],
      ),
    );

    final id = conflictId('tsk-1', '3000-0-hub-0000', '2000-0-android-1');
    await service.resolveConflict(id, ConflictAdoption.device);

    final stored = await store.readTaskMaster();
    expect(
      stored.tasks.map((t) => t.id).toSet(),
      <String>{'tsk-1', 'tsk-2'},
      reason: 'the resolution was decided on a document that never saw tsk-2',
    );
    expect(stored.tasks.firstWhere((t) => t.id == 'tsk-1').title, 'スマホの版');
    expect((await store.readConflicts()).single.resolution, 'device');
  });
}
