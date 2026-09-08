# FRELOCATOR Hub: PC 側 MCP 編集とサーバーレス端末間同期

作成日: 2026-09-08 / 改訂: 2026-09-08（Opus と Fable による設計レビューを反映。末尾「レビュー反映」参照）

## 目的

- PC（macOS）で Claude Code から MCP ツール経由で FRELOCATOR のデータ（タスク・カテゴリ・自由時間枠・割当・日次計画）を追加・更新・削除できるようにする。
- スマホ（Android）と PC のデータを、第三者サーバーを経由せずに連携する。主経路は同一ネットワーク内の LAN 同期、ネットワークが一致しないときの副経路として PC→スマホの QR 転送とスマホ→PC のファイル持ち込みを用意する。
- ローカルファーストの方針を維持する。アプリ自身が通信する相手はユーザー自身の PC に限定し、運営者を含む第三者のサーバーには送信しない。ユーザーが共有シートで明示的に選んだ送付先（Nearby Share、USB 転送など）はアプリの通信には含めない。

## 範囲外（v1）

- 差分転送・自動同期・バックグラウンド同期（プロトコルに `since` は予約するだけ）。
- iOS 対応。
- launchd 常駐。ハブは Claude Code から MCP として起動している間だけ動く。
- 3 台以上の端末での動作保証（端末管理の機能自体は複数端末前提で持つが、動作確認は PC 1 台とスマホ 1 台）。
- macOS 版アプリのカメラによる QR 読み取り（スマホ→PC はファイル持ち込みで代替）。

## 構成

```
[Android FRELOCATOR] --LAN HTTPS / QR(PC→スマホ) / 共有シート(スマホ→PC)--> [frelocator-hub (Node/TS)]
                                                                                   |  file lock
                                                          ~/Library/Application Support/FRELOCATOR/data.json
                                                                                   |
[Claude Code] --stdio MCP--> [frelocator-hub]                            [macOS FRELOCATOR.app]
```

- `frelocator-hub`（新規、`tools/hub/`、TypeScript、`@modelcontextprotocol/sdk`）
  - MCP サーバー（stdio）。起動と同時に LAN 向け HTTPS（既定 47820、0.0.0.0）と、ローカル専用 HTTP（127.0.0.1:47821、ペアリング QR とデータ QR の表示ページ）を開く。プロセス終了で閉じる。
  - 正となる JSON ファイルを読み書きする。macOS アプリとはファイルロックで排他する。
- macOS 版 FRELOCATOR.app: 保存先を同じ JSON ファイルに切り替える。サンドボックスは無効のまま配布する（App Store 配布は範囲外。将来必要になれば security-scoped bookmark で同じパスを指す）。
- Android 版 FRELOCATOR: 保存先は従来どおり端末内。設定画面に「PC と同期」を追加する。

## データ形式（スキーマ v2）

`AppDataService.exportAll()` の形式を拡張する。キー名は実装に合わせて camelCase。

```json
{
  "version": 2,
  "exportedAt": "2026-09-08T01:00:00.000Z",
  "deviceId": "android-3f2a…",
  "lastSyncAt": "2026-09-08T00:55:00.000Z",
  "taskMaster": { "tasks": [], "mustDoCategories": [], "wantToDoCategories": [], "settings": { "shareCategories": false, "clock": "…" } },
  "dailyPlan": { "plans": [], "slots": [], "assignments": [] }
}
```

全エンティティ（TaskMaster、TaskCategory、DailyPlan、FreeTimeSlot、SlotTaskAssignment、および `taskMaster.settings`）に次を追加する。

| フィールド | 型 | 意味 |
|---|---|---|
| `clock` | string `"<utcMillis>-<counter>-<deviceId>"` | ハイブリッド論理クロック（HLC）。勝敗判定に使う |
| `updatedAt` | ISO8601 UTC（末尾 `Z`） | 表示用の最終更新時刻。判定には使わない |
| `deletedAt` | ISO8601 UTC or null | 墓標。null 以外は削除済みとして UI に出さない |
| `migrated` | bool | v1 からの補完で付けた値なら true |

