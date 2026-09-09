import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { HubConfig, MAX_PAIR_FAILURES } from '../src/config.js';

let dir: string;
beforeEach(() => { dir = mkdtempSync(join(tmpdir(), 'hub-config-')); });
afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

describe('HubConfig', () => {
  it('creates hub.json with a certificate on first load and reuses it', async () => {
    const a = await HubConfig.load(dir);
    const b = await HubConfig.load(dir);
    expect(a.fingerprint).toBe(b.fingerprint);
    expect(JSON.parse(readFileSync(join(dir, 'hub.json'), 'utf8')).certPem).toContain('BEGIN CERTIFICATE');
  });

  it('issues a single-use pairing code that expires', async () => {
    let now = 1_000_000;
    const cfg = await HubConfig.load(dir, () => now);
    const code = (await cfg.issuePairingCode()).code;
    expect(code).toMatch(/^[A-Z0-9]{8}$/);
    now += 6 * 60 * 1000;
    await expect(cfg.redeemPairingCode(code, 'android-1', 'Pixel')).rejects.toThrow(/expired/);
    const fresh = (await cfg.issuePairingCode()).code;
    const token = await cfg.redeemPairingCode(fresh, 'android-1', 'Pixel');
    expect(token).toMatch(/^[a-f0-9]{64}$/);
    await expect(cfg.redeemPairingCode(fresh, 'android-2', 'x')).rejects.toThrow(/invalid/);
    expect(cfg.deviceForToken(token)?.deviceId).toBe('android-1');
  });

  it('rotates, forgets and records lastSyncAt', async () => {
    const cfg = await HubConfig.load(dir, () => 5_000);
    const token = await cfg.redeemPairingCode((await cfg.issuePairingCode()).code, 'android-1', 'Pixel');
    const rotated = await cfg.rotateToken('android-1');
    expect(rotated).not.toBe(token);
    expect(cfg.deviceForToken(token)).toBeUndefined();
    await cfg.recordSync('android-1', '2026-09-09T00:00:00.000Z');
    expect(cfg.devices()[0].lastSyncAt).toBe('2026-09-09T00:00:00.000Z');
    await cfg.forgetDevice('android-1');
    expect(cfg.devices()).toEqual([]);
    await expect(cfg.rotateToken('nope')).rejects.toThrow(/unknown device/);
  });

  it('stores hub.json with owner-only permissions', async () => {
    await HubConfig.load(dir);
    expect(statSync(join(dir, 'hub.json')).mode & 0o777).toBe(0o600);
  });

  it('recomputes the fingerprint instead of trusting the stored one', async () => {
    const a = await HubConfig.load(dir);
    const path = join(dir, 'hub.json');
    const json = JSON.parse(readFileSync(path, 'utf8'));
    json.fingerprint = 'DEADBEEF';
    writeFileSync(path, JSON.stringify(json));
    const b = await HubConfig.load(dir);
    expect(b.fingerprint).toBe(a.fingerprint);
  });

  it.each([
    ['corrupt JSON', 'not json at all'],
    ['an array root', '[]'],
    ['a missing certPem', JSON.stringify({ keyPem: 'x', devices: [] })],
    ['non-array devices', JSON.stringify({ certPem: 'x', keyPem: 'y', devices: {} })],
  ])('refuses to mint a new identity over %s', async (_label, text) => {
    const path = join(dir, 'hub.json');
    writeFileSync(path, text);
    await expect(HubConfig.load(dir)).rejects.toThrow(/hub identity lost/);
    const broken = readdirSync(dir).filter((f) => f.startsWith('hub.json.broken-'));
    expect(broken).toHaveLength(1);
    expect(readFileSync(join(dir, broken[0]), 'utf8')).toBe(text);
  });

  it('serializes concurrent recordSync calls into one parseable hub.json', async () => {
    const cfg = await HubConfig.load(dir, () => 5_000);
    const ids = Array.from({ length: 12 }, (_, i) => `android-${i}`);
    for (const id of ids) await cfg.redeemPairingCode((await cfg.issuePairingCode()).code, id, id);
    await Promise.all(ids.map((id, i) => cfg.recordSync(id, `2026-09-0${(i % 9) + 1}T00:00:00.000Z`)));
    const json = JSON.parse(readFileSync(join(dir, 'hub.json'), 'utf8'));
    expect(json.devices).toHaveLength(ids.length);
    for (const d of json.devices) expect(d.lastSyncAt).toMatch(/^2026-09-\d\dT/);
  });

  it('keeps a valid pairing code usable after a wrong attempt', async () => {
    const cfg = await HubConfig.load(dir, () => 5_000);
    const code = (await cfg.issuePairingCode()).code;
    await expect(cfg.redeemPairingCode('WRONGWRO', 'android-1', 'Pixel')).rejects.toThrow(/invalid/);
    expect(cfg.pairingCode()?.code).toBe(code);
    await expect(cfg.redeemPairingCode(code, 'android-1', 'Pixel')).resolves.toMatch(/^[a-f0-9]{64}$/);
  });

  it('clears an expired pairing code even on a wrong attempt', async () => {
    let now = 1_000_000;
    const cfg = await HubConfig.load(dir, () => now);
    await cfg.issuePairingCode();
    now += 6 * 60 * 1000;
    await expect(cfg.redeemPairingCode('WRONGWRO', 'android-1', 'Pixel')).rejects.toThrow(/expired/);
    expect(JSON.parse(readFileSync(join(dir, 'hub.json'), 'utf8')).pairing).toBeNull();
  });

  it('disables a pairing code after too many failed attempts', async () => {
    const cfg = await HubConfig.load(dir, () => 5_000);
    const code = (await cfg.issuePairingCode()).code;
    for (let i = 0; i < 9; i += 1) {
      await expect(cfg.redeemPairingCode('WRONGWRO', 'android-1', 'Pixel')).rejects.toThrow(/invalid/);
    }
    expect(cfg.pairingCode()?.code).toBe(code);
    await expect(cfg.redeemPairingCode(code, 'android-1', 'Pixel')).resolves.toMatch(/^[a-f0-9]{64}$/);

    const again = (await cfg.issuePairingCode()).code;
    for (let i = 0; i < 10; i += 1) {
      await expect(cfg.redeemPairingCode('WRONGWRO', 'android-1', 'Pixel')).rejects.toThrow();
    }
    expect(cfg.pairingCode()).toBeNull();
    await expect(cfg.redeemPairingCode(again, 'android-1', 'Pixel')).rejects.toThrow(/too many/i);
  });

  it('rejects pairing failures as SyncRejected(403)', async () => {
    const cfg = await HubConfig.load(dir, () => 5_000);
    await cfg.issuePairingCode();
    await expect(cfg.redeemPairingCode('WRONGWRO', 'android-1', 'Pixel')).rejects.toMatchObject({ status: 403, code: 'pairing_failed' });
  });

  it('reports the pairing state as expired once the TTL passes and locked once the budget is spent', async () => {
    let now = 1_000_000;
    const cfg = await HubConfig.load(dir, () => now);
    expect(cfg.pairingState()).toEqual({ state: 'none', expiresAt: null, failures: 0 });
    const issued = await cfg.issuePairingCode();
    expect(cfg.pairingState()).toEqual({ state: 'issued', expiresAt: new Date(issued.expiresAt).toISOString(), failures: 0 });

    now += 6 * 60 * 1000;
    expect(cfg.pairingState()).toEqual({ state: 'expired', expiresAt: new Date(issued.expiresAt).toISOString(), failures: 0 });

    const relocked = await cfg.issuePairingCode();
    for (let i = 0; i < MAX_PAIR_FAILURES; i += 1) await cfg.recordPairFailure();
    // Locked wins over expired: the caller needs a new code either way, but the
    // reason it must issue one is the spent budget, not the clock.
    expect(cfg.pairingState()).toEqual({
      state: 'locked',
      expiresAt: new Date(relocked.expiresAt).toISOString(),
      failures: MAX_PAIR_FAILURES,
    });
    expect(cfg.pairingCode()).toBeNull();
  });

  it('registerDevice adds a device without touching pairing state', async () => {
    const cfg = await HubConfig.load(dir, () => 5_000);
    const issued = await cfg.issuePairingCode();
    const record = await cfg.registerDevice('android-9', 'file import');
    expect(record).toMatchObject({ deviceId: 'android-9', name: 'file import', lastSyncAt: null });
    expect(record.token).toMatch(/^[a-f0-9]{64}$/);
    // The on-screen code survives: a file import must not invalidate it.
    expect(cfg.pairingCode()?.code).toBe(issued.code);
    expect(cfg.pairingState()).toMatchObject({ state: 'issued', failures: 0 });

    await cfg.registerDevice('android-9', 'renamed');
    expect(cfg.devices().filter((d) => d.deviceId === 'android-9')).toHaveLength(1);
    expect(cfg.device('android-9')!.name).toBe('renamed');
  });

  it('forgets a device token', async () => {
    const cfg = await HubConfig.load(dir, () => 5_000);
    const token = await cfg.redeemPairingCode((await cfg.issuePairingCode()).code, 'android-1', 'Pixel');
    expect(cfg.deviceForToken(token)?.deviceId).toBe('android-1');
    await cfg.forgetDevice('android-1');
    expect(cfg.deviceForToken(token)).toBeUndefined();
  });

  it('does not rewrite hub.json for a web client seen again within the refresh window', async () => {
    const cfg = await HubConfig.load(dir);
    const path = join(dir, 'hub.json');
    await cfg.recordWebClient('web-00112233445566aa', '2026-09-09T00:00:00.000Z');
    const first = statSync(path).mtimeMs;
    // A browser polls every few seconds; each poll must not cost a file rewrite.
    for (let i = 0; i < 5; i += 1) await cfg.recordWebClient('web-00112233445566aa', '2026-09-09T00:00:10.000Z');
    expect(statSync(path).mtimeMs).toBe(first);
    expect(cfg.webClients()).toEqual([{ id: 'web-00112233445566aa', lastSeenAt: '2026-09-09T00:00:10.000Z' }]);
  });

  it('persists again once the recorded lastSeenAt is older than the refresh window', async () => {
    const cfg = await HubConfig.load(dir);
    await cfg.recordWebClient('web-00112233445566aa', '2026-09-09T00:00:00.000Z');
    await cfg.recordWebClient('web-00112233445566aa', '2026-09-09T00:10:00.000Z');
    const stored = JSON.parse(readFileSync(join(dir, 'hub.json'), 'utf8'));
    expect(stored.webClients).toEqual([{ id: 'web-00112233445566aa', lastSeenAt: '2026-09-09T00:10:00.000Z' }]);
  });

  it('caps the web client list and evicts the least recently seen browser', async () => {
    const cfg = await HubConfig.load(dir);
    // 20 distinct browsers, oldest first.
    for (let i = 0; i < 20; i += 1) {
      await cfg.recordWebClient(`web-${String(i).padStart(16, '0')}`, `2026-09-09T00:${String(i).padStart(2, '0')}:00.000Z`);
    }
    const ids = cfg.webClients().map((c) => c.id);
    expect(ids).toHaveLength(16);
    expect(ids).not.toContain('web-0000000000000000');
    expect(ids).not.toContain('web-0000000000000003');
    expect(ids).toContain('web-0000000000000019');
    expect(JSON.parse(readFileSync(join(dir, 'hub.json'), 'utf8')).webClients).toHaveLength(16);
  });

  it('forgets a browser id through forget_device, without touching paired devices', async () => {
    const cfg = await HubConfig.load(dir);
    await cfg.registerDevice('android-1', 'Pixel');
    await cfg.recordWebClient('web-00112233445566aa', '2026-09-09T00:00:00.000Z');
    await cfg.forgetDevice('web-00112233445566aa');
    expect(cfg.webClients()).toEqual([]);
    expect(cfg.devices().map((d) => d.deviceId)).toEqual(['android-1']);
    await expect(cfg.forgetDevice('web-00112233445566aa')).rejects.toThrow(/unknown device/);
  });
});
