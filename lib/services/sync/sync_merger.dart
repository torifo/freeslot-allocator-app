import 'dart:convert';

import '../../core/content_hash.dart';
import '../../core/sync_meta.dart';
import '../../features/daily_plan/domain/daily_plan_models.dart';
import '../../features/task_master/domain/task_models.dart';
import 'sync_document.dart';
import 'sync_progress.dart';

class MergeResult {
  const MergeResult({required this.document, required this.warnings});

  final SyncDocument document;
  final List<String> warnings;

  /// Counts what the merge changed, using the hub's rules (`summarize` in
  /// `tools/hub/src/sync-engine.ts`) so an out-of-band apply reports the same
  /// numbers a LAN sync would.
  SyncSummary summaryAgainst(SyncDocument before) {
    final a = _indexEntities(before);
    final b = _indexEntities(document);
    var added = 0, updated = 0, deleted = 0, removed = 0;
    for (final entry in b.entries) {
      final prev = a[entry.key];
      if (prev == null) {
        if (!entry.value.deleted) added += 1;
        continue;
      }
      if (entry.value.deleted && !prev.deleted) {
        deleted += 1;
      } else if (!entry.value.deleted && entry.value.clock != prev.clock) {
        updated += 1;
      }
    }
    for (final id in a.keys) {
      if (!b.containsKey(id)) removed += 1;
    }
    return SyncSummary(
      added: added,
      updated: updated,
      deleted: deleted,
      removed: removed,
      warnings: warnings.length,
    );
  }
}

typedef _Counted = ({bool deleted, String clock});

Map<String, _Counted> _indexEntities(SyncDocument d) {
  final out = <String, _Counted>{};
  void live(String id, SyncMeta meta) =>
      out[id] = (deleted: false, clock: meta.clock.toString());
  void dead(Tombstone t) => out[t.id] = (deleted: true, clock: t.meta.clock.toString());

  for (final t in d.taskMaster.tasks) {
    live(t.id, t.meta);
  }
  for (final c in [...d.taskMaster.mustDoCategories, ...d.taskMaster.wantToDoCategories]) {
    live(c.id, c.meta);
  }
  for (final p in d.dailyPlan.plans) {
    live(p.id, p.meta);
  }
  for (final s in d.dailyPlan.slots) {
    live(s.id, s.meta);
  }
  for (final a in d.dailyPlan.assignments) {
    live(a.id, a.meta);
  }
  for (final t in [
    ...d.taskMaster.deletedTasks,
    ...d.taskMaster.deletedMustDoCategories,
    ...d.taskMaster.deletedWantToDoCategories,
    ...d.dailyPlan.deletedPlans,
    ...d.dailyPlan.deletedSlots,
    ...d.dailyPlan.deletedAssignments,
  ]) {
    dead(t);
  }
  return out;
}

/// One live-or-dead record in a form the merge can compare.
class _Record {
  _Record.live(this.id, this.json, this.meta) : tombstone = null;
  _Record.dead(Tombstone t)
    : id = t.id,
      json = null,
      meta = t.meta,
      tombstone = t;

  final String id;
  final Map<String, dynamic>? json;
  final SyncMeta meta;
  final Tombstone? tombstone;

  bool get isDead => tombstone != null;
}

class _MergedList<T> {
  const _MergedList(this.live, this.dead);

  final List<T> live;
  final List<Tombstone> dead;
}

