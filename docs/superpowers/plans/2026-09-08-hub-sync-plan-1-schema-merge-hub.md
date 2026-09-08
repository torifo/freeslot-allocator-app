# FRELOCATOR Hub Sync — Plan 1: スキーマ v2・マージ規則・ハブ MCP 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 全エンティティに HLC と墓標を持つスキーマ v2 へ移行し、Dart と TypeScript で同一のマージ規則を共有フィクスチャで検証し、macOS 版アプリと `frelocator-hub`（MCP サーバー）が同じ `data.json` を安全に読み書きできる状態にする。LAN 同期・QR・リリース作業は Plan 2。

**Architecture:** Flutter 側は `SyncMeta`（clock / updatedAt / deletedAt / migrated / extra）を各モデルに追加し、削除を墓標化する。`DeviceClock` が deviceId と HLC を発行する。`SyncMerger` と `InvariantChecker` は純関数で、`test/fixtures/sync_merge/` のケースを Dart と TS の両方が読む。macOS は `FileBackedStore` が `~/Library/Application Support/FRELOCATOR/data.json` をロック付き原子書き込みで扱う。ハブは `tools/hub/`（Node 22 / TypeScript）で、同じファイルを同じロックで扱う MCP stdio サーバー。

**Tech Stack:** Flutter 3 / Dart 3（flutter_riverpod 3、shared_preferences、crypto）、Node 22 / TypeScript 5（`@modelcontextprotocol/sdk`、`zod`、`proper-lockfile`、`vitest`）。

**設計書:** `docs/superpowers/specs/2026-09-08-frelocator-hub-sync-design.md`

---

## ファイル構成

Flutter（`lib/`）
- Create `lib/core/hlc.dart` — `Hlc` 値と比較、`HlcClock`（発行・受信）。
- Create `lib/core/sync_meta.dart` — `SyncMeta`（clock / updatedAt / deletedAt / migrated / extra）と JSON 変換、v1 補完。
- Create `lib/core/device_clock.dart` — `DeviceClock`（deviceId の永続化、`next()` で HLC 発行、`observe()` で受信更新）と Riverpod provider。
- Modify `lib/core/id_generator.dart` — device 成分を追加。
- Modify `lib/features/task_master/domain/task_models.dart` — 各モデルに `meta`、`TaskMasterStateData` に `settings`、墓標除外 getter、strict デコード。
- Modify `lib/features/daily_plan/domain/daily_plan_models.dart` — 同上。`date` を `YYYY-MM-DD` 文字列で保存。
- Modify `lib/features/task_master/application/task_master_controller.dart` — 削除の墓標化、書き込み時の meta 更新。
- Modify `lib/features/task_master/application/task_master_logic.dart` — `deleteCategoryFromState` の墓標化。
- Modify `lib/features/daily_plan/application/daily_plan_controller.dart` — 削除の墓標化、`duplicatePlan` の決定的 id と墓標化、meta 更新。
- Create `lib/core/content_hash.dart` — エンティティ内容ハッシュ（meta を除く正規化 JSON の SHA-256）。
- Create `lib/services/sync/sync_document.dart` — v2 エンベロープ（`SyncDocument`）、v1 → v2 変換、version 検査。
- Create `lib/services/sync/sync_merger.dart` — マージ規則。
- Create `lib/services/sync/invariant_checker.dart` — 不変条件チェック。
- Modify `lib/services/app_data_service.dart` — v2 エンベロープで export / import。
- Create `lib/services/storage/state_store.dart` — `StateStore` 抽象（`readTaskMaster` / `readDailyPlan` / `write…`）。
- Create `lib/services/storage/prefs_state_store.dart` — 既存 shared_preferences 実装。
- Create `lib/services/storage/file_backed_store.dart` — macOS 用ファイル実装（ロック、原子書き込み、bak）。
- Modify `lib/features/task_master/data/task_master_repository.dart`、`lib/features/daily_plan/data/daily_plan_repository.dart` — `StateStore` に委譲。
- Modify `macos/Runner/DebugProfile.entitlements`、`macos/Runner/Release.entitlements` — サンドボックス無効化。

共有フィクスチャ
- Create `test/fixtures/sync_merge/manifest.json` と `test/fixtures/sync_merge/*.json`。

ハブ（`tools/hub/`）
- Create `package.json`、`tsconfig.json`、`vitest.config.ts`。
- Create `src/model.ts`（型と定数）、`src/hlc.ts`、`src/hash.ts`、`src/merge.ts`、`src/invariants.ts`、`src/store.ts`、`src/ids.ts`、`src/tools.ts`（MCP ツール定義）、`src/index.ts`（stdio 起動）。
- Create `test/*.test.ts`。

---

### Task 1: HLC（ハイブリッド論理クロック）

**Files:**
- Create: `lib/core/hlc.dart`
- Test: `test/core/hlc_test.dart`

- [ ] **Step 1: 失敗するテストを書く**

```dart
// test/core/hlc_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/hlc.dart';

void main() {
  group('Hlc', () {
    test('parses and serializes the canonical string form', () {
      final hlc = Hlc.parse('1725760000000-3-android-ab12');
      expect(hlc.physical, 1725760000000);
      expect(hlc.counter, 3);
      expect(hlc.deviceId, 'android-ab12');
      expect(hlc.toString(), '1725760000000-3-android-ab12');
    });

    test('compares by physical, then counter, then deviceId', () {
      final a = Hlc(physical: 10, counter: 0, deviceId: 'b');
      final b = Hlc(physical: 10, counter: 1, deviceId: 'a');
      final c = Hlc(physical: 11, counter: 0, deviceId: 'a');
      final d = Hlc(physical: 10, counter: 0, deviceId: 'a');
      expect(a.compareTo(b) < 0, isTrue);
      expect(b.compareTo(c) < 0, isTrue);
      expect(d.compareTo(a) < 0, isTrue);
      expect(a.compareTo(Hlc.parse('10-0-b')), 0);
    });

    test('migrated sentinel sorts before any real clock', () {
      expect(Hlc.migrated.compareTo(Hlc(physical: 1, counter: 0, deviceId: 'x')) < 0, isTrue);
      expect(Hlc.migrated.toString(), '0-0-migrated');
    });
  });

  group('HlcClock', () {
    test('never goes backwards when wall clock regresses', () {
      var now = 1000;
      final clock = HlcClock(deviceId: 'dev', now: () => now);
      final first = clock.next();
      now = 900;
      final second = clock.next();
      expect(second.compareTo(first) > 0, isTrue);
      expect(second.physical, 1000);
      expect(second.counter, 1);
    });

    test('advances past an observed remote clock', () {
      final clock = HlcClock(deviceId: 'dev', now: () => 1000);
      clock.observe(Hlc(physical: 5000, counter: 2, deviceId: 'other'));
      final next = clock.next();
      expect(next.physical, 5000);
      expect(next.counter, 3);
      expect(next.deviceId, 'dev');
    });
  });
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `cd ~/dev/app/frelocator && flutter test test/core/hlc_test.dart`
Expected: FAIL（`package:frelocator/core/hlc.dart` が無い）

- [ ] **Step 3: 実装する**

```dart
// lib/core/hlc.dart
/// Hybrid logical clock value: `<physicalMillis>-<counter>-<deviceId>`.
///
/// Ordering is physical, then counter, then deviceId (lexicographic). The
/// deviceId makes the order total, so two devices never produce equal clocks.
class Hlc implements Comparable<Hlc> {
  const Hlc({
    required this.physical,
    required this.counter,
    required this.deviceId,
  });

  final int physical;
  final int counter;
  final String deviceId;

  /// Sentinel used for entities migrated from schema v1 (no clock recorded).
  static const Hlc migrated = Hlc(physical: 0, counter: 0, deviceId: 'migrated');

  bool get isMigrated => physical == 0 && counter == 0 && deviceId == 'migrated';

  static Hlc parse(String value) {
    final first = value.indexOf('-');
    final second = value.indexOf('-', first + 1);
    if (first <= 0 || second <= first) {
      throw FormatException('Invalid HLC: $value');
    }
    return Hlc(
      physical: int.parse(value.substring(0, first)),
      counter: int.parse(value.substring(first + 1, second)),
      deviceId: value.substring(second + 1),
    );
  }

  static Hlc? tryParse(String? value) {
    if (value == null) return null;
    try {
      return parse(value);
    } on FormatException {
      return null;
    }
  }

  @override
  int compareTo(Hlc other) {
    if (physical != other.physical) return physical.compareTo(other.physical);
    if (counter != other.counter) return counter.compareTo(other.counter);
    return deviceId.compareTo(other.deviceId);
  }

  @override
  String toString() => '$physical-$counter-$deviceId';

  @override
  bool operator ==(Object other) =>
      other is Hlc &&
      other.physical == physical &&
      other.counter == counter &&
      other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(physical, counter, deviceId);
}

/// Issues monotonically increasing [Hlc] values for one device.
class HlcClock {
  HlcClock({required this.deviceId, int Function()? now, Hlc? last})
      : _now = now ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch),
        _lastPhysical = last?.physical ?? 0,
        _lastCounter = last?.counter ?? 0;

  final String deviceId;
  final int Function() _now;
  int _lastPhysical;
  int _lastCounter;

  Hlc get last => Hlc(physical: _lastPhysical, counter: _lastCounter, deviceId: deviceId);

  Hlc next() {
    final wall = _now();
    if (wall > _lastPhysical) {
      _lastPhysical = wall;
      _lastCounter = 0;
    } else {
      _lastCounter += 1;
    }
    return last;
  }

  /// Folds a clock received from another device into this clock so that the
  /// next issued value is strictly greater than anything seen so far.
  void observe(Hlc remote) {
    if (remote.physical > _lastPhysical) {
      _lastPhysical = remote.physical;
      _lastCounter = remote.counter;
    } else if (remote.physical == _lastPhysical && remote.counter > _lastCounter) {
      _lastCounter = remote.counter;
    }
  }
}
```

- [ ] **Step 4: テストを通す**

Run: `flutter test test/core/hlc_test.dart`
Expected: 5 tests PASS

- [ ] **Step 5: コミット**

```bash
git add lib/core/hlc.dart test/core/hlc_test.dart
git commit -m "feat(core): add hybrid logical clock / HLC を追加"
```

---

### Task 2: SyncMeta と内容ハッシュ

**Files:**
- Create: `lib/core/sync_meta.dart`
- Create: `lib/core/content_hash.dart`
- Modify: `pubspec.yaml`（`crypto: ^3.0.6` を dependencies に追加）
- Test: `test/core/sync_meta_test.dart`、`test/core/content_hash_test.dart`

- [ ] **Step 1: 失敗するテストを書く**

```dart
// test/core/sync_meta_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/hlc.dart';
import 'package:frelocator/core/sync_meta.dart';

void main() {
  test('fromJson fills v1 defaults when meta keys are absent', () {
    final meta = SyncMeta.fromJson(<String, dynamic>{'id': 'x', 'name': 'y'});
    expect(meta.clock, Hlc.migrated);
    expect(meta.updatedAt, DateTime.utc(1970));
    expect(meta.deletedAt, isNull);
    expect(meta.migrated, isTrue);
    expect(meta.extra, isEmpty);
  });

  test('round-trips v2 keys and keeps unknown keys in extra', () {
    final json = <String, dynamic>{
      'id': 'x',
      'clock': '10-2-dev',
      'updatedAt': '2026-09-08T01:00:00.000Z',
      'deletedAt': '2026-09-08T02:00:00.000Z',
      'migrated': false,
      'futureField': 42,
    };
    final meta = SyncMeta.fromJson(json, knownKeys: const {'id'});
    expect(meta.clock, Hlc.parse('10-2-dev'));
    expect(meta.deletedAt, DateTime.utc(2026, 9, 8, 2));
    expect(meta.extra, {'futureField': 42});
    final out = <String, dynamic>{'id': 'x'}..addAll(meta.toJson());
    expect(out['clock'], '10-2-dev');
    expect(out['updatedAt'], '2026-09-08T01:00:00.000Z');
    expect(out['deletedAt'], '2026-09-08T02:00:00.000Z');
    expect(out['migrated'], false);
    expect(out['futureField'], 42);
  });

  test('stamp produces a live, non-migrated meta', () {
    final meta = SyncMeta.stamp(Hlc.parse('5-0-dev'), DateTime.utc(2026, 1, 1));
    expect(meta.isDeleted, isFalse);
    expect(meta.migrated, isFalse);
    expect(meta.tombstone(Hlc.parse('6-0-dev'), DateTime.utc(2026, 1, 2)).isDeleted, isTrue);
  });
}
```

```dart
// test/core/content_hash_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/content_hash.dart';

void main() {
  test('ignores key order and sync meta keys', () {
    final a = contentHash({'name': '仕事', 'id': 'c1', 'clock': '1-0-a', 'updatedAt': 'x'});
    final b = contentHash({'id': 'c1', 'name': '仕事', 'clock': '9-9-b', 'deletedAt': null, 'migrated': true});
    expect(a, b);
    expect(a, hasLength(64));
  });

  test('changes when content changes', () {
    expect(contentHash({'id': 'c1', 'name': 'a'}), isNot(contentHash({'id': 'c1', 'name': 'b'})));
  });
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/core/sync_meta_test.dart test/core/content_hash_test.dart`
Expected: FAIL（ファイル無し）

- [ ] **Step 3: 実装する**

`pubspec.yaml` の `dependencies:` に `crypto: ^3.0.6` を追加し `flutter pub get`。

```dart
// lib/core/sync_meta.dart
import 'hlc.dart';

/// Sync bookkeeping carried by every entity (schema v2).
class SyncMeta {
  const SyncMeta({
    required this.clock,
    required this.updatedAt,
    this.deletedAt,
    this.migrated = false,
    this.extra = const <String, dynamic>{},
  });

  static const List<String> keys = <String>['clock', 'updatedAt', 'deletedAt', 'migrated'];
  static final DateTime epoch = DateTime.utc(1970);

  final Hlc clock;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final bool migrated;
  /// Unknown keys preserved verbatim so a newer schema is not destroyed.
  final Map<String, dynamic> extra;

  bool get isDeleted => deletedAt != null;

  factory SyncMeta.stamp(Hlc clock, DateTime now) =>
      SyncMeta(clock: clock, updatedAt: now.toUtc());

  SyncMeta touch(Hlc clock, DateTime now) =>
      SyncMeta(clock: clock, updatedAt: now.toUtc(), deletedAt: deletedAt, extra: extra);

  SyncMeta tombstone(Hlc clock, DateTime now) =>
      SyncMeta(clock: clock, updatedAt: now.toUtc(), deletedAt: now.toUtc(), extra: extra);

  /// Reads meta from an entity map. Missing keys mean the record predates v2;
  /// they are filled with the deterministic migrated sentinel so both devices
  /// derive the same value. [knownKeys] are the entity's own fields; anything
  /// else (except meta keys) is kept in [extra].
  factory SyncMeta.fromJson(Map<String, dynamic> json, {Set<String> knownKeys = const <String>{}}) {
    final rawClock = json['clock'];
    final clock = rawClock is String ? (Hlc.tryParse(rawClock) ?? Hlc.migrated) : Hlc.migrated;
    final rawUpdated = json['updatedAt'];
    final updatedAt = rawClock is String && rawUpdated is String
        ? (DateTime.tryParse(rawUpdated)?.toUtc() ?? epoch)
        : epoch;
    final rawDeleted = json['deletedAt'];
    final deletedAt = rawDeleted is String ? DateTime.tryParse(rawDeleted)?.toUtc() : null;
    final migrated = rawClock is! String || (json['migrated'] as bool? ?? false);
    final extra = <String, dynamic>{
      for (final entry in json.entries)
        if (!knownKeys.contains(entry.key) && !keys.contains(entry.key)) entry.key: entry.value,
    };
    return SyncMeta(
      clock: clock,
      updatedAt: updatedAt,
      deletedAt: deletedAt,
      migrated: migrated,
      extra: extra,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        ...extra,
        'clock': clock.toString(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'deletedAt': deletedAt?.toUtc().toIso8601String(),
        'migrated': migrated,
      };
}
```

```dart
// lib/core/content_hash.dart
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'sync_meta.dart';

/// SHA-256 of the entity's content with sync meta removed and keys sorted, so
/// Dart and TypeScript compute the same value for the same entity.
String contentHash(Map<String, dynamic> entity) {
  final canonical = _canonicalize(
    Map<String, dynamic>.fromEntries(
      entity.entries.where((e) => !SyncMeta.keys.contains(e.key)),
    ),
  );
  return sha256.convert(utf8.encode(canonical)).toString();
}

String _canonicalize(dynamic value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${_canonicalize(value[k])}').join(',')}}';
  }
  if (value is List) {
    return '[${value.map(_canonicalize).join(',')}]';
  }
  return jsonEncode(value);
}
```

- [ ] **Step 4: テストを通す**

Run: `flutter test test/core/sync_meta_test.dart test/core/content_hash_test.dart`
Expected: 5 tests PASS

- [ ] **Step 5: コミット**

```bash
git add pubspec.yaml pubspec.lock lib/core/sync_meta.dart lib/core/content_hash.dart test/core/sync_meta_test.dart test/core/content_hash_test.dart
git commit -m "feat(core): add SyncMeta and canonical content hash / 同期メタと内容ハッシュを追加"
```

---

### Task 3: DeviceClock と id_generator の device 成分

**Files:**
- Create: `lib/core/device_clock.dart`
- Modify: `lib/core/id_generator.dart`
- Test: `test/core/device_clock_test.dart`、`test/core/id_generator_test.dart`

- [ ] **Step 1: 失敗するテストを書く**

```dart
// test/core/device_clock_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/device_clock.dart';
import 'package:frelocator/core/hlc.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('creates and persists a device id with platform prefix', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final clock = await DeviceClock.load(platformPrefix: 'test');
    expect(clock.deviceId, matches(RegExp(r'^test-[0-9a-f]{8}$')));
    final again = await DeviceClock.load(platformPrefix: 'test');
    expect(again.deviceId, clock.deviceId);
  });

  test('persists the last issued clock so restarts stay monotonic', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final clock = await DeviceClock.load(platformPrefix: 'test', now: () => 100);
    final issued = await clock.next();
    final reloaded = await DeviceClock.load(platformPrefix: 'test', now: () => 50);
    final later = await reloaded.next();
    expect(later.compareTo(issued) > 0, isTrue);
  });

  test('observe folds remote clocks', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final clock = await DeviceClock.load(platformPrefix: 'test', now: () => 100);
    await clock.observe(Hlc.parse('900-0-other'));
    expect((await clock.next()).physical, 900);
  });
}
```

`test/core/id_generator_test.dart` を次に置き換える。

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/id_generator.dart';

void main() {
  group('generateId', () {
    test('embeds prefix, timestamp, device fragment and random suffix', () {
      final id = generateId('slot', deviceId: 'android-ab12cd34');
      expect(id, matches(RegExp(r'^slot-\d+-ab12-[0-9a-f]{6}$')));
    });

    test('falls back to "loc0" without a device id', () {
      expect(generateId('task'), matches(RegExp(r'^task-\d+-loc0-[0-9a-f]{6}$')));
    });

    test('does not collide when called rapidly in a tight loop', () {
      final ids = <String>{
        for (var index = 0; index < 5000; index += 1) generateId('assignment', deviceId: 'x-1234'),
      };
      expect(ids.length, 5000);
    });
  });
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/core/device_clock_test.dart test/core/id_generator_test.dart`
Expected: FAIL

- [ ] **Step 3: 実装する**

```dart
// lib/core/device_clock.dart
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hlc.dart';

/// Loaded once at startup; use `ref.read(deviceClockProvider)` afterwards.
final deviceClockProvider = Provider<DeviceClock>((ref) {
  throw UnimplementedError('deviceClockProvider must be overridden in main()');
});

/// Owns this device's identity and its hybrid logical clock, persisting both.
class DeviceClock {
  DeviceClock._(this._prefs, this.deviceId, this._clock);

  static const _deviceIdKey = 'sync_device_id';
  static const _lastClockKey = 'sync_last_clock';

  final SharedPreferences _prefs;
  final String deviceId;
  final HlcClock _clock;

  static String defaultPlatformPrefix() {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isIOS) return 'ios';
    return 'other';
  }

  static Future<DeviceClock> load({String? platformPrefix, int Function()? now}) async {
    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString(_deviceIdKey);
    if (deviceId == null || deviceId.isEmpty) {
      final random = Random.secure();
      final suffix = List.generate(8, (_) => random.nextInt(16).toRadixString(16)).join();
      deviceId = '${platformPrefix ?? defaultPlatformPrefix()}-$suffix';
      await prefs.setString(_deviceIdKey, deviceId);
    }
    final last = Hlc.tryParse(prefs.getString(_lastClockKey));
    return DeviceClock._(prefs, deviceId, HlcClock(deviceId: deviceId, now: now, last: last));
  }

  Future<Hlc> next() async {
    final value = _clock.next();
    await _prefs.setString(_lastClockKey, value.toString());
    return value;
  }

  Future<void> observe(Hlc remote) async {
    _clock.observe(remote);
    await _prefs.setString(_lastClockKey, _clock.last.toString());
  }
}
```

