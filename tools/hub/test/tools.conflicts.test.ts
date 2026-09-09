import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { HubConfig } from '../src/config.js';
import { Hlc, HlcClock } from '../src/hlc.js';
import { conflictId, type ConflictJson, type Entity } from '../src/model.js';
import { FileStore } from '../src/store.js';
import { SyncEngine } from '../src/sync-engine.js';
import { HubTools } from '../src/tools.js';

let dir: string;
let store: FileStore;
let tools: HubTools;
let cfg: HubConfig;

const now = 1_800_000_000_000;
const iso = (ms: number) => new Date(ms).toISOString();

const HUB_CLOCK = '20-0-hub-0000';
const DEVICE_CLOCK = '15-0-android-1';
const HUB_TITLE = '確定申告の書類を集める';
const DEVICE_TITLE = '確定申告（領収書だけ先に）';

const task = (id: string, title: string, clock: string): Entity => ({
  id,
  title,
  kind: 'must_do',
  priority: 3,
  createdAt: '2026-09-01T00:00:00.000Z',
  memo: '',
  categoryId: null,
  estimatedMinutes: 0,
  clock,
  updatedAt: iso(now - 10_000),
  deletedAt: null,
  migrated: false,
});

const tombstone = (id: string, clock: string): Entity => ({
  id,
  clock,
  updatedAt: iso(now - 10_000),
  deletedAt: iso(now - 10_000),
  migrated: false,
});

/** A record shaped exactly like the merger produces one. */
const record = (
  entityId: string,
  winnerSnapshot: Entity,
  loserSnapshot: Entity,
  over: Partial<ConflictJson> = {},
): ConflictJson => ({
  id: conflictId(entityId, String(winnerSnapshot.clock), String(loserSnapshot.clock)),
  entityType: 'task',
  entityId,
  detectedAt: iso(now - 5_000),
  detectedBy: 'hub-0000',
  winner: {
    side: 'hub',
    deviceId: 'hub-0000',
    clock: String(winnerSnapshot.clock),
    updatedAt: String(winnerSnapshot.updatedAt),
    snapshot: winnerSnapshot as ConflictJson['winner']['snapshot'],
  },
  loser: {
    side: 'device',
    deviceId: 'android-1',
    clock: String(loserSnapshot.clock),
    updatedAt: String(loserSnapshot.updatedAt),
    snapshot: loserSnapshot as ConflictJson['loser']['snapshot'],
  },
  resolution: null,
  resolvedAt: null,
  resolvedBy: null,
  clock: String(winnerSnapshot.clock),
  updatedAt: iso(now - 5_000),
  deletedAt: null,
  migrated: false,
  ...over,
});

const id = conflictId('tsk-1', HUB_CLOCK, DEVICE_CLOCK);
const secondId = conflictId('tsk-2', HUB_CLOCK, DEVICE_CLOCK);
const resolvedId = conflictId('tsk-3', HUB_CLOCK, DEVICE_CLOCK);

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), 'hub-tools-conflicts-'));
  cfg = await HubConfig.load(dir, () => now);
  store = new FileStore(dir, 'hub-0000');
  const clock = new HlcClock('hub-0000', () => now);
  const engine = new SyncEngine(store, cfg, clock, () => new Date(now));
  tools = new HubTools(store, clock, () => new Date(now), {
    config: cfg,
    engine,
    lan: () => ({
      listening: false, disabled: true, url: null, addresses: [], port: null,
      pairingPage: null, qrPage: null,
      webApp: { url: null, built: false, gitRev: null, builtAt: null, stale: false },
    }),
    importDirs: [dir],
  });
  await store.update((doc) => {
    doc.taskMaster.tasks.push(
      task('tsk-1', HUB_TITLE, HUB_CLOCK),
      task('tsk-2', 'hub の版', HUB_CLOCK),
      task('tsk-3', 'すでに決めた版', HUB_CLOCK),
    );
    doc.conflicts = [
      record('tsk-1', task('tsk-1', HUB_TITLE, HUB_CLOCK), task('tsk-1', DEVICE_TITLE, DEVICE_CLOCK)),
      record('tsk-2', task('tsk-2', 'hub の版', HUB_CLOCK), task('tsk-2', '端末の版', DEVICE_CLOCK)),
      record('tsk-3', task('tsk-3', 'すでに決めた版', HUB_CLOCK), task('tsk-3', '捨てた版', DEVICE_CLOCK), {
        resolution: 'hub',
        resolvedAt: iso(now - 1_000),
        resolvedBy: 'hub-0000',
      }),
    ];
    return doc;
  });
});

