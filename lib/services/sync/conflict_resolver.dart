import '../../core/content_hash.dart';
import '../../core/hlc.dart';
import '../../core/sync_meta.dart';
import '../../features/daily_plan/domain/daily_plan_models.dart';
import '../../features/task_master/domain/task_models.dart';
import 'conflict_record.dart';
import 'sync_document.dart';

/// Which of the two recorded versions the user picked.
///
/// The wire values are the ones the hub's `resolve_conflict` writes, so a
/// record resolved on the phone and one resolved from MCP are indistinguishable
/// once they meet in a merge.
enum ConflictAdoption { hub, device, current }

extension ConflictAdoptionWire on ConflictAdoption {
  String get wire => switch (this) {
    ConflictAdoption.hub => 'hub',
    ConflictAdoption.device => 'device',
    ConflictAdoption.current => 'current',
  };
}

/// A resolution the caller asked for that cannot be carried out. The message is
/// Japanese and ready to put on screen.
class ConflictResolutionException implements Exception {
  const ConflictResolutionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What one call to [applyConflictResolutions] did.
class ConflictResolutionResult {
  const ConflictResolutionResult({
    required this.document,
    required this.resolved,
    required this.wrote,
  });

  final SyncDocument document;

  /// Records that were open and are now stamped with a resolution.
  final int resolved;

