# FRELOCATOR Hub Sync — Plan 2b: アプリ側 同期 UI・LAN クライアント・QR 受信・ファイル書き出し・MCP 案内・リリース

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flutter アプリに「PC と同期」画面を追加し、ハブ（Plan 2a）との LAN 同期（証明書ピン留め、ペアリング QR、進捗パネル、置き換えフロー）、ネットワーク不一致時の QR 受信、スマホ→PC のファイル書き出し、macOS 版での Claude Code（MCP）設定案内とファイル取り込みを実装する。あわせてプライバシーポリシー・権限・バージョンを更新し、Play のクローズドテストへ提出できる状態にする。

**Architecture:** `lib/services/sync/` に純 Dart のロジック（`SyncSettings`、`SyncProgress`、`LanSyncClient`、`SyncService`、`QrChunkCodec`、`FileExporter`）を置き、`lib/features/sync/presentation/` に画面（`SyncSettingsScreen`、`PairingScanScreen`、`QrReceiveScreen`、`SyncProgressPanel`）を置く。マージは Plan 1 の `SyncMerger` を再利用し、ハブの `/sync` 応答をそのまま `AppDataService.importDocument` で適用する。表示は既存画面の Material 構成（`Scaffold` + `AppBar` + Riverpod）に合わせる。

**Tech Stack:** Flutter 3 / Dart 3、`http`（`IOClient` + `HttpClient.badCertificateCallback` でピン留め）、`mobile_scanner`、`archive`（gzip）、`share_plus`、`file_picker`、`multicast_dns`、`crypto`、`shared_preferences`。

**設計書:** `docs/superpowers/specs/2026-09-08-frelocator-hub-sync-design.md`。ハブ側の HTTP 形式は Plan 2a に従う: `POST /pair {code, deviceId, name} → {token, hubDeviceId, fingerprint}`、`GET/POST /sync?mode=merge|take_hub|take_phone → {document, summary, warnings}`（`summary` は `{added, updated, deleted, removed, warnings}`。`removed` はハブが墓標ごと捨てた件数で、墓標として残る `deleted` とは別に数える）、`GET /health → {ok, serverTime, schema}`（`HEAD /health` も可）、エラー `{error:{code,message}}`（401 unauthorized、403 pairing_failed、409 purged_before、413 payload_too_large、426 upgrade_required）。

`POST /pair` のボディ上限は **8 KB**（`/sync` は 20 MB）で、フィールド長は `code` ≤ 64 文字、`deviceId` / `name` ≤ 128 文字。超過は `400 bad_request`、ボディ超過は `413 payload_too_large`。**413 応答はハブがボディを読み切らずに返すため `Connection: close` が付き、その接続は再利用できない**。クライアントは 413 を受けたら接続を張り直す（`IOClient` を使い回している場合は同一ソケットへの続けざまの送信を避ける）。

---

## ファイル構成

- Modify `pubspec.yaml` — 依存追加。
- Modify `android/app/src/main/AndroidManifest.xml` — `INTERNET`、`CAMERA`。
- Create `lib/services/sync/sync_settings.dart` — `SyncSettings`（host/port/fingerprint/token/hubDeviceId/lastSyncAt/deviceName）と `SyncSettingsStore`（SharedPreferences）。
- Create `lib/services/sync/sync_progress.dart` — `SyncStage`、`SyncProgress`、`SyncProgressController`（経過秒、バイト数、キャンセル）。
- Create `lib/services/sync/lan_sync_client.dart` — `LanSyncClient`（ピン留め、pair/health/getSync/postSync、進捗コールバック、キャンセル）。`SyncHttpException(status, code, message)`。
- Create `lib/services/sync/sync_service.dart` — `SyncService`（export → post → apply）。`SyncOutcome`。
- Create `lib/services/sync/qr_chunk_codec.dart` — base45、crc32、`QrFrameSet`、`decodeQrFrames`。
- Create `lib/services/sync/file_exporter.dart` — JSON を一時ファイルに書いて共有シートへ。macOS はファイル選択→マージ取り込み。
- Create `lib/services/sync/hub_discovery.dart` — mDNS で `_frelocator._tcp` を探す（任意フォールバック）。`dart:io` の有無で `hub_discovery_io.dart` / `hub_discovery_stub.dart` に条件付きエクスポートで分岐する（Web は常に `null`）。
- Create `lib/services/sync/sync_backup_store.dart` — 置き換え直前の全書き出しを `sync_backup_v1`（SharedPreferences）に 1 件だけ保持する。
- Create `lib/features/sync/presentation/sync_settings_screen.dart`、`pairing_scan_screen.dart`、`qr_receive_screen.dart`、`sync_progress_panel.dart`、`mcp_guide_section.dart`。
- Modify `lib/app/router.dart` — `/sync`、`/sync/pair`、`/sync/qr`。
- Modify `lib/features/home/presentation/home_screen.dart` と `lib/features/task_master/presentation/category_settings_screen.dart` — 「PC と同期」への導線。
- Modify `lib/app/app.dart` — 保存中／ダイアログ表示中は再読み込みを遅延。
- Modify `web/privacy.html`、`web/support.html`、`README.md`、`docs/android_store_assets_checklist.md`。
- Tests: `test/services/sync/{sync_settings_test,sync_progress_test,lan_sync_client_test,lan_sync_client_tls_test,sync_service_test,qr_chunk_codec_test,file_exporter_test}.dart`、`test/services/app_data_service_test.dart`、`test/fixtures/tls/{hub_cert,hub_key}.pem`、`test/features/sync/sync_settings_screen_test.dart`。
- Cross-language fixture: `tools/hub/test/fixtures/qr/sample.frames.json`（Plan 2a の `encodeFrames` で生成した固定フレーム）を Dart 側の codec テストが読む。

---

### Task 1: 依存・権限・SyncSettingsStore

**Files:**
- Modify: `pubspec.yaml`、`android/app/src/main/AndroidManifest.xml`
- Create: `lib/services/sync/sync_settings.dart`
- Test: `test/services/sync/sync_settings_test.dart`

- [ ] **Step 1: 依存と権限を追加する**

`pubspec.yaml` の `dependencies:` に追加:

```yaml
  http: ^1.2.2
  mobile_scanner: ^7.0.0
  archive: ^4.0.4
  share_plus: ^11.0.0
  file_picker: ^10.1.9
  multicast_dns: ^0.3.2+7
  path_provider: ^2.1.5
```

`flutter pub get`。バージョンが解決できない場合は `flutter pub add <pkg>` で最新安定版にし、報告に記す。

`AndroidManifest.xml` の `<manifest>` 直下、`<application>` の前に:

```xml
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.CAMERA" />
    <uses-feature android:name="android.hardware.camera" android:required="false" />
```

`usesCleartextTraffic` は追加しない（HTTPS のみ）。

- [ ] **Step 2: 失敗するテストを書く**

```dart
// test/services/sync/sync_settings_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/services/sync/sync_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('round-trips settings and reports pairing state', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final store = SyncSettingsStore();
    expect((await store.load()).isPaired, isFalse);
    final s = SyncSettings(host: '192.168.1.10', port: 47820, fingerprint: 'AB' * 32, token: 'f' * 64, hubDeviceId: 'hub-macos', deviceName: 'Pixel 8', lastSyncAt: null);
    await store.save(s);
    final back = await store.load();
    expect(back.isPaired, isTrue);
    expect(back.baseUrl, 'https://192.168.1.10:47820');
    await store.save(back.copyWith(lastSyncAt: DateTime.utc(2026, 9, 9)));
    expect((await store.load()).lastSyncAt, DateTime.utc(2026, 9, 9));
    await store.clear();
    expect((await store.load()).isPaired, isFalse);
  });

  test('parses a pairing URL', () {
    final p = PairingInfo.parse('frelocator://pair?host=192.168.1.10&port=47820&fp=${'AB' * 32}&code=K7Q2M9XZ');
    expect(p.host, '192.168.1.10');
    expect(p.port, 47820);
    expect(p.fingerprint, 'AB' * 32);
    expect(p.code, 'K7Q2M9XZ');
    expect(() => PairingInfo.parse('https://example.com'), throwsFormatException);
    expect(() => PairingInfo.parse('frelocator://pair?host=x&port=1&fp=short&code=1'), throwsFormatException);
  });
}
```

- [ ] **Step 3: 失敗を確認する**

Run: `flutter test test/services/sync/sync_settings_test.dart`
Expected: FAIL

- [ ] **Step 4: 実装する**

```dart
// lib/services/sync/sync_settings.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final syncSettingsStoreProvider = Provider<SyncSettingsStore>((ref) => SyncSettingsStore());

/// What the phone remembers about its paired hub.
class SyncSettings {
  const SyncSettings({this.host, this.port = 47820, this.fingerprint, this.token, this.hubDeviceId, this.deviceName = '', this.lastSyncAt});

  final String? host;
  final int port;
  final String? fingerprint;
  final String? token;
  final String? hubDeviceId;
  final String deviceName;
  final DateTime? lastSyncAt;

  bool get isPaired => host != null && fingerprint != null && token != null;
  String get baseUrl => 'https://$host:$port';

  SyncSettings copyWith({String? host, int? port, String? fingerprint, String? token, String? hubDeviceId, String? deviceName, DateTime? lastSyncAt, bool clearLastSync = false}) => SyncSettings(
        host: host ?? this.host, port: port ?? this.port, fingerprint: fingerprint ?? this.fingerprint, token: token ?? this.token,
        hubDeviceId: hubDeviceId ?? this.hubDeviceId, deviceName: deviceName ?? this.deviceName,
        lastSyncAt: clearLastSync ? null : (lastSyncAt ?? this.lastSyncAt),
      );
}

/// Parsed `frelocator://pair?host=…&port=…&fp=…&code=…`.
class PairingInfo {
  const PairingInfo({required this.host, required this.port, required this.fingerprint, required this.code});
  final String host; final int port; final String fingerprint; final String code;

  static PairingInfo parse(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'frelocator' || uri.host != 'pair') throw const FormatException('ペアリング用の QR ではありません');
    final q = uri.queryParameters;
    final host = q['host'] ?? ''; final port = int.tryParse(q['port'] ?? ''); final fp = (q['fp'] ?? '').toUpperCase(); final code = q['code'] ?? '';
    if (host.isEmpty || port == null || !RegExp(r'^[0-9A-F]{64}$').hasMatch(fp) || code.isEmpty) throw const FormatException('ペアリング情報が不完全です');
    return PairingInfo(host: host, port: port, fingerprint: fp, code: code);
  }
}

class SyncSettingsStore {
  static const _k = 'sync_settings_v1';

  Future<SyncSettings> load() async {
    final p = await SharedPreferences.getInstance();
    final host = p.getString('$_k.host');
    return SyncSettings(
      host: host, port: p.getInt('$_k.port') ?? 47820, fingerprint: p.getString('$_k.fp'), token: p.getString('$_k.token'),
      hubDeviceId: p.getString('$_k.hub'), deviceName: p.getString('$_k.name') ?? '',
      lastSyncAt: DateTime.tryParse(p.getString('$_k.lastSyncAt') ?? '')?.toUtc(),
    );
  }