/// Entity-level merge per the design spec. Pure; never mutates its inputs.
/// Only the entity payload (tasks, categories, plans, slots, assignments,
/// tombstones) is order-independent — `merge(a, b)` and `merge(b, a)`
/// produce the same entities. `deviceId` and `lastSyncAt` on the result
/// always come from argument `a`, so the two calls differ in those fields.
///
/// Invariant checking (design rule 8) is the caller's responsibility; this
/// merger does not run `InvariantChecker` itself.
class SyncMerger {
  static MergeResult merge(SyncDocument a, SyncDocument b) {
    final warnings = <String>[];

    final tasks = _mergeLists<TaskMaster>(
      aLive: a.taskMaster.tasks,
      aDead: a.taskMaster.deletedTasks,
      bLive: b.taskMaster.tasks,
      bDead: b.taskMaster.deletedTasks,
      toJson: (t) => t.toJson(),
      fromJson: TaskMaster.fromJson,
      metaOf: (t) => t.meta,
    );
    final mustDo = _mergeLists<TaskCategory>(
      aLive: a.taskMaster.mustDoCategories,
      aDead: a.taskMaster.deletedMustDoCategories,
      bLive: b.taskMaster.mustDoCategories,
      bDead: b.taskMaster.deletedMustDoCategories,
      toJson: (c) => c.toJson(),
      fromJson: TaskCategory.fromJson,
      metaOf: (c) => c.meta,
    );
    final wantToDo = _mergeLists<TaskCategory>(
      aLive: a.taskMaster.wantToDoCategories,
      aDead: a.taskMaster.deletedWantToDoCategories,
      bLive: b.taskMaster.wantToDoCategories,
      bDead: b.taskMaster.deletedWantToDoCategories,
      toJson: (c) => c.toJson(),
      fromJson: TaskCategory.fromJson,
      metaOf: (c) => c.meta,
    );
    final settingsWinner = _pick(
      _Record.live(
        'settings',
        <String, dynamic>{'shareCategories': a.taskMaster.shareCategories},
        a.taskMaster.settingsMeta,
      ),
      _Record.live(
        'settings',
        <String, dynamic>{'shareCategories': b.taskMaster.shareCategories},
        b.taskMaster.settingsMeta,
      ),
    );

    final plans = _mergeLists<DailyPlan>(
      aLive: a.dailyPlan.plans,
      aDead: a.dailyPlan.deletedPlans,
      bLive: b.dailyPlan.plans,
      bDead: b.dailyPlan.deletedPlans,
      toJson: (p) => p.toJson(),
      fromJson: DailyPlan.fromJson,
      metaOf: (p) => p.meta,
    );
    final slots = _mergeLists<FreeTimeSlot>(
      aLive: a.dailyPlan.slots,
      aDead: a.dailyPlan.deletedSlots,
      bLive: b.dailyPlan.slots,
      bDead: b.dailyPlan.deletedSlots,
      toJson: (s) => s.toJson(),
      fromJson: FreeTimeSlot.fromJson,
      metaOf: (s) => s.meta,
    );
    final assignments = _mergeLists<SlotTaskAssignment>(
      aLive: a.dailyPlan.assignments,
      aDead: a.dailyPlan.deletedAssignments,
      bLive: b.dailyPlan.assignments,
      bDead: b.dailyPlan.deletedAssignments,
      toJson: (x) => x.toJson(),
      fromJson: SlotTaskAssignment.fromJson,
      metaOf: (x) => x.meta,
    );

    // Referential warnings (non-destructive: data is kept as-is).
    final liveCategoryIds = <String>{
      ...mustDo.live.map((c) => c.id),
      ...wantToDo.live.map((c) => c.id),
    };
    for (final task in tasks.live) {
      final categoryId = task.categoryId;
      if (categoryId != null && !liveCategoryIds.contains(categoryId)) {
        warnings.add(
          'task ${task.id} references missing category $categoryId',
        );
      }
    }
    final liveSlotIds = slots.live.map((s) => s.id).toSet();
    for (final assignment in assignments.live) {
      if (!liveSlotIds.contains(assignment.slotId)) {
        warnings.add(
          'assignment ${assignment.id} references missing slot '
          '${assignment.slotId}',
        );
      }
    }
    warnings.sort();

    final document = SyncDocument(
      exportedAt: a.exportedAt.isAfter(b.exportedAt) ? a.exportedAt : b.exportedAt,
      // The envelope identity stays with the caller's own document; only the
      // entity payload is order independent.
      deviceId: a.deviceId,
      lastSyncAt: a.lastSyncAt,
      purgedBefore: _later(a.purgedBefore, b.purgedBefore),
      taskMaster: TaskMasterStateData(
        tasks: tasks.live,
        mustDoCategories: mustDo.live,
        wantToDoCategories: wantToDo.live,
        shareCategories: settingsWinner.json!['shareCategories'] as bool,
        settingsMeta: settingsWinner.meta,
        deletedTasks: tasks.dead,
        deletedMustDoCategories: mustDo.dead,
        deletedWantToDoCategories: wantToDo.dead,
      ),
      dailyPlan: DailyPlanStateData(
        plans: plans.live,
        slots: slots.live,
        assignments: assignments.live,
        deletedPlans: plans.dead,
        deletedSlots: slots.dead,
        deletedAssignments: assignments.dead,
      ),
    );
    return MergeResult(document: document, warnings: warnings);
  }

