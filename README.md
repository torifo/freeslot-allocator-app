# FRELOCATOR

FRELOCATOR is a local-first Flutter planner for turning personal free time into concrete, reviewable plans.

FRELOCATOR は、個人の自由時間を具体的な計画に落とし込み、あとから振り返れる形にするためのローカルファーストな Flutter アプリです。

It is built around three connected layers:

- `TaskMaster` for maintaining tasks you want or need to do
- `DailyPlan` for assigning those tasks into actual free-time slots
- `WeeklyReport` for reviewing how time was allocated during a week

3 つの画面レイヤーを中心に構成しています。

- `TaskMaster`
  やりたいこと・やるべきことのタスク管理
- `DailyPlan`
  自由時間枠にタスクを割り当てる日次計画
- `WeeklyReport`
  1 週間の時間配分を振り返るレポート

The app currently stores data on the device with `shared_preferences`. There is no cloud sync, notification delivery, account system, or external calendar integration yet.

現在のデータ保存は `shared_preferences` による端末内保存です。Cloud sync、通知配信、アカウント機能、外部カレンダー連携はまだ実装していません。

## Current Status

The core planning loop is implemented and release builds are being checked for:

- `macOS`
- `Web`
- `Android`

コアとなる計画フローは実装済みで、現在は次の 3 プラットフォーム向けにリリース確認を進めています。

- `macOS`
- `Web`
- `Android`

Recent local verification has covered:

- `flutter analyze`
- `flutter test`
- `flutter build macos`
- `flutter build web`
- `flutter build apk --release`
- `flutter build appbundle`

直近では以下の確認を通しています。

- `flutter analyze`
- `flutter test`
- `flutter build macos`
- `flutter build web`
- `flutter build apk --release`
- `flutter build appbundle`

## What This App Is For

FRELOCATOR is aimed at people who want to:

- manage a backlog of personal tasks
- split tasks into `やるべきこと / やりたいこと`
- reserve concrete time blocks for those tasks
- duplicate planning patterns across days
- review weekly allocation results without leaving the app

このアプリは、次のような人を想定しています。

- 個人タスクの backlog を整理したい
- `やるべきこと / やりたいこと` を分けて管理したい
- タスクを実際の自由時間に割り当てたい
- 日ごとの計画パターンを別日に複製したい
- 週単位で時間の使い方を振り返りたい

## Current Implementation Status

The current implementation already includes the core planning loop.

現在の実装には、計画の作成から振り返りまでの基本フローが含まれています。

### Implemented screens

- Home dashboard
- TaskMaster
- Category settings
- DailyPlan
- WeeklyReport

実装済み画面:

- Home dashboard
- TaskMaster
- Category settings
- DailyPlan
- WeeklyReport

### Implemented features

- task CRUD
- category CRUD
- shared / separate category mode
- daily plan creation by date
- free-time slot CRUD
- cross-midnight slot support
- assignment CRUD inside a slot
- overlap validation for slots and assignments
- drag-and-drop reassignment within and across slots
- duplication by day, slot, and assignment
- weekly aggregation with previous / current / next week switching
- local persistence with `shared_preferences`

主な実装済み機能:

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

### Current constraints

- local storage only
- no account system
- no push notifications
- no Google login
- no backend API

現在の制約:

- ローカル保存のみ
- アカウント機能なし
- Push 通知なし
- Google ログインなし
- バックエンド API なし

## Tech Stack

- `Flutter`
- `flutter_riverpod`
- `go_router`
- `shared_preferences`
- `intl`

Main application code lives under `lib/features/`:

- `home/`
- `task_master/`
- `daily_plan/`
- `weekly_report/`

Routing is currently centered around these screens:

- `/`
- `/tasks`
- `/categories`
- `/daily-plan`
- `/weekly-report`

主なルーティング:

- `/`
- `/tasks`
- `/categories`
- `/daily-plan`
- `/weekly-report`

## Project Structure

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

Flutter scaffold folders for `ios/`, `linux/`, and `windows/` also exist, but the main verification focus is currently macOS, Web, and Android.

`ios/`, `linux/`, `windows/` も scaffold として存在しますが、現在の主な検証対象は `macOS / Web / Android` です。

## Getting Started

Install dependencies:

```bash
flutter pub get
```

Run general checks:

```bash
flutter analyze
flutter test
```

Run by platform:

```bash
flutter run -d macos
flutter run -d chrome
flutter run -d <android_device_id>
```

Alternative web debug flow when Chrome integration is unstable:

```bash
flutter run -d web-server --web-hostname=127.0.0.1 --web-port=8080
```

Build release artifacts:

```bash
flutter build macos
flutter build web
flutter build apk --release
flutter build appbundle
```

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

## 日本語メモ

- Chrome 連携が不安定な時は `web-server` 経由でも確認できます
- Android の release 署名はローカルの `android/key.properties` を使います
- Web の公開対象ドメインは `app.frelocator.riumu.net` です

## Debug and Verification

Use these documents depending on the task:

- [docs/debug_flow.md](docs/debug_flow.md)
  Daily debugging workflow
- [docs/feature_checklist.md](docs/feature_checklist.md)
  Functional verification checklist
- [docs/platform_debug_checklist.md](docs/platform_debug_checklist.md)
  How to launch and verify macOS / Web / Android
- [docs/web_release_checklist.md](docs/web_release_checklist.md)
  Web release preparation
- [docs/android_release_signing.md](docs/android_release_signing.md)
  Android signing and release notes
- [docs/troubleshooting_flutter_web_chrome.md](docs/troubleshooting_flutter_web_chrome.md)
  Chrome / Flutter web troubleshooting

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

## Release Notes

Current release-related status:

- Android package ID: `net.riumu.frelocator`
- macOS bundle ID: `net.riumu.frelocator`
- Web target prepared for `app.frelocator.riumu.net`
- Android release signing is wired through local `android/key.properties`

Public web support pages prepared in the repository:

- `/privacy.html`
- `/support.html`

配布準備メモ:

- Android package ID: `net.riumu.frelocator`
- macOS bundle ID: `net.riumu.frelocator`
- Web target: `app.frelocator.riumu.net`
- Android release signing はローカル `android/key.properties` で設定
- Web サポートページ:
  - `/privacy.html`
  - `/support.html`

## Repository Notes

- Default branch is `main`
- This repository is private for now, but should be kept safe for future publication
- Do not commit keystores, passwords, personal schedules, or environment-specific secrets

リポジトリ運用メモ:

- デフォルトブランチは `main`
- 現在は private repository 前提
- keystore、パスワード、個人スケジュール、環境依存の秘密情報はコミットしない