`lib/core/id_generator.dart` を次に置き換える。

```dart
import 'dart:math';

final Random _random = Random.secure();

/// `<prefix>-<microsecondsSinceEpoch>-<device fragment>-<6 random hex chars>`.
///
/// The device fragment is the 4 characters after the platform prefix of the
/// device id (e.g. `android-ab12cd34` → `ab12`), so ids created on different
/// devices never collide even with identical timestamps and random suffixes.
/// Identifiers created by older builds are plain strings and remain valid.
String generateId(String prefix, {String? deviceId}) {
  final micros = DateTime.now().microsecondsSinceEpoch;
  final suffix = List.generate(6, (_) => _random.nextInt(16).toRadixString(16)).join();
  return '$prefix-$micros-${deviceFragment(deviceId)}-$suffix';
}

String deviceFragment(String? deviceId) {
  if (deviceId == null || deviceId.isEmpty) return 'loc0';
  final dash = deviceId.indexOf('-');
  final body = dash >= 0 ? deviceId.substring(dash + 1) : deviceId;
  return body.length >= 4 ? body.substring(0, 4) : body.padRight(4, '0');
}
```

`main.dart` で `DeviceClock.load()` を待ってから `ProviderScope(overrides: [deviceClockProvider.overrideWithValue(clock)])` を渡す。

```dart
// lib/main.dart の runApp 部分（既存の runApp を置き換える）
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final deviceClock = await DeviceClock.load();
  runApp(
    ProviderScope(
      overrides: [deviceClockProvider.overrideWithValue(deviceClock)],
      child: const FrelocatorApp(),
    ),
  );
}
```

（`FrelocatorApp` は既存のルートウィジェット名に合わせる。`grep -n "runApp" lib/main.dart` で確認。）

- [ ] **Step 4: テストを通す**

Run: `flutter test test/core/`
Expected: 全 PASS

- [ ] **Step 5: コミット**

```bash
git add lib/core/device_clock.dart lib/core/id_generator.dart lib/main.dart test/core/
git commit -m "feat(core): add DeviceClock and device fragment in ids / 端末クロックと id の端末成分"
```

---

### Task 4: モデルに SyncMeta と墓標を追加（スキーマ v2）

方針: 各エンティティに `meta`（省略時は移行由来のセンチネル）を追加する。状態クラスの通常リスト（`tasks` など）は**生きているものだけ**を持ち、削除済みは `Tombstone(id, meta)` として別リストに持つ。JSON では設計書どおり同じ配列に `deletedAt` 付きで並べ、デコード時に分ける。こうすると既存の `copyWith(tasks: …)` や画面のコードを変えずに墓標が保持される。

**Files:**
- Create: `lib/core/tombstone.dart`
- Modify: `lib/features/task_master/domain/task_models.dart`
- Modify: `lib/features/daily_plan/domain/daily_plan_models.dart`
- Test: `test/core/tombstone_test.dart`、`test/features/task_master/domain/task_models_v2_test.dart`、`test/features/daily_plan/domain/daily_plan_models_v2_test.dart`

- [ ] **Step 1: 失敗するテストを書く**

```dart
// test/core/tombstone_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/hlc.dart';
import 'package:frelocator/core/sync_meta.dart';
import 'package:frelocator/core/tombstone.dart';

void main() {
  test('serializes as an id plus meta with deletedAt', () {
    final t = Tombstone(id: 'task-1', meta: SyncMeta.stamp(Hlc.parse('1-0-a'), DateTime.utc(2026)).tombstone(Hlc.parse('2-0-a'), DateTime.utc(2026, 1, 2)));
    final json = t.toJson();
    expect(json['id'], 'task-1');
    expect(json['deletedAt'], '2026-01-02T00:00:00.000Z');
    expect(Tombstone.fromJson(json).meta.clock, Hlc.parse('2-0-a'));
  });

  test('splitDeleted separates live records from tombstones', () {
    final raw = <dynamic>[
      {'id': 'a', 'name': 'x', 'clock': '1-0-d', 'updatedAt': '2026-01-01T00:00:00.000Z', 'deletedAt': null, 'migrated': false},
      {'id': 'b', 'clock': '2-0-d', 'updatedAt': '2026-01-01T00:00:00.000Z', 'deletedAt': '2026-01-01T00:00:00.000Z', 'migrated': false},
      'garbage',
    ];
    final split = splitDeleted(raw, strict: false);
    expect(split.live.map((e) => e['id']), ['a']);
    expect(split.tombstones.map((t) => t.id), ['b']);
  });

  test('strict mode throws on unparsable entries', () {
    expect(() => splitDeleted(<dynamic>['garbage'], strict: true), throwsFormatException);
  });
}
```

```dart
// test/features/task_master/domain/task_models_v2_test.dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/hlc.dart';
import 'package:frelocator/core/sync_meta.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';

void main() {
  test('v1 payload decodes with migrated meta and default settings', () {
    final v1 = jsonEncode({
      'tasks': [
        {'id': 't1', 'title': 'a', 'kind': 'must_do', 'priority': 3, 'createdAt': '2026-01-01T00:00:00.000', 'updatedAt': '2026-01-02T00:00:00.000'}
      ],
      'mustDoCategories': [{'id': 'must-work', 'name': '仕事'}],
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
      tasks: [TaskMaster(id: 't1', title: 'a', kind: TaskKind.mustDo, priority: 3, createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026), meta: meta)],
      mustDoCategories: [TaskCategory(id: 'c1', name: 'x', meta: meta)],
      wantToDoCategories: const [],
      shareCategories: false,
      settingsMeta: meta,
      deletedTasks: [Tombstone(id: 't0', meta: meta.tombstone(Hlc.parse('11-0-dev'), DateTime.utc(2026, 9, 9)))],
    );
    final json = state.toJson();
    expect((json['tasks'] as List).length, 2, reason: 'tombstone is emitted inside the same array');
    expect(json['settings'], {'shareCategories': false, ...meta.toJson()});
    final back = TaskMasterStateData.fromJson(json);
    expect(back.tasks.single.id, 't1');
    expect(back.deletedTasks.single.id, 't0');
    expect(back.deletedTasks.single.meta.clock, Hlc.parse('11-0-dev'));
    expect(back.tasks.single.meta.clock, Hlc.parse('10-0-dev'));
  });

  test('strict decode throws on a corrupt record, lenient skips it', () {
    final json = {'tasks': ['bad'], 'mustDoCategories': [], 'wantToDoCategories': [], 'shareCategories': false};
    expect(() => TaskMasterStateData.fromJson(json, strict: true), throwsFormatException);
    expect(TaskMasterStateData.fromJson(json).tasks, isEmpty);
  });

  test('TaskMaster.toJson/fromJson keeps updatedAt in UTC', () {
    final task = TaskMaster.fromJson({'id': 't', 'title': 'x', 'kind': 'must_do', 'createdAt': '2026-01-01T09:00:00.000+09:00', 'updatedAt': '2026-01-01T09:00:00.000+09:00'});
    expect(task.toJson()['updatedAt'], '2026-01-01T00:00:00.000Z');
  });
}
```

```dart
// test/features/daily_plan/domain/daily_plan_models_v2_test.dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/hlc.dart';
import 'package:frelocator/core/sync_meta.dart';
import 'package:frelocator/features/daily_plan/domain/daily_plan_models.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';

void main() {
  test('date is stored as YYYY-MM-DD and v1 ISO datetime still parses', () {
    final plan = DailyPlan.fromJson({'id': 'p', 'date': '2026-09-08T00:00:00.000', 'createdAt': '2026-09-08T00:00:00.000', 'updatedAt': '2026-09-08T00:00:00.000'});
    expect(plan.date, DateTime(2026, 9, 8));
    expect(plan.toJson()['date'], '2026-09-08');
    expect(DailyPlan.fromJson(plan.toJson()).date, DateTime(2026, 9, 8));
  });

  test('slots and assignments carry meta and tombstones round trip', () {
    final meta = SyncMeta.stamp(Hlc.parse('3-0-dev'), DateTime.utc(2026));
    final state = DailyPlanStateData(
      plans: [DailyPlan(id: 'p', date: DateTime(2026, 9, 8), createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026), meta: meta)],
      slots: [FreeTimeSlot(id: 's', dailyPlanId: 'p', startAt: DateTime.utc(2026, 9, 8, 1), endAt: DateTime.utc(2026, 9, 8, 2), meta: meta)],
      assignments: [SlotTaskAssignment(id: 'a', dailyPlanId: 'p', slotId: 's', taskId: 't', taskTitle: 'x', taskKind: TaskKind.mustDo, startAt: DateTime.utc(2026, 9, 8, 1), endAt: DateTime.utc(2026, 9, 8, 2), sortOrder: 0, meta: meta)],
      deletedSlots: [Tombstone(id: 's0', meta: meta.tombstone(Hlc.parse('4-0-dev'), DateTime.utc(2026, 1, 2)))],
    );
    final back = DailyPlanStateData.decode(jsonEncode(state.toJson()));
    expect(back.slots.single.meta.clock, Hlc.parse('3-0-dev'));
    expect(back.deletedSlots.single.id, 's0');
    expect(back.assignments.single.meta.migrated, isFalse);
  });

  test('legacy constructors without meta default to migrated sentinel', () {
    final slot = FreeTimeSlot(id: 's', dailyPlanId: 'p', startAt: DateTime(2026), endAt: DateTime(2026, 1, 1, 1));
    expect(slot.meta.clock, Hlc.migrated);
  });
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/core/tombstone_test.dart test/features/task_master/domain/task_models_v2_test.dart test/features/daily_plan/domain/daily_plan_models_v2_test.dart`
Expected: FAIL（コンパイルエラー）

- [ ] **Step 3: 実装する**

```dart
// lib/core/tombstone.dart
import 'sync_meta.dart';

/// A deleted entity: only its id and sync meta survive.
class Tombstone {
  const Tombstone({required this.id, required this.meta});

  final String id;
  final SyncMeta meta;

  Map<String, dynamic> toJson() => <String, dynamic>{'id': id, ...meta.toJson()};

  factory Tombstone.fromJson(Map<String, dynamic> json) {
    final meta = SyncMeta.fromJson(json, knownKeys: const {'id'});
    if (!meta.isDeleted) {
      throw const FormatException('Tombstone without deletedAt');
    }
    return Tombstone(id: json['id'] as String, meta: meta);
  }
}

class SplitRecords {
  const SplitRecords({required this.live, required this.tombstones});
  final List<Map<String, dynamic>> live;
  final List<Tombstone> tombstones;
}

/// Splits a JSON array into live entity maps and tombstones.
///
/// In [strict] mode any entry that is not an object, or a tombstone that cannot
/// be parsed, throws a [FormatException] so a sync never silently drops data.
/// Otherwise bad entries are skipped, which is the behaviour startup relies on.
SplitRecords splitDeleted(dynamic raw, {required bool strict}) {
  final live = <Map<String, dynamic>>[];
  final tombstones = <Tombstone>[];
  if (raw is! List) {
    if (strict && raw != null) {
      throw const FormatException('Expected a JSON array');
    }
    return SplitRecords(live: live, tombstones: tombstones);
  }
  for (final dynamic entry in raw) {
    if (entry is! Map<String, dynamic>) {
      if (strict) throw FormatException('Expected an object, got $entry');
      continue;
    }
    if (entry['deletedAt'] is String) {
      try {
        tombstones.add(Tombstone.fromJson(entry));
      } on FormatException {
        if (strict) rethrow;
      }
      continue;
    }
    live.add(entry);
  }
  return SplitRecords(live: live, tombstones: tombstones);
}

/// Parses each live map with [parse]; strict mode rethrows parse failures.
List<T> parseLive<T>(List<Map<String, dynamic>> live, T Function(Map<String, dynamic>) parse, {required bool strict}) {
  final items = <T>[];
  for (final entry in live) {
    try {
      items.add(parse(entry));
    } catch (error) {
      if (strict) throw FormatException('Corrupt record ${entry['id']}: $error');
    }
  }
  return items;
}
```

`lib/features/task_master/domain/task_models.dart` の変更点（差分で示す。既存コードは残す）:

```dart
// 先頭の import に追加
import '../../../core/hlc.dart';
import '../../../core/sync_meta.dart';
import '../../../core/tombstone.dart';
export '../../../core/tombstone.dart' show Tombstone;

// TaskCategory
class TaskCategory {
  const TaskCategory({required this.id, required this.name, SyncMeta? meta})
      : meta = meta ?? const SyncMeta(clock: Hlc.migrated, updatedAt: _epochConst, migrated: true);

  static const _epochConst = _Epoch();  // ← const DateTime は作れないため下の実装を使う
```

Dart では `DateTime` を const にできないので、`SyncMeta` に **static getter** `SyncMeta.migratedDefault` を追加し、各モデルの `meta` は `late final` ではなく通常の final にして `meta ?? SyncMeta.migratedDefault` で初期化する（コンストラクタは `const` をやめる）。以下が実際に書くコード。

```dart
// lib/core/sync_meta.dart に追加
  /// Meta for records created by code that has not been told a clock yet
  /// (legacy constructors, v1 payloads). Deterministic on every device.
  static SyncMeta get migratedDefault =>
      SyncMeta(clock: Hlc.migrated, updatedAt: epoch, migrated: true);

  static const List<String> _taskCategoryKeys = ['id', 'name'];
```

```dart
// task_models.dart — TaskCategory 全体を置き換え
class TaskCategory {
  TaskCategory({required this.id, required this.name, SyncMeta? meta})
      : meta = meta ?? SyncMeta.migratedDefault;

  static const Set<String> jsonKeys = {'id', 'name'};

  final String id;
  final String name;
  final SyncMeta meta;

  TaskCategory copyWith({String? id, String? name, SyncMeta? meta}) {
    return TaskCategory(id: id ?? this.id, name: name ?? this.name, meta: meta ?? this.meta);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{'id': id, 'name': name, ...meta.toJson()};

  factory TaskCategory.fromJson(Map<String, dynamic> json) {
    return TaskCategory(
      id: json['id'] as String,
      name: json['name'] as String,
      meta: SyncMeta.fromJson(json, knownKeys: jsonKeys),
    );
  }
}
```

```dart
// task_models.dart — TaskMaster: フィールド追加と JSON
class TaskMaster {
  TaskMaster({
    required this.id,
    required this.title,
    required this.kind,
    required this.priority,
    required this.createdAt,
    required this.updatedAt,
    this.memo = '',
    this.categoryId,
    this.estimatedMinutes = 0,
    SyncMeta? meta,
  }) : meta = meta ?? SyncMeta.migratedDefault;

  static const Set<String> jsonKeys = {'id', 'title', 'kind', 'priority', 'createdAt', 'memo', 'categoryId', 'estimatedMinutes'};

  // 既存フィールドに加えて
  final SyncMeta meta;

  // copyWith に `SyncMeta? meta` を追加し `meta: meta ?? this.meta` を渡す。

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'kind': kind.storageKey,
    'priority': priority,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'memo': memo,
    'categoryId': categoryId,
    'estimatedMinutes': estimatedMinutes,
    ...meta.toJson(),
    // updatedAt は meta 側の値を正とし、表示用フィールドと二重管理しない。
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  factory TaskMaster.fromJson(Map<String, dynamic> json) {
    final meta = SyncMeta.fromJson(json, knownKeys: jsonKeys);
    final updatedAt = DateTime.parse(json['updatedAt'] as String).toUtc();
    return TaskMaster(
      id: json['id'] as String,
      title: json['title'] as String,
      kind: TaskKindX.fromStorageKey(json['kind'] as String),
      priority: json['priority'] as int? ?? 3,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      updatedAt: updatedAt,
      memo: json['memo'] as String? ?? '',
      categoryId: json['categoryId'] as String?,
      estimatedMinutes: json['estimatedMinutes'] as int? ?? 0,
      meta: meta.migrated ? SyncMeta(clock: Hlc.migrated, updatedAt: updatedAt, migrated: true, extra: meta.extra) : meta,
    );
  }
}
```

注意: `TaskMaster` は v1 から `updatedAt` を持つので、移行時は表示用の `updatedAt` に元の値を残しつつ、判定用 `clock` は `Hlc.migrated` にする（設計書「移行由来の値は決定的」）。

```dart
// task_models.dart — TaskMasterStateData を置き換え
class TaskMasterStateData {
  TaskMasterStateData({
    required List<TaskMaster> tasks,
    required List<TaskCategory> mustDoCategories,
    required List<TaskCategory> wantToDoCategories,
    required this.shareCategories,
    SyncMeta? settingsMeta,
    List<Tombstone> deletedTasks = const <Tombstone>[],
    List<Tombstone> deletedMustDoCategories = const <Tombstone>[],
    List<Tombstone> deletedWantToDoCategories = const <Tombstone>[],
  })  : tasks = List<TaskMaster>.unmodifiable(tasks),
        mustDoCategories = List<TaskCategory>.unmodifiable(mustDoCategories),
        wantToDoCategories = List<TaskCategory>.unmodifiable(wantToDoCategories),
        settingsMeta = settingsMeta ?? SyncMeta.migratedDefault,
        deletedTasks = List<Tombstone>.unmodifiable(deletedTasks),
        deletedMustDoCategories = List<Tombstone>.unmodifiable(deletedMustDoCategories),
        deletedWantToDoCategories = List<Tombstone>.unmodifiable(deletedWantToDoCategories);

  final List<TaskMaster> tasks;
  final List<TaskCategory> mustDoCategories;
  final List<TaskCategory> wantToDoCategories;
  final bool shareCategories;
  final SyncMeta settingsMeta;
  final List<Tombstone> deletedTasks;
  final List<Tombstone> deletedMustDoCategories;
  final List<Tombstone> deletedWantToDoCategories;

  factory TaskMasterStateData.initial() { /* 既存のまま。TaskCategory は const でなくなるので `const <TaskCategory>[...]` を `<TaskCategory>[...]` に変える */ }

  TaskMasterStateData copyWith({
    List<TaskMaster>? tasks,
    List<TaskCategory>? mustDoCategories,
    List<TaskCategory>? wantToDoCategories,
    bool? shareCategories,
    SyncMeta? settingsMeta,
    List<Tombstone>? deletedTasks,
    List<Tombstone>? deletedMustDoCategories,
    List<Tombstone>? deletedWantToDoCategories,
  }) {
    return TaskMasterStateData(
      tasks: tasks ?? this.tasks,
      mustDoCategories: mustDoCategories ?? this.mustDoCategories,
      wantToDoCategories: wantToDoCategories ?? this.wantToDoCategories,
      shareCategories: shareCategories ?? this.shareCategories,
      settingsMeta: settingsMeta ?? this.settingsMeta,
      deletedTasks: deletedTasks ?? this.deletedTasks,
      deletedMustDoCategories: deletedMustDoCategories ?? this.deletedMustDoCategories,
      deletedWantToDoCategories: deletedWantToDoCategories ?? this.deletedWantToDoCategories,
    );
  }

  List<TaskCategory> categoriesFor(TaskKind kind) => kind == TaskKind.mustDo ? mustDoCategories : wantToDoCategories;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'tasks': [...tasks.map((t) => t.toJson()), ...deletedTasks.map((t) => t.toJson())],
    'mustDoCategories': [...mustDoCategories.map((c) => c.toJson()), ...deletedMustDoCategories.map((t) => t.toJson())],
    'wantToDoCategories': [...wantToDoCategories.map((c) => c.toJson()), ...deletedWantToDoCategories.map((t) => t.toJson())],
    'settings': <String, dynamic>{'shareCategories': shareCategories, ...settingsMeta.toJson()},
  };

  String encode() => jsonEncode(toJson());

  factory TaskMasterStateData.fromJson(Map<String, dynamic> json, {bool strict = false}) {
    final tasks = splitDeleted(json['tasks'], strict: strict);
    final mustDo = splitDeleted(json['mustDoCategories'], strict: strict);
    final wantToDo = splitDeleted(json['wantToDoCategories'], strict: strict);
    final settings = json['settings'];
    final bool share;
    final SyncMeta settingsMeta;
    if (settings is Map<String, dynamic>) {
      share = settings['shareCategories'] as bool? ?? false;
      settingsMeta = SyncMeta.fromJson(settings, knownKeys: const {'shareCategories'});
    } else {
      share = json['shareCategories'] as bool? ?? false;   // v1
      settingsMeta = SyncMeta.migratedDefault;
    }
    return TaskMasterStateData(
      tasks: parseLive(tasks.live, TaskMaster.fromJson, strict: strict),
      mustDoCategories: parseLive(mustDo.live, TaskCategory.fromJson, strict: strict),
      wantToDoCategories: parseLive(wantToDo.live, TaskCategory.fromJson, strict: strict),
      shareCategories: share,
      settingsMeta: settingsMeta,
      deletedTasks: tasks.tombstones,
      deletedMustDoCategories: mustDo.tombstones,
      deletedWantToDoCategories: wantToDo.tombstones,
    );
  }

  factory TaskMasterStateData.decode(String source) { /* 既存のまま（fromJson を lenient で呼ぶ） */ }
}
```