afterEach(() => rmSync(dir, { recursive: true, force: true }));

describe('settings conflicts', () => {
  /** The settings entity is one flag; a record on it carries just that. */
  const settingsSide = (shareCategories: boolean, clock: string): Entity => ({
    id: 'settings', shareCategories, clock,
    updatedAt: iso(now - 10_000), deletedAt: null, migrated: false,
  });

  const settingsRecord = record(
    'settings',
    settingsSide(false, HUB_CLOCK),
    settingsSide(true, DEVICE_CLOCK),
    { entityType: 'settings', entityId: 'settings' },
  );

  beforeEach(async () => {
    await store.update((doc) => {
      doc.conflicts = [settingsRecord];
      return doc;
    });
  });

  it('adopting the side already stored marks the record and writes nothing', async () => {
    const r = await tools.resolveConflict({ id: settingsRecord.id, adopt: 'hub' });
    expect(r.wrote).toBe(false);
    expect((await store.read()).taskMaster.settings!.shareCategories).toBe(false);
    expect((await store.read()).conflicts![0].resolution).toBe('hub');
  });

  it('adopting the other side writes the flag with a clock that beats both versions', async () => {
    const r = await tools.resolveConflict({ id: settingsRecord.id, adopt: 'device' });
    expect(r).toMatchObject({ wrote: true, summary: { updated: 1 } });
    const settings = (await store.read()).taskMaster.settings!;
    expect(settings.shareCategories).toBe(true);
    expect(Hlc.compare(Hlc.parse(String(settings.clock)), Hlc.parse(HUB_CLOCK))).toBeGreaterThan(0);
    expect(Hlc.compare(Hlc.parse(String(settings.clock)), Hlc.parse(DEVICE_CLOCK))).toBeGreaterThan(0);
    // The settings entity is never a list member, so it can never be "no longer
    // in the document": the record stays resolvable whatever a purge did.
    expect(settings.deletedAt).toBeNull();
  });

  it('list_conflicts and get_conflict read a settings record as 設定', async () => {
    const listed = await tools.listConflicts({ entityType: 'settings' });
    expect(listed.conflicts).toHaveLength(1);
    expect(listed.conflicts[0].label).toBe('設定');
    const got = await tools.getConflict({ id: settingsRecord.id });
    expect(got.differences).toEqual([{ field: 'shareCategories', hub: false, device: true }]);
    expect(got.sideLabels).toEqual({ hub: 'PC 版', device: 'スマホ版' });
  });
});

describe('conflict side labels and blame', () => {
  it('get_conflict names the two sides 「PC 版」/「スマホ版」', async () => {
    expect((await tools.getConflict({ id })).sideLabels).toEqual({
      hub: 'PC 版',
      device: 'スマホ版',
    });
  });

  it('get_conflict falls back to device ids when both sides read the same', async () => {
    // Two phones: `hub`/`device` still name the two halves the adopt values
    // write, but 「PC 版」 would be a lie about both of them.
    const phones = record(
      'tsk-1',
      task('tsk-1', HUB_TITLE, '25-0-android-2'),
      task('tsk-1', DEVICE_TITLE, DEVICE_CLOCK),
    );
    phones.winner.side = 'device';
    phones.winner.deviceId = 'android-2';
    await store.update((doc) => {
      doc.conflicts = [phones];
      return doc;
    });
    expect((await tools.getConflict({ id: phones.id })).sideLabels).toEqual({
      // `hub` is whichever side `adopt: "hub"` writes — with no PC side on
      // either half that is the loser, and the ids are what name them.
      hub: '端末 A（android-1）',
      device: '端末 B（android-2）',
    });
  });

  it('a resolve refused by the invariants says which record asked for it', async () => {
    const mine = await tools.addCategory({ kind: 'must_do', name: 'カテゴリ甲' });
    const other = await tools.addCategory({ kind: 'must_do', name: 'カテゴリ乙' });
    // Adopting the device version would rename 乙 to 甲, which the document does
    // not allow — and the raw violation names neither the record nor the
    // decision that asked for it.
    const clash = record(
      other.id,
      { ...other, name: 'カテゴリ乙', clock: HUB_CLOCK } as Entity,
      { ...other, name: 'カテゴリ甲', clock: DEVICE_CLOCK } as Entity,
      { entityType: 'category' },
    );
    await store.update((doc) => {
      doc.conflicts = [clash];
      return doc;
    });
    await expect(tools.resolveConflict({ id: clash.id, adopt: 'device' })).rejects.toThrow(
      new RegExp(`resolving conflict ${clash.id} would leave the document invalid`),
    );
    await expect(tools.resolveAllConflicts({ adopt: 'device' })).rejects.toThrow(
      new RegExp(`resolving conflict ${clash.id} would leave the document invalid`),
    );
    // All or nothing: the refused write left both categories as they were.
    const after = await store.read();
    const named = (id: string) => after.taskMaster.mustDoCategories.find((c) => c.id === id)?.name;
    expect(named(mine.id)).toBe('カテゴリ甲');
    expect(named(other.id)).toBe('カテゴリ乙');
    expect(after.conflicts!.every((c) => c.resolution == null)).toBe(true);
  });
});