- 全タイムスタンプは UTC で保存する。`DailyPlan.date` は `YYYY-MM-DD` 文字列にする。
- HLC: 端末は `lastClock` を保持し、書き込み時に `max(now, lastClock.physical)` を physical、同じ physical なら counter+1、を発行する。受信した相手の clock が自分より進んでいれば `lastClock` を引き上げる。比較は physical → counter → deviceId の順。同一端末内で単調増加が保証されるので、時計が戻っても後の編集が負けない。
- v1 → v2 マイグレーション: `clock` が無いものは `0-0-migrated`、`updatedAt` は `1970-01-01T00:00:00.000Z`、`migrated: true`、`deletedAt: null` を補う。両側が `migrated` のエンティティは内容ハッシュが一致すれば「変更なし」として扱い、不一致なら deviceId の辞書順で決める（既定カテゴリの初回同期で無根拠な勝敗を作らない）。
- 未知のキーは `extra` に保持して書き戻す（将来の v3 フィールドを v2 端末が消さない）。
- 同期時のパースは厳格にする。1 件でも壊れていれば同期を中止し、通常起動時のみ従来どおりスキップする。

## 削除とゴミ掃除

- 削除はすべて墓標化する。現行の物理削除（task_master_controller の deleteTask、daily_plan_controller の deleteSlot / unassign / copyDailyPlan の replaceExisting / deletePlan）を全て `deletedAt` 付与に書き換え、Repository の読み出しで墓標を除外する。
- 墓標の物理削除（purge）はハブだけが行う。ハブは既知端末ごとの `lastSyncAt` を持ち、`min(全端末の lastSyncAt)` より古い墓標だけを消す。消した時刻を `purgedBefore` としてファイルと `/sync` の応答に含める。紛失した端末や使わなくなった端末は `forget_device(deviceId)` で既知端末から外し、purge が止まらないようにする。ペアリング直後の端末は `lastSyncAt` をペアリング時刻で初期化し、初回同期は `purgedBefore` 判定を免除する（実データを持つ新しいスマホの初回同期が置き換えフローに落ちない）。
- クライアントは `自分の lastSyncAt < purgedBefore` なら通常マージを行わず、「PC の状態で置き換える」か「自分の状態で PC を置き換える」をユーザーに選ばせる（長期オフライン端末からの復活を防ぐ）。
- `purge_tombstones` は MCP ツールとして明示実行もできる。

## マージ規則（Dart と TS で同一実装）

1. 両側のエンティティを id で突き合わせる。
2. 片側にしか無い id はそのまま採用する（相手の `purgedBefore` より古い墓標由来の欠落は上記の置き換えフローで扱う）。
3. 両側にある id は `clock` が大きい方を採用する。`clock` が同値（実質的に移行由来同士のみ）の場合は内容ハッシュが一致すれば変更なし、不一致なら内容ハッシュの辞書順で大きい方を採用する（両側で同じ結果になる決定的規則）。
4. 墓標も通常の更新として扱う（削除の clock が編集より大きければ削除が勝つ）。
5. 参照整合は非破壊。存在しないカテゴリを指すタスクは保存データを変えず、表示層で「未分類」扱いにする。存在しない枠や日次計画を指す割当は表示層で非表示にし、保存データは保持する（後から枠が届けば復元される）。
6. マージ結果は両側で同一になる（可換・冪等）。property test で検証する。
7. `copyDailyPlan` は決定的 id（`sha256(sourcePlanId + targetDate + sourceEntityId + generation)` の先頭 16 文字）を使い、両端末で同じ複製をしても二重化しない。`generation` は対象日の plan が持つ複製世代カウンタで、墓標を含めて同じ id が既に存在するときに +1 する（複製→削除→再複製で墓標と衝突しない）。
8. マージ後に不変条件チェッカ（枠内の割当、割当の重なり無し、sortOrder 連番、同名カテゴリ無し）を通し、違反はマージ結果に含めず警告として返す。

テストは `test/fixtures/sync_merge/` にケース単位の JSON（`入力 A`、`入力 B`、`期待結果`）とマニフェストを置き、Dart（`flutter test`）と TS（`vitest`）の両方が同じファイルを読んで検証する。

