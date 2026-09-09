# FRELOCATOR Plan 3: ハブ上の Web 版と競合解決

作成日: 2026-09-09 / 前提コミット: `1913ab7`（Plan 1 / 2a / 2b 実装済み）

## 概要

Plan 1〜2b で、`data.json` を正とする MCP ハブ（`tools/hub/`）と、HLC・墓標・エンティティ単位マージによる LAN 同期（PC ⇄ スマホ）が動いている。Plan 3 はその上に二つを足す。

- **3a: ハブ上の Web 版**。ハブが Flutter web ビルドを `http://127.0.0.1:<port>/<secret>/app` で自分自身から配信し、ブラウザがハブの `data.json` を直接読み書きする。MCP の編集がブラウザに出て、ブラウザの編集が MCP とスマホに流れる。公開サーバーは一切関与しない。
- **3b: 競合の記録と解決**。同期は今までどおり必ず完了させる。両側で同じエンティティが変わっていたら HLC の勝者を暫定採用したうえで「競合」として記録し、あとからどちらを採用するかを選べる段階を設ける。

Plan 1〜2b の設計書 `docs/superpowers/specs/2026-09-08-frelocator-hub-sync-design.md` を土台とし、そこで決めた規則（HLC、墓標、`purgedBefore`、`test/fixtures/sync_merge` の Dart / TS 共有フィクスチャ）は変えない。

## 決定事項

オーナー判断（Plan 3 の前提。以降の設計はこれに従う）。

1. **Option A**。ハブが Flutter web ビルドをローカル配信し（ハブのローカルページと同一オリジン）、ブラウザはハブの `data.json` を読み書きする。公開サーバーは介在しない。`app.frelocator.riumu.net` の公開 Web 版は従来どおりブラウザローカルのままで、ハブとは無関係。
2. **モバイルしか持っていない情報を同期で落とさない**。`merge` は id の和集合で、片側にしか無いものは必ず残す。落とし得るのは置き換えモードだけであり、それらは確認・バックアップ・409 ガードで囲う。さらに競合の敗者スナップショットを記録に残すことで、LWW の敗者すら消えない状態にする。
3. **競合があっても同期は正常完了させる**。警告を出し、`conflicts` に記録し、別途「解決の段階」でどちらを採用するか選ぶ。未解決の競合が同期を止めることはない。

派生する設計上の決定。

- 競合の検出は **共有マージャの中** で行う（Dart `SyncMerger` / TS `merge`）。ハブ専用にしない。QR・ファイル取り込みでもスマホ側だけでマージが起きるため。
- 競合レコードの id は **決定的**（内容から導出）にする。時刻由来にすると Dart / TS 共有フィクスチャで期待結果を固定できず、再検出が冪等にならない。
- 競合はドキュメント埋め込み（`conflicts` 配列）。別ファイルにすると同期経路に乗らず、スマホの UI から見えない。
- スキーマ版は **2 のまま**、`conflicts` は任意フィールド。古いクライアントは無視できる。

---

## A. ハブ上の Web 版（Plan 3a）

### A-1. 何をどこに置くか

```
tools/hub/web-dist/            flutter build web の成果物のコピー（git 管理外）
tools/hub/web-dist/BUILD_INFO.json  { gitRev, flutterVersion, builtAt }
tools/hub/scripts/build-web.mjs     リポジトリ直下で flutter build web を実行し web-dist/ へ複製
tools/hub/src/static-server.ts      web-dist/ の静的配信（MIME / ETag / SPA フォールバック / パス検査）
tools/hub/src/web-api.ts            ブラウザ ⇄ ハブの JSON API
```

`build/web` を直接配信しない理由: `flutter run -d chrome` や別ブランチのビルドで中身が入れ替わり、ハブが「今リポジトリにあるもの」ではなく「最後に誰かがビルドしたもの」を配ってしまう。`web-dist/` は `npm run build:web` でしか更新されず、`BUILD_INFO.json` に git rev を刻む。`sync_status` は現在の `git rev-parse HEAD` と食い違うときに `webApp.stale: true` を返す。

`web-dist/` は `.git/info/exclude` に追記する（`.gitignore` には書かない。ユーザー規約）。

ビルドコマンド:

```
flutter build web --release --pwa-strategy=none --no-web-resources-cdn
```

- `--pwa-strategy=none`: Service Worker がハブ再起動をまたいで古い JS を握り続けるのを防ぐ。秘密プレフィックスが起動ごとに変わるので SW のスコープ管理も破綻する。
- `--no-web-resources-cdn`: CanvasKit / フォントを `gstatic.com` から取りに行かせない。ローカルファーストの建前と、オフラインの PC で画面が壊れないため。
- `--base-href` は **付けない**。秘密プレフィックスは起動ごとの乱数なのでビルド時に決められない。代わりにハブが `index.html` を返すときに `<base href>` を書き換える（A-2）。

### A-2. 静的配信

ルート: `GET /<secret>/app` および `GET /<secret>/app/<path...>`。

