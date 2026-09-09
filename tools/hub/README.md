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

全 43 個。オーナー自身のデータしか扱わないので、すべてのエンティティを MCP から作成・取得・更新・削除できる。
網羅状況と設計判断は [`docs/tool-coverage.md`](docs/tool-coverage.md) を参照。

タスク:

- `list_tasks` — 種別・カテゴリ・キーワードで生きているタスクを一覧する
- `get_task` — id で 1 件取得する（`includeDeleted` で墓標も見る）
- `add_task` / `bulk_add_tasks` — 1 件／最大 100 件まとめて追加する
- `update_task` — 指定した項目だけ更新する（kind を変えたら新しい種別に無いカテゴリは外れる）
- `bulk_update_tasks` — 複数件の部分更新を 1 回の書き込みで適用する（1 件でも失敗したら何も書かない）
- `delete_task` / `bulk_delete_tasks` — 墓標化する（物理削除ではない）
- `reorder_tasks` — 種別内の並び順を id 配列で指定する（順序は `priority` に書き戻す）

カテゴリと設定:

- `list_categories` / `add_category` / `update_category`（改名）/ `delete_category`（参照タスクの分類を外す）
- `merge_categories` — 破壊的。タスクを移し替えてから元のカテゴリを墓標化する
- `get_settings` / `set_share_categories` — カテゴリ共有の参照と ON/OFF（ON 時は 4 つのマージ戦略を選べる）

日次計画:

- `list_daily_plans` / `get_daily_plan` / `create_daily_plan`（冪等）
- `delete_daily_plan` — 破壊的。計画と枠・割り当てをまとめて墓標化する
- `copy_daily_plan` / `move_daily_plan` — 別日へ複製する／移して元日を空にする
- `add_free_slot` / `update_free_slot` / `delete_free_slot`（枠の割り当てごと消える）
- `assign_task` / `update_assignment` / `unassign`
- `move_assignment` — 別の枠・別の日・同じ枠の別位置へ移す（移動先の枠は先頭から詰め直される）
- `weekly_report` — 1 週間の自由時間と割り当てを種別・カテゴリで集計する

データ:

- `export_data` / `undo_last_write` / `sync_status`
- `import_file` / `import_data` / `purge_tombstones` / `forget_device` / `rotate_token`

競合（後述）:

- `list_conflicts` / `get_conflict` — 記録された競合を一覧する／1 件の差分を見る
- `resolve_conflict` — PC 版・スマホ版・現状維持のいずれかを選ぶ
- `resolve_all_conflicts` — 破壊的。未解決を全件まとめて同じ方針で解決する（`dryRun` あり）

`import_file` から `rotate_token` までの 5 個は LAN サーバー（後述）が起動できている場合だけ動く。`hub.json` が壊れていて LAN が無効なときは「LAN sync is not configured in this hub process」を返す。

タスクの完了フラグと墓標の復元はモデル側に情報が無いため提供していない（理由は `docs/tool-coverage.md`）。

日付引数（`date` / `from` / `to` / `weekStart` / `fromDate` / `toDate`）は `YYYY-MM-DD` で、ハブを動かしているマシンのローカルなカレンダー日を指す。`startAt` / `endAt` はオフセット付き ISO を受け取り、UTC ISO 文字列として保存する。

## LAN 同期（Plan 2a）

ハブ起動中は、スマホ（Plan 2b の FRELOCATOR アプリ）と同じ Wi-Fi 上で `data.json` を同期できる。MCP を止めるとこの機能も止まる。

### ペアリング

1. `sync_status` ツールが返す `lan.pairingPage`（`http://127.0.0.1:47821/<秘密のパス>/pair`）を PC のブラウザで開く（127.0.0.1 限定。LAN からはアクセスできない）。パスの先頭にはハブ起動ごとに生成されるランダムな秘密文字列が入るので、URL は毎回 `sync_status` から取り直すこと。
2. ページに表示される QR をスマホの FRELOCATOR アプリで読み取る。コードは 5 分・1 回限りで、失敗が 10 回続くとそのコードはロックされる（ページを再読み込みすれば新しいコードが出る）。
3. 成功するとスマホは端末別の長期トークンを受け取り、以後 `Authorization: Bearer <token>` で `/sync` `/health` を呼ぶ。

### 同期モード

