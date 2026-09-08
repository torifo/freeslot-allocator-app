import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/device_clock.dart';
import '../../../core/hlc.dart';
import '../../../core/id_generator.dart';
import '../../../core/sync_meta.dart';
import '../data/daily_plan_repository.dart';
import '../domain/daily_plan_models.dart';
import 'daily_plan_logic.dart';

final dailyPlanControllerProvider =
    AsyncNotifierProvider<DailyPlanController, DailyPlanStateData>(
      DailyPlanController.new,
    );

class DailyPlanController extends AsyncNotifier<DailyPlanStateData> {
  DailyPlanRepository get _repository => ref.read(dailyPlanRepositoryProvider);

  DeviceClock get _device => ref.read(deviceClockProvider);

  /// Issues a fresh clock and folds it into [previous], or starts a new meta.
  Future<SyncMeta> _stamp(SyncMeta? previous) async {
    final clock = await _device.next();
    final now = DateTime.now().toUtc();
    return previous == null
        ? SyncMeta.stamp(clock, now)
        : previous.touch(clock, now);
  }

  /// Deterministic id for copied records so both devices produce the same id
  /// for the same copy. [generation] avoids colliding with a tombstone left by
  /// an earlier copy→delete of the same source.
  static String copyId(
    String prefix,
    String sourcePlanId,
    DateTime targetDate,
    String sourceEntityId,
    int generation,
  ) {
    final digest = sha256
        .convert(
          utf8.encode(
            '$sourcePlanId|${formatDateKey(targetDate)}|'
            '$sourceEntityId|$generation',
          ),
        )
        .toString();
    return '$prefix-${digest.substring(0, 16)}';
  }

  int _nextGeneration(
    String prefix,
    String sourcePlanId,
    DateTime targetDate,
    String sourceEntityId,
    Set<String> takenIds,
  ) {
    var generation = 0;
    while (takenIds.contains(
      copyId(prefix, sourcePlanId, targetDate, sourceEntityId, generation),
    )) {
      generation += 1;
    }
    return generation;
  }

  @override
  Future<DailyPlanStateData> build() async {
    return _repository.load();
  }

  /// Returns the loaded state, or throws a user-facing validation error when a
  /// mutation is attempted while the state is still loading or has failed.
  DailyPlanStateData get _current {
    final snapshot = state;
    if (!snapshot.hasValue) {
      throw const DailyPlanValidationException('データの読み込みが完了していません。');
    }
    return snapshot.value as DailyPlanStateData;
  }

