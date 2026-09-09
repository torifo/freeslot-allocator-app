import 'dart:convert';

import '../../core/content_hash.dart';
import '../../core/hlc.dart';
import '../../core/sync_meta.dart';
import '../../features/daily_plan/domain/daily_plan_models.dart';
import '../../features/task_master/domain/task_models.dart';
import 'conflict_record.dart';
import 'sync_document.dart';
import 'sync_progress.dart';

class MergeResult {
  const MergeResult({
    required this.document,
    required this.warnings,
    this.conflicts = const <ConflictRecord>[],
  });

  final SyncDocument document;
  final List<String> warnings;

  /// Only what this merge newly detected; `document.conflicts` also holds the
  /// records either side already carried.
  final List<ConflictRecord> conflicts;

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
  _Record.live(this.id, this.json, this.meta, {Map<String, dynamic>? raw})
    : tombstone = null,
      _raw = raw;
  _Record.dead(Tombstone t)
    : id = t.id,
      json = null,
      meta = t.meta,
      tombstone = t,
      _raw = null;

  final String id;

  /// What `contentHash` sees — the model's `toJson()`, meta included for
  /// entities and only `shareCategories` for settings.
  final Map<String, dynamic>? json;
  final SyncMeta meta;
  final Tombstone? tombstone;
  final Map<String, dynamic>? _raw;

  bool get isDead => tombstone != null;

  /// The whole record as it sits in the document, meta included. This is what
  /// a conflict snapshot stores and what `changedAt` reads, matching the raw
  /// entity the TypeScript merger works on.
  Map<String, dynamic> get raw => _raw ?? json ?? tombstone!.toJson();
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
  static MergeResult merge(
    SyncDocument a,
    SyncDocument b, {
    DateTime? lastAgreedAt,
    String? detectedBy,
    DateTime? detectedAt,
  }) {
    final warnings = <String>[];
    final detected = <ConflictRecord>[];
    // Null (the default) disables detection entirely, which is what the first
    // sync — and every caller written before Plan 3b — wants.
    final agreed = lastAgreedAt?.toUtc().millisecondsSinceEpoch;
    final at = (detectedAt ?? DateTime.now().toUtc()).toUtc().toIso8601String();
    final by = detectedBy ?? 'unknown';
    void Function(_Record, _Record, String)? detector(String kind) {
      if (agreed == null) return null;
      return (x, y, id) {
        final found = _detect(x, y, kind, id, agreed, at, by);
        if (found != null) detected.add(found);
      };
    }

    final tasks = _mergeLists<TaskMaster>(
      aLive: a.taskMaster.tasks,
      aDead: a.taskMaster.deletedTasks,
      bLive: b.taskMaster.tasks,
      bDead: b.taskMaster.deletedTasks,
      toJson: (t) => t.toJson(),
      fromJson: TaskMaster.fromJson,
      metaOf: (t) => t.meta,
      detector: detector('task'),
    );
    final mustDo = _mergeLists<TaskCategory>(
      aLive: a.taskMaster.mustDoCategories,
      aDead: a.taskMaster.deletedMustDoCategories,
      bLive: b.taskMaster.mustDoCategories,
      bDead: b.taskMaster.deletedMustDoCategories,
      toJson: (c) => c.toJson(),
      fromJson: TaskCategory.fromJson,
      metaOf: (c) => c.meta,
      detector: detector('category'),
    );
    final wantToDo = _mergeLists<TaskCategory>(
      aLive: a.taskMaster.wantToDoCategories,
      aDead: a.taskMaster.deletedWantToDoCategories,
      bLive: b.taskMaster.wantToDoCategories,
      bDead: b.taskMaster.deletedWantToDoCategories,
      toJson: (c) => c.toJson(),
      fromJson: TaskCategory.fromJson,
      metaOf: (c) => c.meta,
      detector: detector('category'),
    );
    _Record settingsRecord(TaskMasterStateData d) => _Record.live(
      'settings',
      <String, dynamic>{'shareCategories': d.shareCategories},
      d.settingsMeta,
      // Settings has no id and no record of its own in the document, so the
      // raw view is rebuilt from the flag plus its meta.
      raw: <String, dynamic>{
        'shareCategories': d.shareCategories,
        ...d.settingsMeta.toJson(),
      },
    );
    final aSettings = settingsRecord(a.taskMaster);
    final bSettings = settingsRecord(b.taskMaster);
    // Settings has no id of its own, so the conflict is filed under "settings".
    detector('settings')?.call(aSettings, bSettings, 'settings');
    final settingsWinner = _pick(aSettings, bSettings);

    final plans = _mergeLists<DailyPlan>(
      aLive: a.dailyPlan.plans,
      aDead: a.dailyPlan.deletedPlans,
      bLive: b.dailyPlan.plans,
      bDead: b.dailyPlan.deletedPlans,
      toJson: (p) => p.toJson(),
      fromJson: DailyPlan.fromJson,
      metaOf: (p) => p.meta,
      detector: detector('plan'),
    );
    final slots = _mergeLists<FreeTimeSlot>(
      aLive: a.dailyPlan.slots,
      aDead: a.dailyPlan.deletedSlots,
      bLive: b.dailyPlan.slots,
      bDead: b.dailyPlan.deletedSlots,
      toJson: (s) => s.toJson(),
      fromJson: FreeTimeSlot.fromJson,
      metaOf: (s) => s.meta,
      detector: detector('slot'),
    );
    final assignments = _mergeLists<SlotTaskAssignment>(
      aLive: a.dailyPlan.assignments,
      aDead: a.dailyPlan.deletedAssignments,
      bLive: b.dailyPlan.assignments,
      bDead: b.dailyPlan.deletedAssignments,
      toJson: (x) => x.toJson(),
      fromJson: SlotTaskAssignment.fromJson,
      metaOf: (x) => x.meta,
      detector: detector('assignment'),
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

    final conflictOutcome = _mergeConflicts(
      a: a.conflicts,
      b: b.conflicts,
      detected: detected,
      liveClocks: <String, Hlc>{
        for (final t in tasks.live) t.id: t.meta.clock,
        for (final c in mustDo.live) c.id: c.meta.clock,
        for (final c in wantToDo.live) c.id: c.meta.clock,
        for (final p in plans.live) p.id: p.meta.clock,
        for (final s in slots.live) s.id: s.meta.clock,
        for (final x in assignments.live) x.id: x.meta.clock,
        'settings': settingsWinner.meta.clock,
      },
      resolvedAt: at,
      resolvedBy: by,
    );

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
      conflicts: conflictOutcome.all,
    );
    return MergeResult(
      document: document,
      warnings: warnings,
      conflicts: conflictOutcome.added,
    );
  }

