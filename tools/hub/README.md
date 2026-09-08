# frelocator-hub

FRELOCATOR の macOS 版と同じ `data.json` を編集する MCP サーバー（Node 22 / TypeScript）。

## 使い方

- ビルド: `npm install && npm run build`
- Claude Code: リポジトリ直下の `.mcp.json` が `node tools/hub/dist/index.js` を登録する。
- 単体起動: `npm start`（stdio でのみ話す。ログは stderr へ）。

## データ

- 既定の保存先は `~/Library/Application Support/FRELOCATOR/data.json`。`FRELOCATOR_DATA_DIR` でディレクトリを変更できる。
- 端末 id は `hub-<FRELOCATOR_HUB_ID>`（既定は `hub-macos`）。同じマシンで複数のハブを動かすときだけ変える。
- 書き込みごとに `data.json.bak` を 1 世代残し、`undo_last_write` で直前の書き込みに戻せる。
- 壊れたファイルは `data.json.broken-<timestamp>` に退避して空データで起動する（`sync_status` の `warning` に出る）。
- ロックは `data.lock` の `proper-lockfile` 互換プロトコル（mkdir センチネル、stale 10 秒）で、macOS 版アプリの `FileBackedStore` と共有する。アプリとハブが同時に書いても壊れない。

## ツール

タスク・カテゴリ・日次計画の CRUD、`copy_daily_plan`、`weekly_report`、`export_data`、`undo_last_write`、`sync_status`、
`import_file` / `purge_tombstones` / `forget_device` / `rotate_token` の 26 個。
後半 4 個は LAN サーバー（後述）が起動できている場合だけ動く。`hub.json` が壊れていて LAN が無効なときは「LAN sync is not configured in this hub process」を返す。

日付引数（`date` / `from` / `to` / `weekStart` / `fromDate` / `toDate`）は `YYYY-MM-DD` で、ハブを動かしているマシンのローカルなカレンダー日を指す。`startAt` / `endAt` はオフセット付き ISO を受け取り、UTC ISO 文字列として保存する。

## LAN 同期（Plan 2a）

ハブ起動中は、スマホ（Plan 2b の FRELOCATOR アプリ）と同じ Wi-Fi 上で `data.json` を同期できる。MCP を止めるとこの機能も止まる。

### ペアリング

1. `sync_status` ツールが返す `lan.pairingPage`（既定 `http://127.0.0.1:47821/pair`）を PC のブラウザで開く（127.0.0.1 限定。LAN からはアクセスできない）。
2. ページに表示される QR をスマホの FRELOCATOR アプリで読み取る。コードは 5 分・1 回限りで、失敗が 10 回続くとそのコードはロックされる（ページを再読み込みすれば新しいコードが出る）。
3. 成功するとスマホは端末別の長期トークンを受け取り、以後 `Authorization: Bearer <token>` で `/sync` `/health` を呼ぶ。

### 同期モード

スマホの「同期」操作は `POST https://<LAN IP>:47820/sync?mode=merge|take_hub|take_phone` を呼ぶ。

- `merge`（既定）: PC とスマホ双方の変更を HLC ベースでマージする。通常はこれを使う。
- `take_hub`: PC 側のデータをそのまま正としてスマホに返す。**スマホ側の未同期の変更は失われる。**
- `take_phone`: スマホが送った文書をそのまま PC の `data.json` として保存する。**PC 側の変更（他端末からの分も含む）は失われる。**

`purge_tombstones` 実行後に一度も同期していない端末が `merge` しようとすると `409 purged_before` で拒否される（下記）。その場合は `take_hub` か `take_phone` を選ぶ必要がある。

### QR でスマホにデータを送る（PC → スマホ）

- `sync_status` の `lan.qrPage`（既定 `http://127.0.0.1:47821/qr`）を開くと、`data.json` 全体を gzip→base45 化した QR コマ（`FRL2:<hash>:<index>:<total>:<crc32>:<chunk>` 形式）を繰り返し表示する。スマホの「QR で受け取る」でカメラを向け続けると全コマを回収して復元・マージする。
- コマ数が 80 を超えると画面に警告が出て LAN 同期を勧める。200 コマを超えるデータは QR 表示自体を拒否する（413）ので、その場合は LAN 同期か後述のファイル取り込みを使う。

