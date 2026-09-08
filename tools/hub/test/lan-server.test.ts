import { mkdtempSync, rmSync } from 'node:fs';
import { Agent, request } from 'node:https';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { HubConfig } from '../src/config.js';
import { HlcClock } from '../src/hlc.js';
import { LanServer } from '../src/lan-server.js';
import { emptyDocument } from '../src/model.js';
import { FileStore } from '../src/store.js';
import { SyncEngine } from '../src/sync-engine.js';
import { fingerprintOf } from '../src/tls.js';

let dir: string; let server: LanServer; let cfg: HubConfig;
const call = (method: string, path: string, body?: unknown, token?: string, expectFp?: string) => new Promise<{ status: number; json: any }>((resolve, reject) => {
  const agent = new Agent({ rejectUnauthorized: false, checkServerIdentity: () => undefined });
  const req = request({ host: '127.0.0.1', port: server.port, method, path, agent, headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) } }, (res) => {
    if (expectFp) expect(fingerprintOf(`-----BEGIN CERTIFICATE-----\n${(res.socket as any).getPeerCertificate().raw.toString('base64')}\n-----END CERTIFICATE-----`)).toBe(expectFp);
    let data = ''; res.on('data', (c) => (data += c)); res.on('end', () => resolve({ status: res.statusCode!, json: data ? JSON.parse(data) : null }));
  });
  req.on('error', reject);
  if (body) req.write(JSON.stringify(body));
  req.end();
});

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), 'hub-lan-'));
  cfg = await HubConfig.load(dir);
  const store = new FileStore(dir, 'hub-0000');
  server = new LanServer(cfg, new SyncEngine(store, cfg, new HlcClock('hub-0000')), { port: 0, host: '127.0.0.1', advertise: false });
  await server.start();
});
afterEach(async () => { await server.stop(); rmSync(dir, { recursive: true, force: true }); });

describe('LanServer', () => {
  it('serves the hub certificate and requires a token for /health', async () => {
    expect((await call('GET', '/health', undefined, undefined, cfg.fingerprint)).status).toBe(401);
  });

  it('pairs with a valid code and then syncs', async () => {
    const code = await cfg.issuePairingCode();
    const pair = await call('POST', '/pair', { code, deviceId: 'android-1', name: 'Pixel' });
    expect(pair.status).toBe(200);
    expect(pair.json.token).toMatch(/^[a-f0-9]{64}$/);
    expect(pair.json.hubDeviceId).toBe('hub-0000');
    expect(pair.json.fingerprint).toBe(cfg.fingerprint);
    expect((await call('POST', '/pair', { code, deviceId: 'android-2', name: 'x' })).status).toBe(403);

    const health = await call('GET', '/health', undefined, pair.json.token);
    expect(health.status).toBe(200);
    expect(health.json.ok).toBe(true);
    expect(health.json.hubDeviceId).toBe('hub-0000');
    expect(health.json.fingerprint).toBe(cfg.fingerprint);
    expect(health.json.version).toBe(2);
    expect(health.json).not.toHaveProperty('deviceId');

    const sync = await call('POST', '/sync', emptyDocument('android-1'), pair.json.token);
    expect(sync.status).toBe(200);
    expect(sync.json.document.version).toBe(2);
    expect(sync.json.summary).toBeTruthy();
    expect(Array.isArray(sync.json.warnings)).toBe(true);
    const get = await call('GET', '/sync', undefined, pair.json.token);
    expect(get.status).toBe(200);
    expect(get.json.document.deviceId).toBe('hub-0000');
  });

  it('accepts deviceName as an alias for name on /pair', async () => {
    const code = await cfg.issuePairingCode();
    const pair = await call('POST', '/pair', { code, deviceId: 'android-9', deviceName: 'Galaxy' });
    expect(pair.status).toBe(200);
    expect(cfg.device('android-9')?.name).toBe('Galaxy');
  });

  it('maps engine rejections to their status codes', async () => {
    const token = await cfg.redeemPairingCode(await cfg.issuePairingCode(), 'android-1', 'Pixel');
    const r = await call('POST', '/sync', { ...emptyDocument('android-1'), version: 1 }, token);
    expect(r.status).toBe(426);
    expect(r.json.error.code).toBe('upgrade_required');

    const bad = await call('POST', '/sync', { version: 2 }, token);
    expect(bad.status).toBe(400);
    expect(bad.json.error.code).toBe('invalid_document');

    const stamp = await call('POST', '/sync', { ...emptyDocument('android-1'), lastSyncAt: 'not-a-date' }, token);
    expect(stamp.status).toBe(400);
    expect(stamp.json.error.code).toBe('bad_timestamp');
  });

  it('rejects an oversized body with 413', async () => {
    const token = await cfg.redeemPairingCode(await cfg.issuePairingCode(), 'android-1', 'Pixel');
    const doc = { ...emptyDocument('android-1'), blob: 'x'.repeat(21 * 1024 * 1024) };
    const r = await call('POST', '/sync', doc, token);
    expect(r.status).toBe(413);
    expect(r.json.error.code).toBe('payload_too_large');
  });

  it('rejects wrong tokens and unknown routes', async () => {
    expect((await call('GET', '/sync', undefined, 'deadbeef')).status).toBe(401);
    const token = await cfg.redeemPairingCode(await cfg.issuePairingCode(), 'android-1', 'Pixel');
    expect((await call('GET', '/nope', undefined, token)).status).toBe(404);
  });
});
