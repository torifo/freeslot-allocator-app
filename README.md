# FRELOCATOR

FRELOCATOR は、個人の自由時間を具体的な計画に落とし込み、あとから振り返れる形にするためのローカルファーストな Flutter アプリです。

アプリは 3 つの画面レイヤーを中心に構成しています。

- `TaskMaster`
  やりたいこと・やるべきことのタスク管理
- `DailyPlan`
  自由時間枠にタスクを割り当てる日次計画
- `WeeklyReport`
  1 週間の時間配分を振り返るレポート

現在のデータ保存は `shared_preferences` による端末内保存です。Cloud sync、通知配信、アカウント機能、外部カレンダー連携はまだ実装していません。

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
- Push 通知なし
- Google ログインなし
- バックエンド API なし

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
