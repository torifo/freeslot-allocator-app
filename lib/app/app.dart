import 'package:flutter/material.dart';

import 'router.dart';
import 'theme.dart';

class FrelocatorApp extends StatelessWidget {
  const FrelocatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Frelocator',
      theme: buildAppTheme(),
      routerConfig: appRouter,
    );
  }
}
