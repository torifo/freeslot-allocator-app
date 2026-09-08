import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { HubConfig } from '../src/config.js';

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
    const code = await cfg.issuePairingCode();
    expect(code).toMatch(/^[A-Z0-9]{8}$/);
    now += 6 * 60 * 1000;
    await expect(cfg.redeemPairingCode(code, 'android-1', 'Pixel')).rejects.toThrow(/expired/);
    const fresh = await cfg.issuePairingCode();
    const token = await cfg.redeemPairingCode(fresh, 'android-1', 'Pixel');
    expect(token).toMatch(/^[a-f0-9]{64}$/);
    await expect(cfg.redeemPairingCode(fresh, 'android-2', 'x')).rejects.toThrow(/invalid/);
    expect(cfg.deviceForToken(token)?.deviceId).toBe('android-1');
  });

  it('rotates, forgets and records lastSyncAt', async () => {
    const cfg = await HubConfig.load(dir, () => 5_000);
    const token = await cfg.redeemPairingCode(await cfg.issuePairingCode(), 'android-1', 'Pixel');
    const rotated = await cfg.rotateToken('android-1');
    expect(rotated).not.toBe(token);
    expect(cfg.deviceForToken(token)).toBeUndefined();
    await cfg.recordSync('android-1', '2026-09-09T00:00:00.000Z');
    expect(cfg.devices()[0].lastSyncAt).toBe('2026-09-09T00:00:00.000Z');
    await cfg.forgetDevice('android-1');
    expect(cfg.devices()).toEqual([]);
    await expect(cfg.rotateToken('nope')).rejects.toThrow(/unknown device/);
  });
});
