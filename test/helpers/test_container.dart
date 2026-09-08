import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:frelocator/core/device_clock.dart';
import 'package:frelocator/features/task_master/data/task_master_repository.dart'
    show stateStoreProvider;
import 'package:frelocator/services/storage/prefs_state_store.dart';

/// Builds a container with a real [DeviceClock] backed by the mocked
/// SharedPreferences, so controllers can stamp HLCs in tests.
///
/// [stateStoreProvider] defaults to a [PrefsStateStore] here regardless of
/// host platform: `flutter test` runs on the developer's machine, where
/// `Platform.isMacOS` is true, and the app's own default would otherwise
/// point tests at the real `~/Library/Application Support/FRELOCATOR/`
/// directory instead of the mocked SharedPreferences. Pass an explicit
/// `stateStoreProvider` (or `taskMasterRepositoryProvider` /
/// `dailyPlanRepositoryProvider`) override to opt out.
///
/// Call `SharedPreferences.setMockInitialValues` before this.
Future<ProviderContainer> testContainer({
  List<Override> overrides = const <Override>[],
  int Function()? now,
}) async {
  final clock = await DeviceClock.load(platformPrefix: 'test', now: now);
  return ProviderContainer(
    overrides: <Override>[
      deviceClockProvider.overrideWithValue(clock),
      stateStoreProvider.overrideWithValue(PrefsStateStore()),
      ...overrides,
    ],
  );
}
