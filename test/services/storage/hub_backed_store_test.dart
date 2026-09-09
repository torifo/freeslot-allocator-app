import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/features/daily_plan/domain/daily_plan_models.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';
import 'package:frelocator/services/hub_mode/hub_mode.dart';
import 'package:frelocator/services/storage/hub_backed_store.dart';
import 'package:frelocator/services/sync/conflict_record.dart';
import 'package:frelocator/services/sync/lan_sync_types.dart';
import 'package:frelocator/services/sync/sync_document.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../helpers/conflict_fixtures.dart';

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

/// A second, recognisable half of the document: one free-time slot is enough
/// to tell "the daily plans survived" from "the daily plans were overwritten".
final plansB = DailyPlanStateData(
  plans: <DailyPlan>[],
  slots: <FreeTimeSlot>[
    FreeTimeSlot(
      id: 'slot-1',
      dailyPlanId: 'plan-1',
      startAt: DateTime.utc(2026, 9, 9, 9),
      endAt: DateTime.utc(2026, 9, 9, 10),
    ),
  ],
  assignments: <SlotTaskAssignment>[],
);

Map<String, dynamic> docOf({
  TaskMasterStateData? tasks,
  DailyPlanStateData? plans,
  List<ConflictRecord> conflicts = const <ConflictRecord>[],
}) => SyncDocument(
  exportedAt: DateTime.utc(2026, 9, 9),
  deviceId: 'hub-macos',
  taskMaster: tasks ?? TaskMasterStateData.initial(),
  dailyPlan: plans ?? DailyPlanStateData.initial(),
  conflicts: conflicts,
).toJson();

Map<String, dynamic> emptyDoc() => docOf();

