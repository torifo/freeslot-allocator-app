# MCP ツール網羅監査 / MCP tool coverage audit

ハブが触るのはオーナー自身のデータだけなので、すべてのエンティティを MCP から
「作成・取得・更新・削除」できることを目標に、`src/model.ts` のデータモデルと
Flutter アプリ（`lib/`）が実行できる変更操作を洗い出し、既存ツールと突き合わせた。

対象コミット: `feature/hub-tool-coverage`（FRELOCATOR main から分岐）
監査時点のツール数: 26 → 実装後: 39 → 競合の記録と解決（Plan 3b）を加えて 43

---

## 1. データモデル（`src/model.ts` / Dart `lib/**/domain/*.dart`）

すべてのレコードは自分のフィールドに加えて `SyncMetaJson`
（`clock` = HLC, `updatedAt`, `deletedAt`, `migrated`）を持つ。削除は物理削除では
なく「id + meta だけの墓標（tombstone）」への置き換えで、`purge_tombstones` が
安全域を超えたものだけを物理削除する。

| セクション | エンティティ | フィールド |
| --- | --- | --- |
| `taskMaster.tasks` | task | `id`, `title`, `kind`(`must_do`/`want_to_do`), `priority`(int), `createdAt`, `memo`, `categoryId`(nullable), `estimatedMinutes` |
| `taskMaster.mustDoCategories` | category (must_do) | `id`, `name` |
| `taskMaster.wantToDoCategories` | category (want_to_do) | `id`, `name` |
| `taskMaster.settings` | settings | `shareCategories`(bool) ＋ meta |
| `dailyPlan.plans` | plan | `id`, `date`(YYYY-MM-DD), `createdAt` |
| `dailyPlan.slots` | free time slot | `id`, `dailyPlanId`, `startAt`, `endAt`, `label` |
| `dailyPlan.assignments` | assignment | `id`, `dailyPlanId`, `slotId`, `taskId`, `taskTitle`, `taskKind`, `startAt`, `endAt`, `sortOrder`, `categoryId`, `categoryName`, `memo` |
| ドキュメント本体 | — | `version`, `exportedAt`, `deviceId`, `lastSyncAt`, `purgedBefore` |

**モデルに無いもの**（したがってツールも作れない）:

- タスクの完了フラグ（`done` / `completedAt`）は存在しない。`complete_task` /
  `uncomplete_task` は**実装不可**。
- タスクに並び順フィールド（`sortOrder`）は無い。アプリの並べ替えは
  `priority` の書き換えで表現される（後述）。
- スロットに並び順フィールドは無い。表示順は常に `startAt` 昇順
  （Dart `sortSlots`）。よって `reorder_free_slots` は**意味を持たない**。

## 2. アプリ（Flutter）が実行できる変更操作

`lib/features/task_master/application/task_master_controller.dart`:

| 操作 | 意味 |
| --- | --- |
| `addOrUpdateTask` | タスクの追加／全項目更新 |
| `deleteTask` | タスクを墓標化 |
| `reorderTasks(kind, orderedIds)` | 種別内の並べ替え。`priority = 件数 - index` を全件に書き戻す（1..5 の上限は無い） |
| `upsertCategory(kind, category)` | カテゴリ追加／改名。共有 ON なら両リストへ反映 |
| `deleteCategory(kind, id)` | カテゴリを墓標化し、参照していたタスクの `categoryId` を null に |
| `setShareCategories(enabled, strategy)` | カテゴリ共有の ON/OFF。ON 時は `CategoryMergeStrategy`（keepShorter/keepLonger/keepMustDo/keepWantToDo）で 2 リストを統合し、消えるカテゴリを墓標化、参照していたタスクを同名カテゴリへ付け替え（同名が無ければ null 化） |

`lib/features/daily_plan/application/daily_plan_controller.dart`:

| 操作 | 意味 |
| --- | --- |
| `ensurePlanForDate(date)` | その日の計画が無ければ作る |
| `duplicatePlan(source, target, slotIds?, assignmentIds?, includeAssignments, replaceExisting)` | 別日から取り込む。日数差だけ時刻をシフトし、id は `copyId` の決定的ハッシュ |
| `upsertSlot(slot)` | 自由時間枠の追加／更新（重なり検証あり） |
| `deleteSlot(id)` | 枠と、その枠の割り当てをまとめて墓標化 |
| `upsertAssignment(a)` | 割り当ての追加／更新（枠内・重なり検証あり）＋ 枠内の `sortOrder` 再採番 |
| `moveAssignmentToSlot(id, targetSlotId, beforeAssignmentId?)` | 割り当てを別枠／同枠の別位置へ移動。移動先の枠頭から詰め直して時刻を再計算し、両方の枠を再採番 |
| `deleteAssignment(id)` | 割り当てを墓標化し、枠を再採番 |

