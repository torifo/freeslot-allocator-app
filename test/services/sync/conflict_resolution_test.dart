import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/device_clock.dart';
import 'package:frelocator/core/hlc.dart';
import 'package:frelocator/features/daily_plan/data/daily_plan_repository.dart';
import 'package:frelocator/features/task_master/data/task_master_repository.dart';
import 'package:frelocator/services/app_data_service.dart';
import 'package:frelocator/services/storage/prefs_state_store.dart';
import 'package:frelocator/services/sync/conflict_resolver.dart';
import 'package:frelocator/services/sync/lan_sync_client.dart';
import 'package:frelocator/services/sync/sync_progress.dart';
import 'package:frelocator/services/sync/sync_service.dart';
import 'package:frelocator/services/sync/sync_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeClient extends LanSyncClient {
  _FakeClient() : super(allowInsecureForTest: true);

  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  @override
  Future<SyncResponse> sync(
    SyncSettings s,
    Map<String, dynamic> document, {
    String mode = 'merge',
    SyncProgressController? progress,
  }) async {
    sent.add(document);
    // The hub echoes what it was given, which is enough to prove what was sent.
    return SyncResponse(
      document: document,
      summary: const SyncSummary(added: 0, updated: 0, deleted: 0, warnings: 0),
      warnings: const <String>[],
    );
  }
}

const String hubClock = '3000-0-hub-0000';
const String deviceClockValue = '2000-0-android-1';

Map<String, dynamic> _task(String title, String clock, String updatedAt) => <String, dynamic>{
  'id': 'tsk-1', 'title': title, 'kind': 'must_do', 'priority': 3,
  'createdAt': '2026-01-01T00:00:00.000Z', 'updatedAt': updatedAt, 'memo': '',
  'categoryId': null, 'estimatedMinutes': 0, 'clock': clock,
  'deletedAt': null, 'migrated': false,
};

