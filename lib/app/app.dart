import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/daily_plan/application/daily_plan_controller.dart';
import '../features/sync/application/sync_in_flight.dart';
import '../features/task_master/application/task_master_controller.dart';
import '../features/task_master/data/task_master_repository.dart' show stateStoreProvider;
import 'router.dart';
import 'theme.dart';

class FrelocatorApp extends ConsumerStatefulWidget {
  const FrelocatorApp({super.key});

  @override
  ConsumerState<FrelocatorApp> createState() => _FrelocatorAppState();
}

/// Reloads task-master and daily-plan state when the app resumes and the
/// backing store (the macOS `FileBackedStore`) changed while it was
/// backgrounded — e.g. the hub or another process wrote `data.json`.
class _FrelocatorAppState extends ConsumerState<FrelocatorApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Set when a resume arrived while a sync was running: reloading then would
  /// race the import that sync is about to commit.
  bool _pendingReload = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (ref.read(syncInFlightProvider)) {
      _pendingReload = true;
      return;
    }
    _reloadIfChanged();
  }

  Future<void> _reloadIfChanged() async {
    final store = ref.read(stateStoreProvider);
    if (await store.changedSinceLastRead()) {
      ref.invalidate(taskMasterControllerProvider);
      ref.invalidate(dailyPlanControllerProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(syncInFlightProvider, (previous, next) {
      if (next || !_pendingReload) return;
      _pendingReload = false;
      _reloadIfChanged();
    });
    return MaterialApp.router(
      title: 'Frelocator',
      locale: const Locale('ja'),
      supportedLocales: const [Locale('ja')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
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