  Future<DailyPlan> ensurePlanForDate(DateTime value) async {
    final current = _current;
    final existing = current.planForDate(value);
    if (existing != null) {
      return existing;
    }

    final now = DateTime.now();
    final plan = DailyPlan(
      id: generateId('plan', deviceId: _device.deviceId),
      date: dateOnly(value),
      createdAt: now,
      updatedAt: now,
      meta: await _stamp(null),
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
    final current = _current;
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
    final clock = await _device.next();
    final nowUtc = DateTime.now().toUtc();
    // One clock for the whole copy: within a device the counter is monotonic,
    // so a single value still orders this operation against every other one.
    final copyMeta = SyncMeta.stamp(clock, nowUtc);
    final dayOffset = normalizedTarget.difference(normalizedSource).inDays;
    final DailyPlan targetPlan;
    if (existingTargetPlan != null) {
      targetPlan = existingTargetPlan.copyWith(
        date: normalizedTarget,
        updatedAt: now,
        meta: existingTargetPlan.meta.touch(clock, nowUtc),
      );
    } else {
      targetPlan = DailyPlan(
        id: generateId('plan', deviceId: _device.deviceId),
        date: normalizedTarget,
        createdAt: now,
        updatedAt: now,
        meta: copyMeta,
      );
    }

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

    final deletedSlots = List<Tombstone>.from(current.deletedSlots);
    final deletedAssignments = List<Tombstone>.from(current.deletedAssignments);
    final List<FreeTimeSlot> slots;
    final List<SlotTaskAssignment> assignments;
    if (replaceExisting) {
      for (final item in current.slots.where(
        (item) => item.dailyPlanId == targetPlan.id,
      )) {
        deletedSlots.add(
          Tombstone(id: item.id, meta: item.meta.tombstone(clock, nowUtc)),
        );
      }
      for (final item in current.assignments.where(
        (item) => item.dailyPlanId == targetPlan.id,
      )) {
        deletedAssignments.add(
          Tombstone(id: item.id, meta: item.meta.tombstone(clock, nowUtc)),
        );
      }
      slots = current.slots
          .where((item) => item.dailyPlanId != targetPlan.id)
          .toList();
      assignments = current.assignments
          .where((item) => item.dailyPlanId != targetPlan.id)
          .toList();
    } else {
      slots = List<FreeTimeSlot>.from(current.slots);
      assignments = List<SlotTaskAssignment>.from(current.assignments);
    }

    // Copied ids must not collide with anything that exists or ever existed,
    // so tombstoned ids are taken too.
    final takenIds = <String>{
      ...current.slots.map((item) => item.id),
      ...current.assignments.map((item) => item.id),
      ...deletedSlots.map((item) => item.id),
      ...deletedAssignments.map((item) => item.id),
    };
    final slotIdMap = <String, String>{};

    for (final slot in sourceSlots) {
      final generation = _nextGeneration(
        'slot',
        sourcePlan.id,
        normalizedTarget,
        slot.id,
        takenIds,
      );
      final copiedSlot = slot.copyWith(
        id: copyId(
          'slot',
          sourcePlan.id,
          normalizedTarget,
          slot.id,
          generation,
        ),
        dailyPlanId: targetPlan.id,
        startAt: shiftDateTimeByDays(slot.startAt, dayOffset),
        endAt: shiftDateTimeByDays(slot.endAt, dayOffset),
        meta: copyMeta,
      );
      validateFreeTimeSlotAgainstPlan(
        slot: copiedSlot,
        existingSlots: slots.where((item) => item.dailyPlanId == targetPlan.id),
      );
      takenIds.add(copiedSlot.id);
      slotIdMap[slot.id] = copiedSlot.id;
      slots.add(copiedSlot);
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
        final generation = _nextGeneration(
          'assignment',
          sourcePlan.id,
          normalizedTarget,
          assignment.id,
          takenIds,
        );
        final copiedAssignment = assignment.copyWith(
          id: copyId(
            'assignment',
            sourcePlan.id,
            normalizedTarget,
            assignment.id,
            generation,
          ),
          dailyPlanId: targetPlan.id,
          slotId: slotIdMap[assignment.slotId] ?? assignment.slotId,
          startAt: shiftDateTimeByDays(assignment.startAt, dayOffset),
          endAt: shiftDateTimeByDays(assignment.endAt, dayOffset),
          meta: copyMeta,
        );
        takenIds.add(copiedAssignment.id);
        assignments.add(copiedAssignment);
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
        deletedSlots: deletedSlots,
        deletedAssignments: deletedAssignments,
      ),
    );
    return targetPlan;
  }

  Future<void> upsertSlot(FreeTimeSlot slot) async {
    final current = _current;
    validateFreeTimeSlotAgainstPlan(
      slot: slot,
      existingSlots: current.slots.where(
        (item) => item.dailyPlanId == slot.dailyPlanId,
      ),
    );
    final slots = List<FreeTimeSlot>.from(current.slots);
    final index = slots.indexWhere((item) => item.id == slot.id);
    final clock = await _device.next();
    final nowUtc = DateTime.now().toUtc();
    final stamped = slot.copyWith(
      meta: index >= 0
          ? slots[index].meta.touch(clock, nowUtc)
          : SyncMeta.stamp(clock, nowUtc),
    );
    if (index >= 0) {
      slots[index] = stamped;
    } else {
      slots.add(stamped);
    }

    await _persist(
      current.copyWith(
        slots: sortSlots(slots),
        plans: _touchPlans(current.plans, <String>[
          slot.dailyPlanId,
        ], clock, nowUtc),
      ),
    );
  }

