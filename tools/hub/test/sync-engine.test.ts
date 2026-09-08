import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { HubConfig } from '../src/config.js';
import { HlcClock } from '../src/hlc.js';
import { emptyDocument, type Entity, type SyncDocumentJson } from '../src/model.js';
import { FileStore } from '../src/store.js';
import { SyncEngine, SyncRejected } from '../src/sync-engine.js';

let dir: string; let engine: SyncEngine; let cfg: HubConfig; let store: FileStore; let now = 1_700_000_000_000;
const task = (id: string, clock: string, deleted = false): Entity => ({ id, title: id, kind: 'must_do', priority: 3, createdAt: 'x', memo: '', categoryId: null, estimatedMinutes: 0, clock, updatedAt: new Date(now).toISOString(), deletedAt: deleted ? new Date(now).toISOString() : null, migrated: false });
const phoneDoc = (tasks: Entity[], extra: Partial<SyncDocumentJson> = {}): SyncDocumentJson => ({ ...emptyDocument('android-1', new Date(now)), taskMaster: { ...emptyDocument('android-1').taskMaster, tasks }, ...extra });

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), 'hub-engine-'));
  cfg = await HubConfig.load(dir, () => now);
  store = new FileStore(dir, 'hub-0000');
  engine = new SyncEngine(store, cfg, new HlcClock('hub-0000', () => now), () => new Date(now));
  await cfg.redeemPairingCode(await cfg.issuePairingCode(), 'android-1', 'Pixel');
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

describe('SyncEngine.sync', () => {
  it('merges, saves, returns the merged document and records lastSyncAt', async () => {
    await store.update((d) => { d.taskMaster.tasks.push(task('hub-task', '10-0-hub')); return d; });
    const result = await engine.sync('android-1', phoneDoc([task('phone-task', '11-0-android-1')]));
    expect(result.document.taskMaster.tasks.map((t) => t.id).sort()).toEqual(['hub-task', 'phone-task']);
    expect(result.summary).toEqual({ added: 1, updated: 0, deleted: 0, warnings: 0 });
    expect(cfg.device('android-1')?.lastSyncAt).toBe(new Date(now).toISOString());
    expect((await store.read()).taskMaster.tasks).toHaveLength(2);
    expect(engine.lastSync?.stage).toBe('done');
  });

  it('rejects schema version < 2 with 426', async () => {
    await expect(engine.sync('android-1', { ...phoneDoc([]), version: 1 })).rejects.toMatchObject({ status: 426 });
  });

  it('rejects a client whose lastSyncAt is older than purgedBefore', async () => {
    await store.update((d) => { d.purgedBefore = '2026-09-01T00:00:00.000Z'; return d; });
    const err = await engine.sync('android-1', phoneDoc([], { lastSyncAt: '2026-08-01T00:00:00.000Z' })).catch((e) => e);
    expect(err).toBeInstanceOf(SyncRejected);
    expect(err.status).toBe(409);
    expect(err.code).toBe('purged_before');
  });

  it('exempts a device that never synced (first sync after pairing)', async () => {
    await store.update((d) => { d.purgedBefore = '2026-09-01T00:00:00.000Z'; return d; });
    await expect(engine.sync('android-1', phoneDoc([], { lastSyncAt: null }))).resolves.toBeTruthy();
  });

  it('replace mode overwrites the hub or the phone without merging', async () => {
    await store.update((d) => { d.taskMaster.tasks.push(task('hub-only', '10-0-hub')); return d; });
    const r1 = await engine.sync('android-1', phoneDoc([task('phone-only', '9-0-android-1')]), 'take_phone');
    expect(r1.document.taskMaster.tasks.map((t) => t.id)).toEqual(['phone-only']);
    const r2 = await engine.sync('android-1', phoneDoc([]), 'take_hub');
    expect(r2.document.taskMaster.tasks.map((t) => t.id)).toEqual(['phone-only']);
  });
});

describe('SyncEngine.purge', () => {
  it('purges tombstones older than the minimum lastSyncAt of known devices and sets purgedBefore', async () => {
    now = Date.parse('2026-09-10T00:00:00.000Z');
    await cfg.recordSync('android-1', '2026-09-05T00:00:00.000Z');
    await store.update((d) => {
      d.taskMaster.tasks.push({ ...task('old', '1-0-hub', true), deletedAt: '2026-09-01T00:00:00.000Z' });
      d.taskMaster.tasks.push({ ...task('new', '2-0-hub', true), deletedAt: '2026-09-08T00:00:00.000Z' });
      return d;
    });
    const result = await engine.purge();
    expect(result.purged).toBe(1);
    const doc = await store.read();
    expect(doc.taskMaster.tasks.map((t) => t.id)).toEqual(['new']);
    expect(doc.purgedBefore).toBe('2026-09-05T00:00:00.000Z');
  });

  it('purges nothing when no device is known', async () => {
    await cfg.forgetDevice('android-1');
    expect((await engine.purge()).purged).toBe(0);
  });
});