`_decodeList` は不要になるので削除する。

`lib/features/daily_plan/domain/daily_plan_models.dart` も同じ形にする。

```dart
// 追加 import
import '../../../core/hlc.dart';
import '../../../core/sync_meta.dart';
import '../../../core/tombstone.dart';

String formatDateKey(DateTime value) {
  final d = dateOnly(value);
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// Accepts both `YYYY-MM-DD` (v2) and a full ISO datetime (v1).
DateTime parseDateKey(String value) {
  final parts = value.split('T').first.split('-');
  return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
}
```

- `DailyPlan`: `SyncMeta? meta` を追加（`const` を外す）。`jsonKeys = {'id', 'date', 'createdAt'}`。`toJson` は `'date': formatDateKey(date)`、`createdAt`/`updatedAt` を UTC ISO、`...meta.toJson()`。`fromJson` は `parseDateKey`、meta は `TaskMaster` と同じ「移行時は updatedAt を残し clock は migrated」規則。
- `FreeTimeSlot`: `SyncMeta? meta` 追加。`jsonKeys = {'id', 'dailyPlanId', 'startAt', 'endAt', 'label'}`。`startAt`/`endAt` は UTC ISO で保存し、読み込み時に `.toLocal()`（表示は端末ローカル）。
- `SlotTaskAssignment`: `SyncMeta? meta` 追加。`jsonKeys = {'id','dailyPlanId','slotId','taskId','taskTitle','taskKind','startAt','endAt','sortOrder','categoryId','categoryName','memo'}`。時刻の扱いは FreeTimeSlot と同じ。
- `DailyPlanStateData`: `deletedPlans` / `deletedSlots` / `deletedAssignments` を追加し、`toJson` は墓標を同じ配列に含め、`fromJson(json, {bool strict = false})` は `splitDeleted` + `parseLive` で分ける。`copyWith` に 3 つを追加。`_decodeList` は削除。

既存の `const TaskCategory(...)` / `const FreeTimeSlot(...)` 呼び出し（`category_settings_screen.dart`、`daily_plan_screen.dart`、テスト）から `const` を外す。`flutter analyze` で残りを洗い出す。

- [ ] **Step 4: テストを通す**

Run: `flutter analyze && flutter test`
Expected: analyze 0 issues、全テスト PASS（既存テストは `const` 除去以外の変更不要）

- [ ] **Step 5: コミット**

```bash
git add lib/core/tombstone.dart lib/core/sync_meta.dart lib/features test/
git commit -m "feat(schema): add sync meta and tombstones to all entities (v2) / 全エンティティに同期メタと墓標を追加"
```

---

### Task 5: コントローラの墓標化と meta 更新

**Files:**
- Modify: `lib/features/task_master/application/task_master_controller.dart`
- Modify: `lib/features/task_master/application/task_master_logic.dart:90-116`
- Modify: `lib/features/daily_plan/application/daily_plan_controller.dart`
- Test: `test/features/task_master/application/task_master_controller_test.dart`、`test/features/daily_plan/application/daily_plan_controller_test.dart`

- [ ] **Step 1: 失敗するテストを追加する**

`task_master_controller_test.dart` に group を追加。既存の `_sampleState()` ヘルパを使う。

```dart
  group('tombstones', () {
    test('deleteTask moves the task into deletedTasks with a newer clock', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'task_master_state_v1': _sampleState().encode(),
      });
      final container = ProviderContainer(overrides: [
        deviceClockProvider.overrideWithValue(await DeviceClock.load(platformPrefix: 'test', now: () => 1000)),
      ]);
      addTearDown(container.dispose);
      await container.read(taskMasterControllerProvider.future);
      final notifier = container.read(taskMasterControllerProvider.notifier);

      await notifier.deleteTask('must-1');

      final state = container.read(taskMasterControllerProvider).requireValue;
      expect(state.tasks.any((t) => t.id == 'must-1'), isFalse);
      expect(state.deletedTasks.single.id, 'must-1');
      expect(state.deletedTasks.single.meta.isDeleted, isTrue);
      expect(state.deletedTasks.single.meta.clock.deviceId, startsWith('test-'));
    });

    test('addOrUpdateTask stamps a fresh clock from the device', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = ProviderContainer(overrides: [
        deviceClockProvider.overrideWithValue(await DeviceClock.load(platformPrefix: 'test', now: () => 1000)),
      ]);
      addTearDown(container.dispose);
      await container.read(taskMasterControllerProvider.future);
      final notifier = container.read(taskMasterControllerProvider.notifier);

      await notifier.addOrUpdateTask(TaskMaster(id: 'new', title: 'x', kind: TaskKind.mustDo, priority: 3, createdAt: DateTime.now(), updatedAt: DateTime.now()));

      final task = container.read(taskMasterControllerProvider).requireValue.tasks.singleWhere((t) => t.id == 'new');
      expect(task.meta.migrated, isFalse);
      expect(task.meta.clock.physical, 1000);
    });

    test('deleteCategory tombstones the category and detaches tasks with a new clock', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'task_master_state_v1': _sampleState().encode(),
      });
      final container = ProviderContainer(overrides: [
        deviceClockProvider.overrideWithValue(await DeviceClock.load(platformPrefix: 'test', now: () => 1000)),
      ]);
      addTearDown(container.dispose);
      await container.read(taskMasterControllerProvider.future);
      await container.read(taskMasterControllerProvider.notifier).deleteCategory(kind: TaskKind.mustDo, categoryId: 'must-work');
      final state = container.read(taskMasterControllerProvider).requireValue;
      expect(state.mustDoCategories.any((c) => c.id == 'must-work'), isFalse);
      expect(state.deletedMustDoCategories.single.id, 'must-work');
    });
  });
```

`daily_plan_controller_test.dart` に group を追加（既存ヘルパで plan / slot / assignment を作る手順は同ファイルの既存テストに倣う）。

```dart
  group('tombstones', () {
    test('deleteSlot tombstones the slot and its assignments', () async {
      // 既存テストと同じ手順で plan → slot → assignment を作成した後:
      await notifier.deleteSlot(slot.id);
      final state = container.read(dailyPlanControllerProvider).requireValue;
      expect(state.slots, isEmpty);
      expect(state.assignments, isEmpty);
      expect(state.deletedSlots.single.id, slot.id);
      expect(state.deletedAssignments.single.id, assignment.id);
    });

    test('duplicatePlan with replaceExisting tombstones replaced records and uses deterministic ids', () async {
      // source 日に slot 1 件、target 日に slot 1 件を作った後:
      final first = await notifier.duplicatePlan(sourceDate: source, targetDate: target, replaceExisting: true);
      final state1 = container.read(dailyPlanControllerProvider).requireValue;
      expect(state1.deletedSlots, hasLength(1), reason: 'target の既存 slot が墓標になる');
      final copiedId = state1.slotsForPlan(first.id).single.id;
      expect(copiedId, matches(RegExp(r'^slot-[0-9a-f]{16}$')));

      await notifier.duplicatePlan(sourceDate: source, targetDate: target, replaceExisting: true);
      final state2 = container.read(dailyPlanControllerProvider).requireValue;
      expect(state2.slotsForPlan(first.id).single.id, isNot(copiedId), reason: '世代カウンタで墓標と衝突しない');
    });
  });
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/features/task_master/application/task_master_controller_test.dart test/features/daily_plan/application/daily_plan_controller_test.dart`
Expected: FAIL

- [ ] **Step 3: 実装する**

`task_master_controller.dart`:

```dart
import '../../../core/device_clock.dart';
import '../../../core/sync_meta.dart';
import '../../../core/tombstone.dart';

  DeviceClock get _device => ref.read(deviceClockProvider);

  Future<SyncMeta> _stamp(SyncMeta? previous) async {
    final clock = await _device.next();
    final now = DateTime.now().toUtc();
    return previous == null ? SyncMeta.stamp(clock, now) : previous.touch(clock, now);
  }

  Future<void> addOrUpdateTask(TaskMaster task) async {
    final current = _current;
    final index = current.tasks.indexWhere((item) => item.id == task.id);
    final previousMeta = index >= 0 ? current.tasks[index].meta : null;
    final sanitizedTask = sanitizeTaskAgainstCategories(task, current)
        .copyWith(meta: await _stamp(previousMeta), updatedAt: DateTime.now().toUtc());
    final tasks = List<TaskMaster>.from(current.tasks);
    if (index >= 0) { tasks[index] = sanitizedTask; } else { tasks.add(sanitizedTask); }
    await _persist(current.copyWith(tasks: _sortTasks(tasks)));
  }

  Future<void> deleteTask(String id) async {
    final current = _current;
    final target = current.tasks.where((task) => task.id == id).firstOrNull;
    if (target == null) return;
    final clock = await _device.next();
    final tombstone = Tombstone(id: id, meta: target.meta.tombstone(clock, DateTime.now().toUtc()));
    await _persist(current.copyWith(
      tasks: current.tasks.where((task) => task.id != id).toList(),
      deletedTasks: [...current.deletedTasks, tombstone],
    ));
  }
```

- `reorderTasks`: 各 task の `copyWith(priority: …, updatedAt: now, meta: await _stamp(task.meta))`。ループ内で `await` するため `for` 文に書き換える。
- `upsertCategory`: 追加・更新するカテゴリに `meta: await _stamp(previous?.meta)` を付ける。`shareCategories` でミラーする側も同じ meta。
- `deleteCategory`: `deleteCategoryFromState(current, kind:, categoryId:, clock: await _device.next(), now: DateTime.now().toUtc())` を呼ぶ。
- `setShareCategories`: `settingsMeta: await _stamp(current.settingsMeta)` を `copyWith` に渡す。

`task_master_logic.dart` の `deleteCategoryFromState` を置き換え:

```dart
TaskMasterStateData deleteCategoryFromState(
  TaskMasterStateData state, {
  required TaskKind kind,
  required String categoryId,
  required Hlc clock,
  required DateTime now,
}) {
  final mustDo = List<TaskCategory>.from(state.mustDoCategories);
  final wantToDo = List<TaskCategory>.from(state.wantToDoCategories);
  final deletedMustDo = List<Tombstone>.from(state.deletedMustDoCategories);
  final deletedWantToDo = List<Tombstone>.from(state.deletedWantToDoCategories);

  void remove(List<TaskCategory> list, List<Tombstone> graveyard) {
    final index = list.indexWhere((c) => c.id == categoryId);
    if (index < 0) return;
    graveyard.add(Tombstone(id: categoryId, meta: list[index].meta.tombstone(clock, now)));
    list.removeAt(index);
  }

  if (state.shareCategories || kind == TaskKind.mustDo) remove(mustDo, deletedMustDo);
  if (state.shareCategories || kind == TaskKind.wantToDo) remove(wantToDo, deletedWantToDo);

  final tasks = state.tasks.map((task) {
    return task.categoryId == categoryId
        ? task.copyWith(clearCategory: true, updatedAt: now, meta: task.meta.touch(clock, now))
        : task;
  }).toList();

  return state.copyWith(
    tasks: tasks,
    mustDoCategories: mustDo,
    wantToDoCategories: wantToDo,
    deletedMustDoCategories: deletedMustDo,
    deletedWantToDoCategories: deletedWantToDo,
  );
}
```

`daily_plan_controller.dart`:

```dart
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../../core/device_clock.dart';
import '../../../core/sync_meta.dart';
import '../../../core/tombstone.dart';

  DeviceClock get _device => ref.read(deviceClockProvider);

  Future<SyncMeta> _stamp(SyncMeta? previous) async {
    final clock = await _device.next();
    final now = DateTime.now().toUtc();
    return previous == null ? SyncMeta.stamp(clock, now) : previous.touch(clock, now);
  }

  /// Deterministic id for copied records so both devices produce the same id
  /// for the same copy. [generation] avoids colliding with a tombstone left by
  /// an earlier copy→delete of the same source.
  static String copyId(String prefix, String sourcePlanId, DateTime targetDate, String sourceEntityId, int generation) {
    final digest = sha256.convert(utf8.encode('$sourcePlanId|${formatDateKey(targetDate)}|$sourceEntityId|$generation')).toString();
    return '$prefix-${digest.substring(0, 16)}';
  }

  int _nextGeneration(String prefix, String sourcePlanId, DateTime targetDate, String sourceEntityId, Set<String> takenIds) {
    var generation = 0;
    while (takenIds.contains(copyId(prefix, sourcePlanId, targetDate, sourceEntityId, generation))) {
      generation += 1;
    }
    return generation;
  }
```

- `ensurePlanForDate`: 新規 plan に `meta: await _stamp(null)`、`id: generateId('plan', deviceId: _device.deviceId)`。
- `duplicatePlan`:
  - `replaceExisting` の場合、対象日の既存 slot / assignment を `where` で落とす代わりに `Tombstone(id:, meta: item.meta.tombstone(clock, now))` にして `deletedSlots` / `deletedAssignments` に積む。`clock` は 1 回の操作で `await _device.next()` を 1 度取り、複製全体で同じ clock を使ってよい（同一端末内では counter が単調なので順序は保たれる）。
  - 複製 slot の id は `copyId('slot', sourcePlan.id, normalizedTarget, slot.id, generation)`、assignment も同様に `copyId('assignment', …)`。`takenIds` は生きている id と墓標の id の和集合。
  - 複製した slot / assignment / targetPlan に `meta: SyncMeta.stamp(clock, now)` を付ける。
- `upsertSlot`: `slot.copyWith(meta: await _stamp(previous?.meta))`。`_touchPlan` は plan の `meta.touch(clock, now)` も更新する（`_touchPlans` に `clock` 引数を追加）。
- `deleteSlot`: slot と、その slot の assignment を墓標化して `deletedSlots` / `deletedAssignments` へ。
- `upsertAssignment` / `moveAssignmentToSlot`: 変更される assignment に `_stamp`。`normalizeAssignmentsForSlot` は sortOrder を書き換えるので、書き換わった assignment だけ meta を更新する（変わらないものは触らない。property test で「無変更の同期が clock を進めない」ことを確認するため）。
- `deleteAssignment`: 墓標化。
- `generateId` 呼び出しはすべて `deviceId: _device.deviceId` を渡す。

- [ ] **Step 4: テストを通す**

Run: `flutter analyze && flutter test`
Expected: 全 PASS。既存テストの `ProviderContainer()` は `deviceClockProvider` の override が必要になるので、テスト用ヘルパ `test/helpers/test_container.dart` を作って共通化する。

```dart
// test/helpers/test_container.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frelocator/core/device_clock.dart';

Future<ProviderContainer> testContainer({List<Override> overrides = const [], int Function()? now}) async {
  final clock = await DeviceClock.load(platformPrefix: 'test', now: now);
  return ProviderContainer(overrides: [deviceClockProvider.overrideWithValue(clock), ...overrides]);
}
```

- [ ] **Step 5: コミット**

```bash
git add lib/features test/
git commit -m "feat(sync): tombstone deletes and stamp HLC on every write / 削除の墓標化と書き込み時の HLC 付与"
```

---

### Task 6: v2 エンベロープ（SyncDocument）と AppDataService

**Files:**
- Create: `lib/services/sync/sync_document.dart`
- Modify: `lib/services/app_data_service.dart`
- Test: `test/services/sync/sync_document_test.dart`

- [ ] **Step 1: 失敗するテストを書く**

```dart
// test/services/sync/sync_document_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/services/sync/sync_document.dart';

void main() {
  test('parses a v1 export and upgrades it to v2', () {
    final doc = SyncDocument.fromJson({
      'version': 1,
      'exported_at': '2026-09-08T00:00:00.000Z',
      'task_master': {'tasks': [], 'mustDoCategories': [], 'wantToDoCategories': [], 'shareCategories': false},
      'daily_plan': {'plans': [], 'slots': [], 'assignments': []},
    });
    expect(doc.version, 2);
    expect(doc.deviceId, 'migrated');
    expect(doc.taskMaster.mustDoCategories, isEmpty);
  });

  test('parses v2 keys and rejects newer versions', () {
    final json = {
      'version': 2,
      'exportedAt': '2026-09-08T00:00:00.000Z',
      'deviceId': 'android-1',
      'lastSyncAt': null,
      'taskMaster': {'tasks': [], 'mustDoCategories': [], 'wantToDoCategories': [], 'settings': {'shareCategories': true}},
      'dailyPlan': {'plans': [], 'slots': [], 'assignments': []},
    };
    final doc = SyncDocument.fromJson(json);
    expect(doc.taskMaster.shareCategories, isTrue);
    expect(doc.toJson()['version'], 2);
    expect(() => SyncDocument.fromJson({...json, 'version': 3}), throwsA(isA<UnsupportedSchemaException>()));
  });

  test('strict mode propagates corrupt records', () {
    expect(
      () => SyncDocument.fromJson({'version': 2, 'exportedAt': 'x', 'deviceId': 'd', 'taskMaster': {'tasks': ['bad']}, 'dailyPlan': {}}, strict: true),
      throwsFormatException,
    );
  });
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/services/sync/sync_document_test.dart`
Expected: FAIL

- [ ] **Step 3: 実装する**

```dart
// lib/services/sync/sync_document.dart
import '../../features/daily_plan/domain/daily_plan_models.dart';
import '../../features/task_master/domain/task_models.dart';

class UnsupportedSchemaException implements Exception {
  const UnsupportedSchemaException(this.version);
  final int version;
  @override
  String toString() => 'Unsupported schema version $version (this app supports up to ${SyncDocument.schemaVersion})';
}

/// The whole-app payload exchanged between devices and written to data.json.
class SyncDocument {
  const SyncDocument({
    required this.exportedAt,
    required this.deviceId,
    required this.taskMaster,
    required this.dailyPlan,
    this.lastSyncAt,
    this.purgedBefore,
  });

  static const int schemaVersion = 2;

  final DateTime exportedAt;
  final String deviceId;
  final DateTime? lastSyncAt;
  final DateTime? purgedBefore;
  final TaskMasterStateData taskMaster;
  final DailyPlanStateData dailyPlan;

  int get version => schemaVersion;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': schemaVersion,
        'exportedAt': exportedAt.toUtc().toIso8601String(),
        'deviceId': deviceId,
        'lastSyncAt': lastSyncAt?.toUtc().toIso8601String(),
        'purgedBefore': purgedBefore?.toUtc().toIso8601String(),
        'taskMaster': taskMaster.toJson(),
        'dailyPlan': dailyPlan.toJson(),
      };

  factory SyncDocument.fromJson(Map<String, dynamic> json, {bool strict = false}) {
    final version = json['version'] as int? ?? 1;
    if (version > schemaVersion) {
      throw UnsupportedSchemaException(version);
    }
    final isV1 = version < 2;
    final taskJson = (isV1 ? json['task_master'] : json['taskMaster']) as Map<String, dynamic>? ?? const {};
    final planJson = (isV1 ? json['daily_plan'] : json['dailyPlan']) as Map<String, dynamic>? ?? const {};
    final exportedRaw = (isV1 ? json['exported_at'] : json['exportedAt']) as String?;
    return SyncDocument(
      exportedAt: DateTime.tryParse(exportedRaw ?? '')?.toUtc() ?? DateTime.utc(1970),
      deviceId: isV1 ? 'migrated' : (json['deviceId'] as String? ?? 'unknown'),
      lastSyncAt: DateTime.tryParse(json['lastSyncAt'] as String? ?? '')?.toUtc(),
      purgedBefore: DateTime.tryParse(json['purgedBefore'] as String? ?? '')?.toUtc(),
      taskMaster: TaskMasterStateData.fromJson(taskJson, strict: strict),
      dailyPlan: DailyPlanStateData.fromJson(planJson, strict: strict),
    );
  }
}
```

