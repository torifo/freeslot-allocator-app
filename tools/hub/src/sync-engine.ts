import { z } from 'zod';
import type { HubConfig } from './config.js';
import { checkInvariants } from './invariants.js';
import { Hlc, HlcClock } from './hlc.js';
import { merge } from './merge.js';
import { conflictSchema, isDeleted, SCHEMA_VERSION, toIsoUtc, type ConflictJson, type Entity, type SyncDocumentJson } from './model.js';
import type { FileStore } from './store.js';

export class SyncRejected extends Error {
  constructor(public readonly status: number, public readonly code: string, message: string) { super(message); }
}

export type SyncMode = 'merge' | 'take_hub' | 'take_phone';
export interface SyncSummary { added: number; updated: number; deleted: number; removed: number; warnings: number; conflicts: number; }
export interface SyncResult { document: SyncDocumentJson; summary: SyncSummary; warnings: string[]; conflicts: ConflictJson[]; }
export interface SyncProgress { deviceId: string; stage: 'received' | 'merging' | 'saving' | 'done' | 'failed'; startedAt: string; finishedAt?: string; summary?: SyncSummary; error?: string; }

/** Tombstones are kept this much longer than the cutoff demands, to absorb device clock skew. */
export const PURGE_SKEW_MS = 24 * 60 * 60 * 1000;

/** Ceilings from the design (C-2). Open conflicts are the ones the user still has to answer. */
export const MAX_OPEN_CONFLICTS = 1000;
export const MAX_RESOLVED_CONFLICTS = 200;
export const RESOLVED_CONFLICT_TTL_MS = 30 * 24 * 60 * 60 * 1000;

/**
 * Applies the conflict ceilings and the resolved-record TTL in one place.
 *
 * Pure, and exported so the rules can be tested without a store: tombstoned
 * records pass through untouched (they belong to `purge`), open records are
 * trimmed oldest-first, resolved ones are kept newest-first, and a resolution
 * older than the TTL is tombstoned with its clock left alone — this is
 * housekeeping, not an edit, and bumping the clock would let it beat a real
 * resolution on another device.
 */
export function capConflicts(conflicts: ConflictJson[], at: string): { conflicts: ConflictJson[]; dropped: number } {
  const cutoff = Date.parse(at) - RESOLVED_CONFLICT_TTL_MS;
  const tombstoned: ConflictJson[] = [];
  const open: ConflictJson[] = [];
  const resolved: ConflictJson[] = [];
  for (const c of conflicts) {
    if (isDeleted(c as unknown as Record<string, unknown>)) { tombstoned.push(c); continue; }
    if (c.resolution == null) { open.push(c); continue; }
    const resolvedAt = instant(c.resolvedAt);
    if (!Number.isNaN(resolvedAt) && resolvedAt < cutoff) tombstoned.push({ ...c, deletedAt: at });
    else resolved.push(c);
  }
  // Oldest first, so slicing from the front drops the oldest. An unparsable
  // detectedAt sorts oldest: a record we cannot date is the safest to shed.
  open.sort((x, y) => (instant(x.detectedAt) || 0) - (instant(y.detectedAt) || 0));
  const dropped = Math.max(0, open.length - MAX_OPEN_CONFLICTS);
  const keptOpen = dropped > 0 ? open.slice(dropped) : open;
  resolved.sort((x, y) => (instant(y.resolvedAt) || 0) - (instant(x.resolvedAt) || 0));
  const keptResolved = resolved.slice(0, MAX_RESOLVED_CONFLICTS);
  const out = [...tombstoned, ...keptOpen, ...keptResolved].sort((x, y) => (x.id < y.id ? -1 : x.id > y.id ? 1 : 0));
  return { conflicts: out, dropped };
}

