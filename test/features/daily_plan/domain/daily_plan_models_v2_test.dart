import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/hlc.dart';
import 'package:frelocator/core/sync_meta.dart';
import 'package:frelocator/features/daily_plan/domain/daily_plan_models.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';

void main() {
  test('date is stored as YYYY-MM-DD and v1 ISO datetime still parses', () {
    final plan = DailyPlan.fromJson({
      'id': 'p',
      'date': '2026-09-08T00:00:00.000',
      'createdAt': '2026-09-08T00:00:00.000',
      'updatedAt': '2026-09-08T00:00:00.000',
    });
    expect(plan.date, DateTime(2026, 9, 8));
    expect(plan.toJson()['date'], '2026-09-08');
    expect(DailyPlan.fromJson(plan.toJson()).date, DateTime(2026, 9, 8));
  });

  test('slots and assignments carry meta and tombstones round trip', () {
    final meta = SyncMeta.stamp(Hlc.parse('3-0-dev'), DateTime.utc(2026));
    final state = DailyPlanStateData(
      plans: [
        DailyPlan(
          id: 'p',
          date: DateTime(2026, 9, 8),
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          meta: meta,
        ),
      ],
      slots: [
        FreeTimeSlot(
          id: 's',
          dailyPlanId: 'p',
          startAt: DateTime.utc(2026, 9, 8, 1),
          endAt: DateTime.utc(2026, 9, 8, 2),
          meta: meta,
        ),
      ],
      assignments: [
        SlotTaskAssignment(
          id: 'a',
          dailyPlanId: 'p',
          slotId: 's',
          taskId: 't',
          taskTitle: 'x',
          taskKind: TaskKind.mustDo,
          startAt: DateTime.utc(2026, 9, 8, 1),
          endAt: DateTime.utc(2026, 9, 8, 2),
          sortOrder: 0,
          meta: meta,
        ),
      ],
      deletedSlots: [
        Tombstone(
          id: 's0',
          meta: meta.tombstone(Hlc.parse('4-0-dev'), DateTime.utc(2026, 1, 2)),
        ),
      ],
    );
    final back = DailyPlanStateData.decode(jsonEncode(state.toJson()));
    expect(back.slots.single.meta.clock, Hlc.parse('3-0-dev'));
    expect(back.deletedSlots.single.id, 's0');
    expect(back.assignments.single.meta.migrated, isFalse);
  });

  test('legacy constructors without meta default to migrated sentinel', () {
    final slot = FreeTimeSlot(
      id: 's',
      dailyPlanId: 'p',
      startAt: DateTime(2026),
      endAt: DateTime(2026, 1, 1, 1),
    );
    expect(slot.meta.clock, Hlc.migrated);
  });
}