  Future<void> deleteSlot(String slotId) async {
    final current = _current;
    final slot = current.slots.where((item) => item.id == slotId).firstOrNull;
    if (slot == null) {
      return;
    }

    final clock = await _device.next();
    final nowUtc = DateTime.now().toUtc();
    final slots = current.slots.where((item) => item.id != slotId).toList();
    final assignments = current.assignments
        .where((item) => item.slotId != slotId)
        .toList();
    final deletedAssignments = <Tombstone>[
      ...current.deletedAssignments,
      for (final item in current.assignments.where(
        (item) => item.slotId == slotId,
      ))
        Tombstone(id: item.id, meta: item.meta.tombstone(clock, nowUtc)),
    ];

    await _persist(
      current.copyWith(
        slots: slots,
        assignments: assignments,
        deletedSlots: <Tombstone>[
          ...current.deletedSlots,
          Tombstone(id: slot.id, meta: slot.meta.tombstone(clock, nowUtc)),
        ],
        deletedAssignments: deletedAssignments,
        plans: _touchPlans(current.plans, <String>[
          slot.dailyPlanId,
        ], clock, nowUtc),
      ),
    );
  }

  Future<void> upsertAssignment(SlotTaskAssignment assignment) async {
    final current = _current;
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
    final clock = await _device.next();
    final nowUtc = DateTime.now().toUtc();
    final stamped = assignment.copyWith(
      meta: index >= 0
          ? assignments[index].meta.touch(clock, nowUtc)
          : SyncMeta.stamp(clock, nowUtc),
    );
    if (index >= 0) {
      assignments[index] = stamped;
    } else {
      assignments.add(stamped);
    }

    final normalized = _normalizeAssignments(assignments, stamped.slotId);
    await _persist(
      current.copyWith(
        assignments: normalized,
        plans: _touchPlans(current.plans, <String>[
          assignment.dailyPlanId,
        ], clock, nowUtc),
      ),
    );
  }

  Future<void> moveAssignmentToSlot({
    required String assignmentId,
    required String targetSlotId,
    String? beforeAssignmentId,
  }) async {
    final current = _current;
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

    final clock = await _device.next();
    final nowUtc = DateTime.now().toUtc();
    final targetAssignments = current.assignmentsForSlot(targetSlot.id);
    final rebuiltTargetAssignments = moveAssignmentToSlotPosition(
      assignment: assignment.copyWith(meta: assignment.meta.touch(clock, nowUtc)),
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
        ], clock, nowUtc),
      ),
    );
  }

  Future<void> deleteAssignment(String assignmentId) async {
    final current = _current;
    final assignment = current.assignments
        .where((item) => item.id == assignmentId)
        .firstOrNull;
    if (assignment == null) {
      return;
    }

    final clock = await _device.next();
    final nowUtc = DateTime.now().toUtc();
    final assignments = current.assignments
        .where((item) => item.id != assignmentId)
        .toList();
    final normalized = _normalizeAssignments(assignments, assignment.slotId);
    await _persist(
      current.copyWith(
        assignments: normalized,
        deletedAssignments: <Tombstone>[
          ...current.deletedAssignments,
          Tombstone(
            id: assignment.id,
            meta: assignment.meta.tombstone(clock, nowUtc),
          ),
        ],
        plans: _touchPlans(current.plans, <String>[
          assignment.dailyPlanId,
        ], clock, nowUtc),
      ),
    );
  }

  /// Publishes the new state immediately so consecutive mutations build on
  /// the latest value, then writes to storage. If the save fails the previous
  /// state is restored so the UI never shows data that was not persisted.
  Future<void> _persist(DailyPlanStateData next) async {
    final previous = state;
    state = AsyncData(next);
    try {
      await _repository.save(next);
    } catch (_) {
      state = previous;
      rethrow;
    }
  }

  List<DailyPlan> _sortPlans(List<DailyPlan> plans) {
    final items = List<DailyPlan>.from(plans);
    items.sort((a, b) => a.date.compareTo(b.date));
    return items;
  }

  List<DailyPlan> _touchPlans(
    List<DailyPlan> plans,
    List<String> planIds,
    Hlc clock,
    DateTime now,
  ) {
    final targets = planIds.toSet();
    return _sortPlans(
      plans.map((plan) {
        return targets.contains(plan.id)
            ? plan.copyWith(updatedAt: now, meta: plan.meta.touch(clock, now))
            : plan;
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
