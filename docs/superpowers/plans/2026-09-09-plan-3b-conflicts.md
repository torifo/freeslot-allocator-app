# FRELOCATOR Plan 3b: 競合の記録と解決

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 同じエンティティを PC（MCP）とスマホ／ブラウザの両方で編集していた場合に、HLC の勝者を暫定採用して **同期は必ず完了させたうえで**、敗者のスナップショットを競合レコードとして残し、あとからどちらを採用するか選べるようにする。検出は Dart / TS 共有のマージャで行い、競合 id は決定的なので両言語が同じ id を出す。

**Architecture:** ドキュメント直下に任意フィールド `conflicts[]` を足す（スキーマ版は **2 のまま**）。検出は `merge()` / `SyncMerger.merge()` の中で、引数に渡された `lastAgreedAt`（= 受信文書の `lastSyncAt`）を合意点として行う。競合レコードは `clock` / `updatedAt` / `deletedAt` / `migrated` を持つ普通のエンティティなので、既存のマージ規則にそのまま乗る。`SyncEngine` は `summary.conflicts` を出し、置き換えモードでも `conflicts` だけは常に和集合にする。MCP に 4 ツール（39 → 43）、アプリに一覧・詳細画面を足す。解決は「新しい HLC の編集として書き戻す」ので、通常のマージで全端末に伝播する。

**Tech Stack:** Node 22 / TypeScript 5、`zod`、`vitest`。Flutter 3.47 / Dart 3.11、`crypto`（既存依存、SHA-256）、`flutter_test`。

**設計書:** `docs/superpowers/specs/2026-09-09-frelocator-plan3-web-on-hub-and-conflicts.md` の B / C / D / E 節と F 節「Plan 3b」。未決事項は 5 件すべて推奨案で承認済み。3b に効くのは **過検出寄りの検出（`changedAt = max(updatedAt, clock.physical)`、比較は `>=`）**、**未解決 1000 件 / 解決済み 200 件 ＋ 解決済み 30 日 TTL**、**ハブのローカルページに競合一覧を作らない**。

**前提:** Plan 3a（ハブ上の Web 版）が入っていること。`POST /api/sync` は `SyncEngine.sync` をそのまま通すので、`SyncResult` に `conflicts` が乗れば Web 側の応答にも自動で乗る。

**Plan 3a からの申し送り:**
- Web の端末 id は `web-<16 hex>`。UI のラベル出し分けは `deviceId.startsWith('web-')` で判定する。
- Web 擬似端末は `hub.json` の `devices` に入っていない。`purge_tombstones` のカットオフ計算はこれまでどおり実端末だけを見る（競合の TTL 掃除もこのカットオフに乗せる）。

---

## ファイル構成

- Modify: `tools/hub/src/model.ts` — `ConflictJson` / `ConflictSideJson`、`SyncDocumentJson.conflicts?`、`emptyDocument` は `conflicts` を出さない。
- Modify: `tools/hub/src/merge.ts` — `merge(a, b, options?)`、検出規則、決定的 id、`conflicts` の和集合、`superseded` 判定。
- Modify: `tools/hub/src/sync-engine.ts` — `documentSchema` に `conflicts`、`SyncSummary.conflicts`、`SyncResult.conflicts`、置き換えモードでの和集合、`purge()` に上限・TTL。
- Modify: `tools/hub/src/tools.ts` — `list_conflicts` / `get_conflict` / `resolve_conflict` / `resolve_all_conflicts`、schemas。
- Modify: `tools/hub/src/index.ts` — 4 ツールの登録。
- Modify: `tools/hub/scripts/smoke.mjs` — 競合を作って解決するまでの往復、ツール数 43。
- Modify: `tools/hub/README.md`、`tools/hub/docs/tool-coverage.md`。
- Tests: `tools/hub/test/merge.conflicts.test.ts`、`tools/hub/test/sync-engine.conflicts.test.ts`、`tools/hub/test/tools.conflicts.test.ts`。
- Create: `lib/services/sync/conflict_record.dart`。
- Modify: `lib/services/sync/sync_document.dart`、`sync_merger.dart`、`sync_progress.dart`（`SyncSummary.conflicts`）、`sync_service.dart`（解決の書き込み）。
- Create: `lib/features/sync/presentation/conflict_list_screen.dart`、`conflict_detail_screen.dart`、`lib/features/sync/application/conflict_controller.dart`。
- Modify: `lib/features/sync/presentation/sync_progress_panel.dart`、`sync_settings_screen.dart`、`lib/app/router.dart`。
- Create/Modify: `test/fixtures/sync_merge/09..16_*.json` と `manifest.json`（**追加のみ**）、`test/services/sync/sync_merger_fixture_test.dart`（`options` 対応）、`tools/hub/test/merge.fixtures.test.ts`（同）。
- Tests: `test/services/sync/conflict_record_test.dart`、`test/services/sync/sync_merger_conflicts_test.dart`、`test/features/sync/conflict_screens_test.dart`。
- Modify: `pubspec.yaml`（1.0.0+6）、`docs/distribution_release_prep.md`。

---

### Task 1: モデル（`conflicts[]` と決定的 id）

**Files:**
- Modify: `tools/hub/src/model.ts`
- Create: `lib/services/sync/conflict_record.dart`
- Modify: `lib/services/sync/sync_document.dart`
- Test: `tools/hub/test/model.conflicts.test.ts`、`test/services/sync/conflict_record_test.dart`

- [ ] **Step 1: 失敗するテストを書く**

```ts
// tools/hub/test/model.conflicts.test.ts
import { describe, expect, it } from 'vitest';
import { conflictId, conflictSchema, documentSchema } from '../src/model.js';
import { emptyDocument } from '../src/model.js';

const side = (deviceId: string, clock: string) => ({
  side: deviceId.startsWith('hub-') ? 'hub' : 'device',
  deviceId, clock, updatedAt: '2026-09-09T01:00:00.000Z',
  snapshot: { id: 'tsk-1', title: 'x' },
});

describe('conflict model', () => {
  it('derives the id from entityId and both clocks, and nothing else', () => {
    const id = conflictId('tsk-1', '10-0-hub-macos', '9-2-android-3f2a');
    expect(id).toMatch(/^cf-[0-9a-f]{16}$/);
    expect(conflictId('tsk-1', '10-0-hub-macos', '9-2-android-3f2a')).toBe(id);
    expect(conflictId('tsk-2', '10-0-hub-macos', '9-2-android-3f2a')).not.toBe(id);
    // 勝敗が入れ替われば別の競合（同じ 2 版の再検出ではない）。
    expect(conflictId('tsk-1', '9-2-android-3f2a', '10-0-hub-macos')).not.toBe(id);
  });

  it('accepts unknown entityType and unknown resolution values (forward compatible)', () => {
    const record = {
      id: 'cf-0000000000000000', entityType: 'quantum-thing', entityId: 'q-1',
      detectedAt: '2026-09-09T02:00:00.000Z', detectedBy: 'hub-macos',
      winner: side('hub-macos', '10-0-hub-macos'), loser: side('android-1', '9-0-android-1'),
      resolution: null, resolvedAt: null, resolvedBy: null,
      clock: '11-0-hub-macos', updatedAt: '2026-09-09T02:00:00.000Z', deletedAt: null, migrated: false,
    };
    expect(conflictSchema.safeParse(record).success).toBe(true);
    expect(conflictSchema.safeParse({ ...record, id: 42 }).success).toBe(false);
    expect(conflictSchema.safeParse({ ...record, winner: { side: 'hub' } }).success).toBe(false);
  });

  it('documentSchema keeps conflicts optional so a Plan 2b client still validates', () => {
    const doc = emptyDocument('a');
    expect('conflicts' in doc).toBe(false);
    expect(documentSchema.safeParse(doc).success).toBe(true);
    expect(documentSchema.safeParse({ ...doc, conflicts: [] }).success).toBe(true);
  });
});
```