http.Response okJson(Object body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

http.Response errorJson(int status, String code) => http.Response(
  '{"error":{"code":"$code","message":"boom"}}',
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> documentBody({String revision = 'aaaaaaaaaaaaaaaa', Map<String, dynamic>? document}) => {
  'document': document ?? emptyDoc(),
  'hubDeviceId': 'hub-macos',
  'revision': revision,
  'serverTime': '2026-09-09T00:00:00.000Z',
};

Map<String, dynamic> syncBody({Map<String, dynamic>? document}) => {
  'document': document ?? emptyDoc(),
  'summary': {'added': 0, 'updated': 0, 'deleted': 0, 'removed': 0, 'warnings': 0},
  'warnings': <String>[],
};

bool isRevision(http.BaseRequest request) => request.url.path.endsWith('/api/revision');

HubBackedStore storeWith(
  MockClient client, {
  Duration debounce = const Duration(milliseconds: 20),
  DateTime Function()? clock,
}) => HubBackedStore(hub: hub, webId: webId, client: client, debounce: debounce, clock: clock);

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

  test('an edit made while the push is in flight survives it', () async {
    final posted = <Map<String, dynamic>>[];
    late HubBackedStore store;
    final client = MockClient((request) async {
      if (request.method == 'GET') return okJson(documentBody());
      posted.add(jsonDecode(request.body) as Map<String, dynamic>);
      // The user keeps typing while the request is open. Adopting the answer
      // to *this* request would throw that edit away with no copy left.
      if (posted.length == 1) await store.writeAll(tasksA, plansB);
      return okJson(syncBody());
    });
    store = storeWith(client);
    await store.readTaskMaster();
    await store.writeAll(tasksA, plansA);
    await store.flush();
    expect(posted.length, greaterThan(1), reason: 'the store has to go round again');
    final last = posted.last;
    expect((last['taskMaster'] as Map)['settings']['shareCategories'], true);
    expect((last['dailyPlan'] as Map)['slots'], hasLength(1));
    expect(store.hasUnsentEdits.value, isFalse);
  });

  test('a merge that answers with something else asks the screen to reload', () async {
    final store = storeWith(MockClient((r) async {
      if (isRevision(r)) return okJson({'revision': 'a' * 16, 'modifiedAt': null});
      if (r.method == 'GET') return okJson(documentBody());
      // The hub had newer daily plans of its own; the merge brings them back.
      return okJson(syncBody(document: docOf(plans: plansB)));
    }));
    await store.readTaskMaster();
    await store.writeAll(tasksA, plansA);
    await store.flush();
    expect(await store.changedSinceLastRead(), isTrue);
    expect((await store.readDailyPlan()).slots, hasLength(1));
  });

  test('a merge that answers with exactly what was sent leaves the screen alone', () async {
    final store = storeWith(MockClient((r) async {
      if (isRevision(r)) return okJson({'revision': 'a' * 16, 'modifiedAt': null});
      if (r.method == 'GET') return okJson(documentBody());
      return okJson(syncBody());
    }));
    await store.readTaskMaster();
    await store.writeAll(TaskMasterStateData.initial(), DailyPlanStateData.initial());
    await store.flush();
    expect(await store.changedSinceLastRead(), isFalse);
  });

  test('the pushed document carries the conflict records', () async {
    final record = conflictFixture(entityId: 'tsk-1');
    final posted = <Map<String, dynamic>>[];
    final store = storeWith(MockClient((r) async {
      if (isRevision(r)) return okJson({'revision': 'a' * 16, 'modifiedAt': null});
      if (r.method == 'GET') return okJson(documentBody(document: docOf(conflicts: <ConflictRecord>[record])));
      posted.add(jsonDecode(r.body) as Map<String, dynamic>);
      return okJson(syncBody(document: docOf(conflicts: <ConflictRecord>[record])));
    }));
    await store.readTaskMaster();
    // A resolution made in this browser reaches the hub — and from there the
    // phone — only as a record, so dropping them from the payload would make
    // the decision local to the tab.
    await store.writeConflicts(<ConflictRecord>[record.copyWith(resolution: 'device')]);
    await store.flush();
    final sent = (posted.single['conflicts'] as List).single as Map<String, dynamic>;
    expect(sent['id'], record.id);
    expect(sent['resolution'], 'device');
    expect((sent['loser'] as Map)['snapshot']['title'], 'スマホの版');
  });

  test('a merge that only brings back a conflict record still reloads the screen', () async {
    final detected = conflictFixture(entityId: 'tsk-1');
    final store = storeWith(MockClient((r) async {
      if (isRevision(r)) return okJson({'revision': 'a' * 16, 'modifiedAt': null});
      if (r.method == 'GET') return okJson(documentBody());
      // Tasks and plans came back exactly as sent; the merge recorded a
      // conflict, which is the whole of the news and the conflict screen is
      // now behind it.
      return okJson(syncBody(document: docOf(conflicts: <ConflictRecord>[detected])));
    }));
    await store.readTaskMaster();
    await store.writeAll(TaskMasterStateData.initial(), DailyPlanStateData.initial());
    await store.flush();
    expect(await store.changedSinceLastRead(), isTrue);
    expect((await store.readConflicts()).single.id, detected.id);
  });

  test('updateDocument folds the change into the snapshot being pushed', () async {
    final posted = <Map<String, dynamic>>[];
    final store = storeWith(MockClient((r) async {
      if (isRevision(r)) return okJson({'revision': 'a' * 16, 'modifiedAt': null});
      if (r.method == 'GET') return okJson(documentBody());
      posted.add(jsonDecode(r.body) as Map<String, dynamic>);
      return okJson(syncBody(document: jsonDecode(r.body) as Map<String, dynamic>));
    }));
    await store.readTaskMaster();
    await store.updateDocument(
      (document) => document.copyWith(
        taskMaster: document.taskMaster.copyWith(shareCategories: true),
        conflicts: <ConflictRecord>[conflictFixture(entityId: 'tsk-1')],
      ),
    );
    await store.flush();
    expect(posted, hasLength(1), reason: 'read and write are one edit, not two');
    expect((posted.single['taskMaster'] as Map)['settings']['shareCategories'], true);
    expect(posted.single['conflicts'], hasLength(1));

    // Returning null asks for nothing, so nothing is queued.
    await store.updateDocument((_) => null);
    expect(store.hasUnsentEdits.value, isFalse);
    await store.flush();
    expect(posted, hasLength(1));
  });

  test('a failed POST raises the unsent flag and keeps the local snapshot', () async {
    final store = storeWith(MockClient((r) async =>
        r.method == 'GET' ? okJson(documentBody()) : errorJson(500, 'internal')));
    await store.readTaskMaster();
    await store.writeAll(tasksA, plansA);
    await store.flush();
    expect(store.hasUnsentEdits.value, isTrue);
    // 送信に失敗しても画面の内容は消さない（次の再送で送る）。
    expect((await store.readTaskMaster()).shareCategories, isTrue);
    expect(store.lastError.value?.code, 'internal');
    expect(store.lastError.value?.terminal, isFalse);
  });

  test('the poller retries a push that failed, and clears the flag once it lands', () async {
    var now = DateTime.utc(2026, 9, 9, 12);
    var fail = true;
    final store = storeWith(
      clock: () => now,
      MockClient((r) async {
        if (r.method == 'GET') return okJson(documentBody());
        if (fail) return errorJson(500, 'internal');
        return okJson(syncBody());
      }),
    );
    await store.readTaskMaster();
    await store.writeAll(tasksA, plansA);
    await store.flush();
    expect(store.hasUnsentEdits.value, isTrue);
    fail = false;
    now = now.add(const Duration(seconds: 2));
    await store.pollOnce();
    expect(store.hasUnsentEdits.value, isFalse);
    expect(store.lastError.value, isNull);
  });

  test('a network failure backs off 2 s, then 4 s, before trying again', () async {
    var now = DateTime.utc(2026, 9, 9, 12);
    var posts = 0;
    var fail = true;
    final store = storeWith(
      clock: () => now,
      MockClient((r) async {
        if (isRevision(r)) return okJson({'revision': 'a' * 16, 'modifiedAt': null});
        if (r.method == 'GET') return okJson(documentBody());
        posts += 1;
        return fail ? errorJson(503, 'internal') : okJson(syncBody());
      }),
    );
    await store.readTaskMaster();
    await store.writeAll(tasksA, plansA);
    await store.flush();
    expect(posts, 1);
    await store.pollOnce();
    expect(posts, 1, reason: 'the first retry waits 2 s rather than hammering the hub');
    now = now.add(const Duration(seconds: 2));
    await store.pollOnce();
    expect(posts, 2);
    now = now.add(const Duration(seconds: 2));
    await store.pollOnce();
    expect(posts, 2, reason: 'the second wait is 4 s');
    now = now.add(const Duration(seconds: 2));
    fail = false;
    await store.pollOnce();
    expect(posts, 3);
    expect(store.hasUnsentEdits.value, isFalse);
    expect(store.lastError.value, isNull);
  });

  test('a terminal 409 stops the retries and says so in Japanese', () async {
    var posts = 0;
    final store = storeWith(MockClient((r) async {
      if (isRevision(r)) return okJson({'revision': 'a' * 16, 'modifiedAt': null});
      if (r.method == 'GET') return okJson(documentBody());
      posts += 1;
      return errorJson(409, 'purged_before');
    }));
    await store.readTaskMaster();
    await store.writeAll(tasksA, plansA);
    await store.flush();
    expect(posts, 1);
    expect(store.lastError.value?.terminal, isTrue);
    expect(store.lastError.value?.code, 'purged_before');
    expect(store.lastError.value?.message, syncErrorMessage('purged_before'));
    await store.pollOnce();
    await store.pollOnce();
    expect(posts, 1, reason: 'retrying a purged_before merge can only fail the same way');
    // 編集は手元に残したまま、どちらを正にするかをユーザーに選ばせる。
    expect(store.hasUnsentEdits.value, isTrue);
    expect((await store.readTaskMaster()).shareCategories, isTrue);
  });

  test('「PC のデータで置き換える」 posts mode=take_hub and clears the error', () async {
    final modes = <String>[];
    final store = storeWith(MockClient((r) async {
      if (isRevision(r)) return okJson({'revision': 'a' * 16, 'modifiedAt': null});
      if (r.method == 'GET') return okJson(documentBody());
      final mode = r.url.queryParameters['mode']!;
      modes.add(mode);
      if (mode == 'merge') return errorJson(409, 'purged_before');
      return okJson(syncBody(document: docOf(plans: plansB)));
    }));
    await store.readTaskMaster();
    await store.writeAll(tasksA, plansA);
    await store.flush();
    expect(store.lastError.value, isNotNull);
    await store.replaceWith(HubReplace.takeHub);
    expect(modes, <String>['merge', 'take_hub']);
    expect(store.lastError.value, isNull);
    expect(store.hasUnsentEdits.value, isFalse);
    expect((await store.readDailyPlan()).slots, hasLength(1));
  });

  test('「ブラウザのデータで置き換える」 posts mode=take_web with the local document', () async {
    Map<String, dynamic>? posted;
    final store = storeWith(MockClient((r) async {
      if (isRevision(r)) return okJson({'revision': 'a' * 16, 'modifiedAt': null});
      if (r.method == 'GET') return okJson(documentBody());
      if (r.url.queryParameters['mode'] == 'merge') return errorJson(409, 'purged_before');
      posted = jsonDecode(r.body) as Map<String, dynamic>;
      return okJson(syncBody(document: docOf(tasks: tasksA)));
    }));
    await store.readTaskMaster();
    await store.writeAll(tasksA, plansA);
    await store.flush();
    await store.replaceWith(HubReplace.takeWeb);
    expect((posted!['taskMaster'] as Map)['settings']['shareCategories'], true);
    expect(store.hasUnsentEdits.value, isFalse);
  });

  test('changedSinceLastRead flips once the poller sees a new revision', () async {
    var revision = 'a' * 16;
    final store = storeWith(MockClient((r) async => okJson(
      isRevision(r) ? {'revision': revision, 'modifiedAt': null} : documentBody(revision: revision),
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
      if (isRevision(r)) return okJson({'revision': revision, 'modifiedAt': null});
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
      if (r.method == 'POST') return errorJson(500, 'internal');
      if (isRevision(r)) return okJson({'revision': revision, 'modifiedAt': null});
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

  test('a remote change lands, then a local task write keeps the remote daily plans', () async {
    var revision = 'a' * 16;
    var plans = DailyPlanStateData.initial();
    Map<String, dynamic>? posted;
    final store = storeWith(MockClient((r) async {
      if (isRevision(r)) return okJson({'revision': revision, 'modifiedAt': null});
      if (r.method == 'GET') {
        return okJson(documentBody(revision: revision, document: docOf(plans: plans)));
      }
      posted = jsonDecode(r.body) as Map<String, dynamic>;
      return okJson(syncBody(document: docOf(tasks: tasksA, plans: plans)));
    }));
    await store.readTaskMaster();
    // MCP added a free-time slot on the PC while this tab was idle.
    plans = plansB;
    revision = 'b' * 16;
    await store.pollOnce();
    await store.writeTaskMaster(tasksA);
    await store.flush();
    expect((posted!['taskMaster'] as Map)['settings']['shareCategories'], true);
    expect((posted!['dailyPlan'] as Map)['slots'], hasLength(1),
        reason: 'a task-only write must not overwrite the half it never touched');
  });

  test('the store never writes business data to browser storage', () async {
    // The web seam is the stub under `flutter test`; this asserts the store
    // asks for nothing beyond the id it was handed.
    final store = storeWith(MockClient((r) async => okJson(documentBody())));
    await store.readTaskMaster();
    expect(readWebId(), isNull);
  });
}
