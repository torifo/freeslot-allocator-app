import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../application/week_overview.dart';

/// The "THIS WEEK" strip on the home sidebar: one bar per day, Monday first.
///
/// Bar height follows the free time planned for that day, and the filled
/// part of each bar shows how much of it already has tasks assigned. Days
/// with no plan get a low stub so an empty week still reads as a week.
class WeekMiniCard extends StatelessWidget {
  const WeekMiniCard({
    super.key,
    required this.today,
    required this.days,
    this.onTap,
  });

  final DateTime today;
  final List<WeekDayOverview> days;
  final VoidCallback? onTap;

  static const double maxBarHeight = 30;
  static const double minPlannedHeight = 8;
  static const double stubHeight = 4;
  static const List<String> dayLabels = ['月', '火', '水', '木', '金', '土', '日'];

  /// Pixel height for a day, scaled against the busiest day of the week so
  /// the strip always uses its full height once any plan exists.
  static double barHeight(WeekDayOverview day, int maxFreeMinutes) {
    if (!day.hasPlan) return stubHeight;
    if (day.freeMinutes <= 0 || maxFreeMinutes <= 0) return minPlannedHeight;
    return minPlannedHeight +
        (maxBarHeight - minPlannedHeight) * day.freeMinutes / maxFreeMinutes;
  }

  static String _tooltip(WeekDayOverview day) {
    final label = dayLabels[day.date.weekday - DateTime.monday];
    final date = '${day.date.month}/${day.date.day}（$label）';
    if (!day.hasPlan) return '$date 計画なし';
    return '$date 自由 ${_minutes(day.freeMinutes)} / '
        '割り当て ${_minutes(day.assignedMinutes)}';
  }

  static String _minutes(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '$m分';
    if (m == 0) return '$h時間';
    return '$h時間$m分';
  }

  @override
  Widget build(BuildContext context) {
    final todayDate = DateTime(today.year, today.month, today.day);
    var maxFree = 0;
    for (final day in days) {
      if (day.freeMinutes > maxFree) maxFree = day.freeMinutes;
    }
    final card = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.deep,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'THIS WEEK',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 2.0,
              color: AppColors.clay,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '今週の計画を確認する',
            style: japaneseSerifTextStyle(
              fontSize: 12,
              color: AppColors.onDeep,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            // Tall enough for the highest bar plus its day label.
            height: maxBarHeight + 18,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final day in days)
                  Expanded(
                    child: _DayBar(
                      day: day,
                      isToday: day.date == todayDate,
                      height: barHeight(day, maxFree),
                      tooltip: _tooltip(day),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: card,
      ),
    );
  }
}

class _DayBar extends StatelessWidget {
  const _DayBar({
    required this.day,
    required this.isToday,
    required this.height,
    required this.tooltip,
  });

  final WeekDayOverview day;
  final bool isToday;
  final double height;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    // Today is clay; other planned days are the muted ink; unplanned days
    // fade back so the eye lands on the days that carry time.
    final Color freeColor;
    final Color assignedColor;
    final Color labelColor;
    if (isToday) {
      freeColor = AppColors.clay.withValues(alpha: 0.45);
      assignedColor = AppColors.clay;
      labelColor = AppColors.clay;
    } else if (day.hasPlan) {
      freeColor = AppColors.ink2;
      assignedColor = AppColors.onDeepMt;
      labelColor = AppColors.onDeepMt;
    } else {
      freeColor = AppColors.ink2.withValues(alpha: 0.5);
      assignedColor = AppColors.ink2;
      labelColor = AppColors.ink3;
    }
    const radius = BorderRadius.only(
      topLeft: Radius.circular(3),
      topRight: Radius.circular(3),
    );
    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1.5),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              height: height,
              decoration: BoxDecoration(color: freeColor, borderRadius: radius),
              alignment: Alignment.bottomCenter,
              child: AnimatedFractionallySizedBox(
                duration: const Duration(milliseconds: 300),
                heightFactor: day.assignedRatio,
                widthFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: assignedColor,
                    borderRadius: day.assignedRatio >= 1 ? radius : null,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              WeekMiniCard.dayLabels[day.date.weekday - DateTime.monday],
              style: TextStyle(
                fontSize: 9,
                color: labelColor,
                fontWeight: isToday ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
