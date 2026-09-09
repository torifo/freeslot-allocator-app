import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/device_clock.dart';
import '../../features/daily_plan/domain/daily_plan_models.dart';
import '../../features/task_master/domain/task_models.dart';
import '../hub_mode/hub_mode.dart';
import '../sync/document_clocks.dart';
import '../sync/sync_document.dart';
import 'state_store.dart';

/// A [StateStore] that lives directly on the hub's `data.json`.
///
/// Reads answer from the last fetched snapshot; writes update that snapshot and
/// are pushed to `POST /api/sync?mode=merge` after a short debounce, so a burst
/// of edits is one request and MCP's concurrent edits come back already merged.
///
/// Nothing is persisted in the browser. That is the deliberate half of the
/// design: a local copy would have to be merged against whatever MCP did while
/// the tab was closed, which is exactly the three-way merge this mode exists to
/// avoid. The price is that an unsent edit dies with the tab, so
/// [hasUnsentEdits] drives a banner and a `beforeunload` guard.
class HubBackedStore extends StateStore {
  HubBackedStore({
    required this.hub,
    required this.webId,
    http.Client? client,
    this.debounce = const Duration(milliseconds: 400),
    this.pollInterval = const Duration(seconds: 2),
    this.deviceClock,
    String? origin,
  }) : _client = client ?? http.Client(),
       _origin = _originOf(origin);

  /// Under `flutter test` there is no browser to ask, and every request goes to
  /// a `MockClient` anyway; the host only has to make the URL absolute.
  static String _originOf(String? given) {
    final origin = given ?? readOrigin() ?? '';
    return origin.isEmpty ? 'http://localhost' : origin;
  }

  final HubMode hub;

  /// 16 hex characters; the hub turns it into the device id `web-<webId>`.
  final String webId;
  final Duration debounce;
  final Duration pollInterval;

  /// Present in the app, absent in tests: the HLC has to be pulled up to
  /// whatever the hub has seen before this browser stamps its next edit.
  final DeviceClock? deviceClock;

  final http.Client _client;
  final String _origin;

  /// True while an edit has not reached the hub. The app draws a red banner and
  /// registers a `beforeunload` handler while this is set.
  final ValueNotifier<bool> hasUnsentEdits = ValueNotifier<bool>(false);

  /// When the hub last accepted this browser's document, for the settings screen.
  DateTime? lastSavedAt;

  SyncDocument? _snapshot;
  String? _knownRevision;
  bool _remoteChanged = false;
  bool _dirty = false;
  String? _lastWarning;

  Timer? _debounceTimer;
  Timer? _pollTimer;
  Future<void>? _inFlight;
  bool _resend = false;
  bool _visible = true;
  void Function()? _onRemoteChange;

  @override
  String? get lastWarning => _lastWarning;

  Map<String, String> get _headers => <String, String>{'X-FRELOCATOR-Web-Id': webId};

  Uri _url(String route, [Map<String, String>? query]) {
    final url = Uri.parse('$_origin${hub.api}$route');
    return query == null ? url : url.replace(queryParameters: query);
  }

  // --- reads -------------------------------------------------------------

  @override
  Future<TaskMasterStateData> readTaskMaster() async => (await _document()).taskMaster;

  @override
  Future<DailyPlanStateData> readDailyPlan() async => (await _document()).dailyPlan;

  /// The snapshot, refetched only when the poller saw someone else write and
  /// this browser has nothing of its own to lose.
  Future<SyncDocument> _document() async {
    final snapshot = _snapshot;
    if (snapshot != null && (!_remoteChanged || _dirty)) return snapshot;
    return _fetch();
  }

  Future<SyncDocument> _fetch() async {
    final response = await _client.get(_url('document'), headers: _headers);
    final body = _decode(response);
    final document = SyncDocument.fromJson(body['document'] as Map<String, dynamic>, strict: true);
    _knownRevision = body['revision'] as String?;
    _remoteChanged = false;
    await _adopt(document);
    return document;
  }

  Future<void> _adopt(SyncDocument document) async {
    _snapshot = document;
    final clock = deviceClock;
    if (clock != null) await observeDocumentClocks(clock, document);
  }

  // --- writes ------------------------------------------------------------

  @override
  Future<void> writeTaskMaster(TaskMasterStateData state) async =>
      writeAll(state, (await _document()).dailyPlan);

  @override
  Future<void> writeDailyPlan(DailyPlanStateData state) async =>
      writeAll((await _document()).taskMaster, state);

