# FRELOCATOR

<!-- tech-stack:start (auto-generated) -->
<p align="center">
  <img src="https://img.shields.io/badge/Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white" alt="Flutter">
  <img src="https://img.shields.io/badge/Dart-0175C2?style=for-the-badge&logo=dart&logoColor=white" alt="Dart">
</p>
<!-- tech-stack:end -->

FRELOCATOR は、個人の自由時間を具体的な計画に落とし込み、あとから振り返れる形にするためのローカルファーストな Flutter アプリです。

アプリは 3 つの画面レイヤーを中心に構成しています。

- `TaskMaster`
  やりたいこと・やるべきことのタスク管理
- `DailyPlan`
  自由時間枠にタスクを割り当てる日次計画
- `WeeklyReport`
  1 週間の時間配分を振り返るレポート

データ保存は端末内のみです（Android / Web は `shared_preferences`、macOS は `~/Library/Application Support/FRELOCATOR/data.json`）。macOS の JSON は `tools/hub`（Claude Code 向け MCP サーバー）と共有され、PC 上では Claude からタスクや計画を編集できます。端末間の同期（LAN / QR）は `docs/superpowers/specs/2026-09-08-frelocator-hub-sync-design.md` に沿って実装中です。Cloud sync、通知配信、アカウント機能、外部カレンダー連携はまだ実装していません。

### PC と同期

Android 版の設定画面から「PC と同期」を有効にすると、Claude Code で `tools/hub`（frelocator-hub）を起動している PC（macOS）と、第三者サーバーを経由せずにデータを連携できます。

- LAN 同期: PC とスマホが同じ Wi-Fi 上にあれば、ペアリング後は「同期」操作 1 回で双方の変更を HLC ベースでマージします。通信は自己署名 TLS で、証明書フィンガープリントをペアリング時にピン留めします。
- QR: ネットワークが分かれている場合、PC 側のローカルページ（`http://127.0.0.1:47821/.../qr`）が表示する QR コマをスマホのカメラで読み取り、PC のデータを取り込めます。
- ファイル書き出し: スマホの「PC へ書き出す」で v2 JSON を共有シート経由でエクスポートし、PC 側は `import_file` ツール（または macOS 版アプリの「ファイルから取り込む」）で取り込みます。
- macOS の MCP 案内: `tools/hub` を Claude Code の MCP サーバーとして起動すると、`sync_status` ツールでペアリング用 QR ページや接続状況を確認できます。詳しくは [tools/hub/README.md](tools/hub/README.md) を参照してください。

## 現在の状況

コアとなる計画フローは実装済みで、現在は次の 3 プラットフォーム向けにリリース確認を進めています。

- `macOS`
- `Web`
- `Android`

直近では以下の確認を通しています。

- `flutter analyze`
- `flutter test`
- `flutter build macos`
- `flutter build web`
- `flutter build apk --release`
- `flutter build appbundle`

## このアプリの目的

このアプリは、次のような人を想定しています。

- 個人タスクの backlog を整理したい
- `やるべきこと / やりたいこと` を分けて管理したい
- タスクを実際の自由時間に割り当てたい
- 日ごとの計画パターンを別日に複製したい
- 週単位で時間の使い方を振り返りたい

## 実装状況

現在の実装には、計画の作成から振り返りまでの基本フローが含まれています。

### 実装済み画面

- Home dashboard
- TaskMaster
- Category settings
- DailyPlan
- WeeklyReport

### 主な実装済み機能

- タスク CRUD
- カテゴリ CRUD
- カテゴリの共通 / 分離モード
- 日付ごとの日次計画作成
- 自由時間枠 CRUD
- 日またぎ枠のサポート
- 枠内の予定 CRUD
- 枠と予定の重複バリデーション
- 枠内および枠間のドラッグ移動
- 日 / 枠 / 予定単位での複製
- 前週 / 今週 / 翌週を切り替える週次集計
- `shared_preferences` によるローカル保存

### 現在の制約

- ローカル保存のみ
- アカウント機能なし
- 通知機能は未実装
- Google ログインなし
- バックエンド API なし

### 今後の想定

- 通知機能は今後実装予定
- アカウント機能は作らない方針
- ただし、端末変更時のための引き継ぎ機能は追加したい

## 技術スタック

- `Flutter`
- `flutter_riverpod`
- `go_router`
- `shared_preferences`
- `intl`

メインのアプリケーションコードは `lib/features/` 以下にあります。

- `home/`
- `task_master/`
- `daily_plan/`
- `weekly_report/`

主なルーティング:

- `/`
- `/tasks`
- `/categories`
- `/daily-plan`
- `/weekly-report`

## プロジェクト構成

```text
lib/
  app/
  features/
    home/
    task_master/
    daily_plan/
    weekly_report/
docs/
test/
web/
android/
macos/
```

`ios/`, `linux/`, `windows/` も scaffold として存在しますが、現在の主な検証対象は `macOS / Web / Android` です。

## セットアップ

依存導入:

```bash
flutter pub get
```

基本確認:

```bash
flutter analyze
flutter test
```

プラットフォーム別起動:

```bash
flutter run -d macos
flutter run -d chrome
flutter run -d <android_device_id>
```

Chrome 連携が不安定な場合:

```bash
flutter run -d web-server --web-hostname=127.0.0.1 --web-port=8080
```

リリースビルド:

```bash
flutter build macos
flutter build web
flutter build apk --release
flutter build appbundle
```

## デバッグと確認

用途別ドキュメント:

- [docs/debug_flow.md](docs/debug_flow.md)
  日々のデバッグフロー
- [docs/feature_checklist.md](docs/feature_checklist.md)
  機能確認チェックリスト
- [docs/platform_debug_checklist.md](docs/platform_debug_checklist.md)
  macOS / Web / Android の起動と確認方法
- [docs/web_release_checklist.md](docs/web_release_checklist.md)
  Web 公開準備
- [docs/android_release_signing.md](docs/android_release_signing.md)
  Android 署名とリリースメモ
- [docs/troubleshooting_flutter_web_chrome.md](docs/troubleshooting_flutter_web_chrome.md)
  Flutter Web と Chrome のトラブルシュート
- [docs/distribution_release_prep.md](docs/distribution_release_prep.md)
  配布準備メモ
- [docs/android_store_assets_checklist.md](docs/android_store_assets_checklist.md)
  Android ストア素材チェックリスト

## 配布メモ

- Android package ID: `net.riumu.frelocator`
- macOS bundle ID: `net.riumu.frelocator`
- Web target: `app.frelocator.riumu.net`
- Android release signing はローカル `android/key.properties` で設定
- Web サポートページ:
  - `/privacy.html`
  - `/support.html`

## リポジトリ運用メモ

- デフォルトブランチは `main`
- 現在は private repository 前提
- keystore、パスワード、個人スケジュール、環境依存の秘密情報はコミットしない