  Future<void> save(SyncSettings s) async {
    final p = await SharedPreferences.getInstance();
    Future<void> put(String key, String? v) => v == null ? p.remove('$_k.$key') : p.setString('$_k.$key', v);
    await put('host', s.host); await p.setInt('$_k.port', s.port); await put('fp', s.fingerprint); await put('token', s.token);
    await put('hub', s.hubDeviceId); await put('name', s.deviceName); await put('lastSyncAt', s.lastSyncAt?.toUtc().toIso8601String());
  }

  Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    for (final key in ['host', 'port', 'fp', 'token', 'hub', 'name', 'lastSyncAt']) { await p.remove('$_k.$key'); }
  }
}
```

トークンは shared_preferences に平文で置く（端末内、アプリサンドボックス）。設計書に「端末別トークンは端末内保存」と追記する。

- [ ] **Step 5: テストを通す・コミット**

Run: `flutter analyze && flutter test test/services/sync/sync_settings_test.dart`

```bash
git add pubspec.yaml pubspec.lock android/app/src/main/AndroidManifest.xml lib/services/sync/sync_settings.dart test/services/sync/sync_settings_test.dart
git commit -m "feat(sync): sync settings store, pairing URL parser, network and camera permissions / 同期設定と権限"
```

---

### Task 2: SyncProgress（段階・経過時間・キャンセル）

**Files:**
- Create: `lib/services/sync/sync_progress.dart`
- Test: `test/services/sync/sync_progress_test.dart`

- [ ] **Step 1: 失敗するテストを書く**

```dart
// test/services/sync/sync_progress_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/services/sync/sync_progress.dart';

void main() {
  test('advances stages, tracks bytes and elapsed, and flags slow stages', () {
    var now = DateTime.utc(2026, 1, 1);
    final c = SyncProgressController(now: () => now);
    c.start(SyncKind.lan);
    expect(c.value.stage, SyncStage.connecting);
    c.stage(SyncStage.sending, totalBytes: 1000);
    c.bytes(400);
    expect(c.value.sentBytes, 400);
    expect(c.value.fraction, closeTo(0.4, 0.001));
    now = now.add(const Duration(seconds: 11));
    expect(c.value.elapsed(now).inSeconds, 11);
    expect(c.value.isSlow(now), isTrue);
    c.stage(SyncStage.applying);
    c.finish(const SyncSummary(added: 1, updated: 2, deleted: 0, warnings: 0));
    expect(c.value.stage, SyncStage.done);
    expect(c.value.summary?.updated, 2);
  });

  test('cancel before send completes is clean; after send is flagged', () {
    final c = SyncProgressController();
    c.start(SyncKind.lan);
    c.stage(SyncStage.sending);
    c.cancel();
    expect(c.value.stage, SyncStage.cancelled);
    expect(c.value.hubMayHaveChanged, isFalse);
    c.start(SyncKind.lan);
    c.stage(SyncStage.waitingHub);
    c.cancel();
    expect(c.value.hubMayHaveChanged, isTrue);
    expect(c.isCancelled, isTrue);
  });

  test('fail records the error code', () {
    final c = SyncProgressController();
    c.start(SyncKind.qr);
    c.fail('unreachable', 'PC が見つかりません');
    expect(c.value.stage, SyncStage.failed);
    expect(c.value.errorCode, 'unreachable');
  });

  test('qr frames progress', () {
    final c = SyncProgressController();
    c.start(SyncKind.qr);
    c.frames(received: 3, total: 10, missing: [0, 4, 5, 6, 7, 8, 9]);
    expect(c.value.fraction, closeTo(0.3, 0.001));
    expect(c.value.missingFrames, hasLength(7));
  });
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/services/sync/sync_progress_test.dart`
Expected: FAIL

- [ ] **Step 3: 実装する**

```dart
// lib/services/sync/sync_progress.dart
import 'package:flutter/foundation.dart';

enum SyncKind { lan, qr, file }
enum SyncStage { idle, connecting, sending, waitingHub, receiving, applying, saving, done, cancelled, failed, scanning, decoding }

class SyncSummary {
  const SyncSummary({required this.added, required this.updated, required this.deleted, required this.warnings});
  final int added; final int updated; final int deleted; final int warnings;
  factory SyncSummary.fromJson(Map<String, dynamic> j) => SyncSummary(added: j['added'] as int? ?? 0, updated: j['updated'] as int? ?? 0, deleted: j['deleted'] as int? ?? 0, warnings: j['warnings'] as int? ?? 0);
}

/// Immutable snapshot the UI renders. Only measurable stages carry numbers.
class SyncProgress {
  const SyncProgress({
    required this.kind, required this.stage, required this.startedAt, this.stageStartedAt,
    this.sentBytes = 0, this.totalBytes, this.receivedBytes = 0, this.framesReceived = 0, this.framesTotal = 0, this.missingFrames = const [],
    this.summary, this.errorCode, this.errorMessage, this.hubMayHaveChanged = false,
  });

  final SyncKind kind; final SyncStage stage; final DateTime startedAt; final DateTime? stageStartedAt;
  final int sentBytes; final int? totalBytes; final int receivedBytes;
  final int framesReceived; final int framesTotal; final List<int> missingFrames;
  final SyncSummary? summary; final String? errorCode; final String? errorMessage;
  /// True when cancel happened after the request was fully sent: the hub may already hold the merge.
  final bool hubMayHaveChanged;

  static const slowAfter = Duration(seconds: 10);

  Duration elapsed(DateTime now) => now.difference(startedAt);
  bool isSlow(DateTime now) => stage != SyncStage.done && stage != SyncStage.failed && stage != SyncStage.cancelled && elapsed(now) > slowAfter;
  double? get fraction {
    if (stage == SyncStage.sending && totalBytes != null && totalBytes! > 0) return sentBytes / totalBytes!;
    if (kind == SyncKind.qr && framesTotal > 0) return framesReceived / framesTotal;
    if (stage == SyncStage.done) return 1;
    return null; // indeterminate (e.g. waitingHub)
  }
  bool get isActive => stage != SyncStage.idle && stage != SyncStage.done && stage != SyncStage.failed && stage != SyncStage.cancelled;

  SyncProgress copyWith({SyncStage? stage, DateTime? stageStartedAt, int? sentBytes, int? totalBytes, int? receivedBytes, int? framesReceived, int? framesTotal, List<int>? missingFrames, SyncSummary? summary, String? errorCode, String? errorMessage, bool? hubMayHaveChanged}) => SyncProgress(
        kind: kind, stage: stage ?? this.stage, startedAt: startedAt, stageStartedAt: stageStartedAt ?? this.stageStartedAt,
        sentBytes: sentBytes ?? this.sentBytes, totalBytes: totalBytes ?? this.totalBytes, receivedBytes: receivedBytes ?? this.receivedBytes,
        framesReceived: framesReceived ?? this.framesReceived, framesTotal: framesTotal ?? this.framesTotal, missingFrames: missingFrames ?? this.missingFrames,
        summary: summary ?? this.summary, errorCode: errorCode ?? this.errorCode, errorMessage: errorMessage ?? this.errorMessage, hubMayHaveChanged: hubMayHaveChanged ?? this.hubMayHaveChanged,
      );
}

class SyncProgressController extends ValueNotifier<SyncProgress> {
  SyncProgressController({DateTime Function()? now})
      : _now = now ?? (() => DateTime.now().toUtc()),
        super(SyncProgress(kind: SyncKind.lan, stage: SyncStage.idle, startedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)));

  final DateTime Function() _now;
  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  void start(SyncKind kind) { _cancelled = false; value = SyncProgress(kind: kind, stage: SyncStage.connecting, startedAt: _now(), stageStartedAt: _now()); }
  void stage(SyncStage s, {int? totalBytes}) => value = value.copyWith(stage: s, stageStartedAt: _now(), totalBytes: totalBytes);
  void bytes(int sent) => value = value.copyWith(sentBytes: sent);
  void received(int bytes) => value = value.copyWith(receivedBytes: bytes);
  void frames({required int received, required int total, required List<int> missing}) => value = value.copyWith(framesReceived: received, framesTotal: total, missingFrames: missing);
  void finish(SyncSummary summary) => value = value.copyWith(stage: SyncStage.done, summary: summary, stageStartedAt: _now());
  void fail(String code, String message) => value = value.copyWith(stage: SyncStage.failed, errorCode: code, errorMessage: message, stageStartedAt: _now());
  void cancel() {
    _cancelled = true;
    final after = value.stage.index >= SyncStage.waitingHub.index && value.stage != SyncStage.done;
    value = value.copyWith(stage: SyncStage.cancelled, hubMayHaveChanged: after, stageStartedAt: _now());
  }
}
```

- [ ] **Step 4: テストを通す・コミット**

Run: `flutter analyze && flutter test test/services/sync/sync_progress_test.dart`

```bash
git add lib/services/sync/sync_progress.dart test/services/sync/sync_progress_test.dart
git commit -m "feat(sync): measurable sync progress model with cancel semantics / 同期進捗モデル"
```

---

### Task 3: LanSyncClient（証明書ピン留め、pair / health / sync、進捗、キャンセル）

**Files:**
- Create: `lib/services/sync/lan_sync_client.dart`
- Test: `test/services/sync/lan_sync_client_test.dart`

テストは `dart:io` の `HttpServer` を平文で立て、`LanSyncClient(allowInsecureForTest: true)` で HTTP に接続する。ピン留めの判定は `verifyFingerprint(X509Certificate, expected)` を純関数にして単体テストする。

- [ ] **Step 1: 失敗するテストを書く**

```dart
// test/services/sync/lan_sync_client_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/services/sync/lan_sync_client.dart';
import 'package:frelocator/services/sync/sync_progress.dart';
import 'package:frelocator/services/sync/sync_settings.dart';

void main() {
  late HttpServer server;
  late List<HttpRequest> seen;

  Future<void> serve(Map<String, dynamic Function(HttpRequest, String body)> routes) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    seen = [];
    server.listen((req) async {
      seen.add(req);
      final body = await utf8.decoder.bind(req).join();
      final key = '${req.method} ${req.uri.path}';
      final handler = routes[key];
      if (handler == null) { req.response.statusCode = 404; await req.response.close(); return; }
      final result = handler(req, body);
      final status = result is Map && result.containsKey('_status') ? result['_status'] as int : 200;
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(result is Map ? (Map.of(result)..remove('_status')) : result));
      await req.response.close();
    });
  }

  tearDown(() => server.close(force: true));

  SyncSettings settings() => SyncSettings(host: '127.0.0.1', port: server.port, fingerprint: 'AB' * 32, token: 't' * 64, hubDeviceId: 'hub');

  test('pair posts code and device, returns token and fingerprint', () async {
    await serve({'POST /pair': (req, body) => {'token': 'x' * 64, 'hubDeviceId': 'hub-macos', 'fingerprint': 'AB' * 32}});
    final client = LanSyncClient(allowInsecureForTest: true);
    final r = await client.pair(PairingInfo(host: '127.0.0.1', port: server.port, fingerprint: 'AB' * 32, code: 'K7Q2M9XZ'), deviceId: 'android-1', deviceName: 'Pixel');
    expect(r.token, 'x' * 64);
    expect(r.hubDeviceId, 'hub-macos');
    expect(seen.single.headers.value('authorization'), isNull);
  });

  test('sync sends bearer token, mode, reports progress and parses the result', () async {
    await serve({'POST /sync': (req, body) {
      expect(req.headers.value('authorization'), 'Bearer ${'t' * 64}');
      expect(req.uri.queryParameters['mode'], 'merge');
      return {'document': {'version': 2, 'exportedAt': 'x', 'deviceId': 'hub', 'taskMaster': {}, 'dailyPlan': {}}, 'summary': {'added': 1, 'updated': 0, 'deleted': 0, 'warnings': 0}, 'warnings': []};
    }});
    final progress = SyncProgressController();
    progress.start(SyncKind.lan);
    final client = LanSyncClient(allowInsecureForTest: true);
    final r = await client.sync(settings(), {'version': 2, 'payload': 'x' * 5000}, progress: progress);
    expect(r.summary.added, 1);
    expect(progress.value.sentBytes, greaterThan(5000));
    expect(progress.value.stage, SyncStage.receiving);
  });

  test('maps error responses to SyncHttpException with code', () async {
    await serve({'POST /sync': (req, body) => {'_status': 409, 'error': {'code': 'purged_before', 'message': 'choose'}}});
    final client = LanSyncClient(allowInsecureForTest: true);
    await expectLater(client.sync(settings(), {'version': 2}), throwsA(isA<SyncHttpException>().having((e) => e.status, 'status', 409).having((e) => e.code, 'code', 'purged_before')));
  });

  test('unreachable host fails fast with code unreachable', () async {
    final client = LanSyncClient(allowInsecureForTest: true, timeout: const Duration(milliseconds: 300));
    await expectLater(client.health(const SyncSettings(host: '127.0.0.1', port: 1, fingerprint: 'x', token: 'y')), throwsA(isA<SyncHttpException>().having((e) => e.code, 'code', 'unreachable')));
  });

  test('fingerprint verification', () {
    expect(fingerprintMatches(sha256Hex: 'ab' * 32, expected: 'AB' * 32), isTrue);
    expect(fingerprintMatches(sha256Hex: 'ab' * 32, expected: 'CD' * 32), isFalse);
  });
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/services/sync/lan_sync_client_test.dart`
Expected: FAIL

- [ ] **Step 3: 実装する**

```dart
// lib/services/sync/lan_sync_client.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'sync_progress.dart';
import 'sync_settings.dart';

