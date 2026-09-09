import { contentHash } from "./hash.js";
import { compareStrings, Hlc } from "./hlc.js";
import {
  conflictId,
  ENTITY_KEYS,
  isDeleted,
  metaKey,
  readMeta,
  SCHEMA_VERSION,
  toIsoUtc,
  type ConflictJson,
  type ConflictSideJson,
  type Entity,
  type EntityKind,
  type SyncDocumentJson,
  type SyncMetaJson,
} from "./model.js";

export interface MergeOptions {
  /**
   * The instant the two sides last agreed — the incoming document's
   * `lastSyncAt`. Null or absent (the default) disables detection entirely,
   * which is what the first sync and every pre-Plan-3b caller want.
   */
  lastAgreedAt?: string | null;
  detectedBy?: string;
  detectedAt?: string;
}

export interface MergeResult {
  document: SyncDocumentJson;
  warnings: string[];
  /** Only what this merge newly detected; `document.conflicts` also holds the older ones. */
  conflicts: ConflictJson[];
}

type Raw = Record<string, unknown>;
type Settings = { shareCategories: boolean } & SyncMetaJson;

/**
 * Rule 3 and its tie-breaks, mirroring `SyncMerger._pick` in Dart:
 * the larger clock wins; equal clocks fall back to the larger content hash
 * (a tombstone hashes to the empty string); identical content falls back to
 * the smaller canonical meta key, with ties going to `x`.
 */
function pick(x: Raw, y: Raw, kind: EntityKind): Raw {
  const keysOf = (e: Raw): readonly string[] =>
    isDeleted(e) && kind !== "settings"
      ? ENTITY_KEYS.tombstone
      : ENTITY_KEYS[kind];
  const mx = readMeta(x, keysOf(x));
  const my = readMeta(y, keysOf(y));
  const cmp = Hlc.compare(mx.clock, my.clock);
  if (cmp > 0) return x;
  if (cmp < 0) return y;
  const hx = isDeleted(x) ? "" : contentHash(contentOf(x, kind));
  const hy = isDeleted(y) ? "" : contentHash(contentOf(y, kind));
  const byHash = compareStrings(hx, hy);
  if (byHash !== 0) return byHash > 0 ? x : y;
  return compareStrings(metaKey(mx), metaKey(my)) <= 0 ? x : y;
}

/**
 * What Dart hashes: the model's `toJson()`. For entities that is the record
 * itself (contentHash drops the meta keys); for settings it is only the
 * `shareCategories` flag, because settings has no id in the Dart merger.
 */
function contentOf(e: Raw, kind: EntityKind): Raw {
  if (kind === "settings") return { shareCategories: e.shareCategories };
  return e;
}

function mergeList(
  a: Entity[],
  b: Entity[],
  kind: EntityKind,
  detector?: (x: Raw, y: Raw, id: string) => void,
): Entity[] {
  const ia = new Map(a.map((e) => [e.id, e]));
  const ib = new Map(b.map((e) => [e.id, e]));
  const ids = [...new Set([...ia.keys(), ...ib.keys()])].sort(compareStrings);
  return ids.map((id) => {
    const x = ia.get(id);
    const y = ib.get(id);
    if (!x) return y!;
    if (!y) return x;
    // Only an id both sides hold can be in conflict; a one-sided id is simply new.
    detector?.(x, y, id);
    return pick(x, y, kind) as Entity;
  });
}

/**
 * `max(updatedAt, clock.physical)` in milliseconds.
 *
 * The wall clock alone is not enough: a device whose clock lags looks like it
 * changed nothing, and a missed detection means the losing version really is
 * gone. The HLC's physical component is monotonic within a device, so mixing
 * it in biases towards over-detection — an extra row the user closes with
 * 「現状のまま」, which is the cheap failure.
 */
function changedAt(e: Raw): number {
  const updated =
    typeof e.updatedAt === "string" ? Date.parse(e.updatedAt) : Number.NaN;
  const clock = Hlc.tryParse(e.clock);
  const physical = clock ? clock.physical : Number.NaN;
  const values = [updated, physical].filter((v) => !Number.isNaN(v));
  // A record with neither a parsable time nor a parsable clock cannot be shown
  // to be old, so it counts as changed: over-detection is the safe side.
  return values.length === 0 ? Number.POSITIVE_INFINITY : Math.max(...values);
}

