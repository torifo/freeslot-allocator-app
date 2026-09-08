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

  Future<void> pumpAt(
    WidgetTester tester,
    String location, {
    Size logicalSize = const Size(390, 844),
  }) async {
    tester.view.physicalSize = logicalSize * 3;
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

  testWidgets('a wide window navigates from every branch, not just home', (
    tester,
  ) async {
    // The bar is dropped above 800 dp, and the sidebar that replaced it was
    // home's own: /tasks and the rest had no navigation at all (C-1).
    await pumpAt(tester, '/tasks', logicalSize: const Size(1280, 800));

    final rail = find.byType(NavigationRail);
    expect(rail, findsOneWidget);
    expect(tester.widget<NavigationRail>(rail).selectedIndex, 1);
    expect(
      find.descendant(of: rail, matching: find.text('タスク')),
      findsOneWidget,
    );
    expect(find.byType(TaskMasterScreen), findsOneWidget);
    expect(find.byType(HomeBottomNav), findsNothing);
  });

  testWidgets('a wide window offers exactly one way to navigate', (
    tester,
  ) async {
    await pumpAt(tester, '/', logicalSize: const Size(1280, 800));

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(HomeBottomNav), findsNothing);
    // The home sidebar keeps its brand column but no second copy of the five
    // destinations, so the rail is the only place a branch is chosen.
    expect(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('日次計画'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the rail switches branch on tap', (tester) async {
    await pumpAt(tester, '/', logicalSize: const Size(1280, 800));

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('週次'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(WeeklyReportScreen), findsOneWidget);
    expect(tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex, 3);
  });

  testWidgets('the system back button goes up to home, not out of the app', (
    tester,
  ) async {
    await pumpAt(tester, '/tasks');
    expect(find.byType(TaskMasterScreen), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(
      tester.widget<HomeBottomNav>(find.byType(HomeBottomNav)).currentIndex,
      0,
    );
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
