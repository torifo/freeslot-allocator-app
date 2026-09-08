import { mkdtempSync, rmSync } from 'node:fs';
import { Agent, request } from 'node:https';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { HubConfig } from '../src/config.js';
import { HlcClock } from '../src/hlc.js';
import { LanServer } from '../src/lan-server.js';
import { emptyDocument } from '../src/model.js';
import { FileStore } from '../src/store.js';
import { SyncEngine } from '../src/sync-engine.js';
import { fingerprintOf } from '../src/tls.js';

let dir: string; let server: LanServer; let cfg: HubConfig;
const newAgent = () => new Agent({ rejectUnauthorized: false, checkServerIdentity: () => undefined });
/** Raw request helper: sends `body` verbatim and lets the caller reuse an agent. */
const raw = (method: string, path: string, options: { body?: string; token?: string; agent?: Agent; headers?: Record<string, string>; endRequest?: boolean } = {}) =>
  new Promise<{ status: number; text: string }>((resolve, reject) => {
    const req = request({
      host: '127.0.0.1', port: server.port, method, path,
      agent: options.agent ?? newAgent(),
      headers: { 'content-type': 'application/json', ...(options.token ? { authorization: `Bearer ${options.token}` } : {}), ...options.headers },
    }, (res) => {
      let data = ''; res.on('data', (c) => (data += c)); res.on('end', () => { req.destroy(); resolve({ status: res.statusCode!, text: data }); });
    });
    req.on('error', (e) => { if (!(e as NodeJS.ErrnoException).code?.includes('ECONNRESET')) reject(e); });
    if (options.body !== undefined) req.write(options.body);
    if (options.endRequest !== false) req.end();
  });

const call = (method: string, path: string, body?: unknown, token?: string, expectFp?: string) => new Promise<{ status: number; json: any }>((resolve, reject) => {
  const agent = newAgent();
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
    const code = (await cfg.issuePairingCode()).code;
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
    const code = (await cfg.issuePairingCode()).code;
    const pair = await call('POST', '/pair', { code, deviceId: 'android-9', deviceName: 'Galaxy' });
    expect(pair.status).toBe(200);
    expect(cfg.device('android-9')?.name).toBe('Galaxy');
  });

  it('maps engine rejections to their status codes', async () => {
    const token = await cfg.redeemPairingCode((await cfg.issuePairingCode()).code, 'android-1', 'Pixel');
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
    const token = await cfg.redeemPairingCode((await cfg.issuePairingCode()).code, 'android-1', 'Pixel');
    const doc = { ...emptyDocument('android-1'), blob: 'x'.repeat(21 * 1024 * 1024) };
    const r = await call('POST', '/sync', doc, token);
    expect(r.status).toBe(413);
    expect(r.json.error.code).toBe('payload_too_large');
  });

  it('rejects wrong tokens and unknown routes', async () => {
    expect((await call('GET', '/sync', undefined, 'deadbeef')).status).toBe(401);
    const token = await cfg.redeemPairingCode((await cfg.issuePairingCode()).code, 'android-1', 'Pixel');
    expect((await call('GET', '/nope', undefined, token)).status).toBe(404);
  });
});

describe('LanServer input limits', () => {
  it('rejects an oversized /pair body with 413 before pairing is attempted', async () => {
    const r = await raw('POST', '/pair', { body: JSON.stringify({ code: '1'.repeat(9 * 1024) }) });
    expect(r.status).toBe(413);
    expect(JSON.parse(r.text).error.code).toBe('payload_too_large');
  });

  it('rejects on the content-length header alone, without reading a body', async () => {
    // One byte is written only to flush the headers; the declared 9 KB never arrives,
    // so a 413 here proves the decision came from the content-length header.
    const r = await raw('POST', '/pair', { headers: { 'content-length': String(9 * 1024) }, body: '{', endRequest: false });
    expect(r.status).toBe(413);
    expect(JSON.parse(r.text).error.code).toBe('payload_too_large');
  });

  it('closes the connection after a 413 so a keep-alive agent does not desync', async () => {
    const agent = new Agent({ rejectUnauthorized: false, checkServerIdentity: () => undefined, keepAlive: true, maxSockets: 1 });
    const token = await cfg.redeemPairingCode((await cfg.issuePairingCode()).code, 'android-1', 'Pixel');
    const big = await raw('POST', '/pair', { agent, body: JSON.stringify({ code: 'x'.repeat(9 * 1024) }) });
    expect(big.status).toBe(413);
    const after = await raw('GET', '/health', { agent, token });
    expect(after.status).toBe(200);
    expect(JSON.parse(after.text).ok).toBe(true);
    agent.destroy();
  });

  it('caps pairing field lengths', async () => {
    const code = (await cfg.issuePairingCode()).code;
    const long = await call('POST', '/pair', { code, deviceId: 'z'.repeat(200), name: 'Pixel' });
    expect(long.status).toBe(400);
    expect(long.json.error.code).toBe('bad_request');
    expect((await call('POST', '/pair', { code: 'c'.repeat(65), deviceId: 'android-3' })).status).toBe(400);
  });
});

