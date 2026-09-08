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

  test('detects an external change since last read', () async {
    final store = FileBackedStore(directory: tmp.path, deviceId: 'macos-1');
    await store.writeTaskMaster(TaskMasterStateData.initial());
    expect(await store.changedSinceLastRead(), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    File('${tmp.path}/data.json').writeAsStringSync(
      '${File('${tmp.path}/data.json').readAsStringSync()} ',
    );
    expect(await store.changedSinceLastRead(), isTrue);
  });
}