  /// The later of two instants, compared as instants and never as text.
  ///
  /// `purgedBefore` arrives as an ISO-8601 string that may carry any offset,
  /// so a lexicographic comparison would rank `2026-01-01T09:00+09:00` above
  /// the identical `2026-01-01T00:00Z` and walk the value backwards, which
  /// resurrects every tombstone the hub already purged. `SyncDocument` parses
  /// both sides to UTC and this picks by [DateTime.isAfter]; the value is
  /// written back out as UTC ISO with `Z`.
  static DateTime? _later(DateTime? x, DateTime? y) {
    if (x == null) return y;
    if (y == null) return x;
    return x.isAfter(y) ? x : y;
  }

  /// Rule 3: the larger clock wins. Equal clocks (only possible for migrated
  /// records) fall back to the content hash, and identical content falls back
  /// to the canonical meta, so the pick never depends on argument order.
  static _Record _pick(_Record x, _Record y) {
    final cmp = x.meta.clock.compareTo(y.meta.clock);
    if (cmp > 0) return x;
    if (cmp < 0) return y;
    final hx = x.isDead ? '' : contentHash(x.json!);
    final hy = y.isDead ? '' : contentHash(y.json!);
    final byHash = hx.compareTo(hy);
    if (byHash != 0) return byHash > 0 ? x : y;
    // Same clock and same content: the records only differ in meta (a v1
    // record can carry a different updatedAt on each device). Comparing the
    // serialized meta keeps the choice deterministic in both directions.
    return _metaKey(x).compareTo(_metaKey(y)) <= 0 ? x : y;
  }

  static String _metaKey(_Record record) {
    final meta = record.meta.toJson();
    final keys = meta.keys.toList()..sort();
    return jsonEncode(<String, dynamic>{for (final k in keys) k: meta[k]});
  }

  static _MergedList<T> _mergeLists<T>({
    required List<T> aLive,
    required List<Tombstone> aDead,
    required List<T> bLive,
    required List<Tombstone> bDead,
    required Map<String, dynamic> Function(T) toJson,
    required T Function(Map<String, dynamic>) fromJson,
    required SyncMeta Function(T) metaOf,
  }) {
    Map<String, _Record> index(List<T> live, List<Tombstone> dead) {
      final records = <String, _Record>{};
      for (final item in live) {
        final json = toJson(item);
        final id = json['id'] as String;
        records[id] = _Record.live(id, json, metaOf(item));
      }
      for (final t in dead) {
        records[t.id] = _Record.dead(t);
      }
      return records;
    }

    final ia = index(aLive, aDead);
    final ib = index(bLive, bDead);
    final ids = <String>{...ia.keys, ...ib.keys}.toList()..sort();
    final live = <T>[];
    final deadOut = <Tombstone>[];
    for (final id in ids) {
      final x = ia[id];
      final y = ib[id];
      final winner = x == null ? y! : (y == null ? x : _pick(x, y));
      if (winner.isDead) {
        deadOut.add(winner.tombstone!);
      } else {
        live.add(fromJson(winner.json!));
      }
    }
    return _MergedList<T>(live, deadOut);
  }
}
