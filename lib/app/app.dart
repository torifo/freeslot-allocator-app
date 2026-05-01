import 'package:flutter/material.dart';

import 'router.dart';
import 'theme.dart';

class FrelocatorApp extends StatelessWidget {
  const FrelocatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Frelocator',
      locale: const Locale('ja'),
      theme: buildAppTheme(),
      scrollBehavior: const _AppScrollBehavior(),
      routerConfig: appRouter,
    );
  }
}

class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}
