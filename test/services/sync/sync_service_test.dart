import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/device_clock.dart';
import 'package:frelocator/features/daily_plan/data/daily_plan_repository.dart';
import 'package:frelocator/features/task_master/data/task_master_repository.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';
import 'package:frelocator/services/app_data_service.dart';
import 'package:frelocator/services/storage/prefs_state_store.dart';
import 'package:frelocator/services/sync/lan_sync_client.dart';
import 'package:frelocator/services/sync/sync_document.dart';
import 'package:frelocator/services/sync/sync_progress.dart';
import 'package:frelocator/services/sync/sync_service.dart';
import 'package:frelocator/services/sync/sync_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeClient extends LanSyncClient {
  _FakeClient(this.onSync) : super(allowInsecureForTest: true);

  final Future<SyncResponse> Function(SyncSettings s, Map<String, dynamic> document, String mode)
  onSync;

  String? lastMode;
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  final List<String> hosts = <String>[];

  @override
  Future<SyncResponse> sync(
    SyncSettings s,
    Map<String, dynamic> document, {
    String mode = 'merge',
    SyncProgressController? progress,
  }) {
    lastMode = mode;
    sent.add(document);
    hosts.add('${s.host}:${s.port}');
    return onSync(s, document, mode);
  }
}

Map<String, dynamic> _hubTask(String id, String clock) => <String, dynamic>{
  'id': id,
  'title': 'x',
  'kind': 'must_do',
  'priority': 3,
  'createdAt': '2026-01-01T00:00:00.000Z',
  'updatedAt': '2026-01-01T00:00:00.000Z',
  'memo': '',
  'categoryId': null,
  'estimatedMinutes': 0,
  'clock': clock,
  'deletedAt': null,
  'migrated': false,
};