```dart
// test/services/sync/conflict_record_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/services/sync/conflict_record.dart';

void main() {
  test('conflictId matches the TypeScript rule byte for byte', () {
    // tools/hub/test/model.conflicts.test.ts と同じ入力・同じ期待値。
    expect(conflictId('tsk-1', '10-0-hub-macos', '9-2-android-3f2a'),
        matches(RegExp(r'^cf-[0-9a-f]{16}$')));
  });

  test('fromJson is strict about the load-bearing fields and lenient elsewhere', () {
    final json = <String, dynamic>{
      'id': 'cf-0000000000000000', 'entityType': 'task', 'entityId': 'tsk-1',
      'detectedAt': '2026-09-09T02:00:00.000Z', 'detectedBy': 'hub-macos',
      'winner': {'side': 'hub', 'deviceId': 'hub-macos', 'clock': '10-0-hub-macos', 'updatedAt': '2026-09-09T01:00:00.000Z', 'snapshot': {'id': 'tsk-1', 'title': 'x'}},
      'loser': {'side': 'device', 'deviceId': 'android-1', 'clock': '9-0-android-1', 'updatedAt': '2026-09-09T00:00:00.000Z', 'snapshot': {'id': 'tsk-1', 'title': 'y'}},
      'resolution': null, 'resolvedAt': null, 'resolvedBy': null,
      'clock': '11-0-hub-macos', 'updatedAt': '2026-09-09T02:00:00.000Z', 'deletedAt': null, 'migrated': false,
      'futureField': {'kept': true},
    };
    final record = ConflictRecord.fromJson(json, strict: true);
    expect(record.entityId, 'tsk-1');
    expect(record.winner.deviceId, 'hub-macos');
    // 未知キーは extra として往復する（既存の SyncMeta.extra と同じ方式）。
    expect(record.toJson()['futureField'], {'kept': true});
    expect(() => ConflictRecord.fromJson({...json, 'id': 42}, strict: true), throwsFormatException);
    expect(() => ConflictRecord.fromJson({...json, 'winner': 'x'}, strict: true), throwsFormatException);
    // 未知の entityType / resolution は受けてそのまま保持する。
    expect(ConflictRecord.fromJson({...json, 'entityType': 'zzz', 'resolution': 'zzz'}, strict: true).entityType, 'zzz');
  });

  test('an empty conflicts list is omitted from toJson entirely', () {
    final doc = SyncDocument(/* … conflicts: const [] … */);
    expect(doc.toJson().containsKey('conflicts'), isFalse);
  });

  test('a v2 document without conflicts round-trips unchanged', () {
    // 古いハブ・古いアプリとの差分を無用に増やさない。
  });
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `cd tools/hub && npm test -- model.conflicts` / `flutter test test/services/sync/conflict_record_test.dart`
Expected: FAIL

- [ ] **Step 3: 実装する**

```ts
// src/model.ts（追記）
import { createHash } from 'node:crypto';
import { z } from 'zod';

export interface ConflictSideJson {
  side: 'hub' | 'device';
  deviceId: string;
  clock: string;
  updatedAt: string;
  /** The whole record as it stood on that side; a tombstone is `{id, clock, updatedAt, deletedAt}`. */
  snapshot: { id: string } & Record<string, unknown>;
}

export type ConflictResolution = 'hub' | 'device' | 'current' | 'superseded';

export interface ConflictJson extends SyncMetaJson {
  id: string;
  entityType: string;
  entityId: string;
  detectedAt: string;
  detectedBy?: string;
  winner: ConflictSideJson;
  loser: ConflictSideJson;
  resolution?: ConflictResolution | string | null;
  resolvedAt?: string | null;
  resolvedBy?: string | null;
}

/**
 * `cf-<sha256(entityId \n winnerClock \n loserClock)[0..16]>`.
 *
 * Derived from content and never from time, so Dart and TypeScript detecting
 * the same conflict independently produce the same id, re-detection is
 * idempotent, and the shared fixtures can pin an exact expected id.
 */
export function conflictId(entityId: string, winnerClock: string, loserClock: string): string {
  return `cf-${createHash('sha256').update(`${entityId}\n${winnerClock}\n${loserClock}`, 'utf8').digest('hex').slice(0, 16)}`;
}

const conflictSideSchema = z.object({
  side: z.enum(['hub', 'device']),
  deviceId: z.string(),
  clock: z.string(),
  updatedAt: z.string(),
  snapshot: z.object({ id: z.string() }).passthrough(),
}).passthrough();

export const conflictSchema = z.object({
  id: z.string(),
  // A string, not an enum: a newer app may record a type this build cannot draw,
  // and dropping it would delete the other side's record on the round trip.
  entityType: z.string(),
  entityId: z.string(),
  detectedAt: z.string(),
  detectedBy: z.string().optional(),
  winner: conflictSideSchema,
  loser: conflictSideSchema,
  resolution: z.string().nullish(),
  resolvedAt: z.string().nullish(),
  resolvedBy: z.string().nullish(),
  clock: z.string(),
  updatedAt: z.string(),
  deletedAt: z.string().nullish(),
  migrated: z.boolean().optional(),
}).passthrough();

// SyncDocumentJson に:  conflicts?: ConflictJson[];
```

`sync-engine.ts` の `documentSchema` に `conflicts: z.array(conflictSchema).optional(),` を足す（`documentSchema` は `model.ts` へ移して両方から使ってもよいが、移すなら既存テストの import を全部直すこと。移さずに `conflictSchema` だけ import するのが差分は小さい）。

```dart
// lib/services/sync/conflict_record.dart（骨子）
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../core/sync_meta.dart';

/// `cf-<sha256(entityId \n winnerClock \n loserClock)[0..16]>` — byte for byte
/// the same rule as `conflictId` in tools/hub/src/model.ts.
String conflictId(String entityId, String winnerClock, String loserClock) =>
    'cf-${sha256.convert(utf8.encode('$entityId\n$winnerClock\n$loserClock')).toString().substring(0, 16)}';

class ConflictSide {
  const ConflictSide({required this.side, required this.deviceId, required this.clock, required this.updatedAt, required this.snapshot});
  final String side;        // 'hub' | 'device'（未知値も保持する）
  final String deviceId;
  final String clock;       // 生の HLC 文字列。Hlc に落とさないのは往復で形を変えないため。
  final DateTime updatedAt;
  final Map<String, dynamic> snapshot;
  bool get isDeleted => snapshot['deletedAt'] is String;
  Map<String, dynamic> toJson();
  factory ConflictSide.fromJson(Map<String, dynamic> json, {bool strict = false});
}

class ConflictRecord {
  const ConflictRecord({required this.id, required this.entityType, required this.entityId,
    required this.detectedAt, required this.winner, required this.loser, required this.meta,
    this.detectedBy, this.resolution, this.resolvedAt, this.resolvedBy,
    this.extra = const <String, dynamic>{}});

  static const Set<String> jsonKeys = {'id', 'entityType', 'entityId', 'detectedAt',
    'detectedBy', 'winner', 'loser', 'resolution', 'resolvedAt', 'resolvedBy'};