**アプリに無い操作**: 日次計画（plan）そのものの削除・日付変更。plan の墓標
（`deletedPlans`）は Dart 側のモデルにも存在し、同期でも扱えるので、ハブから
削除・移動を提供しても壊れない。

## 3. 監査時点の既存 26 ツール

| ツール | 入力スキーマ |
| --- | --- |
| `list_tasks` | `kind?`, `categoryId?`, `query?` |
| `add_task` | `title`, `kind`, `priority?`, `categoryId?`, `estimatedMinutes?`, `memo?` |
| `bulk_add_tasks` | `tasks[1..100]`（`add_task` と同形） |
| `update_task` | `id`, `title?`, `kind?`, `priority?`, `categoryId?`(nullable), `estimatedMinutes?`, `memo?` |
| `delete_task` | `id` |
| `list_categories` | `kind?` |
| `add_category` | `kind`, `name` |
| `update_category` | `kind`, `id`, `name` |
| `delete_category` | `kind`, `id` |
| `list_daily_plans` | `from`, `to` |
| `get_daily_plan` | `date` |
| `add_free_slot` | `date`, `startAt`, `endAt`, `label?` |
| `update_free_slot` | `id`, `startAt?`, `endAt?`, `label?` |
| `delete_free_slot` | `id` |
| `assign_task` | `slotId`, `taskId`, `startAt`, `endAt`, `memo?` |
| `update_assignment` | `id`, `startAt?`, `endAt?`, `sortOrder?`, `memo?` |
| `unassign` | `id` |
| `copy_daily_plan` | `fromDate`, `toDate`, `replaceExisting?` |
| `weekly_report` | `weekStart` |
| `export_data` | — |
| `undo_last_write` | — |
| `sync_status` | — |
| `import_file` | `path` |
| `purge_tombstones` | — |
| `forget_device` | `deviceId` |
| `rotate_token` | `deviceId` |
| `list_conflicts` | `status?`(`open`/`resolved`/`all`), `entityType?`, `limit?` |
| `get_conflict` | `id` |
| `resolve_conflict` | `id`, `adopt`(`hub`/`device`/`current`) |
| `resolve_all_conflicts` | `adopt`, `entityType?`, `dryRun?` |

## 4. エンティティ × 操作マトリクス

✔ = ツールあり / ✘ = 監査時点で欠落（→ 追加したツール名）/ — = モデル上意味を持たない

| エンティティ | create | list | get | update(部分) | delete | reorder | bulk | 特殊 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| task | ✔ `add_task` | ✔ `list_tasks` | ✘ → `get_task` | ✔ `update_task` | ✔ `delete_task` | ✘ → `reorder_tasks` | ✔ `bulk_add_tasks` / ✘ → `bulk_update_tasks`, `bulk_delete_tasks` | 完了フラグ無し（—） |
| category | ✔ `add_category` | ✔ `list_categories` | ✔ `list_categories` / `get_entity` | ✔ `update_category`（可変項目は `name` のみ） | ✔ `delete_category` | —（`name` 昇順固定） | — | 統合: ✘ → `merge_categories` |
| settings | — | ✘ → `get_settings` | ✘ → `get_settings` | ✘ → `set_share_categories` | — | — | — | 共有 ON/OFF のマージ戦略 |
| plan | ✘（`add_free_slot` の副作用のみ）→ `create_daily_plan` | ✔ `list_daily_plans` | ✔ `get_daily_plan` | ✘ → `move_daily_plan`（`date` が唯一の可変項目） | ✘ → `delete_daily_plan` | — | — | ✔ `copy_daily_plan`（前後どちらの日付へもコピー可） |
| free slot | ✔ `add_free_slot` | ✔ `get_daily_plan` | ✔ `get_daily_plan` / `get_entity` | ✔ `update_free_slot` | ✔ `delete_free_slot` | —（`startAt` 昇順固定） | — | — |
| assignment | ✔ `assign_task` | ✔ `get_daily_plan` | ✔ `get_daily_plan` / `get_entity` | ✔ `update_assignment` | ✔ `unassign` | ✘ → `move_assignment`（枠内位置指定＝並べ替え） | — | 別枠・別日への移動: ✘ → `move_assignment` |
| document | — | — | ✔ `export_data` | ✔ `import_file` / ✘ → `import_data`（インライン JSON） | — | — | — | ✔ `undo_last_write`, `purge_tombstones` |
| device | — | ✔ `sync_status` | ✔ `sync_status` | ✔ `rotate_token` | ✔ `forget_device` | — | — | — |
| conflict | —（マージが作る） | ✔ `list_conflicts` | ✔ `get_conflict` | ✔ `resolve_conflict` | ✔（解決 30 日後に自動墓標化） | — | ✔ `resolve_all_conflicts` | 採用は新しい clock の編集として書き戻る |