スマホの「同期」操作は `POST https://<LAN IP>:47820/sync?mode=merge|take_hub|take_phone` を呼ぶ。

- `merge`（既定）: PC とスマホ双方の変更を HLC ベースでマージする。通常はこれを使う。
- `take_hub`: PC 側のデータをそのまま正としてスマホに返す。**スマホ側の未同期の変更は失われる。**
- `take_phone`: スマホが送った文書をそのまま PC の `data.json` として保存する。**PC 側の変更（他端末からの分も含む）は失われる。**

`purge_tombstones` 実行後に一度も同期していない端末が `merge` しようとすると `409 purged_before` で拒否される（下記）。その場合は `take_hub` か `take_phone` を選ぶ必要がある。

### QR でスマホにデータを送る（PC → スマホ）

- `sync_status` の `lan.qrPage`（`http://127.0.0.1:47821/<秘密のパス>/qr`）を開くと、`data.json` 全体を gzip→base45 化した QR コマ（`FRL2:<hash>:<index>:<total>:<crc32>:<chunk>` 形式）を繰り返し表示する。スマホの「QR で受け取る」でカメラを向け続けると全コマを回収して復元・マージする。
- コマ数が 80 を超えると画面に警告が出て LAN 同期を勧める。200 コマを超えるデータは QR 表示自体を拒否する（413）ので、その場合は LAN 同期か後述のファイル取り込みを使う。

### ファイル取り込み（スマホ → PC）

- スマホの「PC へ書き出す」で作った v2 JSON ファイルを、`import_file(path)` ツールで取り込む。中身は `/sync?mode=merge` と同じマージ規則で `data.json` に反映される。
- 読めるのは **データディレクトリ（`FRELOCATOR_DATA_DIR`）・`~/Downloads`・`FRELOCATOR_IMPORT_DIRS`（`:` 区切り）配下のファイルだけ**。それ以外は `path not allowed: <解決後のパス>` で拒否する。先頭の `~` はホームディレクトリに展開する。
- サイズ上限は `/sync` と同じ 20 MB。超えるファイルは開かずに拒否する。
- 送ってきた `deviceId` が未登録の端末なら、**マージが成功した後に**登録される（purge のカットオフ計算に入れるため）。**画面に表示中のペアリングコードは消費しない**ので、QR ペアリングの途中でも使ってよい。取り込みが失敗した場合は端末レコードも残らない。

### 端末管理

- `forget_device(deviceId)`: 端末を `hub.json` の一覧から外す。以後その端末はトークンが無効になり、`purge_tombstones` のカットオフ計算からも除外される。
- `rotate_token(deviceId)`: その端末のトークンを失効させ新しいものを発行する。**新しいトークンは応答に含めない**（MCP の応答はログやチャットに残るため）。スマホは新しいペアリング QR を読み直して再ペアリングする。
- `purge_tombstones()`: 墓標（削除済みレコード）を物理削除する。カットオフは「ペアリング済み端末全員の `lastSyncAt` の最小値 − 24 時間」。1 台でも一度も同期していない端末があれば何も削除しない。

### `sync_status`

主なフィールド:

- `dataFile` / `modifiedAt` / `warning` / `purgedBefore`: `data.json` 自体の情報。
- `lan`: `{ listening, disabled, url, addresses, port, pairingPage, qrPage }` のオブジェクト。`FRELOCATOR_LAN=off` のときは `listening: false` / `disabled: true` で、`url` `port` `pairingPage` `qrPage` は `null`。`null` になるのは `hub.json` の読み込みに失敗した（`configError` 付き）ときだけ。
- `fingerprint`: 証明書の SHA-256 フィンガープリント。
- `pairing`: `{ state: 'none'|'issued'|'expired'|'locked', expiresAt, failures }`。コードそのものは含まれない。
- `devices`: ペアリング済み端末（トークンは含まない）と、各端末の直近同期の進捗（`progress`）。
- `lastSync`: 直近に処理した同期の段階・結果。
- `lanError` / `configError`: LAN 起動や `hub.json` 読み込みが失敗した理由。`FRELOCATOR_LAN=off` のときは `lanError` に `LAN disabled by FRELOCATOR_LAN=off` が入る（失敗ではなく設定である目印）。

### 環境変数