- パス検査: URL デコード後に `path.normalize` し、`web-dist/` の実パス配下（`fs.realpath` 済み）に収まらなければ 403。`..`、`%2e%2e`、シンボリックリンク経由の脱出を弾く。
- MIME: 拡張子表引き（`.js` `.mjs` `.json` `.wasm` `.css` `.html` `.png` `.svg` `.ttf` `.otf` `.woff2` `.bin` `.symbols`）。表に無い拡張子は `application/octet-stream`。
- キャッシュ: Flutter web の出力はファイル名にハッシュが入らないので、`Cache-Control: no-cache` ＋ 強い `ETag`（`sha256(内容)` の先頭 16 文字、起動時に一括計算してメモリに保持）。`If-None-Match` 一致で 304。再ビルド後の取りこぼしが無く、リロードは全部 304 で済む。
- `index.html` だけは毎回生成する。`<head>` 先頭を次で置き換える:

```html
<base href="/<secret>/app/">
<script>window.__FRELOCATOR_HUB__ = {
  "mode": "hub",
  "base": "/<secret>/app/",
  "api": "/<secret>/api/",
  "hubDeviceId": "hub-macos",
  "schema": 2,
  "dataFile": "~/Library/Application Support/FRELOCATOR/data.json"
};</script>
```

- SPA フォールバック: `/<secret>/app/<path>` が実ファイルでなく、拡張子を持たない GET なら `index.html` を返す。Flutter web の既定はハッシュ URL 戦略なので通常は使われないが、`usePathUrlStrategy` に切り替えたときに壊れないようにしておく。
- ディレクトリ一覧は返さない。`web-dist/` が無い場合は 503 と「`cd tools/hub && npm run build:web` を実行してください」の日本語ページ。

### A-3. ブラウザ ⇄ ハブ API

同一オリジン（`http://127.0.0.1:<port>`）の JSON エンドポイント。`SyncEngine` をそのまま再利用する。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/<secret>/api/document` | `{ document, hubDeviceId, revision, serverTime }` |
| `GET` | `/<secret>/api/revision` | `{ revision, modifiedAt }`（ポーリング用の軽い応答） |
| `POST` | `/<secret>/api/sync?mode=merge\|take_hub\|take_web` | `{ document, summary, warnings, conflicts }` |

- `revision` = `data.json` の `sha256` 先頭 16 文字。ブラウザは可視のとき 2 秒間隔で `/api/revision` を叩き、変わっていたら `/api/document` を取り直す（＝ MCP の編集が数秒で画面に出る）。タブが隠れている間はポーリングを止める。WebSocket は使わない（ローカルページが HTTP のみで完結している構成を崩さないため）。
- `POST /api/sync` は LAN の `POST /sync` と同じ実装を通す。`SyncEngine.sync(deviceId, document, mode)` を `deviceId = "web-<browserId>"` で呼ぶだけ。したがって応答形（`{document, summary, warnings}` ＋ Plan 3b の `conflicts`）とエラー形（`{error:{code,message}}`、400 / 409 / 413 / 426）は LAN と完全に同じで、スマホと Web で挙動が割れない。
- `take_web` は `SyncMode` の `take_phone` に写像する（内部名は変えず、API の見せ方だけ変える）。
- `browserId`: Web アプリが初回に `crypto.getRandomValues` で 16 桁 hex を作り `localStorage` に保存する。リクエストヘッダ `X-FRELOCATOR-Web-Id: <16 hex>` で送り、ハブは形（`/^[0-9a-f]{16}$/`）を検査して `web-<browserId>` を端末 id にする。ブラウザプロファイルごとに別端末になるので、HLC の deviceId が衝突しない。

### A-4. ガード（ローカルページと同等 ＋ API 用の緩和）

現行 `LocalPages.guard()` は GET/HEAD 限定・`Origin` ヘッダがあれば一律 403 なので、API 用に次の形へ広げる。

- `Host` は `127.0.0.1:<port>` か `localhost:<port>` のみ（DNS リバインディング対策、現状維持）。
- `Sec-Fetch-Site` は `none` / `same-origin` のみ（現状維持）。
- `Origin` は「無い」か「`http://127.0.0.1:<port>` / `http://localhost:<port>` と完全一致」のみ許す。それ以外は 403（現状の「あれば拒否」から緩和）。
- POST は `/<secret>/api/` 配下だけ。`Content-Type: application/json` 必須（フォームによる simple request での CSRF を封じる）。
- `X-FRELOCATOR-Web-Id` 必須。カスタムヘッダはプリフライト無しでクロスオリジン送信できないため、上記と合わせて二重の壁になる。
- ボディ上限は `/sync` と同じ 20 MB。超過は 413 ＋ `Connection: close`（LAN と同じ挙動）。
- 秘密プレフィックスは `sync_status` からしか出さない（現状維持）。ハブ再起動で変わる。

### A-5. Web アプリ側の hub モード

- 判定: `lib/services/hub_mode/hub_mode.dart` を条件付きエクスポート（`hub_mode_stub.dart` / `hub_mode_web.dart`、既存の `lan_sync_client.dart` と同じ形）にし、`dart:js_interop` で `globalContext['__FRELOCATOR_HUB__']` を読む。存在しなければ `HubMode.none`。公開 Web 版（`app.frelocator.riumu.net`）にはこの global が無いので、既存の `PrefsStateStore` 経路のまま **一切変わらない**。
- 保存層: hub モードでは `stateStoreProvider` が `HubBackedStore implements StateStore` を返す。
  - `read*` は直近に取得したドキュメントのメモリ上のスナップショットから返す。
  - `writeAll` はスナップショットを更新し、400 ms デバウンス・single-flight で `POST /api/sync?mode=merge` する。返ってきたドキュメントをそのまま採用する（＝ MCP の同時編集がマージ済みで返る）。
  - `changedSinceLastRead()` はポーラが新しい `revision` を見たときに true を返す。`lib/app/app.dart` の既存の再読み込み導線がそのまま使える（編集ダイアログ表示中は遅延、も既存のまま）。
  - **ブラウザローカルに業務データは持たない**（ライブ編集）。`localStorage` に置くのは `browserId`・`lastSyncAt`・UI の表示設定だけ。二つの真実（ブラウザのコピーとハブの `data.json`）が並存すると、ブラウザを閉じている間の MCP 編集との突き合わせが「同期」ではなく「三者マージ」になり、複雑さに見合わない。
  - 送信に失敗したら赤帯で「PC に保存できていません（再試行）」を出し、`beforeunload` で離脱を警告する。未送信の編集はリロードで消える、と画面上で明示する。