/** Union of two conflict lists by id; the larger clock — the later resolution — wins. */
function unionConflicts(a: ConflictJson[], b: ConflictJson[]): ConflictJson[] {
  const byId = new Map(a.map((c) => [c.id, c]));
  for (const c of b) {
    const existing = byId.get(c.id);
    if (!existing) { byId.set(c.id, c); continue; }
    const x = Hlc.tryParse(existing.clock);
    const y = Hlc.tryParse(c.clock);
    if (x && y && Hlc.compare(y, x) > 0) byId.set(c.id, c);
  }
  return [...byId.values()];
}

const ENTITY_LISTS = (d: SyncDocumentJson): Entity[][] => [
  d.taskMaster.tasks, d.taskMaster.mustDoCategories, d.taskMaster.wantToDoCategories,
  d.dailyPlan.plans, d.dailyPlan.slots, d.dailyPlan.assignments,
];

const entitySchema = z.object({ id: z.string() }).passthrough();
const entityList = z.array(entitySchema);
/** Permissive on unknown fields so a newer client's extra keys survive instead of breaking sync. */
export const documentSchema = z.object({
  version: z.number(),
  exportedAt: z.string().optional(),
  deviceId: z.string().optional(),
  lastSyncAt: z.string().nullish(),
  purgedBefore: z.string().nullish(),
  taskMaster: z.object({
    tasks: entityList,
    mustDoCategories: entityList,
    wantToDoCategories: entityList,
    // Required: `take_phone` persists the incoming document verbatim, so a
    // settings-less payload would be stored and crash every later merge.
    settings: z.object({ shareCategories: z.boolean() }).passthrough(),
  }).passthrough(),
  dailyPlan: z.object({ plans: entityList, slots: entityList, assignments: entityList }).passthrough(),
  // Optional: a Plan 2b client sends no `conflicts` at all, and a hub with
  // nothing recorded omits the key rather than sending an empty array.
  conflicts: z.array(conflictSchema).optional(),
}).passthrough();

/** Instant of an ISO string, whatever its offset or precision; NaN when unparsable. */
const instant = (value: unknown): number => (typeof value === 'string' ? Date.parse(value) : Number.NaN);

/** Implements POST /sync and tombstone purge. Pure of HTTP concerns. */
export class SyncEngine {
  private readonly progress = new Map<string, SyncProgress>();

  constructor(
    readonly store: FileStore,
    private readonly config: HubConfig,
    private readonly clock: HlcClock,
    private readonly now: () => Date = () => new Date(),
  ) {}

  /** The most recently updated device's progress. */
  get lastSync(): SyncProgress | null {
    let last: SyncProgress | null = null;
    for (const p of this.progress.values()) last = p;
    return last ? { ...last } : null;
  }

  progressFor(deviceId: string): SyncProgress | undefined {
    const p = this.progress.get(deviceId);
    return p ? { ...p } : undefined;
  }

  private setProgress(deviceId: string, patch: Partial<SyncProgress> & Pick<SyncProgress, 'stage'>): void {
    const previous = this.progress.get(deviceId);
    const next: SyncProgress = { deviceId, startedAt: previous?.startedAt ?? this.now().toISOString(), ...previous, ...patch };
    // Re-insert so Map iteration order tracks recency.
    this.progress.delete(deviceId);
    this.progress.set(deviceId, next);
  }