- `FRELOCATOR_LAN=off` — LAN サーバーとローカルページを起動しない（ローカルの MCP ツールは通常どおり動く）。
- `FRELOCATOR_LAN_PORT`（既定 `47820`）/ `FRELOCATOR_LOCAL_PORT`（既定 `47821`）。
- `FRELOCATOR_MDNS=off` — mDNS（`_frelocator._tcp`）広告だけ止める。LAN サーバー自体は動く。
- `FRELOCATOR_IMPORT_DIRS` — `import_file` が読んでよいディレクトリの追加分（`:` 区切り）。既定はデータディレクトリと `~/Downloads`。
- ポート番号が 0〜65535 の整数でない場合は stderr に警告を出して既定値に戻す。

### セキュリティ

- 通信は自己署名 TLS。スマホはペアリング時に受け取った証明書フィンガープリントだけを信頼する（ホスト名検証はしない = ピン留め）。
- `/pair` 以外は端末別トークンによる Bearer 認証必須。トークンは `hub.json`（同ディレクトリ、パーミッション 600）にのみ保存され、`sync_status` など MCP 応答には絶対に出さない。
- ペアリングコードの誤入力は 1 コードあたり 10 回まで。超えるとそのコードはロックされ、新しいコードを発行し直す必要がある。
- ローカルページ（`/pair` `/qr`）は **URL を知っているプロセスをすべて信頼する**。同じ Mac の他プロセスや他ユーザーから守るため、全ルートはハブ起動ごとのランダムな秘密パス（16 バイト hex）配下に置かれ、その URL は `sync_status` の応答でしか手に入らない。秘密パスの付いていないリクエストは 404。
- 加えて、ブラウザからの横取りを防ぐガードを掛けている: `Host` が `127.0.0.1:<port>` か `localhost:<port>` でなければ 403（DNS リバインディング対策）、`Origin` が付いていて同一オリジンと完全一致しなければ 403、`Sec-Fetch-Site` が `none` / `same-origin` 以外なら 403。メソッドは `GET` / `HEAD` のみで、`POST` は `/<秘密のパス>/api/` 配下だけが受け付ける（それ以外は 405）。
- `import_file` が読めるのはデータディレクトリ・`~/Downloads`・`FRELOCATOR_IMPORT_DIRS` 配下だけ。エラーメッセージはファイルの中身を反射しない（`not valid JSON` / `cannot read file` の固定文言）。
- `hub.json` が壊れている（JSON が壊れている・証明書が不正）場合は `hub.json.broken-<timestamp>` に退避して起動する。証明書ごと失われるため、**全端末が再ペアリングになる**。ローカルのタスク管理ツールは引き続き使えるが、LAN 同期は `configError` 付きで無効になる。

### トラブルシューティング

- スマホから LAN 経由で繋がらない: `sync_status` の `lan.addresses`（複数 NIC がある Mac では正しくない候補が先頭に出ることがある）から別の候補アドレスを試す。ペアリングページにも同じ候補一覧が出る。
- `413 payload_too_large`: `/pair` は 8KB、`/sync` は 20MB が上限。応答は `Connection: close` を伴うので、クライアントは接続を張り直してから再送する。
- `426 upgrade_required`: スマホ側のスキーマバージョンがハブより古い。アプリを更新する。

## ハブ上の Web 版（Plan 3a）

ハブ自身が Flutter web ビルドを配信し、そのブラウザが同一オリジンの JSON API で PC の `data.json` を直接読み書きする。公開 Web 版（`app.frelocator.riumu.net`）とスマホアプリの挙動は変わらない。

