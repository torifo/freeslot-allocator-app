import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/app/theme.dart';
import 'package:frelocator/features/home/presentation/home_screen.dart';

void main() {
  Widget host({
    required double bottomInset,
    int currentIndex = 0,
    ValueChanged<int>? onSelect,
  }) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(padding: EdgeInsets.only(bottom: bottomInset)),
      child: Scaffold(
        body: const SizedBox(),
        bottomNavigationBar: HomeBottomNav(
          currentIndex: currentIndex,
          onSelect: onSelect,
        ),
      ),
    ),
  );

  Color colorOfLabel(WidgetTester tester, String label) =>
      tester.widget<Text>(find.text(label)).style!.color!;

  testWidgets('reserves the system navigation inset below the row', (
    tester,
  ) async {
    await tester.pumpWidget(host(bottomInset: 48));
    final bar = tester.getRect(find.byType(HomeBottomNav));
    expect(bar.height, HomeBottomNav.contentHeight + 48);
    final label = tester.getRect(find.text('設定'));
    expect(label.bottom, lessThanOrEqualTo(bar.bottom - 48));
    expect(find.text('今日'), findsOneWidget);
  });

  testWidgets('keeps the plain height without an inset', (tester) async {
    await tester.pumpWidget(host(bottomInset: 0));
    expect(
      tester.getRect(find.byType(HomeBottomNav)).height,
      HomeBottomNav.contentHeight,
    );
  });

  testWidgets('highlights the destination it was given, not always 今日', (
    tester,
  ) async {
    await tester.pumpWidget(host(bottomInset: 0, currentIndex: 1));
    expect(colorOfLabel(tester, 'タスク'), AppColors.clay);
    expect(colorOfLabel(tester, '今日'), AppColors.ink3);

    await tester.pumpWidget(host(bottomInset: 0, currentIndex: 4));
    await tester.pump();
    expect(colorOfLabel(tester, '設定'), AppColors.clay);
    expect(colorOfLabel(tester, 'タスク'), AppColors.ink3);
  });

  testWidgets('reports the tapped destination by index', (tester) async {
    final taps = <int>[];
    await tester.pumpWidget(
      host(bottomInset: 0, currentIndex: 0, onSelect: taps.add),
    );
    await tester.tap(find.text('週次'));
    await tester.tap(find.bySemanticsLabel('日次計画'));
    expect(taps, <int>[3, 2]);
  });
}