Map<String, dynamic> _tombstone(String clock, String at) => <String, dynamic>{
  'id': 'tsk-1', 'clock': clock, 'updatedAt': at, 'deletedAt': at, 'migrated': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeClient client;

  Future<SyncService> make({DateTime? lastSyncAt}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final store = PrefsStateStore();
    final clock = await DeviceClock.load(platformPrefix: 'test', now: () => 9000);
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
        lastSyncAt: lastSyncAt ?? DateTime.utc(2026, 1, 1),
      ),
    );
    client = _FakeClient();
    return SyncService(
      client: client,
      data: data,
      settingsStore: settingsStore,
      deviceClock: clock,
      discover: () async => null,
    );
  }

  /// Records one task conflict by merging an incoming document against a local
  /// edit of the same task, exactly as a QR or file import would.
  Future<SyncService> withConflict({Map<String, dynamic>? incomingTask}) async {
    final service = await make();
    final local = await service.data.exportDocument();
    final localJson = local.toJson();
    (localJson['taskMaster'] as Map<String, dynamic>)['tasks'] = <Map<String, dynamic>>[
      _task('PC で直した', hubClock, '2026-02-01T00:00:00.000Z'),
    ];
    await service.data.importAll(localJson);

    final incoming = local.toJson();
    (incoming['taskMaster'] as Map<String, dynamic>)['tasks'] = <Map<String, dynamic>>[
      incomingTask ?? _task('スマホで直した', deviceClockValue, '2026-02-02T00:00:00.000Z'),
    ];
    final applied = await service.applyReceived(incoming) as SyncApplied;
    expect(applied.summary.conflicts, 1);
    return service;
  }

  test('a detected conflict survives the import that stored it', () async {
    final service = await withConflict();
    final stored = await service.data.exportDocument();
    expect(stored.conflicts, hasLength(1));
    expect(stored.conflicts.single.entityId, 'tsk-1');
    expect(stored.conflicts.single.isOpen, isTrue);
    // The HLC winner is live; the loser is only in the record.
    expect((await service.data.taskRepo.load()).tasks.single.title, 'PC で直した');
    expect(stored.conflicts.single.loser.snapshot['title'], 'スマホで直した');
  });

  test('adopting the loser writes it back as a fresh edit', () async {
    final service = await withConflict();
    final id = (await service.data.exportDocument()).conflicts.single.id;
    final result = await service.resolveConflict(id, ConflictAdoption.device);
    expect(result.wrote, 1);
    expect(result.resolved, 1);

    final tasks = (await service.data.taskRepo.load()).tasks;
    expect(tasks.single.title, 'スマホで直した');
    // A new clock, not the loser's: the decision has to beat both versions.
    expect(tasks.single.meta.clock.compareTo(Hlc.parse(deviceClockValue)) > 0, isTrue);
    expect(tasks.single.meta.clock.compareTo(Hlc.parse(hubClock)) > 0, isTrue);
    expect(tasks.single.meta.migrated, isFalse);

    final record = (await service.data.exportDocument()).conflicts.single;
    expect(record.resolution, 'device');
    expect(record.resolvedAt, isNotNull);
    expect(record.resolvedBy, isNotEmpty);
    expect(record.isOpen, isFalse);
    expect(record.meta.clock.compareTo(Hlc.parse(hubClock)) > 0, isTrue);
  });

  test('現状のまま marks the record and writes nothing', () async {
    final service = await withConflict();
    final before = (await service.data.taskRepo.load()).tasks.single;
    final id = (await service.data.exportDocument()).conflicts.single.id;
    final result = await service.resolveConflict(id, ConflictAdoption.current);
    expect(result.wrote, 0);
    final after = (await service.data.taskRepo.load()).tasks.single;
    expect(after.title, before.title);
    expect(after.meta.clock.toString(), before.meta.clock.toString());
    expect((await service.data.exportDocument()).conflicts.single.resolution, 'current');
  });

  test('adopting a side that is already live marks the record without writing', () async {
    final service = await withConflict();
    final id = (await service.data.exportDocument()).conflicts.single.id;
    final result = await service.resolveConflict(id, ConflictAdoption.hub);
    expect(result.wrote, 0);
    expect(result.resolved, 1);
    expect((await service.data.taskRepo.load()).tasks.single.title, 'PC で直した');
  });

  test('adopting a tombstone deletes the entity again', () async {
    final service = await withConflict(
      incomingTask: _tombstone(deviceClockValue, '2026-02-02T00:00:00.000Z'),
    );
    final id = (await service.data.exportDocument()).conflicts.single.id;
    final result = await service.resolveConflict(id, ConflictAdoption.device);
    expect(result.wrote, 1);
    final state = await service.data.taskRepo.load();
    expect(state.tasks, isEmpty);
    expect(state.deletedTasks.single.id, 'tsk-1');
  });

  test('resolveAll closes every open record and refuses to re-resolve one', () async {
    final service = await withConflict();
    final id = (await service.data.exportDocument()).conflicts.single.id;
    final result = await service.resolveAll(ConflictAdoption.current);
    expect(result.resolved, 1);
    expect((await service.data.exportDocument()).conflicts.every((c) => !c.isOpen), isTrue);
    // A second pass has nothing left to do rather than re-deciding.
    expect((await service.resolveAll(ConflictAdoption.hub)).resolved, 0);
    await expectLater(
      service.resolveConflict(id, ConflictAdoption.hub),
      throwsA(isA<ConflictResolutionException>()),
    );
  });

  test('resolveAll can be limited to one entity type', () async {
    final service = await withConflict();
    expect((await service.resolveAll(ConflictAdoption.hub, entityType: 'slot')).resolved, 0);
    expect((await service.resolveAll(ConflictAdoption.hub, entityType: 'task')).resolved, 1);
  });

  test('an unknown id is refused', () async {
    final service = await withConflict();
    await expectLater(
      service.resolveConflict('cf-nope', ConflictAdoption.hub),
      throwsA(isA<ConflictResolutionException>()),
    );
  });

  test('the next sync carries the records, so a decision reaches the PC', () async {
    final service = await withConflict();
    await service.syncNow();
    final sent = client.sent.single;
    final conflicts = sent['conflicts'] as List<dynamic>;
    expect(conflicts, hasLength(1));
    expect((conflicts.single as Map<String, dynamic>)['entityId'], 'tsk-1');
  });
}
