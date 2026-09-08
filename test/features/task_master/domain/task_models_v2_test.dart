import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/hlc.dart';
import 'package:frelocator/core/sync_meta.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';

void main() {
  test('v1 payload decodes with migrated meta and default settings', () {
    final v1 = jsonEncode({
      'tasks': [
        {
          'id': 't1',
          'title': 'a',
          'kind': 'must_do',
          'priority': 3,
          'createdAt': '2026-01-01T00:00:00.000',
          'updatedAt': '2026-01-02T00:00:00.000',
        },
      ],
      'mustDoCategories': [
        {'id': 'must-work', 'name': '仕事'},
      ],
      'wantToDoCategories': [],
      'shareCategories': true,
    });
    final state = TaskMasterStateData.decode(v1);
    expect(state.tasks.single.meta.clock, Hlc.migrated);
    expect(state.tasks.single.meta.migrated, isTrue);
    expect(state.mustDoCategories.single.meta.clock, Hlc.migrated);
    expect(state.shareCategories, isTrue);
    expect(state.settingsMeta.clock, Hlc.migrated);
    expect(state.deletedTasks, isEmpty);
  });

  test('v2 round trip keeps tombstones, settings meta and extra keys', () {
    final meta = SyncMeta.stamp(Hlc.parse('10-0-dev'), DateTime.utc(2026, 9, 8));
    final state = TaskMasterStateData(
      tasks: [
        TaskMaster(
          id: 't1',
          title: 'a',
          kind: TaskKind.mustDo,
          priority: 3,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          meta: meta,
        ),
      ],
      mustDoCategories: [TaskCategory(id: 'c1', name: 'x', meta: meta)],
      wantToDoCategories: const [],
      shareCategories: false,
      settingsMeta: meta,
      deletedTasks: [
        Tombstone(
          id: 't0',
          meta: meta.tombstone(Hlc.parse('11-0-dev'), DateTime.utc(2026, 9, 9)),
        ),
      ],
    );
    final json = state.toJson();
    expect(
      (json['tasks'] as List).length,
      2,
      reason: 'tombstone is emitted inside the same array',
    );
    expect(json['settings'], {'shareCategories': false, ...meta.toJson()});
    final back = TaskMasterStateData.fromJson(json);
    expect(back.tasks.single.id, 't1');
    expect(back.deletedTasks.single.id, 't0');
    expect(back.deletedTasks.single.meta.clock, Hlc.parse('11-0-dev'));
    expect(back.tasks.single.meta.clock, Hlc.parse('10-0-dev'));
  });

  test('strict decode throws on a corrupt record, lenient skips it', () {
    final json = {
      'tasks': ['bad'],
      'mustDoCategories': [],
      'wantToDoCategories': [],
      'shareCategories': false,
    };
    expect(
      () => TaskMasterStateData.fromJson(json, strict: true),
      throwsFormatException,
    );
    expect(TaskMasterStateData.fromJson(json).tasks, isEmpty);
  });

  test('TaskMaster.toJson/fromJson keeps updatedAt in UTC', () {
    final task = TaskMaster.fromJson({
      'id': 't',
      'title': 'x',
      'kind': 'must_do',
      'createdAt': '2026-01-01T09:00:00.000+09:00',
      'updatedAt': '2026-01-01T09:00:00.000+09:00',
    });
    expect(task.toJson()['updatedAt'], '2026-01-01T00:00:00.000Z');
  });
}