  /// Deliberately reaches its first `await` only when there is no snapshot yet:
  /// a caller that fires two edits and then [flush]es must find both of them
  /// already folded into the pending document, not still in a microtask queue.
  @override
  Future<void> writeAll(TaskMasterStateData tasks, DailyPlanStateData plans) async {
    final snapshot = _snapshot ?? await _fetch();
    _snapshot = snapshot.copyWith(
      taskMaster: tasks,
      dailyPlan: plans,
      exportedAt: DateTime.now().toUtc(),
    );
    _dirty = true;
    hasUnsentEdits.value = true;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () {
      _debounceTimer = null;
      unawaited(_send());
    });
  }

  /// Sends any pending edit now (tests and the unload path use it).
  Future<void> flush() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (_dirty) {
      await _send();
    } else {
      await _inFlight;
    }
  }

  /// Single-flight: a second caller does not open a second request, it asks the
  /// one in flight to go round again. Two overlapping POSTs of the same
  /// document would make the hub merge this browser against itself.
  Future<void> _send() async {
    if (_inFlight != null) {
      _resend = true;
      await _inFlight;
      return;
    }
    final completer = Completer<void>();
    _inFlight = completer.future;
    try {
      do {
        _resend = false;
        await _push();
      } while (_resend);
    } finally {
      _inFlight = null;
      completer.complete();
    }
  }

  Future<void> _push() async {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    final payload = SyncDocument(
      exportedAt: DateTime.now().toUtc(),
      // `web-<webId>`, matching the id the hub derives from the header.
      deviceId: 'web-$webId',
      lastSyncAt: snapshot.lastSyncAt,
      purgedBefore: snapshot.purgedBefore,
      taskMaster: snapshot.taskMaster,
      dailyPlan: snapshot.dailyPlan,
    );
    try {
      final response = await _client.post(
        _url('sync', <String, String>{'mode': 'merge'}),
        headers: <String, String>{..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode(payload.toJson()),
      );
      final body = _decode(response);
      await _adopt(SyncDocument.fromJson(body['document'] as Map<String, dynamic>, strict: true));
      final warnings = (body['warnings'] as List<dynamic>? ?? const <dynamic>[]).cast<String>();
      _lastWarning = warnings.isEmpty ? null : warnings.first;
      _dirty = false;
      hasUnsentEdits.value = false;
      lastSavedAt = DateTime.now();
      // The answer carries no revision, and guessing one would make the very
      // next poll look like someone else's edit.
      await _refreshRevision(flagChanges: false);
    } catch (error) {
      // The snapshot is kept: it is the only copy of the user's edit, and the
      // poller retries it on the next tick.
      _lastWarning = 'PC に保存できていません（$error）';
      hasUnsentEdits.value = true;
    }
  }

  // --- polling -----------------------------------------------------------

  @override
  Future<bool> changedSinceLastRead() async => _remoteChanged;

  /// One `/api/revision` round trip. Doubles as the retry for a failed push:
  /// the tick that notices the hub moved on is also the moment to try again.
  Future<void> pollOnce() async {
    await _refreshRevision(flagChanges: true);
    if (_dirty) await _send();
  }

  Future<void> _refreshRevision({required bool flagChanges}) async {
    try {
      final response = await _client.get(_url('revision'), headers: _headers);
      final revision = _decode(response)['revision'] as String?;
      if (revision == null) return;
      if (flagChanges && _knownRevision != null && revision != _knownRevision) {
        _remoteChanged = true;
        _onRemoteChange?.call();
      }
      _knownRevision = revision;
    } catch (_) {
      // A dropped request is not news: the next tick asks again.
    }
  }

  /// Starts the 2 s poll, pauses it while the tab is hidden and arms the
  /// unload guard. Called by the app, never by tests.
  void startPolling({void Function()? onRemoteChange}) {
    _onRemoteChange = onRemoteChange;
    if (_pollTimer != null) return;
    _visible = documentVisible();
    addVisibilityListener((visible) {
      _visible = visible;
      // Coming back to a tab that has been hidden for a while: ask straight
      // away rather than waiting out the interval.
      if (visible) unawaited(pollOnce());
    });
    setUnloadGuard(() => hasUnsentEdits.value);
    _pollTimer = Timer.periodic(pollInterval, (_) {
      if (_visible) unawaited(pollOnce());
    });
  }

  void dispose() {
    _debounceTimer?.cancel();
    _pollTimer?.cancel();
    hasUnsentEdits.dispose();
    _client.close();
  }

  /// Turns a non-200 into the hub's own `{error:{code,message}}` wording, so
  /// the banner says what the hub said instead of "500".
  Map<String, dynamic> _decode(http.Response response) {
    Map<String, dynamic>? body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      body = null;
    }
    if (response.statusCode != 200) {
      final error = body?['error'];
      throw HubApiException(
        response.statusCode,
        error is Map<String, dynamic> ? error['code'] as String? ?? 'error' : 'error',
        error is Map<String, dynamic> ? error['message'] as String? ?? '' : response.reasonPhrase ?? '',
      );
    }
    if (body == null) throw HubApiException(response.statusCode, 'bad_response', 'the hub answered with something other than JSON');
    return body;
  }
}

/// The hub refused or failed a request; the message is the hub's own.
class HubApiException implements Exception {
  const HubApiException(this.status, this.code, this.message);

  final int status;
  final String code;
  final String message;

  @override
  String toString() => '$code ($status): $message';
}