## LAN 同期プロトコル

- 通信は HTTPS。ハブは初回起動時に自己署名証明書（10 年）を生成し `hub.json` に保持する。証明書の SHA-256 フィンガープリントをペアリング QR に載せ、スマホは以後そのフィンガープリントだけを信頼する（ピン留め）。cleartext 許可は行わない。
- ペアリング: MCP ツール `sync_status` がローカル専用ページ `http://127.0.0.1:47821/pair` を返す。ページは `frelocator://pair?host=<LAN IP>&port=47820&fp=<sha256>&code=<短命コード>` を QR 表示する。短命コードは 5 分・1 回限り。スマホが `POST /pair` に code と自分の deviceId を送ると、ハブが端末別の長期トークンを返す。トークンは `hub.json` に端末ごとに保存し、`rotate_token` ツールで失効・再発行できる。スマホ側は端末トークンとフィンガープリントを `shared_preferences`（アプリのサンドボックス内、端末内のみ）に平文で保存する。OS のキーチェーンは使わない: 盗まれても影響は同じ LAN 上のハブに限られ、そのハブは `rotate_token` / `forget_device` でいつでも失効できるため、追加依存に見合わない。アプリ側で「PC と同期」をペアリング解除すると、この端末トークンと保存済みフィンガープリントは `shared_preferences` から削除する。
- エンドポイント（`/pair` 以外は `Authorization: Bearer <端末トークン>` 必須）
  - `POST /pair` → `{ token, hubDeviceId, fingerprint }`
  - `GET /sync` → `{ document, hubDeviceId }`（`document` は PC 側の全データ v2 JSON、`purgedBefore` 付き）
  - `POST /sync?mode=merge|take_hub|take_phone`（既定 `merge`）body: スマホ側の全データ → ハブがマージ／置き換えし、ファイルに保存してから `{ document, summary, warnings }` を返す。`summary` は `{ added, updated, deleted, removed, warnings }`。`take_hub` は PC 側をそのまま返し、`take_phone` は受信文書をそのまま保存する（いずれも相手側の未反映の変更を破棄する）。`version < 2` は 426 で拒否しアプリ更新を促す
  - `GET /health`（HEAD も可）→ `{ ok: true, hubDeviceId, fingerprint, version, schema, serverTime }`
  - エラーは共通で `{ error: { code, message } }`。401（トークン不正）・403（ペアリング失敗／期限切れ／試行回数超過）・409 `purged_before`（`merge` で自分の `lastSyncAt` より新しく purge が進んでいる）・413（`/pair` 8KB・`/sync` 20MB 超過、`Connection: close` 付き）・426（スキーマ古すぎ）。
- リプレイ対策は TLS と端末別トークンに委ねる（nonce は持たない）。
- 接続先の解決順: 保存済み host → mDNS（`_frelocator._tcp`、ハブが広告）→ ペアリングし直し。
- スマホの「同期」ボタン 1 回で `POST /sync` → 返ってきた結果で自分を置き換える、まで行う。
- ハブが見つからない（タイムアウト 3 秒）場合は「同じ Wi-Fi に接続されているか確認するか、QR で連携してください」と案内し、QR 画面へのボタンを出す。
- エミュレーター: Android エミュレーターからは `10.0.2.2:47820` に接続する。設定画面に host を手入力できる欄を置く。

## ネットワーク不一致時の副経路

PC → スマホ（QR）
- ペイロード: v2 JSON を gzip → base45。1 コマ 600 文字、誤り訂正レベル M。各コマは `FRL2:<全体 SHA-256 先頭 16 文字（大文字 hex）>:<index>:<total>:<CRC32（大文字 hex）>:<chunk>` とし、区切りの `:` を含めて全文字を QR 英数モードの文字集合（0-9 A-Z 空白 $%*+-./:）に収める。1 文字でも外れるとバイトモードに落ちて容量が約 1.5 倍悪化するため、エンコーダはフレーム生成後に文字集合検査を行う。
- ハブのローカルページ `http://127.0.0.1:47821/qr` が全コマを繰り返し表示する。表示間隔は既定 400ms でスライダーで変更できる。
- スマホの「QR で受け取る」がカメラを向け続け、全コマが揃ったら復元してマージする。コマ単位の crc32 不一致は捨て、全体 hash が途中で変わったら「別のデータです。最初からやり直しますか」と確認する。
- 目安: タスク 300 件で約 8KB（gzip 後）→ 約 14 コマ。80 コマを超える場合は警告し、LAN 同期を勧める。