- HLC: Web も自分の `DeviceClock`（`web-<browserId>`）を持ち、`localStorage` に `lastClock` を保存する。受信ドキュメントの clock を `observe` するのは `SyncService._observeClocks` と同じ処理を使い回す。
- 画面: hub モードでは「PC と同期」画面のペアリング・QR・LAN 系を隠し、「このブラウザは PC の `data.json` を直接編集しています」と保存先パス、最終保存時刻、競合バッジ（Plan 3b）を出す。

### A-6. MCP 書き込みとの並行

- ハブ側の書き込みは全て `FileStore.update` の一本のロックを通る。`POST /api/sync` もその中で read-modify-write するので、MCP の書き込みが割り込んでも「読んだ後に上書き」は起きない。エンティティ単位の勝敗は HLC の LWW。
- Web が古い `revision` を持ったまま POST しても壊れない: 送るのは全文書で、マージは id の和集合＋ HLC なので、その間に MCP が触ったエンティティは MCP 側の新しい clock で勝つ。ただし **Web が同じエンティティを触っていた場合は競合**になる（Plan 3b）。
- Web の擬似端末を `hub.json` の `devices`（purge のカットオフ計算対象）に **入れない**。Web は永続ストアを持たないので `purgedBefore` に取り残される概念が無く、逆に登録すると「しばらくブラウザを開かない」だけで purge が止まる。表示用に `webClients: [{ id, lastSeenAt }]` を別に持ち、`sync_status` に出す。`forget_device` はこちらにも効くようにする。

---

## B. モバイルしか持っていない情報を落とさない

### B-1. 現状、データが減り得る経路

| 経路 | 何が消えるか | 既存のガード |
|---|---|---|
| `POST /sync?mode=take_hub` | スマホにしか無いエンティティ（スマホ側が丸ごとハブの文書に置き換わる） | `SyncService._snapshotBeforeReplace()` → `sync_backup_v1`、`restoreBackup()`、`confirmAction` の確認ダイアログ |
| `POST /sync?mode=take_phone` | ハブにしか無いエンティティ（MCP の未同期編集を含む） | `data.json.bak` 1 世代＋ `undo_last_write` |
| `import_data mode='replace'` | 同上（内部で `take_phone` に写像） | 同上。ただし確認は無い |
| `purge_tombstones` | 墓標の物理削除。それ自体は生データを消さないが、`purgedBefore` に取り残された端末が置き換えモードに落ちる | 409 `purged_before`、`PURGE_SKEW_MS = 24h`、未同期端末が 1 台でもあれば purge しない、`forget_device` |
| （3a 追加）`POST /api/sync?mode=take_web` | ハブにしか無いエンティティ | `data.json.bak`。UI では「PC のデータを置き換える」と明示し確認する |
| （3a 追加）hub モードでの未送信編集 | ブラウザ内の未送信の編集（保存前のリロード） | 赤帯＋ `beforeunload` |

`mode=merge` の経路では **一件も減らない**。`mergeList` は `[...ia.keys(), ...ib.keys()]` の和集合を走査し、片側にしか無い id はそのまま採用する（TS `merge.ts` / Dart `SyncMerger._mergeLists` とも同じ形）。墓標も id を持つので、削除は「消える」ではなく「墓標として残る」。

### B-2. Plan 3 で足すガード

- **不変条件テスト**（Dart / TS 両方）: 「マージ前に A か B のどちらかに存在した id は、マージ後も必ず存在する（生きているか墓標かは問わない）」。
  - `test/fixtures/sync_merge/manifest.json` の全ケースに対して、期待結果の比較とは別にこの不変条件を機械的に検査する（ケースを足すたびに自動で適用される）。
  - property test にも追加: ランダム操作列で A / B を作り、`merge(A,B)` と `merge(B,A)` の双方で id 集合が `ids(A) ∪ ids(B)` に一致すること。
  - purge はこの不変条件の対象外（墓標を意図的に落とす操作）。不変条件は `merge` に対してのみ主張する。
- **置き換えの退避を両側に**: ハブ側の置き換え（`take_phone` / `take_web` / `import_data mode=replace`）は、捨てる側の文書を `data.json.replaced-<timestamp>` に 3 世代まで残す。`undo_last_write` は 1 世代しか戻せず、置き換えは「戻したい」が最も起きやすい操作のため。
- **`import_data mode='replace'` に `confirm: true` を必須化**。ツール説明にも「PC 側の未同期の変更が失われる」と書く。MCP からの誤爆が一番怖い経路のため。
- **競合の敗者を残す**（Plan 3b）。LWW で負けた側のスナップショットが `conflicts[].loser.snapshot` に丸ごと残るので、`merge` では「上書きで見えなくなる」ことすら起きなくなる。決定事項 2 に対する実質的な保証はここが本体。

