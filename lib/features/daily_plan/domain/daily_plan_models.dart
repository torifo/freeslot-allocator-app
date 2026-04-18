import 'dart:convert';

import '../../task_master/domain/task_models.dart';

DateTime dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

class DailyPlan {
  const DailyPlan({
    required this.id,
    required this.date,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final DateTime date;
  final DateTime createdAt;
  final DateTime updatedAt;

  DailyPlan copyWith({
    String? id,
    DateTime? date,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return DailyPlan(
      id: id ?? this.id,
      date: date ?? this.date,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'date': date.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory DailyPlan.fromJson(Map<String, dynamic> json) {
    return DailyPlan(
      id: json['id'] as String,
      date: dateOnly(DateTime.parse(json['date'] as String)),
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }
}

class FreeTimeSlot {
  const FreeTimeSlot({
    required this.id,
    required this.dailyPlanId,
    required this.startAt,
    required this.endAt,
    this.label = '',
  });

  final String id;
  final String dailyPlanId;
  final DateTime startAt;
  final DateTime endAt;
  final String label;

  int get durationMinutes => endAt.difference(startAt).inMinutes;

  FreeTimeSlot copyWith({
    String? id,
    String? dailyPlanId,
    DateTime? startAt,
    DateTime? endAt,
    String? label,
  }) {
    return FreeTimeSlot(
      id: id ?? this.id,
      dailyPlanId: dailyPlanId ?? this.dailyPlanId,
      startAt: startAt ?? this.startAt,
      endAt: endAt ?? this.endAt,
      label: label ?? this.label,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'dailyPlanId': dailyPlanId,
    'startAt': startAt.toIso8601String(),
    'endAt': endAt.toIso8601String(),
    'label': label,
  };

  factory FreeTimeSlot.fromJson(Map<String, dynamic> json) {
    return FreeTimeSlot(
      id: json['id'] as String,
      dailyPlanId: json['dailyPlanId'] as String,
      startAt: DateTime.parse(json['startAt'] as String),
      endAt: DateTime.parse(json['endAt'] as String),
      label: json['label'] as String? ?? '',
    );
  }
}

class SlotTaskAssignment {
  const SlotTaskAssignment({
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
  });

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

  int get durationMinutes => endAt.difference(startAt).inMinutes;

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
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'dailyPlanId': dailyPlanId,
    'slotId': slotId,
    'taskId': taskId,
    'taskTitle': taskTitle,
    'taskKind': taskKind.storageKey,
    'startAt': startAt.toIso8601String(),
    'endAt': endAt.toIso8601String(),
    'sortOrder': sortOrder,
    'categoryId': categoryId,
    'categoryName': categoryName,
    'memo': memo,
  };

  factory SlotTaskAssignment.fromJson(Map<String, dynamic> json) {
    return SlotTaskAssignment(
      id: json['id'] as String,
      dailyPlanId: json['dailyPlanId'] as String,
      slotId: json['slotId'] as String,
      taskId: json['taskId'] as String,
      taskTitle: json['taskTitle'] as String,
      taskKind: TaskKindX.fromStorageKey(json['taskKind'] as String),
      startAt: DateTime.parse(json['startAt'] as String),
      endAt: DateTime.parse(json['endAt'] as String),
      sortOrder: json['sortOrder'] as int? ?? 0,
      categoryId: json['categoryId'] as String?,
      categoryName: json['categoryName'] as String?,
      memo: json['memo'] as String? ?? '',
    );
  }
}

class DailyPlanStateData {
  const DailyPlanStateData({
    required this.plans,
    required this.slots,
    required this.assignments,
  });

  final List<DailyPlan> plans;
  final List<FreeTimeSlot> slots;
  final List<SlotTaskAssignment> assignments;

  factory DailyPlanStateData.initial() {
    return const DailyPlanStateData(
      plans: <DailyPlan>[],
      slots: <FreeTimeSlot>[],
      assignments: <SlotTaskAssignment>[],
    );
  }

  DailyPlanStateData copyWith({
    List<DailyPlan>? plans,
    List<FreeTimeSlot>? slots,
    List<SlotTaskAssignment>? assignments,
  }) {
    return DailyPlanStateData(
      plans: plans ?? this.plans,
      slots: slots ?? this.slots,
      assignments: assignments ?? this.assignments,
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
    'plans': plans.map((item) => item.toJson()).toList(),
    'slots': slots.map((item) => item.toJson()).toList(),
    'assignments': assignments.map((item) => item.toJson()).toList(),
  };

  String encode() => jsonEncode(toJson());

  factory DailyPlanStateData.fromJson(Map<String, dynamic> json) {
    return DailyPlanStateData(
      plans: (json['plans'] as List<dynamic>? ?? <dynamic>[])
          .map(
            (dynamic item) => DailyPlan.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
      slots: (json['slots'] as List<dynamic>? ?? <dynamic>[])
          .map(
            (dynamic item) =>
                FreeTimeSlot.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
      assignments: (json['assignments'] as List<dynamic>? ?? <dynamic>[])
          .map(
            (dynamic item) =>
                SlotTaskAssignment.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
    );
  }

  factory DailyPlanStateData.decode(String source) {
    return DailyPlanStateData.fromJson(
      jsonDecode(source) as Map<String, dynamic>,
    );
  }
}