スマホ → PC（ファイル持ち込み）
- スマホの「PC へ書き出す」が v2 JSON をファイルとして共有シートに渡す。画面では Nearby Share や USB 転送など第三者サーバーを経由しない手段を推奨し、「共有先はご自身で選んだものであり、アプリは送信しません」と明示する。
- Mac 側は MCP ツール `import_file(path)` か、macOS 版アプリの「ファイルから取り込む」で読み込み、同じマージ規則（`mode=merge` 相当）で JSON ファイルに反映する。ファイルの `deviceId` が未登録の端末なら、その場でペアリング登録される（現在発行中のペアリングコードを消費する）。

## 進捗と待ち状態の可視化（LAN・QR・ファイル共通）

- 表示する段階は実測できるものに限る。LAN 同期は「接続中 → 送信中（送信バイト / 総バイト）→ PC で処理中（不確定インジケータ）→ 受信中（受信バイト）→ 保存中 → 完了」。各段階に経過秒数を出し、10 秒を超えたら「時間がかかっています」と補足する。
- キャンセル: 送信完了前なら何も変わらない。送信完了後はハブ側が保存済みの可能性があるため「PC は更新済みの可能性があります。この端末への反映だけ中止しました」と表示する。ローカルの原子的書き込みに入った後はキャンセルできない。
- QR 受信: 「n / total コマ受信」の数値と、コマごとの受信済みマスのグリッド。未受信のコマ番号が分かる。全コマ揃うと「復元中 → マージ中 → 保存中」。
- QR 表示（ハブページ）: 「コマ i / total」、総コマ数、目安時間、表示間隔スライダー。
- ファイル取り込み: 読み込み → 検証 → マージ → 保存の段階と件数。
- macOS 版の再読み込み中はヘッダーにスピナー。編集ダイアログを開いている間は再読み込みを遅延し、閉じたときに同じマージ規則で取り込む。
- `sync_status` に直近の同期の段階・経過時間・結果を含め、Claude 側からも進捗を確認できる。
- 完了時は「追加 n / 更新 n / 削除 n / 消去 n / 警告 n」を表示する（`消去` はハブが墓標ごと捨てた件数 = `summary.removed`。`削除` は墓標として残る件数）。失敗時は未接続、証明書不一致、トークン無効、JSON 破損、バージョン不一致、purge 後の長期オフライン、を別文言で表示する。

## ファイル所有と並行制御（macOS）

- 書き込みは同一ディレクトリ内の一時ファイルに書いて `rename()` する（同一ボリューム内で原子的）。書き込み前に `data.json.bak` を 1 世代残す。
- ハブと macOS アプリの両方が `proper-lockfile` 互換の mkdir センチネル方式でロックする（`<dir>/data.lock.lock` を排他的に `mkdir` し、保持中はハートビートで mtime を更新、10 秒間更新が無ければ stale とみなして奪取し、解放時に `rmdir` する）。Node 側は `proper-lockfile` パッケージがこの方式を実装しており、fcntl などの POSIX advisory lock は使わない。Dart 側もこの mkdir センチネル方式をネイティブに実装し、両者が確実に排他制御される。読み出し時に mtime とサイズを記録し、書き込み直前に再検査して変わっていれば再読み込みしてマージし直す。
- JSON 破損時は `data.json.broken-<timestamp>` に退避して空データで起動し、MCP の応答と macOS アプリの画面に警告を出す。
- Release ビルドは entitlements でサンドボックスを無効化しているため、Mac App Store 配布は対象外（App Store 配布には別途サンドボックス対応が必要）。

## MCP ツール一覧