- 準備: `cd tools/hub && npm run build:web`（リポジトリ直下で `flutter build web` を回して `web-dist/` に置く。`web-dist/` は git 管理外）。ビルドは `web-dist.tmp` に組み立ててから差し替えるので、途中で失敗しても手元の `web-dist/` は無傷のまま残る。ハブを動かしたまま再ビルドしても構わない（ETag はファイルごとの `mtime`/サイズで持っていて、ずれた分だけ取り直す）。`flutter` が PATH に無いときは、その旨だけ言って止まる。
- 開き方: `sync_status` の `lan.webApp.url`（`http://127.0.0.1:47821/<秘密のパス>/app/`）をブラウザで開く。URL には起動ごとに変わる秘密プレフィックスが入るので、ブラウザの履歴から開き直さず毎回 `sync_status` から取り直す。
- このブラウザは PC の `data.json` を **直接** 編集する。ブラウザ内に控えは持たない（リロードで未送信の編集は失われる。未送信がある間は赤い帯と離脱警告が出る）。
- MCP の編集は 2 秒間隔のポーリングで画面に出る。タブが隠れている間はポーリングを止める。
- `sync_status.lan.webApp.stale` が `true` のときは、`web-dist/` が今の HEAD と違うコミットで作られている。`npm run build:web` を実行し直す。`gitRev` が読めない・`git` が無い場合は判定できないので `false` のまま。
- `web-dist/` が無い場合は `built: false` で URL も出ない。ハブ自体は通常どおり起動する。
- `sync_status.webClients` は画面を開いたブラウザの一覧（表示専用）。墓標の掃除（`purge_tombstones`）のカットオフ計算には **入らない**。不要になったら `forget_device` に `web-<16 桁 hex>` を渡して消せる。最大 16 件で、あふれると `lastSeenAt` が最も古いものから捨てる。`hub.json` への書き戻しは「初めて見た id」か「記録済みの `lastSeenAt` が 5 分より古い」ときだけなので、タブを開けっぱなしにしてもファイルを叩き続けない。
- ブラウザ側の編集は `web-…` という擬似端末 id で `SyncEngine.sync()` を通るが、ペアリング済み端末としては記録しない（ブラウザは手元に控えを持たないので、墓標の掃除を待たせてはいけない）。そのため web からの同期では端末ごとの `lastSyncAt` 記録を行わず、成功した同期の `warnings` は空になる。

### 動作確認

`npm run smoke` は `web-dist/` があるときだけブラウザ往復も検査する（無ければその節をスキップして緑のまま）。見ているのは、index.html が `window.__FRELOCATOR_HUB__` と書き換え済みの `<base href>` を含むこと・`flutter_bootstrap.js` が配信されること・MCP の `add_task` が `GET /api/document` に出ること・`POST /api/sync` で足したタスクが `list_tasks` に出ること・そのブラウザが `webClients` にだけ載って `devices` には載らないこと・別オリジンからの `POST` と web id ヘッダ無しの呼び出しが 403 になること。

ブラウザでの手動確認（Chrome / Safari）:

1. `sync_status` の `lan.webApp.url` を開く。
2. MCP から `add_task` → 数秒で画面に出る。
3. ブラウザで編集 → スマホの「PC と同期」に出る。
4. タブを隠す → `/api/revision` のリクエストが止まる（Network タブ）。
5. 保存前にリロード → 未送信バナーと離脱警告が出る。

### API とガード

- `GET /<秘密のパス>/api/document` — 文書全体と `hubDeviceId` / `revision` / `serverTime`。
- `GET /<秘密のパス>/api/revision` — `revision`（`sha256(data.json)` の先頭 16 桁）と `modifiedAt` だけ。ポーリング用。
- `POST /<秘密のパス>/api/sync?mode=merge|take_hub|take_web` — LAN の `/sync` と同じ `SyncEngine.sync()` を通る（`take_web` は LAN の `take_phone` と同じ意味）。
- どのリクエストも `X-FRELOCATOR-Web-Id: <16 桁 hex>` が必須（端末 id は `web-<hex>`）。カスタムヘッダはプリフライト無しでは送れないため、秘密プレフィックスと合わせて二重の壁になる。`POST` は `Content-Type: application/json` も必須。
- エラーは LAN 側と同じ `{ "error": { "code": ..., "message": ... } }`。
- `GET /api/revision` は `data.json` の `{mtime, サイズ}` をキーに結果を持ち回す。値が動いていなければデータロックも取らず再ハッシュもしないので、2 秒ごとのポーリングがスマホの同期とロックを奪い合わない。

### ブラウザに残るもの・保存できないとき

- ブラウザ（hub モード）が localStorage に持つのは web id（`frelocator.webId`）と HLC クロックだけです。タスクや計画などの業務データはブラウザに保存されず、常にハブの `data.json` が正です。記録に刻まれる端末 id は保存せず `web-<webId>` として導出します。
- 保存に失敗したとき: 5xx や接続断などの一時的な失敗は 2→4→8 秒（上限 30 秒）のバックオフで自動再送します。ハブが同じ理由で拒否し続けるもの（`409 purged_before`、`426 upgrade_required`、`400 invalid_document` / `bad_timestamp`、`403`）は再送を止めて編集を手元に保持し、「PC と同期」カードに理由と「PC のデータで置き換える」「ブラウザのデータで置き換える」を出します（それぞれ `POST /<秘密のパス>/api/sync?mode=take_hub` / `?mode=take_web`）。