describe('LanServer error handling', () => {
  it('does not leak internal error detail in a 500 but writes it to stderr', async () => {
    const stderr = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    const secret = '/Users/secret/hub.json EACCES pid 4242';
    vi.spyOn(cfg, 'redeemPairingCode').mockRejectedValue(new Error(secret));
    const r = await call('POST', '/pair', { code: '123456', deviceId: 'android-1' });
    expect(r.status).toBe(500);
    expect(r.json.error).toEqual({ code: 'internal', message: 'internal error' });
    expect(JSON.stringify(r.json)).not.toContain('secret');
    expect(stderr.mock.calls.map((c) => String(c[0])).join('')).toContain(secret);
    vi.restoreAllMocks();
  });

  it('answers malformed JSON with 400 bad_request', async () => {
    const token = await cfg.redeemPairingCode((await cfg.issuePairingCode()).code, 'android-1', 'Pixel');
    const r = await raw('POST', '/sync', { token, body: '{not json' });
    expect(r.status).toBe(400);
    expect(JSON.parse(r.text).error.code).toBe('bad_request');
  });

  it('rejects an unknown sync mode with 400 bad_mode', async () => {
    const token = await cfg.redeemPairingCode((await cfg.issuePairingCode()).code, 'android-1', 'Pixel');
    const r = await call('POST', '/sync?mode=bogus', emptyDocument('android-1'), token);
    expect(r.status).toBe(400);
    expect(r.json.error.code).toBe('bad_mode');
  });

  it('answers a malformed HTTP request line with a JSON 400 envelope', async () => {
    const { connect } = await import('node:tls');
    const text = await new Promise<string>((resolve, reject) => {
      const socket = connect({ host: '127.0.0.1', port: server.port, rejectUnauthorized: false }, () => {
        socket.write('GET /health HTTP/1.1\r\nHost: local\r\nBad Header\r\n\r\n');
      });
      let data = ''; socket.on('data', (c) => (data += c)); socket.on('close', () => resolve(data)); socket.on('error', reject);
    });
    expect(text).toContain('400 Bad Request');
    expect(text).toContain('"bad_request"');
  });
});

describe('LanServer lifecycle and modes', () => {
  it('supports HEAD on /health', async () => {
    const token = await cfg.redeemPairingCode((await cfg.issuePairingCode()).code, 'android-1', 'Pixel');
    const r = await raw('HEAD', '/health', { token });
    expect(r.status).toBe(200);
    expect(r.text).toBe('');
  });

  it('runs take_hub and take_phone end to end', async () => {
    const token = await cfg.redeemPairingCode((await cfg.issuePairingCode()).code, 'android-1', 'Pixel');
    const phone = { ...emptyDocument('android-1'), lastSyncAt: new Date().toISOString() };
    const hub = await call('POST', '/sync?mode=take_hub', phone, token);
    expect(hub.status).toBe(200);
    expect(hub.json.document.deviceId).toBe('hub-0000');
    const mine = await call('POST', '/sync?mode=take_phone', phone, token);
    expect(mine.status).toBe(200);
    expect(mine.json.document.deviceId).toBe('hub-0000');
    expect(mine.json.summary).toBeTruthy();
  });

  it('rejects a token after the device is forgotten', async () => {
    const token = await cfg.redeemPairingCode((await cfg.issuePairingCode()).code, 'android-1', 'Pixel');
    expect((await call('GET', '/health', undefined, token)).status).toBe(200);
    await cfg.forgetDevice('android-1');
    const r = await call('GET', '/health', undefined, token);
    expect(r.status).toBe(401);
    expect(r.json.error.code).toBe('unauthorized');
  });

  it('stop() resolves promptly even with an idle keep-alive connection open', async () => {
    const agent = new Agent({ keepAlive: true, rejectUnauthorized: false, checkServerIdentity: () => undefined });
    // A keep-alive socket keeps `server.close()` pending until it times out.
    expect((await call('GET', '/health')).status).toBe(401);
    await raw('GET', '/health', { agent });
    const started = Date.now();
    await server.stop();
    expect(Date.now() - started).toBeLessThan(2000);
    agent.destroy();
  });

  it('tolerates stop() twice', async () => {
    await server.stop();
    await expect(server.stop()).resolves.toBeUndefined();
  });
});
