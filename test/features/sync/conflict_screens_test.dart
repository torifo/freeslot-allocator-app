import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/device_clock.dart';
import 'package:frelocator/core/hlc.dart';
import 'package:frelocator/features/daily_plan/data/daily_plan_repository.dart';
import 'package:frelocator/features/sync/application/conflict_controller.dart';
import 'package:frelocator/features/sync/presentation/conflict_detail_screen.dart';
import 'package:frelocator/features/sync/presentation/conflict_list_screen.dart';
import 'package:frelocator/features/task_master/data/task_master_repository.dart'
    show stateStoreProvider, TaskMasterRepository;
import 'package:frelocator/services/app_data_service.dart';
import 'package:frelocator/services/hub_mode/hub_mode.dart';
import 'package:frelocator/services/storage/prefs_state_store.dart';
import 'package:frelocator/services/sync/conflict_record.dart';
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
  }) async => throw StateError('the conflict screens never talk to the hub');
}

const String hubClock = '3000-0-hub-0000';
const String phoneClock = '2000-0-android-1';
const String hubTitle = '確定申告の書類を集める';
const String phoneTitle = '確定申告（領収書だけ先に）';

Map<String, dynamic> _task(String id, String title, String clock) => <String, dynamic>{
  'id': id, 'title': title, 'kind': 'must_do', 'priority': 3,
  'createdAt': '2026-01-01T00:00:00.000Z', 'updatedAt': '2026-02-01T00:00:00.000Z',
  'memo': '', 'categoryId': null, 'estimatedMinutes': 0,
  'clock': clock, 'deletedAt': null, 'migrated': false,
};

Map<String, dynamic> _grave(String id, String clock) => <String, dynamic>{
  'id': id, 'clock': clock, 'updatedAt': '2026-02-01T00:00:00.000Z',
  'deletedAt': '2026-02-01T00:00:00.000Z', 'migrated': false,
};

ConflictRecord _record({
  required String entityId,
  required Map<String, dynamic> winner,
  required Map<String, dynamic> loser,
  String winnerDeviceId = 'hub-0000',
  String loserDeviceId = 'android-1',
  String? resolution,
}) => ConflictRecord.fromJson(<String, dynamic>{
  'id': conflictId(entityId, winner['clock'] as String, loser['clock'] as String),
  'entityType': 'task',
  'entityId': entityId,
  'detectedAt': '2026-02-03T00:00:00.000Z',
  'detectedBy': 'android-1',
  'winner': <String, dynamic>{
    'side': sideOfDevice(winnerDeviceId), 'deviceId': winnerDeviceId, 'clock': winner['clock'],
    'updatedAt': winner['updatedAt'], 'snapshot': winner,
  },
  'loser': <String, dynamic>{
    'side': sideOfDevice(loserDeviceId), 'deviceId': loserDeviceId, 'clock': loser['clock'],
    'updatedAt': loser['updatedAt'], 'snapshot': loser,
  },
  'resolution': resolution,
  'resolvedAt': resolution == null ? null : '2026-02-04T00:00:00.000Z',
  'resolvedBy': resolution == null ? null : 'hub-0000',
  'clock': winner['clock'],
  'updatedAt': '2026-02-03T00:00:00.000Z',
  'deletedAt': null,
  'migrated': false,
});

late PrefsStateStore store;
late SyncService service;
late DeviceClock clock;