  final String id, entityType, entityId;
  final DateTime detectedAt;
  final String? detectedBy;
  final ConflictSide winner, loser;
  /// Unknown values are kept: an app that cannot draw a resolution must not delete it.
  final String? resolution;
  final DateTime? resolvedAt;
  final String? resolvedBy;
  final SyncMeta meta;
  final Map<String, dynamic> extra;

  bool get isOpen => resolution == null && !meta.isDeleted;

  Map<String, dynamic> toJson();
  factory ConflictRecord.fromJson(Map<String, dynamic> json, {bool strict = false});
  ConflictRecord copyWith({String? resolution, DateTime? resolvedAt, String? resolvedBy, SyncMeta? meta});
}
```

`SyncDocument` に `final List<ConflictRecord> conflicts;`（既定 `const []`）を足し、`toJson` は **空なら `conflicts` キーごと出さない**、`fromJson` は `json['conflicts']` が `List` でなければ空リスト（`strict` でも例外にしない。古い文書が普通に無いため）。`copyWith` にも足す。

- [ ] **Step 4: テストを通す**

Run: `cd tools/hub && npm test && npm run typecheck` / `flutter analyze && flutter test`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add tools/hub/src/model.ts tools/hub/src/sync-engine.ts tools/hub/test/model.conflicts.test.ts lib/services/sync/conflict_record.dart lib/services/sync/sync_document.dart test/services/sync/conflict_record_test.dart
git commit -m "feat(sync): conflict records with deterministic ids in the v2 document / 決定的 id を持つ競合レコード"
```

**レビュー観点:** id の材料が `entityId` と 2 つの clock だけか（時刻・端末名を混ぜていないか）／Dart と TS の連結文字列が完全に同じか（`\n` 区切り、順序）／`entityType` / `resolution` が enum になっていないか／`conflicts` が空のとき JSON に出ないか／スキーマ版が 2 のままか。

---

### Task 2: 検出を共有マージャへ（TS / Dart ＋ 共有フィクスチャ 8 本）

**Files:**
- Modify: `tools/hub/src/merge.ts`、`lib/services/sync/sync_merger.dart`
- Create: `test/fixtures/sync_merge/09_conflict_both_changed.json` 〜 `16_conflict_superseded.json`（8 本）
- Modify: `test/fixtures/sync_merge/manifest.json`（**追加のみ**）
- Modify: `tools/hub/test/merge.fixtures.test.ts`、`test/services/sync/sync_merger_fixture_test.dart`（`options` 対応と id パリティ）
- Test: `tools/hub/test/merge.conflicts.test.ts`、`test/services/sync/sync_merger_conflicts_test.dart`

- [ ] **Step 1: 失敗するテストを書く**

まずフィクスチャ 8 本。ケース JSON には既存の `name` / `a` / `b` / `expected` / `expectedWarnings` に加えて、任意の `options` と `expectedConflicts` を足す。

```json
// test/fixtures/sync_merge/09_conflict_both_changed.json（抜粋）
{
  "name": "both sides edited the same task after the last agreement",
  "options": {
    "lastAgreedAt": "2026-09-09T00:00:00.000Z",
    "detectedBy": "hub-macos",
    "detectedAt": "2026-09-09T03:00:00.000Z"
  },
  "a": { "…": "hub 側: tsk-1 を clock 20-0-hub-macos / updatedAt 02:00 で編集" },
  "b": { "…": "device 側: 同じ tsk-1 を clock 15-0-android-1 / updatedAt 01:00 で編集" },
  "expected": { "…": "エンティティは HLC の勝者（hub 版）そのまま" },
  "expectedConflicts": [
    {
      "id": "cf-…",
      "entityType": "task",
      "entityId": "tsk-1",
      "winner": { "side": "hub", "deviceId": "hub-macos", "clock": "20-0-hub-macos" },
      "loser": { "side": "device", "deviceId": "android-1", "clock": "15-0-android-1" },
      "resolution": null
    }
  ],
  "expectedWarnings": []
}
```

8 本の内訳（設計書 E 節の表どおり）:

| ファイル | 検証すること |
|---|---|
| `09_conflict_both_changed.json` | 両側変更で 1 件立つ。id が決定的 |
| `10_conflict_one_side_only.json` | 片側だけ変更 → 競合ゼロ |
| `11_conflict_delete_vs_edit.json` | 墓標 vs 編集で 1 件。`loser.snapshot` が墓標形 |
| `12_conflict_before_last_sync.json` | 両側とも `lastAgreedAt` より古い → 競合ゼロ |
| `13_conflict_no_last_sync.json` | `lastAgreedAt` 無し（初回同期）→ 競合ゼロ |
| `14_conflict_records_union.json` | 既存の競合レコード同士が id で和集合、解決済みが（大きい clock で）勝つ |
| `15_conflict_settings.json` | `settings` の競合（`entityId: "settings"`、`entityType: "settings"`） |
| `16_conflict_superseded.json` | 後の編集が両版を上書き → `resolution: "superseded"` |

ランナーの拡張（両言語とも **既存ケースの挙動は変えない**: `options` が無ければ従来どおり検出なし）:

```ts
// tools/hub/test/merge.fixtures.test.ts（差分）
const options = fx.options as { lastAgreedAt?: string; detectedBy?: string; detectedAt?: string } | undefined;
const ab = merge(a, b, options);
const ba = merge(b, a, options);
// …既存の期待…
// 競合は「側」が入れ替わるので id までは可換にならない。件数と entityId の集合で比べる。
expect(ab.conflicts.map((c) => c.entityId).sort()).toEqual(ba.conflicts.map((c) => c.entityId).sort());
if (fx.expectedConflicts) {
  expect(ab.conflicts.map((c) => ({ id: c.id, entityType: c.entityType, entityId: c.entityId,
    winner: { side: c.winner.side, deviceId: c.winner.deviceId, clock: c.winner.clock },
    loser: { side: c.loser.side, deviceId: c.loser.deviceId, clock: c.loser.clock },
    resolution: c.resolution ?? null })))
    .toEqual(fx.expectedConflicts);
}
```

```dart
// test/services/sync/sync_merger_fixture_test.dart（差分）
final options = fixture['options'] as Map<String, dynamic>?;
final ab = SyncMerger.merge(a, b,
    lastAgreedAt: DateTime.tryParse(options?['lastAgreedAt'] as String? ?? '')?.toUtc(),
    detectedBy: options?['detectedBy'] as String?,
    detectedAt: DateTime.tryParse(options?['detectedAt'] as String? ?? '')?.toUtc());
// 期待する competing id まで一致させる（決定的 id にした効果の実証）。
if (fixture['expectedConflicts'] != null) {
  expect(ab.conflicts.map((c) => c.id).toList(),
      (fixture['expectedConflicts'] as List).map((e) => (e as Map)['id']).toList());
}
```

さらに **id 和集合の不変条件**（設計書 B-2）を全フィクスチャに機械適用する:

```dart
// 各フィクスチャの検証の最後に（TS 側にも同じものを置く）
final before = <String>{...idsOf(a), ...idsOf(b)};
expect(idsOf(ab.document).containsAll(before), isTrue,
    reason: 'merge は id を落とさない（生存でも墓標でも必ず残る）');
```

そして検出規則そのものの単体テスト:

```ts
// tools/hub/test/merge.conflicts.test.ts（要点だけ）
it('does not detect anything when lastAgreedAt is absent', …);
it('does not detect when the two sides hold identical content', …);
it('uses max(updatedAt, clock.physical) so a lagging wall clock still counts as changed', …);
it('compares with >= so a change exactly at lastAgreedAt is treated as a conflict (over-detection is the safe side)', …);
it('treats settings as entityId "settings"', …);
it('re-detecting the same pair produces the same id and does not add a second record', …);
it('unions existing conflict records by id, letting the larger clock win', …);
it('marks a conflict superseded when the live entity clock is greater than both sides', …);
```

