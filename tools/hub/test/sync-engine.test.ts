import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
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
    expect(result.summary).toEqual({ added: 1, updated: 0, deleted: 0, removed: 0, warnings: 0 });
    expect(result.document.lastSyncAt).toBe(new Date(now).toISOString());
    expect((await store.read()).lastSyncAt).toBe(new Date(now).toISOString());
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
    expect(r1.summary).toMatchObject({ added: 1, removed: 1, deleted: 0 });
    const r2 = await engine.sync('android-1', phoneDoc([]), 'take_hub');
    expect(r2.document.taskMaster.tasks.map((t) => t.id)).toEqual(['phone-only']);
    expect(r2.summary).toMatchObject({ added: 0, updated: 0, removed: 0, deleted: 0 });
  });

  it('rejects a document without taskMaster.settings with 400 and leaves the store untouched', async () => {
    await store.update((d) => { d.taskMaster.tasks.push(task('hub-task', '10-0-hub')); return d; });
    const before = await store.read();
    const incoming = phoneDoc([task('phone-task', '11-0-android-1')]);
    delete (incoming.taskMaster as unknown as Record<string, unknown>).settings;
    const err = await engine.sync('android-1', incoming, 'take_phone').catch((e) => e);
    expect(err).toBeInstanceOf(SyncRejected);
    expect(err.status).toBe(400);
    expect(err.code).toBe('invalid_document');
    expect(await store.read()).toEqual(before);
  });

  it('warns instead of silently skipping the purgedBefore guard when it is unparsable', async () => {
    await store.update((d) => { d.purgedBefore = 'not-a-timestamp'; return d; });
    const result = await engine.sync('android-1', phoneDoc([], { lastSyncAt: '2026-08-01T00:00:00.000Z' }));
    expect(result.warnings).toContain('purgedBefore unparsable, guard skipped');
    expect(result.summary.warnings).toBe(result.warnings.length);
  });

  it('lastSync returns a copy, so callers cannot mutate the tracked progress', async () => {
    await engine.sync('android-1', phoneDoc([]));
    const snapshot = engine.lastSync!;
    snapshot.stage = 'failed';
    expect(engine.lastSync?.stage).toBe('done');
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
    // The effective cutoff carries a 24h clock-skew margin (see PURGE_SKEW_MS).
    expect(doc.purgedBefore).toBe('2026-09-04T00:00:00.000Z');
    expect(result.purgedBefore).toBe('2026-09-04T00:00:00.000Z');
  });

  it('purges nothing when no device is known', async () => {
    await cfg.forgetDevice('android-1');
    expect((await engine.purge()).purged).toBe(0);
  });

  it('purges nothing while a known device has never synced', async () => {
    await store.update((d) => { d.taskMaster.tasks.push({ ...task('old', '1-0-hub', true), deletedAt: '2000-01-01T00:00:00.000Z' }); return d; });
    expect(await engine.purge()).toEqual({ purged: 0, purgedBefore: null });
    expect((await store.read()).taskMaster.tasks).toHaveLength(1);
  });

  it('keeps a tombstone deleted just before the cutoff and drops a clearly older one', async () => {
    now = Date.parse('2026-09-10T00:00:00.000Z');
    await cfg.recordSync('android-1', '2026-09-05T00:00:00.000Z');
    await store.update((d) => {
      d.taskMaster.tasks.push({ ...task('within-skew', '1-0-hub', true), deletedAt: '2026-09-04T23:00:00.000Z' });
      d.taskMaster.tasks.push({ ...task('beyond-skew', '2-0-hub', true), deletedAt: '2026-09-03T00:00:00.000Z' });
      return d;
    });
    expect((await engine.purge()).purged).toBe(1);
    expect((await store.read()).taskMaster.tasks.map((t) => t.id)).toEqual(['within-skew']);
  });

  it('never lowers purgedBefore', async () => {
    now = Date.parse('2026-09-10T00:00:00.000Z');
    await store.update((d) => { d.purgedBefore = '2026-09-20T00:00:00.000Z'; return d; });
    await cfg.recordSync('android-1', '2026-09-05T00:00:00.000Z');
    const result = await engine.purge();
    expect(result.purgedBefore).toBe('2026-09-20T00:00:00.000Z');
    expect((await store.read()).purgedBefore).toBe('2026-09-20T00:00:00.000Z');
  });

  it('takes the earliest lastSyncAt across devices regardless of string form', async () => {
    now = Date.parse('2026-09-10T00:00:00.000Z');
    await cfg.redeemPairingCode(await cfg.issuePairingCode(), 'android-2', 'Tab');
    await cfg.recordSync('android-1', '2026-09-08T00:00:00.000Z');
    await cfg.recordSync('android-2', '2026-09-06T09:00:00+09:00'); // 2026-09-06T00:00Z, the true minimum
    expect((await engine.purge()).purgedBefore).toBe('2026-09-05T00:00:00.000Z');
  });
});

