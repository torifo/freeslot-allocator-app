import '../../features/daily_plan/domain/daily_plan_models.dart';
import '../../features/task_master/domain/task_models.dart';
import 'sync_document.dart';

class InvariantViolation {
  const InvariantViolation(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// Checks the rules the app UI otherwise guarantees. Used by the hub before
/// writing and by the merger to report (never to mutate).
class InvariantChecker {
  static List<InvariantViolation> check(SyncDocument doc) {
    final out = <InvariantViolation>[];
    _categories(doc.taskMaster.mustDoCategories, 'mustDo', out);
    _categories(doc.taskMaster.wantToDoCategories, 'wantToDo', out);

    final slotsById = <String, FreeTimeSlot>{
      for (final s in doc.dailyPlan.slots) s.id: s,
    };
    for (final slot in doc.dailyPlan.slots) {
      if (!slot.endAt.isAfter(slot.startAt)) {
        out.add(
          InvariantViolation(
            'slot_time_reversed',
            'slot ${slot.id} ends before it starts',
          ),
        );
      }
    }
    final bySlot = <String, List<SlotTaskAssignment>>{};
    for (final a in doc.dailyPlan.assignments) {
      bySlot.putIfAbsent(a.slotId, () => <SlotTaskAssignment>[]).add(a);
      final slot = slotsById[a.slotId];
      if (slot != null &&
          (a.startAt.isBefore(slot.startAt) || a.endAt.isAfter(slot.endAt))) {
        out.add(
          InvariantViolation(
            'assignment_outside_slot',
            'assignment ${a.id} exceeds slot ${slot.id}',
          ),
        );
      }
    }
    for (final entry in bySlot.entries) {
      final items = List<SlotTaskAssignment>.from(entry.value)
        ..sort((x, y) => x.sortOrder.compareTo(y.sortOrder));
      for (var i = 0; i < items.length; i += 1) {
        if (items[i].sortOrder != i) {
          out.add(
            InvariantViolation(
              'sort_order_not_contiguous',
              'slot ${entry.key} has gaps in sortOrder',
            ),
          );
          break;
        }
      }
      final byStart = List<SlotTaskAssignment>.from(entry.value)
        ..sort((x, y) => x.startAt.compareTo(y.startAt));
      for (var i = 1; i < byStart.length; i += 1) {
        if (byStart[i].startAt.isBefore(byStart[i - 1].endAt)) {
          out.add(
            InvariantViolation(
              'assignment_overlap',
              'assignments ${byStart[i - 1].id} and ${byStart[i].id} overlap',
            ),
          );
          break;
        }
      }
    }
    return out;
  }

  static void _categories(
    List<TaskCategory> categories,
    String kind,
    List<InvariantViolation> out,
  ) {
    final names = <String>{};
    for (final c in categories) {
      if (!names.add(c.name)) {
        out.add(
          InvariantViolation(
            'duplicate_category_name',
            '$kind has duplicate category "${c.name}"',
          ),
        );
        return;
      }
    }
  }
}
