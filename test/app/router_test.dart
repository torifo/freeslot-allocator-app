import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/app/router.dart';
import 'package:frelocator/app/theme.dart';
import 'package:frelocator/features/daily_plan/presentation/daily_plan_screen.dart';
import 'package:frelocator/features/home/presentation/home_screen.dart';
import 'package:frelocator/features/task_master/presentation/category_settings_screen.dart';
import 'package:frelocator/features/task_master/presentation/task_master_screen.dart';
import 'package:frelocator/features/sync/presentation/sync_settings_screen.dart';
import 'package:frelocator/features/weekly_report/presentation/weekly_report_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_container.dart';

void main() {
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    container = await testContainer();
  });

  tearDown(() => container.dispose());

  Future<void> pumpAt(WidgetTester tester, String location) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          locale: const Locale('ja'),
          supportedLocales: const <Locale>[Locale('ja')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: buildAppTheme(),
          routerConfig: buildAppRouter(initialLocation: location),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('every top-level deep link keeps the navigation bar', (
    tester,
  ) async {
    for (final (index, path) in shellBranchPaths.indexed) {
      await pumpAt(tester, path);
      expect(find.byType(HomeBottomNav), findsOneWidget, reason: path);
      expect(
        tester.widget<HomeBottomNav>(find.byType(HomeBottomNav)).currentIndex,
        index,
        reason: path,
      );
    }
  });

  testWidgets('each branch shows its own screen', (tester) async {
    await pumpAt(tester, '/');
    expect(find.byType(HomeScreen), findsOneWidget);
    await pumpAt(tester, '/tasks');
    expect(find.byType(TaskMasterScreen), findsOneWidget);
    await pumpAt(tester, '/daily-plan');
    expect(find.byType(DailyPlanScreen), findsOneWidget);
    await pumpAt(tester, '/weekly-report');
    expect(find.byType(WeeklyReportScreen), findsOneWidget);
    await pumpAt(tester, '/categories');
    expect(find.byType(CategorySettingsScreen), findsOneWidget);
  });

  testWidgets('the sync screens sit outside the shell', (tester) async {
    await pumpAt(tester, '/sync');
    expect(find.byType(SyncSettingsScreen), findsOneWidget);
    expect(find.byType(HomeBottomNav), findsNothing);
  });

  testWidgets('the tasks screen can push category settings and come back', (
    tester,
  ) async {
    await pumpAt(tester, '/tasks');
    await tester.tap(find.byTooltip('カテゴリ設定'));
    await tester.pumpAndSettle();
    expect(find.byType(CategorySettingsScreen), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(TaskMasterScreen), findsOneWidget);
  });
}
