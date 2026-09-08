import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app/app.dart';
import 'core/device_clock.dart';

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  Intl.defaultLocale = 'ja';
  await initializeDateFormatting('ja');
  _lockPortraitOnPhones(binding);
  final deviceClock = await DeviceClock.load();
  runApp(
    ProviderScope(
      overrides: [deviceClockProvider.overrideWithValue(deviceClock)],
      child: const FrelocatorApp(),
    ),
  );
}

/// Phones stay upright; tablets and desktops may still turn.
///
/// Every screen here is one scrolling column built for a portrait phone, and
/// landscape on a handset leaves the hero card and the timeline fighting over
/// ~350 logical pixels of height. Above 600 dp on the short side the wide
/// layout (`_WideHome`) is worth having, so rotation is left alone there.
void _lockPortraitOnPhones(WidgetsBinding binding) {
  if (_applyPortraitLock(binding)) return;
  // No view, or a view that has not been measured yet: a `physicalSize` of
  // zero read as a 0 dp phone and locked a tablet to portrait (M-5). The first
  // frame is the point at which the size is real.
  binding.addPostFrameCallback((_) => _applyPortraitLock(binding));
}

/// Applies the lock when the screen size is known; false when it is not yet.
bool _applyPortraitLock(WidgetsBinding binding) {
  final dispatcher = binding.platformDispatcher;
  if (dispatcher.views.isEmpty) return false;
  final view = dispatcher.implicitView ?? dispatcher.views.first;
  final size = view.physicalSize / view.devicePixelRatio;
  if (size.shortestSide <= 0) return false;
  if (size.shortestSide < 600) {
    unawaited(
      SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]),
    );
  }
  return true;
}