### ファイル取り込み（スマホ → PC）

- スマホの「PC へ書き出す」で作った v2 JSON ファイルを、`import_file(path)` ツールで取り込む。中身は `/sync?mode=merge` と同じマージ規則で `data.json` に反映される。
- 送ってきた `deviceId` が未登録の端末なら自動でペアリング登録される（**その時点で画面に表示中のペアリングコードが消費される**ので、QR ペアリングの途中では使わないこと）。

### 端末管理

- `forget_device(deviceId)`: 端末を `hub.json` の一覧から外す。以後その端末はトークンが無効になり、`purge_tombstones` のカットオフ計算からも除外される。
- `rotate_token(deviceId)`: その端末のトークンを失効させ新しいものを発行する。スマホは再ペアリングが必要。
- `purge_tombstones()`: 墓標（削除済みレコード）を物理削除する。カットオフは「ペアリング済み端末全員の `lastSyncAt` の最小値 − 24 時間」。1 台でも一度も同期していない端末があれば何も削除しない。

### `sync_status`

主なフィールド:

- `dataFile` / `modifiedAt` / `warning` / `purgedBefore`: `data.json` 自体の情報。
- `lan`: `{ listening, url, addresses, port, pairingPage, qrPage }`。LAN が無効なら `null`。
- `fingerprint`: 証明書の SHA-256 フィンガープリント。
- `pairing`: `{ state: 'none'|'issued'|'expired'|'locked', expiresAt, failures }`。コードそのものは含まれない。
- `devices`: ペアリング済み端末（トークンは含まない）と、各端末の直近同期の進捗（`progress`）。
- `lastSync`: 直近に処理した同期の段階・結果。
- `lanError` / `configError`: LAN 起動や `hub.json` 読み込みが失敗した理由。

### 環境変数

- `FRELOCATOR_LAN=off` — LAN サーバーとローカルページを起動しない（ローカルの MCP ツールは通常どおり動く）。
- `FRELOCATOR_LAN_PORT`（既定 `47820`）/ `FRELOCATOR_LOCAL_PORT`（既定 `47821`）。
- `FRELOCATOR_MDNS=off` — mDNS（`_frelocator._tcp`）広告だけ止める。LAN サーバー自体は動く。

### セキュリティ

- 通信は自己署名 TLS。スマホはペアリング時に受け取った証明書フィンガープリントだけを信頼する（ホスト名検証はしない = ピン留め）。
- `/pair` 以外は端末別トークンによる Bearer 認証必須。トークンは `hub.json`（同ディレクトリ、パーミッション 600）にのみ保存され、`sync_status` など MCP 応答には絶対に出さない。
- ペアリングコードの誤入力は 1 コードあたり 10 回まで。超えるとそのコードはロックされ、新しいコードを発行し直す必要がある。
- `hub.json` が壊れている（JSON が壊れている・証明書が不正）場合は `hub.json.broken-<timestamp>` に退避して起動する。証明書ごと失われるため、**全端末が再ペアリングになる**。ローカルのタスク管理ツールは引き続き使えるが、LAN 同期は `configError` 付きで無効になる。

### トラブルシューティング

- スマホから LAN 経由で繋がらない: `sync_status` の `lan.addresses`（複数 NIC がある Mac では正しくない候補が先頭に出ることがある）から別の候補アドレスを試す。ペアリングページにも同じ候補一覧が出る。
- `413 payload_too_large`: `/pair` は 8KB、`/sync` は 20MB が上限。応答は `Connection: close` を伴うので、クライアントは接続を張り直してから再送する。
- `426 upgrade_required`: スマホ側のスキーマバージョンがハブより古い。アプリを更新する。

## 開発

- テスト: `npm test`（マージ規則と不変条件は `test/fixtures/sync_merge` を Flutter 側と共有）。
- 型検査: `npm run typecheck`（`tsconfig.test.json`。テストも含めて検査する）。
- stdio サーバーの疎通確認: `npm run smoke`（ビルドしてから実クライアントでツール一覧と `add_task` → `list_tasks` を往復する）。