const sideOf = (raw: Raw, side: "hub" | "device"): ConflictSideJson => ({
  side,
  deviceId: Hlc.tryParse(raw.clock)?.deviceId ?? "unknown",
  clock: String(raw.clock),
  updatedAt: String(raw.updatedAt),
  snapshot: { ...raw } as ConflictSideJson["snapshot"],
});

function detect(
  x: Raw,
  y: Raw,
  kind: EntityKind,
  entityId: string,
  agreed: number,
  options: Required<Pick<MergeOptions, "detectedBy" | "detectedAt">>,
): ConflictJson | null {
  const hx = isDeleted(x) ? "" : contentHash(contentOf(x, kind));
  const hy = isDeleted(y) ? "" : contentHash(contentOf(y, kind));
  // A tombstone on one side and a live record on the other differ by definition
  // (the empty hash), which is exactly the conflict worth surfacing.
  if (hx === hy && isDeleted(x) === isDeleted(y)) return null;
  // `>=`, not `>`: a change landing exactly on the agreement instant is
  // recorded rather than lost (design C-1).
  if (!(changedAt(x) >= agreed && changedAt(y) >= agreed)) return null;
  const winnerIsX = pick(x, y, kind) === x;
  const [w, l] = winnerIsX ? [x, y] : [y, x];
  const winner = sideOf(w, winnerIsX ? "hub" : "device");
  const loser = sideOf(l, winnerIsX ? "device" : "hub");
  return {
    id: conflictId(entityId, winner.clock, loser.clock),
    entityType: kind,
    entityId,
    detectedAt: options.detectedAt,
    detectedBy: options.detectedBy,
    winner,
    loser,
    resolution: null,
    resolvedAt: null,
    resolvedBy: null,
    // The record rides the winner's clock, so a later resolution — which mints
    // a bigger one — wins the next merge.
    clock: winner.clock,
    updatedAt: options.detectedAt,
    deletedAt: null,
    migrated: false,
  };
}