  /// How many of those actually changed an entity. Adopting the version that is
  /// already live only marks the record.
  final int wrote;
}

/// Applies one decision to every open record [where] selects.
///
/// Adopting a side writes it back as a *new* edit rather than rewinding the
/// clock: the id stays, the clock advances and `migrated` is false, so an
/// ordinary merge carries the decision to the PC and to every other device.
/// Adopting a tombstone deletes the entity again. `current` writes nothing and
/// only closes the record.
///
/// Pure apart from [nextClock]: it never touches a store, which is what lets
/// the hub-mode browser and the phone share it.
Future<ConflictResolutionResult> applyConflictResolutions(
  SyncDocument document, {
  required ConflictAdoption adopt,
  required Future<Hlc> Function() nextClock,
  required String resolvedBy,
  bool Function(ConflictRecord record)? where,
  DateTime? at,
}) async {
  final now = (at ?? DateTime.now()).toUtc();
  final stamp = now.toIso8601String();
  var taskMaster = document.taskMaster;
  var dailyPlan = document.dailyPlan;
  final records = <ConflictRecord>[];
  var resolved = 0;
  var wrote = 0;

  for (final record in document.conflicts) {
    if (!record.isOpen || (where != null && !where(record))) {
      records.add(record);
      continue;
    }
    if (adopt != ConflictAdoption.current) {
      final side = record.winner.side == adopt.wire ? record.winner : record.loser;
      final applied = await _adopt(
        record: record,
        side: side,
        taskMaster: taskMaster,
        dailyPlan: dailyPlan,
        nextClock: nextClock,
        now: now,
      );
      taskMaster = applied.taskMaster;
      dailyPlan = applied.dailyPlan;
      if (applied.wrote) wrote += 1;
    }
    records.add(
      record.copyWith(
        resolution: adopt.wire,
        resolvedAt: stamp,
        resolvedBy: resolvedBy,
        // A new clock, so the decision beats the detection — and any earlier
        // decision — the next time two devices meet.
        meta: record.meta.touch(await nextClock(), now),
      ),
    );
    resolved += 1;
  }

  return ConflictResolutionResult(
    document: document.copyWith(
      taskMaster: taskMaster,
      dailyPlan: dailyPlan,
      conflicts: records,
    ),
    resolved: resolved,
    wrote: wrote,
  );
}

typedef _Applied = ({TaskMasterStateData taskMaster, DailyPlanStateData dailyPlan, bool wrote});

/// Writes one adopted snapshot into the two halves of the document.
Future<_Applied> _adopt({
  required ConflictRecord record,
  required ConflictSide side,
  required TaskMasterStateData taskMaster,
  required DailyPlanStateData dailyPlan,
  required Future<Hlc> Function() nextClock,
  required DateTime now,
}) async {
  final snapshot = side.snapshot;
  final id = record.entityId;
  var tasks = taskMaster;
  var plans = dailyPlan;

  if (record.entityType == 'settings') {
    final adopted = snapshot['shareCategories'];
    if (adopted is! bool) {
      throw const ConflictResolutionException('この設定の記録が読めないため採用できません。');
    }
    if (adopted == taskMaster.shareCategories) {
      return (taskMaster: tasks, dailyPlan: plans, wrote: false);
    }
    return (
      taskMaster: taskMaster.copyWith(
        shareCategories: adopted,
        settingsMeta: taskMaster.settingsMeta.touch(await nextClock(), now),
      ),
      dailyPlan: plans,
      wrote: true,
    );
  }

  final live = _liveJson(taskMaster, dailyPlan, record.entityType, id);
  final tombstoned = _isTombstoned(taskMaster, dailyPlan, record.entityType, id);
  final deletedSnapshot = side.isDeleted;

  // Adopting what is already stored is a decision, not an edit.
  if (deletedSnapshot && (tombstoned || live == null)) {
    return (taskMaster: tasks, dailyPlan: plans, wrote: false);
  }
  if (!deletedSnapshot && live != null && contentHash(live) == contentHash(snapshot)) {
    return (taskMaster: tasks, dailyPlan: plans, wrote: false);
  }
  if (live == null && !tombstoned) {
    // Purge dropped the record this conflict names, and a category id alone
    // does not even say which of the two lists it belonged to.
    throw const ConflictResolutionException(
      'この項目はもう端末にありません。「現状のまま」で記録だけ閉じてください。',
    );
  }

  if (deletedSnapshot) {
    final meta = SyncMeta(clock: await nextClock(), updatedAt: now, deletedAt: now);
    final grave = Tombstone(id: id, meta: meta);
    switch (record.entityType) {
      case 'task':
        tasks = taskMaster.copyWith(
          tasks: taskMaster.tasks.where((t) => t.id != id).toList(),
          deletedTasks: _withGrave(taskMaster.deletedTasks, grave),
        );
      case 'category':
        if (taskMaster.mustDoCategories.any((c) => c.id == id)) {
          tasks = taskMaster.copyWith(
            mustDoCategories: taskMaster.mustDoCategories.where((c) => c.id != id).toList(),
            deletedMustDoCategories: _withGrave(taskMaster.deletedMustDoCategories, grave),
          );
        } else {
          tasks = taskMaster.copyWith(
            wantToDoCategories: taskMaster.wantToDoCategories.where((c) => c.id != id).toList(),
            deletedWantToDoCategories: _withGrave(taskMaster.deletedWantToDoCategories, grave),
          );
        }
      case 'plan':
        plans = dailyPlan.copyWith(
          plans: dailyPlan.plans.where((p) => p.id != id).toList(),
          deletedPlans: _withGrave(dailyPlan.deletedPlans, grave),
        );
      case 'slot':
        plans = dailyPlan.copyWith(
          slots: dailyPlan.slots.where((s) => s.id != id).toList(),
          deletedSlots: _withGrave(dailyPlan.deletedSlots, grave),
        );
      case 'assignment':
        plans = dailyPlan.copyWith(
          assignments: dailyPlan.assignments.where((a) => a.id != id).toList(),
          deletedAssignments: _withGrave(dailyPlan.deletedAssignments, grave),
        );
      default:
        throw ConflictResolutionException(
          'この種類（${record.entityType}）の競合はこのアプリでは解決できません。',
        );
    }
    return (taskMaster: tasks, dailyPlan: plans, wrote: true);
  }

  final json = <String, dynamic>{
    ...snapshot,
    ...SyncMeta(clock: await nextClock(), updatedAt: now).toJson(),
  };
  try {
    switch (record.entityType) {
      case 'task':
        final entity = TaskMaster.fromJson(json);
        tasks = taskMaster.copyWith(
          tasks: _replace<TaskMaster>(taskMaster.tasks, entity, (t) => t.id),
          deletedTasks: _withoutGrave(taskMaster.deletedTasks, id),
        );
      case 'category':
        final entity = TaskCategory.fromJson(json);
        if (taskMaster.wantToDoCategories.any((c) => c.id == id) ||
            taskMaster.deletedWantToDoCategories.any((c) => c.id == id)) {
          tasks = taskMaster.copyWith(
            wantToDoCategories:
                _replace<TaskCategory>(taskMaster.wantToDoCategories, entity, (c) => c.id),
            deletedWantToDoCategories: _withoutGrave(taskMaster.deletedWantToDoCategories, id),
          );
        } else {
          tasks = taskMaster.copyWith(
            mustDoCategories:
                _replace<TaskCategory>(taskMaster.mustDoCategories, entity, (c) => c.id),
            deletedMustDoCategories: _withoutGrave(taskMaster.deletedMustDoCategories, id),
          );
        }
      case 'plan':
        final entity = DailyPlan.fromJson(json);
        plans = dailyPlan.copyWith(
          plans: _replace<DailyPlan>(dailyPlan.plans, entity, (p) => p.id),
          deletedPlans: _withoutGrave(dailyPlan.deletedPlans, id),
        );
      case 'slot':
        final entity = FreeTimeSlot.fromJson(json);
        plans = dailyPlan.copyWith(
          slots: _replace<FreeTimeSlot>(dailyPlan.slots, entity, (s) => s.id),
          deletedSlots: _withoutGrave(dailyPlan.deletedSlots, id),
        );
      case 'assignment':
        final entity = SlotTaskAssignment.fromJson(json);
        plans = dailyPlan.copyWith(
          assignments: _replace<SlotTaskAssignment>(dailyPlan.assignments, entity, (a) => a.id),
          deletedAssignments: _withoutGrave(dailyPlan.deletedAssignments, id),
        );
      default:
        throw ConflictResolutionException(
          'この種類（${record.entityType}）の競合はこのアプリでは解決できません。',
        );
    }
  } on FormatException catch (error) {
    throw ConflictResolutionException('記録された内容を復元できませんでした（$error）。');
  } on TypeError {
    throw const ConflictResolutionException('記録された内容を復元できませんでした。');
  }
  return (taskMaster: tasks, dailyPlan: plans, wrote: true);
}

/// The stored version of the entity as JSON, or null when nothing live holds
/// the id. Comparing JSON keeps the check identical to the hub's `contentHash`.
Map<String, dynamic>? _liveJson(
  TaskMasterStateData taskMaster,
  DailyPlanStateData dailyPlan,
  String entityType,
  String id,
) {
  Map<String, dynamic>? first<T>(List<T> list, String Function(T) idOf, Map<String, dynamic> Function(T) toJson) {
    for (final item in list) {
      if (idOf(item) == id) return toJson(item);
    }
    return null;
  }

  return switch (entityType) {
    'task' => first<TaskMaster>(taskMaster.tasks, (t) => t.id, (t) => t.toJson()),
    'category' =>
      first<TaskCategory>(taskMaster.mustDoCategories, (c) => c.id, (c) => c.toJson()) ??
          first<TaskCategory>(taskMaster.wantToDoCategories, (c) => c.id, (c) => c.toJson()),
    'plan' => first<DailyPlan>(dailyPlan.plans, (p) => p.id, (p) => p.toJson()),
    'slot' => first<FreeTimeSlot>(dailyPlan.slots, (s) => s.id, (s) => s.toJson()),
    'assignment' =>
      first<SlotTaskAssignment>(dailyPlan.assignments, (a) => a.id, (a) => a.toJson()),
    _ => null,
  };
}

bool _isTombstoned(
  TaskMasterStateData taskMaster,
  DailyPlanStateData dailyPlan,
  String entityType,
  String id,
) {
  bool has(List<Tombstone> list) => list.any((t) => t.id == id);
  return switch (entityType) {
    'task' => has(taskMaster.deletedTasks),
    'category' =>
      has(taskMaster.deletedMustDoCategories) || has(taskMaster.deletedWantToDoCategories),
    'plan' => has(dailyPlan.deletedPlans),
    'slot' => has(dailyPlan.deletedSlots),
    'assignment' => has(dailyPlan.deletedAssignments),
    _ => false,
  };
}

/// Replaces the entity in place when the id is already there, appends it when
/// it is not: the document's order is not meaningful, but keeping it stable
/// makes a diff of data.json readable.
List<T> _replace<T>(List<T> list, T entity, String Function(T) idOf) {
  final out = List<T>.from(list);
  final index = out.indexWhere((item) => idOf(item) == idOf(entity));
  if (index < 0) {
    out.add(entity);
  } else {
    out[index] = entity;
  }
  return out;
}

List<Tombstone> _withGrave(List<Tombstone> list, Tombstone grave) =>
    <Tombstone>[...list.where((t) => t.id != grave.id), grave];

List<Tombstone> _withoutGrave(List<Tombstone> list, String id) =>
    list.where((t) => t.id != id).toList();