`lib/services/app_data_service.dart` を置き換え:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/device_clock.dart';
import '../features/daily_plan/data/daily_plan_repository.dart';
import '../features/task_master/data/task_master_repository.dart';
import 'sync/sync_document.dart';

final appDataServiceProvider = Provider<AppDataService>((ref) {
  return AppDataService(
    taskRepo: ref.read(taskMasterRepositoryProvider),
    dailyPlanRepo: ref.read(dailyPlanRepositoryProvider),
    deviceClock: ref.read(deviceClockProvider),
  );
});

class AppDataService {
  const AppDataService({required this.taskRepo, required this.dailyPlanRepo, required this.deviceClock});

  final TaskMasterRepository taskRepo;
  final DailyPlanRepository dailyPlanRepo;
  final DeviceClock deviceClock;

  Future<SyncDocument> exportDocument() async {
    return SyncDocument(
      exportedAt: DateTime.now().toUtc(),
      deviceId: deviceClock.deviceId,
      taskMaster: await taskRepo.load(),
      dailyPlan: await dailyPlanRepo.load(),
    );
  }

  Future<Map<String, dynamic>> exportAll() async => (await exportDocument()).toJson();

  /// Replaces local state with [document]. Callers that merge must do so
  /// before calling this (see SyncMerger).
  Future<void> importDocument(SyncDocument document) async {
    await taskRepo.save(document.taskMaster);
    await dailyPlanRepo.save(document.dailyPlan);
  }

  Future<void> importAll(Map<String, dynamic> data) =>
      importDocument(SyncDocument.fromJson(data, strict: true));
}
```

- [ ] **Step 4: テストを通す**

Run: `flutter test test/services/sync/sync_document_test.dart && flutter analyze`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add lib/services test/services
git commit -m "feat(sync): add v2 SyncDocument envelope / v2 エンベロープを追加"
```

---

### Task 7: SyncMerger と共有フィクスチャ

**Files:**
- Create: `lib/services/sync/sync_merger.dart`
- Create: `test/fixtures/sync_merge/manifest.json`、`test/fixtures/sync_merge/*.json`
- Test: `test/services/sync/sync_merger_fixture_test.dart`

フィクスチャは Dart と TS の両方が読む。1 ケース 1 ファイル。形式:

```json
{
  "name": "newer clock wins",
  "a": { "version": 2, "exportedAt": "…", "deviceId": "a", "taskMaster": {…}, "dailyPlan": {…} },
  "b": { … },
  "expected": { "taskMaster": {…}, "dailyPlan": {…} },
  "expectedWarnings": []
}
```

`expected` は配列の順序を無視して比較する（id でソートしてから比較）。`clock` / `updatedAt` / `deletedAt` / `migrated` を含む完全一致。

- [ ] **Step 1: フィクスチャを書く（最初の 6 ケース）**

`test/fixtures/sync_merge/manifest.json`:

```json
["01_only_in_a.json", "02_newer_clock_wins.json", "03_delete_beats_older_edit.json", "04_edit_beats_older_delete.json", "05_migrated_same_hash_no_change.json", "06_migrated_diff_hash_lexicographic.json", "07_dangling_category_kept.json", "08_settings_merge.json"]
```

共通の空スケルトン（各ケースで必要な配列だけ埋める）:

```json
{"version": 2, "exportedAt": "2026-09-08T00:00:00.000Z", "deviceId": "a",
 "taskMaster": {"tasks": [], "mustDoCategories": [], "wantToDoCategories": [], "settings": {"shareCategories": false, "clock": "0-0-migrated", "updatedAt": "1970-01-01T00:00:00.000Z", "deletedAt": null, "migrated": true}},
 "dailyPlan": {"plans": [], "slots": [], "assignments": []}}
```

`01_only_in_a.json`: A に task `t1`（clock `10-0-a`）、B は空 → expected は `t1` を含む。

`02_newer_clock_wins.json`: A と B に同じ id `t1`、A は title "old" clock `10-0-a`、B は title "new" clock `11-0-b` → expected は B の内容。逆順（B を a、A を b）でも同じ結果になることをテスト側で検証する。

`03_delete_beats_older_edit.json`: A は `t1` 生存 clock `10-0-a`、B は `t1` 墓標 clock `12-0-b` → expected は墓標（`deletedAt` あり、内容フィールド無し）。

`04_edit_beats_older_delete.json`: A は `t1` 墓標 clock `10-0-a`、B は `t1` 生存 clock `12-0-b` → expected は生存。

`05_migrated_same_hash_no_change.json`: 両方 `must-work`（名前 "仕事"、clock `0-0-migrated`）→ expected は A のものそのまま（clock は migrated のまま）。

`06_migrated_diff_hash_lexicographic.json`: 両方 clock `0-0-migrated` で名前が "仕事" と "業務" → 内容ハッシュの辞書順で大きい方。期待値はテスト作成時に `contentHash` で計算して固定する（計算手順: `dart run tool/print_hash.dart '{"id":"must-work","name":"仕事"}'`。`tool/print_hash.dart` はこのタスクで作る 5 行のスクリプト）。

`07_dangling_category_kept.json`: A に task `t1`（categoryId `c1`、clock `10-0-a`）、B に `c1` の墓標 clock `11-0-b` → expected は `t1` の categoryId が `c1` のまま（非破壊）、`c1` は墓標。`expectedWarnings` に `"task t1 references missing category c1"`。

`08_settings_merge.json`: settings の shareCategories が A false（clock `5-0-a`）、B true（clock `6-0-b`）→ expected は true と B の meta。

- [ ] **Step 2: 失敗するテストを書く**

```dart
// test/services/sync/sync_merger_fixture_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/services/sync/sync_document.dart';
import 'package:frelocator/services/sync/sync_merger.dart';

void main() {
  final dir = Directory('test/fixtures/sync_merge');
  final manifest = (jsonDecode(File('${dir.path}/manifest.json').readAsStringSync()) as List).cast<String>();

  for (final name in manifest) {
    final fixture = jsonDecode(File('${dir.path}/$name').readAsStringSync()) as Map<String, dynamic>;
    test(fixture['name'] as String, () {
      final a = SyncDocument.fromJson(fixture['a'] as Map<String, dynamic>, strict: true);
      final b = SyncDocument.fromJson(fixture['b'] as Map<String, dynamic>, strict: true);
      final expected = fixture['expected'] as Map<String, dynamic>;

      final ab = SyncMerger.merge(a, b);
      final ba = SyncMerger.merge(b, a);

      expect(normalize(ab.document.taskMaster.toJson()), normalize(expected['taskMaster']));
      expect(normalize(ab.document.dailyPlan.toJson()), normalize(expected['dailyPlan']));
      expect(normalize(ba.document.toJson()['taskMaster']), normalize(ab.document.toJson()['taskMaster']), reason: 'commutative');
      expect(ab.warnings, (fixture['expectedWarnings'] as List?)?.cast<String>() ?? <String>[]);

      final again = SyncMerger.merge(ab.document, b);
      expect(normalize(again.document.toJson()['taskMaster']), normalize(ab.document.toJson()['taskMaster']), reason: 'idempotent');
    });
  }
}

/// Sorts every entity array by id so order differences do not fail the test.
dynamic normalize(dynamic value) {
  if (value is Map) {
    return {for (final e in value.entries) e.key.toString(): normalize(e.value)};
  }
  if (value is List) {
    final items = value.map(normalize).toList();
    if (items.every((i) => i is Map && i['id'] != null)) {
      items.sort((x, y) => (x['id'] as String).compareTo(y['id'] as String));
    }
    return items;
  }
  return value;
}
```

- [ ] **Step 3: 失敗を確認する**

Run: `flutter test test/services/sync/sync_merger_fixture_test.dart`
Expected: FAIL（`sync_merger.dart` が無い）

- [ ] **Step 4: 実装する**

```dart
// lib/services/sync/sync_merger.dart
import '../../core/content_hash.dart';
import '../../core/sync_meta.dart';
import '../../core/tombstone.dart';
import '../../features/daily_plan/domain/daily_plan_models.dart';
import '../../features/task_master/domain/task_models.dart';
import 'sync_document.dart';

class MergeResult {
  const MergeResult({required this.document, required this.warnings});
  final SyncDocument document;
  final List<String> warnings;
}

/// One live-or-dead record in a form the merge can compare.
class _Record {
  _Record.live(this.id, this.json, this.meta) : tombstone = null;
  _Record.dead(Tombstone t) : id = t.id, json = null, meta = t.meta, tombstone = t;
  final String id;
  final Map<String, dynamic>? json;
  final SyncMeta meta;
  final Tombstone? tombstone;
  bool get isDead => tombstone != null;
}

/// Entity-level merge per the design spec. Pure; never mutates inputs.
class SyncMerger {
  static MergeResult merge(SyncDocument a, SyncDocument b) {
    final warnings = <String>[];

    final tasks = _mergeLists<TaskMaster>(
      aLive: a.taskMaster.tasks, aDead: a.taskMaster.deletedTasks,
      bLive: b.taskMaster.tasks, bDead: b.taskMaster.deletedTasks,
      toJson: (t) => t.toJson(), fromJson: TaskMaster.fromJson, metaOf: (t) => t.meta,
    );
    final mustDo = _mergeLists<TaskCategory>(
      aLive: a.taskMaster.mustDoCategories, aDead: a.taskMaster.deletedMustDoCategories,
      bLive: b.taskMaster.mustDoCategories, bDead: b.taskMaster.deletedMustDoCategories,
      toJson: (c) => c.toJson(), fromJson: TaskCategory.fromJson, metaOf: (c) => c.meta,
    );
    final wantToDo = _mergeLists<TaskCategory>(
      aLive: a.taskMaster.wantToDoCategories, aDead: a.taskMaster.deletedWantToDoCategories,
      bLive: b.taskMaster.wantToDoCategories, bDead: b.taskMaster.deletedWantToDoCategories,
      toJson: (c) => c.toJson(), fromJson: TaskCategory.fromJson, metaOf: (c) => c.meta,
    );
    final settingsWinner = _pick(
      _Record.live('settings', {'shareCategories': a.taskMaster.shareCategories}, a.taskMaster.settingsMeta),
      _Record.live('settings', {'shareCategories': b.taskMaster.shareCategories}, b.taskMaster.settingsMeta),
    );

    final plans = _mergeLists<DailyPlan>(
      aLive: a.dailyPlan.plans, aDead: a.dailyPlan.deletedPlans,
      bLive: b.dailyPlan.plans, bDead: b.dailyPlan.deletedPlans,
      toJson: (p) => p.toJson(), fromJson: DailyPlan.fromJson, metaOf: (p) => p.meta,
    );
    final slots = _mergeLists<FreeTimeSlot>(
      aLive: a.dailyPlan.slots, aDead: a.dailyPlan.deletedSlots,
      bLive: b.dailyPlan.slots, bDead: b.dailyPlan.deletedSlots,
      toJson: (s) => s.toJson(), fromJson: FreeTimeSlot.fromJson, metaOf: (s) => s.meta,
    );
    final assignments = _mergeLists<SlotTaskAssignment>(
      aLive: a.dailyPlan.assignments, aDead: a.dailyPlan.deletedAssignments,
      bLive: b.dailyPlan.assignments, bDead: b.dailyPlan.deletedAssignments,
      toJson: (x) => x.toJson(), fromJson: SlotTaskAssignment.fromJson, metaOf: (x) => x.meta,
    );

    // Referential warnings (non-destructive: data is kept as-is).
    final liveCategoryIds = {...mustDo.live.map((c) => c.id), ...wantToDo.live.map((c) => c.id)};
    for (final task in tasks.live) {
      if (task.categoryId != null && !liveCategoryIds.contains(task.categoryId)) {
        warnings.add('task ${task.id} references missing category ${task.categoryId}');
      }
    }
    final liveSlotIds = slots.live.map((s) => s.id).toSet();
    for (final assignment in assignments.live) {
      if (!liveSlotIds.contains(assignment.slotId)) {
        warnings.add('assignment ${assignment.id} references missing slot ${assignment.slotId}');
      }
    }
    warnings.sort();

    final document = SyncDocument(
      exportedAt: a.exportedAt.isAfter(b.exportedAt) ? a.exportedAt : b.exportedAt,
      deviceId: a.deviceId,
      lastSyncAt: a.lastSyncAt,
      purgedBefore: _later(a.purgedBefore, b.purgedBefore),
      taskMaster: TaskMasterStateData(
        tasks: tasks.live,
        mustDoCategories: mustDo.live,
        wantToDoCategories: wantToDo.live,
        shareCategories: settingsWinner.json!['shareCategories'] as bool,
        settingsMeta: settingsWinner.meta,
        deletedTasks: tasks.dead,
        deletedMustDoCategories: mustDo.dead,
        deletedWantToDoCategories: wantToDo.dead,
      ),
      dailyPlan: DailyPlanStateData(
        plans: plans.live,
        slots: slots.live,
        assignments: assignments.live,
        deletedPlans: plans.dead,
        deletedSlots: slots.dead,
        deletedAssignments: assignments.dead,
      ),
    );
    return MergeResult(document: document, warnings: warnings);
  }

  static DateTime? _later(DateTime? x, DateTime? y) {
    if (x == null) return y;
    if (y == null) return x;
    return x.isAfter(y) ? x : y;
  }

  /// Rule 3: larger clock wins. Equal clocks (only possible for migrated
  /// records) fall back to content hash: equal hash → unchanged (keep a),
  /// otherwise the lexicographically larger hash wins so both sides agree.
  static _Record _pick(_Record x, _Record y) {
    final cmp = x.meta.clock.compareTo(y.meta.clock);
    if (cmp > 0) return x;
    if (cmp < 0) return y;
    final hx = x.isDead ? '' : contentHash(x.json!);
    final hy = y.isDead ? '' : contentHash(y.json!);
    if (hx == hy) return x;
    return hx.compareTo(hy) > 0 ? x : y;
  }

  static ({List<T> live, List<Tombstone> dead}) _mergeLists<T>({
    required List<T> aLive, required List<Tombstone> aDead,
    required List<T> bLive, required List<Tombstone> bDead,
    required Map<String, dynamic> Function(T) toJson,
    required T Function(Map<String, dynamic>) fromJson,
    required SyncMeta Function(T) metaOf,
  }) {
    Map<String, _Record> index(List<T> live, List<Tombstone> dead) => {
          for (final item in live) (toJson(item)['id'] as String): _Record.live(toJson(item)['id'] as String, toJson(item), metaOf(item)),
          for (final t in dead) t.id: _Record.dead(t),
        };
    final ia = index(aLive, aDead);
    final ib = index(bLive, bDead);
    final ids = {...ia.keys, ...ib.keys}.toList()..sort();
    final live = <T>[];
    final deadOut = <Tombstone>[];
    for (final id in ids) {
      final x = ia[id];
      final y = ib[id];
      final winner = x == null ? y! : (y == null ? x : _pick(x, y));
      if (winner.isDead) {
        deadOut.add(winner.tombstone!);
      } else {
        live.add(fromJson(winner.json!));
      }
    }
    return (live: live, dead: deadOut);
  }
}
```

`tool/print_hash.dart`（フィクスチャ作成補助）:

```dart
import 'dart:convert';
import 'dart:io';
import 'package:frelocator/core/content_hash.dart';

void main(List<String> args) {
  stdout.writeln(contentHash(jsonDecode(args.first) as Map<String, dynamic>));
}
```

- [ ] **Step 5: テストを通す**

Run: `flutter test test/services/sync/sync_merger_fixture_test.dart`
Expected: 8 tests PASS。`06` の期待値は `dart run tool/print_hash.dart` の結果で埋めてから実行する。

- [ ] **Step 6: コミット**

```bash
git add lib/services/sync/sync_merger.dart test/fixtures/sync_merge test/services/sync/sync_merger_fixture_test.dart tool/print_hash.dart
git commit -m "feat(sync): entity-level merger with shared fixtures / エンティティ単位マージと共有フィクスチャ"
```

---

### Task 8: InvariantChecker と収束の property test

**Files:**
- Create: `lib/services/sync/invariant_checker.dart`
- Create: `test/fixtures/sync_invariants/manifest.json`、`test/fixtures/sync_invariants/*.json`
- Test: `test/services/sync/invariant_checker_test.dart`、`test/services/sync/sync_convergence_test.dart`

- [ ] **Step 1: 失敗するテストを書く**

```dart
// test/services/sync/invariant_checker_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/services/sync/invariant_checker.dart';
import 'package:frelocator/services/sync/sync_document.dart';

void main() {
  final dir = Directory('test/fixtures/sync_invariants');
  final manifest = (jsonDecode(File('${dir.path}/manifest.json').readAsStringSync()) as List).cast<String>();
  for (final name in manifest) {
    final fixture = jsonDecode(File('${dir.path}/$name').readAsStringSync()) as Map<String, dynamic>;
    test(fixture['name'] as String, () {
      final doc = SyncDocument.fromJson(fixture['document'] as Map<String, dynamic>, strict: true);
      final violations = InvariantChecker.check(doc);
      expect(violations.map((v) => v.code).toList(), (fixture['expectedCodes'] as List).cast<String>());
    });
  }
}
```

フィクスチャ（`document` は Task 7 のスケルトン形式、`expectedCodes` は違反コードの配列）:
- `01_clean.json` → `[]`
- `02_assignment_outside_slot.json`（assignment の endAt が slot の endAt より後）→ `["assignment_outside_slot"]`
- `03_overlapping_assignments.json`（同じ slot で時間帯が重なる 2 件）→ `["assignment_overlap"]`
- `04_sort_order_gap.json`（同 slot の sortOrder が 0,2）→ `["sort_order_not_contiguous"]`
- `05_duplicate_category_name.json`（mustDo に同名 2 件）→ `["duplicate_category_name"]`
- `06_slot_time_reversed.json`（slot の endAt <= startAt）→ `["slot_time_reversed"]`

```dart
// test/services/sync/sync_convergence_test.dart
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/hlc.dart';
import 'package:frelocator/core/sync_meta.dart';
import 'package:frelocator/core/tombstone.dart';
import 'package:frelocator/features/daily_plan/domain/daily_plan_models.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';
import 'package:frelocator/services/sync/sync_document.dart';
import 'package:frelocator/services/sync/sync_merger.dart';

/// Applies random add/edit/delete operations on two replicas, syncs them in
/// random order three times, and asserts both replicas end identical.
void main() {
  test('random operation sequences converge', () {
    for (var seed = 0; seed < 50; seed += 1) {
      final random = Random(seed);
      var a = _empty('a');
      var b = _empty('b');
      final clockA = HlcClock(deviceId: 'a', now: () => 1000 + random.nextInt(50));
      final clockB = HlcClock(deviceId: 'b', now: () => 1000 + random.nextInt(50));
      for (var step = 0; step < 20; step += 1) {
        if (random.nextBool()) { a = _mutate(a, clockA, random); } else { b = _mutate(b, clockB, random); }
        if (random.nextInt(4) == 0) {
          final merged = SyncMerger.merge(a, b).document;
          a = merged; b = merged;
          clockA.observe(_maxClock(merged)); clockB.observe(_maxClock(merged));
        }
      }
      for (var round = 0; round < 3; round += 1) {
        final merged = random.nextBool() ? SyncMerger.merge(a, b) : SyncMerger.merge(b, a);
        a = merged.document; b = merged.document;
      }
      expect(a.toJson()['taskMaster'], b.toJson()['taskMaster'], reason: 'seed $seed');
    }
  });
}

SyncDocument _empty(String device) => SyncDocument(
      exportedAt: DateTime.utc(2026), deviceId: device,
      taskMaster: TaskMasterStateData(tasks: const [], mustDoCategories: const [], wantToDoCategories: const [], shareCategories: false),
      dailyPlan: DailyPlanStateData.initial(),
    );

SyncDocument _mutate(SyncDocument doc, HlcClock clock, Random random) {
  final tasks = List<TaskMaster>.from(doc.taskMaster.tasks);
  final dead = List<Tombstone>.from(doc.taskMaster.deletedTasks);
  final now = DateTime.utc(2026, 1, 1, 0, 0, clock.last.counter);
  final op = random.nextInt(3);
  if (op == 0 || tasks.isEmpty) {
    tasks.add(TaskMaster(id: 't${random.nextInt(8)}-${clock.deviceId}', title: 'x${random.nextInt(100)}', kind: TaskKind.mustDo, priority: 3,
        createdAt: now, updatedAt: now, meta: SyncMeta.stamp(clock.next(), now)));
  } else if (op == 1) {
    final i = random.nextInt(tasks.length);
    tasks[i] = tasks[i].copyWith(title: 'y${random.nextInt(100)}', meta: tasks[i].meta.touch(clock.next(), now));
  } else {
    final removed = tasks.removeAt(random.nextInt(tasks.length));
    dead.add(Tombstone(id: removed.id, meta: removed.meta.tombstone(clock.next(), now)));
  }
  // Re-adding an id that is tombstoned is allowed; merge decides by clock.
  final seen = <String>{};
  tasks.retainWhere((t) => seen.add(t.id));
  return SyncDocument(exportedAt: doc.exportedAt, deviceId: doc.deviceId,
      taskMaster: doc.taskMaster.copyWith(tasks: tasks, deletedTasks: dead), dailyPlan: doc.dailyPlan);
}

Hlc _maxClock(SyncDocument doc) {
  var best = Hlc.migrated;
  for (final t in doc.taskMaster.tasks) { if (t.meta.clock.compareTo(best) > 0) best = t.meta.clock; }
  for (final t in doc.taskMaster.deletedTasks) { if (t.meta.clock.compareTo(best) > 0) best = t.meta.clock; }
  return best;
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/services/sync/`
Expected: FAIL（`invariant_checker.dart` が無い）

