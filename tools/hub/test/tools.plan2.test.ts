import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { HubConfig } from '../src/config.js';
import { HlcClock } from '../src/hlc.js';
import { emptyDocument } from '../src/model.js';
import { FileStore } from '../src/store.js';
import { SyncEngine } from '../src/sync-engine.js';
import { HubTools } from '../src/tools.js';

let dir: string;
let tools: HubTools;
let cfg: HubConfig;
let engine: SyncEngine;
let store: FileStore;

const lanInfo = () => ({
  listening: true,
  disabled: false,
  url: 'https://192.168.1.10:47820',
  addresses: ['192.168.1.10', '10.0.0.5'],
  port: 47820,
  pairingPage: 'http://127.0.0.1:47821/deadbeefdeadbeefdeadbeefdeadbeef/pair',
  qrPage: 'http://127.0.0.1:47821/deadbeefdeadbeefdeadbeefdeadbeef/qr',
});

const importable = (deviceId: string) => {
  const doc = emptyDocument(deviceId);
  doc.taskMaster.tasks.push({
    id: 'imported', title: 'x', kind: 'must_do', priority: 3, createdAt: 'c', memo: '',
    categoryId: null, estimatedMinutes: 0, clock: '5-0-android-1',
    updatedAt: '2026-09-09T00:00:00.000Z', deletedAt: null, migrated: false,
  });
  return doc;
};

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), 'hub-tools2-'));
  cfg = await HubConfig.load(dir);
  store = new FileStore(dir, 'hub-0000');
  const clock = new HlcClock('hub-0000');
  engine = new SyncEngine(store, cfg, clock);
  tools = new HubTools(store, clock, () => new Date(), { config: cfg, engine, lan: lanInfo, importDirs: [dir] });
});

afterEach(() => rmSync(dir, { recursive: true, force: true }));

