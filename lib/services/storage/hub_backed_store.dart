import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/device_clock.dart';
import '../../features/daily_plan/domain/daily_plan_models.dart';
import '../../features/task_master/domain/task_models.dart';
import '../hub_mode/hub_mode.dart';
import '../sync/document_clocks.dart';
import '../sync/lan_sync_types.dart' show syncErrorMessage;
import '../sync/sync_document.dart';
import 'state_store.dart';

/// Which side wins when the hub refuses to merge at all.
enum HubReplace { takeHub, takeWeb }

extension HubReplaceWire on HubReplace {
  /// The `mode` query value the hub understands.
  String get wire => switch (this) {
    HubReplace.takeHub => 'take_hub',
    HubReplace.takeWeb => 'take_web',
  };
}

/// A push that failed, in the shape the hub card needs to draw it.
///
/// [terminal] is the whole point of the class: a 500 or a dropped connection
/// is worth retrying forever, while `purged_before` or `upgrade_required`
/// will fail identically every two seconds until a person chooses a side.
@immutable
class HubError {
  const HubError({
    required this.status,
    required this.code,
    required this.message,
    required this.terminal,
  });

  /// HTTP status, or 0 when the request never produced one.
  final int status;
  final String code;

  /// Japanese, ready to put on screen.
  final String message;

  /// True when retrying unchanged can only fail the same way.
  final bool terminal;

  @override
  String toString() => '$code ($status): $message';
}

/// A [StateStore] that lives directly on the hub's `data.json`.
///
/// Reads answer from the last fetched snapshot; writes update that snapshot and
/// are pushed to `POST /api/sync?mode=merge` after a short debounce, so a burst
/// of edits is one request and MCP's concurrent edits come back already merged.
///
/// Nothing is persisted in the browser. That is the deliberate half of the
/// design: a local copy would have to be merged against whatever MCP did while
/// the tab was closed, which is exactly the three-way merge this mode exists to
/// avoid. The browser keeps two things only — the web id and the HLC clock, both
/// identity rather than business data. The price is that an unsent edit dies
/// with the tab, so [hasUnsentEdits] drives a banner and a `beforeunload` guard.
class HubBackedStore extends StateStore {
  HubBackedStore({
    required this.hub,
    required this.webId,
    http.Client? client,
    this.debounce = const Duration(milliseconds: 400),
    this.pollInterval = const Duration(seconds: 2),
    this.deviceClock,
    String? origin,
    DateTime Function()? clock,
  }) : _client = client ?? http.Client(),
       _now = clock ?? DateTime.now,
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

  /// Injected so the retry backoff can be tested without waiting real seconds.
  final DateTime Function() _now;

  /// True while an edit has not reached the hub. The app draws a red banner and
  /// registers a `beforeunload` handler while this is set.
  final ValueNotifier<bool> hasUnsentEdits = ValueNotifier<bool>(false);

  /// The last push failure, or null once a push lands. The hub card shows the
  /// message, and offers the two replace buttons when it is [HubError.terminal].
  final ValueNotifier<HubError?> lastError = ValueNotifier<HubError?>(null);

  /// When the hub last accepted this browser's document, for the settings screen.
  DateTime? lastSavedAt;

  SyncDocument? _snapshot;
  String? _knownRevision;

  /// The hub holds something this browser has not adopted: the next read has to
  /// refetch rather than answer from the snapshot.
  bool _remoteChanged = false;

  /// The screen is behind the snapshot — because the poller saw a new revision,
  /// or because a merge came back carrying work this browser never sent.
  bool _uiStale = false;
  bool _dirty = false;
  String? _lastWarning;

  /// Bumped by every local write. A push captures it before the request and
  /// compares afterwards: a different value means an edit landed mid-flight and
  /// the answer must not be adopted over it.
  int _gen = 0;

  Duration _backoff = Duration.zero;
  DateTime? _retryAt;

