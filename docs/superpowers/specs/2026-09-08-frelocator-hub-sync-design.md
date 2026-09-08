# FRELOCATOR Hub: PC 側 MCP 編集とサーバーレス端末間同期

作成日: 2026-09-08

## 目的

- PC（macOS）で Claude Code から MCP ツール経由で FRELOCATOR のデータ（タスク・カテゴリ・自由時間枠・割当・日次計画）を自由に追加・更新・削除できるようにする。
- スマホ（Android）と PC のデータを、第三者サーバーを経由せずに連携する。主経路は同一ネットワーク内の LAN 同期、ネットワークが一致しないときの副経路として QR 転送を用意する。
- ローカルファーストと「アプリ自身は外部サーバーに通信しない」というプライバシーポリシーの方針を維持する。

## 範囲外（v1）

- 差分転送・自動同期・バックグラウンド同期。
- iOS 対応（Android と macOS を対象にする）。
- launchd 常駐。ハブは Claude Code から MCP として起動している間だけ動く。
- 3 台以上の端末間の同期（PC 1 台とスマホ 1 台）。

## 構成

```
[Android FRELOCATOR] --LAN HTTP / QR--> [frelocator-hub (Node/TS)] <--file--> ~/Library/Application Support/FRELOCATOR/data.json <--file--> [macOS FRELOCATOR.app]
                                              ^ stdio MCP
                                        [Claude Code]
```

- `frelocator-hub`（新規、`tools/hub/` に TypeScript で作成、`@modelcontextprotocol/sdk` 使用）
  - MCP サーバー（stdio）。Claude Code の MCP 設定から `node tools/hub/dist/index.js` で起動する。
  - 起動と同時に LAN 向け HTTP（既定ポート 47820、0.0.0.0 バインド）を開く。プロセス終了で閉じる。
  - 正となる JSON ファイルを読み書きする唯一の書き手（macOS アプリと排他制御はファイルロック＋原子的リネームで行う）。
- macOS 版 FRELOCATOR.app: 保存先を shared_preferences から同じ JSON ファイルに切り替える。起動時と前面復帰時に再読み込みする。
- Android 版 FRELOCATOR: 保存先は従来どおり端末内。設定画面に「PC と同期」を追加する。

## データ形式（スキーマ v2）

`AppDataService.exportAll()` の形式を拡張する。

```json
{
  "version": 2,
  "exported_at": "2026-09-08T10:00:00+09:00",
  "device_id": "android-3f2a…",
  "task_master": { "tasks": [], "must_do_categories": [], "want_to_do_categories": [], "share_categories": [] },
  "daily_plan": { "plans": [], "slots": [], "assignments": [] }
}
```

全エンティティ（TaskMaster、TaskCategory、DailyPlan、FreeTimeSlot、SlotTaskAssignment）に次を追加する。

| フィールド | 型 | 意味 |
|---|---|---|
| `updatedAt` | ISO8601 | 最終更新時刻。既存の TaskMaster / DailyPlan は流用 |
| `updatedBy` | string | 更新した device_id（ハブは `hub`） |
| `deletedAt` | ISO8601 or null | 墓標。null 以外は削除済みとして UI に出さない |

- v1 → v2 マイグレーション: 読み込み時に `updatedAt` が無いものは `exported_at` か現在時刻、`updatedBy` は自端末、`deletedAt` は null を補う。
- 墓標は 90 日経過後に物理削除する（同期時にハブ側で掃除）。
- device_id は初回起動時に生成して端末に保存する。

## マージ規則（Dart と TS で同一実装）

1. 両側のエンティティを id で突き合わせる。
2. 片側にしか無い id はそのまま採用する。
3. 両側にある id は `updatedAt` が新しい方を採用する。同時刻なら `updatedBy` の辞書順で大きい方。
4. 墓標も通常の更新として扱う（削除の updatedAt が編集より新しければ削除が勝つ）。
5. 参照整合: 採用後に存在しないカテゴリを指すタスクは categoryId を null にする。存在しないスロットや日次計画を指す割当は墓標にする。
6. マージ結果は両側で同一になる（可換・冪等）。