- [ ] **Step 3: 実装する**

```dart
// lib/services/sync/invariant_checker.dart
import '../../features/daily_plan/domain/daily_plan_models.dart';
import '../../features/task_master/domain/task_models.dart';
import 'sync_document.dart';

class InvariantViolation {
  const InvariantViolation(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => '$code: $message';
}

/// Checks the rules the app UI otherwise guarantees. Used by the hub before
/// writing and by the merger to report (never to mutate).
class InvariantChecker {
  static List<InvariantViolation> check(SyncDocument doc) {
    final out = <InvariantViolation>[];
    _categories(doc.taskMaster.mustDoCategories, 'mustDo', out);
    _categories(doc.taskMaster.wantToDoCategories, 'wantToDo', out);

    final slotsById = {for (final s in doc.dailyPlan.slots) s.id: s};
    for (final slot in doc.dailyPlan.slots) {
      if (!slot.endAt.isAfter(slot.startAt)) {
        out.add(InvariantViolation('slot_time_reversed', 'slot ${slot.id} ends before it starts'));
      }
    }
    final bySlot = <String, List<SlotTaskAssignment>>{};
    for (final a in doc.dailyPlan.assignments) {
      bySlot.putIfAbsent(a.slotId, () => []).add(a);
      final slot = slotsById[a.slotId];
      if (slot != null && (a.startAt.isBefore(slot.startAt) || a.endAt.isAfter(slot.endAt))) {
        out.add(InvariantViolation('assignment_outside_slot', 'assignment ${a.id} exceeds slot ${slot.id}'));
      }
    }
    for (final entry in bySlot.entries) {
      final items = List<SlotTaskAssignment>.from(entry.value)..sort((x, y) => x.sortOrder.compareTo(y.sortOrder));
      for (var i = 0; i < items.length; i += 1) {
        if (items[i].sortOrder != i) {
          out.add(InvariantViolation('sort_order_not_contiguous', 'slot ${entry.key} has gaps in sortOrder'));
          break;
        }
      }
      final byStart = List<SlotTaskAssignment>.from(entry.value)..sort((x, y) => x.startAt.compareTo(y.startAt));
      for (var i = 1; i < byStart.length; i += 1) {
        if (byStart[i].startAt.isBefore(byStart[i - 1].endAt)) {
          out.add(InvariantViolation('assignment_overlap', 'assignments ${byStart[i - 1].id} and ${byStart[i].id} overlap'));
          break;
        }
      }
    }
    return out;
  }

  static void _categories(List<TaskCategory> categories, String kind, List<InvariantViolation> out) {
    final names = <String>{};
    for (final c in categories) {
      if (!names.add(c.name)) {
        out.add(InvariantViolation('duplicate_category_name', '$kind has duplicate category "${c.name}"'));
        return;
      }
    }
  }
}
```

- [ ] **Step 4: テストを通す**

Run: `flutter test test/services/sync/`
Expected: 全 PASS（収束テストは 50 seed）

- [ ] **Step 5: コミット**

```bash
git add lib/services/sync/invariant_checker.dart test/fixtures/sync_invariants test/services/sync/
git commit -m "feat(sync): invariant checker and convergence property test / 不変条件チェックと収束テスト"
```

---

### Task 9: StateStore 抽象と macOS の FileBackedStore

**Files:**
- Create: `lib/services/storage/state_store.dart`
- Create: `lib/services/storage/prefs_state_store.dart`
- Create: `lib/services/storage/file_backed_store.dart`
- Modify: `lib/features/task_master/data/task_master_repository.dart`
- Modify: `lib/features/daily_plan/data/daily_plan_repository.dart`
- Modify: `macos/Runner/DebugProfile.entitlements`、`macos/Runner/Release.entitlements`
- Test: `test/services/storage/file_backed_store_test.dart`

- [ ] **Step 1: 失敗するテストを書く**

```dart
// test/services/storage/file_backed_store_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';
import 'package:frelocator/services/storage/file_backed_store.dart';

void main() {
  late Directory tmp;
  setUp(() async { tmp = await Directory.systemTemp.createTemp('frelocator-store-'); });
  tearDown(() async { await tmp.delete(recursive: true); });

  test('returns initial state when the file does not exist', () async {
    final store = FileBackedStore(directory: tmp.path, deviceId: 'macos-1');
    final state = await store.readTaskMaster();
    expect(state.tasks, isEmpty);
    expect(state.mustDoCategories, hasLength(3));
  });

  test('writes a v2 document atomically and keeps one .bak', () async {
    final store = FileBackedStore(directory: tmp.path, deviceId: 'macos-1');
    await store.writeTaskMaster(TaskMasterStateData.initial().copyWith(shareCategories: true));
    await store.writeTaskMaster(TaskMasterStateData.initial().copyWith(shareCategories: false));
    final json = jsonDecode(File('${tmp.path}/data.json').readAsStringSync()) as Map<String, dynamic>;
    expect(json['version'], 2);
    expect(json['deviceId'], 'macos-1');
    expect((json['taskMaster'] as Map)['settings']['shareCategories'], false);
    final bak = jsonDecode(File('${tmp.path}/data.json.bak').readAsStringSync()) as Map<String, dynamic>;
    expect((bak['taskMaster'] as Map)['settings']['shareCategories'], true);
    expect(await File('${tmp.path}/data.json.tmp').exists(), isFalse);
  });

  test('quarantines a corrupt file and starts empty', () async {
    File('${tmp.path}/data.json').writeAsStringSync('{not json');
    final store = FileBackedStore(directory: tmp.path, deviceId: 'macos-1');
    final state = await store.readDailyPlan();
    expect(state.plans, isEmpty);
    expect(tmp.listSync().any((f) => f.path.contains('data.json.broken-')), isTrue);
    expect(store.lastWarning, contains('broken'));
  });

  test('writing task master preserves daily plan data in the same file', () async {
    final store = FileBackedStore(directory: tmp.path, deviceId: 'macos-1');
    final planJson = {'plans': [{'id': 'p', 'date': '2026-09-08', 'createdAt': '2026-09-08T00:00:00.000Z', 'updatedAt': '2026-09-08T00:00:00.000Z'}], 'slots': [], 'assignments': []};
    File('${tmp.path}/data.json').writeAsStringSync(jsonEncode({'version': 2, 'exportedAt': 'x', 'deviceId': 'd', 'taskMaster': TaskMasterStateData.initial().toJson(), 'dailyPlan': planJson}));
    await store.writeTaskMaster(TaskMasterStateData.initial().copyWith(shareCategories: true));
    expect((await store.readDailyPlan()).plans.single.id, 'p');
  });

  test('detects an external change since last read', () async {
    final store = FileBackedStore(directory: tmp.path, deviceId: 'macos-1');
    await store.writeTaskMaster(TaskMasterStateData.initial());
    expect(await store.changedSinceLastRead(), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    File('${tmp.path}/data.json').writeAsStringSync('${File('${tmp.path}/data.json').readAsStringSync()} ');
    expect(await store.changedSinceLastRead(), isTrue);
  });
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/services/storage/file_backed_store_test.dart`
Expected: FAIL

- [ ] **Step 3: 実装する**

```dart
// lib/services/storage/state_store.dart
import '../../features/daily_plan/domain/daily_plan_models.dart';
import '../../features/task_master/domain/task_models.dart';

/// Where app state lives. Two implementations: shared_preferences (Android,
/// web) and a JSON file shared with the hub (macOS).
abstract class StateStore {
  Future<TaskMasterStateData> readTaskMaster();
  Future<void> writeTaskMaster(TaskMasterStateData state);
  Future<DailyPlanStateData> readDailyPlan();
  Future<void> writeDailyPlan(DailyPlanStateData state);
  /// True when something other than this store changed the backing data.
  Future<bool> changedSinceLastRead() async => false;
  String? get lastWarning => null;
}
```

```dart
// lib/services/storage/prefs_state_store.dart
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/daily_plan/domain/daily_plan_models.dart';
import '../../features/task_master/domain/task_models.dart';
import 'state_store.dart';

class PrefsStateStore extends StateStore {
  static const taskKey = 'task_master_state_v1';   // key kept for backward compatibility; payload is v2
  static const planKey = 'daily_plan_state_v1';

  Future<SharedPreferences>? _prefs;
  Future<SharedPreferences> _get() => _prefs ??= SharedPreferences.getInstance();

  @override
  Future<TaskMasterStateData> readTaskMaster() async {
    final raw = (await _get()).getString(taskKey);
    return raw == null || raw.isEmpty ? TaskMasterStateData.initial() : TaskMasterStateData.decode(raw);
  }

  @override
  Future<void> writeTaskMaster(TaskMasterStateData state) async => (await _get()).setString(taskKey, state.encode());

  @override
  Future<DailyPlanStateData> readDailyPlan() async {
    final raw = (await _get()).getString(planKey);
    return raw == null || raw.isEmpty ? DailyPlanStateData.initial() : DailyPlanStateData.decode(raw);
  }

  @override
  Future<void> writeDailyPlan(DailyPlanStateData state) async => (await _get()).setString(planKey, state.encode());
}
```

```dart
// lib/services/storage/file_backed_store.dart
import 'dart:convert';
import 'dart:io';

import '../../features/daily_plan/domain/daily_plan_models.dart';
import '../../features/task_master/domain/task_models.dart';
import '../sync/sync_document.dart';
import 'state_store.dart';

/// JSON file store shared with frelocator-hub. Reads and writes the whole
/// SyncDocument under an advisory lock and replaces the file atomically.
class FileBackedStore extends StateStore {
  FileBackedStore({required this.directory, required this.deviceId});

  static String defaultDirectory() =>
      '${Platform.environment['HOME']}/Library/Application Support/FRELOCATOR';

  final String directory;
  final String deviceId;
  String? _lastWarning;
  DateTime? _lastReadModified;
  int? _lastReadLength;

  @override
  String? get lastWarning => _lastWarning;

  File get _file => File('$directory/data.json');
  File get _lock => File('$directory/data.lock');

  Future<T> _withLock<T>(Future<T> Function() body) async {
    await Directory(directory).create(recursive: true);
    final raf = await _lock.open(mode: FileMode.write);
    await raf.lock(FileLock.blockingExclusive);
    try {
      return await body();
    } finally {
      await raf.unlock();
      await raf.close();
    }
  }

  Future<SyncDocument> _readLocked() async {
    if (!await _file.exists()) {
      return _emptyDocument();
    }
    final text = await _file.readAsString();
    final stat = await _file.stat();
    _lastReadModified = stat.modified;
    _lastReadLength = stat.size;
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) throw const FormatException('root is not an object');
      return SyncDocument.fromJson(json);
    } on FormatException catch (error) {
      final quarantine = '$directory/data.json.broken-${DateTime.now().toUtc().millisecondsSinceEpoch}';
      await _file.rename(quarantine);
      _lastWarning = 'data.json was corrupt ($error); moved to $quarantine and started with empty data (broken file kept).';
      return _emptyDocument();
    }
  }

  SyncDocument _emptyDocument() => SyncDocument(
        exportedAt: DateTime.now().toUtc(),
        deviceId: deviceId,
        taskMaster: TaskMasterStateData.initial(),
        dailyPlan: DailyPlanStateData.initial(),
      );

  Future<void> _writeLocked(SyncDocument doc) async {
    final tmp = File('$directory/data.json.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(doc.toJson()), flush: true);
    if (await _file.exists()) {
      await _file.copy('$directory/data.json.bak');
    }
    await tmp.rename(_file.path);
    final stat = await _file.stat();
    _lastReadModified = stat.modified;
    _lastReadLength = stat.size;
  }

  @override
  Future<TaskMasterStateData> readTaskMaster() => _withLock(() async => (await _readLocked()).taskMaster);

  @override
  Future<DailyPlanStateData> readDailyPlan() => _withLock(() async => (await _readLocked()).dailyPlan);

  @override
  Future<void> writeTaskMaster(TaskMasterStateData state) => _withLock(() async {
        final current = await _readLocked();
        await _writeLocked(SyncDocument(
          exportedAt: DateTime.now().toUtc(), deviceId: deviceId,
          lastSyncAt: current.lastSyncAt, purgedBefore: current.purgedBefore,
          taskMaster: state, dailyPlan: current.dailyPlan,
        ));
      });

  @override
  Future<void> writeDailyPlan(DailyPlanStateData state) => _withLock(() async {
        final current = await _readLocked();
        await _writeLocked(SyncDocument(
          exportedAt: DateTime.now().toUtc(), deviceId: deviceId,
          lastSyncAt: current.lastSyncAt, purgedBefore: current.purgedBefore,
          taskMaster: current.taskMaster, dailyPlan: state,
        ));
      });

  @override
  Future<bool> changedSinceLastRead() async {
    if (!await _file.exists()) return _lastReadLength != null;
    final stat = await _file.stat();
    return stat.modified != _lastReadModified || stat.size != _lastReadLength;
  }
}
```

Repository は `StateStore` に委譲する。`task_master_repository.dart`:

```dart
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/device_clock.dart';
import '../../../services/storage/file_backed_store.dart';
import '../../../services/storage/prefs_state_store.dart';
import '../../../services/storage/state_store.dart';
import '../domain/task_models.dart';

/// One store instance shared by both repositories (the file store keeps a
/// single document, so both must go through the same lock and cache).
final stateStoreProvider = Provider<StateStore>((ref) {
  if (!kIsWeb && Platform.isMacOS) {
    return FileBackedStore(
      directory: FileBackedStore.defaultDirectory(),
      deviceId: ref.read(deviceClockProvider).deviceId,
    );
  }
  return PrefsStateStore();
});

final taskMasterRepositoryProvider = Provider<TaskMasterRepository>((ref) {
  return TaskMasterRepository(ref.read(stateStoreProvider));
});

class TaskMasterRepository {
  TaskMasterRepository(this._store);
  final StateStore _store;

  Future<TaskMasterStateData> load() => _store.readTaskMaster();
  Future<void> save(TaskMasterStateData state) => _store.writeTaskMaster(state);
}
```

`daily_plan_repository.dart` も同様に `ref.read(stateStoreProvider)` を受け取る（`stateStoreProvider` は task_master_repository.dart から import）。既存テストの `_FailingTaskMasterRepository extends TaskMasterRepository` はコンストラクタ引数が増えるので `super(PrefsStateStore())` を渡すように直す。

macOS の前面復帰時の再読み込みは `lib/app/app.dart` に `WidgetsBindingObserver` を付け、`AppLifecycleState.resumed` で `stateStoreProvider` の `changedSinceLastRead()` が true なら `ref.invalidate(taskMasterControllerProvider)` と `ref.invalidate(dailyPlanControllerProvider)` を呼ぶ。編集ダイアログ中の遅延（設計書）は Plan 2 の UI 作業で扱う。

エンティトルメント: `macos/Runner/DebugProfile.entitlements` と `Release.entitlements` の `com.apple.security.app-sandbox` を `<false/>` にする（ファイル共有のため。設計書「サンドボックスは無効のまま配布」）。

- [ ] **Step 4: テストを通す**

Run: `flutter analyze && flutter test && flutter build macos --debug`
Expected: 全 PASS、macOS ビルド成功。起動して `~/Library/Application Support/FRELOCATOR/data.json` が生成されることを確認。

- [ ] **Step 5: コミット**

```bash
git add lib/services/storage lib/features/*/data lib/app/app.dart macos/Runner/*.entitlements test/
git commit -m "feat(storage): StateStore abstraction and macOS file-backed store / ストア抽象と macOS ファイル保存"
```

---

### Task 10: ハブの雛形（package、HLC、hash、型）

**Files:**
- Create: `tools/hub/package.json`、`tools/hub/tsconfig.json`、`tools/hub/vitest.config.ts`、`tools/hub/.gitignore`
- Create: `tools/hub/src/model.ts`、`tools/hub/src/hlc.ts`、`tools/hub/src/hash.ts`
- Test: `tools/hub/test/hlc.test.ts`、`tools/hub/test/hash.test.ts`

- [ ] **Step 1: パッケージを作る**

```json
// tools/hub/package.json
{
  "name": "frelocator-hub",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "bin": { "frelocator-hub": "dist/index.js" },
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "test": "vitest run",
    "start": "node dist/index.js"
  },
  "dependencies": {
    "@modelcontextprotocol/sdk": "^1.12.0",
    "proper-lockfile": "^4.1.2",
    "zod": "^3.23.8"
  },
  "devDependencies": {
    "@types/node": "^22.0.0",
    "@types/proper-lockfile": "^4.1.4",
    "typescript": "^5.6.0",
    "vitest": "^2.1.0"
  }
}
```

```json
// tools/hub/tsconfig.json
{
  "compilerOptions": {
    "target": "ES2022", "module": "NodeNext", "moduleResolution": "NodeNext",
    "outDir": "dist", "rootDir": "src", "strict": true, "esModuleInterop": true,
    "skipLibCheck": true, "declaration": false
  },
  "include": ["src"]
}
```

```ts
// tools/hub/vitest.config.ts
import { defineConfig } from 'vitest/config';
export default defineConfig({ test: { include: ['test/**/*.test.ts'] } });
```

`tools/hub/.gitignore`: `node_modules/` と `dist/`。

Run: `cd tools/hub && npm install`
Expected: `node_modules` 生成、エラーなし。

- [ ] **Step 2: 失敗するテストを書く**

```ts
// tools/hub/test/hlc.test.ts
import { describe, expect, it } from 'vitest';
import { Hlc, HlcClock } from '../src/hlc.js';

describe('Hlc', () => {
  it('parses and prints', () => {
    const h = Hlc.parse('1725760000000-3-android-ab12');
    expect(h.physical).toBe(1725760000000);
    expect(h.counter).toBe(3);
    expect(h.deviceId).toBe('android-ab12');
    expect(h.toString()).toBe('1725760000000-3-android-ab12');
  });
  it('orders physical, counter, deviceId', () => {
    expect(Hlc.compare(Hlc.parse('10-0-b'), Hlc.parse('10-1-a'))).toBeLessThan(0);
    expect(Hlc.compare(Hlc.parse('10-0-a'), Hlc.parse('10-0-b'))).toBeLessThan(0);
    expect(Hlc.compare(Hlc.parse('11-0-a'), Hlc.parse('10-9-z'))).toBeGreaterThan(0);
  });
  it('clock is monotonic and observes remote', () => {
    let now = 1000;
    const clock = new HlcClock('hub', () => now);
    const a = clock.next();
    now = 500;
    const b = clock.next();
    expect(Hlc.compare(b, a)).toBeGreaterThan(0);
    clock.observe(Hlc.parse('5000-2-x'));
    expect(clock.next().toString()).toBe('5000-3-hub');
  });
});
```

```ts
// tools/hub/test/hash.test.ts
import { describe, expect, it } from 'vitest';
import { contentHash } from '../src/hash.js';

describe('contentHash', () => {
  it('ignores key order and meta keys', () => {
    const a = contentHash({ name: '仕事', id: 'c1', clock: '1-0-a', updatedAt: 'x' });
    const b = contentHash({ id: 'c1', name: '仕事', migrated: true, deletedAt: null });
    expect(a).toBe(b);
    expect(a).toHaveLength(64);
  });
  it('matches the Dart implementation for a known input', () => {
    // Value produced by `dart run tool/print_hash.dart '{"id":"c1","name":"仕事"}'`.
    expect(contentHash({ id: 'c1', name: '仕事' })).toBe('<Dart で計算した 64 文字をここに貼る>');
  });
});
```