final lanSyncClientProvider = Provider<LanSyncClient>((ref) => LanSyncClient());

class SyncHttpException implements Exception {
  const SyncHttpException(this.status, this.code, this.message);
  final int status; final String code; final String message;
  @override
  String toString() => 'SyncHttpException($status $code): $message';
}

class PairResult { const PairResult({required this.token, required this.hubDeviceId, required this.fingerprint}); final String token; final String hubDeviceId; final String fingerprint; }
class SyncResponse { const SyncResponse({required this.document, required this.summary, required this.warnings}); final Map<String, dynamic> document; final SyncSummary summary; final List<String> warnings; }

bool fingerprintMatches({required String sha256Hex, required String expected}) => sha256Hex.toUpperCase() == expected.toUpperCase();

/// HTTPS client that trusts exactly one certificate: the hub's, by SHA-256 fingerprint.
class LanSyncClient {
  LanSyncClient({this.allowInsecureForTest = false, this.timeout = const Duration(seconds: 3)});

  final bool allowInsecureForTest;
  final Duration timeout;

  http.Client _client(String? expectedFingerprint) {
    final io = HttpClient()
      ..connectionTimeout = timeout
      ..badCertificateCallback = (X509Certificate cert, String host, int port) {
        if (expectedFingerprint == null) return false;
        return fingerprintMatches(sha256Hex: sha256.convert(cert.der).toString(), expected: expectedFingerprint);
      };
    return IOClient(io);
  }

  Uri _uri(String host, int port, String path, [Map<String, String>? query]) =>
      Uri(scheme: allowInsecureForTest ? 'http' : 'https', host: host, port: port, path: path, queryParameters: query);

  Future<PairResult> pair(PairingInfo info, {required String deviceId, required String deviceName}) async {
    final json = await _post(_uri(info.host, info.port, '/pair'), {'code': info.code, 'deviceId': deviceId, 'name': deviceName}, fingerprint: info.fingerprint);
    return PairResult(token: json['token'] as String, hubDeviceId: json['hubDeviceId'] as String, fingerprint: (json['fingerprint'] as String).toUpperCase());
  }

  Future<Map<String, dynamic>> health(SyncSettings s) => _get(_uri(s.host!, s.port, '/health'), s);

  Future<Map<String, dynamic>> fetch(SyncSettings s) async => (await _get(_uri(s.host!, s.port, '/sync'), s))['document'] as Map<String, dynamic>;

  Future<SyncResponse> sync(SyncSettings s, Map<String, dynamic> document, {String mode = 'merge', SyncProgressController? progress}) async {
    final body = utf8.encode(jsonEncode(document));
    progress?.stage(SyncStage.sending, totalBytes: body.length);
    final client = _client(s.fingerprint);
    try {
      final request = http.StreamedRequest('POST', _uri(s.host!, s.port, '/sync', {'mode': mode}))
        ..headers['authorization'] = 'Bearer ${s.token}'
        ..headers['content-type'] = 'application/json'
        ..contentLength = body.length;
      // Feed in chunks so the progress panel can show sent bytes.
      unawaited(() async {
        const chunk = 16 * 1024; var sent = 0;
        for (var i = 0; i < body.length; i += chunk) {
          if (progress?.isCancelled ?? false) { request.sink.close(); return; }
          final end = (i + chunk < body.length) ? i + chunk : body.length;
          request.sink.add(body.sublist(i, end)); sent = end; progress?.bytes(sent);
          await Future<void>.delayed(Duration.zero);
        }
        await request.sink.close();
      }());
      final streamed = await client.send(request).timeout(timeout * 10, onTimeout: () => throw const SyncHttpException(0, 'timeout', 'PC からの応答がありません'));
      progress?.stage(SyncStage.waitingHub);
      final bytes = <int>[];
      await for (final part in streamed.stream) { bytes.addAll(part); progress?.received(bytes.length); if (progress?.value.stage == SyncStage.waitingHub) progress?.stage(SyncStage.receiving); }
      final json = _decode(streamed.statusCode, utf8.decode(bytes));
      return SyncResponse(document: json['document'] as Map<String, dynamic>, summary: SyncSummary.fromJson(json['summary'] as Map<String, dynamic>), warnings: (json['warnings'] as List? ?? const []).cast<String>());
    } on SocketException catch (e) { throw SyncHttpException(0, 'unreachable', e.message);
    } on HandshakeException catch (e) { throw SyncHttpException(0, 'certificate', '証明書が一致しません: ${e.message}');
    } on TimeoutException { throw const SyncHttpException(0, 'timeout', 'PC に接続できません');
    } finally { client.close(); }
  }

  Future<Map<String, dynamic>> _get(Uri uri, SyncSettings s) async {
    final client = _client(s.fingerprint);
    try {
      final r = await client.get(uri, headers: {'authorization': 'Bearer ${s.token}'}).timeout(timeout);
      return _decode(r.statusCode, r.body);
    } on SocketException catch (e) { throw SyncHttpException(0, 'unreachable', e.message);
    } on HandshakeException catch (e) { throw SyncHttpException(0, 'certificate', e.message);
    } on TimeoutException { throw const SyncHttpException(0, 'unreachable', 'PC に接続できません');
    } finally { client.close(); }
  }

  Future<Map<String, dynamic>> _post(Uri uri, Map<String, dynamic> body, {required String fingerprint}) async {
    final client = _client(fingerprint);
    try {
      final r = await client.post(uri, headers: {'content-type': 'application/json'}, body: jsonEncode(body)).timeout(timeout);
      return _decode(r.statusCode, r.body);
    } on SocketException catch (e) { throw SyncHttpException(0, 'unreachable', e.message);
    } on HandshakeException catch (e) { throw SyncHttpException(0, 'certificate', e.message);
    } on TimeoutException { throw const SyncHttpException(0, 'unreachable', 'PC に接続できません');
    } finally { client.close(); }
  }