| ツール | 引数 | 動作 |
|---|---|---|
| `list_tasks` | kind?, categoryId?, query? | 墓標を除いたタスク一覧 |
| `add_task` / `bulk_add_tasks` | title, kind, priority?, categoryId?, estimatedMinutes?, memo?（bulk は配列） | id を採番して追加 |
| `update_task` | id, 変更フィールド | clock / updatedAt を更新 |
| `delete_task` | id | 墓標化 |
| `list_categories` / `add_category` / `update_category` / `delete_category` | kind, name 等 | 同上。同名は拒否 |
| `list_daily_plans` | from, to | 期間内の日次計画の一覧 |
| `get_daily_plan` | date（`YYYY-MM-DD`、ハブのローカル日） | 日次計画・枠・割当をまとめて返す |
| `add_free_slot` / `update_free_slot` / `delete_free_slot` | date, startAt, endAt, label | 枠の CRUD。plan が無ければ作成 |
| `assign_task` / `update_assignment` / `unassign` | slotId, taskId, startAt, endAt, sortOrder | 割当の CRUD。不変条件チェッカを通す |
| `copy_daily_plan` | fromDate, toDate, replaceExisting | 決定的 id で複製 |
| `weekly_report` | weekStart | 週の時間配分集計（読み取り専用） |
| `export_data` / `import_file` | path | v2 JSON の書き出し / 取り込み（マージ） |
| `undo_last_write` | なし | `.bak` を復元（1 世代） |
| `purge_tombstones` / `rotate_token` / `forget_device` | なし / deviceId / deviceId | 明示的な掃除 / トークン失効と再発行 / 既知端末からの除外 |
| `sync_status` | なし | LAN 待ち受け先、ペアリングページ URL、既知端末と lastSyncAt、直近同期の段階・結果 |

- id は Dart と同じ `<prefix>-<microsSinceEpoch>-<deviceId 先頭 4 文字>-<6 hex>` にする（Dart 側も device 成分を追加）。
- 書き込みはすべてファイルロックを取り、不変条件チェッカを通してから原子的に書き換える。バリデーション規則は JSON で記述し、マージ規則と同様に Dart / TS の両方で同じ規則を実行する。
- 時刻の基準: MCP の `date` 引数はハブのローカル日として解釈し、保存は UTC。

## アプリ側の変更（Flutter）

- `lib/core/hlc.dart`、`lib/core/id_generator.dart`（device 成分追加）。
- `lib/services/sync/`: `SyncMerger`、`InvariantChecker`、`LanSyncClient`（http、証明書ピン留め）、`QrChunkCodec`（base45・crc32）、`SyncProgress`、`FileExporter`。
- `lib/features/settings/`: 「PC と同期」画面。ペアリング（QR 読み取り）、同期、QR で受け取る、PC へ書き出す、host 手入力、進捗パネル。
- 保存層: v2 マイグレーション、墓標化、`extra` 保持、厳格パース。macOS は `FileBackedStore` に切り替え、ロックと再検査を実装。
- 依存追加: `http`（証明書ピン留めは `dart:io` の `HttpClient.badCertificateCallback` で SHA-256 を照合し `IOClient` で包む）、`mobile_scanner`、`qr_flutter`、`archive`、`path_provider`、`share_plus`、`file_picker`、`crypto`、`multicast_dns`。
- Android: `INTERNET` と `CAMERA` 権限を追加。カメラは初回に用途（QR 読み取り）を説明してから要求する。cleartext 設定は追加しない。
- `web/privacy.html`: 「ネットワーク通信をしない」「クラウド同期なし」の既存文を削除し、「アプリは同一ネットワーク内のユーザー自身の PC とのみ通信し、運営者を含む第三者のサーバーには送信しない。通信は暗号化される。ユーザーが共有機能で選んだ送付先はユーザー自身の管理下にある」に書き換える。Play のデータセーフティは「収集なし」を維持し、提出時に質問票を再確認する。

## テスト