Future<void> seed(List<ConflictRecord> conflicts, {List<Map<String, dynamic>>? tasks}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  store = PrefsStateStore();
  clock = await DeviceClock.load(platformPrefix: 'test', now: () => 9000);
  final data = AppDataService(
    taskRepo: TaskMasterRepository(store),
    dailyPlanRepo: DailyPlanRepository(store),
    store: store,
    deviceClock: clock,
  );
  final document = await data.exportDocument();
  final json = document.toJson();
  (json['taskMaster'] as Map<String, dynamic>)['tasks'] =
      tasks ?? <Map<String, dynamic>>[_task('tsk-1', hubTitle, hubClock)];
  json['conflicts'] = conflicts.map((c) => c.toJson()).toList();
  await data.importAll(json);
  final settingsStore = SyncSettingsStore();
  await settingsStore.save(
    SyncSettings(host: 'h', port: 1, fingerprint: 'AB' * 32, token: 't', hubDeviceId: 'hub'),
  );
  service = SyncService(
    client: _UnusedClient(),
    data: data,
    settingsStore: settingsStore,
    deviceClock: clock,
    discover: () async => null,
  );
}

/// Pushes [screen] on top of a stand-in list screen, so a `pop` is something
/// the test can see. [pump] puts the screen up as the whole route, where there
/// is nothing to pop at all.
Future<void> pushed(WidgetTester tester, Widget screen) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        deviceClockProvider.overrideWithValue(clock),
        stateStoreProvider.overrideWithValue(store),
        syncServiceProvider.overrideWithValue(service),
        hubModeProvider.overrideWithValue(null),
        webIdProvider.overrideWithValue(null),
      ],
      child: MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Center(child: Text('競合の一覧'))),
      ),
    ),
  );
  unawaited(
    navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => screen)),
  );
  await tester.pumpAndSettle();
}

