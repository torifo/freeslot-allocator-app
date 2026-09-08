import 'dart:convert';
import 'dart:math';

import '../../../core/hlc.dart';
import '../../../core/sync_meta.dart';
import '../../../core/tombstone.dart';
import '../../task_master/domain/task_models.dart';

export '../../../core/tombstone.dart' show Tombstone;

DateTime dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// `YYYY-MM-DD` for the calendar day a [DailyPlan] belongs to. The day is a
/// calendar label, not an instant, so it is never converted to UTC.
String formatDateKey(DateTime value) {
  final d = dateOnly(value);
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// Accepts both `YYYY-MM-DD` (v2) and a full ISO datetime (v1).
DateTime parseDateKey(String value) {
  final parts = value.split('T').first.split('-');
  return DateTime(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
}

class DailyPlan {
  DailyPlan({
    required this.id,
    required this.date,
    required this.createdAt,
    required this.updatedAt,
    SyncMeta? meta,
  }) : meta = meta ?? SyncMeta.migratedDefault;

  static const Set<String> jsonKeys = <String>{'id', 'date', 'createdAt'};

  final String id;
  final DateTime date;
  final DateTime createdAt;
  final DateTime updatedAt;
  final SyncMeta meta;

  DailyPlan copyWith({
    String? id,
    DateTime? date,
    DateTime? createdAt,
    DateTime? updatedAt,
    SyncMeta? meta,
  }) {
    return DailyPlan(
      id: id ?? this.id,
      date: date ?? this.date,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      meta: meta ?? this.meta,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'date': formatDateKey(date),
    'createdAt': createdAt.toUtc().toIso8601String(),
    // updatedAt は meta 側だけを正とする。表示用フィールドは meta から復元する。
    ...meta.toJson(),
    'updatedAt': meta.updatedAt.toUtc().toIso8601String(),
  };

  factory DailyPlan.fromJson(Map<String, dynamic> json) {
    final rawMeta = SyncMeta.fromJson(json, knownKeys: jsonKeys);
    final legacyUpdatedAt = DateTime.parse(json['updatedAt'] as String).toUtc();
    final meta = rawMeta.migrated
        ? SyncMeta(
            clock: Hlc.migrated,
            updatedAt: legacyUpdatedAt,
            migrated: true,
            extra: rawMeta.extra,
          )
        : rawMeta;
    return DailyPlan(
      id: json['id'] as String,
      date: parseDateKey(json['date'] as String),
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      updatedAt: meta.updatedAt,
      meta: meta,
    );
  }
}

class FreeTimeSlot {
  FreeTimeSlot({
    required this.id,
    required this.dailyPlanId,
    required this.startAt,
    required this.endAt,
    this.label = '',
    SyncMeta? meta,
  }) : meta = meta ?? SyncMeta.migratedDefault;

  static const Set<String> jsonKeys = <String>{
    'id',
    'dailyPlanId',
    'startAt',
    'endAt',
    'label',
  };

  final String id;
  final String dailyPlanId;
  final DateTime startAt;
  final DateTime endAt;
  final String label;
  final SyncMeta meta;

  int get durationMinutes => max(0, endAt.difference(startAt).inMinutes);

  FreeTimeSlot copyWith({
    String? id,
    String? dailyPlanId,
    DateTime? startAt,
    DateTime? endAt,
    String? label,
    SyncMeta? meta,
  }) {
    return FreeTimeSlot(
      id: id ?? this.id,
      dailyPlanId: dailyPlanId ?? this.dailyPlanId,
      startAt: startAt ?? this.startAt,
      endAt: endAt ?? this.endAt,
      label: label ?? this.label,
      meta: meta ?? this.meta,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'dailyPlanId': dailyPlanId,
    'startAt': startAt.toUtc().toIso8601String(),
    'endAt': endAt.toUtc().toIso8601String(),
    'label': label,
    ...meta.toJson(),
  };

  factory FreeTimeSlot.fromJson(Map<String, dynamic> json) {
    return FreeTimeSlot(
      id: json['id'] as String,
      dailyPlanId: json['dailyPlanId'] as String,
      startAt: DateTime.parse(json['startAt'] as String).toLocal(),
      endAt: DateTime.parse(json['endAt'] as String).toLocal(),
      label: json['label'] as String? ?? '',
      meta: SyncMeta.fromJson(json, knownKeys: jsonKeys),
    );
  }
}

class SlotTaskAssignment {
  SlotTaskAssignment({
    required this.id,
    required this.dailyPlanId,
    required this.slotId,
    required this.taskId,
    required this.taskTitle,
    required this.taskKind,
    required this.startAt,
    required this.endAt,
    required this.sortOrder,
    this.categoryId,
    this.categoryName,
    this.memo = '',
    SyncMeta? meta,
  }) : meta = meta ?? SyncMeta.migratedDefault;

  static const Set<String> jsonKeys = <String>{
    'id',
    'dailyPlanId',
    'slotId',
    'taskId',
    'taskTitle',
    'taskKind',
    'startAt',
    'endAt',
    'sortOrder',
    'categoryId',
    'categoryName',
    'memo',
  };

  final String id;
  final String dailyPlanId;
  final String slotId;
  final String taskId;
  final String taskTitle;
  final TaskKind taskKind;
  final DateTime startAt;
  final DateTime endAt;
  final int sortOrder;
  final String? categoryId;
  final String? categoryName;
  final String memo;
  final SyncMeta meta;

  int get durationMinutes => max(0, endAt.difference(startAt).inMinutes);

  SlotTaskAssignment copyWith({
    String? id,
    String? dailyPlanId,
    String? slotId,
    String? taskId,
    String? taskTitle,
    TaskKind? taskKind,
    DateTime? startAt,
    DateTime? endAt,
    int? sortOrder,
    String? categoryId,
    bool clearCategory = false,
    String? categoryName,
    bool clearCategoryName = false,
    String? memo,
    SyncMeta? meta,
  }) {
    return SlotTaskAssignment(
      id: id ?? this.id,
      dailyPlanId: dailyPlanId ?? this.dailyPlanId,
      slotId: slotId ?? this.slotId,
      taskId: taskId ?? this.taskId,
      taskTitle: taskTitle ?? this.taskTitle,
      taskKind: taskKind ?? this.taskKind,
      startAt: startAt ?? this.startAt,
      endAt: endAt ?? this.endAt,
      sortOrder: sortOrder ?? this.sortOrder,
      categoryId: clearCategory ? null : (categoryId ?? this.categoryId),
      categoryName: clearCategoryName
          ? null
          : (categoryName ?? this.categoryName),
      memo: memo ?? this.memo,
      meta: meta ?? this.meta,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'dailyPlanId': dailyPlanId,
    'slotId': slotId,
    'taskId': taskId,
    'taskTitle': taskTitle,
    'taskKind': taskKind.storageKey,
    'startAt': startAt.toUtc().toIso8601String(),
    'endAt': endAt.toUtc().toIso8601String(),
    'sortOrder': sortOrder,
    'categoryId': categoryId,
    'categoryName': categoryName,
    'memo': memo,
    ...meta.toJson(),
  };

  factory SlotTaskAssignment.fromJson(Map<String, dynamic> json) {
    return SlotTaskAssignment(
      id: json['id'] as String,
      dailyPlanId: json['dailyPlanId'] as String,
      slotId: json['slotId'] as String,
      taskId: json['taskId'] as String,
      taskTitle: json['taskTitle'] as String,
      taskKind: TaskKindX.fromStorageKey(json['taskKind'] as String),
      startAt: DateTime.parse(json['startAt'] as String).toLocal(),
      endAt: DateTime.parse(json['endAt'] as String).toLocal(),
      sortOrder: json['sortOrder'] as int? ?? 0,
      categoryId: json['categoryId'] as String?,
      categoryName: json['categoryName'] as String?,
      memo: json['memo'] as String? ?? '',
      meta: SyncMeta.fromJson(json, knownKeys: jsonKeys),
    );
  }
}

class DailyPlanStateData {
  DailyPlanStateData({
    required List<DailyPlan> plans,
    required List<FreeTimeSlot> slots,
    required List<SlotTaskAssignment> assignments,
    List<Tombstone> deletedPlans = const <Tombstone>[],
    List<Tombstone> deletedSlots = const <Tombstone>[],
    List<Tombstone> deletedAssignments = const <Tombstone>[],
  }) : assert(
         idsDisjoint(plans.map((item) => item.id), deletedPlans),
         'a plan id cannot be both live and tombstoned',
       ),
       assert(
         idsDisjoint(slots.map((item) => item.id), deletedSlots),
         'a slot id cannot be both live and tombstoned',
       ),
       assert(
         idsDisjoint(assignments.map((item) => item.id), deletedAssignments),
         'an assignment id cannot be both live and tombstoned',
       ),
       plans = List<DailyPlan>.unmodifiable(plans),
       slots = List<FreeTimeSlot>.unmodifiable(slots),
       assignments = List<SlotTaskAssignment>.unmodifiable(assignments),
       deletedPlans = List<Tombstone>.unmodifiable(deletedPlans),
       deletedSlots = List<Tombstone>.unmodifiable(deletedSlots),
       deletedAssignments = List<Tombstone>.unmodifiable(deletedAssignments);

  final List<DailyPlan> plans;
  final List<FreeTimeSlot> slots;
  final List<SlotTaskAssignment> assignments;
  final List<Tombstone> deletedPlans;
  final List<Tombstone> deletedSlots;
  final List<Tombstone> deletedAssignments;

  factory DailyPlanStateData.initial() {
    return DailyPlanStateData(
      plans: <DailyPlan>[],
      slots: <FreeTimeSlot>[],
      assignments: <SlotTaskAssignment>[],
    );
  }

  DailyPlanStateData copyWith({
    List<DailyPlan>? plans,
    List<FreeTimeSlot>? slots,
    List<SlotTaskAssignment>? assignments,
    List<Tombstone>? deletedPlans,
    List<Tombstone>? deletedSlots,
    List<Tombstone>? deletedAssignments,
  }) {
    return DailyPlanStateData(
      plans: plans ?? this.plans,
      slots: slots ?? this.slots,
      assignments: assignments ?? this.assignments,
      deletedPlans: deletedPlans ?? this.deletedPlans,
      deletedSlots: deletedSlots ?? this.deletedSlots,
      deletedAssignments: deletedAssignments ?? this.deletedAssignments,
    );
  }

  DailyPlan? planForDate(DateTime value) {
    final target = dateOnly(value);
    return plans.where((plan) => plan.date == target).firstOrNull;
  }

  List<FreeTimeSlot> slotsForPlan(String planId) {
    final items = slots.where((slot) => slot.dailyPlanId == planId).toList();
    items.sort((a, b) => a.startAt.compareTo(b.startAt));
    return items;
  }

  List<SlotTaskAssignment> assignmentsForSlot(String slotId) {
    final items = assignments.where((item) => item.slotId == slotId).toList();
    items.sort((a, b) {
      final startCompare = a.startAt.compareTo(b.startAt);
      if (startCompare != 0) {
        return startCompare;
      }
      return a.sortOrder.compareTo(b.sortOrder);
    });
    return items;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'plans': <Map<String, dynamic>>[
      ...plans.map((item) => item.toJson()),
      ...deletedPlans.map((item) => item.toJson()),
    ],
    'slots': <Map<String, dynamic>>[
      ...slots.map((item) => item.toJson()),
      ...deletedSlots.map((item) => item.toJson()),
    ],
    'assignments': <Map<String, dynamic>>[
      ...assignments.map((item) => item.toJson()),
      ...deletedAssignments.map((item) => item.toJson()),
    ],
  };

  String encode() => jsonEncode(toJson());

  factory DailyPlanStateData.fromJson(
    Map<String, dynamic> json, {
    bool strict = false,
  }) {
    final plans = splitDeleted(json['plans'], strict: strict);
    final slots = splitDeleted(json['slots'], strict: strict);
    final assignments = splitDeleted(json['assignments'], strict: strict);
    return DailyPlanStateData(
      plans: parseLive(plans.live, DailyPlan.fromJson, strict: strict),
      slots: parseLive(slots.live, FreeTimeSlot.fromJson, strict: strict),
      assignments: parseLive(
        assignments.live,
        SlotTaskAssignment.fromJson,
        strict: strict,
      ),
      // A payload that carries both a live record and its tombstone is
      // corrupt; keep the live record so nothing is silently lost.
      deletedPlans: withoutTombstonesFor(
        plans.tombstones,
        plans.live.map((item) => item['id'] as String? ?? ''),
      ),
      deletedSlots: withoutTombstonesFor(
        slots.tombstones,
        slots.live.map((item) => item['id'] as String? ?? ''),
      ),
      deletedAssignments: withoutTombstonesFor(
        assignments.tombstones,
        assignments.live.map((item) => item['id'] as String? ?? ''),
      ),
    );
  }

  /// Decodes persisted state, falling back to an empty state when the stored
  /// payload is not valid JSON or is not a JSON object.
  factory DailyPlanStateData.decode(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map<String, dynamic>) {
        return DailyPlanStateData.initial();
      }
      return DailyPlanStateData.fromJson(decoded);
    } on FormatException {
      return DailyPlanStateData.initial();
    }
  }
}