テストは `test/fixtures/sync_merge_cases.json` に入力 A・入力 B・期待結果を並べ、Dart（`flutter test`）と TS（`vitest`）の両方が同じファイルを読んで検証する。

## LAN 同期プロトコル

- ペアリング: ハブの MCP ツール `sync_status` がペアリング用 URL `frelocator://pair?host=<LAN IP>&port=47820&token=<32 文字>` と、それを QR 化したローカルページ `http://localhost:47820/pair` を返す。スマホは設定画面の「PC とペアリング」でカメラから読み取り、host / port / token を端末に保存する。トークンはハブが初回起動時に生成し `~/Library/Application Support/FRELOCATOR/hub.json` に保持する。
- エンドポイント（すべて `Authorization: Bearer <token>` 必須、LAN 内のみ）
  - `GET /sync` → PC 側の全データ（v2 JSON）
  - `POST /sync` body: スマホ側の全データ → ハブがマージし、結果を JSON ファイルに保存してから同じ結果を返す
  - `GET /health` → `{ ok: true, deviceId, updatedAt }`
- スマホの「同期」ボタン 1 回で `POST /sync` → 返ってきた結果で自分を置き換える、まで行う。1 往復で双方向が完了する。
- ハブが見つからない（タイムアウト 3 秒）場合は「同じ Wi-Fi に接続されているか確認するか、QR で連携してください」と案内し、QR 画面へのボタンを出す。
- TLS は使わない。LAN 外からは到達せず、トークンで他端末からの誤接続を防ぐ。
- 転送層は `SyncTransport` インターフェースで抽象化し、Play のデータセーフティで転送暗号化を求められた場合にトークン由来鍵の AES-256-GCM（ペイロード暗号化）を差し込めるようにする。v1 では平文 JSON。

## QR 転送（ネットワークが一致しないときの副経路）

- ペイロード: v2 JSON を gzip → base64。1,200 文字ごとに分割し、各コマに `FRL1|<全体 hash 先頭 8 文字>|<index>/<total>|<chunk>` を載せる。
- PC → スマホ: ハブの `http://localhost:47820/qr` が全コマを 250ms 間隔で繰り返し表示する。スマホは「QR で受け取る」でカメラを向け続け、全コマが揃ったら復元してマージする。
- スマホ → PC: スマホの「QR で送る」が同じ形式でアニメーション表示する。macOS 版アプリの「QR で受け取る」がカメラで読み取り、JSON ファイルにマージして保存する。
- 受信側は index の集合を持ち、揃っていないコマだけを待つ（表示側は繰り返しているので順不同で回収できる）。
- 目安: タスク 300 件で約 40KB → gzip 後 8KB 程度 → 7 コマ。100 コマを超える場合は警告を出す。

## 進捗と待ち状態の可視化（LAN・QR 共通）

時間がかかる処理は必ず画面で状態が分かるようにする。

- LAN 同期: ボタン押下直後にモーダルの進捗パネルを出し、「接続中 → 送信中（バイト数）→ PC でマージ中 → 受信中 → 保存中 → 完了」の段階をテキストとインジケータで表示する。各段階に経過秒数を出し、10 秒を超えたら「時間がかかっています」と補足する。キャンセル可能。
- QR 受信: 「n / total コマ受信」の数値と、コマごとの受信済みマスを並べたグリッドを表示する。未受信のコマ番号が分かるので、表示側で該当コマが来るまで待てばよいと分かる。全コマ揃うと「復元中 → マージ中 → 保存中」を表示する。
- QR 表示: 「コマ i / total を表示中」と、受信側に伝えるための総コマ数と目安時間を表示する。
- macOS 版アプリのファイル再読み込み: 再読み込み中はヘッダーに小さなスピナーを出す。
- ハブの MCP 側: `sync_status` に直近の同期の段階と経過時間を含め、Claude 側からも進捗を確認できるようにする。
- 完了時は SnackBar に「追加 n / 更新 n / 削除 n」を出し、何が起きたか分かるようにする。失敗時は原因（未接続、トークン不一致、JSON 破損）を文言で区別する。

## MCP ツール一覧

