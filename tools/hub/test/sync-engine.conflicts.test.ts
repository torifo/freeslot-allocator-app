import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { HubConfig } from '../src/config.js';
import { HlcClock } from '../src/hlc.js';
import { conflictId, emptyDocument, type ConflictJson, type Entity, type SyncDocumentJson } from '../src/model.js';
import { FileStore } from '../src/store.js';
import {
  capConflicts,
  MAX_OPEN_CONFLICTS,
  MAX_RESOLVED_CONFLICTS,
  RESOLVED_CONFLICT_TTL_MS,
  SyncEngine,
} from '../src/sync-engine.js';

let dir: string; let engine: SyncEngine; let cfg: HubConfig; let store: FileStore;
const now = 1_800_000_000_000;
const iso = (ms: number) => new Date(ms).toISOString();
const AGREED = iso(now - 60_000);

const task = (id: string, title: string, clock: string, updatedMs = now): Entity => ({
  id, title, kind: 'must_do', priority: 3, createdAt: 'x', memo: '', categoryId: null,
  estimatedMinutes: 0, clock, updatedAt: iso(updatedMs), deletedAt: null, migrated: false,
});

const phoneDoc = (tasks: Entity[], extra: Partial<SyncDocumentJson> = {}): SyncDocumentJson => ({
  ...emptyDocument('android-1', new Date(now)),
  taskMaster: { ...emptyDocument('android-1').taskMaster, tasks },
  lastSyncAt: AGREED,
  ...extra,
});

/** A record shaped exactly like one `merge` produces, for the cap/TTL tests. */
const record = (id: string, over: Partial<ConflictJson> = {}): ConflictJson => ({
  id,
  entityType: 'task',
  entityId: `e-${id}`,
  detectedAt: iso(now - 1000),
  detectedBy: 'hub-0000',
  winner: { side: 'hub', deviceId: 'hub-0000', clock: '20-0-hub-0000', updatedAt: iso(now), snapshot: { id: `e-${id}` } },
  loser: { side: 'device', deviceId: 'android-1', clock: '15-0-android-1', updatedAt: iso(now), snapshot: { id: `e-${id}` } },
  resolution: null,
  resolvedAt: null,
  resolvedBy: null,
  clock: '20-0-hub-0000',
  updatedAt: iso(now - 1000),
  deletedAt: null,
  migrated: false,
  ...over,
});

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), 'hub-conflicts-'));
  cfg = await HubConfig.load(dir, () => now);
  store = new FileStore(dir, 'hub-0000');
  engine = new SyncEngine(store, cfg, new HlcClock('hub-0000', () => now), () => new Date(now));
  await cfg.redeemPairingCode((await cfg.issuePairingCode()).code, 'android-1', 'Pixel');
  await store.update((d) => {
    d.taskMaster.tasks.push(task('tsk-1', 'hub edit', '20-0-hub-0000'));
    return d;
  });
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

const clashing = () => phoneDoc([task('tsk-1', 'device edit', '15-0-android-1')]);

