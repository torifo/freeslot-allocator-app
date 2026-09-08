import type { HubConfig } from './config.js';
import { checkInvariants } from './invariants.js';
import { Hlc, HlcClock } from './hlc.js';
import { merge } from './merge.js';
import { isDeleted, SCHEMA_VERSION, type Entity, type SyncDocumentJson } from './model.js';
import type { FileStore } from './store.js';

export class SyncRejected extends Error {
  constructor(public readonly status: number, public readonly code: string, message: string) { super(message); }
}

export type SyncMode = 'merge' | 'take_hub' | 'take_phone';
export interface SyncSummary { added: number; updated: number; deleted: number; warnings: number; }
export interface SyncResult { document: SyncDocumentJson; summary: SyncSummary; warnings: string[]; }
export interface SyncProgress { deviceId: string; stage: 'received' | 'merging' | 'saving' | 'done' | 'failed'; startedAt: string; finishedAt?: string; summary?: SyncSummary; error?: string; }

const ENTITY_LISTS = (d: SyncDocumentJson): Entity[][] => [
  d.taskMaster.tasks, d.taskMaster.mustDoCategories, d.taskMaster.wantToDoCategories,
  d.dailyPlan.plans, d.dailyPlan.slots, d.dailyPlan.assignments,
];

/** Implements POST /sync and tombstone purge. Pure of HTTP concerns. */
export class SyncEngine {
  lastSync: SyncProgress | null = null;

  constructor(
    private readonly store: FileStore,
    private readonly config: HubConfig,
    private readonly clock: HlcClock,
    private readonly now: () => Date = () => new Date(),
  ) {}

  async sync(deviceId: string, incoming: SyncDocumentJson, mode: SyncMode = 'merge'): Promise<SyncResult> {
    const startedAt = this.now().toISOString();
    this.lastSync = { deviceId, stage: 'received', startedAt };
    try {
      if (typeof incoming.version !== 'number' || incoming.version < SCHEMA_VERSION) {
        throw new SyncRejected(426, 'upgrade_required', `client schema ${incoming.version} is older than ${SCHEMA_VERSION}; update the app`);
      }
      if (incoming.version > SCHEMA_VERSION) {
        throw new SyncRejected(400, 'unsupported_version', `client schema ${incoming.version} is newer than the hub`);
      }
      const current = await this.store.read();
      if (mode === 'merge' && current.purgedBefore && incoming.lastSyncAt && incoming.lastSyncAt < current.purgedBefore) {
        throw new SyncRejected(409, 'purged_before', `this device last synced at ${incoming.lastSyncAt}, before the hub purged tombstones at ${current.purgedBefore}; choose take_hub or take_phone`);
      }
      this.lastSync.stage = 'merging';
      for (const list of [...ENTITY_LISTS(current), ...ENTITY_LISTS(incoming)]) for (const e of list) { const h = Hlc.tryParse(e.clock); if (h) this.clock.observe(h); }

      let merged: SyncDocumentJson; let warnings: string[] = [];
      if (mode === 'take_phone') merged = { ...incoming, deviceId: current.deviceId, lastSyncAt: current.lastSyncAt ?? null, purgedBefore: current.purgedBefore ?? null };
      else if (mode === 'take_hub') merged = current;
      else { const r = merge(current, incoming); merged = r.document; warnings = r.warnings; }
      warnings = [...warnings, ...checkInvariants(merged).map((v) => `${v.code}: ${v.message}`)];

      const summary = summarize(current, merged, warnings.length);
      this.lastSync.stage = 'saving';
      const saved = await this.store.update(() => merged);
      const at = this.now().toISOString();
      await this.config.recordSync(deviceId, at);
      this.lastSync = { ...this.lastSync, stage: 'done', finishedAt: at, summary };
      return { document: { ...saved, lastSyncAt: at }, summary, warnings };
    } catch (error) {
      this.lastSync = { ...this.lastSync, stage: 'failed', finishedAt: this.now().toISOString(), error: String((error as Error).message ?? error) };
      throw error;
    }
  }

  /** Physically drops tombstones older than every known device's lastSyncAt. Nothing is purged while any device has never synced or no device is known. */
  async purge(): Promise<{ purged: number; purgedBefore: string | null }> {
    const devices = this.config.devices();
    if (devices.length === 0 || devices.some((d) => !d.lastSyncAt)) return { purged: 0, purgedBefore: null };
    const cutoff = devices.map((d) => d.lastSyncAt!).sort()[0];
    let purged = 0;
    await this.store.update((doc) => {
      const keep = (list: Entity[]) => list.filter((e) => { const drop = isDeleted(e) && String(e.deletedAt) < cutoff; if (drop) purged += 1; return !drop; });
      doc.taskMaster.tasks = keep(doc.taskMaster.tasks);
      doc.taskMaster.mustDoCategories = keep(doc.taskMaster.mustDoCategories);
      doc.taskMaster.wantToDoCategories = keep(doc.taskMaster.wantToDoCategories);
      doc.dailyPlan.plans = keep(doc.dailyPlan.plans);
      doc.dailyPlan.slots = keep(doc.dailyPlan.slots);
      doc.dailyPlan.assignments = keep(doc.dailyPlan.assignments);
      doc.purgedBefore = cutoff;
      return doc;
    });
    return { purged, purgedBefore: cutoff };
  }
}

function summarize(before: SyncDocumentJson, after: SyncDocumentJson, warnings: number): SyncSummary {
  const index = (d: SyncDocumentJson) => new Map(ENTITY_LISTS(d).flat().map((e) => [e.id, e]));
  const a = index(before); const b = index(after);
  let added = 0, updated = 0, deleted = 0;
  for (const [id, e] of b) {
    const prev = a.get(id);
    if (!prev) { if (!isDeleted(e)) added += 1; continue; }
    if (isDeleted(e) && !isDeleted(prev)) deleted += 1;
    else if (!isDeleted(e) && e.clock !== prev.clock) updated += 1;
  }
  return { added, updated, deleted, warnings };
}