- [ ] **Step 3: 失敗を確認する**

Run: `cd tools/hub && npm test`
Expected: FAIL（モジュール無し）

- [ ] **Step 4: 実装する**

```ts
// tools/hub/src/hlc.ts
export class Hlc {
  constructor(public readonly physical: number, public readonly counter: number, public readonly deviceId: string) {}
  static readonly migrated = new Hlc(0, 0, 'migrated');
  static parse(value: string): Hlc {
    const first = value.indexOf('-');
    const second = value.indexOf('-', first + 1);
    if (first <= 0 || second <= first) throw new Error(`Invalid HLC: ${value}`);
    return new Hlc(Number(value.slice(0, first)), Number(value.slice(first + 1, second)), value.slice(second + 1));
  }
  static tryParse(value: unknown): Hlc | null {
    if (typeof value !== 'string') return null;
    try { return Hlc.parse(value); } catch { return null; }
  }
  static compare(a: Hlc, b: Hlc): number {
    if (a.physical !== b.physical) return a.physical - b.physical;
    if (a.counter !== b.counter) return a.counter - b.counter;
    return a.deviceId < b.deviceId ? -1 : a.deviceId > b.deviceId ? 1 : 0;
  }
  get isMigrated(): boolean { return this.physical === 0 && this.counter === 0 && this.deviceId === 'migrated'; }
  toString(): string { return `${this.physical}-${this.counter}-${this.deviceId}`; }
}

export class HlcClock {
  private lastPhysical: number;
  private lastCounter: number;
  constructor(public readonly deviceId: string, private readonly now: () => number = () => Date.now(), last?: Hlc) {
    this.lastPhysical = last?.physical ?? 0;
    this.lastCounter = last?.counter ?? 0;
  }
  get last(): Hlc { return new Hlc(this.lastPhysical, this.lastCounter, this.deviceId); }
  next(): Hlc {
    const wall = this.now();
    if (wall > this.lastPhysical) { this.lastPhysical = wall; this.lastCounter = 0; } else { this.lastCounter += 1; }
    return this.last;
  }
  observe(remote: Hlc): void {
    if (remote.physical > this.lastPhysical) { this.lastPhysical = remote.physical; this.lastCounter = remote.counter; }
    else if (remote.physical === this.lastPhysical && remote.counter > this.lastCounter) { this.lastCounter = remote.counter; }
  }
}
```

```ts
// tools/hub/src/hash.ts
import { createHash } from 'node:crypto';

export const META_KEYS = ['clock', 'updatedAt', 'deletedAt', 'migrated'] as const;

function canonicalize(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalize).join(',')}]`;
  if (value && typeof value === 'object') {
    const obj = value as Record<string, unknown>;
    const keys = Object.keys(obj).sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalize(obj[k])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

/** Same algorithm as lib/core/content_hash.dart: drop meta keys, sort keys, SHA-256. */
export function contentHash(entity: Record<string, unknown>): string {
  const filtered: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(entity)) if (!(META_KEYS as readonly string[]).includes(k)) filtered[k] = v;
  return createHash('sha256').update(canonicalize(filtered), 'utf8').digest('hex');
}
```

注意: Dart の `jsonEncode` は非 ASCII をエスケープしないので、TS の `JSON.stringify` と一致する。数値は Dart の `jsonEncode(1.0)` が `1.0` になる点だけ差があるが、モデルに double は無い。

```ts
// tools/hub/src/model.ts
export const SCHEMA_VERSION = 2;

export interface SyncMetaJson {
  clock: string;
  updatedAt: string;
  deletedAt: string | null;
  migrated: boolean;
}

/** Any entity: its own fields plus meta. Tombstones carry only id + meta. */
export type Entity = { id: string } & SyncMetaJson & Record<string, unknown>;

export interface TaskMasterJson {
  tasks: Entity[];
  mustDoCategories: Entity[];
  wantToDoCategories: Entity[];
  settings: { shareCategories: boolean } & SyncMetaJson;
}

export interface DailyPlanJson {
  plans: Entity[];
  slots: Entity[];
  assignments: Entity[];
}

export interface SyncDocumentJson {
  version: number;
  exportedAt: string;
  deviceId: string;
  lastSyncAt?: string | null;
  purgedBefore?: string | null;
  taskMaster: TaskMasterJson;
  dailyPlan: DailyPlanJson;
}

export const TASK_KINDS = ['must_do', 'want_to_do'] as const;
export type TaskKind = (typeof TASK_KINDS)[number];

export function isDeleted(e: Entity): boolean { return typeof e.deletedAt === 'string'; }

export function emptyDocument(deviceId: string, now = new Date()): SyncDocumentJson {
  const migrated: SyncMetaJson = { clock: '0-0-migrated', updatedAt: '1970-01-01T00:00:00.000Z', deletedAt: null, migrated: true };
  const cat = (id: string, name: string): Entity => ({ id, name, ...migrated });
  return {
    version: SCHEMA_VERSION,
    exportedAt: now.toISOString(),
    deviceId,
    lastSyncAt: null,
    purgedBefore: null,
    taskMaster: {
      tasks: [],
      mustDoCategories: [cat('must-work', '仕事'), cat('must-housework', '家事'), cat('must-admin', '雑務')],
      wantToDoCategories: [cat('want-hobby', '趣味'), cat('want-learning', '学習'), cat('want-health', '健康')],
      settings: { shareCategories: false, ...migrated },
    },
    dailyPlan: { plans: [], slots: [], assignments: [] },
  };
}
```

- [ ] **Step 5: テストを通す**

Run: `cd tools/hub && npm test`
Expected: PASS（hash の既知値は Dart 側の出力を貼ってから）

- [ ] **Step 6: コミット**

```bash
git add tools/hub
git commit -m "feat(hub): scaffold frelocator-hub with HLC and content hash / ハブ雛形と HLC・ハッシュ"
```

---

### Task 11: ハブのマージと不変条件（共有フィクスチャで検証）

**Files:**
- Create: `tools/hub/src/merge.ts`、`tools/hub/src/invariants.ts`
- Test: `tools/hub/test/merge.fixtures.test.ts`、`tools/hub/test/invariants.fixtures.test.ts`

- [ ] **Step 1: 失敗するテストを書く**

```ts
// tools/hub/test/merge.fixtures.test.ts
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { merge } from '../src/merge.js';
import type { SyncDocumentJson } from '../src/model.js';

const dir = join(__dirname, '../../../test/fixtures/sync_merge');
const manifest = JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8')) as string[];

function normalize(value: unknown): unknown {
  if (Array.isArray(value)) {
    const items = value.map(normalize) as Array<Record<string, unknown>>;
    if (items.every((i) => i && typeof i === 'object' && 'id' in i)) items.sort((a, b) => String(a.id).localeCompare(String(b.id)));
    return items;
  }
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value as Record<string, unknown>).map(([k, v]) => [k, normalize(v)]));
  }
  return value;
}

describe('merge fixtures', () => {
  for (const name of manifest) {
    const fx = JSON.parse(readFileSync(join(dir, name), 'utf8'));
    it(fx.name, () => {
      const a = fx.a as SyncDocumentJson;
      const b = fx.b as SyncDocumentJson;
      const ab = merge(a, b);
      const ba = merge(b, a);
      expect(normalize(ab.document.taskMaster)).toEqual(normalize(fx.expected.taskMaster));
      expect(normalize(ab.document.dailyPlan)).toEqual(normalize(fx.expected.dailyPlan));
      expect(normalize(ba.document.taskMaster)).toEqual(normalize(ab.document.taskMaster));
      expect(ab.warnings).toEqual(fx.expectedWarnings ?? []);
      expect(normalize(merge(ab.document, b).document.taskMaster)).toEqual(normalize(ab.document.taskMaster));
    });
  }
});
```

```ts
// tools/hub/test/invariants.fixtures.test.ts
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { checkInvariants } from '../src/invariants.js';

const dir = join(__dirname, '../../../test/fixtures/sync_invariants');
const manifest = JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8')) as string[];

describe('invariant fixtures', () => {
  for (const name of manifest) {
    const fx = JSON.parse(readFileSync(join(dir, name), 'utf8'));
    it(fx.name, () => {
      expect(checkInvariants(fx.document).map((v) => v.code)).toEqual(fx.expectedCodes);
    });
  }
});
```

- [ ] **Step 2: 失敗を確認する**

Run: `cd tools/hub && npm test`
Expected: FAIL

- [ ] **Step 3: 実装する**

```ts
// tools/hub/src/merge.ts
import { contentHash } from './hash.js';
import { Hlc } from './hlc.js';
import { isDeleted, type Entity, type SyncDocumentJson } from './model.js';

export interface MergeResult { document: SyncDocumentJson; warnings: string[]; }

/** Rule 3 + tie-break: larger clock; equal clock → equal hash keeps x, else larger hash. */
function pick(x: Entity, y: Entity): Entity {
  const cmp = Hlc.compare(Hlc.tryParse(x.clock) ?? Hlc.migrated, Hlc.tryParse(y.clock) ?? Hlc.migrated);
  if (cmp > 0) return x;
  if (cmp < 0) return y;
  const hx = isDeleted(x) ? '' : contentHash(x);
  const hy = isDeleted(y) ? '' : contentHash(y);
  if (hx === hy) return x;
  return hx > hy ? x : y;
}

function mergeList(a: Entity[], b: Entity[]): Entity[] {
  const ia = new Map(a.map((e) => [e.id, e]));
  const ib = new Map(b.map((e) => [e.id, e]));
  const ids = [...new Set([...ia.keys(), ...ib.keys()])].sort();
  return ids.map((id) => {
    const x = ia.get(id);
    const y = ib.get(id);
    if (!x) return y!;
    if (!y) return x;
    return pick(x, y);
  });
}

export function merge(a: SyncDocumentJson, b: SyncDocumentJson): MergeResult {
  const tasks = mergeList(a.taskMaster.tasks, b.taskMaster.tasks);
  const mustDo = mergeList(a.taskMaster.mustDoCategories, b.taskMaster.mustDoCategories);
  const wantToDo = mergeList(a.taskMaster.wantToDoCategories, b.taskMaster.wantToDoCategories);
  const settings = pick({ id: 'settings', ...a.taskMaster.settings }, { id: 'settings', ...b.taskMaster.settings });
  const plans = mergeList(a.dailyPlan.plans, b.dailyPlan.plans);
  const slots = mergeList(a.dailyPlan.slots, b.dailyPlan.slots);
  const assignments = mergeList(a.dailyPlan.assignments, b.dailyPlan.assignments);

  const warnings: string[] = [];
  const liveCats = new Set([...mustDo, ...wantToDo].filter((c) => !isDeleted(c)).map((c) => c.id));
  for (const t of tasks) if (!isDeleted(t) && t.categoryId && !liveCats.has(String(t.categoryId))) warnings.push(`task ${t.id} references missing category ${t.categoryId}`);
  const liveSlots = new Set(slots.filter((s) => !isDeleted(s)).map((s) => s.id));
  for (const x of assignments) if (!isDeleted(x) && !liveSlots.has(String(x.slotId))) warnings.push(`assignment ${x.id} references missing slot ${x.slotId}`);
  warnings.sort();

  const { id: _drop, ...settingsOut } = settings;
  const later = (x?: string | null, y?: string | null) => (!x ? y ?? null : !y ? x : x > y ? x : y);
  return {
    document: {
      version: 2,
      exportedAt: a.exportedAt > b.exportedAt ? a.exportedAt : b.exportedAt,
      deviceId: a.deviceId,
      lastSyncAt: a.lastSyncAt ?? null,
      purgedBefore: later(a.purgedBefore, b.purgedBefore),
      taskMaster: { tasks, mustDoCategories: mustDo, wantToDoCategories: wantToDo, settings: settingsOut as SyncDocumentJson['taskMaster']['settings'] },
      dailyPlan: { plans, slots, assignments },
    },
    warnings,
  };
}
```

Dart 側の `toJson()` は生存レコードと墓標を同じ配列に出すので、フィクスチャ形式は上の TS 表現と一致する。

```ts
// tools/hub/src/invariants.ts
import { isDeleted, type Entity, type SyncDocumentJson } from './model.js';

export interface Violation { code: string; message: string; }

