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

タスク・カテゴリ・日次計画の CRUD、`copy_daily_plan`、`weekly_report`、`export_data`、`undo_last_write`、`sync_status` の 26 個。
`import_file` / `purge_tombstones` / `forget_device` / `rotate_token` はスキーマだけ定義済みで、呼ぶと「Plan 2 で提供」というエラーを返す。

日付引数（`date` / `from` / `to` / `weekStart` / `fromDate` / `toDate`）は `YYYY-MM-DD` で、ハブを動かしているマシンのローカルなカレンダー日を指す。`startAt` / `endAt` はオフセット付き ISO を受け取り、UTC ISO 文字列として保存する。

## 開発

- テスト: `npm test`（マージ規則と不変条件は `test/fixtures/sync_merge` を Flutter 側と共有）。
- 型検査: `npm run typecheck`（`tsconfig.test.json`。テストも含めて検査する）。
- stdio サーバーの疎通確認: `npm run smoke`（ビルドしてから実クライアントでツール一覧と `add_task` → `list_tasks` を往復する）。
