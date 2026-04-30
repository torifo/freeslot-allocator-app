# FRELOCATOR

FRELOCATOR is a Flutter app for planning free time with three connected layers:

- `TaskMaster` for maintaining tasks you want or need to do
- `DailyPlan` for assigning those tasks into actual free-time slots
- `WeeklyReport` for reviewing how time was allocated during a week

The app is currently designed as a local-first personal planning tool. Data is stored on the device with `shared_preferences`. There is no cloud sync, notification delivery, or external calendar integration yet.

## What This App Is For

FRELOCATOR is aimed at people who want to:

- manage a backlog of personal tasks
- split tasks into `やるべきこと / やりたいこと`
- reserve concrete time blocks for those tasks
- duplicate planning patterns across days
- review weekly allocation results without leaving the app

## Current Implementation Status

The current implementation already includes the core planning loop.

### Implemented screens

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

### Current constraints

- local storage only
- no account system
- no push notifications
- no Google login
- no backend API

## Supported Targets

The repository is currently being verified for:

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

Build release artifacts:

```bash
flutter build macos
flutter build web
flutter build apk --release
flutter build appbundle
```

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

## Release Notes

Current release-related status:

- Android package ID: `net.riumu.frelocator`
- macOS bundle ID: `net.riumu.frelocator`
- Web target prepared for `app.frelocator.riumu.net`
- Android release signing is wired through local `android/key.properties`

## Repository Notes

- Default branch is `main`
- This repository is private for now, but should be kept safe for future publication
- Do not commit keystores, passwords, personal schedules, or environment-specific secrets