export function checkInvariants(doc: SyncDocumentJson): Violation[] {
  const out: Violation[] = [];
  const dupe = (list: Entity[], kind: string) => {
    const names = new Set<string>();
    for (const c of list.filter((e) => !isDeleted(e))) {
      const name = String(c.name);
      if (names.has(name)) { out.push({ code: 'duplicate_category_name', message: `${kind} has duplicate category "${name}"` }); return; }
      names.add(name);
    }
  };
  dupe(doc.taskMaster.mustDoCategories, 'mustDo');
  dupe(doc.taskMaster.wantToDoCategories, 'wantToDo');

  const slots = doc.dailyPlan.slots.filter((s) => !isDeleted(s));
  const slotById = new Map(slots.map((s) => [s.id, s]));
  for (const s of slots) if (String(s.endAt) <= String(s.startAt)) out.push({ code: 'slot_time_reversed', message: `slot ${s.id} ends before it starts` });

  const bySlot = new Map<string, Entity[]>();
  for (const a of doc.dailyPlan.assignments.filter((e) => !isDeleted(e))) {
    const list = bySlot.get(String(a.slotId)) ?? [];
    list.push(a);
    bySlot.set(String(a.slotId), list);
    const slot = slotById.get(String(a.slotId));
    if (slot && (String(a.startAt) < String(slot.startAt) || String(a.endAt) > String(slot.endAt))) {
      out.push({ code: 'assignment_outside_slot', message: `assignment ${a.id} exceeds slot ${slot.id}` });
    }
  }
  for (const [slotId, list] of bySlot) {
    const byOrder = [...list].sort((x, y) => Number(x.sortOrder) - Number(y.sortOrder));
    if (byOrder.some((a, i) => Number(a.sortOrder) !== i)) out.push({ code: 'sort_order_not_contiguous', message: `slot ${slotId} has gaps in sortOrder` });
    const byStart = [...list].sort((x, y) => String(x.startAt).localeCompare(String(y.startAt)));
    for (let i = 1; i < byStart.length; i += 1) {
      if (String(byStart[i].startAt) < String(byStart[i - 1].endAt)) { out.push({ code: 'assignment_overlap', message: `assignments ${byStart[i - 1].id} and ${byStart[i].id} overlap` }); break; }
    }
  }
  return out;
}
```

時刻は全て UTC ISO 文字列（Task 4 で保証）なので文字列比較で順序が正しい。

- [ ] **Step 4: テストを通す**

Run: `cd tools/hub && npm test`
Expected: Dart と同じ 8 + 6 ケースが PASS

- [ ] **Step 5: コミット**

```bash
git add tools/hub/src/merge.ts tools/hub/src/invariants.ts tools/hub/test
git commit -m "feat(hub): merge and invariant checks sharing Dart fixtures / ハブのマージと不変条件（共有フィクスチャ）"
```

---

### Task 12: ハブのファイルストア（ロック・原子書き込み・bak・undo）と id 採番

**Files:**
- Create: `tools/hub/src/store.ts`、`tools/hub/src/ids.ts`
- Test: `tools/hub/test/store.test.ts`、`tools/hub/test/ids.test.ts`

- [ ] **Step 1: 失敗するテストを書く**

```ts
// tools/hub/test/store.test.ts
import { mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { FileStore } from '../src/store.js';

let dir: string;
beforeEach(() => { dir = mkdtempSync(join(tmpdir(), 'hub-store-')); });
afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

describe('FileStore', () => {
  it('creates an empty v2 document when missing', async () => {
    const store = new FileStore(dir, 'hub');
    const doc = await store.read();
    expect(doc.version).toBe(2);
    expect(doc.taskMaster.mustDoCategories).toHaveLength(3);
    expect(existsSync(join(dir, 'data.json'))).toBe(false);
  });

  it('update() writes atomically, keeps .bak, and undo restores it', async () => {
    const store = new FileStore(dir, 'hub');
    await store.update((d) => { d.taskMaster.settings.shareCategories = true; return d; });
    await store.update((d) => { d.taskMaster.settings.shareCategories = false; return d; });
    expect(JSON.parse(readFileSync(join(dir, 'data.json'), 'utf8')).taskMaster.settings.shareCategories).toBe(false);
    expect(JSON.parse(readFileSync(join(dir, 'data.json.bak'), 'utf8')).taskMaster.settings.shareCategories).toBe(true);
    await store.undoLastWrite();
    expect((await store.read()).taskMaster.settings.shareCategories).toBe(true);
    expect(existsSync(join(dir, 'data.json.tmp'))).toBe(false);
  });

  it('quarantines corrupt data and reports a warning', async () => {
    writeFileSync(join(dir, 'data.json'), '{bad');
    const store = new FileStore(dir, 'hub');
    const doc = await store.read();
    expect(doc.taskMaster.tasks).toEqual([]);
    expect(store.lastWarning).toContain('broken');
  });

  it('rejects a document with a newer schema version', async () => {
    writeFileSync(join(dir, 'data.json'), JSON.stringify({ version: 3 }));
    await expect(new FileStore(dir, 'hub').read()).rejects.toThrow(/version 3/);
  });

  it('serializes concurrent updates', async () => {
    const store = new FileStore(dir, 'hub');
    await Promise.all(Array.from({ length: 10 }, (_, i) => store.update((d) => { d.taskMaster.tasks.push({ id: `t${i}`, title: 'x', clock: `${i}-0-hub`, updatedAt: 'x', deletedAt: null, migrated: false }); return d; })));
    expect((await store.read()).taskMaster.tasks).toHaveLength(10);
  });
});
```

```ts
// tools/hub/test/ids.test.ts
import { describe, expect, it } from 'vitest';
import { generateId, copyId } from '../src/ids.js';

describe('ids', () => {
  it('matches the Dart format with a device fragment', () => {
    expect(generateId('task', 'hub-1234abcd')).toMatch(/^task-\d+-1234-[0-9a-f]{6}$/);
  });
  it('copyId is deterministic and generation-aware', () => {
    const a = copyId('slot', 'plan-1', '2026-09-09', 'slot-1', 0);
    expect(a).toBe(copyId('slot', 'plan-1', '2026-09-09', 'slot-1', 0));
    expect(a).not.toBe(copyId('slot', 'plan-1', '2026-09-09', 'slot-1', 1));
    expect(a).toMatch(/^slot-[0-9a-f]{16}$/);
  });
});
```

- [ ] **Step 2: 失敗を確認する**

Run: `cd tools/hub && npm test`
Expected: FAIL

- [ ] **Step 3: 実装する**

```ts
// tools/hub/src/ids.ts
import { createHash, randomBytes } from 'node:crypto';

export function deviceFragment(deviceId?: string): string {
  if (!deviceId) return 'loc0';
  const dash = deviceId.indexOf('-');
  const body = dash >= 0 ? deviceId.slice(dash + 1) : deviceId;
  return body.length >= 4 ? body.slice(0, 4) : body.padEnd(4, '0');
}

/** `<prefix>-<microsSinceEpoch>-<device fragment>-<6 hex>` — same as lib/core/id_generator.dart. */
export function generateId(prefix: string, deviceId?: string): string {
  const micros = BigInt(Date.now()) * 1000n + BigInt(process.hrtime.bigint() % 1000n);
  return `${prefix}-${micros}-${deviceFragment(deviceId)}-${randomBytes(3).toString('hex')}`;
}

/** Same as DailyPlanController.copyId in Dart. */
export function copyId(prefix: string, sourcePlanId: string, targetDate: string, sourceEntityId: string, generation: number): string {
  const digest = createHash('sha256').update(`${sourcePlanId}|${targetDate}|${sourceEntityId}|${generation}`, 'utf8').digest('hex');
  return `${prefix}-${digest.slice(0, 16)}`;
}
```

```ts
// tools/hub/src/store.ts
import { copyFile, mkdir, readFile, rename, stat, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import lockfile from 'proper-lockfile';
import { emptyDocument, SCHEMA_VERSION, type SyncDocumentJson } from './model.js';

export class UnsupportedSchemaError extends Error {
  constructor(public readonly version: number) { super(`Unsupported schema version ${version} (hub supports up to ${SCHEMA_VERSION})`); }
}

/** Owns data.json. Every read/update runs under the shared advisory lock. */
export class FileStore {
  lastWarning: string | null = null;
  private chain: Promise<unknown> = Promise.resolve();

  constructor(public readonly directory: string, public readonly deviceId: string) {}

  static defaultDirectory(): string {
    return join(process.env.HOME ?? '.', 'Library', 'Application Support', 'FRELOCATOR');
  }

  get filePath(): string { return join(this.directory, 'data.json'); }
  private get lockPath(): string { return join(this.directory, 'data.lock'); }

  /** Serializes calls in-process and takes the cross-process lock. */
  private async withLock<T>(body: () => Promise<T>): Promise<T> {
    const run = async () => {
      await mkdir(this.directory, { recursive: true });
      if (!existsSync(this.lockPath)) await writeFile(this.lockPath, '');
      const release = await lockfile.lock(this.lockPath, { retries: { retries: 50, minTimeout: 20, maxTimeout: 200 } });
      try { return await body(); } finally { await release(); }
    };
    const next = this.chain.then(run, run);
    this.chain = next.catch(() => undefined);
    return next;
  }

  private async readLocked(): Promise<SyncDocumentJson> {
    if (!existsSync(this.filePath)) return emptyDocument(this.deviceId);
    const text = await readFile(this.filePath, 'utf8');
    let json: unknown;
    try { json = JSON.parse(text); } catch (error) {
      const quarantine = `${this.filePath}.broken-${Date.now()}`;
      await rename(this.filePath, quarantine);
      this.lastWarning = `data.json was corrupt (${String(error)}); moved to ${quarantine} (broken file kept) and started empty.`;
      return emptyDocument(this.deviceId);
    }
    const doc = json as Partial<SyncDocumentJson>;
    const version = typeof doc.version === 'number' ? doc.version : 1;
    if (version > SCHEMA_VERSION) throw new UnsupportedSchemaError(version);
    if (version < SCHEMA_VERSION) return upgradeV1(doc as Record<string, unknown>, this.deviceId);
    return doc as SyncDocumentJson;
  }

  private async writeLocked(doc: SyncDocumentJson): Promise<void> {
    const tmp = `${this.filePath}.tmp`;
    await writeFile(tmp, JSON.stringify(doc, null, 2), 'utf8');
    if (existsSync(this.filePath)) await copyFile(this.filePath, `${this.filePath}.bak`);
    await rename(tmp, this.filePath);
  }

  read(): Promise<SyncDocumentJson> { return this.withLock(() => this.readLocked()); }

  update(mutate: (doc: SyncDocumentJson) => SyncDocumentJson): Promise<SyncDocumentJson> {
    return this.withLock(async () => {
      const current = await this.readLocked();
      const next = mutate(structuredClone(current));
      next.version = SCHEMA_VERSION;
      next.exportedAt = new Date().toISOString();
      next.deviceId = this.deviceId;
      await this.writeLocked(next);
      return next;
    });
  }

  undoLastWrite(): Promise<boolean> {
    return this.withLock(async () => {
      const bak = `${this.filePath}.bak`;
      if (!existsSync(bak)) return false;
      await copyFile(bak, `${this.filePath}.tmp`);
      await rename(`${this.filePath}.tmp`, this.filePath);
      return true;
    });
  }

  async modifiedAt(): Promise<Date | null> {
    return existsSync(this.filePath) ? (await stat(this.filePath)).mtime : null;
  }
}

/** Minimal v1 → v2: rename envelope keys; entity meta defaults are filled lazily by merge/tools. */
function upgradeV1(doc: Record<string, unknown>, deviceId: string): SyncDocumentJson {
  const base = emptyDocument(deviceId);
  const tm = (doc.task_master ?? doc.taskMaster ?? {}) as Record<string, unknown>;
  const dp = (doc.daily_plan ?? doc.dailyPlan ?? {}) as Record<string, unknown>;
  const migrated = { clock: '0-0-migrated', updatedAt: '1970-01-01T00:00:00.000Z', deletedAt: null, migrated: true };
  const fill = (list: unknown) => (Array.isArray(list) ? list : []).map((e) => ({ ...migrated, ...(e as object) }));
  return {
    ...base,
    taskMaster: {
      tasks: fill(tm.tasks) as SyncDocumentJson['taskMaster']['tasks'],
      mustDoCategories: fill(tm.mustDoCategories) as SyncDocumentJson['taskMaster']['tasks'],
      wantToDoCategories: fill(tm.wantToDoCategories) as SyncDocumentJson['taskMaster']['tasks'],
      settings: { shareCategories: Boolean(tm.shareCategories), ...migrated },
    },
    dailyPlan: {
      plans: fill(dp.plans) as SyncDocumentJson['dailyPlan']['plans'],
      slots: fill(dp.slots) as SyncDocumentJson['dailyPlan']['plans'],
      assignments: fill(dp.assignments) as SyncDocumentJson['dailyPlan']['plans'],
    },
  };
}
```

`fill` は `{...migrated, ...e}` の順なので、v1 の `TaskMaster.updatedAt` は残り、`clock` は migrated になる（Dart と同じ規則）。

- [ ] **Step 4: テストを通す**

Run: `cd tools/hub && npm test`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add tools/hub/src/store.ts tools/hub/src/ids.ts tools/hub/test
git commit -m "feat(hub): locked atomic file store with bak/undo and id helpers / ロック付きファイルストアと id 採番"
```

---

### Task 13: MCP ツールと stdio サーバー

**Files:**
- Create: `tools/hub/src/tools.ts`、`tools/hub/src/index.ts`
- Create: `.mcp.json`（リポジトリ直下。Claude Code がプロジェクトを開いたときにハブを登録する）
- Test: `tools/hub/test/tools.test.ts`

- [ ] **Step 1: 失敗するテストを書く**

```ts
// tools/hub/test/tools.test.ts
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { HlcClock } from '../src/hlc.js';
import { FileStore } from '../src/store.js';
import { HubTools } from '../src/tools.js';

let dir: string; let tools: HubTools;
beforeEach(() => { dir = mkdtempSync(join(tmpdir(), 'hub-tools-')); tools = new HubTools(new FileStore(dir, 'hub-0000'), new HlcClock('hub-0000', () => 1000)); });
afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

describe('tasks', () => {
  it('add, list, update, delete round trip with tombstone', async () => {
    const added = await tools.addTask({ title: 'buy milk', kind: 'must_do', priority: 3 });
    expect(added.id).toMatch(/^task-\d+-0000-[0-9a-f]{6}$/);
    expect((await tools.listTasks({})).map((t) => t.title)).toEqual(['buy milk']);
    await tools.updateTask({ id: added.id, title: 'buy oat milk' });
    expect((await tools.listTasks({ query: 'oat' }))).toHaveLength(1);
    await tools.deleteTask({ id: added.id });
    expect(await tools.listTasks({})).toEqual([]);
    const raw = await tools.exportData();
    expect(raw.taskMaster.tasks[0].deletedAt).not.toBeNull();
  });
  it('rejects an empty title and an unknown category', async () => {
    await expect(tools.addTask({ title: '  ', kind: 'must_do' })).rejects.toThrow(/title/);
    await expect(tools.addTask({ title: 'x', kind: 'must_do', categoryId: 'nope' })).rejects.toThrow(/category/);
  });
});

describe('categories', () => {
  it('rejects duplicate names within a kind', async () => {
    await expect(tools.addCategory({ kind: 'must_do', name: '仕事' })).rejects.toThrow(/duplicate/);
    const c = await tools.addCategory({ kind: 'must_do', name: '運動' });
    expect((await tools.listCategories({ kind: 'must_do' })).some((x) => x.id === c.id)).toBe(true);
  });
});

describe('daily plan', () => {
  it('creates slots and assignments and enforces invariants', async () => {
    const slot = await tools.addFreeSlot({ date: '2026-09-09', startAt: '2026-09-09T10:00:00+09:00', endAt: '2026-09-09T12:00:00+09:00', label: 'morning' });
    const task = await tools.addTask({ title: 'read', kind: 'want_to_do' });
    const a = await tools.assignTask({ slotId: slot.id, taskId: task.id, startAt: '2026-09-09T10:00:00+09:00', endAt: '2026-09-09T11:00:00+09:00' });
    expect(a.sortOrder).toBe(0);
    await expect(tools.assignTask({ slotId: slot.id, taskId: task.id, startAt: '2026-09-09T11:30:00+09:00', endAt: '2026-09-09T13:00:00+09:00' })).rejects.toThrow(/assignment_outside_slot/);
    const plan = await tools.getDailyPlan({ date: '2026-09-09' });
    expect(plan.slots[0].assignments).toHaveLength(1);
  });
  it('copy_daily_plan uses deterministic ids', async () => {
    await tools.addFreeSlot({ date: '2026-09-09', startAt: '2026-09-09T10:00:00+09:00', endAt: '2026-09-09T12:00:00+09:00' });
    const first = await tools.copyDailyPlan({ fromDate: '2026-09-09', toDate: '2026-09-10' });
    expect(first.slots[0].id).toMatch(/^slot-[0-9a-f]{16}$/);
  });
});

describe('sync_status & undo', () => {
  it('reports file path and undoes the last write', async () => {
    await tools.addTask({ title: 'a', kind: 'must_do' });
    await tools.addTask({ title: 'b', kind: 'must_do' });
    expect(await tools.undoLastWrite()).toBe(true);
    expect(await tools.listTasks({})).toHaveLength(1);
    const status = await tools.syncStatus();
    expect(status.dataFile).toContain('data.json');
  });
});
```

- [ ] **Step 2: 失敗を確認する**

Run: `cd tools/hub && npm test`
Expected: FAIL

- [ ] **Step 3: 実装する**

`tools/hub/src/tools.ts` — 純粋なアプリ層。MCP から独立させてテストしやすくする。

```ts
import { z } from 'zod';
import { checkInvariants } from './invariants.js';
import { HlcClock } from './hlc.js';
import { copyId, generateId } from './ids.js';
import { isDeleted, TASK_KINDS, type Entity, type SyncDocumentJson } from './model.js';
import { FileStore } from './store.js';

export class ToolError extends Error {}

const kindSchema = z.enum(TASK_KINDS);
export const schemas = {
  listTasks: z.object({ kind: kindSchema.optional(), categoryId: z.string().optional(), query: z.string().optional() }),
  addTask: z.object({ title: z.string(), kind: kindSchema, priority: z.number().int().min(1).max(5).optional(), categoryId: z.string().optional(), estimatedMinutes: z.number().int().min(0).optional(), memo: z.string().optional() }),
  bulkAddTasks: z.object({ tasks: z.array(z.object({ title: z.string(), kind: kindSchema, priority: z.number().int().min(1).max(5).optional(), categoryId: z.string().optional(), estimatedMinutes: z.number().int().min(0).optional(), memo: z.string().optional() })).min(1).max(100) }),
  updateTask: z.object({ id: z.string(), title: z.string().optional(), kind: kindSchema.optional(), priority: z.number().int().min(1).max(5).optional(), categoryId: z.string().nullable().optional(), estimatedMinutes: z.number().int().min(0).optional(), memo: z.string().optional() }),
  deleteTask: z.object({ id: z.string() }),
  listCategories: z.object({ kind: kindSchema.optional() }),
  addCategory: z.object({ kind: kindSchema, name: z.string() }),
  updateCategory: z.object({ kind: kindSchema, id: z.string(), name: z.string() }),
  deleteCategory: z.object({ kind: kindSchema, id: z.string() }),
  listDailyPlans: z.object({ from: z.string(), to: z.string() }),
  getDailyPlan: z.object({ date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/) }),
  addFreeSlot: z.object({ date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/), startAt: z.string(), endAt: z.string(), label: z.string().optional() }),
  updateFreeSlot: z.object({ id: z.string(), startAt: z.string().optional(), endAt: z.string().optional(), label: z.string().optional() }),
  deleteFreeSlot: z.object({ id: z.string() }),
  assignTask: z.object({ slotId: z.string(), taskId: z.string(), startAt: z.string(), endAt: z.string(), memo: z.string().optional() }),
  updateAssignment: z.object({ id: z.string(), startAt: z.string().optional(), endAt: z.string().optional(), sortOrder: z.number().int().min(0).optional(), memo: z.string().optional() }),
  unassign: z.object({ id: z.string() }),
  copyDailyPlan: z.object({ fromDate: z.string(), toDate: z.string(), replaceExisting: z.boolean().optional() }),
  weeklyReport: z.object({ weekStart: z.string().regex(/^\d{4}-\d{2}-\d{2}$/) }),
  importFile: z.object({ path: z.string() }),
  purgeTombstones: z.object({}),
  forgetDevice: z.object({ deviceId: z.string() }),
  rotateToken: z.object({ deviceId: z.string() }),
};

const iso = (s: string) => { const d = new Date(s); if (Number.isNaN(d.getTime())) throw new ToolError(`invalid datetime: ${s}`); return d.toISOString(); };
const live = (list: Entity[]) => list.filter((e) => !isDeleted(e));

export class HubTools {
  constructor(private readonly store: FileStore, private readonly clock: HlcClock, private readonly now: () => Date = () => new Date()) {}

  private stamp(previous?: Entity): Pick<Entity, 'clock' | 'updatedAt' | 'deletedAt' | 'migrated'> {
    return { clock: this.clock.next().toString(), updatedAt: this.now().toISOString(), deletedAt: previous?.deletedAt ?? null, migrated: false };
  }
  private tomb(e: Entity): Entity {
    const t = this.now().toISOString();
    return { id: e.id, clock: this.clock.next().toString(), updatedAt: t, deletedAt: t, migrated: false };
  }
  private observeAll(doc: SyncDocumentJson) {
    for (const list of [doc.taskMaster.tasks, doc.taskMaster.mustDoCategories, doc.taskMaster.wantToDoCategories, doc.dailyPlan.plans, doc.dailyPlan.slots, doc.dailyPlan.assignments]) {
      for (const e of list) { const h = HlcParse(e.clock); if (h) this.clock.observe(h); }
    }
  }
  private async mutate(fn: (doc: SyncDocumentJson) => void): Promise<SyncDocumentJson> {
    const current = await this.store.read();
    this.observeAll(current);
    return this.store.update((doc) => {
      fn(doc);
      const violations = checkInvariants(doc);
      if (violations.length) throw new ToolError(`invariant violation: ${violations.map((v) => `${v.code} (${v.message})`).join('; ')}`);
      return doc;
    });
  }
  private cats(doc: SyncDocumentJson, kind: string) { return kind === 'must_do' ? doc.taskMaster.mustDoCategories : doc.taskMaster.wantToDoCategories; }

  // ---- tasks ----
  async listTasks(input: z.infer<typeof schemas.listTasks>) {
    const doc = await this.store.read();
    const q = input.query?.toLowerCase();
    return live(doc.taskMaster.tasks).filter((t) => (!input.kind || t.kind === input.kind) && (!input.categoryId || t.categoryId === input.categoryId) && (!q || String(t.title).toLowerCase().includes(q) || String(t.memo ?? '').toLowerCase().includes(q)));
  }
  async addTask(input: z.infer<typeof schemas.addTask>) {
    let created!: Entity;
    await this.mutate((doc) => { created = this.buildTask(doc, input); doc.taskMaster.tasks.push(created); });
    return created;
  }
  async bulkAddTasks(input: z.infer<typeof schemas.bulkAddTasks>) {
    const created: Entity[] = [];
    await this.mutate((doc) => { for (const t of input.tasks) { const e = this.buildTask(doc, t); created.push(e); doc.taskMaster.tasks.push(e); } });
    return created;
  }
  private buildTask(doc: SyncDocumentJson, input: z.infer<typeof schemas.addTask>): Entity {
    const title = input.title.trim();
    if (!title) throw new ToolError('title must not be empty');
    if (input.categoryId && !live(this.cats(doc, input.kind)).some((c) => c.id === input.categoryId)) throw new ToolError(`unknown category ${input.categoryId} for ${input.kind}`);
    const t = this.now().toISOString();
    return { id: generateId('task', this.store.deviceId), title, kind: input.kind, priority: input.priority ?? 3, createdAt: t, memo: input.memo ?? '', categoryId: input.categoryId ?? null, estimatedMinutes: input.estimatedMinutes ?? 0, ...this.stamp() };
  }
  async updateTask(input: z.infer<typeof schemas.updateTask>) {
    let updated!: Entity;
    await this.mutate((doc) => {
      const i = doc.taskMaster.tasks.findIndex((t) => t.id === input.id && !isDeleted(t));
      if (i < 0) throw new ToolError(`task ${input.id} not found`);
      const prev = doc.taskMaster.tasks[i];
      const kind = input.kind ?? String(prev.kind);
      if (input.title !== undefined && !input.title.trim()) throw new ToolError('title must not be empty');
      if (input.categoryId && !live(this.cats(doc, kind)).some((c) => c.id === input.categoryId)) throw new ToolError(`unknown category ${input.categoryId} for ${kind}`);
      updated = { ...prev, ...Object.fromEntries(Object.entries(input).filter(([k, v]) => k !== 'id' && v !== undefined)), title: input.title?.trim() ?? prev.title, ...this.stamp(prev) };
      doc.taskMaster.tasks[i] = updated;
    });
    return updated;
  }
  async deleteTask(input: z.infer<typeof schemas.deleteTask>) {
    await this.mutate((doc) => {
      const i = doc.taskMaster.tasks.findIndex((t) => t.id === input.id && !isDeleted(t));
      if (i < 0) throw new ToolError(`task ${input.id} not found`);
      doc.taskMaster.tasks[i] = this.tomb(doc.taskMaster.tasks[i]);
    });
    return { id: input.id, deleted: true };
  }

  // ---- categories ----
  async listCategories(input: z.infer<typeof schemas.listCategories>) {
    const doc = await this.store.read();
    const out = [] as Array<Entity & { kind: string }>;
    for (const kind of TASK_KINDS) if (!input.kind || input.kind === kind) out.push(...live(this.cats(doc, kind)).map((c) => ({ ...c, kind })));
    return out;
  }
  async addCategory(input: z.infer<typeof schemas.addCategory>) {
    let created!: Entity;
    await this.mutate((doc) => {
      const name = input.name.trim();
      if (!name) throw new ToolError('name must not be empty');
      const list = this.cats(doc, input.kind);
      if (live(list).some((c) => c.name === name)) throw new ToolError(`duplicate category name "${name}"`);
      created = { id: generateId(input.kind === 'must_do' ? 'must' : 'want', this.store.deviceId), name, ...this.stamp() };
      list.push(created);
      if (doc.taskMaster.settings.shareCategories) this.cats(doc, input.kind === 'must_do' ? 'want_to_do' : 'must_do').push({ ...created });
    });
    return created;
  }
  async updateCategory(input: z.infer<typeof schemas.updateCategory>) {
    let updated!: Entity;
    await this.mutate((doc) => {
      const list = this.cats(doc, input.kind);
      const i = list.findIndex((c) => c.id === input.id && !isDeleted(c));
      if (i < 0) throw new ToolError(`category ${input.id} not found`);
      const name = input.name.trim();
      if (live(list).some((c) => c.id !== input.id && c.name === name)) throw new ToolError(`duplicate category name "${name}"`);
      updated = { ...list[i], name, ...this.stamp(list[i]) };
      list[i] = updated;
    });
    return updated;
  }
  async deleteCategory(input: z.infer<typeof schemas.deleteCategory>) {
    await this.mutate((doc) => {
      const list = this.cats(doc, input.kind);
      const i = list.findIndex((c) => c.id === input.id && !isDeleted(c));
      if (i < 0) throw new ToolError(`category ${input.id} not found`);
      list[i] = this.tomb(list[i]);
      doc.taskMaster.tasks = doc.taskMaster.tasks.map((t) => (!isDeleted(t) && t.categoryId === input.id ? { ...t, categoryId: null, ...this.stamp(t) } : t));
    });
    return { id: input.id, deleted: true };
  }

  // ---- daily plan ----
  private planFor(doc: SyncDocumentJson, date: string): Entity | undefined { return live(doc.dailyPlan.plans).find((p) => p.date === date); }
  private ensurePlan(doc: SyncDocumentJson, date: string): Entity {
    const existing = this.planFor(doc, date);
    if (existing) return existing;
    const t = this.now().toISOString();
    const plan: Entity = { id: generateId('plan', this.store.deviceId), date, createdAt: t, ...this.stamp() };
    doc.dailyPlan.plans.push(plan);
    return plan;
  }
  private touchPlan(doc: SyncDocumentJson, planId: string) {
    doc.dailyPlan.plans = doc.dailyPlan.plans.map((p) => (p.id === planId ? { ...p, ...this.stamp(p) } : p));
  }
  private normalizeSlot(doc: SyncDocumentJson, slotId: string) {
    const items = live(doc.dailyPlan.assignments).filter((a) => a.slotId === slotId).sort((x, y) => String(x.startAt).localeCompare(String(y.startAt)) || String(x.endAt).localeCompare(String(y.endAt)) || Number(x.sortOrder) - Number(y.sortOrder));
    items.forEach((a, i) => { if (a.sortOrder !== i) { const j = doc.dailyPlan.assignments.findIndex((x) => x.id === a.id); doc.dailyPlan.assignments[j] = { ...a, sortOrder: i, ...this.stamp(a) }; } });
  }
  async listDailyPlans(input: z.infer<typeof schemas.listDailyPlans>) {
    const doc = await this.store.read();
    return live(doc.dailyPlan.plans).filter((p) => String(p.date) >= input.from && String(p.date) <= input.to).sort((a, b) => String(a.date).localeCompare(String(b.date)));
  }
  async getDailyPlan(input: z.infer<typeof schemas.getDailyPlan>) {
    const doc = await this.store.read();
    const plan = this.planFor(doc, input.date);
    if (!plan) return { date: input.date, plan: null, slots: [] };
    const slots = live(doc.dailyPlan.slots).filter((s) => s.dailyPlanId === plan.id).sort((a, b) => String(a.startAt).localeCompare(String(b.startAt)));
    return { date: input.date, plan, slots: slots.map((s) => ({ ...s, assignments: live(doc.dailyPlan.assignments).filter((a) => a.slotId === s.id).sort((x, y) => Number(x.sortOrder) - Number(y.sortOrder)) })) };
  }
  async addFreeSlot(input: z.infer<typeof schemas.addFreeSlot>) {
    let created!: Entity;
    await this.mutate((doc) => {
      const plan = this.ensurePlan(doc, input.date);
      created = { id: generateId('slot', this.store.deviceId), dailyPlanId: plan.id, startAt: iso(input.startAt), endAt: iso(input.endAt), label: input.label ?? '', ...this.stamp() };
      doc.dailyPlan.slots.push(created);
      this.touchPlan(doc, plan.id);
    });
    return created;
  }
  async updateFreeSlot(input: z.infer<typeof schemas.updateFreeSlot>) {
    let updated!: Entity;
    await this.mutate((doc) => {
      const i = doc.dailyPlan.slots.findIndex((s) => s.id === input.id && !isDeleted(s));
      if (i < 0) throw new ToolError(`slot ${input.id} not found`);
      const prev = doc.dailyPlan.slots[i];
      updated = { ...prev, startAt: input.startAt ? iso(input.startAt) : prev.startAt, endAt: input.endAt ? iso(input.endAt) : prev.endAt, label: input.label ?? prev.label, ...this.stamp(prev) };
      doc.dailyPlan.slots[i] = updated;
      this.touchPlan(doc, String(prev.dailyPlanId));
    });
    return updated;
  }
  async deleteFreeSlot(input: z.infer<typeof schemas.deleteFreeSlot>) {
    await this.mutate((doc) => {
      const i = doc.dailyPlan.slots.findIndex((s) => s.id === input.id && !isDeleted(s));
      if (i < 0) throw new ToolError(`slot ${input.id} not found`);
      const planId = String(doc.dailyPlan.slots[i].dailyPlanId);
      doc.dailyPlan.slots[i] = this.tomb(doc.dailyPlan.slots[i]);
      doc.dailyPlan.assignments = doc.dailyPlan.assignments.map((a) => (!isDeleted(a) && a.slotId === input.id ? this.tomb(a) : a));
      this.touchPlan(doc, planId);
    });
    return { id: input.id, deleted: true };
  }
  async assignTask(input: z.infer<typeof schemas.assignTask>) {
    let created!: Entity;
    await this.mutate((doc) => {
      const slot = live(doc.dailyPlan.slots).find((s) => s.id === input.slotId);
      if (!slot) throw new ToolError(`slot ${input.slotId} not found`);
      const task = live(doc.taskMaster.tasks).find((t) => t.id === input.taskId);
      if (!task) throw new ToolError(`task ${input.taskId} not found`);
      const cat = task.categoryId ? live(this.cats(doc, String(task.kind))).find((c) => c.id === task.categoryId) : undefined;
      const count = live(doc.dailyPlan.assignments).filter((a) => a.slotId === slot.id).length;
      created = { id: generateId('assignment', this.store.deviceId), dailyPlanId: slot.dailyPlanId, slotId: slot.id, taskId: task.id, taskTitle: task.title, taskKind: task.kind, startAt: iso(input.startAt), endAt: iso(input.endAt), sortOrder: count, categoryId: task.categoryId ?? null, categoryName: cat?.name ?? null, memo: input.memo ?? '', ...this.stamp() };
      doc.dailyPlan.assignments.push(created);
      this.normalizeSlot(doc, slot.id);
      this.touchPlan(doc, String(slot.dailyPlanId));
      created = doc.dailyPlan.assignments.find((a) => a.id === created.id)!;
    });
    return created;
  }
  async updateAssignment(input: z.infer<typeof schemas.updateAssignment>) {
    let updated!: Entity;
    await this.mutate((doc) => {
      const i = doc.dailyPlan.assignments.findIndex((a) => a.id === input.id && !isDeleted(a));
      if (i < 0) throw new ToolError(`assignment ${input.id} not found`);
      const prev = doc.dailyPlan.assignments[i];
      updated = { ...prev, startAt: input.startAt ? iso(input.startAt) : prev.startAt, endAt: input.endAt ? iso(input.endAt) : prev.endAt, sortOrder: input.sortOrder ?? prev.sortOrder, memo: input.memo ?? prev.memo, ...this.stamp(prev) };
      doc.dailyPlan.assignments[i] = updated;
      this.normalizeSlot(doc, String(prev.slotId));
      this.touchPlan(doc, String(prev.dailyPlanId));
      updated = doc.dailyPlan.assignments.find((a) => a.id === input.id)!;
    });
    return updated;
  }
  async unassign(input: z.infer<typeof schemas.unassign>) {
    await this.mutate((doc) => {
      const i = doc.dailyPlan.assignments.findIndex((a) => a.id === input.id && !isDeleted(a));
      if (i < 0) throw new ToolError(`assignment ${input.id} not found`);
      const prev = doc.dailyPlan.assignments[i];
      doc.dailyPlan.assignments[i] = this.tomb(prev);
      this.normalizeSlot(doc, String(prev.slotId));
      this.touchPlan(doc, String(prev.dailyPlanId));
    });
    return { id: input.id, deleted: true };
  }
  async copyDailyPlan(input: z.infer<typeof schemas.copyDailyPlan>) {
    let result!: { plan: Entity; slots: Entity[]; assignments: Entity[] };
    await this.mutate((doc) => {
      if (input.fromDate === input.toDate) throw new ToolError('fromDate and toDate must differ');
      const source = this.planFor(doc, input.fromDate);
      if (!source) throw new ToolError(`no plan on ${input.fromDate}`);
      const target = this.ensurePlan(doc, input.toDate);
      if (input.replaceExisting) {
        doc.dailyPlan.slots = doc.dailyPlan.slots.map((s) => (!isDeleted(s) && s.dailyPlanId === target.id ? this.tomb(s) : s));
        doc.dailyPlan.assignments = doc.dailyPlan.assignments.map((a) => (!isDeleted(a) && a.dailyPlanId === target.id ? this.tomb(a) : a));
      }
      const taken = new Set([...doc.dailyPlan.slots.map((s) => s.id), ...doc.dailyPlan.assignments.map((a) => a.id)]);
      const nextId = (prefix: string, sourceId: string) => { let g = 0; while (taken.has(copyId(prefix, source.id, input.toDate, sourceId, g))) g += 1; const id = copyId(prefix, source.id, input.toDate, sourceId, g); taken.add(id); return id; };
      const dayMs = (new Date(input.toDate).getTime() - new Date(input.fromDate).getTime());
      const shift = (s: unknown) => new Date(new Date(String(s)).getTime() + dayMs).toISOString();
      const slotMap = new Map<string, string>();
      const slots: Entity[] = []; const assignments: Entity[] = [];
      for (const s of live(doc.dailyPlan.slots).filter((s) => s.dailyPlanId === source.id)) {
        const id = nextId('slot', s.id); slotMap.set(s.id, id);
        const copy: Entity = { ...s, id, dailyPlanId: target.id, startAt: shift(s.startAt), endAt: shift(s.endAt), ...this.stamp() };
        doc.dailyPlan.slots.push(copy); slots.push(copy);
      }
      for (const a of live(doc.dailyPlan.assignments).filter((a) => a.dailyPlanId === source.id && slotMap.has(String(a.slotId)))) {
        const copy: Entity = { ...a, id: nextId('assignment', a.id), dailyPlanId: target.id, slotId: slotMap.get(String(a.slotId))!, startAt: shift(a.startAt), endAt: shift(a.endAt), ...this.stamp() };
        doc.dailyPlan.assignments.push(copy); assignments.push(copy);
      }
      this.touchPlan(doc, target.id);
      result = { plan: target, slots, assignments };
    });
    return result;
  }
  async weeklyReport(input: z.infer<typeof schemas.weeklyReport>) {
    const doc = await this.store.read();
    const start = new Date(`${input.weekStart}T00:00:00Z`);
    const end = new Date(start.getTime() + 7 * 86400000);
    const plans = live(doc.dailyPlan.plans).filter((p) => new Date(`${p.date}T00:00:00Z`) >= start && new Date(`${p.date}T00:00:00Z`) < end);
    const planIds = new Set(plans.map((p) => p.id));
    const minutes = (a: Entity) => Math.max(0, (new Date(String(a.endAt)).getTime() - new Date(String(a.startAt)).getTime()) / 60000);
    const byKind: Record<string, number> = { must_do: 0, want_to_do: 0 };
    const byCategory: Record<string, number> = {};
    let freeMinutes = 0;
    for (const s of live(doc.dailyPlan.slots).filter((s) => planIds.has(String(s.dailyPlanId)))) freeMinutes += minutes(s);
    for (const a of live(doc.dailyPlan.assignments).filter((a) => planIds.has(String(a.dailyPlanId)))) { byKind[String(a.taskKind)] += minutes(a); const c = String(a.categoryName ?? '未分類'); byCategory[c] = (byCategory[c] ?? 0) + minutes(a); }
    return { weekStart: input.weekStart, days: plans.length, freeMinutes, assignedMinutes: byKind.must_do + byKind.want_to_do, byKind, byCategory };
  }

  // ---- data ----
  async exportData() { return this.store.read(); }
  async undoLastWrite() { return this.store.undoLastWrite(); }
  async syncStatus() {
    return { dataFile: this.store.filePath, modifiedAt: (await this.store.modifiedAt())?.toISOString() ?? null, warning: this.store.lastWarning, lan: 'not started (Plan 2)' };
  }
}

function HlcParse(v: unknown) { return typeof v === 'string' ? (Hlc.tryParse(v)) : null; }
import { Hlc } from './hlc.js';
```

`import_file` / `purge_tombstones` / `forget_device` / `rotate_token` は Plan 2（同期と端末管理）で実装する。スキーマは定義済みなので、Plan 1 では MCP サーバー側で「Plan 2 で提供」とエラーを返す。

`tools/hub/src/index.ts`:

```ts
#!/usr/bin/env node
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { HlcClock } from './hlc.js';
import { FileStore } from './store.js';
import { HubTools, ToolError, schemas } from './tools.js';

const dir = process.env.FRELOCATOR_DATA_DIR ?? FileStore.defaultDirectory();
const store = new FileStore(dir, 'hub-' + (process.env.FRELOCATOR_HUB_ID ?? 'macos'));
const tools = new HubTools(store, new HlcClock(store.deviceId));
const server = new McpServer({ name: 'frelocator-hub', version: '0.1.0' });

const text = (v: unknown) => ({ content: [{ type: 'text' as const, text: JSON.stringify(v, null, 2) }] });
const wrap = <T>(fn: () => Promise<T>) => fn().then(text).catch((e) => ({ isError: true, content: [{ type: 'text' as const, text: e instanceof ToolError ? e.message : String(e) }] }));
const notYet = () => wrap(async () => { throw new ToolError('available in Plan 2 (LAN sync)'); });

server.tool('list_tasks', 'List live tasks, optionally filtered by kind/category/query', schemas.listTasks.shape, (i) => wrap(() => tools.listTasks(i)));
server.tool('add_task', 'Add a task', schemas.addTask.shape, (i) => wrap(() => tools.addTask(i)));
server.tool('bulk_add_tasks', 'Add many tasks at once', schemas.bulkAddTasks.shape, (i) => wrap(() => tools.bulkAddTasks(i)));
server.tool('update_task', 'Update fields of a task', schemas.updateTask.shape, (i) => wrap(() => tools.updateTask(i)));
server.tool('delete_task', 'Delete (tombstone) a task', schemas.deleteTask.shape, (i) => wrap(() => tools.deleteTask(i)));
server.tool('list_categories', 'List categories', schemas.listCategories.shape, (i) => wrap(() => tools.listCategories(i)));
server.tool('add_category', 'Add a category', schemas.addCategory.shape, (i) => wrap(() => tools.addCategory(i)));
server.tool('update_category', 'Rename a category', schemas.updateCategory.shape, (i) => wrap(() => tools.updateCategory(i)));
server.tool('delete_category', 'Delete a category and detach its tasks', schemas.deleteCategory.shape, (i) => wrap(() => tools.deleteCategory(i)));
server.tool('list_daily_plans', 'List plans in a date range', schemas.listDailyPlans.shape, (i) => wrap(() => tools.listDailyPlans(i)));
server.tool('get_daily_plan', 'Get plan, slots and assignments for a date (YYYY-MM-DD, hub local day)', schemas.getDailyPlan.shape, (i) => wrap(() => tools.getDailyPlan(i)));
server.tool('add_free_slot', 'Add a free time slot (creates the plan if needed)', schemas.addFreeSlot.shape, (i) => wrap(() => tools.addFreeSlot(i)));
server.tool('update_free_slot', 'Update a slot', schemas.updateFreeSlot.shape, (i) => wrap(() => tools.updateFreeSlot(i)));
server.tool('delete_free_slot', 'Delete a slot and its assignments', schemas.deleteFreeSlot.shape, (i) => wrap(() => tools.deleteFreeSlot(i)));
server.tool('assign_task', 'Assign a task into a slot', schemas.assignTask.shape, (i) => wrap(() => tools.assignTask(i)));
server.tool('update_assignment', 'Update an assignment', schemas.updateAssignment.shape, (i) => wrap(() => tools.updateAssignment(i)));
server.tool('unassign', 'Remove an assignment', schemas.unassign.shape, (i) => wrap(() => tools.unassign(i)));
server.tool('copy_daily_plan', 'Copy slots and assignments from one date to another', schemas.copyDailyPlan.shape, (i) => wrap(() => tools.copyDailyPlan(i)));
server.tool('weekly_report', 'Aggregate time by kind/category for a week', schemas.weeklyReport.shape, (i) => wrap(() => tools.weeklyReport(i)));
server.tool('export_data', 'Return the full v2 document', {}, () => wrap(() => tools.exportData()));
server.tool('undo_last_write', 'Restore data.json.bak (one generation)', {}, () => wrap(() => tools.undoLastWrite()));
server.tool('sync_status', 'Data file path, last modification, warnings, LAN status', {}, () => wrap(() => tools.syncStatus()));
server.tool('import_file', 'Merge a v2 JSON file into the store (Plan 2)', schemas.importFile.shape, notYet);
server.tool('purge_tombstones', 'Purge old tombstones (Plan 2)', {}, notYet);
server.tool('forget_device', 'Forget a paired device (Plan 2)', schemas.forgetDevice.shape, notYet);
server.tool('rotate_token', 'Rotate a device token (Plan 2)', schemas.rotateToken.shape, notYet);

await server.connect(new StdioServerTransport());
```

`.mcp.json`（リポジトリ直下）:

```json
{
  "mcpServers": {
    "frelocator-hub": {
      "command": "node",
      "args": ["tools/hub/dist/index.js"]
    }
  }
}
```

- [ ] **Step 4: テストとビルド**

Run: `cd tools/hub && npm test && npm run build`
Expected: 全 PASS、`dist/index.js` 生成。

手動確認: リポジトリを Claude Code で開き直し、MCP に `frelocator-hub` が現れること。`sync_status` → `add_task` → macOS 版 FRELOCATOR.app を前面に戻すとタスクが表示されること。逆に macOS 版で追加したタスクが `list_tasks` に出ること。

- [ ] **Step 5: コミット**

```bash
git add tools/hub .mcp.json
git commit -m "feat(hub): MCP tools and stdio server / MCP ツールと stdio サーバー"
```

---

### Task 14: ドキュメントと仕上げ

**Files:**
- Modify: `README.md`（「現在のデータ保存」の段落を更新）
- Modify: `docs/sync_extension_plan.md`（冒頭に「この計画は 2026-09-08 の設計書に置き換えられた」と追記し、設計書へのリンク）
- Create: `tools/hub/README.md`（起動方法、データファイルの場所、`FRELOCATOR_DATA_DIR`、undo の説明）

- [ ] **Step 1: README を更新する**

`README.md` の「現在のデータ保存は `shared_preferences` による端末内保存です。…」を次に置き換える。

```markdown
データ保存は端末内のみです（Android / Web は `shared_preferences`、macOS は `~/Library/Application Support/FRELOCATOR/data.json`）。macOS の JSON は `tools/hub`（Claude Code 向け MCP サーバー）と共有され、PC 上では Claude からタスクや計画を編集できます。端末間の同期（LAN / QR）は `docs/superpowers/specs/2026-09-08-frelocator-hub-sync-design.md` に沿って実装中です。
```

- [ ] **Step 2: `tools/hub/README.md` を書く**

```markdown
# frelocator-hub

FRELOCATOR の macOS 版と同じ `data.json` を編集する MCP サーバー。

- ビルド: `npm install && npm run build`
- Claude Code: リポジトリ直下の `.mcp.json` が `node tools/hub/dist/index.js` を登録する。
- データ: `~/Library/Application Support/FRELOCATOR/data.json`（`FRELOCATOR_DATA_DIR` で変更可）。書き込みごとに `data.json.bak` を 1 世代残し、`undo_last_write` で戻せる。
- 壊れたファイルは `data.json.broken-<timestamp>` に退避して空データで起動する（`sync_status` の `warning` に出る）。
- テスト: `npm test`（マージ規則は `test/fixtures/sync_merge` を Flutter 側と共有）。
```

- [ ] **Step 3: 全体を検証してコミット**

Run: `flutter analyze && flutter test && (cd tools/hub && npm test && npm run build)`
Expected: 全 PASS

```bash
git add README.md docs/sync_extension_plan.md tools/hub/README.md
git commit -m "docs: describe hub and file-backed storage / ハブとファイル保存の説明を追加"
```

---

## 自己レビュー（計画作成時に実施）

- 設計書のカバレッジ: スキーマ v2（Task 2, 4）、HLC（Task 1, 3）、墓標化（Task 4, 5）、マージ規則と共有フィクスチャ（Task 7, 11）、不変条件（Task 8, 11）、決定的な複製 id（Task 5, 12, 13）、ファイル所有と並行制御（Task 9, 12）、MCP ツール（Task 13）、macOS サンドボックス無効化（Task 9）、id の device 成分（Task 3, 12）、未知キー保持と厳格パース（Task 2, 4）。LAN / ペアリング / QR / ファイル持ち込み / purge / forget_device / rotate_token / 進捗 UI / プライバシーポリシー / 権限は Plan 2。
- 型の整合: `SyncMeta.stamp/touch/tombstone`、`Tombstone(id, meta)`、`splitDeleted/parseLive`、`SyncDocument(exportedAt, deviceId, lastSyncAt, purgedBefore, taskMaster, dailyPlan)`、`SyncMerger.merge → MergeResult(document, warnings)`、`InvariantChecker.check → List<InvariantViolation(code, message)>`、`StateStore` の 4 メソッド、`FileStore.read/update/undoLastWrite`、`HubTools` のメソッド名は Task 13 のテストと一致。
- 既知の注意点: Task 4 でモデルの `const` コンストラクタを外すため、画面側の `const` 呼び出しを analyze で洗い出す。Task 10 の hash 既知値と Task 7 の `06` 期待値は Dart の `tool/print_hash.dart` で生成してから貼る。