  Map<String, dynamic> _decode(int status, String body) {
    final json = body.isEmpty ? <String, dynamic>{} : jsonDecode(body) as Map<String, dynamic>;
    if (status >= 200 && status < 300) return json;
    final err = json['error'] as Map<String, dynamic>?;
    throw SyncHttpException(status, err?['code'] as String? ?? 'http_$status', err?['message'] as String? ?? 'HTTP $status');
  }
}
```

Web ビルドでは `dart:io` が使えないため、`lan_sync_client.dart` は `lan_sync_client_io.dart` と `lan_sync_client_stub.dart` に分け、`export 'lan_sync_client_stub.dart' if (dart.library.io) 'lan_sync_client_io.dart';` の条件付き export にする。stub は全メソッドで `SyncHttpException(0, 'unsupported', 'Web 版では LAN 同期は使えません')` を投げる。

- [ ] **Step 4: テストを通す・コミット**

Run: `flutter analyze && flutter test test/services/sync/lan_sync_client_test.dart && flutter build web --no-pub 2>&1 | tail -1`
Expected: PASS、Web ビルド成功

```bash
git add lib/services/sync/lan_sync_client*.dart test/services/sync/lan_sync_client_test.dart
git commit -m "feat(sync): pinned HTTPS LAN client with pairing, progress and cancel / LAN クライアント"
```

---

### Task 4: SyncService（export → sync → apply、置き換えフロー、mDNS フォールバック）

**Files:**
- Create: `lib/services/sync/sync_service.dart`、`lib/services/sync/hub_discovery.dart`（`hub_discovery_io.dart` / `hub_discovery_stub.dart` に条件付きエクスポートで分岐）、`lib/services/sync/sync_backup_store.dart`
- Modify: `lib/services/app_data_service.dart`、`lib/services/storage/state_store.dart`（`writeAll`）
- Test: `test/services/sync/sync_service_test.dart`、`test/services/app_data_service_test.dart`

この Task で確定した設計判断:

- **置き換え前バックアップ（決定: 実装する）** — `take_hub` / `take_phone` は負けた側を捨てるので、`importDocument` の直前に `AppDataService.exportAll()` を `sync_backup_v1`（SharedPreferences、常に 1 件）へ退避する。`SyncService.hasBackup` / `restoreBackup()` を公開し、設定画面に「直前の同期前に戻す」を置く。復元は 1 回きり（成功したらスナップショットを消す）で、`merge` では取らない（捨てているものが無いため）。QR / ファイルの `applyReceived` は常にマージなのでバックアップ対象外。
- **取り込みは 1 コミット** — タスクと日次計画は 1 つの文書の両半分（割当がタスク id を参照する）なので、`StateStore.writeAll(tasks, plans)` で一括に書く。`FileBackedStore` は 1 ファイル 1 ロックで本当に原子的、`PrefsStateStore` は両方をエンコードしてから書き、後半が失敗したら前半を戻す。
- **`lastSyncAt` はハブの値** — 端末時計ではなく応答文書の `lastSyncAt`（無ければ現在 UTC）を保存する。時計が進んだ端末が未来の値を記録すると次の差分が空に見える。
- **単一実行（single-flight）** — 実行中の `syncNow` があるあいだ、2 本目は即座に `SyncFailed('busy', …)` を返す。同じ文書を 2 回書き出して `importDocument` を競わせない。
- **`applyReceived` は `Future<SyncOutcome>`** — 失敗マッピングを `_mapFailure` に切り出し、`syncNow` と共有する。壊れた文書は `SyncFailed('corrupt', …)` ＋ `progress.fail` になる。
- **mDNS で見つけた住所は成功後に保存** — 再試行が通ってから `settingsStore.save`。通らなかった住所で上書きすると、手入力し直すまで復旧できない。

- [ ] **Step 1: 失敗するテストを書く**

```dart
// test/services/sync/sync_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/device_clock.dart';
import 'package:frelocator/core/hlc.dart';
import 'package:frelocator/services/app_data_service.dart';
import 'package:frelocator/services/storage/prefs_state_store.dart';
import 'package:frelocator/features/daily_plan/data/daily_plan_repository.dart';
import 'package:frelocator/features/task_master/data/task_master_repository.dart';
import 'package:frelocator/services/sync/lan_sync_client.dart';
import 'package:frelocator/services/sync/sync_document.dart';
import 'package:frelocator/services/sync/sync_progress.dart';
import 'package:frelocator/services/sync/sync_service.dart';
import 'package:frelocator/services/sync/sync_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeClient extends LanSyncClient {
  _FakeClient(this.onSync) : super(allowInsecureForTest: true);
  final Future<SyncResponse> Function(SyncSettings, Map<String, dynamic>, String mode) onSync;
  String? lastMode;
  @override
  Future<SyncResponse> sync(SyncSettings s, Map<String, dynamic> document, {String mode = 'merge', SyncProgressController? progress}) { lastMode = mode; return onSync(s, document, mode); }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SyncService> make(_FakeClient client) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final store = PrefsStateStore();
    final clock = await DeviceClock.load(platformPrefix: 'test', now: () => 1000);
    final data = AppDataService(taskRepo: TaskMasterRepository(store), dailyPlanRepo: DailyPlanRepository(store), deviceClock: clock);
    final settingsStore = SyncSettingsStore();
    await settingsStore.save(SyncSettings(host: 'h', port: 1, fingerprint: 'AB' * 32, token: 't', hubDeviceId: 'hub'));
    return SyncService(client: client, data: data, settingsStore: settingsStore, deviceClock: clock);
  }

  test('applies the hub result, records lastSyncAt and observes hub clocks', () async {
    final client = _FakeClient((s, doc, mode) async {
      final result = SyncDocument.fromJson(doc, strict: true).toJson();
      (result['taskMaster'] as Map)['tasks'] = [
        {'id': 'from-hub', 'title': 'x', 'kind': 'must_do', 'priority': 3, 'createdAt': '2026-01-01T00:00:00.000Z', 'updatedAt': '2026-01-01T00:00:00.000Z', 'memo': '', 'categoryId': null, 'estimatedMinutes': 0, 'clock': '999999-0-hub', 'deletedAt': null, 'migrated': false}
      ];
      return SyncResponse(document: result, summary: const SyncSummary(added: 1, updated: 0, deleted: 0, warnings: 0), warnings: const []);
    });
    final service = await make(client);
    final progress = SyncProgressController();
    final outcome = await service.syncNow(progress: progress);
    expect(outcome, isA<SyncApplied>());
    expect((await service.data.taskRepo.load()).tasks.single.id, 'from-hub');
    expect((await service.settingsStore.load()).lastSyncAt, isNotNull);
    expect(service.deviceClock.deviceId, startsWith('test-'));
    expect((await service.deviceClock.next()).physical, greaterThanOrEqualTo(999999));
    expect(progress.value.stage, SyncStage.done);
  });

  test('409 purged_before becomes NeedsReplace and a replace call sends the mode', () async {
    var calls = 0;
    final client = _FakeClient((s, doc, mode) async {
      calls += 1;
      if (mode == 'merge') throw const SyncHttpException(409, 'purged_before', 'choose');
      return SyncResponse(document: SyncDocument.fromJson(doc, strict: true).toJson(), summary: const SyncSummary(added: 0, updated: 0, deleted: 0, warnings: 0), warnings: const []);
    });
    final service = await make(client);
    final outcome = await service.syncNow();
    expect(outcome, isA<SyncNeedsReplace>());
    final again = await service.syncNow(mode: SyncMode.takePhone);
    expect(again, isA<SyncApplied>());
    expect(client.lastMode, 'take_phone');
    expect(calls, 2);
  });

  test('426 and unreachable become SyncFailed with distinct codes', () async {
    final s1 = await make(_FakeClient((s, d, m) async => throw const SyncHttpException(426, 'upgrade_required', 'update')));
    expect((await s1.syncNow() as SyncFailed).code, 'upgrade_required');
    final s2 = await make(_FakeClient((s, d, m) async => throw const SyncHttpException(0, 'unreachable', 'no route')));
    expect((await s2.syncNow() as SyncFailed).code, 'unreachable');
  });

  test('not paired is reported without calling the client', () async {
    final client = _FakeClient((s, d, m) async => throw StateError('should not be called'));
    final service = await make(client);
    await service.settingsStore.clear();
    expect((await service.syncNow() as SyncFailed).code, 'not_paired');
  });
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/services/sync/sync_service_test.dart`
Expected: FAIL

- [ ] **Step 3: 実装する**

```dart
// lib/services/sync/sync_service.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/device_clock.dart';
import '../../core/hlc.dart';
import '../app_data_service.dart';
import 'lan_sync_client.dart';
import 'sync_document.dart';
import 'sync_progress.dart';
import 'sync_settings.dart';

final syncServiceProvider = Provider<SyncService>((ref) => SyncService(
      client: ref.read(lanSyncClientProvider), data: ref.read(appDataServiceProvider),
      settingsStore: ref.read(syncSettingsStoreProvider), deviceClock: ref.read(deviceClockProvider),
    ));

enum SyncMode { merge, takeHub, takePhone }
extension on SyncMode { String get wire => switch (this) { SyncMode.merge => 'merge', SyncMode.takeHub => 'take_hub', SyncMode.takePhone => 'take_phone' }; }

sealed class SyncOutcome { const SyncOutcome(); }
class SyncApplied extends SyncOutcome { const SyncApplied(this.summary, this.warnings); final SyncSummary summary; final List<String> warnings; }
class SyncNeedsReplace extends SyncOutcome { const SyncNeedsReplace(this.message); final String message; }
class SyncCancelled extends SyncOutcome { const SyncCancelled({required this.hubMayHaveChanged}); final bool hubMayHaveChanged; }
class SyncFailed extends SyncOutcome { const SyncFailed(this.code, this.message); final String code; final String message; }

/// One tap = export → POST /sync → replace local state with the hub's merged result.
class SyncService {
  SyncService({required this.client, required this.data, required this.settingsStore, required this.deviceClock});
  final LanSyncClient client; final AppDataService data; final SyncSettingsStore settingsStore; final DeviceClock deviceClock;

  Future<SyncOutcome> syncNow({SyncMode mode = SyncMode.merge, SyncProgressController? progress}) async {
    final settings = await settingsStore.load();
    if (!settings.isPaired) { progress?.fail('not_paired', 'PC とペアリングされていません'); return const SyncFailed('not_paired', 'PC とペアリングされていません。設定の「PC とペアリング」から QR を読み取ってください。'); }
    progress?.start(SyncKind.lan);
    try {
      final exported = await data.exportDocument();
      final payload = SyncDocument(exportedAt: exported.exportedAt, deviceId: exported.deviceId, lastSyncAt: settings.lastSyncAt, taskMaster: exported.taskMaster, dailyPlan: exported.dailyPlan).toJson();
      final response = await client.sync(settings, payload, mode: mode.wire, progress: progress);
      if (progress?.isCancelled ?? false) return SyncCancelled(hubMayHaveChanged: progress!.value.hubMayHaveChanged);
      progress?.stage(SyncStage.applying);
      final document = SyncDocument.fromJson(response.document, strict: true);
      await _observeClocks(document);
      progress?.stage(SyncStage.saving);
      await data.importDocument(document);
      final now = DateTime.now().toUtc();
      await settingsStore.save(settings.copyWith(lastSyncAt: now));
      progress?.finish(response.summary);
      return SyncApplied(response.summary, response.warnings);
    } on SyncHttpException catch (e) {
      final message = switch (e.code) {
        'purged_before' => 'PC 側でしばらく前の削除履歴が掃除されています。どちらのデータを正にするか選んでください。',
        'upgrade_required' => 'アプリが古いため同期できません。アプリを更新してください。',
        'unauthorized' => 'PC の認証に失敗しました。もう一度ペアリングしてください。',
        'certificate' => 'PC の証明書が変わっています。もう一度ペアリングしてください。',
        'unreachable' => '同じ Wi-Fi に接続されているか確認するか、QR で連携してください。',
        'timeout' => 'PC からの応答がありません。',
        _ => e.message,
      };
      if (e.code == 'purged_before') { progress?.fail(e.code, message); return SyncNeedsReplace(message); }
      progress?.fail(e.code, message);
      return SyncFailed(e.code, message);
    } on FormatException catch (e) {
      progress?.fail('corrupt', 'PC から受け取ったデータを読めません: ${e.message}');
      return SyncFailed('corrupt', 'PC から受け取ったデータを読めません。');
    }
  }

  /// Applies a document received out of band (QR or file) using the same merge rules.
  Future<SyncApplied> applyReceived(Map<String, dynamic> json, {SyncProgressController? progress}) async {
    progress?.stage(SyncStage.applying);
    final incoming = SyncDocument.fromJson(json, strict: true);
    final local = await data.exportDocument();
    final merged = SyncMerger.merge(local, incoming);
    await _observeClocks(merged.document);
    progress?.stage(SyncStage.saving);
    await data.importDocument(merged.document);
    final summary = SyncSummary(added: 0, updated: 0, deleted: 0, warnings: merged.warnings.length);
    progress?.finish(summary);
    return SyncApplied(summary, merged.warnings);
  }

  Future<void> _observeClocks(SyncDocument doc) async {
    var best = Hlc.migrated;
    void consider(Hlc c) { if (c.compareTo(best) > 0) best = c; }
    for (final t in doc.taskMaster.tasks) consider(t.meta.clock);
    for (final t in doc.taskMaster.deletedTasks) consider(t.meta.clock);
    for (final c in [...doc.taskMaster.mustDoCategories, ...doc.taskMaster.wantToDoCategories]) consider(c.meta.clock);
    for (final p in doc.dailyPlan.plans) consider(p.meta.clock);
    for (final s in doc.dailyPlan.slots) consider(s.meta.clock);
    for (final a in doc.dailyPlan.assignments) consider(a.meta.clock);
    consider(doc.taskMaster.settingsMeta.clock);
    if (!best.isMigrated) await deviceClock.observe(best);
  }
}
```

`sync_merger.dart` の import を追加する。`applyReceived` の summary は Plan 2a の `summarize` と同じ規則で数える方が親切なので、`SyncMerger` に `MergeResult.summaryAgainst(SyncDocument before)` を追加して added/updated/deleted を数える（Task 7 の QR 画面で表示）。

```dart
// lib/services/sync/hub_discovery.dart
import 'package:multicast_dns/multicast_dns.dart';

