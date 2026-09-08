import { contentHash } from './hash.js';
import { compareStrings, Hlc } from './hlc.js';
import {
  ENTITY_KEYS,
  isDeleted,
  metaKey,
  readMeta,
  SCHEMA_VERSION,
  toIsoUtc,
  type Entity,
  type EntityKind,
  type SyncDocumentJson,
  type SyncMetaJson,
} from './model.js';

export interface MergeResult {
  document: SyncDocumentJson;
  warnings: string[];
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
    isDeleted(e) && kind !== 'settings' ? ENTITY_KEYS.tombstone : ENTITY_KEYS[kind];
  const mx = readMeta(x, keysOf(x));
  const my = readMeta(y, keysOf(y));
  const cmp = Hlc.compare(mx.clock, my.clock);
  if (cmp > 0) return x;
  if (cmp < 0) return y;
  const hx = isDeleted(x) ? '' : contentHash(contentOf(x, kind));
  const hy = isDeleted(y) ? '' : contentHash(contentOf(y, kind));
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
  if (kind === 'settings') return { shareCategories: e.shareCategories };
  return e;
}

function mergeList(a: Entity[], b: Entity[], kind: EntityKind): Entity[] {
  const ia = new Map(a.map((e) => [e.id, e]));
  const ib = new Map(b.map((e) => [e.id, e]));
  const ids = [...new Set([...ia.keys(), ...ib.keys()])].sort(compareStrings);
  return ids.map((id) => {
    const x = ia.get(id);
    const y = ib.get(id);
    if (!x) return y!;
    if (!y) return x;
    return pick(x, y, kind) as Entity;
  });
}

export function merge(a: SyncDocumentJson, b: SyncDocumentJson): MergeResult {
  const tasks = mergeList(a.taskMaster.tasks, b.taskMaster.tasks, 'task');
  const mustDo = mergeList(a.taskMaster.mustDoCategories, b.taskMaster.mustDoCategories, 'category');
  const wantToDo = mergeList(
    a.taskMaster.wantToDoCategories,
    b.taskMaster.wantToDoCategories,
    'category',
  );
  const settings = pick(
    a.taskMaster.settings as unknown as Raw,
    b.taskMaster.settings as unknown as Raw,
    'settings',
  ) as unknown as Settings;
  const plans = mergeList(a.dailyPlan.plans, b.dailyPlan.plans, 'plan');
  const slots = mergeList(a.dailyPlan.slots, b.dailyPlan.slots, 'slot');
  const assignments = mergeList(a.dailyPlan.assignments, b.dailyPlan.assignments, 'assignment');

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
  const liveSlots = new Set(slots.filter((s) => !isDeleted(s)).map((s) => s.id));
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
  const laterInstant = <T extends string | null | undefined>(x: T, y: T): T | null => {
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

  return {
    document: {
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
    },
    warnings,
  };
}
