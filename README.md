# Frelocator

Frelocator is a Flutter mobile app for managing free time slots, task planning, and weekly summaries with local storage.

## Current Scope

The current MVP includes:

- `TaskMaster` CRUD
- category settings with shared / separate mode
- `DailyPlan`, `FreeTimeSlot`, and `SlotTaskAssignment`
- plan duplication by day, slot, and assignment
- drag-and-drop reassignment inside and across slots
- weekly report with period switching

Data is stored locally with `shared_preferences`. There is no cloud sync, notification, or external calendar integration yet.

## Tech Stack

- `Flutter`
- `flutter_riverpod`
- `go_router`
- `shared_preferences`
- `intl`

Main code lives under `lib/features/`:

- `task_master/`
- `daily_plan/`
- `weekly_report/`

Project notes and implementation references live under `docs/`.

## Getting Started

```bash
flutter pub get
flutter run
```

Useful commands:

```bash
flutter analyze
flutter test
dart format lib test
```

## Key Documents

- `docs/flutter_development_flow.md`
- `docs/flutter_onboarding_for_fullstack_developer.md`
- `docs/debug_flow.md`
- `docs/feature_checklist.md`

## Notes

- Default branch is `main`.
- `AGENTS.md` is excluded from version control.
- This repository may be made public later, so avoid committing secrets, private identifiers, or environment-specific sensitive data.
