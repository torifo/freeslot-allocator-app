import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/services/sync/sync_document.dart';

void main() {
  test('parses a v1 export and upgrades it to v2', () {
    final doc = SyncDocument.fromJson(<String, dynamic>{
      'version': 1,
      'exported_at': '2026-09-08T00:00:00.000Z',
      'task_master': <String, dynamic>{
        'tasks': <dynamic>[],
        'mustDoCategories': <dynamic>[],
        'wantToDoCategories': <dynamic>[],
        'shareCategories': false,
      },
      'daily_plan': <String, dynamic>{
        'plans': <dynamic>[],
        'slots': <dynamic>[],
        'assignments': <dynamic>[],
      },
    });
    expect(doc.version, 2);
    expect(doc.deviceId, 'migrated');
    expect(doc.taskMaster.mustDoCategories, isEmpty);
    expect(doc.exportedAt, DateTime.utc(2026, 9, 8));
    expect(doc.taskMaster.settingsMeta.migrated, isTrue);
  });

  test('parses v2 keys and rejects newer versions', () {
    final json = <String, dynamic>{
      'version': 2,
      'exportedAt': '2026-09-08T00:00:00.000Z',
      'deviceId': 'android-1',
      'lastSyncAt': null,
      'taskMaster': <String, dynamic>{
        'tasks': <dynamic>[],
        'mustDoCategories': <dynamic>[],
        'wantToDoCategories': <dynamic>[],
        'settings': <String, dynamic>{'shareCategories': true},
      },
      'dailyPlan': <String, dynamic>{
        'plans': <dynamic>[],
        'slots': <dynamic>[],
        'assignments': <dynamic>[],
      },
    };
    final doc = SyncDocument.fromJson(json);
    expect(doc.taskMaster.shareCategories, isTrue);
    expect(doc.deviceId, 'android-1');
    expect(doc.toJson()['version'], 2);
    expect(
      () => SyncDocument.fromJson(<String, dynamic>{...json, 'version': 3}),
      throwsA(isA<UnsupportedSchemaException>()),
    );
  });

  test('round trips through toJson', () {
    final source = <String, dynamic>{
      'version': 2,
      'exportedAt': '2026-09-08T00:00:00.000Z',
      'deviceId': 'android-1',
      'lastSyncAt': '2026-09-07T00:00:00.000Z',
      'purgedBefore': '2026-08-01T00:00:00.000Z',
      'taskMaster': <String, dynamic>{
        'tasks': <dynamic>[
          <String, dynamic>{
            'id': 't1',
            'title': 'x',
            'kind': 'must_do',
            'priority': 3,
            'createdAt': '2026-09-01T00:00:00.000Z',
            'updatedAt': '2026-09-01T00:00:00.000Z',
            'memo': '',
            'categoryId': null,
            'estimatedMinutes': 0,
            'clock': '10-0-a',
            'deletedAt': null,
            'migrated': false,
          },
        ],
        'mustDoCategories': <dynamic>[],
        'wantToDoCategories': <dynamic>[],
        'settings': <String, dynamic>{'shareCategories': false},
      },
      'dailyPlan': <String, dynamic>{
        'plans': <dynamic>[],
        'slots': <dynamic>[],
        'assignments': <dynamic>[],
      },
    };
    final doc = SyncDocument.fromJson(source, strict: true);
    final again = SyncDocument.fromJson(doc.toJson(), strict: true);
    expect(again.toJson(), doc.toJson());
    expect(again.lastSyncAt, DateTime.utc(2026, 9, 7));
    expect(again.purgedBefore, DateTime.utc(2026, 8, 1));
    expect(again.taskMaster.tasks.single.meta.clock.toString(), '10-0-a');
  });

  test('strict mode propagates corrupt records', () {
    expect(
      () => SyncDocument.fromJson(<String, dynamic>{
        'version': 2,
        'exportedAt': 'x',
        'deviceId': 'd',
        'taskMaster': <String, dynamic>{
          'tasks': <dynamic>['bad'],
        },
        'dailyPlan': <String, dynamic>{},
      }, strict: true),
      throwsFormatException,
    );
  });

  test('strict mode rejects a non-int version', () {
    expect(
      () => SyncDocument.fromJson(<String, dynamic>{
        ..._validV2Json(),
        'version': '2',
      }, strict: true),
      throwsFormatException,
    );
  });

  test('strict mode rejects a missing exportedAt', () {
    final json = _validV2Json()..remove('exportedAt');
    expect(
      () => SyncDocument.fromJson(json, strict: true),
      throwsFormatException,
    );
  });

  test('strict mode rejects an unparsable exportedAt', () {
    expect(
      () => SyncDocument.fromJson(<String, dynamic>{
        ..._validV2Json(),
        'exportedAt': 'not-a-date',
      }, strict: true),
      throwsFormatException,
    );
  });

  test('strict mode rejects a non-String deviceId', () {
    expect(
      () => SyncDocument.fromJson(<String, dynamic>{
        ..._validV2Json(),
        'deviceId': 42,
      }, strict: true),
      throwsFormatException,
    );
  });

  test('strict mode rejects a taskMaster that is not a Map', () {
    expect(
      () => SyncDocument.fromJson(<String, dynamic>{
        ..._validV2Json(),
        'taskMaster': <dynamic>[],
      }, strict: true),
      throwsFormatException,
    );
  });

  test('strict mode rejects a dailyPlan that is not a Map', () {
    expect(
      () => SyncDocument.fromJson(<String, dynamic>{
        ..._validV2Json(),
        'dailyPlan': 'nope',
      }, strict: true),
      throwsFormatException,
    );
  });

  test('lenient mode still tolerates all of the above', () {
    final json = _validV2Json()..remove('exportedAt');
    final doc = SyncDocument.fromJson(<String, dynamic>{
      ...json,
      'deviceId': 42,
      'taskMaster': <dynamic>[],
      'dailyPlan': 'nope',
    });
    expect(doc.version, 2);
    expect(doc.exportedAt, DateTime.utc(1970));
    expect(doc.deviceId, 'unknown');
    expect(doc.taskMaster.tasks, isEmpty);
    expect(doc.dailyPlan.plans, isEmpty);

    final nonIntVersionDoc = SyncDocument.fromJson(<String, dynamic>{
      ..._validV2Json(),
      'version': '2',
    });
    expect(nonIntVersionDoc.version, 2);
    expect(nonIntVersionDoc.deviceId, 'migrated');
  });
}

Map<String, dynamic> _validV2Json() => <String, dynamic>{
  'version': 2,
  'exportedAt': '2026-09-08T00:00:00.000Z',
  'deviceId': 'android-1',
  'taskMaster': <String, dynamic>{
    'tasks': <dynamic>[],
    'mustDoCategories': <dynamic>[],
    'wantToDoCategories': <dynamic>[],
    'settings': <String, dynamic>{'shareCategories': false},
  },
  'dailyPlan': <String, dynamic>{
    'plans': <dynamic>[],
    'slots': <dynamic>[],
    'assignments': <dynamic>[],
  },
};
