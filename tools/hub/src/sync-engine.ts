import { z } from 'zod';
import type { HubConfig } from './config.js';
import { checkInvariants } from './invariants.js';
import { Hlc, HlcClock } from './hlc.js';
import { merge } from './merge.js';
import { isDeleted, SCHEMA_VERSION, toIsoUtc, type Entity, type SyncDocumentJson } from './model.js';
import type { FileStore } from './store.js';

export class SyncRejected extends Error {
  constructor(public readonly status: number, public readonly code: string, message: string) { super(message); }
}

export type SyncMode = 'merge' | 'take_hub' | 'take_phone';
export interface SyncSummary { added: number; updated: number; deleted: number; removed: number; warnings: number; }
export interface SyncResult { document: SyncDocumentJson; summary: SyncSummary; warnings: string[]; }
export interface SyncProgress { deviceId: string; stage: 'received' | 'merging' | 'saving' | 'done' | 'failed'; startedAt: string; finishedAt?: string; summary?: SyncSummary; error?: string; }

/** Tombstones are kept this much longer than the cutoff demands, to absorb device clock skew. */
export const PURGE_SKEW_MS = 24 * 60 * 60 * 1000;

const ENTITY_LISTS = (d: SyncDocumentJson): Entity[][] => [
  d.taskMaster.tasks, d.taskMaster.mustDoCategories, d.taskMaster.wantToDoCategories,
  d.dailyPlan.plans, d.dailyPlan.slots, d.dailyPlan.assignments,
];

const entitySchema = z.object({ id: z.string() }).passthrough();
const entityList = z.array(entitySchema);
/** Permissive on unknown fields so a newer client's extra keys survive instead of breaking sync. */
const documentSchema = z.object({
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
      let summary: SyncSummary = { added: 0, updated: 0, deleted: 0, removed: 0, warnings: 0 };
      let warnings: string[] = [];
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
        if (mode === 'take_phone') merged = { ...incoming, deviceId: current.deviceId, purgedBefore: current.purgedBefore ?? null };
        else if (mode === 'take_hub') merged = current;
        else { const r = merge(current, incoming); merged = r.document; mergeWarnings = r.warnings; }
        merged.lastSyncAt = at;
        warnings = [...mergeWarnings, ...checkInvariants(merged).map((v) => `${v.code}: ${v.message}`)];
        if (guardSkipped) warnings.push('purgedBefore unparsable, guard skipped');
        summary = summarize(current, merged, warnings.length);
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
      return { document: saved, summary, warnings };
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
  return { added, updated, deleted, removed, warnings };
}
