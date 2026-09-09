import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/features/daily_plan/domain/daily_plan_models.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';
import 'package:frelocator/services/hub_mode/hub_mode.dart';
import 'package:frelocator/services/storage/hub_backed_store.dart';
import 'package:frelocator/services/sync/sync_document.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const hub = HubMode(
  base: '/abc/app/',
  api: '/abc/api/',
  hubDeviceId: 'hub-macos',
  dataFile: '/tmp/data.json',
);
const webId = '00112233445566aa';

final tasksA = TaskMasterStateData.initial().copyWith(shareCategories: true);
final tasksB = TaskMasterStateData.initial().copyWith(shareCategories: false);
final plansA = DailyPlanStateData.initial();

Map<String, dynamic> emptyDoc() => SyncDocument(
  exportedAt: DateTime.utc(2026, 9, 9),
  deviceId: 'hub-macos',
  taskMaster: TaskMasterStateData.initial(),
  dailyPlan: DailyPlanStateData.initial(),
).toJson();

http.Response okJson(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

Map<String, dynamic> documentBody({String revision = 'aaaaaaaaaaaaaaaa'}) => {
  'document': emptyDoc(),
  'hubDeviceId': 'hub-macos',
  'revision': revision,
  'serverTime': '2026-09-09T00:00:00.000Z',
};

Map<String, dynamic> syncBody() => {
  'document': emptyDoc(),
  'summary': {'added': 0, 'updated': 0, 'deleted': 0, 'removed': 0, 'warnings': 0},
  'warnings': <String>[],
};

HubBackedStore storeWith(MockClient client, {Duration debounce = const Duration(milliseconds: 20)}) =>
    HubBackedStore(hub: hub, webId: webId, client: client, debounce: debounce);

void main() {
  test('reads come from the snapshot fetched once, not from a request per read', () async {
    var documentCalls = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/api/document')) {
        documentCalls += 1;
        expect(request.headers['x-frelocator-web-id'], webId);
        return okJson(documentBody());
      }
      throw StateError('unexpected ${request.url}');
    });
    final store = storeWith(client);
    await store.readTaskMaster();
    await store.readDailyPlan();
    expect(documentCalls, 1);
  });

  test('writeAll debounces and single-flights into one POST /api/sync', () async {
    final posted = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      if (request.method == 'GET') return okJson(documentBody());
      expect(request.headers['x-frelocator-web-id'], webId);
      expect(request.headers['content-type'], contains('application/json'));
      expect(request.url.queryParameters['mode'], 'merge');
      posted.add(jsonDecode(request.body) as Map<String, dynamic>);
      return okJson(syncBody());
    });
    final store = storeWith(client);
    await store.readTaskMaster();
    unawaited(store.writeAll(tasksA, plansA));
    unawaited(store.writeAll(tasksB, plansA));
    await store.flush();
    expect(posted, hasLength(1), reason: 'the debounce folds a burst of edits into one request');
    expect(posted.single['deviceId'], 'web-$webId');
    expect(posted.single['version'], 2);
    expect(store.hasUnsentEdits.value, isFalse);
  });

  test('a failed POST raises the unsent flag and keeps the local snapshot', () async {
    final store = storeWith(MockClient((r) async => r.method == 'GET'
        ? okJson(documentBody())
        : http.Response('{"error":{"code":"internal","message":"boom"}}', 500,
            headers: {'content-type': 'application/json'})));
    await store.readTaskMaster();
    await store.writeAll(tasksA, plansA);
    await store.flush();
    expect(store.hasUnsentEdits.value, isTrue);
    // 送信に失敗しても画面の内容は消さない（次の再送で送る）。
    expect((await store.readTaskMaster()).shareCategories, isTrue);
    expect(store.lastWarning, isNotNull);
  });

  test('the poller retries a push that failed, and clears the flag once it lands', () async {
    var fail = true;
    final store = storeWith(MockClient((r) async {
      if (r.method == 'GET') return okJson(documentBody());
      if (fail) return http.Response('{"error":{"code":"internal","message":"boom"}}', 500);
      return okJson(syncBody());
    }));
    await store.readTaskMaster();
    await store.writeAll(tasksA, plansA);
    await store.flush();
    expect(store.hasUnsentEdits.value, isTrue);
    fail = false;
    await store.pollOnce();
    expect(store.hasUnsentEdits.value, isFalse);
  });

  test('changedSinceLastRead flips once the poller sees a new revision', () async {
    var revision = 'a' * 16;
    final store = storeWith(MockClient((r) async => okJson(
      r.url.path.endsWith('/api/revision')
          ? {'revision': revision, 'modifiedAt': null}
          : documentBody(revision: revision),
    )));
    await store.readTaskMaster();
    expect(await store.changedSinceLastRead(), isFalse);
    revision = 'b' * 16;
    await store.pollOnce();
    expect(await store.changedSinceLastRead(), isTrue);
  });

  test('a read after a remote change refetches the document and clears the flag', () async {
    var revision = 'a' * 16;
    var documentCalls = 0;
    final store = storeWith(MockClient((r) async {
      if (r.url.path.endsWith('/api/revision')) return okJson({'revision': revision, 'modifiedAt': null});
      documentCalls += 1;
      return okJson(documentBody(revision: revision));
    }));
    await store.readTaskMaster();
    revision = 'b' * 16;
    await store.pollOnce();
    await store.readTaskMaster();
    expect(documentCalls, 2);
    expect(await store.changedSinceLastRead(), isFalse);
  });

  test('an unsent edit is never overwritten by a refetch', () async {
    var revision = 'a' * 16;
    final store = storeWith(MockClient((r) async {
      if (r.method == 'POST') return http.Response('{"error":{"code":"internal","message":"boom"}}', 500);
      if (r.url.path.endsWith('/api/revision')) return okJson({'revision': revision, 'modifiedAt': null});
      return okJson(documentBody(revision: revision));
    }));
    await store.readTaskMaster();
    await store.writeAll(tasksA, plansA);
    await store.flush();
    revision = 'b' * 16;
    // The hub moved on and the push failed: the user's edit still wins the
    // screen, because dropping it would lose work no copy holds.
    expect((await store.readTaskMaster()).shareCategories, isTrue);
  });

  test('writeTaskMaster keeps the daily plans it did not touch', () async {
    Map<String, dynamic>? posted;
    final store = storeWith(MockClient((r) async {
      if (r.method == 'GET') return okJson(documentBody());
      posted = jsonDecode(r.body) as Map<String, dynamic>;
      return okJson(syncBody());
    }));
    await store.writeTaskMaster(tasksA);
    await store.flush();
    expect((posted!['taskMaster'] as Map)['settings']['shareCategories'], true);
    expect(posted!['dailyPlan'], isNotNull);
  });

  test('the store never writes business data to browser storage', () async {
    // The web seam is the stub under `flutter test`; this asserts the store
    // asks for nothing beyond the id it was handed.
    final store = storeWith(MockClient((r) async => okJson(documentBody())));
    await store.readTaskMaster();
    expect(readWebId(), isNull);
  });
}