### 実装しなかったもの（理由つき）

- **`complete_task` / `uncomplete_task`**: モデルに完了の概念が無い。追加には
  Dart 側のスキーマ変更が必要なので実施せず。
- **`restore_deleted`（墓標の復元）**: 墓標は `id` と meta しか保持しない設計で、
  `title` などの本体データは削除時点で失われる。よって墓標からの復元は
  **原理的に不可能**。直前の書き込みに限り `undo_last_write`
  （`data.json.bak` 1 世代）で戻せる。
- **`reorder_free_slots`**: スロットに順序フィールドが無い（常に時刻順）。
- **`set_task_priority`**: `update_task` の `priority` で足りる。ただし
  `update_task` は 1..5 に制限されており、`reorder_tasks` は Dart と同じく
  「件数 - index」を書くため 5 を超える値を作ることがある（下記 §5 参照）。

## 5. 既存ツールの挙動チェック結果

| 観点 | 結果 |
| --- | --- |
| 部分更新（未指定フィールドは不変） | ✔ `update_task` / `update_free_slot` / `update_assignment` はいずれも未指定を保持。`memo`/`label` に空文字を渡す更新も `??` 判定なので通る |
| 削除は墓標か | ✔ `delete_*` / `unassign` はすべて `tomb()` で id + meta のみに置換。物理削除は `purge_tombstones` だけ |
| 書き込みは `store.update` 経由か | ✔ すべての変更が `HubTools.mutate` → `store.update`（ファイルロック＋`data.json.bak` 生成）を通る。よって全ツールが `undo_last_write` の対象 |
| 不変条件の検査 | ✔ `mutate` が書き込み前に `checkInvariants` を実行し、違反があれば例外にして書き込みを中止する。加えて `assertSlotFits` / `assertAssignmentFits` が重なり・枠外を個別に弾く |
| 不明な id | ✔ `... not found` の `ToolError` になり、クラッシュしない |
| タイムスタンプ | ✔ `iso()` が `Date.parse` → `toISOString()` で必ず UTC の `Z` に正規化する |
| `updatedAt` / `clock` の更新 | ✔ `stamp()` が毎回 HLC を進める。読み込み時に `observeAll` で既存の最大クロックを取り込むので、アプリが進めたクロックを追い越せる |
| ツール説明文 | △ 破壊的操作である旨は `delete_task`（"Delete (tombstone)"）などで概ね明示。`delete_free_slot` が割り当てごと消すこと、`delete_category` がタスクの分類を外すことも説明済み。新規ツールでも同じ水準を維持した |

### 見つかった不具合

1. **`update_task` で `kind` を変えても `categoryId` が検証されない**
   （修正済み）。共有 OFF のとき、`must_do` のタスクを `want_to_do` に変えると
   `categoryId` は must_do 側のカテゴリを指したまま残り、`list_categories` に
   出てこない id を参照する壊れた状態になった。Dart の
   `sanitizeTaskAgainstCategories` と同じく、**新しい kind のカテゴリに存在しない
   id は null にする**よう修正した。

2. **`update_assignment` の `sortOrder` はほぼ効かない**（仕様として文書化）。
   書き込み直後に `normalizeSlot` が `startAt`→`endAt`→`sortOrder` 順で再採番する
   ため、時刻が同じ場合以外は指定値が上書きされる。これは Dart 側と同じ挙動なので
   変更せず、枠内の並べ替えは新設の `move_assignment`
   （`beforeAssignmentId` 指定）で行う、と説明文に明記した。

3. **`checkInvariants` は参照整合性を検査しない**（意図的に据え置き）。
   削除済みカテゴリを指す `task.categoryId` や、存在しない `taskId` を指す
   assignment は違反として報告されない。`invariants.ts` は Dart の
   `InvariantChecker` と 1:1 対応で、共有フィクスチャ
   （`test/fixtures/sync_merge`）でも突き合わせているため、ここは変更していない。
   代わりに、参照を作る／壊す可能性のあるツール側
   （`update_task`, `merge_categories`, `bulk_update_tasks`, `move_assignment` 等）
   で個別に検証している。