export function merge(
  a: SyncDocumentJson,
  b: SyncDocumentJson,
  options: MergeOptions = {},
): MergeResult {
  const agreed =
    options.lastAgreedAt == null
      ? Number.NaN
      : Date.parse(options.lastAgreedAt);
  const detecting = !Number.isNaN(agreed);
  const detectOptions = {
    detectedBy: options.detectedBy ?? "unknown",
    detectedAt: options.detectedAt ?? new Date().toISOString(),
  };
  const detected: ConflictJson[] = [];
  const detector = (kind: EntityKind) =>
    detecting
      ? (x: Raw, y: Raw, id: string) => {
          const found = detect(x, y, kind, id, agreed, detectOptions);
          if (found) detected.push(found);
        }
      : undefined;

  const tasks = mergeList(
    a.taskMaster.tasks,
    b.taskMaster.tasks,
    "task",
    detector("task"),
  );
  const mustDo = mergeList(
    a.taskMaster.mustDoCategories,
    b.taskMaster.mustDoCategories,
    "category",
    detector("category"),
  );
  const wantToDo = mergeList(
    a.taskMaster.wantToDoCategories,
    b.taskMaster.wantToDoCategories,
    "category",
    detector("category"),
  );
  const aSettings = a.taskMaster.settings as unknown as Raw;
  const bSettings = b.taskMaster.settings as unknown as Raw;
  // Settings has no id of its own, so the conflict is filed under "settings".
  if (detecting) {
    const found = detect(
      aSettings,
      bSettings,
      "settings",
      "settings",
      agreed,
      detectOptions,
    );
    if (found) detected.push(found);
  }
  const settings = pick(
    aSettings,
    bSettings,
    "settings",
  ) as unknown as Settings;
  const plans = mergeList(
    a.dailyPlan.plans,
    b.dailyPlan.plans,
    "plan",
    detector("plan"),
  );
  const slots = mergeList(
    a.dailyPlan.slots,
    b.dailyPlan.slots,
    "slot",
    detector("slot"),
  );
  const assignments = mergeList(
    a.dailyPlan.assignments,
    b.dailyPlan.assignments,
    "assignment",
    detector("assignment"),
  );

  // Referential warnings (non-destructive: data is kept as-is).
  const warnings: string[] = [];
  const liveCats = new Set(
    [...mustDo, ...wantToDo].filter((c) => !isDeleted(c)).map((c) => c.id),
  );
  for (const t of tasks) {
    if (isDeleted(t)) continue;
    const categoryId = t.categoryId;
    if (categoryId != null && !liveCats.has(String(categoryId))) {
      warnings.push(`task ${t.id} references missing category ${categoryId}`);
    }
  }
  const liveSlots = new Set(
    slots.filter((s) => !isDeleted(s)).map((s) => s.id),
  );
  for (const x of assignments) {
    if (isDeleted(x)) continue;
    const slotId = x.slotId;
    if (slotId != null && !liveSlots.has(String(slotId))) {
      warnings.push(`assignment ${x.id} references missing slot ${slotId}`);
    }
  }
  warnings.sort(compareStrings);

  // Envelope timestamps are compared as instants, never lexicographically: a
  // phone sending `+09:00` would otherwise sort ahead of an earlier UTC value.
  // When one side is null or unparsable the other one is kept as-is.
  const laterInstant = <T extends string | null | undefined>(
    x: T,
    y: T,
  ): T | null => {
    const ix = x == null ? Number.NaN : Date.parse(x);
    const iy = y == null ? Number.NaN : Date.parse(y);
    if (Number.isNaN(ix)) return Number.isNaN(iy) ? (x ?? y ?? null) : y;
    if (Number.isNaN(iy)) return x;
    return ix >= iy ? x : y;
  };
  // purgedBefore is stored normalized so the next comparison — and any client
  // reading it back — sees a single canonical form. Taking the max is
  // deliberately monotonic; rejecting a hostile client's far-future value is
  // out of scope here.
  const purgedBefore = toIsoUtc(laterInstant(a.purgedBefore, b.purgedBefore));

  // Existing records union by id and follow the ordinary rules: both sides
  // holding one means the larger clock — the later resolution — wins.
  const byId = new Map(
    (
      mergeList(
        (a.conflicts ?? []) as unknown as Entity[],
        (b.conflicts ?? []) as unknown as Entity[],
        "conflict",
      ) as unknown as ConflictJson[]
    ).map((c) => [c.id, c]),
  );
  // Re-detection is idempotent: an id already on file is left exactly as it is,
  // and is not reported as newly found either — a sync that changed nothing
  // must not keep announcing the same conflict.
  const added: ConflictJson[] = [];
  for (const c of detected) {
    if (byId.has(c.id)) continue;
    byId.set(c.id, c);
    added.push(c);
  }

  // Stale conflicts close themselves: when the surviving entity's clock is past
  // both recorded versions, a later edit already overwrote them and there is
  // nothing left for the user to choose.
  const liveClock = new Map<string, string>([
    ...[
      ...tasks,
      ...mustDo,
      ...wantToDo,
      ...plans,
      ...slots,
      ...assignments,
    ].map((e) => [e.id, String(e.clock)] as const),
    ["settings", String((settings as unknown as Raw).clock)],
  ]);
  for (const [id, c] of byId) {
    if (c.resolution != null || isDeleted(c as unknown as Raw)) continue;
    const now = Hlc.tryParse(liveClock.get(c.entityId));
    const w = Hlc.tryParse(c.winner.clock);
    const l = Hlc.tryParse(c.loser.clock);
    if (now && w && l && Hlc.compare(now, w) > 0 && Hlc.compare(now, l) > 0) {
      byId.set(id, {
        ...c,
        resolution: "superseded",
        resolvedAt: detectOptions.detectedAt,
        resolvedBy: detectOptions.detectedBy,
      });
    }
  }
  const conflicts = [...byId.values()].sort((x, y) =>
    compareStrings(x.id, y.id),
  );

  const document: SyncDocumentJson = {
    version: SCHEMA_VERSION,
    exportedAt: laterInstant(a.exportedAt, b.exportedAt) ?? a.exportedAt,
    // The envelope identity stays with argument `a`; only the entity
    // payload is order independent (same rule as the Dart merger).
    deviceId: a.deviceId,
    lastSyncAt: a.lastSyncAt ?? null,
    purgedBefore,
    taskMaster: {
      tasks,
      mustDoCategories: mustDo,
      wantToDoCategories: wantToDo,
      settings,
    },
    dailyPlan: { plans, slots, assignments },
  };
  // Omitted when empty so a document with nothing recorded stays byte-identical
  // to what a pre-Plan-3b build would have written.
  if (conflicts.length > 0) document.conflicts = conflicts;

  return { document, warnings, conflicts: added };
}
