import 'package:go_router/go_router.dart';

import '../features/daily_plan/presentation/daily_plan_screen.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/sync/presentation/pairing_scan_screen.dart';
import '../features/sync/presentation/qr_receive_screen.dart';
import '../features/sync/presentation/sync_settings_screen.dart';
import '../features/task_master/presentation/category_settings_screen.dart';
import '../features/task_master/presentation/task_master_screen.dart';
import '../features/weekly_report/presentation/weekly_report_screen.dart';

final GoRouter appRouter = GoRouter(
  routes: <RouteBase>[
    GoRoute(
      path: '/',
      builder: (context, state) => const HomeScreen(),
      routes: <RouteBase>[
        GoRoute(
          path: 'tasks',
          builder: (context, state) => const TaskMasterScreen(),
        ),
        GoRoute(
          path: 'categories',
          builder: (context, state) => const CategorySettingsScreen(),
        ),
        GoRoute(
          path: 'daily-plan',
          builder: (context, state) => const DailyPlanScreen(),
        ),
        GoRoute(
          path: 'weekly-report',
          builder: (context, state) => const WeeklyReportScreen(),
        ),
        GoRoute(
          path: 'sync',
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
    ),
  ],
);