describe('SyncEngine conflicts', () => {
  it('reports the count in summary.conflicts and the records alongside the document', async () => {
    const result = await engine.sync('android-1', clashing());
    expect(result.summary.conflicts).toBe(1);
    expect(result.conflicts.map((c) => c.entityId)).toEqual(['tsk-1']);
    expect(result.document.conflicts).toHaveLength(1);
    // Conflicts are not warnings: `summary.warnings` must stay the warning count.
    expect(result.warnings.some((w) => w.includes('conflict'))).toBe(false);
    expect(result.summary.warnings).toBe(result.warnings.length);
  });

  it('passes the incoming lastSyncAt as lastAgreedAt and the hub id as detectedBy', async () => {
    const result = await engine.sync('android-1', clashing());
    const [conflict] = result.conflicts;
    expect(conflict.detectedBy).toBe('hub-0000');
    expect(conflict.detectedAt).toBe(iso(now));
    expect(conflict.id).toBe(conflictId('tsk-1', '20-0-hub-0000', '15-0-android-1'));
    expect(conflict.winner.side).toBe('hub');
  });

  it('detects nothing on the first sync (lastSyncAt null)', async () => {
    const result = await engine.sync('android-1', { ...clashing(), lastSyncAt: null });
    expect(result.summary.conflicts).toBe(0);
    expect(result.document.conflicts).toBeUndefined();
  });

  it('keeps conflicts as a union through take_phone', async () => {
    await store.update((d) => { d.conflicts = [record('cf-a'), record('cf-b')]; return d; });
    const result = await engine.sync('android-1', { ...clashing(), conflicts: [record('cf-c')] }, 'take_phone');
    expect(result.document.conflicts?.map((c) => c.id).sort()).toEqual(['cf-a', 'cf-b', 'cf-c']);
    // The replacement itself still happened.
    expect(result.document.taskMaster.tasks.map((t) => t.title)).toEqual(['device edit']);
  });

  it('take_hub keeps the hub conflicts and folds in what the phone sent', async () => {
    await store.update((d) => { d.conflicts = [record('cf-a')]; return d; });
    const result = await engine.sync('android-1', { ...clashing(), conflicts: [record('cf-c')] }, 'take_hub');
    expect(result.document.conflicts?.map((c) => c.id).sort()).toEqual(['cf-a', 'cf-c']);
    expect(result.document.taskMaster.tasks.map((t) => t.title)).toEqual(['hub edit']);
  });

  it('caps open conflicts at 1000, dropping the oldest and warning', async () => {
    const many = Array.from({ length: MAX_OPEN_CONFLICTS + 5 }, (_, i) =>
      record(`cf-${String(i).padStart(5, '0')}`, { detectedAt: iso(now - (MAX_OPEN_CONFLICTS + 5 - i) * 1000) }));
    await store.update((d) => { d.conflicts = many; return d; });
    const result = await engine.sync('android-1', phoneDoc([]));
    const open = result.document.conflicts!.filter((c) => c.resolution == null && c.deletedAt == null);
    expect(open).toHaveLength(MAX_OPEN_CONFLICTS);
    // The oldest five went, not the newest.
    expect(open.some((c) => c.id === 'cf-00000')).toBe(false);
    expect(result.warnings).toContain('conflict_overflow');
    expect(result.summary.warnings).toBe(result.warnings.length);
  });

  it('keeps only the 200 most recent resolved conflicts', async () => {
    const many = Array.from({ length: MAX_RESOLVED_CONFLICTS + 10 }, (_, i) =>
      record(`cf-r${String(i).padStart(5, '0')}`, {
        resolution: 'hub',
        resolvedAt: iso(now - (MAX_RESOLVED_CONFLICTS + 10 - i) * 1000),
      }));
    await store.update((d) => { d.conflicts = many; return d; });
    const result = await engine.sync('android-1', phoneDoc([]));
    expect(result.document.conflicts).toHaveLength(MAX_RESOLVED_CONFLICTS);
    expect(result.document.conflicts!.some((c) => c.id === 'cf-r00000')).toBe(false);
  });

  it('tombstones resolved conflicts older than 30 days and purges them on the existing cutoff', async () => {
    await store.update((d) => {
      d.conflicts = [record('cf-old', { resolution: 'hub', resolvedAt: iso(now - RESOLVED_CONFLICT_TTL_MS - 1000) })];
      return d;
    });
    const result = await engine.sync('android-1', phoneDoc([]));
    expect(result.document.conflicts![0].deletedAt).toBe(iso(now));
    // The purge cutoff is the earliest device lastSyncAt minus the skew, so a
    // tombstone written far in the past is what actually gets dropped.
    await store.update((d) => { d.conflicts![0].deletedAt = iso(now - 30 * 24 * 60 * 60 * 1000); return d; });
    const purged = await engine.purge();
    expect(purged.purged).toBeGreaterThan(0);
    expect((await store.read()).conflicts).toBeUndefined();
  });

  it('never loses an id: the merged document holds every id either side had', async () => {
    const result = await engine.sync('android-1', phoneDoc([task('tsk-2', 'phone only', '21-0-android-1')]));
    expect(result.document.taskMaster.tasks.map((t) => t.id).sort()).toEqual(['tsk-1', 'tsk-2']);
  });
});

describe('capConflicts', () => {
  it('leaves a small set alone and reports nothing dropped', () => {
    const out = capConflicts([record('cf-a')], iso(now));
    expect(out.dropped).toBe(0);
    expect(out.conflicts).toHaveLength(1);
  });

  it('is a pure function: the input array is untouched', () => {
    const input = [record('cf-a', { resolution: 'hub', resolvedAt: iso(now - RESOLVED_CONFLICT_TTL_MS - 1) })];
    const copy = JSON.parse(JSON.stringify(input));
    capConflicts(input, iso(now));
    expect(input).toEqual(copy);
  });

  it('leaves tombstoned records for purge rather than counting them against a cap', () => {
    const out = capConflicts([record('cf-a', { deletedAt: iso(now - 1) })], iso(now));
    expect(out.conflicts).toHaveLength(1);
    expect(out.dropped).toBe(0);
  });
});