Future<void> pump(WidgetTester tester, Widget screen, {HubMode? hub, String? webId}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        deviceClockProvider.overrideWithValue(clock),
        stateStoreProvider.overrideWithValue(store),
        syncServiceProvider.overrideWithValue(service),
        hubModeProvider.overrideWithValue(hub),
        webIdProvider.overrideWithValue(webId),
      ],
      child: MaterialApp(home: screen),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final open = _record(
    entityId: 'tsk-1',
    winner: _task('tsk-1', hubTitle, hubClock),
    loser: _task('tsk-1', phoneTitle, phoneClock),
  );
  final second = _record(
    entityId: 'tsk-2',
    winner: _task('tsk-2', 'もう一件', hubClock),
    loser: _task('tsk-2', 'もう一件（スマホ）', phoneClock),
  );
  final closed = _record(
    entityId: 'tsk-3',
    winner: _task('tsk-3', '決めた分', hubClock),
    loser: _task('tsk-3', '捨てた分', phoneClock),
    resolution: 'hub',
  );

  testWidgets('the list separates open conflicts from resolved ones', (tester) async {
    await seed(<ConflictRecord>[open, second, closed]);
    await pump(tester, const ConflictListScreen());

    expect(find.text('未解決 2 件'), findsOneWidget);
    expect(find.text('解決済み 1 件'), findsOneWidget);
    expect(find.text('タスク「$hubTitle」'), findsOneWidget);
    // The resolved one is folded away until the user opens it.
    expect(find.text('タスク「決めた分」'), findsNothing);
    await tester.tap(find.text('解決済み 1 件'));
    await tester.pumpAndSettle();
    expect(find.text('タスク「決めた分」'), findsOneWidget);
  });

  testWidgets('an empty list says so instead of drawing nothing', (tester) async {
    await seed(<ConflictRecord>[]);
    await pump(tester, const ConflictListScreen());
    expect(find.text('競合はありません'), findsOneWidget);
    expect(find.text('すべてPC 版を採用'), findsNothing);
  });

  testWidgets('the batch buttons confirm before applying', (tester) async {
    await seed(
      <ConflictRecord>[open, second],
      tasks: <Map<String, dynamic>>[
        _task('tsk-1', hubTitle, hubClock),
        _task('tsk-2', 'もう一件', hubClock),
      ],
    );
    await pump(tester, const ConflictListScreen());

    await tester.tap(find.text('すべてPC 版を採用'));
    await tester.pumpAndSettle();
    expect(find.text('採用する'), findsOneWidget);
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    // Cancelling really is a cancel: both records are still open.
    expect(find.text('未解決 2 件'), findsOneWidget);

    await tester.tap(find.text('すべてスマホ版を採用'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('採用する'));
    await tester.pumpAndSettle();
    expect(find.text('未解決 0 件'), findsOneWidget);
    expect(find.text('解決済み 2 件'), findsOneWidget);
    expect((await store.readTaskMaster()).tasks.firstWhere((t) => t.id == 'tsk-1').title, phoneTitle);
  });

  testWidgets('the detail screen highlights the differing field and offers three choices', (tester) async {
    await seed(<ConflictRecord>[open]);
    await pump(tester, ConflictDetailScreen(id: open.id));

    expect(find.text('PC 版'), findsOneWidget);
    expect(find.text('スマホ版'), findsOneWidget);
    expect(find.text('PC 版を採用'), findsOneWidget);
    expect(find.text('スマホ版を採用'), findsOneWidget);
    expect(find.text('現状のまま'), findsOneWidget);
    // Only the field that differs is called out; the identical ones are quiet.
    expect(find.text('タイトル'), findsOneWidget);
    expect(find.text(hubTitle), findsOneWidget);
    expect(find.text(phoneTitle), findsOneWidget);
    expect(find.text('違いのある項目'), findsOneWidget);
  });

  testWidgets('adopting writes a fresh edit with a clock greater than both sides', (tester) async {
    await seed(<ConflictRecord>[open]);
    await pump(tester, ConflictDetailScreen(id: open.id));

    await tester.tap(find.text('スマホ版を採用'));
    await tester.pumpAndSettle();

    final task = (await store.readTaskMaster()).tasks.firstWhere((t) => t.id == 'tsk-1');
    expect(task.title, phoneTitle);
    expect(task.meta.clock.compareTo(Hlc.parse(phoneClock)) > 0, isTrue);
    expect(task.meta.clock.compareTo(Hlc.parse(hubClock)) > 0, isTrue);
    expect((await store.readConflicts()).single.resolution, 'device');
  });

  testWidgets('現状のまま closes the record without touching the data', (tester) async {
    await seed(<ConflictRecord>[open]);
    await pump(tester, ConflictDetailScreen(id: open.id));

    await tester.tap(find.text('現状のまま'));
    await tester.pumpAndSettle();

    expect((await store.readTaskMaster()).tasks.single.title, hubTitle);
    expect((await store.readConflicts()).single.resolution, 'current');
  });

  testWidgets('one side deleted is drawn as 削除済み, not as an empty record', (tester) async {
    final deleted = _record(
      entityId: 'tsk-1',
      winner: _task('tsk-1', hubTitle, hubClock),
      loser: _grave('tsk-1', phoneClock),
    );
    await seed(<ConflictRecord>[deleted]);
    await pump(tester, ConflictDetailScreen(id: deleted.id));

    expect(find.text('削除済み'), findsOneWidget);
    await tester.tap(find.text('スマホ版を採用'));
    await tester.pumpAndSettle();
    final state = await store.readTaskMaster();
    expect(state.tasks.where((t) => t.id == 'tsk-1'), isEmpty);
    expect(state.deletedTasks.single.id, 'tsk-1');
  });

  testWidgets('in hub mode the labels say PC（MCP）版 / この端末の版', (tester) async {
    final fromBrowser = _record(
      entityId: 'tsk-1',
      winner: _task('tsk-1', hubTitle, hubClock),
      loser: _task('tsk-1', phoneTitle, phoneClock),
      loserDeviceId: 'web-00112233445566aa',
    );
    await seed(<ConflictRecord>[fromBrowser]);
    await pump(
      tester,
      ConflictDetailScreen(id: fromBrowser.id),
      hub: const HubMode(base: '/s/app/', api: '/s/api/', hubDeviceId: 'hub-0000', dataFile: '/tmp/data.json'),
      webId: '00112233445566aa',
    );

    expect(find.text('PC（MCP）版'), findsOneWidget);
    expect(find.text('この端末の版'), findsOneWidget);
    expect(find.text('この端末の版を採用'), findsOneWidget);
  });

  testWidgets('a browser that is not this one is named as such', (tester) async {
    final fromBrowser = _record(
      entityId: 'tsk-1',
      winner: _task('tsk-1', hubTitle, hubClock),
      loser: _task('tsk-1', phoneTitle, phoneClock),
      loserDeviceId: 'web-ffffffffffffffff',
    );
    await seed(<ConflictRecord>[fromBrowser]);
    await pump(
      tester,
      ConflictDetailScreen(id: fromBrowser.id),
      hub: const HubMode(base: '/s/app/', api: '/s/api/', hubDeviceId: 'hub-0000', dataFile: '/tmp/data.json'),
      webId: '00112233445566aa',
    );
    expect(find.text('ブラウザ版'), findsOneWidget);
  });

  testWidgets('a refused resolution keeps the screen and says why', (tester) async {
    // Purge dropped the entity the record names, which is the one resolution
    // the app cannot carry out.
    await seed(<ConflictRecord>[open], tasks: <Map<String, dynamic>>[]);
    await pushed(tester, ConflictDetailScreen(id: open.id));

    await tester.tap(find.text('スマホ版を採用'));
    await tester.pumpAndSettle();

    expect(
      find.text('この項目はもう端末にありません。「現状のまま」で記録だけ閉じてください。'),
      findsOneWidget,
    );
    // Still here: leaving would take the explanation with it and read as if the
    // choice had been applied.
    expect(find.text('スマホ版を採用'), findsOneWidget);
    expect(find.text('競合の一覧'), findsNothing);
    expect((await store.readConflicts()).single.isOpen, isTrue);
  });

  testWidgets('a resolution that goes through does go back to the list', (tester) async {
    await seed(<ConflictRecord>[open]);
    await pushed(tester, ConflictDetailScreen(id: open.id));

    await tester.tap(find.text('スマホ版を採用'));
    await tester.pumpAndSettle();

    expect(find.text('競合の一覧'), findsOneWidget);
    expect((await store.readConflicts()).single.resolution, 'device');
  });

  testWidgets('two phones are told apart by device id, not by side', (tester) async {
    // Since a side is read off the device id, both halves of a record can
    // legitimately be 「スマホ版」 — and then that name tells the user nothing.
    final phones = _record(
      entityId: 'tsk-1',
      winner: _task('tsk-1', hubTitle, '3000-0-android-2'),
      loser: _task('tsk-1', phoneTitle, phoneClock),
      winnerDeviceId: 'android-2',
      loserDeviceId: 'android-1',
    );
    await seed(<ConflictRecord>[phones]);
    await pump(tester, ConflictDetailScreen(id: phones.id));

    expect(find.text('スマホ版'), findsNothing);
    expect(find.text('端末 A（android-1）'), findsOneWidget);
    expect(find.text('端末 B（android-2）'), findsOneWidget);
    expect(find.text('端末 A（android-1）を採用'), findsOneWidget);
    expect(find.text('端末 B（android-2）を採用'), findsOneWidget);

    // And the choice still lands on the side the button names.
    await tester.tap(find.text('端末 B（android-2）を採用'));
    await tester.pumpAndSettle();
    expect((await store.readTaskMaster()).tasks.single.title, hubTitle);
  });

  testWidgets('the list names a two-phone conflict the same way', (tester) async {
    final phones = _record(
      entityId: 'tsk-1',
      winner: _task('tsk-1', hubTitle, '3000-0-android-2'),
      loser: _task('tsk-1', phoneTitle, phoneClock),
      winnerDeviceId: 'android-2',
      loserDeviceId: 'android-1',
    );
    await seed(<ConflictRecord>[phones]);
    await pump(tester, const ConflictListScreen());
    expect(find.textContaining('いまは端末 B（android-2）'), findsOneWidget);
  });
}
