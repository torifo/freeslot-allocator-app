import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/app/theme.dart';
import 'package:frelocator/features/daily_plan/domain/daily_plan_models.dart';
import 'package:frelocator/features/daily_plan/presentation/daily_plan_screen.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/test_container.dart';

/// The screen always opens on today, so the seeded plan has to be dated today.
final DateTime _today = dateOnly(DateTime.now());

DailyPlanStateData _stateWith({
  bool plan = true,
  bool slot = true,
  int assignments = 0,
}) {
  final thePlan = DailyPlan(
    id: 'plan-today',
    date: _today,
    createdAt: _today,
    updatedAt: _today,
  );
  final theSlot = FreeTimeSlot(
    id: 'slot-1',
    dailyPlanId: thePlan.id,
    startAt: _today.add(const Duration(hours: 9)),
    endAt: _today.add(const Duration(hours: 12)),
    label: '午前',
  );
  return DailyPlanStateData(
    plans: <DailyPlan>[if (plan) thePlan],
    slots: <FreeTimeSlot>[if (plan && slot) theSlot],
    assignments: <SlotTaskAssignment>[
      for (var i = 0; i < assignments; i += 1)
        SlotTaskAssignment(
          id: 'assignment-$i',
          dailyPlanId: thePlan.id,
          slotId: theSlot.id,
          taskId: 'task-$i',
          taskTitle: '予定 $i',
          taskKind: TaskKind.mustDo,
          startAt: theSlot.startAt.add(Duration(minutes: 30 * i)),
          endAt: theSlot.startAt.add(Duration(minutes: 30 * (i + 1))),
          sortOrder: i,
        ),
    ],
  );
}

void main() {
  setUpAll(() async {
    // The card formats its date in Japanese, the way the app does at startup.
    Intl.defaultLocale = 'ja';
    await initializeDateFormatting('ja');
  });

  Future<ProviderContainer> pump(
    WidgetTester tester,
    DailyPlanStateData state,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'daily_plan_state_v1': state.encode(),
    });
    final container = await testContainer();
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const DailyPlanScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  group('the summary badge', () {
    testWidgets('a day with no plan says so', (tester) async {
      await pump(tester, _stateWith(plan: false));
      // 「枠 未設定」 was shown here too, which named the wrong missing thing
      // (M-6).
      expect(find.text('未作成'), findsOneWidget);
      expect(find.text('枠 未設定'), findsNothing);
    });

    testWidgets('a plan with nothing in it says the slots are missing', (
      tester,
    ) async {
      await pump(tester, _stateWith(slot: false));
      expect(find.text('枠 未設定'), findsOneWidget);
      expect(find.text('未作成'), findsNothing);
    });

    testWidgets('a plan with slots counts them', (tester) async {
      await pump(tester, _stateWith());
      expect(find.text('枠 1 件'), findsOneWidget);
    });
  });

  testWidgets('starting a drag does not move the list under the finger', (
    tester,
  ) async {
    await pump(tester, _stateWith(assignments: 2));

    final second = find.text('予定 1');
    expect(second, findsOneWidget);
    // The slot details sit below the timeline; the drag has to happen where a
    // finger could actually reach it.
    await tester.ensureVisible(second);
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(second);

    // Long-press the first tile: the drop zones used to be inserted into the
    // tree at this instant, shoving every row below down (I-6).
    final gesture = await tester.startGesture(tester.getCenter(find.text('予定 0')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    await tester.pump();


    expect(tester.getTopLeft(second), before);

    // The zones are still offered, once the drag is properly under way.
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('末尾に移動'), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('the drop zones stay out of the way while nothing is dragging', (
    tester,
  ) async {
    await pump(tester, _stateWith(assignments: 2));
    expect(find.textContaining('末尾に移動'), findsNothing);
  });
}