### レスポンスヘッダ

ローカルページのすべての応答に `Referrer-Policy: no-referrer`（秘密プレフィックスを `Referer` に漏らさない）・`X-Content-Type-Options: nosniff`・`Cross-Origin-Opener-Policy: same-origin` を付ける。アプリの HTML にはさらに CSP を付ける:

```
default-src 'self'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline';
img-src 'self' data: blob:; font-src 'self' data: https://fonts.gstatic.com;
connect-src 'self' https://fonts.gstatic.com; worker-src 'self' blob:
```

`'unsafe-inline'`（script）は Flutter が `flutter_bootstrap.js` と `__FRELOCATOR_HUB__` をインラインで置くため、`'wasm-unsafe-eval'` は CanvasKit / skwasm のため。CanvasKit 自体はローカル配信（ビルドの `--no-web-resources-cdn` により `useLocalCanvasKit: true`）なので `script-src` は `'self'` のまま。

唯一の外部許可が `https://fonts.gstatic.com` で、これは Flutter エンジンが日本語の字形を Noto Sans JP のサブセットとして取りに行くため（`fontFallbackBaseUrl` の既定値）。アプリはフォントを同梱していないので、ここを塞ぐと日本語がすべて豆腐になる。実ビルドの `web-dist/` を Chrome で読み込んで確認した結果、外部に出るリクエストはこの Noto のサブセットだけで、`.wasm` を含む他のすべては同一オリジンから配信されている。

## 競合（Plan 3b）

同じエンティティを PC（MCP）とスマホ／ブラウザの両方で編集していると、マージは
HLC の勝者を暫定採用して**同期そのものは必ず完了させ**、敗者のスナップショットを
競合レコードとしてドキュメント直下の `conflicts[]` に残す。あとから
`resolve_conflict` でどちらを採るか選ぶ。

- 検出はマージの中で行い、合意点は受信側が申告する `lastSyncAt`。初回同期
  （`lastSyncAt` が null）では検出しない。
- レコードの id は `cf-<sha256(entityId+勝者clock+敗者clock)[0..16]>` で決定的。
  Dart と TypeScript が別々に検出しても同じ id になるので、再検出は冪等。
- 採用は**新しい clock の編集として書き戻す**（clock は巻き戻らない）。したがって
  次の通常マージでスマホにもブラウザにも伝播する。墓標を採用すると再び削除される。
- 上限は未解決 1000 件・解決済み 200 件。解決済みは 30 日で墓標化し、
  `purge_tombstones` のカットオフに乗って物理削除される。溢れたときは同期の
  warnings に `conflict_overflow` が出る。
- `take_hub` / `take_phone`（`import_data` の `mode=replace` を含む）でデータを
  置き換えても、`conflicts` だけは常に両者の和集合を保つ。置き換えは
  「どちらのデータを採るか」であって「何が競合したかの記録を消すこと」ではない。
- スキーマ版は 2 のまま。`conflicts` を持たない古いアプリとも往復できるが、
  **古いアプリはこのフィールドを落とす**（受け取った側が保持しない）。ハブは常に
  和集合を取るのでハブ側の記録は消えない、という非対称がある。
- ハブのローカルページ（ペアリング／QR）に競合一覧は作っていない。参照と解決は
  MCP ツールとアプリの「設定 › PC と同期 › 競合」から行う。

## 開発

- テスト: `npm test`（マージ規則と不変条件は `test/fixtures/sync_merge` を Flutter 側と共有）。
- 型検査: `npm run typecheck`（`tsconfig.test.json`。テストも含めて検査する）。
- web 版のビルド: `npm run build:web`（`flutter build web --release` を回して `web-dist.tmp` へ複製してから `web-dist/` に差し替え、`BUILD_INFO.json` に git rev と時刻を書く）。
- stdio サーバーの疎通確認: `npm run smoke`（ビルドしてから実クライアントでツール一覧を取り、カテゴリ作成から並べ替え・割り当て移動・削除・`undo_last_write`・競合の作成と解決・`purge_tombstones` まで CRUD を一巡させ、各段階で不変条件を検査する）。