describe('plan 2 tools', () => {
  it('import_file merges a v2 file and reports counts', async () => {
    const path = join(dir, 'phone.json');
    writeFileSync(path, JSON.stringify(importable('android-1')));
    const r = await tools.importFile({ path });
    expect(r.summary.added).toBe(1);
    expect(r.deviceId).toBe('android-1');
    expect(r.warnings).toEqual([]);
    expect((await tools.listTasks({})).map((t) => t.id)).toEqual(['imported']);
    await expect(tools.importFile({ path: join(dir, 'missing.json') })).rejects.toThrow(/cannot read file/);
    writeFileSync(path, '{"version": 1}');
    await expect(tools.importFile({ path })).rejects.toThrow(/version/);
  });

  it('import_file registers the file\'s device so purge accounting sees it', async () => {
    const path = join(dir, 'phone.json');
    writeFileSync(path, JSON.stringify(importable('android-2')));
    await tools.importFile({ path });
    expect(cfg.device('android-2')).toBeDefined();
    expect(cfg.device('android-2')!.lastSyncAt).not.toBeNull();
  });

  it('import_file leaves no device record when the merge is rejected', async () => {
    const path = join(dir, 'phone.json');
    const doc = importable('android-3') as unknown as Record<string, unknown>;
    // `taskMaster.settings` is required on the wire; a file without it must not
    // register a device that would then hold back tombstone purge forever.
    delete (doc.taskMaster as Record<string, unknown>).settings;
    writeFileSync(path, JSON.stringify(doc));
    await expect(tools.importFile({ path })).rejects.toThrow(/invalid_document|settings/);
    expect(cfg.device('android-3')).toBeUndefined();
  });

  it('import_file does not consume the pairing code shown on the pairing page', async () => {
    const issued = await cfg.issuePairingCode();
    const path = join(dir, 'phone.json');
    writeFileSync(path, JSON.stringify(importable('android-4')));
    await tools.importFile({ path });
    expect(cfg.pairingCode()?.code).toBe(issued.code);
    expect(cfg.pairingState()).toMatchObject({ state: 'issued', failures: 0 });
  });

  it('import_file refuses a path outside the allowlist without saying whether it exists', async () => {
    const outside = mkdtempSync(join(tmpdir(), 'hub-outside-'));
    const path = join(outside, 'phone.json');
    writeFileSync(path, JSON.stringify(importable('android-5')));
    try {
      await expect(tools.importFile({ path })).rejects.toThrow(`path not allowed: ${path}`);
      expect(cfg.device('android-5')).toBeUndefined();
    } finally {
      rmSync(outside, { recursive: true, force: true });
    }
  });

  it('import_file expands a leading ~ against the allowlist', async () => {
    const home = mkdtempSync(join(tmpdir(), 'hub-home-'));
    writeFileSync(join(home, 'phone.json'), JSON.stringify(importable('android-6')));
    const homed = new HubTools(store, new HlcClock('hub-0000'), () => new Date(), {
      config: cfg, engine, lan: lanInfo, importDirs: [home],
    });
    // `os.homedir()` reads $HOME on POSIX, and the module itself cannot be spied on.
    const previous = process.env.HOME;
    process.env.HOME = home;
    try {
      expect((await homed.importFile({ path: '~/phone.json' })).deviceId).toBe('android-6');
    } finally {
      process.env.HOME = previous;
      rmSync(home, { recursive: true, force: true });
    }
  });

  it('import_file refuses a file over the 20 MB limit and never echoes file bytes on a parse error', async () => {
    const big = join(dir, 'big.json');
    writeFileSync(big, `{"pad":"${'x'.repeat(21 * 1024 * 1024)}"}`);
    await expect(tools.importFile({ path: big })).rejects.toThrow(/20 MB import limit/);

    const junk = join(dir, 'junk.json');
    writeFileSync(junk, 'SECRET-PAYLOAD-not-json');
    const error = await tools.importFile({ path: junk }).then(() => null, (e: unknown) => e as Error);
    expect(error?.message).toBe('not valid JSON');
    expect(error?.message).not.toContain('SECRET-PAYLOAD');
  });

  it('forget_device, rotate_token and purge_tombstones delegate to config/engine', async () => {
    const token = await cfg.redeemPairingCode((await cfg.issuePairingCode()).code, 'android-1', 'Pixel');
    const rotated = await tools.rotateToken({ deviceId: 'android-1' });
    expect(rotated).toMatchObject({ deviceId: 'android-1', rotated: true });
    expect(cfg.device('android-1')!.token).not.toBe(token);
    // The new token must never reach an MCP result: those end up in logs and chat.
    expect(JSON.stringify(rotated)).not.toContain(cfg.device('android-1')!.token);
    expect(rotated.note).toMatch(/pair again/);
    expect((await tools.purgeTombstones()).purged).toBe(0);
    expect((await tools.forgetDevice({ deviceId: 'android-1' })).forgotten).toBe(true);
    await expect(tools.forgetDevice({ deviceId: 'android-1' })).rejects.toThrow(/unknown device/);
    await expect(tools.rotateToken({ deviceId: 'nope' })).rejects.toThrow(/unknown device/);
  });

  it('sync_status exposes LAN state, fingerprint, pairing page, devices and last sync', async () => {
    await cfg.redeemPairingCode((await cfg.issuePairingCode()).code, 'android-1', 'Pixel');
    const s = await tools.syncStatus();
    expect(s.lan).toEqual(lanInfo());
    expect(s.fingerprint).toBe(cfg.fingerprint);
    expect(s.devices[0]).toMatchObject({ deviceId: 'android-1', name: 'Pixel', lastSyncAt: null, progress: null });
    expect(s.devices[0]).not.toHaveProperty('token');
    expect(JSON.stringify(s)).not.toContain(cfg.device('android-1')!.token);
    expect(s.lastSync).toBeNull();
    expect(s.purgedBefore).toBeNull();
    expect(s.lanError).toBeNull();
    expect(s.configError).toBeNull();
  });

  it('sync_status reports the pairing code state without ever printing the code', async () => {
    expect((await tools.syncStatus()).pairing).toEqual({ state: 'none', expiresAt: null, failures: 0 });
    const code = (await cfg.issuePairingCode()).code;
    const issued = await tools.syncStatus();
    expect(issued.pairing.state).toBe('issued');
    expect(issued.pairing.expiresAt).not.toBeNull();
    expect(JSON.stringify(issued)).not.toContain(code);
  });

  it('sync_status reports per-device progress and purgedBefore after a sync and a purge', async () => {
    await cfg.redeemPairingCode((await cfg.issuePairingCode()).code, 'android-1', 'Pixel');
    await engine.sync('android-1', importable('android-1'), 'merge');
    const s = await tools.syncStatus();
    expect(s.devices[0].progress).toMatchObject({ deviceId: 'android-1', stage: 'done' });
    expect(s.devices[0].lastSyncAt).not.toBeNull();
    expect(s.lastSync).toMatchObject({ stage: 'done' });
    await tools.purgeTombstones();
    expect((await tools.syncStatus()).purgedBefore).not.toBeNull();
  });

  it('without LAN deps the local tools still work and the sync tools fail cleanly', async () => {
    const local = new HubTools(store, new HlcClock('hub-0000'));
    const s = await local.syncStatus();
    expect(s.lan).toBeNull();
    expect(s.devices).toEqual([]);
    expect(s.fingerprint).toBeNull();
    await expect(local.purgeTombstones()).rejects.toThrow(/not configured/);
    await expect(local.rotateToken({ deviceId: 'x' })).rejects.toThrow(/not configured/);
  });
});
