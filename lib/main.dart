import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app/app.dart';
import 'core/device_clock.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Intl.defaultLocale = 'ja';
  await initializeDateFormatting('ja');
  final deviceClock = await DeviceClock.load();
  runApp(
    ProviderScope(
      overrides: [deviceClockProvider.overrideWithValue(deviceClock)],
      child: const FrelocatorApp(),
    ),
  );
}