/// Echoes the phone's document back with one extra task, the way the hub does.
Future<SyncResponse> _echoWithHubTask(
  SyncSettings s,
  Map<String, dynamic> doc,
  String mode,
) async {
  final result = SyncDocument.fromJson(doc, strict: true).toJson();
  (result['taskMaster'] as Map<String, dynamic>)['tasks'] = <Map<String, dynamic>>[
    _hubTask('from-hub', '999999-0-hub'),
  ];
  return SyncResponse(
    document: result,
    summary: const SyncSummary(added: 1, updated: 0, deleted: 0, removed: 0, warnings: 0),
    warnings: const <String>[],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SyncService> make(
    _FakeClient client, {
    Future<({String host, int port})?> Function()? discover,
  }) async {
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
      SyncSettings(host: 'h', port: 1, fingerprint: 'AB' * 32, token: 't', hubDeviceId: 'hub'),
    );
    return SyncService(
      client: client,
      data: data,
      settingsStore: settingsStore,
      deviceClock: clock,
      // Never touch the network from a unit test; the mDNS path has its own case.
      discover: discover ?? () async => null,
    );
  }

  test('applies the hub result, records lastSyncAt and observes hub clocks', () async {
    final client = _FakeClient(_echoWithHubTask);
    final service = await make(client);
    final progress = SyncProgressController();
    final outcome = await service.syncNow(progress: progress);
    expect(outcome, isA<SyncApplied>());
    expect((outcome as SyncApplied).summary.added, 1);
    expect((await service.data.taskRepo.load()).tasks.single.id, 'from-hub');
    expect((await service.settingsStore.load()).lastSyncAt, isNotNull);
    expect(service.deviceClock.deviceId, startsWith('test-'));
    expect((await service.deviceClock.next()).physical, greaterThanOrEqualTo(999999));
    expect(progress.value.stage, SyncStage.done);
  });

  test('every timestamp on the wire is UTC ISO-8601 with Z', () async {
    final client = _FakeClient(_echoWithHubTask);
    final service = await make(client);
    // A first sync records lastSyncAt; the second one has to send it back.
    await service.syncNow();
    await service.syncNow();
    expect(client.sent, hasLength(2));
    final second = client.sent.last;
    expect(second['version'], 2);
    expect(second['lastSyncAt'], isNotNull);
    // taskMaster.settings is mandatory on the wire: the hub answers 400
    // invalid_document without it, and take_phone would then store a
    // document that breaks every later merge.
    expect((second['taskMaster'] as Map<String, dynamic>)['settings'], isA<Map<String, dynamic>>());

    final stamps = <String>[];
    void walk(dynamic node) {
      if (node is Map) {
        for (final entry in node.entries) {
          final value = entry.value;
          if (value is String && RegExp(r'^\d{4}-\d{2}-\d{2}T').hasMatch(value)) {
            stamps.add('${entry.key}=$value');
          } else {
            walk(value);
          }
        }
      } else if (node is List) {
        node.forEach(walk);
      }
    }

    walk(second);
    expect(stamps, isNotEmpty);
    for (final stamp in stamps) {
      expect(stamp, endsWith('Z'), reason: 'the hub reads offset-less stamps as its own local time');
    }
  });

  test('409 purged_before becomes NeedsReplace and a replace call sends the mode', () async {
    var calls = 0;
    final client = _FakeClient((s, doc, mode) async {
      calls += 1;
      if (mode == 'merge') throw const SyncHttpException(409, 'purged_before', 'choose');
      return _echoWithHubTask(s, doc, mode);
    });
    final service = await make(client);
    final outcome = await service.syncNow();
    expect(outcome, isA<SyncNeedsReplace>());
    expect((outcome as SyncNeedsReplace).message, contains('選んで'));
    final again = await service.syncNow(mode: SyncMode.takePhone);
    expect(again, isA<SyncApplied>());
    expect(client.lastMode, 'take_phone');
    expect(calls, 2);
  });

  test('take_hub is sent on the wire as take_hub', () async {
    final client = _FakeClient(_echoWithHubTask);
    final service = await make(client);
    await service.syncNow(mode: SyncMode.takeHub);
    expect(client.lastMode, 'take_hub');
  });

  test('426, 401 and unreachable become SyncFailed with distinct codes', () async {
    final s1 = await make(
      _FakeClient((s, d, m) async => throw const SyncHttpException(426, 'upgrade_required', 'update')),
    );
    final failed = await s1.syncNow() as SyncFailed;
    expect(failed.code, 'upgrade_required');
    expect(failed.message, contains('アプリを更新'));
    expect(failed.retriable, isFalse);

    final s2 = await make(
      _FakeClient((s, d, m) async => throw const SyncHttpException(0, 'unreachable', 'no route')),
    );
    final unreachable = await s2.syncNow() as SyncFailed;
    expect(unreachable.code, 'unreachable');
    expect(unreachable.retriable, isTrue);

    final s3 = await make(
      _FakeClient((s, d, m) async => throw const SyncHttpException(401, 'unauthorized', 'nope')),
    );
    final unauthorized = await s3.syncNow() as SyncFailed;
    expect(unauthorized.code, 'unauthorized');
    expect(unauthorized.needsRepair, isTrue, reason: '401 means the pairing has to be redone');
  });

  test('413 fails without retrying', () async {
    var calls = 0;
    final client = _FakeClient((s, d, m) async {
      calls += 1;
      throw const SyncHttpException(413, 'payload_too_large', 'too big');
    });
    final service = await make(client);
    final outcome = await service.syncNow() as SyncFailed;
    expect(outcome.code, 'payload_too_large');
    expect(outcome.retriable, isFalse);
    expect(calls, 1);
  });

  test('not paired is reported without calling the client', () async {
    final client = _FakeClient((s, d, m) async => throw StateError('should not be called'));
    final service = await make(client);
    await service.settingsStore.clear();
    expect((await service.syncNow() as SyncFailed).code, 'not_paired');
  });

  test('cancel during the exchange yields SyncCancelled', () async {
    final progress = SyncProgressController();
    final client = _FakeClient((s, d, m) async {
      progress.stage(SyncStage.waitingHub);
      progress.cancel();
      throw const SyncHttpException(0, 'cancelled', '同期を中止しました');
    });
    final service = await make(client);
    progress.start(SyncKind.lan);
    final outcome = await service.syncNow(progress: progress);
    expect(outcome, isA<SyncCancelled>());
    expect((outcome as SyncCancelled).hubMayHaveChanged, isTrue);
  });

  group('mDNS fallback', () {
    test('is tried once when the stored address is unreachable, then the new one is saved', () async {
      var discovered = 0;
      final client = _FakeClient((s, doc, mode) async {
        if (s.host == 'h') throw const SyncHttpException(0, 'unreachable', 'no route');
        return _echoWithHubTask(s, doc, mode);
      });
      final service = await make(
        client,
        discover: () async {
          discovered += 1;
          return (host: '10.0.0.5', port: 47820);
        },
      );
      final outcome = await service.syncNow();
      expect(outcome, isA<SyncApplied>());
      expect(discovered, 1);
      expect(client.hosts, ['h:1', '10.0.0.5:47820']);
      final saved = await service.settingsStore.load();
      expect(saved.host, '10.0.0.5');
      expect(saved.port, 47820);
      expect(saved.token, 't', reason: 'the token and pin survive a re-addressed hub');
      expect(saved.fingerprint, 'AB' * 32);
    });

    test('is not consulted when the manual address works', () async {
      var discovered = 0;
      final service = await make(
        _FakeClient(_echoWithHubTask),
        discover: () async {
          discovered += 1;
          return (host: '10.0.0.5', port: 47820);
        },
      );
      expect(await service.syncNow(), isA<SyncApplied>());
      expect(discovered, 0);
    });

    test('a discovery that finds nothing leaves the original failure intact', () async {
      var discovered = 0;
      final client = _FakeClient(
        (s, d, m) async => throw const SyncHttpException(0, 'unreachable', 'no route'),
      );
      final service = await make(
        client,
        discover: () async {
          discovered += 1;
          return null;
        },
      );
      expect((await service.syncNow() as SyncFailed).code, 'unreachable');
      expect(discovered, 1);
      expect(client.hosts, ['h:1'], reason: 'no retry without a new address');
    });

    test('a discovery that hangs cannot stall the sync forever', () async {
      final service = await make(
        _FakeClient((s, d, m) async => throw const SyncHttpException(0, 'unreachable', 'no route')),
        discover: () => Future<({String host, int port})?>.delayed(const Duration(seconds: 30)),
      );
      final outcome = await service
          .syncNow()
          .timeout(const Duration(seconds: 5), onTimeout: () => throw StateError('not time-boxed'));
      expect((outcome as SyncFailed).code, 'unreachable');
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  test('applyReceived merges an out-of-band document and counts what changed', () async {
    final service = await make(_FakeClient((s, d, m) async => throw StateError('unused')));
    final local = await service.data.exportDocument();
    final incoming = local.copyWith(
      taskMaster: local.taskMaster.copyWith(
        tasks: [
          ...local.taskMaster.tasks,
          TaskMaster.fromJson(_hubTask('from-qr', '5000-0-other')),
        ],
      ),
    );
    final applied = await service.applyReceived(incoming.toJson()) as SyncApplied;
    expect(applied.summary.added, 1);
    expect((await service.data.taskRepo.load()).tasks.map((t) => t.id), contains('from-qr'));
  });

  test('applyReceived reports a corrupt document instead of throwing', () async {
    final service = await make(_FakeClient((s, d, m) async => throw StateError('unused')));
    final progress = SyncProgressController();
    progress.start(SyncKind.qr);
    final outcome = await service.applyReceived(
      <String, dynamic>{'version': 2, 'taskMaster': 'not-an-object'},
      progress: progress,
    );
    expect(outcome, isA<SyncFailed>());
    expect((outcome as SyncFailed).code, 'corrupt');
    expect(progress.value.stage, SyncStage.failed);
    expect(progress.value.errorCode, 'corrupt');
  });

  test('lastSyncAt comes from the hub document, not the phone clock', () async {
    final hubStamp = DateTime.utc(2020, 5, 4, 3, 2, 1);
    final client = _FakeClient((s, doc, mode) async {
      final result = SyncDocument.fromJson(doc, strict: true).toJson();
      result['lastSyncAt'] = hubStamp.toIso8601String();
      return SyncResponse(
        document: result,
        summary: const SyncSummary(added: 0, updated: 0, deleted: 0, warnings: 0),
        warnings: const <String>[],
      );
    });
    final service = await make(client);
    expect(await service.syncNow(), isA<SyncApplied>());
    expect((await service.settingsStore.load()).lastSyncAt, hubStamp);
  });

  test('a second concurrent syncNow is refused as busy', () async {
    final gate = Completer<void>();
    var calls = 0;
    final client = _FakeClient((s, doc, mode) async {
      calls += 1;
      await gate.future;
      return _echoWithHubTask(s, doc, mode);
    });
    final service = await make(client);
    final first = service.syncNow();
    final second = await service.syncNow();
    expect(second, isA<SyncFailed>());
    expect((second as SyncFailed).code, 'busy');
    expect((second).message, contains('実行中'));
    gate.complete();
    expect(await first, isA<SyncApplied>());
    expect(calls, 1);
    // The guard has to lift once the first sync is done.
    expect(await service.syncNow(), isA<SyncApplied>());
  });

  test('a replace snapshots the current data first and restoreBackup puts it back', () async {
    final client = _FakeClient(_echoWithHubTask);
    final service = await make(client);
    // Something only this phone has, which take_hub is about to wipe out.
    final before = await service.data.exportDocument();
    await service.data.importDocument(
      before.copyWith(
        taskMaster: before.taskMaster.copyWith(
          tasks: [TaskMaster.fromJson(_hubTask('only-on-phone', '1000-0-me'))],
        ),
      ),
    );
    expect(await service.hasBackup, isFalse);

    expect(await service.syncNow(mode: SyncMode.takeHub), isA<SyncApplied>());
    expect((await service.data.taskRepo.load()).tasks.map((t) => t.id), ['from-hub']);
    expect(await service.hasBackup, isTrue);

    expect(await service.restoreBackup(), isTrue);
    expect((await service.data.taskRepo.load()).tasks.map((t) => t.id), ['only-on-phone']);
    expect(await service.hasBackup, isFalse, reason: 'the snapshot is spent once used');
    expect(await service.restoreBackup(), isFalse);
  });

  test('a merge does not snapshot: nothing is being thrown away', () async {
    final service = await make(_FakeClient(_echoWithHubTask));
    expect(await service.syncNow(), isA<SyncApplied>());
    expect(await service.hasBackup, isFalse);
  });

  test('the hub English message stays out of the panel text', () async {
    final service = await make(
      _FakeClient((s, d, m) async => throw const SyncHttpException(401, 'unauthorized', 'bad token')),
    );
    final progress = SyncProgressController();
    final failed = await service.syncNow(progress: progress) as SyncFailed;
    expect(progress.value.errorMessage, isNot(contains('bad token')));
    expect(progress.value.errorMessage, contains('ペアリング'));
    expect(failed.message, contains('bad token'), reason: 'kept as detail for the log');
  });

  test('a rediscovered address is only stored once the retry works', () async {
    final client = _FakeClient((s, doc, mode) async {
      throw const SyncHttpException(0, 'unreachable', 'no route');
    });
    final service = await make(
      client,
      discover: () async => (host: '10.0.0.9', port: 47820),
    );
    expect((await service.syncNow() as SyncFailed).code, 'unreachable');
    expect(client.hosts, ['h:1', '10.0.0.9:47820']);
    final saved = await service.settingsStore.load();
    expect(saved.host, 'h', reason: 'a guess that did not work must not replace the stored address');
    expect(saved.port, 1);
  });
}