---

## C. 競合の記録（Plan 3b・モデルと検出）

### C-1. 定義と検出規則

**競合** = 同じ id のエンティティが両側にあり、内容が異なり、かつ **前回両者が一致した時点より後に両側が変更している** 状態。

エンティティごとの基準版（base）を保存していないので、次の実務的な規則を採る。

```
changedAt(e) = max(Date.parse(e.updatedAt), e.clock.physical)   // ミリ秒
conflict(x, y) ⇔
      x と y の id が一致し
  ∧   contentHash(x) ≠ contentHash(y)  （片方だけが墓標の場合も含む）
  ∧   lastAgreedAt ≠ null
  ∧   changedAt(x) >= lastAgreedAt  ∧  changedAt(y) >= lastAgreedAt
```

`lastAgreedAt` は「相手と最後に同期が成功した時刻」＝ 受信文書の `lastSyncAt`（スマホ / Web が保持し、ハブの応答の `lastSyncAt` を写して更新している値）。

**なぜこの規則か。**

- *per-entity `lastSeenClock`*: 端末 × エンティティで状態を持つことになり、文書サイズが倍近くになるうえ、その状態自体をマージしなければならない。費用に見合わない。却下。
- *「どちらの clock も相手を支配しない」*: HLC は全順序なので必ずどちらかが勝つ。この条件は決して真にならず、検出器として成立しない。却下。
- *`lastSyncAt` ベース*: `lastSyncAt` は既に往復していて、意味も「これより古いものは相手からもらった」で、まさに合意点そのもの。追加の状態がゼロ。採用。

**性質。**

- 初回同期（`lastSyncAt == null`）は競合ゼロ。合意点が無いので「両側で変えた」が定義できない。`purgedBefore` の初回免除と同じ考え方。
- 同期直後に両側が持つのは同一の勝者なので `contentHash` が一致し、次回は競合にならない（エコーバックによる偽陽性は起きない）。
- 両側で偶然まったく同じ編集をした場合も内容一致で競合にならない。
- 端末の壁時計が遅れていると `updatedAt` が古く見えて検出漏れになる。そこで `changedAt` に `clock.physical` を混ぜ（HLC は端末内で単調）、比較は `>=` にして **過検出側に倒す**。検出漏れは「敗者が記録されず本当に消える」が、過検出は「一覧に 1 件余分に出る（『現状のまま』で閉じられる）」だけで、非対称に検出漏れの方が痛い。
- `taskMaster.settings` は id を持たないので `entityId = "settings"`、`entityType = "settings"` として扱う。
- 削除 vs 編集（片側が墓標）は最も価値のある競合で、内容差の条件で自然に拾える。

### C-2. データ形状

ドキュメント直下（`taskMaster` / `dailyPlan` の兄弟）に置く。

```json
{
  "version": 2,
  "conflicts": [
    {
      "id": "cf-9a3f1c2b7d4e5061",
      "entityType": "task",
      "entityId": "tsk-1757370000000000-a1b2-0c3d4e",
      "detectedAt": "2026-09-09T02:11:04.000Z",
      "detectedBy": "hub-macos",
      "winner": {
        "side": "hub",
        "deviceId": "hub-macos",
        "clock": "1757369000000-0-hub-macos",
        "updatedAt": "2026-09-09T01:23:20.000Z",
        "snapshot": { "id": "tsk-…", "title": "確定申告の書類を集める", "kind": "must_do", "priority": 3, "categoryId": "must-admin", "estimatedMinutes": 60, "memo": null, "createdAt": "…", "clock": "…", "updatedAt": "…", "deletedAt": null, "migrated": false }
      },
      "loser": {
        "side": "device",
        "deviceId": "android-3f2a…",
        "clock": "1757368000000-2-android-3f2a…",
        "updatedAt": "2026-09-09T01:06:40.000Z",
        "snapshot": { "id": "tsk-…", "title": "確定申告（領収書だけ先に）", "…": "…" }
      },
      "resolution": null,
      "resolvedAt": null,
      "resolvedBy": null,
      "clock": "1757370664000-0-hub-macos",
      "updatedAt": "2026-09-09T02:11:04.000Z",
      "deletedAt": null,
      "migrated": false
    }
  ]
}
```

- `side`: `"hub"` = 検出時にハブ（＝マージ引数 A）側だった版、`"device"` = 受信文書（引数 B）側だった版。UI は `deviceId` から「PC（MCP）」「Pixel 8」「このブラウザ」を引いて表示する。
- 墓標の版は `snapshot` が `{ "id": …, "clock": …, "updatedAt": …, "deletedAt": "…" }` だけになる（既存の墓標形と同じ）。UI は「削除済み」と描く。
- レコード自身が `clock` / `updatedAt` / `deletedAt` / `migrated` を持つ ＝ 普通のエンティティとして既存のマージ規則に乗る。
- **id は決定的**: `"cf-" + sha256(entityId + "\n" + winner.clock + "\n" + loser.clock).slice(0, 16)`。同じ競合を Dart と TS が別々に検出しても同じ id になり、再検出は冪等（既に同 id があれば何もしない）。共有フィクスチャで期待結果を固定できるのもこれが理由。