| ツール | 引数 | 動作 |
|---|---|---|
| `list_tasks` | kind?, categoryId?, query? | 墓標を除いたタスク一覧 |
| `add_task` | title, kind, priority?, categoryId?, estimatedMinutes?, memo? | id を採番して追加 |
| `update_task` | id, 変更フィールド | updatedAt / updatedBy を更新 |
| `delete_task` | id | 墓標化 |
| `list_categories` / `add_category` / `update_category` / `delete_category` | kind, name 等 | 同上。同名は拒否 |
| `get_daily_plan` | date | 日次計画・枠・割当をまとめて返す |
| `add_free_slot` / `update_free_slot` / `delete_free_slot` | date, startAt, endAt, label | 枠の CRUD。plan が無ければ作成 |
| `assign_task` / `update_assignment` / `unassign` | slotId, taskId, startAt, endAt, sortOrder | 割当の CRUD。枠外の時刻は拒否 |
| `copy_daily_plan` | fromDate, toDate | 既存アプリの「別日に複製」と同じ規則 |
| `weekly_report` | weekStart | 週の時間配分集計（読み取り専用） |
| `sync_status` | なし | LAN 待ち受け先、ペアリング QR の URL、直近同期の段階・時刻・結果 |

- すべての書き込みはファイルロックを取り、v2 JSON を原子的に書き換える。
- バリデーションはアプリ側のコントローラと同じ規則（空タイトル拒否、枠の時刻逆転拒否、同名カテゴリ拒否）を TS で再実装する。

## アプリ側の変更（Flutter）

- `lib/services/sync/`: `SyncMerger`（マージ規則）、`LanSyncClient`（http）、`QrChunkCodec`（分割・復元）、`SyncProgress`（段階と経過時間の状態）。
- `lib/features/settings/`: 「PC と同期」画面。ペアリング、同期、QR で受け取る、QR で送る、進捗パネル。
- 保存層: `TaskMasterRepository` / `DailyPlanRepository` に v2 マイグレーションと墓標フィルタを追加。macOS では保存先を JSON ファイルにする `FileBackedStore` を追加し、`kIsWeb` と `Platform.isMacOS` で切り替える。
- 依存追加: `http`、`mobile_scanner`、`qr_flutter`、`archive`、`path_provider`、`uuid`。
- `web/privacy.html` に「同一ネットワーク内のユーザー自身の PC とのみ通信し、運営者を含む第三者のサーバーには送信しない」を追記する。Play のデータセーフティは「収集なし」のままで整合する。

## エラー処理

- LAN: 接続失敗、401（トークン不一致）、JSON 破損、スキーマ version 不一致をそれぞれ別文言で表示し、QR への誘導を出す。
- QR: hash 不一致のコマは捨てる。別データの QR を途中で読んだ場合は「別のデータです。最初からやり直しますか」と確認する。
- ハブ: JSON 破損時は `.broken-<timestamp>` に退避して空データで起動し、MCP の応答に警告を含める。書き込み前に `.bak` を 1 世代残す。

## テスト

- マージ規則: 共通フィクスチャを Dart / TS 両方で実行（追加のみ、片側削除、同時刻同点、参照切れ、墓標の掃除）。
- QrChunkCodec: 分割 → 順不同で復元、欠落コマ検出、hash 不一致の破棄。
- ハブ: MCP ツールごとのユニットテスト、`/sync` 往復で両端が同一になることの確認、ファイルロック競合。
- 手動: Pixel_8 エミュレーター（ハブは `10.0.2.2`）と実機で LAN 同期と QR 双方向を 1 回ずつ。進捗パネルの各段階が表示されることを目視確認。

## 段階的な実装順

1. スキーマ v2 とマージ規則（Dart / TS）＋共通フィクスチャ。
2. ハブの MCP ツールと JSON ファイル書き込み。macOS 版のファイル読み書き切り替え。
3. LAN 同期（ハブ側エンドポイント、アプリ側クライアントと進捗パネル、ペアリング QR）。
4. QR 転送（コーデック、PC 表示ページ、スマホの送受信画面、macOS のカメラ受信）。
5. プライバシーポリシー追記、ドキュメント、Play 向けリリース。