- [ ] **Step 2: 失敗を確認する**

Run: `cd tools/hub && npm test -- merge` / `flutter test test/services/sync/`
Expected: FAIL

- [ ] **Step 3: TS を実装する**

```ts
// src/merge.ts（追記・変更）
export interface MergeOptions {
  /** The instant the two sides last agreed — the incoming document's `lastSyncAt`. Null (the default) disables detection entirely. */
  lastAgreedAt?: string | null;
  detectedBy?: string;
  detectedAt?: string;
}

export interface MergeResult {
  document: SyncDocumentJson;
  warnings: string[];
  /** Only what this merge newly detected; `document.conflicts` also holds the older ones. */
  conflicts: ConflictJson[];
}

/**
 * `max(updatedAt, clock.physical)` in milliseconds.
 *
 * The wall clock alone is not enough: a device whose clock lags looks like it
 * changed nothing, and a missed detection means the losing version really is
 * gone. The HLC's physical component is monotonic within a device, so mixing
 * it in biases towards over-detection — an extra row the user closes with
 * 「現状のまま」, which is the cheap failure.
 */
function changedAt(e: Raw): number {
  const updated = typeof e.updatedAt === 'string' ? Date.parse(e.updatedAt) : Number.NaN;
  const clock = Hlc.tryParse(e.clock);
  const physical = clock ? clock.physical : Number.NaN;
  const values = [updated, physical].filter((v) => !Number.isNaN(v));
  return values.length === 0 ? Number.POSITIVE_INFINITY : Math.max(...values);
}
```

`mergeList` を、両側にある id について勝者を決めたあとに検出を挟む形にする:

```ts
function detect(x: Raw, y: Raw, kind: EntityKind, entityId: string, agreed: number, o: Required<MergeOptions>): ConflictJson | null {
  const hx = isDeleted(x) ? '' : contentHash(contentOf(x, kind));
  const hy = isDeleted(y) ? '' : contentHash(contentOf(y, kind));
  // A tombstone on one side and a live record on the other differ by definition
  // (the empty hash), which is exactly the conflict worth surfacing.
  if (hx === hy && isDeleted(x) === isDeleted(y)) return null;
  if (!(changedAt(x) >= agreed && changedAt(y) >= agreed)) return null;
  const winnerIsX = pick(x, y, kind) === x;
  const [w, l] = winnerIsX ? [x, y] : [y, x];
  const wClock = String(w.clock), lClock = String(l.clock);
  return {
    id: conflictId(entityId, wClock, lClock),
    entityType: kind,
    entityId,
    detectedAt: o.detectedAt,
    detectedBy: o.detectedBy,
    winner: { side: winnerIsX ? 'hub' : 'device', deviceId: Hlc.tryParse(wClock)?.deviceId ?? 'unknown', clock: wClock, updatedAt: String(w.updatedAt), snapshot: { ...w } as ConflictSideJson['snapshot'] },
    loser: { side: winnerIsX ? 'device' : 'hub', deviceId: Hlc.tryParse(lClock)?.deviceId ?? 'unknown', clock: lClock, updatedAt: String(l.updatedAt), snapshot: { ...l } as ConflictSideJson['snapshot'] },
    resolution: null, resolvedAt: null, resolvedBy: null,
    clock: wClock, updatedAt: o.detectedAt, deletedAt: null, migrated: false,
  };
}
```

`merge()` の末尾で:

```ts
// 既存の競合レコード同士は id で和集合。両側にあれば通常どおり clock の大きい方
// （＝あとから行われた解決）が勝つ。settings は id を持たないので "settings"。
const mergedConflicts = mergeList(
  (a.conflicts ?? []) as unknown as Entity[],
  (b.conflicts ?? []) as unknown as Entity[],
  'conflict',
) as unknown as ConflictJson[];

// 新規検出を id で重ね、既に同じ id があれば何もしない（再検出は冪等）。
const byId = new Map(mergedConflicts.map((c) => [c.id, c]));
for (const c of detected) if (!byId.has(c.id)) byId.set(c.id, c);

// 陳腐化: マージ後の生きている版が winner / loser の両方より新しければ、その後の
// 編集が両者を上書きしている。ユーザーの操作は要らないので自動で閉じる。
const liveClock = new Map(ENTITY_LISTS(document).flat().map((e) => [e.id, e.clock as string]));
for (const [id, c] of byId) {
  if (c.resolution != null) continue;
  const now = liveClock.get(c.entityId);
  if (!now) continue;
  const h = Hlc.tryParse(now); const w = Hlc.tryParse(c.winner.clock); const l = Hlc.tryParse(c.loser.clock);
  if (h && w && l && Hlc.compare(h, w) > 0 && Hlc.compare(h, l) > 0) {
    byId.set(id, { ...c, resolution: 'superseded', resolvedAt: options.detectedAt, resolvedBy: options.detectedBy });
  }
}
const conflicts = [...byId.values()].sort((x, y) => compareStrings(x.id, y.id));
```

`ENTITY_KEYS` に `conflict: ['id','entityType','entityId','detectedAt','detectedBy','winner','loser','resolution','resolvedAt','resolvedBy']` を足して、既存の `pick` / `metaKey` がそのまま使えるようにする。`document.conflicts` は **空配列なら出さない**（`if (conflicts.length > 0) document.conflicts = conflicts;`）。

- [ ] **Step 4: Dart を実装する**

`SyncMerger.merge(SyncDocument a, SyncDocument b, {DateTime? lastAgreedAt, String? detectedBy, DateTime? detectedAt})`。既定は `lastAgreedAt: null` ＝ 検出しない（既存の呼び出し・フィクスチャ・property test はそのまま通る）。`MergeResult` に `final List<ConflictRecord> conflicts;` を足す。

Dart は live と tombstone を別リストで持つので、`_mergeLists` の中で「両側に `_Record` があり、片方が dead の場合も含めて」検出する。`contentHash` の呼び分けは既存の `_pick` と同じ（dead は空文字）。`changedAt` は `max(meta.updatedAt.millisecondsSinceEpoch, meta.clock.physical)`。

TS の `mergeList` を通した `conflicts` の和集合は、Dart では `ConflictRecord` を `_Record.live(c.id, c.toJson(), c.meta)` に包んで既存の `_mergeLists` に渡せば規則がそのまま揃う。

- [ ] **Step 5: テストを通す**

Run: `cd tools/hub && npm test && npm run typecheck` / `flutter analyze && flutter test`
Expected: PASS（既存 8 ケースの期待値は 1 文字も変えていないこと）

- [ ] **Step 6: コミット**

```bash
git add tools/hub/src/merge.ts tools/hub/test/merge.conflicts.test.ts tools/hub/test/merge.fixtures.test.ts lib/services/sync/sync_merger.dart test/fixtures/sync_merge test/services/sync/sync_merger_fixture_test.dart test/services/sync/sync_merger_conflicts_test.dart
git commit -m "feat(sync): detect conflicts in the shared merger with parity fixtures / 共有マージャでの競合検出と共有フィクスチャ"
```

**レビュー観点:** 既存フィクスチャ 8 本の `expected` を変えていないか／`options` が無いケースで検出が一切走らないか／Dart と TS で同じ id が出るか（フィクスチャの `expectedConflicts[].id` を両言語が満たすか）／`>=` で比較しているか（過検出寄り）／エンティティのマージ規則自体は変わっていないか／`conflicts` が空のときキーが出ないか。