/// Finds the hub on the local network via mDNS. Returns `host:port` or null.
Future<({String host, int port})?> discoverHub({Duration timeout = const Duration(seconds: 3)}) async {
  final client = MDnsClient();
  try {
    await client.start();
    await for (final ptr in client.lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer('_frelocator._tcp.local')).timeout(timeout, onTimeout: (sink) => sink.close())) {
      await for (final srv in client.lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName)).timeout(timeout, onTimeout: (sink) => sink.close())) {
        await for (final ip in client.lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(srv.target)).timeout(timeout, onTimeout: (sink) => sink.close())) {
          return (host: ip.address.address, port: srv.port);
        }
      }
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    client.stop();
  }
}
```

`SyncService.syncNow` は `unreachable` のとき 1 回だけ `discoverHub()` を試し、見つかれば `settings.copyWith(host:, port:)` を保存して再試行する（フィンガープリントとトークンは同じ）。テストでは `discover` を差し替えられるようコンストラクタ引数 `Future<({String host, int port})?> Function()? discover` を持たせ、既定を `discoverHub` にする。

- [ ] **Step 4: テストを通す・コミット**

Run: `flutter analyze && flutter test test/services/sync/`

```bash
git add lib/services/sync/sync_service.dart lib/services/sync/hub_discovery.dart lib/services/sync/sync_merger.dart test/services/sync/sync_service_test.dart
git commit -m "feat(sync): sync service with replace flow, mDNS fallback and out-of-band apply / 同期サービス"
```

---

### Task 5: QrChunkCodec（Dart 側、TS と同一フレーム形式）

**Files:**
- Create: `lib/services/sync/qr_chunk_codec.dart`
- Create: `tools/hub/test/fixtures/qr/sample.frames.json`（Plan 2a の `encodeFrames` で生成: `node -e` で `{version:2,…}` の小さな文書を 3 コマになるよう `chunkChars: 200` で作り、`{ "value": <元の JSON>, "frames": [...] }` として保存）
- Test: `test/services/sync/qr_chunk_codec_test.dart`

- [ ] **Step 1: 失敗するテストを書く**

```dart
// test/services/sync/qr_chunk_codec_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/services/sync/qr_chunk_codec.dart';

void main() {
  test('base45 vectors (RFC 9285)', () {
    expect(base45Encode(utf8.encode('AB')), 'BB8');
    expect(base45Encode(utf8.encode('Hello!!')), '%69 VD92EX0');
    expect(utf8.decode(base45Decode('QED8WEX0')), 'ietf!');
    expect(() => base45Decode('GGW'), throwsFormatException);
  });

  test('crc32 check value', () {
    expect(crc32Hex(utf8.encode('123456789')), 'CBF43926');
  });

  test('decodes frames produced by the TypeScript hub, in any order', () {
    final fixture = jsonDecode(File('tools/hub/test/fixtures/qr/sample.frames.json').readAsStringSync()) as Map<String, dynamic>;
    final frames = (fixture['frames'] as List).cast<String>();
    final set = QrFrameSet();
    for (final f in frames.reversed) { expect(set.add(f), QrAddResult.added); }
    expect(set.isComplete, isTrue);
    expect(decodeQrFrames(set), fixture['value']);
  });

  test('reports duplicates, crc mismatch and foreign payloads', () {
    final fixture = jsonDecode(File('tools/hub/test/fixtures/qr/sample.frames.json').readAsStringSync()) as Map<String, dynamic>;
    final frames = (fixture['frames'] as List).cast<String>();
    final set = QrFrameSet();
    expect(set.add(frames[0]), QrAddResult.added);
    expect(set.add(frames[0]), QrAddResult.duplicate);
    expect(set.missing, hasLength(frames.length - 1));
    final bad = '${frames[1].substring(0, frames[1].length - 1)}${frames[1].endsWith('A') ? 'B' : 'A'}';
    expect(set.add(bad), QrAddResult.crcMismatch);
    expect(set.add('FRL2:0000000000000000:0:1:00000000:AB'), QrAddResult.differentPayload);
    // 総数が最初のフレームと食い違うものも differentPayload（混ぜると永久に未完成になる）。
    expect(set.add('FRL2:${set.hash}:1:${frames.length + 1}:00000000:AB'), QrAddResult.differentPayload);
    expect(set.add('garbage'), QrAddResult.malformed);
    // 十進数字以外の添字・総数、および 512 を超える総数は malformed。
    expect(set.add('FRL2:${set.hash}: 1:3:00000000:AB'), QrAddResult.malformed);
    expect(set.add('FRL2:${set.hash}:0:2000000000:00000000:AB'), QrAddResult.malformed);
    // chunk に ':' を含むフレームも往復できること（base45 の英数字集合に ':' が入る）。
    const colonChunk = 'A:B';
    final colonFrame = 'FRL2:0123456789ABCDEF:0:1:${crc32Hex(utf8.encode(colonChunk))}:$colonChunk';
    final colonSet = QrFrameSet();
    expect(colonSet.add(colonFrame), QrAddResult.added);
    expect(colonSet.chunkAt(0), colonChunk);
  });
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/services/sync/qr_chunk_codec_test.dart`
Expected: FAIL

- [ ] **Step 3: 実装する**

```dart
// lib/services/sync/qr_chunk_codec.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

const _b45 = r'0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:';

String base45Encode(List<int> bytes) {
  final out = StringBuffer();
  for (var i = 0; i < bytes.length; i += 2) {
    if (i + 1 < bytes.length) {
      final n = bytes[i] * 256 + bytes[i + 1];
      out..write(_b45[n % 45])..write(_b45[(n ~/ 45) % 45])..write(_b45[n ~/ (45 * 45)]);
    } else {
      final n = bytes[i]; out..write(_b45[n % 45])..write(_b45[n ~/ 45]);
    }
  }
  return out.toString();
}

Uint8List base45Decode(String text) {
  final vals = text.runes.map((r) { final v = _b45.indexOf(String.fromCharCode(r)); if (v < 0) throw FormatException('invalid base45 char'); return v; }).toList();
  final out = <int>[];
  for (var i = 0; i < vals.length; i += 3) {
    if (i + 2 < vals.length) {
      final n = vals[i] + vals[i + 1] * 45 + vals[i + 2] * 45 * 45;
      if (n > 0xffff) throw const FormatException('invalid base45 triplet');
      out..add(n >> 8)..add(n & 0xff);
    } else if (i + 1 < vals.length) {
      final n = vals[i] + vals[i + 1] * 45;
      if (n > 0xff) throw const FormatException('invalid base45 pair');
      out.add(n);
    } else { throw const FormatException('invalid base45 length'); }
  }
  return Uint8List.fromList(out);
}

String crc32Hex(List<int> bytes) => getCrc32(bytes).toRadixString(16).toUpperCase().padLeft(8, '0');

enum QrAddResult { added, duplicate, crcMismatch, differentPayload, malformed }

/// フレーム総数の上限（ハブ側 `MAX_FRAMES` と一致させること）。
const int kMaxQrFrames = 512;

/// Collects `FRL2:<sha16>:<i>:<n>:<crc>:<chunk>` frames in any order.
class QrFrameSet {
  String? hash; int total = 0;
  final Map<int, String> _chunks = {};
  int get received => _chunks.length;
  bool get isComplete => total > 0 && _chunks.length == total;
  List<int> get missing => [for (var i = 0; i < total; i += 1) if (!_chunks.containsKey(i)) i];
  String? chunkAt(int i) => _chunks[i];

  QrAddResult add(String frame) {
    // base45 の英数字集合に ':' が含まれるため chunk にも ':' が現れる。
    // 区切りとして意味を持つのは最初の 5 個だけ（`parts.length != 6` / `parts[5]` は誤り）。
    final parts = frame.split(':');
    if (parts.length < 6 || parts[0] != 'FRL2') return QrAddResult.malformed;
    final chunk = parts.sublist(5).join(':');
    // 十進数字のみ。`int.tryParse(' 1')` や `'0x1'` を通さない。
    if (!RegExp(r'^\d+$').hasMatch(parts[2]) || !RegExp(r'^\d+$').hasMatch(parts[3])) return QrAddResult.malformed;
    final i = int.parse(parts[2]); final n = int.parse(parts[3]);
    // n を先に縛る（TS 側の MAX_FRAMES と同じ 512）。縛らないと missing の生成で暴走する。
    if (n < 1 || n > kMaxQrFrames || i >= n) return QrAddResult.malformed;
    // 別ペイロード、または総数が最初のフレームと食い違うものは混ぜない
    // （総数が違うと集合が永久に未完成になる）。
    if (hash != null && (hash != parts[1] || n != total)) return QrAddResult.differentPayload;
    if (crc32Hex(utf8.encode(chunk)) != parts[4]) return QrAddResult.crcMismatch;
    hash ??= parts[1]; if (total == 0) total = n;
    if (_chunks.containsKey(i)) return QrAddResult.duplicate;
    _chunks[i] = chunk;
    return QrAddResult.added;
  }

  void reset() { hash = null; total = 0; _chunks.clear(); }
}

Map<String, dynamic> decodeQrFrames(QrFrameSet set) {
  if (!set.isComplete) throw FormatException('incomplete: missing ${set.missing}');
  final text = [for (var i = 0; i < set.total; i += 1) set.chunkAt(i)!].join();
  final json = GZipDecoder().decodeBytes(base45Decode(text));
  final digest = sha256.convert(json).toString().substring(0, 16).toUpperCase();
  if (digest != set.hash) throw const FormatException('payload hash mismatch');
  return jsonDecode(utf8.decode(json)) as Map<String, dynamic>;
}
```

`getCrc32` は `package:archive` の関数。TS 側の crc は UTF-8 バイト列に対して計算しているので、Dart も `utf8.encode(chunk)` を渡す（chunk は ASCII なので同値）。

- [ ] **Step 4: テストを通す・コミット**

Run: `flutter analyze && flutter test test/services/sync/qr_chunk_codec_test.dart`

```bash
git add lib/services/sync/qr_chunk_codec.dart test/services/sync/qr_chunk_codec_test.dart tools/hub/test/fixtures/qr/sample.frames.json
git commit -m "feat(sync): QR frame codec compatible with the hub / QR フレームコーデック（Dart）"
```

---

### Task 6: FileExporter（スマホ→PC の書き出し、macOS の取り込み）

**Files:**
- Create: `lib/services/sync/file_exporter.dart`
- Test: `test/services/sync/file_exporter_test.dart`

- [ ] **Step 1: 失敗するテストを書く**

```dart
// test/services/sync/file_exporter_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/services/sync/file_exporter.dart';
import 'package:frelocator/services/sync/sync_document.dart';
import 'package:frelocator/features/daily_plan/domain/daily_plan_models.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';

void main() {
  test('writes a v2 json file with a timestamped name into the given directory', () async {
    final dir = await Directory.systemTemp.createTemp('frelocator-export-');
    addTearDown(() => dir.delete(recursive: true));
    final doc = SyncDocument(exportedAt: DateTime.utc(2026, 9, 9, 1, 2, 3), deviceId: 'android-1', taskMaster: TaskMasterStateData.initial(), dailyPlan: DailyPlanStateData.initial());
    final file = await writeExportFile(doc, directory: dir.path);
    expect(file.path, endsWith('frelocator-android-1-20260909-010203.json'));
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(json['version'], 2);
    expect(json['deviceId'], 'android-1');
  });

  test('readImportFile validates strictly', () async {
    final dir = await Directory.systemTemp.createTemp('frelocator-import-');
    addTearDown(() => dir.delete(recursive: true));
    final bad = File('${dir.path}/bad.json')..writeAsStringSync('{"version": 1}');
    expect(() => readImportFile(bad.path), throwsFormatException);
    final good = File('${dir.path}/good.json')..writeAsStringSync(jsonEncode({'version': 2, 'exportedAt': '2026-09-09T00:00:00.000Z', 'deviceId': 'android-1', 'taskMaster': TaskMasterStateData.initial().toJson(), 'dailyPlan': {'plans': [], 'slots': [], 'assignments': []}}));
    expect((await readImportFile(good.path)).deviceId, 'android-1');
  });
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/services/sync/file_exporter_test.dart`
Expected: FAIL

- [ ] **Step 3: 実装する**

```dart
// lib/services/sync/file_exporter.dart
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'sync_document.dart';

String _stamp(DateTime t) {
  final u = t.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${u.year}${two(u.month)}${two(u.day)}-${two(u.hour)}${two(u.minute)}${two(u.second)}';
}

Future<File> writeExportFile(SyncDocument doc, {String? directory}) async {
  final dir = directory ?? (await getTemporaryDirectory()).path;
  final file = File('$dir/frelocator-${doc.deviceId}-${_stamp(doc.exportedAt)}.json');
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(doc.toJson()), flush: true);
  return file;
}

/// Phone → PC without a network: hand the file to the share sheet. The user
/// picks the destination (Nearby Share, USB, …); the app itself sends nothing.
Future<void> shareExportFile(SyncDocument doc) async {
  final file = await writeExportFile(doc);
  await SharePlus.instance.share(ShareParams(files: [XFile(file.path, mimeType: 'application/json')], subject: 'FRELOCATOR export', text: 'FRELOCATOR のデータ書き出し。PC 側では Claude の import_file か、macOS 版アプリの「ファイルから取り込む」で読み込みます。'));
}

/// Strict read used by the macOS "ファイルから取り込む" flow and by tests.
Future<SyncDocument> readImportFile(String path) async {
  final text = await File(path).readAsString();
  final json = jsonDecode(text);
  if (json is! Map<String, dynamic>) throw const FormatException('JSON のトップレベルがオブジェクトではありません');
  if ((json['version'] as num?) == null || (json['version'] as num) < 2) throw const FormatException('スキーマ v2 のファイルだけ取り込めます');
  return SyncDocument.fromJson(json, strict: true);
}

Future<String?> pickImportFile() async {
  final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
  return result?.files.single.path;
}
```

`share_plus` の API 名はインストールされた版に合わせる（v10 以前は `Share.shareXFiles`）。

- [ ] **Step 4: テストを通す・コミット**

Run: `flutter analyze && flutter test test/services/sync/file_exporter_test.dart`

```bash
git add lib/services/sync/file_exporter.dart test/services/sync/file_exporter_test.dart
git commit -m "feat(sync): export file to share sheet and strict file import / ファイル書き出しと取り込み"
```

---

### Task 7: 画面（PC と同期、ペアリング読み取り、QR 受信、進捗パネル、MCP 案内）

**Files:**
- Create: `lib/features/sync/presentation/sync_progress_panel.dart`、`sync_settings_screen.dart`、`pairing_scan_screen.dart`、`qr_receive_screen.dart`、`mcp_guide_section.dart`
- Modify: `lib/app/router.dart`、`lib/features/home/presentation/home_screen.dart`（設定ボタンの遷移先は `/categories` のまま。`category_settings_screen.dart` の末尾に「PC と同期」への `ListTile` を追加）
- Test: `test/features/sync/sync_settings_screen_test.dart`

UI の方針: 既存画面に合わせて `Scaffold` + `AppBar(title: Text('PC と同期'))`、`ListView` にカードを並べる。Riverpod は `ConsumerStatefulWidget`。色は既存の `AppColors` を使い、新しい色を作らない。

画面側で守ること:

- 進捗パネルの完了表示は「追加 n / 更新 n / 削除 n / 消去 n / 警告 n」。`消去`（`summary.removed`）はハブが墓標ごと捨てた件数で、墓標として残る `削除` と混ぜない。
- エラー表示は例外の `message` を直接出さず、必ず `syncErrorMessage(code)` を通す（ハブの `message` は英語のログ用文言。`SyncFailed.message` には詳細として括弧で残っているが、画面には出さない）。ペアリング画面も同じ関数を使う。
- 設定画面に「直前の同期前に戻す」を置く。`SyncService.hasBackup` が `true` のときだけ表示し、押すと `restoreBackup()`（1 回きり）。
- 「今すぐ同期」は実行中に無効化する。押せてしまっても `SyncService` が `busy` を返すだけだが、ボタンが反応しない理由を出さないほうが不親切。
- iOS は Play のリリース範囲外だが、`ios/Runner/Info.plist` には `NSCameraUsageDescription`（日本語）、`NSLocalNetworkUsageDescription`、`NSBonjourServices = [_frelocator._tcp]` を入れて正しい状態に保つ（後で iOS を出すときに権限だけ抜けている、を防ぐ）。

- [ ] **Step 1: 失敗するウィジェットテストを書く**

```dart
// test/features/sync/sync_settings_screen_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/features/sync/presentation/sync_settings_screen.dart';
import 'package:frelocator/services/sync/sync_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/test_container.dart';

void main() {
  testWidgets('unpaired state shows pairing CTA and hides sync button', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = await testContainer();
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const MaterialApp(home: SyncSettingsScreen())));
    await tester.pumpAndSettle();
    expect(find.text('PC とペアリング'), findsOneWidget);
    expect(find.text('今すぐ同期'), findsNothing);
    expect(find.text('QR で受け取る'), findsOneWidget);
    expect(find.text('PC へ書き出す'), findsOneWidget);
  });

  testWidgets('paired state shows host, last sync and sync button', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SyncSettingsStore().save(SyncSettings(host: '192.168.1.10', port: 47820, fingerprint: 'AB' * 32, token: 't' * 64, hubDeviceId: 'hub-macos', lastSyncAt: DateTime.utc(2026, 9, 9, 1)));
    final container = await testContainer();
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const MaterialApp(home: SyncSettingsScreen())));
    await tester.pumpAndSettle();
    expect(find.textContaining('192.168.1.10'), findsOneWidget);
    expect(find.text('今すぐ同期'), findsOneWidget);
    expect(find.text('ペアリングを解除'), findsOneWidget);
  });
}
```

`macOS` セクションの表示は `Platform.isMacOS` で分岐するので、ウィジェットテストではホスト（macOS）で「Claude Code（MCP）と連携」が表示されることも `expect(find.text('Claude Code（MCP）と連携'), findsOneWidget)` で確認する（テストは macOS でのみ実行される前提。`!kIsWeb && Platform.isMacOS` を `debugDefaultTargetPlatformOverride` ではなく `Platform` で判定しているため、CI が Linux の場合は skip 条件を付ける）。

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/features/sync/`
Expected: FAIL