**なぜ埋め込みで、`conflicts.json` ではないか。** 競合はスマホでも解決できなければならず、スマホに届く経路はドキュメントしか無い（LAN・QR・ファイルの全部）。埋め込みなら追加のエンドポイントもプロトコルも要らず、両 UI が同じ一覧を見る。

**大きさと掃除。** 1 件は 2 スナップショット分（タスクなら約 1 KB）。

- 上限: 未解決 1000 件（超えたら最古の未解決を落とし、`warnings` に `conflict_overflow` を出す）、解決済みは最新 200 件のみ保持。
- TTL: 解決済みは `resolvedAt` から 30 日で墓標化し、`purge_tombstones` の既存カットオフ（全端末の最小 `lastSyncAt` − 24h）で物理削除する。`conflicts` を purge の対象リストに追加する。

### C-3. マージ時の挙動

- エンティティのマージ規則は **変えない**。HLC の勝者を暫定採用し、同期は完了する（決定事項 3）。
- 検出は共有マージャの中。API を両言語で揃える:
  - Dart: `SyncMerger.merge(SyncDocument a, SyncDocument b, {DateTime? lastAgreedAt, String? detectedBy, DateTime? detectedAt})`
  - TS: `merge(a: SyncDocumentJson, b: SyncDocumentJson, options?: { lastAgreedAt?: string | null; detectedBy?: string; detectedAt?: string }): MergeResult`
  - 既定は `lastAgreedAt: null` ＝ 検出しない。既存の呼び出し（フィクスチャ、property test）はそのまま通る。
- `MergeResult` に `conflicts: ConflictRecord[]`（今回新たに検出した分）を足す。文書側の `conflicts` は「既存の和集合 ＋ 新規」。
- `SyncEngine.sync` は `mode === 'merge'` のとき `lastAgreedAt = incoming.lastSyncAt`、`detectedBy = hub deviceId`、`detectedAt = at` を渡す。
- `SyncSummary` に `conflicts: number` を追加（TS `sync-engine.ts` の `SyncSummary`、Dart `sync_progress.dart` の `SyncSummary`。`fromJson` は既存フィールドと同じく `?? 0`）。
- `warnings` には `conflict: <entityType> <entityId>` を **入れない**。`warnings.length` が `summary.warnings` になっており、競合を混ぜると「警告 N 件」の意味が変わるため。代わりに応答直下に `conflicts` を返し、UI は `summary.conflicts` で件数を出す。
- **競合レコード同士のマージ**: id で和集合。両側にあれば通常どおり `clock` の大きい方を採る。解決は `clock` を進めるので「後から行われた解決が勝つ」（決定事項どおり）。
- **置き換えモードの例外**: `take_hub` はハブの文書をそのまま返すので問題ない。`take_phone` / `take_web` は受信文書をそのまま保存する実装なので、そのままだとハブ側の `conflicts` が消える。`conflicts` だけは **常に和集合** にする（`merged.conflicts = union(current.conflicts, incoming.conflicts)`）。データを置き換えても「何が競合していたか」の記録は残す。
- **陳腐化した競合の自動解決**: マージ後の生きているエンティティの `clock` が `winner.clock` と `loser.clock` の両方より大きい場合、その後の編集が両方を上書きしている。`resolution: "superseded"`、`resolvedAt` を入れて一覧から隠す（ユーザーの操作は要らない）。

---

## D. 競合解決の段階（Plan 3b・ツールと UI）

### D-1. MCP ツール（4 個追加、39 → 43）

```
list_conflicts({ status?: 'open' | 'resolved' | 'all', entityType?: string, limit?: number })
  → { open: number, resolved: number, conflicts: [{ id, entityType, entityId, label, detectedAt, resolution }] }

get_conflict({ id })
  → { conflict: ConflictRecord,
      differences: [{ field, hub, device }],   // 値が異なるフィールドだけ
      current: { clock, deletedAt, supersedes: boolean } }  // 今 data.json に入っている版

resolve_conflict({ id, adopt: 'hub' | 'device' | 'current' })
  → { id, adopted, wrote: boolean, summary }

resolve_all_conflicts({ adopt: 'hub' | 'device' | 'current', entityType?: string, dryRun?: boolean })
  → { resolved: number, skipped: number, results: [{ id, adopted, wrote }] }
```

`resolve_conflict` の動作:

1. 採用する側のスナップショットが既に生きている版と同一なら、書き込みはせず `resolution` だけ立てる。
2. 異なるなら、そのスナップショットを **新しい編集として書き戻す**。id は据え置き、`clock = clock.next()`（ハブの HLC）、`updatedAt = now`、`migrated = false`。墓標を採用する場合は再削除になる。新しい clock なので、通常のマージでスマホにも Web にも伝播する。
3. `resolution` / `resolvedAt` / `resolvedBy` を書き、レコード自身の `clock` も進める。
4. 全部 `FileStore.update` の 1 ロック内。`resolve_all_conflicts` は 1 回の書き込みでまとめて適用する（1 件でも失敗したら何も書かない）。

`adopt: 'current'` は「今の状態のまま閉じる」。過検出を畳むための出口。

`README.md` と `docs/tool-coverage.md` にツール表を追記する。

### D-2. スマホ UI