---

### Task 3: `SyncEngine` / `SyncService` 配線と上限・TTL

**Files:**
- Modify: `tools/hub/src/sync-engine.ts`
- Modify: `lib/services/sync/sync_progress.dart`（`SyncSummary.conflicts`）、`lib/services/sync/sync_service.dart`
- Test: `tools/hub/test/sync-engine.conflicts.test.ts`、`test/services/sync/sync_service_conflicts_test.dart`

- [ ] **Step 1: 失敗するテストを書く**

```ts
// tools/hub/test/sync-engine.conflicts.test.ts（要点）
it('reports the count in summary.conflicts and the records alongside the document', async () => {
  const result = await engine.sync('android-1', incoming, 'merge');
  expect(result.summary.conflicts).toBe(1);
  expect(result.conflicts.map((c) => c.entityId)).toEqual(['tsk-1']);
  // 競合を warnings に混ぜない: summary.warnings が warnings.length のままである必要がある。
  expect(result.warnings.some((w) => w.includes('conflict'))).toBe(false);
  expect(result.summary.warnings).toBe(result.warnings.length);
});

it('passes the incoming lastSyncAt as lastAgreedAt and the hub id as detectedBy', async () => { … });

it('detects nothing on the first sync (lastSyncAt null)', async () => { … });

it('keeps conflicts as a union through take_phone and take_web', async () => {
  // ハブに 2 件、受信文書に 1 件。置き換えでも記録は 3 件残る。
  const result = await engine.sync('android-1', incomingWithOneConflict, 'take_phone');
  expect(result.document.conflicts).toHaveLength(3);
});

it('take_hub keeps the hub conflicts untouched', async () => { … });

it('caps open conflicts at 1000, dropping the oldest and warning', async () => {
  expect(result.document.conflicts!.filter((c) => c.resolution == null)).toHaveLength(1000);
  expect(result.warnings).toContain('conflict_overflow');
});

it('keeps only the 200 most recent resolved conflicts', async () => { … });

it('tombstones resolved conflicts older than 30 days and purges them on the existing cutoff', async () => {
  const purged = await engine.purge();
  expect(purged.purged).toBeGreaterThan(0);
  expect((await store.read()).conflicts ?? []).toHaveLength(0);
});

it('never loses an id: the merged document holds every id either side had', async () => { … });
```

- [ ] **Step 2: 失敗を確認する**

Run: `cd tools/hub && npm test -- sync-engine`
Expected: FAIL

- [ ] **Step 3: 実装する**

```ts
// src/sync-engine.ts（差分）
export interface SyncSummary { added: number; updated: number; deleted: number; removed: number; warnings: number; conflicts: number; }
export interface SyncResult { document: SyncDocumentJson; summary: SyncSummary; warnings: string[]; conflicts: ConflictJson[]; }

/** Ceilings from the design (C-2). Open conflicts are the ones the user still has to answer. */
export const MAX_OPEN_CONFLICTS = 1000;
export const MAX_RESOLVED_CONFLICTS = 200;
export const RESOLVED_CONFLICT_TTL_MS = 30 * 24 * 60 * 60 * 1000;
```

`sync()` の中:

```ts
let detected: ConflictJson[] = [];
// …update() の中…
if (mode === 'take_phone') {
  merged = { ...incoming, deviceId: current.deviceId, purgedBefore: current.purgedBefore ?? null };
  // Replacing the data must not replace the record of what was in conflict.
  merged.conflicts = unionConflicts(current.conflicts ?? [], incoming.conflicts ?? []);
} else if (mode === 'take_hub') {
  merged = { ...current, conflicts: unionConflicts(current.conflicts ?? [], incoming.conflicts ?? []) };
} else {
  const r = merge(current, incoming, {
    lastAgreedAt: incomingLastSync,
    detectedBy: this.store.deviceId,
    detectedAt: at,
  });
  merged = r.document;
  mergeWarnings = r.warnings;
  detected = r.conflicts;
}
const capped = capConflicts(merged.conflicts ?? [], at);
if (capped.dropped > 0) mergeWarnings = [...mergeWarnings, 'conflict_overflow'];
if (capped.conflicts.length > 0) merged.conflicts = capped.conflicts; else delete merged.conflicts;
// …
summary = { ...summarize(current, merged, warnings.length), conflicts: detected.length };
```

`capConflicts` は「未解決を `detectedAt` 昇順で並べて 1000 件を超えた古いものを落とす」「解決済みを `resolvedAt` 降順で 200 件に切る」「`resolvedAt` が 30 日より古い解決済みを墓標化する（`deletedAt = at`、`clock` は据え置き — 掃除であって編集ではない）」を 1 か所でやる純関数。テストしやすいよう export する。

`purge()` の `keep` を回すリストに `doc.conflicts` を足す（同じ `deletedAt < cutoffMs` の規則）。`conflicts` が空になったらキーを消す。

Dart 側:

```dart
// sync_progress.dart
class SyncSummary {
  const SyncSummary({required this.added, required this.updated, required this.deleted,
    required this.warnings, this.removed = 0, this.conflicts = 0});
  final int conflicts;
  factory SyncSummary.fromJson(Map<String, dynamic> j) => SyncSummary(
    …, conflicts: j['conflicts'] as int? ?? 0);
}
```

`SyncService`:
- `syncNow` は今までどおり `SyncApplied` を返す（競合は同期を止めない）。応答の `conflicts` は `document.conflicts` として `importDocument` 経由で入るので、追加の配線は不要。
- `applyReceived`（QR / ファイル）は `SyncMerger.merge(local, incoming, lastAgreedAt: settings.lastSyncAt, detectedBy: deviceClock.deviceId, detectedAt: DateTime.now().toUtc())` を渡し、`merged.summaryAgainst(local)` に `conflicts: merged.conflicts.length` を載せる。
- 解決の書き込み用に `Future<void> resolveConflict(String id, ConflictAdopt adopt)` を足す（Task 5 の画面から呼ぶ）。採用側のスナップショットを **新しい HLC の編集** として書き戻し、レコードの `resolution` / `resolvedAt` / `resolvedBy` と `clock` を進める。採用側が既に生きている版と同一なら書き戻しはせず `resolution` だけ立てる。

- [ ] **Step 4: テストを通す**

Run: `cd tools/hub && npm test && npm run typecheck && npm run build` / `flutter analyze && flutter test`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add tools/hub/src/sync-engine.ts tools/hub/test/sync-engine.conflicts.test.ts lib/services/sync/sync_progress.dart lib/services/sync/sync_service.dart test/services/sync/sync_service_conflicts_test.dart
git commit -m "feat(sync): surface conflict counts and keep the record through replace modes / 競合件数の露出と置き換えでの記録保持"
```

**レビュー観点:** `warnings` に競合を混ぜていないか（`summary.warnings === warnings.length` が保たれているか）／`take_phone` / `take_web` / `take_hub` のすべてで `conflicts` が和集合か／上限・TTL が 1 つの純関数に閉じているか／`purge` の対象に `conflicts` が入ったか／初回同期で検出ゼロか。

---

### Task 4: MCP ツール 4 個（39 → 43）

**Files:**
- Modify: `tools/hub/src/tools.ts`、`tools/hub/src/index.ts`
- Modify: `tools/hub/scripts/smoke.mjs`、`tools/hub/README.md`、`tools/hub/docs/tool-coverage.md`
- Test: `tools/hub/test/tools.conflicts.test.ts`

- [ ] **Step 1: 失敗するテストを書く**

```ts
// tools/hub/test/tools.conflicts.test.ts（要点）
it('list_conflicts counts open and resolved and returns a human label', async () => {
  const r = await tools.listConflicts({});
  expect(r.open).toBe(2);
  expect(r.resolved).toBe(1);
  expect(r.conflicts[0]).toMatchObject({ id: expect.stringMatching(/^cf-/), entityType: 'task', entityId: 'tsk-1' });
  expect(typeof r.conflicts[0].label).toBe('string');
  expect((await tools.listConflicts({ status: 'resolved' })).conflicts).toHaveLength(1);
  expect((await tools.listConflicts({ entityType: 'settings' })).conflicts).toHaveLength(0);
});