- [ ] **Step 3: 実装する**

進捗パネル（設計書「進捗と待ち状態の可視化」）:

```dart
// lib/features/sync/presentation/sync_progress_panel.dart
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/sync/sync_progress.dart';

String stageLabel(SyncStage s) => switch (s) {
      SyncStage.idle => '待機中', SyncStage.connecting => '接続中', SyncStage.sending => '送信中', SyncStage.waitingHub => 'PC で処理中',
      SyncStage.receiving => '受信中', SyncStage.applying => 'マージ中', SyncStage.saving => '保存中', SyncStage.done => '完了',
      SyncStage.cancelled => '中止しました', SyncStage.failed => '失敗', SyncStage.scanning => '読み取り中', SyncStage.decoding => '復元中',
    };

/// Modal-style panel bound to a [SyncProgressController]. Shows only measurable numbers;
/// the hub-side stage is an indeterminate bar. Re-renders every second for the elapsed time.
class SyncProgressPanel extends StatefulWidget {
  const SyncProgressPanel({super.key, required this.controller, required this.onCancel, required this.onClose});
  final SyncProgressController controller; final VoidCallback onCancel; final VoidCallback onClose;
  @override
  State<SyncProgressPanel> createState() => _SyncProgressPanelState();
}

class _SyncProgressPanelState extends State<SyncProgressPanel> {
  late final Timer _ticker;
  @override
  void initState() { super.initState(); _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {})); }
  @override
  void dispose() { _ticker.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SyncProgress>(
      valueListenable: widget.controller,
      builder: (context, p, _) {
        final now = DateTime.now().toUtc();
        final elapsed = p.elapsed(now).inSeconds;
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(stageLabel(p.stage), style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: p.fraction),
            const SizedBox(height: 8),
            Text(_detail(p), style: theme.textTheme.bodySmall),
            Text('経過 $elapsed 秒${p.isSlow(now) ? '（時間がかかっています）' : ''}', style: theme.textTheme.bodySmall),
            if (p.kind == SyncKind.qr && p.framesTotal > 0) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 4, runSpacing: 4, children: [
                for (var i = 0; i < p.framesTotal; i += 1)
                  Container(width: 18, height: 18, alignment: Alignment.center,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(3), color: p.missingFrames.contains(i) ? theme.colorScheme.surfaceContainerHighest : theme.colorScheme.primary),
                    child: Text('${i + 1}', style: TextStyle(fontSize: 9, color: p.missingFrames.contains(i) ? theme.colorScheme.onSurface : theme.colorScheme.onPrimary))),
              ]),
              Text('未受信: ${p.missingFrames.map((i) => i + 1).join(', ')}', style: theme.textTheme.bodySmall),
            ],
            if (p.stage == SyncStage.done && p.summary != null) Text('追加 ${p.summary!.added} / 更新 ${p.summary!.updated} / 削除 ${p.summary!.deleted} / 警告 ${p.summary!.warnings}'),
            if (p.stage == SyncStage.failed) Text(p.errorMessage ?? '', style: TextStyle(color: theme.colorScheme.error)),
            if (p.stage == SyncStage.cancelled && p.hubMayHaveChanged) const Text('PC は更新済みの可能性があります。この端末への反映だけ中止しました。'),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              if (p.isActive && p.stage != SyncStage.saving) TextButton(onPressed: widget.onCancel, child: const Text('キャンセル')),
              if (!p.isActive) FilledButton(onPressed: widget.onClose, child: const Text('閉じる')),
            ]),
          ]),
        );
      },
    );
  }

  String _detail(SyncProgress p) => switch (p.stage) {
        SyncStage.sending when p.totalBytes != null => '${_kb(p.sentBytes)} / ${_kb(p.totalBytes!)}',
        SyncStage.receiving => '${_kb(p.receivedBytes)} 受信',
        SyncStage.waitingHub => 'PC がマージしています（進捗は計測できません）',
        SyncStage.scanning => '${p.framesReceived} / ${p.framesTotal} コマ受信',
        _ => '',
      };
  String _kb(int b) => '${(b / 1024).toStringAsFixed(1)} KB';
}
```

設定画面（要点。各セクションは `Card` + `ListTile`）:

