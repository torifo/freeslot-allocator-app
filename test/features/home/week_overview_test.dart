import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/features/daily_plan/domain/daily_plan_models.dart';
import 'package:frelocator/features/home/application/week_overview.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';

// 2026-09-25 is a Friday.
final DateTime _friday = DateTime(2026, 9, 25);

DailyPlanStateData _data() {
  final wednesday = DateTime(2026, 9, 23);
  final planWed = DailyPlan(
    id: 'plan-wed',
    date: wednesday,
    createdAt: wednesday,
    updatedAt: wednesday,
  );
  final planFri = DailyPlan(
    id: 'plan-fri',
    date: _friday,
    createdAt: _friday,
    updatedAt: _friday,
  );
  final slotWed = FreeTimeSlot(
    id: 'slot-wed',
    dailyPlanId: planWed.id,
    startAt: wednesday.add(const Duration(hours: 9)),
    endAt: wednesday.add(const Duration(hours: 12)),
  );
  final slotFri1 = FreeTimeSlot(
    id: 'slot-fri-1',
    dailyPlanId: planFri.id,
    startAt: _friday.add(const Duration(hours: 9)),
    endAt: _friday.add(const Duration(hours: 10)),
  );
  final slotFri2 = FreeTimeSlot(
    id: 'slot-fri-2',
    dailyPlanId: planFri.id,
    startAt: _friday.add(const Duration(hours: 13)),
    endAt: _friday.add(const Duration(hours: 14, minutes: 30)),
  );
  return DailyPlanStateData(
    plans: [planWed, planFri],
    slots: [slotWed, slotFri1, slotFri2],
    assignments: [
      SlotTaskAssignment(
        id: 'a-1',
        dailyPlanId: planFri.id,
        slotId: slotFri1.id,
        taskId: 't-1',
        taskTitle: '資料',
        taskKind: TaskKind.mustDo,
        startAt: slotFri1.startAt,
        endAt: slotFri1.startAt.add(const Duration(minutes: 45)),
        sortOrder: 0,
      ),
    ],
  );
}

void main() {
  test('startOfWeek returns the Monday of the same week', () {
    expect(startOfWeek(_friday), DateTime(2026, 9, 21));
    expect(startOfWeek(DateTime(2026, 9, 21)), DateTime(2026, 9, 21));
    expect(startOfWeek(DateTime(2026, 9, 27, 23, 59)), DateTime(2026, 9, 21));
  });

  test('builds seven Monday-first days with real minutes', () {
    final week = buildWeekOverview(_data(), _friday);

    expect(week.length, 7);
    expect(week.first.date, DateTime(2026, 9, 21));
    expect(week.last.date, DateTime(2026, 9, 27));

    final wed = week[2];
    expect(wed.hasPlan, isTrue);
    expect(wed.freeMinutes, 180);
    expect(wed.assignedMinutes, 0);

    final fri = week[4];
    expect(fri.hasPlan, isTrue);
    expect(fri.freeMinutes, 150);
    expect(fri.assignedMinutes, 45);
    expect(fri.assignedRatio, closeTo(0.3, 0.001));

    final mon = week[0];
    expect(mon.hasPlan, isFalse);
    expect(mon.freeMinutes, 0);
  });

  test('an empty week is seven unplanned days', () {
    final week = buildWeekOverview(DailyPlanStateData.initial(), _friday);
    expect(week.every((d) => !d.hasPlan && d.freeMinutes == 0), isTrue);
  });
}