describe('SyncEngine document validation', () => {
  it('rejects a structurally invalid document with 400 invalid_document', async () => {
    const err = await engine.sync('android-1', { version: 2 } as never).catch((e) => e);
    expect(err).toBeInstanceOf(SyncRejected);
    expect(err.status).toBe(400);
    expect(err.code).toBe('invalid_document');
  });

  it('accepts unknown extra fields so the schema can evolve', async () => {
    const doc = { ...phoneDoc([task('t1', '11-0-android-1')]), futureField: { anything: true } } as SyncDocumentJson;
    await expect(engine.sync('android-1', doc)).resolves.toBeTruthy();
  });

  it('rejects an unparsable lastSyncAt with 400 bad_timestamp', async () => {
    const err = await engine.sync('android-1', phoneDoc([], { lastSyncAt: 'yesterday' })).catch((e) => e);
    expect(err.status).toBe(400);
    expect(err.code).toBe('bad_timestamp');
  });
});

describe('SyncEngine timestamp handling', () => {
  // purgedBefore is 2026-09-01T00:00:00.000Z in every row.
  it.each([
    ['UTC Z, before', '2026-08-31T23:00:00.000Z', true],
    ['UTC Z, after', '2026-09-01T01:00:00.000Z', false],
    // No suffix is local time by definition, so these rows stay clear of any UTC offset.
    ['no suffix, before', '2026-08-30T12:00:00.000', true],
    ['no suffix, after', '2026-09-02T12:00:00.000', false],
    ['+09:00 offset, before', '2026-09-01T08:00:00+09:00', true],
    ['+09:00 offset, after', '2026-09-01T10:00:00+09:00', false],
    ['second precision, before', '2026-08-31T23:00:00Z', true],
    ['second precision, after', '2026-09-01T00:00:01Z', false],
  ])('compares %s as an instant', async (_label, lastSyncAt, rejected) => {
    await store.update((d) => { d.purgedBefore = '2026-09-01T00:00:00.000Z'; return d; });
    const outcome = await engine.sync('android-1', phoneDoc([], { lastSyncAt })).then(() => 'ok').catch((e) => e.code);
    expect(outcome).toBe(rejected ? 'purged_before' : 'ok');
  });
});

describe('SyncEngine concurrency', () => {
  it('does not lose an entity when two devices sync at once', async () => {
    await cfg.redeemPairingCode(await cfg.issuePairingCode(), 'android-2', 'Tab');
    const [a, b] = await Promise.all([
      engine.sync('android-1', phoneDoc([task('from-1', '11-0-android-1')])),
      engine.sync('android-2', { ...phoneDoc([task('from-2', '12-0-android-2')]), deviceId: 'android-2' }),
    ]);
    expect(a.document).toBeTruthy();
    expect(b.document).toBeTruthy();
    expect((await store.read()).taskMaster.tasks.map((t) => t.id).sort()).toEqual(['from-1', 'from-2']);
  });

  it('tracks progress per device and exposes the most recent as lastSync', async () => {
    await cfg.redeemPairingCode(await cfg.issuePairingCode(), 'android-2', 'Tab');
    await engine.sync('android-1', phoneDoc([]));
    await engine.sync('android-2', { ...phoneDoc([]), deviceId: 'android-2' });
    expect(engine.lastSync?.deviceId).toBe('android-2');
    expect(engine.progressFor('android-1')?.stage).toBe('done');
    expect(engine.progressFor('nobody')).toBeUndefined();
  });

  it('warns instead of failing when recording lastSyncAt fails', async () => {
    const boom = new Error('hub.json is read-only');
    const spy = vi.spyOn(cfg, 'recordSync').mockRejectedValueOnce(boom);
    const result = await engine.sync('android-1', phoneDoc([task('t1', '11-0-android-1')]));
    expect(result.warnings.some((w) => w.includes('hub.json is read-only'))).toBe(true);
    expect(result.summary.warnings).toBe(result.warnings.length);
    expect(engine.lastSync?.stage).toBe('done');
    spy.mockRestore();
  });
});