```dart
// lib/features/sync/presentation/sync_settings_screen.dart
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/device_clock.dart';
import '../../../services/app_data_service.dart';
import '../../../services/sync/file_exporter.dart';
import '../../../services/sync/sync_progress.dart';
import '../../../services/sync/sync_service.dart';
import '../../../services/sync/sync_settings.dart';
import '../../daily_plan/application/daily_plan_controller.dart';
import '../../task_master/application/task_master_controller.dart';
import 'mcp_guide_section.dart';
import 'sync_progress_panel.dart';

class SyncSettingsScreen extends ConsumerStatefulWidget {
  const SyncSettingsScreen({super.key});
  @override
  ConsumerState<SyncSettingsScreen> createState() => _SyncSettingsScreenState();
}

class _SyncSettingsScreenState extends ConsumerState<SyncSettingsScreen> {
  SyncSettings? _settings;
  final _progress = SyncProgressController();

  @override
  void initState() { super.initState(); _reload(); }
  @override
  void dispose() { _progress.dispose(); super.dispose(); }

  Future<void> _reload() async { final s = await ref.read(syncSettingsStoreProvider).load(); if (mounted) setState(() => _settings = s); }

  Future<void> _showProgressAndRun(Future<SyncOutcome> Function() run) async {
    final sheet = showModalBottomSheet<void>(context: context, isDismissible: false, enableDrag: false,
      builder: (_) => SyncProgressPanel(controller: _progress, onCancel: _progress.cancel, onClose: () => Navigator.of(context).pop()));
    final outcome = await run();
    if (!mounted) return;
    if (outcome is SyncNeedsReplace) { Navigator.of(context).pop(); await _askReplace(outcome.message); }
    else if (outcome is SyncApplied) { ref.invalidate(taskMasterControllerProvider); ref.invalidate(dailyPlanControllerProvider); await _reload(); }
    await sheet;
  }

  Future<void> _askReplace(String message) async {
    final choice = await showDialog<SyncMode>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('どちらを正にしますか？'), content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('やめる')),
        TextButton(onPressed: () => Navigator.pop(ctx, SyncMode.takeHub), child: const Text('PC の状態で置き換える')),
        TextButton(onPressed: () => Navigator.pop(ctx, SyncMode.takePhone), child: const Text('この端末で PC を置き換える')),
      ]));
    if (choice != null && mounted) await _showProgressAndRun(() => ref.read(syncServiceProvider).syncNow(mode: choice, progress: _progress));
  }

  @override
  Widget build(BuildContext context) {
    final s = _settings;
    final isMac = !kIsWeb && Platform.isMacOS;
    return Scaffold(
      appBar: AppBar(title: const Text('PC と同期')),
      body: s == null ? const Center(child: CircularProgressIndicator()) : ListView(padding: const EdgeInsets.all(16), children: [
        Card(child: Column(children: [
          ListTile(title: const Text('接続状態'), subtitle: Text(s.isPaired ? '${s.host}:${s.port}（${s.hubDeviceId ?? 'hub'}）' : '未ペアリング')),
          if (s.isPaired) ListTile(title: const Text('最終同期'), subtitle: Text(s.lastSyncAt == null ? 'まだ同期していません' : DateFormat('yyyy/MM/dd HH:mm').format(s.lastSyncAt!.toLocal()))),
          ListTile(title: const Text('この端末の ID'), subtitle: Text(ref.read(deviceClockProvider).deviceId)),
        ])),
        Card(child: Column(children: [
          if (s.isPaired) ListTile(leading: const Icon(Icons.sync), title: const Text('今すぐ同期'), subtitle: const Text('同じ Wi-Fi の PC と双方向に同期します'),
            onTap: () => _showProgressAndRun(() => ref.read(syncServiceProvider).syncNow(progress: _progress))),
          ListTile(leading: const Icon(Icons.qr_code_scanner), title: const Text('PC とペアリング'), subtitle: const Text('PC の画面の QR を読み取ります'),
            onTap: () async { await context.push('/sync/pair'); await _reload(); }),
          ListTile(leading: const Icon(Icons.edit), title: const Text('接続先を手入力'), subtitle: const Text('エミュレーターや IP が変わったとき'), onTap: () => _editHost(s)),
          if (s.isPaired) ListTile(leading: const Icon(Icons.link_off), title: const Text('ペアリングを解除'), onTap: () async { await ref.read(syncSettingsStoreProvider).clear(); await _reload(); }),
        ])),
        Card(child: Column(children: [
          const ListTile(title: Text('ネットワークが違うとき'), subtitle: Text('QR かファイルでやり取りします')),
          ListTile(leading: const Icon(Icons.qr_code), title: const Text('QR で受け取る'), subtitle: const Text('PC の QR 画面にカメラを向けます'), onTap: () async { await context.push('/sync/qr'); await _reload(); }),
          ListTile(leading: const Icon(Icons.ios_share), title: const Text('PC へ書き出す'), subtitle: const Text('共有シートで JSON を送ります。アプリ自身は送信しません'),
            onTap: () async { final doc = await ref.read(appDataServiceProvider).exportDocument(); await shareExportFile(doc); }),
          if (isMac) ListTile(leading: const Icon(Icons.file_open), title: const Text('ファイルから取り込む'), subtitle: const Text('スマホが書き出した JSON をマージします'),
            onTap: () async { final path = await pickImportFile(); if (path == null || !mounted) return; _progress.start(SyncKind.file);
              await _showProgressAndRun(() async { try { final doc = await readImportFile(path); return await ref.read(syncServiceProvider).applyReceived(doc.toJson(), progress: _progress); } on FormatException catch (e) { _progress.fail('corrupt', e.message); return SyncFailed('corrupt', e.message); } }); }),
        ])),
        if (isMac) const McpGuideSection(),
      ]),
    );
  }

  Future<void> _editHost(SyncSettings s) async {
    final host = TextEditingController(text: s.host ?? '10.0.2.2'); final port = TextEditingController(text: '${s.port}');
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: const Text('接続先'), content: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: host, decoration: const InputDecoration(labelText: 'ホスト（IP）')), TextField(controller: port, decoration: const InputDecoration(labelText: 'ポート'), keyboardType: TextInputType.number)]),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('やめる')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存'))]));
    if (ok == true) { await ref.read(syncSettingsStoreProvider).save(s.copyWith(host: host.text.trim(), port: int.tryParse(port.text) ?? s.port)); await _reload(); }
  }
}
```

MCP 案内セクション（macOS のみ。ユーザーの質問「MCP の使い方や設定方法は PC 版の UI にある？」への答え）:

```dart
// lib/features/sync/presentation/mcp_guide_section.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/storage/file_backed_store.dart';

/// Shown on macOS only: where the data lives and how to enable the Claude Code hub.
class McpGuideSection extends StatelessWidget {
  const McpGuideSection({super.key});

  static const _mcpJson = '''{
  "mcpServers": {
    "frelocator-hub": { "command": "node", "args": ["tools/hub/dist/index.js"] }
  }
}''';

  @override
  Widget build(BuildContext context) {
    final dataDir = FileBackedStore.defaultDirectory();
    return Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Claude Code（MCP）と連携', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      const Text('この Mac では、Claude Code から FRELOCATOR のタスクや計画を直接編集できます。手順:'),
      const SizedBox(height: 8),
      _step(context, '1', 'リポジトリでハブをビルドする', 'cd tools/hub && npm install && npm run build'),
      _step(context, '2', 'リポジトリ直下の .mcp.json に登録する（同梱済み）', _mcpJson),
      _step(context, '3', 'Claude Code でリポジトリを開き直すと frelocator-hub が使えます。sync_status で状態を確認できます。', null),
      const SizedBox(height: 8),
      Text('データファイル', style: Theme.of(context).textTheme.labelLarge),
      SelectableText('$dataDir/data.json', style: const TextStyle(fontFamily: 'Menlo', fontSize: 12)),
      const Text('アプリとハブは同じファイルをロック付きで共有します。1 世代前は data.json.bak に残ります。', style: TextStyle(fontSize: 12)),
      const SizedBox(height: 8),
      Text('ペアリングと QR', style: Theme.of(context).textTheme.labelLarge),
      const Text('Claude Code でハブが動いている間、スマホとの LAN 同期を受け付けます。ペアリング QR は http://127.0.0.1:47821/pair、スマホへ送る QR は http://127.0.0.1:47821/qr（この Mac からのみ開けます）。', style: TextStyle(fontSize: 12)),
    ])));
  }

  Widget _step(BuildContext context, String no, String title, String? command) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text('$no. $title'),
    if (command != null) Row(children: [
      Expanded(child: SelectableText(command, style: const TextStyle(fontFamily: 'Menlo', fontSize: 12))),
      IconButton(tooltip: 'コピー', icon: const Icon(Icons.copy, size: 18), onPressed: () async { await Clipboard.setData(ClipboardData(text: command)); if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('コピーしました'))); }),
    ]),
  ]));
}
```

ペアリング読み取り画面:

```dart
// lib/features/sync/presentation/pairing_scan_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/device_clock.dart';
import '../../../services/sync/lan_sync_client.dart';
import '../../../services/sync/sync_settings.dart';

class PairingScanScreen extends ConsumerStatefulWidget {
  const PairingScanScreen({super.key});
  @override
  ConsumerState<PairingScanScreen> createState() => _PairingScanScreenState();
}

class _PairingScanScreenState extends ConsumerState<PairingScanScreen> {
  bool _busy = false; String? _error;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_busy) return;
    final raw = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
    if (raw == null) return;
    setState(() { _busy = true; _error = null; });
    try {
      final info = PairingInfo.parse(raw);
      final deviceId = ref.read(deviceClockProvider).deviceId;
      final result = await ref.read(lanSyncClientProvider).pair(info, deviceId: deviceId, deviceName: 'FRELOCATOR ($deviceId)');
      await ref.read(syncSettingsStoreProvider).save(SyncSettings(host: info.host, port: info.port, fingerprint: result.fingerprint, token: result.token, hubDeviceId: result.hubDeviceId, deviceName: 'FRELOCATOR ($deviceId)'));
      if (mounted) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('ペアリングしました'))); Navigator.of(context).pop(); }
    } on FormatException catch (e) { setState(() { _error = e.message; _busy = false; });
    } on SyncHttpException catch (e) { setState(() { _error = switch (e.code) { 'pairing_failed' => 'コードが無効か期限切れです。PC の画面を再読み込みしてください。', 'unreachable' => 'PC に届きません。同じ Wi-Fi か確認してください。', 'certificate' => '証明書が一致しません。', _ => e.message }; _busy = false; }); }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('PC とペアリング')),
    body: Column(children: [
      const Padding(padding: EdgeInsets.all(12), child: Text('PC で http://127.0.0.1:47821/pair を開き、表示された QR を読み取ります。カメラはこの QR の読み取りにだけ使います。')),
      Expanded(child: MobileScanner(onDetect: _onDetect)),
      if (_busy) const LinearProgressIndicator(),
      if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
    ]),
  );
}
```

QR 受信画面:

```dart
// lib/features/sync/presentation/qr_receive_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../services/sync/qr_chunk_codec.dart';
import '../../../services/sync/sync_progress.dart';
import '../../../services/sync/sync_service.dart';
import '../../daily_plan/application/daily_plan_controller.dart';
import '../../task_master/application/task_master_controller.dart';
import 'sync_progress_panel.dart';

class QrReceiveScreen extends ConsumerStatefulWidget {
  const QrReceiveScreen({super.key});
  @override
  ConsumerState<QrReceiveScreen> createState() => _QrReceiveScreenState();
}

class _QrReceiveScreenState extends ConsumerState<QrReceiveScreen> {
  final _set = QrFrameSet(); final _progress = SyncProgressController(); bool _done = false; String? _note;

  @override
  void initState() { super.initState(); _progress.start(SyncKind.qr); _progress.stage(SyncStage.scanning); }
  @override
  void dispose() { _progress.dispose(); super.dispose(); }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_done) return;
    for (final raw in capture.barcodes.map((b) => b.rawValue).whereType<String>()) {
      final r = _set.add(raw);
      if (r == QrAddResult.differentPayload) {
        final restart = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: const Text('別のデータです'), content: const Text('最初からやり直しますか？'), actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('いいえ')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('やり直す'))]));
        if (restart == true) { _set.reset(); _set.add(raw); }
      } else if (r == QrAddResult.crcMismatch) { _note = '読み取りエラーのコマを捨てました'; }
      _progress.frames(received: _set.received, total: _set.total, missing: _set.missing);
      if (_set.isComplete) { _done = true; await _apply(); return; }
    }
    if (mounted) setState(() {});
  }

  Future<void> _apply() async {
    _progress.stage(SyncStage.decoding);
    try {
      final json = decodeQrFrames(_set);
      await ref.read(syncServiceProvider).applyReceived(json, progress: _progress);
      ref.invalidate(taskMasterControllerProvider); ref.invalidate(dailyPlanControllerProvider);
    } on FormatException catch (e) { _progress.fail('corrupt', e.message); }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('QR で受け取る')),
    body: Column(children: [
      const Padding(padding: EdgeInsets.all(12), child: Text('PC の QR 画面（http://127.0.0.1:47821/qr）にカメラを向け続けてください。コマは繰り返し表示されるので順番は気にしなくて大丈夫です。')),
      Expanded(child: _done ? const SizedBox.shrink() : MobileScanner(onDetect: _onDetect)),
      SyncProgressPanel(controller: _progress, onCancel: () => Navigator.of(context).pop(), onClose: () => Navigator.of(context).pop()),
      if (_note != null) Text(_note!, style: Theme.of(context).textTheme.bodySmall),
    ]),
  );
}
```