- マージ規則: ケース単位フィクスチャを Dart / TS 両方で実行。追加のみ、片側削除、同 clock、時計逆行、移行由来同士（ハッシュ一致・不一致）、purge 後の長期オフライン端末、参照切れの往復、copyDailyPlan 後の同期、v1 クライアント拒否。
- property test: ランダム操作列を A / B に適用し、任意順で 3 回同期して両端が収束することを検証（Dart / TS 双方）。
- QrChunkCodec: 分割 → 順不同で復元、欠落コマ検出、crc32 不一致の破棄、hash 変化の検出、80 コマ超の警告。
- ハブ: MCP ツールごとのユニットテスト、`/sync` 往復で両端が同一になること、ロック競合（macOS アプリ書き込み中の `POST /sync`）、破損 JSON からの復旧、`undo_last_write`。
- 手動: Pixel_8 エミュレーター（`10.0.2.2`）と実機で LAN 同期、QR 受信、ファイル書き出し→`import_file` を 1 回ずつ。進捗パネルの各段階が表示されることを目視確認。

## 段階的な実装順

1. スキーマ v2、HLC、墓標化、マージ規則とチェッカ（Dart / TS）＋共通フィクスチャと property test。
2. ハブの MCP ツールとファイル書き込み（ロック・bak・undo）。macOS 版のファイル読み書き切り替え。
3. LAN 同期（自己署名 TLS、ペアリング、端末トークン、mDNS、アプリ側クライアントと進捗パネル）。
4. PC→スマホ QR とスマホ→PC ファイル持ち込み。
5. プライバシーポリシー書き換え、権限追加、ドキュメント、Play 向けリリース。

## レビュー反映（2026-09-08、Opus と Fable、二次パス含む）

採用した指摘
- 削除の墓標化を全経路に拡大し、purge を「既知端末の lastSyncAt の最小値」基準に変更。長期オフライン端末は置き換えフローに落とす。
- 勝敗判定を updatedAt から HLC に変更。v1 移行由来の値は決定的にし、内容ハッシュで同一判定。
- 参照整合を非破壊（表示層で吸収）に変更。copyDailyPlan は決定的 id。
- LAN を v1 から自己署名 TLS＋フィンガープリントのピン留めにし、cleartext 設定を排除。ペアリングは短命コード→端末別トークン。ペアリング / QR ページは 127.0.0.1 限定。
- スマホ→PC の QR は廃止し、ファイル持ち込み（`import_file`）に置き換え。QR は base45・600 文字・crc32 付きに変更。
- 進捗は実測できる段階のみ表示。キャンセルの意味を明記。
- v1 クライアントの同期を拒否。未知キーは保持。同期時は厳格パース。
- MCP ツールに bulk_add、list_daily_plans、export/import、undo、purge、rotate を追加。id に device 成分を追加。不変条件チェッカを導入。
- プライバシーポリシーは追記ではなく既存文の書き換え。CAMERA / INTERNET 権限を明記。

不採用または修正した指摘
- 「mobile_scanner は macOS 非対応」は誤り（7.4.0 で macOS 対応）。ただし Mac 内蔵カメラにスマホをかざす運用が現実的でない点は同意し、スマホ→PC はファイル持ち込みにした。macOS のカメラ受信は範囲外として残す。
- `/sync` のジョブ化（POST → jobId → GET）は v1 では見送り。「PC で処理中」を不確定インジケータで出すことで足りる。

二次パスで追加した修正
- 「第三者サーバーを経由しない」の主語を「アプリ自身の通信」に限定し、共有シートの送付先はユーザー管理下と明記。画面でも Nearby Share / USB を推奨。
- QR フレームを英数モードの文字集合に収める形式に変更し、エンコーダに文字集合検査を追加。
- マージ規則 3 に clock 同値時の決定的な勝敗（内容ハッシュ）を明記。
- purge の停滞対策として `forget_device` を追加し、ペアリング直後の端末は初回同期で `purgedBefore` 判定を免除。
- copyDailyPlan の決定的 id に世代カウンタを追加し、墓標との衝突を回避。
- nonce は撤回し、リプレイ対策は TLS と端末別トークンに一本化。
- 範囲外を「3 台以上の動作保証」に緩め、端末管理機能は複数端末前提のままとする。
- 証明書ピン留めの実装手段（`HttpClient.badCertificateCallback` + `IOClient`）を依存欄に明記。

