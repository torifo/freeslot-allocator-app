import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/app/theme.dart';
import 'package:frelocator/features/home/application/week_overview.dart';
import 'package:frelocator/features/home/presentation/week_mini_card.dart';

final DateTime _friday = DateTime(2026, 9, 25);

List<WeekDayOverview> _week({int fridayFree = 150, int wednesdayFree = 180}) {
  final monday = DateTime(2026, 9, 21);
  return List.generate(7, (i) {
    final date = monday.add(Duration(days: i));
    if (i == 2) {
      return WeekDayOverview(
        date: date,
        hasPlan: true,
        freeMinutes: wednesdayFree,
        assignedMinutes: 0,
      );
    }
    if (i == 4) {
      return WeekDayOverview(
        date: date,
        hasPlan: true,
        freeMinutes: fridayFree,
        assignedMinutes: 45,
      );
    }
    return WeekDayOverview(
      date: date,
      hasPlan: false,
      freeMinutes: 0,
      assignedMinutes: 0,
    );
  });
}

Widget _host(List<WeekDayOverview> days, {VoidCallback? onTap}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 236,
      child: WeekMiniCard(today: _friday, days: days, onTap: onTap),
    ),
  ),
);

void main() {
  testWidgets('today is the only clay label', (tester) async {
    await tester.pumpWidget(_host(_week()));
    await tester.pumpAndSettle();

    Color labelColor(String label) =>
        tester.widget<Text>(find.text(label)).style!.color!;

    expect(labelColor('金'), AppColors.clay);
    expect(labelColor('水'), AppColors.onDeepMt); // planned, not today
    expect(labelColor('月'), AppColors.ink3); // no plan
  });

  testWidgets('bar heights follow the planned free minutes', (tester) async {
    await tester.pumpWidget(_host(_week()));
    await tester.pumpAndSettle();

    final bars = tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .toList();
    expect(bars.length, 7);

    double h(int i) => (bars[i].constraints!).maxHeight;

    expect(h(2), WeekMiniCard.maxBarHeight); // busiest day fills the strip
    expect(h(4), lessThan(h(2)));
    expect(h(4), greaterThan(WeekMiniCard.minPlannedHeight));
    expect(h(0), WeekMiniCard.stubHeight); // no plan
  });

  testWidgets('heights change when the data changes', (tester) async {
    await tester.pumpWidget(_host(_week(fridayFree: 60)));
    await tester.pumpAndSettle();
    double fridayHeight() => tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .elementAt(4)
        .constraints!
        .maxHeight;
    final before = fridayHeight();

    await tester.pumpWidget(_host(_week(fridayFree: 180)));
    await tester.pumpAndSettle();

    expect(fridayHeight(), greaterThan(before));
  });

  testWidgets('tapping the card reports the tap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(_week(), onTap: () => taps += 1));
    await tester.tap(find.text('今週の計画を確認する'));
    expect(taps, 1);
  });
}
