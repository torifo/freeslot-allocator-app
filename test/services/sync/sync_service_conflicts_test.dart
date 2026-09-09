import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/device_clock.dart';
import 'package:frelocator/features/daily_plan/data/daily_plan_repository.dart';
import 'package:frelocator/features/task_master/data/task_master_repository.dart';
import 'package:frelocator/services/app_data_service.dart';
import 'package:frelocator/services/storage/prefs_state_store.dart';
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
}
