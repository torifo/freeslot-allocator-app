import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/features/home/presentation/home_screen.dart';

void main() {
  Widget host({required double bottomInset}) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(padding: EdgeInsets.only(bottom: bottomInset)),
      child: const Scaffold(body: SizedBox(), bottomNavigationBar: HomeBottomNav()),
    ),
  );

  testWidgets('reserves the system navigation inset below the row', (tester) async {
    await tester.pumpWidget(host(bottomInset: 48));
    final bar = tester.getRect(find.byType(HomeBottomNav));
    expect(bar.height, HomeBottomNav.contentHeight + 48);
    final label = tester.getRect(find.text('設定'));
    expect(label.bottom, lessThanOrEqualTo(bar.bottom - 48));
    expect(find.text('今日'), findsOneWidget);
  });

  testWidgets('keeps the plain height without an inset', (tester) async {
    await tester.pumpWidget(host(bottomInset: 0));
    expect(tester.getRect(find.byType(HomeBottomNav)).height, HomeBottomNav.contentHeight);
  });
}