it('get_conflict lists only the fields that differ plus what is live now', async () => {
  const r = await tools.getConflict({ id });
  expect(r.differences).toEqual([{ field: 'title', hub: '確定申告の書類を集める', device: '確定申告（領収書だけ先に）' }]);
  expect(r.current).toMatchObject({ clock: expect.any(String), deletedAt: null, supersedes: false });
  await expect(tools.getConflict({ id: 'cf-nope' })).rejects.toThrow(/not found/);
});

it('resolve_conflict with adopt=current only marks the record, writing nothing', async () => {
  const before = await store.read();
  const r = await tools.resolveConflict({ id, adopt: 'current' });
  expect(r).toMatchObject({ id, adopted: 'current', wrote: false });
  expect((await store.read()).taskMaster.tasks).toEqual(before.taskMaster.tasks);
});

it('resolve_conflict with adopt=device writes the loser back as a fresh edit', async () => {
  const r = await tools.resolveConflict({ id, adopt: 'device' });
  expect(r.wrote).toBe(true);
  const task = (await store.read()).taskMaster.tasks.find((t) => t.id === 'tsk-1')!;
  expect(task.title).toBe('確定申告（領収書だけ先に）');
  // 据え置きの id、進んだ clock、migrated は false。次のマージで全端末に伝播する。
  expect(Hlc.compare(Hlc.parse(task.clock as string), Hlc.parse(loserClock))).toBeGreaterThan(0);
  expect(task.migrated).toBe(false);
});

it('adopting a tombstone deletes the entity again', async () => { … });

it('resolve_all_conflicts is all-or-nothing and dryRun writes nothing', async () => {
  const dry = await tools.resolveAllConflicts({ adopt: 'hub', dryRun: true });
  expect(dry.resolved).toBe(2);
  expect((await store.read()).conflicts!.every((c) => c.resolution == null)).toBe(true);
  const done = await tools.resolveAllConflicts({ adopt: 'hub' });
  expect(done.results).toHaveLength(2);
});

it('resolving twice is refused rather than silently re-resolving', async () => { … });
```

- [ ] **Step 2: 失敗を確認する**

Run: `cd tools/hub && npm test -- tools.conflicts`
Expected: FAIL

- [ ] **Step 3: 実装する**

```ts
// src/tools.ts（schemas に追記）
listConflicts: z.object({
  status: z.enum(['open', 'resolved', 'all']).optional(),
  entityType: z.string().optional(),
  limit: z.number().int().min(1).max(500).optional(),
}),
getConflict: z.object({ id: z.string() }),
resolveConflict: z.object({ id: z.string(), adopt: z.enum(['hub', 'device', 'current']) }),
resolveAllConflicts: z.object({
  adopt: z.enum(['hub', 'device', 'current']),
  entityType: z.string().optional(),
  dryRun: z.boolean().optional(),
}),
```

4 メソッドの骨子:

```ts
/** Reading only: no lock beyond the store's own read. */
async listConflicts(input): Promise<{ open: number; resolved: number; conflicts: Array<{ id: string; entityType: string; entityId: string; label: string; detectedAt: string; resolution: string | null }> }>

async getConflict(input): Promise<{
  conflict: ConflictJson;
  /** Only the fields whose values differ; meta keys are excluded. */
  differences: Array<{ field: string; hub: unknown; device: unknown }>;
  /** What data.json holds for that entity right now. */
  current: { clock: string | null; deletedAt: string | null; supersedes: boolean };
}>

/**
 * Adopting a side writes it back as a *new* edit rather than rewinding the
 * clock: the id stays, `clock` advances, `updatedAt` becomes now and
 * `migrated` is false, so an ordinary merge carries the decision to the phone
 * and to the browser. Adopting a tombstone deletes the entity again.
 */
async resolveConflict(input): Promise<{ id: string; adopted: string; wrote: boolean; summary: SyncSummary }>

/** One `store.update`: if any single id fails, nothing at all is written. */
async resolveAllConflicts(input): Promise<{ resolved: number; skipped: number; results: Array<{ id: string; adopted: string; wrote: boolean }> }>
```

要点:
- 全部 `store.update` の 1 ロック内。`resolveAllConflicts` は 1 回の書き込みでまとめて適用する。
- 採用側のスナップショットが既に生きている版と `contentHash` で同一なら `wrote: false`（`resolution` だけ立てる）。
- `label` は「タスク『確定申告の書類を集める』」のような日本語の 1 行（`entityType` と勝者スナップショットの `title` / `name` / `date` から作る。無ければ `entityId`）。
- 既に `resolution` が入っている競合への `resolve_conflict` は `ToolError`（「すでに解決済みです」）。`adopt: 'current'` でも同じ。

`index.ts` の登録（説明文は既存ツールと同じ水準で、破壊性を明示する）:

```ts
register('list_conflicts', 'List recorded sync conflicts (records where the same entity was edited on both sides). status defaults to open', schemas.listConflicts.shape, (i) => wrap(() => tools.listConflicts(i)));
register('get_conflict', 'Get one conflict with the fields that differ between the two versions and what data.json holds right now', schemas.getConflict.shape, (i) => wrap(() => tools.getConflict(i)));
register('resolve_conflict', "Resolve one conflict by adopting the hub version, the device version, or leaving the current state as-is. Adopting writes that snapshot back as a fresh edit (a new clock), so it propagates to the phone and the browser on the next sync; adopting a tombstone deletes the entity again", schemas.resolveConflict.shape, (i) => wrap(() => tools.resolveConflict(i)));
register('resolve_all_conflicts', 'Destructive: resolve every open conflict the same way in one write (all or nothing). dryRun reports what would change without writing', schemas.resolveAllConflicts.shape, (i) => wrap(() => tools.resolveAllConflicts(i)));
```

- [ ] **Step 4: スモークとドキュメントを更新する**

`scripts/smoke.mjs`:
- `check('tool count is 39', …)` → **43**、必須ツール一覧に 4 個を追加。
- 競合を作る往復: `add_task` → `export_data` → その文書のタスクを別内容・別 clock に書き換え、`lastSyncAt` を過去に設定 → `import_data`（`mode` 既定 = merge）→ `list_conflicts` が 1 件 → `get_conflict` の `differences` に `title` → `resolve_conflict({adopt:'device'})` → `get_task` が device 版になっている、を 1 本。

`README.md` に「競合（Plan 3b）」の節、`docs/tool-coverage.md` のマトリクスに `conflict` 行と「追加したツール（4 個）」表、ツール数 39 → 43 の更新。

```markdown
| conflict | —（マージが作る） | ✔ `list_conflicts` | ✔ `get_conflict` | ✔ `resolve_conflict` | ✔（解決 30 日後に自動墓標化） | — | ✔ `resolve_all_conflicts` | 採用は新しい clock の編集として書き戻る |
```

- [ ] **Step 5: テストを通す**

Run: `cd tools/hub && npm test && npm run typecheck && npm run build && npm run smoke`
Expected: PASS（`tools listed: 43`）

- [ ] **Step 6: コミット**

```bash
git add tools/hub/src/tools.ts tools/hub/src/index.ts tools/hub/test/tools.conflicts.test.ts tools/hub/scripts/smoke.mjs tools/hub/README.md tools/hub/docs/tool-coverage.md
git commit -m "feat(hub): list, inspect and resolve sync conflicts from MCP / MCP から競合を一覧・確認・解決する"
```

**レビュー観点:** 解決が clock を巻き戻していないか（必ず `clock.next()`）／`resolve_all` が全か無かか／`dryRun` が本当に書かないか／ツール数 43 がスモークと `tool-coverage.md` の両方で揃っているか／説明文が破壊性を明示しているか。

---

### Task 5: スマホ / Web UI（一覧・詳細・進捗パネル）

**Files:**
- Create: `lib/features/sync/application/conflict_controller.dart`
- Create: `lib/features/sync/presentation/conflict_list_screen.dart`、`conflict_detail_screen.dart`
- Modify: `lib/features/sync/presentation/sync_progress_panel.dart`、`sync_settings_screen.dart`、`lib/app/router.dart`
- Test: `test/features/sync/conflict_screens_test.dart`、`test/features/sync/sync_progress_panel_conflicts_test.dart`

- [ ] **Step 1: 失敗するテストを書く**

```dart
// test/features/sync/conflict_screens_test.dart（要点）
testWidgets('the list separates open conflicts from resolved ones', (tester) async {
  await pump(tester, const ConflictListScreen());
  expect(find.text('未解決 2 件'), findsOneWidget);
  expect(find.textContaining('タスク「確定申告の書類を集める」'), findsOneWidget);
  // 解決済みは折りたたみの中。
  expect(find.text('解決済み 1 件'), findsOneWidget);
});