  /// `max(updatedAt, clock.physical)` in milliseconds — the same rule as
  /// `changedAt` in tools/hub/src/merge.ts.
  ///
  /// The wall clock alone is not enough: a device whose clock lags looks like
  /// it changed nothing, and a missed detection means the losing version
  /// really is gone. The HLC's physical part only moves forward within a
  /// device, so mixing it in biases towards over-detection — an extra row the
  /// user closes with 「現状のまま」, which is the cheap failure.
  static double _changedAt(Map<String, dynamic> raw) {
    final rawUpdated = raw['updatedAt'];
    final updated = rawUpdated is String
        ? DateTime.tryParse(rawUpdated)?.toUtc().millisecondsSinceEpoch
        : null;
    final rawClock = raw['clock'];
    final physical = rawClock is String ? Hlc.tryParse(rawClock)?.physical : null;
    final values = <int>[?updated, ?physical];
    // Neither a parsable time nor a parsable clock: it cannot be shown to be
    // old, so it counts as changed.
    if (values.isEmpty) return double.infinity;
    return values.reduce((x, y) => x > y ? x : y).toDouble();
  }

  static ConflictSide _side(_Record r, String which) {
    final raw = r.raw;
    final clock = raw['clock'];
    final clockText = clock is String ? clock : r.meta.clock.toString();
    final updatedAt = raw['updatedAt'];
    return ConflictSide(
      side: which,
      deviceId: Hlc.tryParse(clockText)?.deviceId ?? 'unknown',
      clock: clockText,
      updatedAt: updatedAt is String
          ? updatedAt
          : r.meta.updatedAt.toUtc().toIso8601String(),
      snapshot: raw,
    );
  }

  static ConflictRecord? _detect(
    _Record x,
    _Record y,
    String kind,
    String entityId,
    int agreed,
    String detectedAt,
    String detectedBy,
  ) {
    final hx = x.isDead ? '' : contentHash(x.json!);
    final hy = y.isDead ? '' : contentHash(y.json!);
    // A tombstone on one side and a live record on the other differ by
    // definition (the empty hash), which is exactly the conflict worth
    // surfacing.
    if (hx == hy && x.isDead == y.isDead) return null;
    // `>=`, not `>`: a change landing exactly on the agreement instant is
    // recorded rather than lost.
    if (!(_changedAt(x.raw) >= agreed && _changedAt(y.raw) >= agreed)) return null;
    final winnerIsX = identical(_pick(x, y), x);
    final winner = _side(winnerIsX ? x : y, winnerIsX ? 'hub' : 'device');
    final loser = _side(winnerIsX ? y : x, winnerIsX ? 'device' : 'hub');
    return ConflictRecord(
      id: conflictId(entityId, winner.clock, loser.clock),
      entityType: kind,
      entityId: entityId,
      detectedAt: detectedAt,
      detectedBy: detectedBy,
      winner: winner,
      loser: loser,
      // The record rides the winner's clock, so a later resolution — which
      // mints a bigger one — wins the next merge.
      meta: SyncMeta(
        clock: Hlc.tryParse(winner.clock) ?? Hlc.migrated,
        updatedAt: DateTime.tryParse(detectedAt)?.toUtc() ?? SyncMeta.epoch,
      ),
    );
  }