- `SyncProgressPanel`: 完了行の「追加 n / 更新 n / 削除 n / 消去 n / 警告 n」に **「競合 n 件」** を足し、n > 0 なら「確認する」ボタンを出す。押すと競合一覧へ。同期自体は成功として閉じる（決定事項 3）。
- 導線は同期直後だけにしない。「PC と同期」画面に「競合 n 件」の行を常設し、未解決があればバッジを出す。
- `ConflictListScreen`（`/sync/conflicts`）: 未解決を上に、解決済みは折りたたみ。行は「タスク『確定申告の書類を集める』」＋ 検出時刻＋ 現在採用中の側。上部に一括ボタン「すべて PC 版を採用」「すべてスマホ版を採用」（`confirmAction` で確認）。
- `ConflictDetailScreen`: 二列の対比表（左「PC 版」／右「スマホ版」）。差のあるフィールドだけ強調し、同じフィールドは薄く出す。片側が削除なら「削除済み」と大きく描く。ボタンは「PC 版を採用」「スマホ版を採用」「現状のまま」。
- 解決はこの端末のローカル編集として書く（`DeviceClock.next()` で新しい clock）。次の同期で PC に伝播する。オフラインでも解決できる。

### D-3. Web UI（hub モード）

同じ `ConflictListScreen` / `ConflictDetailScreen` をそのまま使う（純 Flutter で、プラットフォーム固有コードを含まない）。hub モードでは解決の書き込みが `HubBackedStore` 経由の `POST /api/sync` になるだけで、画面は共通。ラベルは「PC（MCP）版」／「この端末の版」を `deviceId` から出し分ける。アプリバーに未解決件数のバッジ。

### D-4. ハブのローカルページ

`/<secret>/conflicts` の読み取り専用ページは **作らない**。同一オリジンの Web 版が同じ画面を持つので重複であり、ローカルページは「ペアリング QR とデータ QR」という用途に絞ったままにする（未決事項 4 で再確認）。

### D-5. 不変な性質

- 未解決の競合は同期を **止めない**。同期は常に完了する。
- 未解決の競合は同期をまたいで残る（普通のエンティティなので）。
- 両側が別々に解決してから同期した場合、競合レコードは `clock` の大きい方＝後の解決が勝ち、エンティティ本体もその解決が書いた clock の方が大きいので、記録と実体が一致する。
- 解決後にどちらかで再編集し、また両側で変えたら、clock が変わるので **新しい id の競合** が立つ（同じ競合が復活するのではない）。

---

## E. 互換性

- **スキーマ版は 2 のまま**。`conflicts` は任意フィールドで、無ければ空配列とみなす。古いアプリ（Plan 2b ビルド）は `SyncDocument.fromJson` で未知キーを読み飛ばし、往復で落とす。ハブ側は `conflicts` を常に和集合で扱うので、**ハブの記録は消えない**。古いアプリでは画面に出ないだけで、アプリを更新すれば次の同期で全件見える。この非対称を許容する（版を 3 に上げて 426 で古いアプリを止める方が害が大きい）。
- **zod（TS）**:

```ts
const sideSchema = z.object({
  side: z.enum(['hub', 'device']),
  deviceId: z.string(),
  clock: z.string(),
  updatedAt: z.string(),
  snapshot: z.object({ id: z.string() }).passthrough(),
}).passthrough();

const conflictSchema = z.object({
  id: z.string(),
  entityType: z.string(),      // 未知の型も保持する（前方互換）。描画側で無視する
  entityId: z.string(),
  detectedAt: z.string(),
  detectedBy: z.string().optional(),
  winner: sideSchema,
  loser: sideSchema,
  resolution: z.enum(['hub', 'device', 'current', 'superseded']).nullish(),
  resolvedAt: z.string().nullish(),
  resolvedBy: z.string().nullish(),
  clock: z.string(),
  updatedAt: z.string(),
  deletedAt: z.string().nullish(),
  migrated: z.boolean().optional(),
}).passthrough();

// documentSchema に追加
conflicts: z.array(conflictSchema).optional(),
```

- **Dart `fromJson`**: `ConflictRecord.fromJson(json, {strict})`。`strict` では `id` / `entityId` / `winner` / `loser` / `clock` の型不一致を `FormatException`。`entityType` と `resolution` は未知値でも受け（そのまま保持し、UI で「不明な種別」として読み取り専用に描く）、未知キーは既存の `extra` 方式で保持する。`toJson` は `conflicts` が空なら **キーごと出さない**（古いハブや古いアプリとの差分を無用に増やさない）。
- **共有フィクスチャ**: `test/fixtures/sync_merge/` にケースを追加し、`manifest.json` に登録する。ケース JSON に任意の `"options": { "lastAgreedAt": "…", "detectedBy": "…", "detectedAt": "…" }` を足し、両言語のランナーがこれを読んでマージ引数にする（無ければ従来どおり検出なし）。

| ファイル | 検証すること |
|---|---|
| `09_conflict_both_changed.json` | 両側変更で 1 件立つ。id が決定的 |
| `10_conflict_one_side_only.json` | 片側だけ変更 → 競合ゼロ（勝者はそのまま） |
| `11_conflict_delete_vs_edit.json` | 墓標 vs 編集で 1 件。`loser.snapshot` が墓標形 |
| `12_conflict_before_last_sync.json` | 両側とも `lastSyncAt` より古い → 競合ゼロ |
| `13_conflict_no_last_sync.json` | `lastAgreedAt` null（初回同期）→ 競合ゼロ |
| `14_conflict_records_union.json` | 既存の競合レコード同士が id で和集合、解決済みが勝つ |
| `15_conflict_settings.json` | `settings` の競合（`entityId: "settings"`） |
| `16_conflict_superseded.json` | 後の編集が両版を上書き → `superseded` |