  Timer? _debounceTimer;
  Timer? _pollTimer;
  Future<void>? _inFlight;
  bool _resend = false;
  bool _visible = true;
  void Function()? _onRemoteChange;
  void Function()? _removeVisibilityListener;
  void Function()? _removeUnloadGuard;

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
    if (snapshot != null && (!_remoteChanged || _dirty)) {
      _uiStale = false;
      return snapshot;
    }
    return _fetch();
  }

  Future<SyncDocument> _fetch() async {
    final response = await _client.get(_url('document'), headers: _headers);
    final body = _decode(response);
    final document = SyncDocument.fromJson(body['document'] as Map<String, dynamic>, strict: true);
    _knownRevision = body['revision'] as String?;
    _remoteChanged = false;
    _uiStale = false;
    await _adopt(document);
    return document;
  }

  Future<void> _adopt(SyncDocument document) async {
    _snapshot = document;
    await _observe(document);
  }

  /// Pulls the HLC up to the document's clocks without touching the snapshot:
  /// used when the answer must be learned from but not adopted.
  Future<void> _observe(SyncDocument document) async {
    final clock = deviceClock;
    if (clock != null) await observeDocumentClocks(clock, document);
  }

  // --- writes ------------------------------------------------------------

  /// Writes only the task half, on top of whatever document is current.
  ///
  /// [_document] is what makes that "current": if the poller has just seen the
  /// hub move on, this refetches first, so the daily plans that came with the
  /// remote change are the ones carried forward rather than the stale copy.
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
      exportedAt: _now().toUtc(),
    );
    _gen += 1;
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
    if (!_dirty) return;
    // A terminal refusal will refuse the same document identically; the edit
    // stays here until a person picks a side in the hub card.
    if (lastError.value?.terminal ?? false) return;
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

  SyncDocument _payload(SyncDocument snapshot) => SyncDocument(
    exportedAt: _now().toUtc(),
    // `web-<webId>`, matching the id the hub derives from the header.
    deviceId: 'web-$webId',
    lastSyncAt: snapshot.lastSyncAt,
    purgedBefore: snapshot.purgedBefore,
    taskMaster: snapshot.taskMaster,
    dailyPlan: snapshot.dailyPlan,
  );

  Future<Map<String, dynamic>> _post(String mode, SyncDocument payload) async {
    final response = await _client.post(
      _url('sync', <String, String>{'mode': mode}),
      headers: <String, String>{..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode(payload.toJson()),
    );
    return _decode(response);
  }

  /// The two halves that actually matter, for "did the hub answer with
  /// something other than what we sent?". Timestamps and the device id differ
  /// on every round trip and say nothing about the content.
  String _bodyOf(SyncDocument document) => jsonEncode(<String, dynamic>{
    'taskMaster': document.taskMaster.toJson(),
    'dailyPlan': document.dailyPlan.toJson(),
  });

  Future<void> _push() async {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    final sentGen = _gen;
    final payload = _payload(snapshot);
    try {
      final body = await _post('merge', payload);
      final merged = SyncDocument.fromJson(body['document'] as Map<String, dynamic>, strict: true);
      final warnings = (body['warnings'] as List<dynamic>? ?? const <dynamic>[]).cast<String>();
      _lastWarning = warnings.isEmpty ? null : warnings.first;
      lastError.value = null;
      _backoff = Duration.zero;
      _retryAt = null;
      lastSavedAt = _now();
      // The hub answered with something else: MCP or another browser got in
      // first and the merge brought their work back. The screen is behind it
      // whichever way the snapshot goes below.
      final diverged = _bodyOf(merged) != _bodyOf(payload);
      if (_gen != sentGen) {
        // An edit landed while the request was open. Adopting the answer would
        // throw it away, and no other copy of it exists — so keep the local
        // document, learn the clocks, and go round again with both edits.
        await _observe(merged);
        _resend = true;
      } else {
        await _adopt(merged);
        _dirty = false;
        hasUnsentEdits.value = false;
      }
      if (diverged) {
        _uiStale = true;
        _onRemoteChange?.call();
      }
      // The answer carries no revision, and guessing one would make the very
      // next poll look like someone else's edit.
      await _refreshRevision(flagChanges: false);
    } catch (error) {
      // The snapshot is kept: it is the only copy of the user's edit, and the
      // poller retries it once the backoff is up.
      _recordFailure(error);
    }
  }

  /// Resolves a terminal refusal by letting one side win outright.
  ///
  /// Both directions throw work away, which is why the screen puts a confirm
  /// dialog in front of each: `takeHub` drops this browser's unsent edit,
  /// `takeWeb` drops whatever the PC has (including anything a phone synced).
  Future<void> replaceWith(HubReplace choice) async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    await _inFlight;
    final payload = _payload(_snapshot ?? await _fetch());
    try {
      final body = await _post(choice.wire, payload);
      await _adopt(SyncDocument.fromJson(body['document'] as Map<String, dynamic>, strict: true));
      _dirty = false;
      _resend = false;
      _gen += 1;
      _lastWarning = null;
      lastError.value = null;
      _backoff = Duration.zero;
      _retryAt = null;
      hasUnsentEdits.value = false;
      lastSavedAt = _now();
      _remoteChanged = false;
      // Whichever side won, the screen is showing the losing one.
      _uiStale = true;
      _onRemoteChange?.call();
      await _refreshRevision(flagChanges: false);
    } catch (error) {
      _recordFailure(error);
      rethrow;
    }
  }

  /// Terminal for anything the hub refused on its merits (4xx), retryable for
  /// anything that looks like weather: no connection, a 5xx, a timeout, a 429.
  static bool _isTerminal(int status) =>
      status >= 400 && status < 500 && status != 408 && status != 429;

  void _recordFailure(Object error) {
    final api = error is HubApiException ? error : null;
    final status = api?.status ?? 0;
    final code = api?.code ?? 'unreachable';
    final terminal = _isTerminal(status);
    lastError.value = HubError(
      status: status,
      code: code,
      terminal: terminal,
      message: syncErrorMessage(code, fallback: 'PC に保存できませんでした（$code）。'),
    );
    hasUnsentEdits.value = true;
    if (terminal) {
      _backoff = Duration.zero;
      _retryAt = null;
      return;
    }
    _backoff = _backoff == Duration.zero
        ? const Duration(seconds: 2)
        : Duration(seconds: math.min(30, _backoff.inSeconds * 2));
    _retryAt = _now().add(_backoff);
  }

  // --- polling -----------------------------------------------------------

  @override
  Future<bool> changedSinceLastRead() async => _uiStale;

  /// One `/api/revision` round trip. Doubles as the retry for a failed push:
  /// the tick that notices the hub moved on is also the moment to try again —
  /// unless the backoff says to wait, or the failure was terminal.
  Future<void> pollOnce() async {
    await _refreshRevision(flagChanges: true);
    if (!_dirty) return;
    if (lastError.value?.terminal ?? false) return;
    final retryAt = _retryAt;
    if (retryAt != null && _now().isBefore(retryAt)) return;
    await _send();
  }

  Future<void> _refreshRevision({required bool flagChanges}) async {
    try {
      final response = await _client.get(_url('revision'), headers: _headers);
      final revision = _decode(response)['revision'] as String?;
      if (revision == null) return;
      if (flagChanges && _knownRevision != null && revision != _knownRevision) {
        _remoteChanged = true;
        _uiStale = true;
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
    _removeVisibilityListener = addVisibilityListener((visible) {
      _visible = visible;
      // Coming back to a tab that has been hidden for a while: ask straight
      // away rather than waiting out the interval.
      if (visible) unawaited(pollOnce());
    });
    _removeUnloadGuard = setUnloadGuard(() => hasUnsentEdits.value);
    _pollTimer = Timer.periodic(pollInterval, (_) {
      if (_visible) unawaited(pollOnce());
    });
  }

  void dispose() {
    _debounceTimer?.cancel();
    _pollTimer?.cancel();
    // Both listeners close over this store; leaving them on `document` and
    // `window` would keep it (and its http client) alive for the tab's life.
    _removeVisibilityListener?.call();
    _removeVisibilityListener = null;
    _removeUnloadGuard?.call();
    _removeUnloadGuard = null;
    _onRemoteChange = null;
    hasUnsentEdits.dispose();
    lastError.dispose();
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