describe('conflict tools', () => {
  it('list_conflicts counts open and resolved and returns a human label', async () => {
    const r = await tools.listConflicts({});
    expect(r.open).toBe(2);
    expect(r.resolved).toBe(1);
    expect(r.conflicts).toHaveLength(2);
    expect(r.conflicts[0]).toMatchObject({
      id: expect.stringMatching(/^cf-/),
      entityType: 'task',
      entityId: 'tsk-1',
      resolution: null,
    });
    expect(r.conflicts[0].label).toBe(`タスク「${HUB_TITLE}」`);
    expect((await tools.listConflicts({ status: 'resolved' })).conflicts).toHaveLength(1);
    expect((await tools.listConflicts({ status: 'all' })).conflicts).toHaveLength(3);
    expect((await tools.listConflicts({ entityType: 'settings' })).conflicts).toHaveLength(0);
    expect((await tools.listConflicts({ limit: 1 })).conflicts).toHaveLength(1);
  });

  it('get_conflict lists only the fields that differ plus what is live now', async () => {
    const r = await tools.getConflict({ id });
    expect(r.differences).toEqual([{ field: 'title', hub: HUB_TITLE, device: DEVICE_TITLE }]);
    expect(r.current).toMatchObject({ clock: HUB_CLOCK, deletedAt: null, supersedes: false });
    expect(r.conflict.id).toBe(id);
    await expect(tools.getConflict({ id: 'cf-nope' })).rejects.toThrow(/not found/);
  });

  it('get_conflict reports a live record that already moved past both versions', async () => {
    await tools.updateTask({ id: 'tsk-1', memo: 'あとから直した' });
    expect((await tools.getConflict({ id })).current.supersedes).toBe(true);
  });

  it('resolve_conflict with adopt=current only marks the record, writing nothing', async () => {
    const before = await store.read();
    const r = await tools.resolveConflict({ id, adopt: 'current' });
    expect(r).toMatchObject({ id, adopted: 'current', wrote: false });
    expect((await store.read()).taskMaster.tasks).toEqual(before.taskMaster.tasks);
    const stored = (await store.read()).conflicts!.find((c) => c.id === id)!;
    expect(stored.resolution).toBe('current');
    expect(stored.resolvedBy).toBe('hub-0000');
    expect(Hlc.compare(Hlc.parse(stored.clock), Hlc.parse(HUB_CLOCK))).toBeGreaterThan(0);
  });

  it('resolve_conflict with adopt=hub writes nothing when the hub version is already live', async () => {
    const r = await tools.resolveConflict({ id, adopt: 'hub' });
    expect(r.wrote).toBe(false);
    expect((await tools.getTask({ id: 'tsk-1' })).clock).toBe(HUB_CLOCK);
  });

  it('resolve_conflict with adopt=device writes the loser back as a fresh edit', async () => {
    const r = await tools.resolveConflict({ id, adopt: 'device' });
    expect(r.wrote).toBe(true);
    expect(r.summary.updated).toBe(1);
    const task1 = (await store.read()).taskMaster.tasks.find((t) => t.id === 'tsk-1')!;
    expect(task1.title).toBe(DEVICE_TITLE);
    expect(Hlc.compare(Hlc.parse(String(task1.clock)), Hlc.parse(DEVICE_CLOCK))).toBeGreaterThan(0);
    expect(Hlc.compare(Hlc.parse(String(task1.clock)), Hlc.parse(HUB_CLOCK))).toBeGreaterThan(0);
    expect(task1.migrated).toBe(false);
    expect(task1.updatedAt).toBe(iso(now));
  });

  it('adopt=hub means the PC, so it also names a version the browser wrote', async () => {
    const WEB_CLOCK = '30-0-web-abcd';
    const WEB_TITLE = 'ブラウザで直した版';
    await store.update((doc) => {
      // The browser's version is the winner and is labelled `web`, not `hub`.
      // Reading `side === 'hub'` literally would hand `adopt: 'hub'` the
      // phone's snapshot — the exact opposite of what the user asked for.
      doc.conflicts = [
        record('tsk-2', task('tsk-2', WEB_TITLE, WEB_CLOCK), task('tsk-2', '端末の版', DEVICE_CLOCK), {
          winner: {
            side: 'web', deviceId: 'web-abcd', clock: WEB_CLOCK, updatedAt: iso(now - 10_000),
            snapshot: task('tsk-2', WEB_TITLE, WEB_CLOCK) as ConflictJson['winner']['snapshot'],
          },
        }),
      ];
      return doc;
    });
    const webId = (await store.read()).conflicts![0].id;
    expect((await tools.getConflict({ id: webId })).differences).toEqual([
      { field: 'title', hub: WEB_TITLE, device: '端末の版' },
    ]);
    const r = await tools.resolveConflict({ id: webId, adopt: 'hub' });
    expect(r.wrote).toBe(true);
    expect((await tools.getTask({ id: 'tsk-2' })).title).toBe(WEB_TITLE);
  });

  it('adopting a tombstone deletes the entity again', async () => {
    await store.update((doc) => {
      doc.conflicts = [
        record('tsk-2', task('tsk-2', 'hub の版', HUB_CLOCK), tombstone('tsk-2', DEVICE_CLOCK)),
      ];
      return doc;
    });
    const deletedId = conflictId('tsk-2', HUB_CLOCK, DEVICE_CLOCK);
    const r = await tools.resolveConflict({ id: deletedId, adopt: 'device' });
    expect(r.wrote).toBe(true);
    expect(r.summary.deleted).toBe(1);
    const stored = (await store.read()).taskMaster.tasks.find((t) => t.id === 'tsk-2')!;
    expect(typeof stored.deletedAt).toBe('string');
    expect(stored.title).toBeUndefined();
    await expect(tools.getTask({ id: 'tsk-2' })).rejects.toThrow(/deleted/);
  });

  it('resolve_all_conflicts is all-or-nothing and dryRun writes nothing', async () => {
    const dry = await tools.resolveAllConflicts({ adopt: 'hub', dryRun: true });
    expect(dry.resolved).toBe(2);
    expect((await store.read()).conflicts!.filter((c) => c.resolution == null)).toHaveLength(2);
    const done = await tools.resolveAllConflicts({ adopt: 'hub' });
    expect(done.results).toHaveLength(2);
    expect(done.resolved).toBe(2);
    expect(done.skipped).toBe(1);
    expect((await store.read()).conflicts!.every((c) => c.resolution != null)).toBe(true);
  });

  it('resolve_all_conflicts can be limited to one entity type and adopts the device side', async () => {
    const r = await tools.resolveAllConflicts({ adopt: 'device', entityType: 'settings' });
    expect(r.resolved).toBe(0);
    expect((await store.read()).conflicts!.filter((c) => c.resolution == null)).toHaveLength(2);
    const tasks = await tools.resolveAllConflicts({ adopt: 'device', entityType: 'task' });
    expect(tasks.resolved).toBe(2);
    expect(tasks.results.every((x) => x.wrote)).toBe(true);
    const titles = (await tools.listTasks({})).map((t) => t.title).sort();
    expect(titles).toEqual([DEVICE_TITLE, 'すでに決めた版', '端末の版'].sort());
  });

  it('resolving twice is refused rather than silently re-resolving', async () => {
    await tools.resolveConflict({ id, adopt: 'current' });
    await expect(tools.resolveConflict({ id, adopt: 'device' })).rejects.toThrow(/already resolved/);
    await expect(tools.resolveConflict({ id: resolvedId, adopt: 'current' })).rejects.toThrow(/already resolved/);
    expect(secondId).not.toBe(id);
  });
});
