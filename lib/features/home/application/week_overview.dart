import '../../daily_plan/domain/daily_plan_models.dart';

/// One day of the home screen's week strip: how much free time was planned
/// for it and how much of that is already assigned to tasks.
class WeekDayOverview {
  const WeekDayOverview({
    required this.date,
    required this.hasPlan,
    required this.freeMinutes,
    required this.assignedMinutes,
  });

  final DateTime date;
  final bool hasPlan;
  final int freeMinutes;
  final int assignedMinutes;

  /// 0..1 share of the planned free time that already has tasks on it.
  double get assignedRatio =>
      freeMinutes <= 0 ? 0 : (assignedMinutes / freeMinutes).clamp(0.0, 1.0);
}

/// Monday of the week containing [day] (calendar day, no time component).
DateTime startOfWeek(DateTime day) {
  final d = dateOnly(day);
  return d.subtract(Duration(days: d.weekday - DateTime.monday));
}

/// Monday-first overview of the week containing [today], one entry per day.
///
/// Days without a plan report zero minutes and `hasPlan == false`, so the
/// strip can draw them as a stub instead of pretending they carry time.
List<WeekDayOverview> buildWeekOverview(
  DailyPlanStateData data,
  DateTime today,
) {
  final monday = startOfWeek(today);
  return List<WeekDayOverview>.generate(7, (offset) {
    final date = monday.add(Duration(days: offset));
    final plan = data.planForDate(date);
    if (plan == null) {
      return WeekDayOverview(
        date: date,
        hasPlan: false,
        freeMinutes: 0,
        assignedMinutes: 0,
      );
    }
    final slots = data.slotsForPlan(plan.id);
    var free = 0;
    var assigned = 0;
    for (final slot in slots) {
      free += slot.durationMinutes;
      for (final item in data.assignmentsForSlot(slot.id)) {
        assigned += item.durationMinutes;
      }
    }
    return WeekDayOverview(
      date: date,
      hasPlan: true,
      freeMinutes: free,
      assignedMinutes: assigned,
    );
  });
}
