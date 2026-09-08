import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:frelocator/core/device_clock.dart';

/// Builds a container with a real [DeviceClock] backed by the mocked
/// SharedPreferences, so controllers can stamp HLCs in tests.
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
      ...overrides,
    ],
  );
}
