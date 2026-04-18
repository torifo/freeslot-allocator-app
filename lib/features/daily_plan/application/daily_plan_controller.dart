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

  Future<DailyPlan> duplicatePlan({
    required DateTime sourceDate,
    required DateTime targetDate,
    List<String>? sourceSlotIds,
    List<String>? sourceAssignmentIds,
    bool includeAssignments = true,
    bool replaceExisting = false,
  }) async {
    final current = state.requireValue;
    final normalizedSource = dateOnly(sourceDate);
    final normalizedTarget = dateOnly(targetDate);
    if (normalizedSource == normalizedTarget) {
      throw const DailyPlanValidationException('同じ日付には複製できません。');
    }

    final sourcePlan = current.planForDate(normalizedSource);
    if (sourcePlan == null) {
      throw const DailyPlanValidationException('複製元の DailyPlan が見つかりません。');
    }

    final existingTargetPlan = current.planForDate(normalizedTarget);

    final now = DateTime.now();
    final dayOffset = normalizedTarget.difference(normalizedSource).inDays;
    final targetPlan =
        existingTargetPlan?.copyWith(date: normalizedTarget, updatedAt: now) ??
        DailyPlan(
          id: 'plan-${now.microsecondsSinceEpoch}',
          date: normalizedTarget,
          createdAt: now,
          updatedAt: now,
        );

    final selectedSourceSlotIds = sourceSlotIds?.toSet();
    final sourceSlots = current
        .slotsForPlan(sourcePlan.id)
        .where(
          (slot) =>
              selectedSourceSlotIds == null ||
              selectedSourceSlotIds.contains(slot.id),
        )
        .toList();
    if (sourceSlots.isEmpty) {
      throw const DailyPlanValidationException('複製する自由時間枠を1件以上選択してください。');
    }

    final selectedSourceAssignmentIds = sourceAssignmentIds?.toSet();
    final sourceAssignments = current.assignments
        .where(
          (item) =>
              item.dailyPlanId == sourcePlan.id &&
              sourceSlots.any((slot) => slot.id == item.slotId) &&
              (selectedSourceAssignmentIds == null ||
                  selectedSourceAssignmentIds.contains(item.id)),
        )
        .toList();
    final slots = replaceExisting
        ? current.slots
              .where((item) => item.dailyPlanId != targetPlan.id)
              .toList()
        : List<FreeTimeSlot>.from(current.slots);
    final assignments = replaceExisting
        ? current.assignments
              .where((item) => item.dailyPlanId != targetPlan.id)
              .toList()
        : List<SlotTaskAssignment>.from(current.assignments);
    final slotIdMap = <String, String>{};

    for (final slot in sourceSlots) {
      final newSlotId =
          'slot-${DateTime.now().microsecondsSinceEpoch}-${slotIdMap.length}';
      slotIdMap[slot.id] = newSlotId;
      slots.add(
        slot.copyWith(
          id: newSlotId,
          dailyPlanId: targetPlan.id,
          startAt: shiftDateTimeByDays(slot.startAt, dayOffset),
          endAt: shiftDateTimeByDays(slot.endAt, dayOffset),
        ),
      );
    }

    if (includeAssignments) {
      final sortedSourceAssignments =
          List<SlotTaskAssignment>.from(sourceAssignments)..sort((a, b) {
            final order = a.startAt.compareTo(b.startAt);
            if (order != 0) {
              return order;
            }
            return a.sortOrder.compareTo(b.sortOrder);
          });
      for (final assignment in sortedSourceAssignments) {
        assignments.add(
          assignment.copyWith(
            id: 'assignment-${DateTime.now().microsecondsSinceEpoch}-${assignments.length}',
            dailyPlanId: targetPlan.id,
            slotId: slotIdMap[assignment.slotId] ?? assignment.slotId,
            startAt: shiftDateTimeByDays(assignment.startAt, dayOffset),
            endAt: shiftDateTimeByDays(assignment.endAt, dayOffset),
          ),
        );
      }
    }

    final plans =
        current.plans.where((item) => item.id != targetPlan.id).toList()
          ..add(targetPlan);

    await _persist(
      current.copyWith(
        plans: _sortPlans(plans),
        slots: sortSlots(slots),
        assignments: _normalizeAllAssignments(assignments),
      ),
    );
    return targetPlan;
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

  Future<void> moveAssignmentToSlot({
    required String assignmentId,
    required String targetSlotId,
    String? beforeAssignmentId,
  }) async {
    final current = state.requireValue;
    final assignment = current.assignments
        .where((item) => item.id == assignmentId)
        .firstOrNull;
    if (assignment == null) {
      throw const DailyPlanValidationException('移動対象の予定が見つかりません。');
    }
    final targetSlot = current.slots
        .where((item) => item.id == targetSlotId)
        .firstOrNull;
    if (targetSlot == null) {
      throw const DailyPlanValidationException('移動先の自由時間枠が見つかりません。');
    }

    final targetAssignments = current.assignmentsForSlot(targetSlot.id);
    final rebuiltTargetAssignments = moveAssignmentToSlotPosition(
      assignment: assignment,
      targetSlot: targetSlot,
      existingAssignments: targetAssignments,
      beforeAssignmentId: beforeAssignmentId,
    );
    final assignments = List<SlotTaskAssignment>.from(current.assignments);
    final sourceAssignments = assignment.slotId == targetSlot.id
        ? const <SlotTaskAssignment>[]
        : normalizeAssignmentsForSlot(
            current
                .assignmentsForSlot(assignment.slotId)
                .where((item) => item.id != assignment.id),
          );
    assignments.removeWhere(
      (item) =>
          item.slotId == targetSlot.id || item.slotId == assignment.slotId,
    );
    assignments.addAll(sourceAssignments);
    assignments.addAll(rebuiltTargetAssignments);

    await _persist(
      current.copyWith(
        assignments: _normalizeMultipleSlots(assignments, <String>[
          assignment.slotId,
          targetSlot.id,
        ]),
        plans: _touchPlans(current.plans, <String>[
          assignment.dailyPlanId,
          targetSlot.dailyPlanId,
        ]),
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
    return _touchPlans(plans, <String>[planId]);
  }

  List<DailyPlan> _touchPlans(List<DailyPlan> plans, List<String> planIds) {
    final now = DateTime.now();
    final targets = planIds.toSet();
    return _sortPlans(
      plans.map((plan) {
        return targets.contains(plan.id) ? plan.copyWith(updatedAt: now) : plan;
      }).toList(),
    );
  }

  List<SlotTaskAssignment> _normalizeAssignments(
    List<SlotTaskAssignment> assignments,
    String slotId,
  ) {
    return _normalizeMultipleSlots(assignments, <String>[slotId]);
  }

  List<SlotTaskAssignment> _normalizeMultipleSlots(
    List<SlotTaskAssignment> assignments,
    List<String> slotIds,
  ) {
    final targets = slotIds.toSet();
    final currentSlots = assignments.where(
      (item) => targets.contains(item.slotId),
    );
    final otherSlots = assignments.where(
      (item) => !targets.contains(item.slotId),
    );
    final normalized = <SlotTaskAssignment>[];
    for (final slotId in targets) {
      normalized.addAll(
        normalizeAssignmentsForSlot(
          currentSlots.where((item) => item.slotId == slotId),
        ),
      );
    }
    return <SlotTaskAssignment>[...otherSlots, ...normalized];
  }

  List<SlotTaskAssignment> _normalizeAllAssignments(
    List<SlotTaskAssignment> assignments,
  ) {
    final bySlot = <String, List<SlotTaskAssignment>>{};
    for (final assignment in assignments) {
      bySlot
          .putIfAbsent(assignment.slotId, () => <SlotTaskAssignment>[])
          .add(assignment);
    }

    final normalized = <SlotTaskAssignment>[];
    for (final entry in bySlot.entries) {
      normalized.addAll(normalizeAssignmentsForSlot(entry.value));
    }
    return normalized;
  }
}