ルーター: `/` の子に `GoRoute(path: 'sync', builder: (_, __) => const SyncSettingsScreen(), routes: [GoRoute(path: 'pair', builder: (_, __) => const PairingScanScreen()), GoRoute(path: 'qr', builder: (_, __) => const QrReceiveScreen())])` を追加。

導線: `category_settings_screen.dart` の一覧末尾に `ListTile(leading: Icon(Icons.devices), title: Text('PC と同期'), onTap: () => context.go('/sync'))`。ホームの下部ナビは変更しない。

`lib/app/app.dart` の再読み込み遅延: `ModalRoute.of(context)?.isCurrent == false`（ダイアログやシートが開いている）または `SyncService` が同期中（`_progress.value.isActive` を `syncInFlightProvider`（`StateProvider<bool>`）に反映）のときは `_pendingReload = true` にして、シートが閉じた／同期が終わったタイミングで invalidate する。

- [ ] **Step 4: テストを通す・目視確認**

Run: `flutter analyze && flutter test`
手動: Pixel_8 エミュレーター（ハブは `10.0.2.2:47820`。`sync_status` の pairing QR は `host=<Mac の LAN IP>` になるので、エミュレーターでは「接続先を手入力」で `10.0.2.2` に変更してから「今すぐ同期」）。進捗パネルの段階表示、キャンセル、QR 受信のコマグリッド、macOS 版の MCP 案内セクションを確認する。

- [ ] **Step 5: コミット**

```bash
git add lib/features/sync lib/app/router.dart lib/app/app.dart lib/features/task_master/presentation/category_settings_screen.dart test/features/sync
git commit -m "feat(sync): PC sync screen with pairing, progress panel, QR receive, file export and MCP guide / PC と同期の画面"
```

---

### Task 8: プライバシーポリシー・ストア情報・バージョン・リリース手順

**Files:**
- Modify: `web/privacy.html`、`web/support.html`
- Modify: `pubspec.yaml`（`version: 1.0.0+4`）
- Modify: `README.md`、`docs/android_store_assets_checklist.md`、`docs/superpowers/specs/2026-09-08-frelocator-hub-sync-design.md`（トークンの保存先を追記）

- [ ] **Step 1: privacy.html を書き換える**

「Information sharing」「Third-party services」「Data control」の段落を次に置き換える（英語のまま。既存の文体に合わせる）:

```html
<h2>Information sharing</h2>
<p>FRELOCATOR does not sell user data. The app does not send your data to any server operated by us or by third parties. When you enable "Sync with PC", the app communicates only with your own computer on the same local network, over an encrypted connection that is pinned to that computer's certificate during pairing.</p>
<h2>Third-party services</h2>
<p>The app embeds no analytics, advertising, or crash-reporting SDK. Network access is used solely for syncing with your own computer. The camera is used solely to read the pairing QR code and data QR codes shown on your computer; images are not stored or transmitted.</p>
<h2>Data control</h2>
<p>Your data stays on your devices. You can unpair the computer at any time from the app settings, and deleting the app or clearing app data on the device removes stored planning information from that device. If you choose to export your data with the share sheet, the destination is chosen by you and is outside the app's control.</p>
```

「How data is stored」の「does not provide cloud sync」を「does not use cloud sync; optional sync happens directly between your own devices」に変える。`Last updated` を `2026-09-xx`（実施日）に。

`support.html` に FAQ を 1 項目追加: 「同期できない → 同じ Wi-Fi か、PC で Claude Code（ハブ）が起動しているか、ペアリングし直す」。

- [ ] **Step 2: バージョンとドキュメント**

- `pubspec.yaml`: `version: 1.0.0+4`。
- `README.md`: 「PC と同期」の段落を追加（LAN 同期、QR、ファイル書き出し、macOS の MCP 案内）。
- `docs/android_store_assets_checklist.md`: データセーフティに「収集なしを維持。デバイス間転送のみ。転送は暗号化（TLS）」、権限に INTERNET / CAMERA の理由文を追記。
- 設計書: 「端末別トークンはスマホの shared_preferences に保存。ペアリング解除で削除」を「LAN 同期プロトコル」に追記。

- [ ] **Step 3: ビルドと提出準備**

Run: `flutter analyze && flutter test && flutter build appbundle && flutter build macos && flutter build web`
Expected: 全成功。aab は `build/app/outputs/bundle/release/app-release.aab`（版 4）。

Play Console の手順（手動、Plan 2 の実装後にユーザーが実施）: 内部テストと Alpha に版 4 のリリースを作成 → データセーフティの質問票を再確認（「暗号化して転送」に Yes） → プライバシーポリシー URL は同じ → 審査送信。

- [ ] **Step 4: コミット**

```bash
git add web/privacy.html web/support.html pubspec.yaml README.md docs/
git commit -m "docs(release): privacy policy for local sync, permissions notes, bump to 1.0.0+4 / 同期対応のポリシー更新と版上げ"
```

---

## レビュー反映（Task 1-4）

Task 1-4 実装後のレビューで入れた修正。番号はレビュー指摘の ID。

- **C1** `HttpClient(context: SecurityContext(withTrustedRoots: false))` にする。既定のトラストストアが有効だと `badCertificateCallback` は OS が弾いた証明書にしか呼ばれず、公的 CA 署名の証明書やリダイレクト先はピンを素通りする。コールバック内で 64 桁の 16 進でないフィンガープリントは拒否し、リクエストは `followRedirects = false`（ハブはリダイレクトしない）。
- **C2** `test/fixtures/tls/`（自己署名の PEM）＋ `HttpServer.bindSecure` の実 TLS テスト。正しいピン → 200、違うピン → `certificate`、64 桁でないピン → `certificate`、リダイレクト → 追随しない。`SecurityContext.defaultContext.setTrustedCertificatesBytes` でその証明書をプロセスに信頼させたうえで拒否されることを見て、`withTrustedRoots:false` が効いていることを証明する。
- **I1 / I2** ハブ JSON の無検査キャストをやめ、形が違えば `SyncHttpException(0, 'corrupt', …)`。`TypeError` / `NoSuchMethodError` / `FormatException` も `corrupt` に寄せ、`unreachable` はソケット層の失敗だけに残す。
- **I3** 応答ボディの読み出しに期限を付ける（`streamed.stream.timeout(_syncTimeout)`）。ヘッダだけ返して止まるハブでパネルが開いたままにならない。
- **I4** チャンク送出の future を `finally` で待つ（`feeding` フラグでも止める）。413 のあとに `progress.bytes` が流れ続けない。
- **I5** `AppDataService.importDocument` を `StateStore.writeAll` の 1 コミットに。
- **I6** 置き換え前バックアップ `sync_backup_v1` と `SyncService.hasBackup` / `restoreBackup()`（Task 4・Task 7 参照）。
- **I7** `lastSyncAt` はハブの応答文書から取る（フォールバックは現在 UTC）。
- **I8** `syncNow` の single-flight ガード。2 本目は `SyncFailed('busy', …)`。
- **I9** `applyReceived` が `Future<SyncOutcome>` を返し、`_mapFailure` を `syncNow` と共有する。
- **I10** `TaskMasterStateData.fromJson(strict: true)` は `settings` オブジェクトを必須にする（無ければ `FormatException`）。非 strict は v1 互換のフォールバックのまま。
- **I11** Android の mDNS は `MDnsClient(rawDatagramSocketFactory: …)` で `reusePort: false` を指定しないと `bind` に失敗する。iOS は `Info.plist` に `NSCameraUsageDescription` / `NSLocalNetworkUsageDescription` / `NSBonjourServices` を追加（リリース範囲外だが正しい状態を保つ）。
- **I12** `bad_mode` / `bad_request` / `internal` / `not_found` / `unsupported_version` / `busy` / `corrupt` の日本語文言を追加し、ハブの英語 `message` を `fallback` に渡すのをやめる（`SyncFailed.message` の詳細としてのみ残す）。
- **Task 2 レビュー（I-1 / M1〜M6）** `cancel()` は `{waitingHub, receiving, applying, saving}` かつ `kind == SyncKind.lan` のときだけ `hubMayHaveChanged`、非アクティブなら何もしない。`missingFrames` は `List.unmodifiable`、`copyWith` に `clearError` / `clearSummary`、`fraction` は `done` を先に 1 と判定、`sending` に入るたび `sentBytes` を 0 に戻す。`PairingInfo.parse` はポートを 1..65535 に制限。`retriable` は `retriableSyncCodes` 一箇所から導出し、`bad_timestamp` は `needsRepair` に入れない（文言も再ペアリングを約束しない表現に修正）。`health()` / `fetch()` は host / token 未設定なら `not_paired`。

---

## 自己レビュー

- 設計書カバレッジ: ペアリング（Task 1, 3, 7）、ピン留め TLS（Task 3）、同期 1 回で双方向（Task 4）、置き換えフロー（Task 4, 7）、mDNS フォールバック（Task 4）、エミュレーター用 host 手入力（Task 7）、QR 受信とコマグリッド（Task 5, 7）、ファイル書き出し／macOS 取り込み（Task 6, 7）、進捗の段階・経過秒・10 秒超の補足・キャンセルの意味（Task 2, 7）、再読み込みの遅延（Task 7）、プライバシーポリシー書き換え・CAMERA / INTERNET・データセーフティ（Task 1, 8）、macOS の MCP 案内（Task 7）。
- 型の整合: `SyncSettings.isPaired/baseUrl`、`PairingInfo.parse`、`SyncProgressController.start/stage/bytes/received/frames/finish/fail/cancel`、`LanSyncClient.pair/health/fetch/sync`、`SyncHttpException(status, code, message)`、`SyncService.syncNow(mode:, progress:) → SyncOutcome`、`applyReceived(json, {progress}) → Future<SyncOutcome>`、`SyncService.hasBackup` / `restoreBackup() → Future<bool>`、`StateStore.writeAll(tasks, plans)`、`QrFrameSet.add → QrAddResult`、`decodeQrFrames`、`writeExportFile/shareExportFile/readImportFile/pickImportFile`。ハブ側の HTTP 形式は Plan 2a と一致（`/sync?mode=`、`{document, summary, warnings}`、エラーコード）。
- 未決・注意: `share_plus` / `file_picker` / `mobile_scanner` の API はメジャー版で変わるので、実装時にインストール版の README を確認する。Web ビルドは LAN 同期を stub にして通す。iOS は Play のリリース範囲外だが、`Info.plist` の権限文言と `NSBonjourServices` だけは正しい状態に保つ。