testWidgets('the detail screen highlights only the differing fields and offers three choices', (tester) async {
  await pump(tester, ConflictDetailScreen(id: id));
  expect(find.text('PC 版'), findsOneWidget);
  expect(find.text('スマホ版'), findsOneWidget);
  expect(find.text('PC 版を採用'), findsOneWidget);
  expect(find.text('スマホ版を採用'), findsOneWidget);
  expect(find.text('現状のまま'), findsOneWidget);
});

testWidgets('adopting writes a fresh edit with a clock greater than both sides', (tester) async {
  await tester.tap(find.text('スマホ版を採用'));
  await tester.pumpAndSettle();
  final task = (await store.readTaskMaster()).tasks.firstWhere((t) => t.id == 'tsk-1');
  expect(task.title, '確定申告（領収書だけ先に）');
  expect(task.meta.clock.compareTo(loserClock) > 0, isTrue);
});

testWidgets('one side deleted is drawn as 削除済み, not as an empty record', (tester) async { … });

testWidgets('the batch buttons confirm before applying', (tester) async {
  await tester.tap(find.text('すべて PC 版を採用'));
  await tester.pumpAndSettle();
  expect(find.text('採用する'), findsOneWidget);   // confirmAction のダイアログ
});

testWidgets('in hub mode the labels say PC（MCP）版 / この端末の版', (tester) async { … });

// sync_progress_panel_conflicts_test.dart
testWidgets('the completion line adds 競合 n 件 and a way in', (tester) async {
  await pumpPanel(tester, const SyncSummary(added: 1, updated: 0, deleted: 0, warnings: 0, conflicts: 2));
  expect(find.textContaining('競合 2'), findsOneWidget);
  expect(find.text('確認する'), findsOneWidget);
  // 同期そのものは成功として閉じる。
  expect(find.text('同期しました'), findsOneWidget);
});
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/features/sync/`
Expected: FAIL

- [ ] **Step 3: 実装する**

- `conflict_controller.dart`: ドキュメントの `conflicts` を読み、未解決／解決済みに分けて公開する `AsyncNotifier`。解決は `SyncService.resolveConflict` を呼び、`taskMasterControllerProvider` / `dailyPlanControllerProvider` を invalidate する。
- `ConflictListScreen`（`/sync/conflicts`）: 未解決を上、解決済みは `ExpansionTile` で折りたたみ。行は `label` ＋ 検出時刻 ＋ 現在採用中の側。上部に一括ボタン「すべて PC 版を採用」「すべてスマホ版を採用」（`confirmAction` で確認、`destructive: true`）。
- `ConflictDetailScreen`（`/sync/conflicts/:id`）: 二列の対比表。差のあるフィールドだけ強調（同じフィールドは `onSurfaceVariant` で薄く）。片側が墓標なら「削除済み」を大きく描く。ボタン 3 つ。
- ラベルの出し分け（`deviceId` から）:
  - `hub-*` → 「PC（MCP）版」
  - `web-*` → hub モードで自分の id なら「この端末の版」、それ以外は「ブラウザ版」
  - それ以外 → ペアリング名があればその名前、無ければ「スマホ版」
- `sync_progress_panel.dart`: 完了行の文言を `'追加 ${s.added} / 更新 ${s.updated} / 削除 ${s.deleted} / 消去 ${s.removed} / 警告 ${s.warnings}'` に **「/ 競合 ${s.conflicts}」を追加**し、`s.conflicts > 0` のときだけ「確認する」ボタンを出す（押すと `/sync/conflicts` へ）。同期は成功として閉じる。
- `sync_settings_screen.dart`: 「PC と同期」画面に「競合」行を常設し、未解決があれば件数バッジ。hub モードでもこの行は出す（LAN 系を隠す Plan 3a の分岐とは独立）。
- `router.dart`: `/sync` の子に `conflicts` と `conflicts/:id` を足す。
- 解決はこの端末のローカル編集として書く（`DeviceClock.next()`）。オフラインでも解決でき、次の同期で PC に伝播する。

- [ ] **Step 4: テストを通す**

Run: `flutter analyze && flutter test`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add lib/features/sync lib/app/router.dart test/features/sync
git commit -m "feat(app): conflict list and detail screens with batch resolution / 競合の一覧・詳細画面と一括解決"
```

**レビュー観点:** 進捗パネルが同期を「失敗」に見せていないか／一括ボタンが `confirmAction` を通るか／墓標側が空欄でなく「削除済み」と描かれるか／hub モードでも同じ画面が動くか（プラットフォーム固有コードを含まないこと）／解決が新しい clock を書いているか。

---

### Task 6: リリース（版上げ・リリースノート・Play への影響）

**Files:**
- Modify: `pubspec.yaml`（`1.0.0+5` → `1.0.0+6`）
- Modify: `docs/distribution_release_prep.md`
- Modify: `README.md`（機能の一行）

- [ ] **Step 1: 版を上げる**

```yaml
version: 1.0.0+6
```

- [ ] **Step 2: リリースノートを書く**

```markdown
## 1.0.0+6

PC と同期したときに、同じ項目を PC とスマホの両方で編集していた場合は「競合」として
記録し、あとからどちらを採用するか選べるようになりました。同期そのものは今までどおり
完了します。「設定 › PC と同期 › 競合」から一覧を開けます。
```

データセーフティは「収集なし」のまま **変更なし**（競合レコードは端末とオーナーの PC の間だけを往復する）。権限の追加も無し。

- [ ] **Step 3: 互換性を確認する**

- スキーマ版は 2 のまま。`conflicts` を持たない v2 文書の往復（Plan 2b ビルド ⇄ 新ハブ）。
- 古いアプリは `conflicts` を落とすが、ハブ側が常に和集合にするのでハブの記録は消えない（設計書 E 節）。この非対称を README に明記する。

