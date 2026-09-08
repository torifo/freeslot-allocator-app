import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/daily_plan/presentation/daily_plan_screen.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/sync/presentation/pairing_scan_screen.dart';
import '../features/sync/presentation/qr_receive_screen.dart';
import '../features/sync/presentation/sync_settings_screen.dart';
import '../features/task_master/presentation/category_settings_screen.dart';
import '../features/task_master/presentation/task_master_screen.dart';
import '../features/weekly_report/presentation/weekly_report_screen.dart';

/// The five destinations the bottom navigation switches between, in the order
/// the bar draws them. [HomeBottomNav] indexes into the same list, so a branch
/// and its tab cannot drift apart.
const List<String> shellBranchPaths = <String>[
  '/',
  '/tasks',
  '/daily-plan',
  '/weekly-report',
  '/categories',
];

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Builds the app router.
///
/// A single [StatefulShellRoute.indexedStack] keeps the bottom navigation on
/// every top-level screen and gives each tab its own navigator, so switching
/// tabs no longer throws away where the user was. The sync screens sit outside
/// the shell: they are a job the user finishes and leaves, and a navigation bar
/// under them would invite walking away mid-transfer.
GoRouter buildAppRouter({String initialLocation = '/'}) => GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: initialLocation,
  routes: <RouteBase>[
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          _ShellScaffold(navigationShell: navigationShell),
      branches: <StatefulShellBranch>[
        StatefulShellBranch(
          routes: <RouteBase>[
            GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
          ],
        ),
        StatefulShellBranch(
          routes: <RouteBase>[
            GoRoute(
              path: '/tasks',
              builder: (context, state) => const TaskMasterScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: <RouteBase>[
            GoRoute(
              path: '/daily-plan',
              builder: (context, state) => const DailyPlanScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: <RouteBase>[
            GoRoute(
              path: '/weekly-report',
              builder: (context, state) => const WeeklyReportScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: <RouteBase>[
            GoRoute(
              path: '/categories',
              builder: (context, state) => const CategorySettingsScreen(),
            ),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/sync',
      builder: (context, state) => const SyncSettingsScreen(),
      routes: <RouteBase>[
        GoRoute(
          path: 'pair',
          builder: (context, state) => const PairingScanScreen(),
        ),
        GoRoute(
          path: 'qr',
          builder: (context, state) => const QrReceiveScreen(),
        ),
      ],
    ),
  ],
);

final GoRouter appRouter = buildAppRouter();

/// Holds the active branch above navigation that never moves.
///
/// Narrow layouts get the bottom bar; from 800 dp the same five destinations
/// become a [NavigationRail] down the left edge. The rail lives here rather
/// than in [HomeScreen], which only ever drew a sidebar for itself and left
/// /tasks, /daily-plan, /weekly-report and /categories with no way out on a
/// tablet or a desktop window (C-1).
class _ShellScaffold extends StatelessWidget {
  const _ShellScaffold({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  /// `initialLocation: true` only when the tab is already selected: re-tapping
  /// it returns to that tab's own root instead of doing nothing, while
  /// switching tabs keeps where the user was.
  void _select(int index) => navigationShell.goBranch(
    index,
    initialLocation: index == navigationShell.currentIndex,
  );

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= 800;
    final atHome = navigationShell.currentIndex == 0;
    return PopScope(
      // Android's back gesture used to leave the app from any tab. The first
      // tab is home, so back means "up to home" everywhere else (I-1).
      canPop: atHome,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        navigationShell.goBranch(0);
      },
      child: Scaffold(
        body: isWide
            ? Row(
                children: <Widget>[
                  ShellNavigationRail(
                    currentIndex: navigationShell.currentIndex,
                    onSelect: _select,
                  ),
                  Expanded(child: navigationShell),
                ],
              )
            : navigationShell,
        bottomNavigationBar: isWide
            ? null
            : HomeBottomNav(
                currentIndex: navigationShell.currentIndex,
                onSelect: _select,
              ),
      ),
    );
  }
}
