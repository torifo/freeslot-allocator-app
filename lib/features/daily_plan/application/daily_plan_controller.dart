import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/daily_plan_repository.dart';
import '../domain/daily_plan_models.dart';
import 'daily_plan_logic.dart';

final dailyPlanControllerProvider =
    AsyncNotifierProvider<DailyPlanController, DailyPlanStateData>(
      DailyPlanController.new,
    );

class DailyPlanController extends AsyncNotifier<DailyPlanStateData> {
  DailyPlanRepository get _repository => ref.read(dailyPlanRepositoryProvider);

  @override
  Future<DailyPlanStateData> build() async {
    return _repository.load();
  }

  Future<DailyPlan> ensurePlanForDate(DateTime value) async {
    final current = state.requireValue;
    final existing = current.planForDate(value);
    if (existing != null) {
      return existing;
    }

    final now = DateTime.now();
    final plan = DailyPlan(
      id: 'plan-${now.microsecondsSinceEpoch}',
      date: dateOnly(value),
      createdAt: now,
      updatedAt: now,
    );
    final plans = List<DailyPlan>.from(current.plans)..add(plan);
    await _persist(current.copyWith(plans: _sortPlans(plans)));
    return plan;
  }

  Future<void> upsertSlot(FreeTimeSlot slot) async {
    validateFreeTimeSlot(slot);
    final current = state.requireValue;
    final slots = List<FreeTimeSlot>.from(current.slots);
    final index = slots.indexWhere((item) => item.id == slot.id);
    if (index >= 0) {
      slots[index] = slot;
    } else {
      slots.add(slot);
    }

    await _persist(
      current.copyWith(
        slots: sortSlots(slots),
        plans: _touchPlan(current.plans, slot.dailyPlanId),
      ),
    );
  }

  Future<void> deleteSlot(String slotId) async {
    final current = state.requireValue;
    final slot = current.slots.where((item) => item.id == slotId).firstOrNull;
    if (slot == null) {
      return;
    }

    final slots = current.slots.where((item) => item.id != slotId).toList();
    final assignments = current.assignments
        .where((item) => item.slotId != slotId)
        .toList();

    await _persist(
      current.copyWith(
        slots: slots,
        assignments: assignments,
        plans: _touchPlan(current.plans, slot.dailyPlanId),
      ),
    );
  }

  Future<void> upsertAssignment(SlotTaskAssignment assignment) async {
    final current = state.requireValue;
    final slot = current.slots
        .where((item) => item.id == assignment.slotId)
        .firstOrNull;
    if (slot == null) {
      throw const DailyPlanValidationException('対象の自由時間枠が見つかりません。');
    }

    final sameSlotAssignments = current.assignmentsForSlot(assignment.slotId);
    validateAssignment(
      assignment: assignment,
      slot: slot,
      existingAssignments: sameSlotAssignments,
    );

    final assignments = List<SlotTaskAssignment>.from(current.assignments);
    final index = assignments.indexWhere((item) => item.id == assignment.id);
    if (index >= 0) {
      assignments[index] = assignment;
    } else {
      assignments.add(assignment);
    }

    final normalized = _normalizeAssignments(assignments, assignment.slotId);
    await _persist(
      current.copyWith(
        assignments: normalized,
        plans: _touchPlan(current.plans, assignment.dailyPlanId),
      ),
    );
  }

  Future<void> deleteAssignment(String assignmentId) async {
    final current = state.requireValue;
    final assignment = current.assignments
        .where((item) => item.id == assignmentId)
        .firstOrNull;
    if (assignment == null) {
      return;
    }

    final assignments = current.assignments
        .where((item) => item.id != assignmentId)
        .toList();
    final normalized = _normalizeAssignments(assignments, assignment.slotId);
    await _persist(
      current.copyWith(
        assignments: normalized,
        plans: _touchPlan(current.plans, assignment.dailyPlanId),
      ),
    );
  }

  Future<void> _persist(DailyPlanStateData next) async {
    state = AsyncData(next);
    await _repository.save(next);
  }

  List<DailyPlan> _sortPlans(List<DailyPlan> plans) {
    final items = List<DailyPlan>.from(plans);
    items.sort((a, b) => a.date.compareTo(b.date));
    return items;
  }

  List<DailyPlan> _touchPlan(List<DailyPlan> plans, String planId) {
    final now = DateTime.now();
    return _sortPlans(
      plans.map((plan) {
        return plan.id == planId ? plan.copyWith(updatedAt: now) : plan;
      }).toList(),
    );
  }

  List<SlotTaskAssignment> _normalizeAssignments(
    List<SlotTaskAssignment> assignments,
    String slotId,
  ) {
    final currentSlot = assignments.where((item) => item.slotId == slotId);
    final otherSlots = assignments.where((item) => item.slotId != slotId);
    return <SlotTaskAssignment>[
      ...otherSlots,
      ...normalizeAssignmentsForSlot(currentSlot),
    ];
  }
}