  /**
   * `bookkeep: false` skips the `lastSyncAt` write on the device record. The web
   * pseudo-device (`web-…`) has no record on purpose — a browser holds no local
   * store, so it must never hold back tombstone purge — and recording it would
   * otherwise throw and turn every clean browser sync into a
   * `record_sync_failed` warning.
   */
  async sync(
    deviceId: string,
    incoming: SyncDocumentJson,
    mode: SyncMode = 'merge',
    options: { bookkeep?: boolean } = {},
  ): Promise<SyncResult> {
    const startedAt = this.now().toISOString();
    this.progress.delete(deviceId);
    this.setProgress(deviceId, { stage: 'received', startedAt, finishedAt: undefined, summary: undefined, error: undefined });
    try {
      const parsed = documentSchema.safeParse(incoming);
      if (!parsed.success) {
        throw new SyncRejected(400, 'invalid_document', `document does not match the sync schema: ${parsed.error.issues.map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`).join('; ')}`);
      }
      if (typeof incoming.version !== 'number' || incoming.version < SCHEMA_VERSION) {
        throw new SyncRejected(426, 'upgrade_required', `client schema ${incoming.version} is older than ${SCHEMA_VERSION}; update the app`);
      }
      if (incoming.version > SCHEMA_VERSION) {
        throw new SyncRejected(400, 'unsupported_version', `client schema ${incoming.version} is newer than the hub`);
      }
      const incomingLastSync = incoming.lastSyncAt ?? null;
      if (incomingLastSync !== null && Number.isNaN(instant(incomingLastSync))) {
        throw new SyncRejected(400, 'bad_timestamp', `lastSyncAt ${JSON.stringify(incomingLastSync)} is not a parsable timestamp; send UTC ISO-8601`);
      }

      const at = this.now().toISOString();
      let summary: SyncSummary = { added: 0, updated: 0, deleted: 0, removed: 0, warnings: 0, conflicts: 0 };
      let warnings: string[] = [];
      let detected: ConflictJson[] = [];
      this.setProgress(deviceId, { stage: 'merging' });
      // Guard, merge, check and summarize all run inside the one locked read-modify-write,
      // so a concurrent sync cannot merge against a document that is already stale.
      // The closure counters below (`summary`, `warnings`) assume `FileStore.update`
      // invokes this mutator exactly once — it takes the lock first and does not retry.
      const saved = await this.store.update((current) => {
        const purgedBefore = instant(current.purgedBefore);
        // A stored purgedBefore we cannot parse fails open: rejecting every sync
        // would strand all devices behind a value only the hub can repair, so we
        // let the sync through and surface the skipped guard as a warning instead.
        const guardSkipped = current.purgedBefore != null && Number.isNaN(purgedBefore);
        if (mode === 'merge' && incomingLastSync !== null && !Number.isNaN(purgedBefore) && instant(incomingLastSync) < purgedBefore) {
          throw new SyncRejected(409, 'purged_before', `this device last synced at ${incomingLastSync}, before the hub purged tombstones at ${current.purgedBefore}; choose take_hub or take_phone`);
        }
        for (const list of [...ENTITY_LISTS(current), ...ENTITY_LISTS(incoming)]) for (const e of list) { const h = Hlc.tryParse(e.clock); if (h) this.clock.observe(h); }

        let merged: SyncDocumentJson;
        let mergeWarnings: string[] = [];
        if (mode === 'take_phone') {
          merged = { ...incoming, deviceId: current.deviceId, purgedBefore: current.purgedBefore ?? null };
          // Replacing the data must not replace the record of what was in conflict.
          merged.conflicts = unionConflicts(current.conflicts ?? [], incoming.conflicts ?? []);
        } else if (mode === 'take_hub') {
          merged = { ...current, conflicts: unionConflicts(current.conflicts ?? [], incoming.conflicts ?? []) };
        } else {
          const r = merge(current, incoming, {
            // The agreement point is what the phone says it last received.
            lastAgreedAt: incomingLastSync,
            detectedBy: this.store.deviceId,
            detectedAt: at,
          });
          merged = r.document;
          mergeWarnings = r.warnings;
          detected = r.conflicts;
        }
        const capped = capConflicts(merged.conflicts ?? [], at);
        if (capped.dropped > 0) mergeWarnings = [...mergeWarnings, 'conflict_overflow'];
        if (capped.conflicts.length > 0) merged.conflicts = capped.conflicts;
        else delete merged.conflicts;
        merged.lastSyncAt = at;
        warnings = [...mergeWarnings, ...checkInvariants(merged).map((v) => `${v.code}: ${v.message}`)];
        if (guardSkipped) warnings.push('purgedBefore unparsable, guard skipped');
        summary = { ...summarize(current, merged, warnings.length), conflicts: detected.length };
        return merged;
      });
      this.setProgress(deviceId, { stage: 'saving' });

      try {
        if (options.bookkeep !== false) await this.config.recordSync(deviceId, at);
      } catch (error) {
        // The document is already durable; a failed bookkeeping write must not undo it.
        warnings = [...warnings, `record_sync_failed: ${String((error as Error).message ?? error)}`];
        summary = { ...summary, warnings: warnings.length };
      }
      this.setProgress(deviceId, { stage: 'done', finishedAt: at, summary });
      return { document: saved, summary, warnings, conflicts: detected };
    } catch (error) {
      this.setProgress(deviceId, { stage: 'failed', finishedAt: this.now().toISOString(), error: String((error as Error).message ?? error) });
      throw error;
    }
  }

  /** Drops tombstones whose device-authored `deletedAt` is PURGE_SKEW_MS before the earliest device lastSyncAt; a clock slower than that margin can still lose a tombstone early. Nothing is purged while a device has never synced or none is known. */
  async purge(): Promise<{ purged: number; purgedBefore: string | null }> {
    const devices = this.config.devices();
    if (devices.length === 0 || devices.some((d) => !d.lastSyncAt)) return { purged: 0, purgedBefore: null };
    const earliest = Math.min(...devices.map((d) => instant(d.lastSyncAt)));
    if (Number.isNaN(earliest)) return { purged: 0, purgedBefore: null };
    const cutoffMs = earliest - PURGE_SKEW_MS;
    const cutoff = new Date(cutoffMs).toISOString();
    // `purged` and `effective` are closure counters: they assume `FileStore.update`
    // invokes the mutator exactly once (it locks first and does not retry).
    let purged = 0;
    let effective = cutoff;
    await this.store.update((doc) => {
      const keep = (list: Entity[]) => list.filter((e) => { const drop = isDeleted(e) && instant(e.deletedAt) < cutoffMs; if (drop) purged += 1; return !drop; });
      doc.taskMaster.tasks = keep(doc.taskMaster.tasks);
      doc.taskMaster.mustDoCategories = keep(doc.taskMaster.mustDoCategories);
      doc.taskMaster.wantToDoCategories = keep(doc.taskMaster.wantToDoCategories);
      doc.dailyPlan.plans = keep(doc.dailyPlan.plans);
      doc.dailyPlan.slots = keep(doc.dailyPlan.slots);
      doc.dailyPlan.assignments = keep(doc.dailyPlan.assignments);
      // Resolved conflicts tombstoned by `capConflicts` ride the very same cutoff.
      const conflicts = keep((doc.conflicts ?? []) as unknown as Entity[]) as unknown as ConflictJson[];
      if (conflicts.length > 0) doc.conflicts = conflicts; else delete doc.conflicts;
      // Monotonic: purgedBefore only ever moves forward.
      const previous = instant(doc.purgedBefore);
      effective = !Number.isNaN(previous) && previous > cutoffMs ? toIsoUtc(doc.purgedBefore) ?? cutoff : cutoff;
      doc.purgedBefore = effective;
      return doc;
    });
    return { purged, purgedBefore: effective };
  }
}

function summarize(before: SyncDocumentJson, after: SyncDocumentJson, warnings: number): SyncSummary {
  const index = (d: SyncDocumentJson) => new Map(ENTITY_LISTS(d).flat().map((e) => [e.id, e]));
  const a = index(before); const b = index(after);
  let added = 0, updated = 0, deleted = 0, removed = 0;
  for (const [id, e] of b) {
    const prev = a.get(id);
    if (!prev) { if (!isDeleted(e)) added += 1; continue; }
    if (isDeleted(e) && !isDeleted(prev)) deleted += 1;
    else if (!isDeleted(e) && e.clock !== prev.clock) updated += 1;
  }
  for (const id of a.keys()) if (!b.has(id)) removed += 1;
  // `conflicts` is filled in by the caller, which is the only place that knows
  // what this particular merge detected.
  return { added, updated, deleted, removed, warnings, conflicts: 0 };
}