- **パリティテスト**: 上記フィクスチャを `flutter test` と `vitest` の両方が読み、**競合 id まで一致** することを確認する（決定的 id にした効果をここで実証する）。加えて B-2 の id 和集合の不変条件を全フィクスチャに適用する。

---

## F. 実装計画の分割

### Plan 3a: ハブ上の Web 版

Play ストアへの影響: **無し**。アプリの挙動は変わらない（hub モードは `__FRELOCATOR_HUB__` が無ければ死んでいる分岐）。Android ビルドに入るのは stub 側だけであることを確認する。

タスク:

1. `tools/hub/scripts/build-web.mjs` と `npm run build:web`。`BUILD_INFO.json` の生成、`.git/info/exclude` への `tools/hub/web-dist/` 追記。
2. `tools/hub/src/static-server.ts`: パス検査、MIME、ETag / 304、SPA フォールバック、`index.html` の `<base>` と `__FRELOCATOR_HUB__` 注入。
3. `LocalPages` にルート追加と `guard()` の緩和（POST 許可・`Origin` 完全一致・`Content-Type` 必須・`X-FRELOCATOR-Web-Id` 必須）。`sync_status` に `webApp: { url, built, stale }` を追加。
4. `tools/hub/src/web-api.ts`: `/api/document`、`/api/revision`、`/api/sync`。`SyncEngine` 再利用、20 MB 上限、`webClients` の記録。
5. Flutter 側: `lib/services/hub_mode/{hub_mode,hub_mode_web,hub_mode_stub}.dart`、`lib/services/storage/hub_backed_store.dart`（＋ web 実装）、`stateStoreProvider` の分岐、hub モードの UI 調整（LAN 系を隠す・保存先表示・未保存バナー）。
6. ドキュメント: `tools/hub/README.md`（起動手順と URL の取り方）、`docs/web_release_checklist.md`（公開 Web 版は無変更である旨）。

テスト戦略:

- vitest: パストラバーサル（`..`、`%2e%2e`、シンボリックリンク）、404 / 503（`web-dist` 欠落）、ETag と 304、SPA フォールバック、`<base>` 注入結果、ガード（`Host` / `Origin` / `Sec-Fetch-Site` / `Content-Type` / web-id 欠落の各 403）、`/api/sync` が LAN `/sync` と同じ応答形になること。
- 往復: MCP `add_task` → `GET /api/document` に出る／`POST /api/sync` → MCP `list_tasks` に出る、を stdio スモークで 1 本。
- Dart: hub モード判定（stub は常に `none`）、`HubBackedStore` のデバウンス・single-flight・失敗時のバナー状態、`changedSinceLastRead` の連動。
- 手動: Chrome と Safari で `http://127.0.0.1:47821/<secret>/app` を開き、MCP 編集がポーリングで反映されること、ブラウザ編集がスマホの同期に出ること（ユーザー規約の cross-browser 確認）。`flutter build web` が引き続き成功すること。

リスク:

- `web-dist` が古いまま配られる → `BUILD_INFO.json` の git rev と `sync_status` の `stale` 表示で検知。
- Service Worker のキャッシュ → `--pwa-strategy=none`。
- CanvasKit / フォントの CDN 取得 → `--no-web-resources-cdn`。
- `web-dist/` のサイズ（数 MB）が作業ツリーに乗る → git 管理外にする。
- 秘密プレフィックスがブラウザ履歴に残る → ハブ再起動で無効化される旨を README に書く。

### Plan 3b: 競合の記録と解決

Play ストアへの影響: **有り**（アプリの挙動が変わる）。リリースノート例: 「PC と同期したときに、同じ項目を両方で編集していた場合は『競合』として記録し、あとからどちらを採用するか選べるようになりました。同期そのものは今までどおり完了します。」データセーフティは「収集なし」のまま変更なし。

タスク:

1. モデルと解析: TS `ConflictJson` ＋ zod、Dart `ConflictRecord`、`SyncDocument` の `conflicts` 往復、`toJson` の空配列省略。
2. 検出を共有マージャへ: Dart / TS の `merge` に `lastAgreedAt` 系オプション、決定的 id、和集合、上限と TTL、`purge_tombstones` の対象追加、`superseded` 判定。
3. 共有フィクスチャ 8 本＋ `options` 対応のランナー拡張、パリティテスト、id 和集合の不変条件（B-2）。
4. `SyncEngine` 配線: `summary.conflicts`、応答の `conflicts`、置き換えモードでの `conflicts` 和集合、`/sync` と `/api/sync` の応答形。
5. MCP ツール 4 個 ＋ `README.md` / `docs/tool-coverage.md` 更新（39 → 43）。
6. スマホ UI: `SyncSummary.conflicts`、進捗パネルの「競合 n 件」、`ConflictListScreen` / `ConflictDetailScreen`、一括解決、設定画面のバッジ、ルート追加。
7. Web UI（hub モード）: 同じ画面の有効化、ラベルの出し分け、アプリバーのバッジ。
8. リリース: バージョン更新、リリースノート、`flutter analyze && flutter test && flutter build appbundle && flutter build macos && flutter build web`。