## 6. 追加したツール（13 個）

追加後は上のマトリクスの ✘ がすべて解消し、意味を持つ操作はすべて ✔ になった
（`—` の欄はモデル上そもそも存在しない操作）。ツール数 26 → 39。

| ツール | 説明 |
| --- | --- |
| `get_task` | id でタスクを 1 件取得（`includeDeleted` で墓標も可） |
| `get_entity` | 種別を問わず id で 1 件取得。どのリストに属するかを併せて返す |
| `reorder_tasks` | 種別内の並び順を id 配列で丸ごと指定（Dart と同じく `priority` を書き換える） |
| `bulk_update_tasks` | 複数タスクの部分更新を 1 回の書き込みで適用（全件成功か全件失敗） |
| `bulk_delete_tasks` | 複数タスクをまとめて墓標化 |
| `merge_categories` | 同一 kind の 2 カテゴリを統合（参照タスクを付け替えて元を墓標化） |
| `get_settings` | `taskMaster.settings`（`shareCategories` と meta）を返す |
| `set_share_categories` | カテゴリ共有の ON/OFF。ON 時は Dart と同じマージ戦略で 2 リストを統合する |
| `create_daily_plan` | 指定日の計画を作る（既存ならそれを返す冪等操作） |
| `delete_daily_plan` | 計画とその枠・割り当てをまとめて墓標化する破壊的操作 |
| `move_daily_plan` | 計画の枠と割り当てを別日へ移し、元日を空にする（コピー＋元削除） |
| `move_assignment` | 割り当てを別の枠／別の日／同じ枠の別位置へ移動する |
| `import_data` | インライン JSON の v2 ドキュメントを取り込む（`import_file` のファイル無し版） |

## 6b. 競合の記録と解決（Plan 3b・4 個）

同じエンティティを PC とスマホの両方で編集していた場合、マージは HLC の勝者を
暫定採用して**同期そのものは完了させ**、敗者のスナップショットを
`document.conflicts[]` の競合レコードとして残す。この 4 個はそのレコードを
読み・選ぶための操作で、ツール数は 39 → 43 になった。

| ツール | 説明 |
| --- | --- |
| `list_conflicts` | 競合レコードを一覧する。`status` 既定は `open`。未解決／解決済みの総数と、日本語の 1 行ラベルを返す |
| `get_conflict` | 1 件の詳細。両版で**値が違うフィールドだけ**の差分と、いま `data.json` にある版（`clock` / `deletedAt` / 後続の編集に追い越されたか）を返す |
| `resolve_conflict` | `hub` 版・`device` 版・現状維持（`current`）のいずれかを選ぶ。採用側は**新しい clock の編集として書き戻す**ので、次の同期でスマホとブラウザにも伝播する。墓標を採用するとそのエンティティは再び削除される |
| `resolve_all_conflicts` | 破壊的。未解決の全件を同じ方針で 1 回の書き込みにまとめて適用する（全か無か）。`dryRun` は何も書かずに結果だけ返す |

- 解決は clock を巻き戻さない。`resolve_conflict` は必ず `clock.next()` を発行し、
  レコード側にも `resolution` / `resolvedAt` / `resolvedBy` と新しい clock を打つ。
- 既に解決済みのレコードへの `resolve_conflict` は `ToolError`（すでに解決済みです）。
  `adopt: 'current'` でも同じ。
- 採用したいスナップショットが既に生きている版と同じ内容なら `wrote: false` で、
  レコードだけが解決済みになる。
- 対象のエンティティが purge で消えている場合、書き込みを伴う採用は拒否する
  （`adopt: 'current'` なら閉じられる）。

## 7. 検証

- `npm test` — 26 ファイル / 320 件（監査前は 16 ファイル / 186 件、監査直後は 17 ファイル / 214 件）
- `npm run typecheck` — エラーなし
- `npm run build` — 成功
- `npm run smoke` — `SMOKE OK`。stdio の実プロトコルで
  カテゴリ作成 → タスク作成 → 並べ替え → 部分更新 → 計画作成 → 枠追加 → 割り当て →
  割り当て移動 → 解除 → 枠削除 → タスク削除（墓標を確認）→ `undo_last_write` →
  `export_data` → 競合の作成 → `list_conflicts` → `get_conflict` →
  `resolve_conflict`（スマホ版を採用）→ `purge_tombstones` の 24 時間マージンまでを
  一巡し、各段階で `checkInvariants` が空であることを確認する（ツール数 43 も検査する）
- `flutter test`（ワークツリー直下）— 319 件すべて成功。Dart 側と共有フィクスチャは変更していない
