import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/daily_plan/application/daily_plan_controller.dart';
import '../features/sync/application/sync_in_flight.dart';
import '../features/task_master/application/task_master_controller.dart';
import '../features/task_master/data/task_master_repository.dart' show stateStoreProvider;
import '../services/storage/hub_backed_store.dart';
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
    // Hub mode has no lifecycle events to lean on: a browser tab is never
    // "resumed", so the store polls the hub and tells us when to reload.
    final store = ref.read(stateStoreProvider);
    if (store is HubBackedStore) {
      _hubStore = store;
      store.startPolling(onRemoteChange: _reloadIfChanged);
    }
  }

  /// Set only when this build is served by the local hub.
  HubBackedStore? _hubStore;

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
      builder: _withUnsentBanner,
      locale: const Locale('ja'),
      supportedLocales: const [Locale('ja')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: buildAppTheme(),
      scrollBehavior: const _AppScrollBehavior(),
      routerConfig: appRouter,
    );
  }

  /// A browser in hub mode holds the only copy of an edit until the hub takes
  /// it, so an unsent edit gets a permanent red band rather than a snackbar.
  Widget _withUnsentBanner(BuildContext context, Widget? child) {
    final store = _hubStore;
    final content = child ?? const SizedBox.shrink();
    if (store == null) return content;
    return ValueListenableBuilder<bool>(
      valueListenable: store.hasUnsentEdits,
      builder: (context, unsent, _) => Column(
        children: <Widget>[
          if (unsent)
            Material(
              color: Theme.of(context).colorScheme.error,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Text(
                    'PC に保存できていません（再試行中）。'
                    'この状態でリロードすると未送信の編集は失われます。',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onError,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
          Expanded(child: content),
        ],
      ),
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