- [ ] **Step 4: ビルドを通す**

**main のチェックアウトで**（`android/key.properties` が worktree に無い）:

```bash
flutter analyze && flutter test
flutter build appbundle
flutter build macos
flutter build web
cd tools/hub && npm test && npm run typecheck && npm run build && npm run smoke
```

- [ ] **Step 5: コミット**

```bash
git add pubspec.yaml docs/distribution_release_prep.md README.md
git commit -m "chore(release): bump to 1.0.0+6 with conflict resolution release notes / 競合解決を含む版 6"
```

**レビュー観点:** データセーフティの回答が変わっていないか／リリースノートが「同期は今までどおり完了する」を書いているか／`macos/` の無関係な差分が混ざっていないか／AAB がビルドできるか。

---

## 自己レビュー

- 設計書カバレッジ: C-1 検出規則（`changedAt = max(updatedAt, clock.physical)`、`>=`、`lastAgreedAt = incoming.lastSyncAt`、初回免除、`settings` は `entityId: "settings"`、削除 vs 編集）（Task 2）、C-2 データ形状・決定的 id・上限 1000/200・30 日 TTL・purge 統合（Task 1, 3）、C-3 マージ時の挙動（エンティティ規則は不変・`MergeResult.conflicts`・`summary.conflicts`・warnings に混ぜない・レコード同士の和集合・置き換えモードの例外・`superseded`）（Task 2, 3）、D-1 MCP 4 ツール（Task 4）、D-2 / D-3 スマホと Web の UI（Task 5）、D-4 ハブのローカルページに競合ページを作らない（意図的に不実装）、B-2 id 和集合の不変条件（Task 2）、E 互換性（Task 1, 6）。
- 型の整合（実コードで確認済み）: TS `merge(a, b) → { document, warnings }`（→ `conflicts` 追加）、`pick(x, y, kind)` / `contentOf` / `mergeList` / `ENTITY_KEYS` / `readMeta` / `metaKey`、`Hlc.compare` / `Hlc.tryParse` / `Hlc.parse`、`contentHash`、`SyncEngine.sync(deviceId, incoming, mode)` と `SyncSummary { added, updated, deleted, removed, warnings }`、`SyncRejected`、`PURGE_SKEW_MS`、`FileStore.update`、`HubTools.mutate` / `stamp()` / `tomb()` / `pushLive` / `ToolError`、`schemas`。Dart `SyncMerger.merge(a, b)`（→ 名前付き引数追加）、`MergeResult.summaryAgainst`、`_pick` / `_mergeLists` / `_Record` / `_metaKey`、`SyncMeta`（`clock` / `updatedAt` / `deletedAt` / `migrated` / `extra`）、`Tombstone`、`SyncDocument.fromJson(json, {strict})` / `toJson()`、`SyncSummary.fromJson`、`SyncService.applyReceived` / `syncNow` / `_observeClocks`、`confirmAction`、`stateStoreProvider`。
- 未決・注意: 競合レコードは `mergeList` に `'conflict'` という `EntityKind` を足して既存の勝敗規則に乗せるが、`ENTITY_KEYS.conflict` の並びは `contentHash` の入力に効くので Dart 側の `ConflictRecord.toJson()` のキー集合と **必ず一致させる**こと（ずれると同じレコードのハッシュが両言語で割れ、clock が同値のときだけ勝者が食い違う）。`conflicts` の和集合は id ベースなので、`entityId` が同じでも clock の組が違えば別レコードとして両方残る — 意図どおり（解決後の再編集は新しい id の競合になる）。

### 実装後の追記（Task 4–6）

- **Batch 1 からの持ち越しを Task 5 で吸収した。** `SyncService.resolveConflict` と、スマホ側で
  `conflicts` を保存する経路（`StateStore.readConflicts` / `writeConflicts`、
  `writeAll(..., conflicts:)`、`AppDataService.exportDocument` / `importDocument`）は
  Task 1–3 では未実装だったので Task 5 でまとめて入れた。
- **道中で見つかった取りこぼし（いずれも修正済み）。** 競合レコードは
  (1) `SyncService._syncNow` が組み立てる送信ペイロード、(2) `FileBackedStore` の 3 つの
  書き込み経路、(3) `HubBackedStore._payload` のいずれからも落ちていた。落としたままだと
  端末側で解決しても PC に伝わらず、macOS ではローカル編集のたびにハブの記録が消える。
  `HubBackedStore._bodyOf`（画面が遅れているかの判定）にも `conflicts` を含めた。
- **UI のラベル。** ペアリング名は `FRELOCATOR (<deviceId>)` という自動生成の文字列で、
  画面に出すと「スマホ版」より分かりにくいため使っていない。ハブ側は hub モードでのみ
  「PC（MCP）版」、通常は「PC 版」と出し分ける（hub モードではブラウザ自身が PC なので
  区別が要る）。一括ボタンは `すべて<ラベル>を採用`（計画本文の「すべて PC 版を採用」に
  対して、ラベル側の空白の有無だけが違う）。
- **`get_conflict` の差分。** `deletedAt` は差分から除外せず、片側が墓標なら差として出す。
  アプリ側の詳細画面だけは、墓標側を項目の羅列ではなく「削除済み」1 語で描く。
- **purge で消えたエンティティ。** 書き込みを伴う採用は TS / Dart とも拒否し、
  `adopt: 'current'`（「現状のまま」）でだけ記録を閉じられる。カテゴリはスナップショットに
  kind が無く、どちらのリストに戻すべきか決められないため。
- **検証結果:** ハブ `npm test` 320 件（+10）／`typecheck`・`build`・`smoke`（`tools listed: 43`）
  すべて緑。アプリ `flutter analyze` 0 件、`flutter test` 389 件（+20）。
  リリース成果物（AAB / macOS / web）は main のチェックアウトで作る。

---

## 実装者への注意

- **worktree で作業する。** `superpowers:using-git-worktrees` で隔離した作業ツリーを作り、そこで実装する。main のチェックアウトは触らない。
- **TDD を守る。** 各 Task は「失敗するテストを書く → 失敗を確認する → 実装する → 通す → コミット」の順。テストを後から書かない。
- **コミットメッセージに Claude / Anthropic の情報を一切入れない。** `Co-Authored-By: Claude …`、`🤖 Generated with Claude Code`、その他の署名・帰属行は禁止。本文は Conventional Commits の EN / JA 併記のまま。
- **共有フィクスチャ（`test/fixtures/sync_merge/`）の既存 8 ケースは絶対に変更しない。** `09`〜`16` の **追加だけ**。`manifest.json` も追記のみ。既存ケースが `options` 無しで従来どおり通ることが、後方互換の証明になっている。
- **Dart / TS のパリティを保つ。** 検出規則・決定的 id・`ENTITY_KEYS.conflict` のキー集合・`contentHash` の入力を片方だけ直さない。フィクスチャの `expectedConflicts[].id` を両言語が満たすことで担保する。
- **検証コマンド:** `cd tools/hub && npm test && npm run typecheck && npm run build && npm run smoke`、リポジトリ直下で `flutter analyze && flutter test`。全部緑になるまで完了と言わない。
- **リリース成果物（AAB / macOS / web の配布ビルド）は main のチェックアウトでのみ作る。** 署名鍵の `android/key.properties` は worktree に無い。
- **`macos/` の無関係な差分は戻す。** Xcode / CocoaPods が勝手に書き換えたファイルはコミットに含めない。
