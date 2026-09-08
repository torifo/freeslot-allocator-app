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
  await _lockPortraitOnPhones(binding);
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
Future<void> _lockPortraitOnPhones(WidgetsBinding binding) async {
  final view = binding.platformDispatcher.implicitView;
  if (view == null) return;
  final size = view.physicalSize / view.devicePixelRatio;
  if (size.shortestSide >= 600) return;
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
}
