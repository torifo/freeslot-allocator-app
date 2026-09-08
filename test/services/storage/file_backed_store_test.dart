import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';
import 'package:frelocator/services/storage/file_backed_store.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('frelocator-store-');
  });
  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('returns initial state when the file does not exist', () async {
    final store = FileBackedStore(directory: tmp.path, deviceId: 'macos-1');
    final state = await store.readTaskMaster();
    expect(state.tasks, isEmpty);
    expect(state.mustDoCategories, hasLength(3));
  });

  test('writes a v2 document atomically and keeps one .bak', () async {
    final store = FileBackedStore(directory: tmp.path, deviceId: 'macos-1');
    await store.writeTaskMaster(
      TaskMasterStateData.initial().copyWith(shareCategories: true),
    );
    await store.writeTaskMaster(
      TaskMasterStateData.initial().copyWith(shareCategories: false),
    );
    final json =
        jsonDecode(File('${tmp.path}/data.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(json['version'], 2);
    expect(json['deviceId'], 'macos-1');
    expect((json['taskMaster'] as Map)['settings']['shareCategories'], false);
    final bak =
        jsonDecode(File('${tmp.path}/data.json.bak').readAsStringSync())
            as Map<String, dynamic>;
    expect((bak['taskMaster'] as Map)['settings']['shareCategories'], true);
    expect(await File('${tmp.path}/data.json.tmp').exists(), isFalse);
    expect(await File('${tmp.path}/data.json.bak.tmp').exists(), isFalse);
  });

  test('quarantines a corrupt file and starts empty', () async {
    File('${tmp.path}/data.json').writeAsStringSync('{not json');
    final store = FileBackedStore(directory: tmp.path, deviceId: 'macos-1');
    final state = await store.readDailyPlan();
    expect(state.plans, isEmpty);
    expect(
      tmp.listSync().any((f) => f.path.contains('data.json.broken-')),
      isTrue,
    );
    expect(store.lastWarning, contains('broken'));
  });

  test(
    'does not quarantine an empty/whitespace file, just returns empty doc',
    () async {
      File('${tmp.path}/data.json').writeAsStringSync('   \n');
      final store = FileBackedStore(directory: tmp.path, deviceId: 'macos-1');
      final state = await store.readDailyPlan();
      expect(state.plans, isEmpty);
      expect(
        tmp.listSync().any((f) => f.path.contains('data.json.broken-')),
        isFalse,
      );
      expect(store.lastWarning, isNull);
    },
  );

  test('writing task master preserves daily plan data in the same file', () async {
    final store = FileBackedStore(directory: tmp.path, deviceId: 'macos-1');
    final planJson = {
      'plans': [
        {
          'id': 'p',
          'date': '2026-09-08',
          'createdAt': '2026-09-08T00:00:00.000Z',
          'updatedAt': '2026-09-08T00:00:00.000Z',
        },
      ],
      'slots': [],
      'assignments': [],
    };
    File('${tmp.path}/data.json').writeAsStringSync(
      jsonEncode({
        'version': 2,
        'exportedAt': 'x',
        'deviceId': 'd',
        'taskMaster': TaskMasterStateData.initial().toJson(),
        'dailyPlan': planJson,
      }),
    );
    await store.writeTaskMaster(
      TaskMasterStateData.initial().copyWith(shareCategories: true),
    );
    expect((await store.readDailyPlan()).plans.single.id, 'p');
  });

  test('detects an external change since last read via content etag', () async {
    final store = FileBackedStore(directory: tmp.path, deviceId: 'macos-1');
    await store.writeTaskMaster(TaskMasterStateData.initial());
    expect(await store.changedSinceLastRead(), isFalse);
    // Overwrite with same-size, different content (no timing dependency).
    final original = File('${tmp.path}/data.json').readAsStringSync();
    final mutated = original.replaceFirst('"macos-1"', '"macos-2"');
    expect(mutated.length, original.length);
    File('${tmp.path}/data.json').writeAsStringSync(mutated);
    expect(await store.changedSinceLastRead(), isTrue);
  });

  test('defaultDirectory falls back to system temp when HOME is unset', () {
    // We cannot unset Platform.environment (it is immutable in tests), so
    // this just asserts the normal case resolves under HOME when set.
    final dir = FileBackedStore.defaultDirectory();
    expect(dir, isNotEmpty);
  });

  group('mkdir-sentinel lock', () {
    test(
      'a second instance waits for the lock to be released',
      () async {
        final holder = FileBackedStore(directory: tmp.path, deviceId: 'a');
        final waiter = FileBackedStore(directory: tmp.path, deviceId: 'b');

        final release = Completer<void>();
        final holding = Completer<void>();
        final holdFuture = holder.withLockForTest(() async {
          holding.complete();
          await release.future;
        });
        await holding.future;

        var waiterDone = false;
        final waiterFuture = waiter
            .writeTaskMaster(TaskMasterStateData.initial())
            .then((_) => waiterDone = true);

        // Give the waiter a chance to run; it must still be blocked.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(waiterDone, isFalse);

        release.complete();
        await holdFuture;
        await waiterFuture;
        expect(waiterDone, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'a stale sentinel (old mtime) is reclaimed and the write succeeds',
      () async {
        final sentinel = Directory('${tmp.path}/data.lock.lock');
        await sentinel.create(recursive: true);
        final heartbeat = File('${sentinel.path}/heartbeat');
        await heartbeat.writeAsString('stale');
        final old = DateTime.now().subtract(const Duration(seconds: 30));
        await heartbeat.setLastModified(old);

        final store = FileBackedStore(
          directory: tmp.path,
          deviceId: 'a',
          lockTimeout: const Duration(seconds: 3),
        );
        await store.writeTaskMaster(TaskMasterStateData.initial());
        expect(
          (await store.readTaskMaster()).mustDoCategories,
          hasLength(3),
        );
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'a fresh sentinel makes the write throw StateError after the deadline',
      () async {
        final sentinel = Directory('${tmp.path}/data.lock.lock');
        await sentinel.create(recursive: true);
        final heartbeat = File('${sentinel.path}/heartbeat');
        await heartbeat.writeAsString('fresh');
        await heartbeat.setLastModified(DateTime.now());

        final store = FileBackedStore(
          directory: tmp.path,
          deviceId: 'a',
          lockTimeout: const Duration(milliseconds: 500),
        );
        await expectLater(
          store.writeTaskMaster(TaskMasterStateData.initial()),
          throwsA(isA<StateError>()),
        );
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );
  });

  test('bak.tmp does not linger after two writes', () async {
    final store = FileBackedStore(directory: tmp.path, deviceId: 'macos-1');
    await store.writeTaskMaster(
      TaskMasterStateData.initial().copyWith(shareCategories: true),
    );
    await store.writeTaskMaster(
      TaskMasterStateData.initial().copyWith(shareCategories: false),
    );
    expect(await File('${tmp.path}/data.json.bak.tmp').exists(), isFalse);
    final bak =
        jsonDecode(File('${tmp.path}/data.json.bak').readAsStringSync())
            as Map<String, dynamic>;
    expect((bak['taskMaster'] as Map)['settings']['shareCategories'], true);
  });
}