  /// Union by id (larger clock wins, so a later resolution does), then the
  /// newly detected records, then the stale ones close themselves.
  static _ConflictOutcome _mergeConflicts({
    required List<ConflictRecord> a,
    required List<ConflictRecord> b,
    required List<ConflictRecord> detected,
    required Map<String, Hlc> liveClocks,
    required String resolvedAt,
    required String resolvedBy,
  }) {
    final ia = <String, Map<String, dynamic>>{for (final c in a) c.id: c.toJson()};
    final ib = <String, Map<String, dynamic>>{for (final c in b) c.id: c.toJson()};
    final byId = <String, Map<String, dynamic>>{};
    for (final id in <String>{...ia.keys, ...ib.keys}) {
      final x = ia[id];
      final y = ib[id];
      byId[id] = x == null ? y! : (y == null ? x : _pickConflict(x, y));
    }
    // Re-detection is idempotent: an id already on file is left exactly as it
    // is, and is not reported as newly found either.
    final added = <ConflictRecord>[];
    for (final c in detected) {
      if (byId.containsKey(c.id)) continue;
      byId[c.id] = c.toJson();
      added.add(c);
    }
    // Stale conflicts close themselves: when the surviving entity's clock is
    // past both recorded versions, a later edit already overwrote them.
    for (final entry in byId.entries.toList()) {
      final record = entry.value;
      if (record['resolution'] != null || record['deletedAt'] is String) continue;
      final now = liveClocks[record['entityId']];
      final w = Hlc.tryParse((record['winner'] as Map)['clock'] as String?);
      final l = Hlc.tryParse((record['loser'] as Map)['clock'] as String?);
      if (now == null || w == null || l == null) continue;
      if (now.compareTo(w) > 0 && now.compareTo(l) > 0) {
        byId[entry.key] = <String, dynamic>{
          ...record,
          'resolution': 'superseded',
          'resolvedAt': resolvedAt,
          'resolvedBy': resolvedBy,
        };
      }
    }
    final ids = byId.keys.toList()..sort();
    return _ConflictOutcome(
      all: [for (final id in ids) ConflictRecord.fromJson(byId[id]!)],
      added: added,
    );
  }

  /// Rule 3 applied to two conflict records, on their raw JSON so the inputs to
  /// `contentHash` and the meta tie-break match `pick(x, y, 'conflict')` in
  /// tools/hub/src/merge.ts exactly.
  static Map<String, dynamic> _pickConflict(
    Map<String, dynamic> x,
    Map<String, dynamic> y,
  ) {
    SyncMeta metaOf(Map<String, dynamic> json) => SyncMeta.fromJson(
      json,
      // A tombstoned record is read with the tombstone key set, exactly as the
      // hub's `pick` does, so everything else lands in `extra` on both sides.
      knownKeys: json['deletedAt'] is String
          ? const <String>{'id'}
          : ConflictRecord.jsonKeys,
    );
    final mx = metaOf(x);
    final my = metaOf(y);
    final cmp = mx.clock.compareTo(my.clock);
    if (cmp > 0) return x;
    if (cmp < 0) return y;
    final hx = x['deletedAt'] is String ? '' : contentHash(x);
    final hy = y['deletedAt'] is String ? '' : contentHash(y);
    final byHash = hx.compareTo(hy);
    if (byHash != 0) return byHash > 0 ? x : y;
    return _metaKeyOf(mx).compareTo(_metaKeyOf(my)) <= 0 ? x : y;
  }

  static String _metaKeyOf(SyncMeta meta) {
    final json = meta.toJson();
    final keys = json.keys.toList()..sort();
    return jsonEncode(<String, dynamic>{for (final k in keys) k: json[k]});
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
    void Function(_Record x, _Record y, String id)? detector,
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
      // Only an id both sides hold can be in conflict; a one-sided id is new.
      if (x != null && y != null) detector?.call(x, y, id);
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

class _ConflictOutcome {
  const _ConflictOutcome({required this.all, required this.added});

  final List<ConflictRecord> all;
  final List<ConflictRecord> added;
}