テスト戦略:

- 検出の表: 両側変更 / 片側のみ / 同一編集 / 削除 vs 編集 / `lastSyncAt` より前 / `lastSyncAt` null / 時計逆行（`clock.physical` 補正が効く）/ `settings`。
- 解決: 採用側が既に生きていれば書き込み無し、異なれば厳密に大きい clock で書き戻る、墓標採用で再削除、`resolve_all` が全か無かであること。
- 収束の property test 拡張: ランダム操作列に「ランダムな解決」を混ぜ、任意順で 3 回同期して両端のエンティティと `conflicts` が一致すること（Dart / TS 双方）。
- 互換: `conflicts` を持たない v2 文書の往復、未知 `entityType` / 未知 `resolution` の保持、`take_phone` 後もハブの `conflicts` が残ること。
- widget テスト: 一覧・詳細の描画と 3 ボタンの動作、進捗パネルの「競合 n 件」表示。
- MCP stdio スモーク: 競合を作る → `list_conflicts` → `get_conflict` → `resolve_conflict` → 反映確認。

リスク:

- 過検出でノイズになる → 内容差を必須条件にし、`superseded` の自動解決と「現状のまま」「一括」で畳めるようにした。
- ドキュメント肥大 → 上限と TTL、purge 統合。
- 古いアプリが `conflicts` を落とす → ハブ側で和集合にして守る（E 節）。
- Dart / TS で検出結果が割れる → 決定的 id と共有フィクスチャの id 一致テストで固定。

---

## 未決事項（オーナー確認）

1. **hub モードの Web にローカルの控えを持たせるか。** 推奨: **持たない**（ライブ編集のみ）。二つの真実を作らないため。未送信の編集はリロードで失われるので、赤帯の再送バナーと `beforeunload` 警告で埋める。「ブラウザを閉じてもオフラインで続きを書きたい」なら方針を変える必要がある。
2. **競合検出のしきい値。** 推奨: **過検出寄り**（`changedAt = max(updatedAt, clock.physical)`、比較は `>=`）。検出漏れは敗者版が本当に消えるのに対し、過検出は一覧に 1 行余るだけ。逆に「余計な競合が出るのが嫌」なら比較を `>` にして少し漏らす選択もある。
3. **`conflicts` の上限と TTL。** 推奨: 未解決 1000 件 / 解決済み 200 件、解決済みは 30 日で墓標化して既存の purge に乗せる。実運用（PC 1 台＋スマホ 1 台）では上限に触らない想定。
4. **ハブのローカルページに競合一覧を出すか。** 推奨: **出さない**（D-4）。同一オリジンの Web 版が同じ画面を持つため。MCP だけで完結させたい場面が多いなら `list_conflicts` の出力を整形するだけで足りる。
5. **Web の擬似端末を purge のカットオフ計算に入れるか。** 推奨: **入れない**（A-6）。永続ストアを持たないので取り残される概念が無く、入れると「ブラウザを開かない期間」で purge が止まる。表示用の `webClients` に留め、`forget_device` で消せるようにする。

---

## 参考ファイル

- `docs/superpowers/specs/2026-09-08-frelocator-hub-sync-design.md` — HLC・墓標・マージ規則・`purgedBefore`・LAN プロトコルの原設計。
- `docs/superpowers/plans/2026-09-08-hub-sync-plan-1-schema-merge-hub.md` — スキーマ v2 とマージ実装。
- `docs/superpowers/plans/2026-09-08-hub-sync-plan-2a-hub-lan.md` — LAN サーバー・`SyncEngine`・ローカルページ。
- `docs/superpowers/plans/2026-09-08-hub-sync-plan-2b-app-sync.md` — アプリ側同期 UI、レビュー反映（C1/I1〜I12、batch 3/4）。
- `tools/hub/src/merge.ts` / `lib/services/sync/sync_merger.dart` — 競合検出を足す共有マージャ。
- `tools/hub/src/sync-engine.ts` — `/sync` 本体、`summary`、`purge`、`purgedBefore` ガード。
- `tools/hub/src/model.ts` / `tools/hub/src/hlc.ts` — 文書とメタの型、HLC。
- `tools/hub/src/local-pages.ts` — 秘密プレフィックス、`guard()`、静的ページの型。
- `tools/hub/src/tools.ts` — MCP ツール（`import_data mode='replace'` の写像を含む）。
- `tools/hub/README.md` / `tools/hub/docs/tool-coverage.md` — ツール一覧と網羅監査。
- `lib/services/sync/sync_service.dart` / `sync_progress.dart` / `sync_document.dart` — 同期の流れ、進捗と `SyncSummary`、v2 エンベロープ。
- `lib/services/storage/state_store.dart` / `prefs_state_store.dart` / `file_backed_store.dart` — 保存層の抽象と 2 実装。
- `lib/services/sync/{lan_sync_client,hub_discovery,file_exporter}_stub.dart` — Web 用 stub の既存パターン（hub モードの条件付きエクスポートもこれに倣う）。
- `test/fixtures/sync_merge/` — Dart / TS 共有フィクスチャと `manifest.json`。
- `docs/web_release_checklist.md` / `docs/distribution_release_prep.md` — 公開 Web 版（`app.frelocator.riumu.net`）の手順。Plan 3 では変更しない。
