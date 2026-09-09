import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { request } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { HubConfig } from '../src/config.js';
import { HlcClock } from '../src/hlc.js';
import { LocalPages } from '../src/local-pages.js';
import { StaticSite } from '../src/static-server.js';
import { FileStore } from '../src/store.js';
import { SyncEngine } from '../src/sync-engine.js';
import { WebApi } from '../src/web-api.js';
import { emptyDocument } from '../src/model.js';

let dir: string; let pages: LocalPages; let store: FileStore; let secret: string;
const WEB_ID = '00112233445566aa';

const call = (method: string, path: string, options: { body?: string; headers?: Record<string, string> } = {}) =>
  new Promise<{ status: number; body: string; headers: Record<string, string | string[] | undefined> }>((resolve, reject) => {
    const req = request({ host: '127.0.0.1', port: pages.port, path, method, headers: {
      host: `127.0.0.1:${pages.port}`, ...options.headers,
    } }, (res) => { let b = ''; res.on('data', (c) => (b += c)); res.on('end', () => resolve({ status: res.statusCode!, body: b, headers: res.headers })); });
    // The hub may answer (e.g. 413) and close the socket before the declared body
    // is fully written; a post-response EPIPE is expected, not a test failure.
    let responded = false;
    req.on('response', () => { responded = true; });
    req.on('error', (e: NodeJS.ErrnoException) => {
      if (responded && (e.code === 'EPIPE' || e.code === 'ECONNRESET')) return;
      reject(e);
    });
    req.end(options.body);
  });

const post = (path: string, body: unknown, headers: Record<string, string> = {}) =>
  call('POST', path, {
    body: JSON.stringify(body),
    headers: { 'content-type': 'application/json', 'x-frelocator-web-id': WEB_ID, origin: `http://127.0.0.1:${pages.port}`, ...headers },
  });

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), 'hub-webapi-'));
  const dist = join(dir, 'web-dist');
  mkdirSync(dist, { recursive: true });
  writeFileSync(join(dist, 'index.html'), '<!doctype html><html><head><base href="$FLUTTER_BASE_HREF"></head><body></body></html>');
  const config = await HubConfig.load(dir);
  store = new FileStore(dir, 'hub-test');
  const site = new StaticSite(dist);
  await site.load();
  const engine = new SyncEngine(store, config, new HlcClock('hub-test'));
  pages = new LocalPages(config, store, {
    port: 0,
    lanUrl: () => 'https://192.168.1.10:47820',
    site,
    api: new WebApi(engine, config),
  });
  await pages.start();
  secret = new URL(pages.webAppUrl!).pathname.split('/')[1];
});
afterEach(async () => { await pages.stop(); rmSync(dir, { recursive: true, force: true }); });

describe('web API', () => {
  it('GET /api/document returns the hub document with its revision', async () => {
    const r = await call('GET', `/${secret}/api/document`, { headers: { 'x-frelocator-web-id': WEB_ID } });
    expect(r.status).toBe(200);
    const json = JSON.parse(r.body);
    expect(json.document.version).toBe(2);
    expect(json.hubDeviceId).toBe('hub-test');
    expect(json.revision).toMatch(/^[0-9a-f]{16}$/);
    expect(typeof json.serverTime).toBe('string');
  });

  it('GET /api/revision changes when the document changes and is cheap', async () => {
    const first = JSON.parse((await call('GET', `/${secret}/api/revision`, { headers: { 'x-frelocator-web-id': WEB_ID } })).body);
    await store.update((doc) => { doc.taskMaster.tasks.push({ id: 't1', title: 'x', kind: 'must_do', priority: 3, createdAt: 'c', memo: '', categoryId: null, estimatedMinutes: 0, clock: '5-0-web-' + WEB_ID, updatedAt: '2026-09-09T00:00:00.000Z', deletedAt: null, migrated: false }); return doc; });
    const second = JSON.parse((await call('GET', `/${secret}/api/revision`, { headers: { 'x-frelocator-web-id': WEB_ID } })).body);
    expect(second.revision).not.toBe(first.revision);
    expect(second.document).toBeUndefined();
  });

  it('POST /api/sync merges as the web pseudo-device and answers like /sync', async () => {
    const doc = emptyDocument(`web-${WEB_ID}`);
    doc.taskMaster.tasks.push({ id: 'w1', title: 'from the browser', kind: 'must_do', priority: 3, createdAt: 'c', memo: '', categoryId: null, estimatedMinutes: 0, clock: `9-0-web-${WEB_ID}`, updatedAt: '2026-09-09T00:00:00.000Z', deletedAt: null, migrated: false });
    const r = await post(`/${secret}/api/sync?mode=merge`, doc);
    expect(r.status).toBe(200);
    const json = JSON.parse(r.body);
    expect(json.document.taskMaster.tasks.map((t: { id: string }) => t.id)).toContain('w1');
    expect(json.summary.added).toBe(1);
    expect(Array.isArray(json.warnings)).toBe(true);
    expect((await store.read()).taskMaster.tasks).toHaveLength(1);
  });

  it('maps take_web onto the engine take_phone mode', async () => {
    await store.update((doc) => { doc.taskMaster.tasks.push({ id: 'hub-only', title: 'hub', kind: 'must_do', priority: 3, createdAt: 'c', memo: '', categoryId: null, estimatedMinutes: 0, clock: '5-0-hub-test', updatedAt: '2026-09-09T00:00:00.000Z', deletedAt: null, migrated: false }); return doc; });
    const r = await post(`/${secret}/api/sync?mode=take_web`, emptyDocument(`web-${WEB_ID}`));
    expect(r.status).toBe(200);
    expect((await store.read()).taskMaster.tasks).toHaveLength(0);
  });

  it('rejects a bad mode with the same envelope /sync uses', async () => {
    const r = await post(`/${secret}/api/sync?mode=take_moon`, emptyDocument(`web-${WEB_ID}`));
    expect(r.status).toBe(400);
    expect(JSON.parse(r.body).error.code).toBe('bad_mode');
  });

  it('refuses cross-origin, form content types, a missing web id and a bad host', async () => {
    const doc = emptyDocument(`web-${WEB_ID}`);
    expect((await post(`/${secret}/api/sync`, doc, { origin: 'http://evil.example' })).status).toBe(403);
    expect((await post(`/${secret}/api/sync`, doc, { 'content-type': 'application/x-www-form-urlencoded' })).status).toBe(400);
    expect((await post(`/${secret}/api/sync`, doc, { 'x-frelocator-web-id': '' })).status).toBe(403);
    expect((await post(`/${secret}/api/sync`, doc, { 'x-frelocator-web-id': 'ZZZ' })).status).toBe(403);
    expect((await post(`/${secret}/api/sync`, doc, { 'sec-fetch-site': 'cross-site' })).status).toBe(403);
    expect((await call('POST', `/${secret}/api/sync`, { body: '{}', headers: { host: 'evil.example', 'content-type': 'application/json', 'x-frelocator-web-id': WEB_ID } })).status).toBe(403);
  });

  it('still refuses POST outside /api and keeps the pages GET-only', async () => {
    expect((await post(`/${secret}/pair`, {})).status).toBe(405);
    expect((await call('GET', `/${secret}/api/document`, { headers: { origin: 'http://evil.example', 'x-frelocator-web-id': WEB_ID } })).status).toBe(403);
  });

  it('is unreachable without the secret prefix', async () => {
    expect((await call('GET', '/api/document', { headers: { 'x-frelocator-web-id': WEB_ID } })).status).toBe(404);
    expect((await call('GET', '/deadbeefdeadbeefdeadbeefdeadbeef/api/document', { headers: { 'x-frelocator-web-id': WEB_ID } })).status).toBe(404);
  });

  it('413s a body over the shared 20 MB ceiling and closes the connection', async () => {
    const r = await call('POST', `/${secret}/api/sync`, {
      body: 'x'.repeat(64),
      headers: { 'content-type': 'application/json', 'x-frelocator-web-id': WEB_ID, 'content-length': String(21 * 1024 * 1024) },
    });
    expect(r.status).toBe(413);
    expect(JSON.parse(r.body).error.code).toBe('payload_too_large');
    expect(r.headers.connection).toBe('close');
  });

  it('records the browser as a display-only web client, never as a purge-holding device', async () => {
    await post(`/${secret}/api/sync`, emptyDocument(`web-${WEB_ID}`));
    const config = await HubConfig.load(dir);
    expect(config.devices().map((d) => d.deviceId)).not.toContain(`web-${WEB_ID}`);
    expect(config.webClients().map((c) => c.id)).toContain(`web-${WEB_ID}`);
  });

  it('leaves warnings empty on a clean web sync instead of blaming the unknown web device', async () => {
    const r = await post(`/${secret}/api/sync`, emptyDocument(`web-${WEB_ID}`));
    expect(r.status).toBe(200);
    const json = JSON.parse(r.body);
    expect(json.warnings).toEqual([]);
    expect(json.summary.warnings).toBe(0);
  });

  it('answers /api/revision from a stat cache, reading data.json once for repeated polls', async () => {
    const spy = vi.spyOn(store, 'read');
    await call('GET', `/${secret}/api/revision`, { headers: { 'x-frelocator-web-id': WEB_ID } });
    await call('GET', `/${secret}/api/revision`, { headers: { 'x-frelocator-web-id': WEB_ID } });
    await call('GET', `/${secret}/api/revision`, { headers: { 'x-frelocator-web-id': WEB_ID } });
    expect(spy).toHaveBeenCalledTimes(1);
    spy.mockRestore();
  });

  it('does not record a web client for a bare revision poll', async () => {
    await call('GET', `/${secret}/api/revision`, { headers: { 'x-frelocator-web-id': WEB_ID } });
    expect((await HubConfig.load(dir)).webClients()).toEqual([]);
  });

  it('sends the hardening headers on every local page and a CSP on the app HTML', async () => {
    for (const path of [`/${secret}/pair`, `/${secret}/app/`, `/${secret}/api/document`]) {
      const r = await call('GET', path, { headers: { 'x-frelocator-web-id': WEB_ID } });
      expect(r.headers['referrer-policy'], path).toBe('no-referrer');
      expect(r.headers['x-content-type-options'], path).toBe('nosniff');
      expect(r.headers['cross-origin-opener-policy'], path).toBe('same-origin');
    }
    const app = await call('GET', `/${secret}/app/`, { headers: { 'x-frelocator-web-id': WEB_ID } });
    expect(String(app.headers['content-security-policy'])).toContain("default-src 'self'");
  });

  it('400s a malformed escape or an embedded NUL in the app path', async () => {
    expect((await call('GET', `/${secret}/app/%zz`)).status).toBe(400);
    expect((await call('GET', `/${secret}/app/a%00b.js`)).status).toBe(400);
  });

  it('403s a doubly-encoded traversal that would become ../ after one more decode', async () => {
    expect((await call('GET', `/${secret}/app/%252e%252e/secret.txt`)).status).toBe(403);
  });

  it('repeats the headers but no body on HEAD', async () => {
    const r = await call('HEAD', `/${secret}/app/`, { headers: { 'x-frelocator-web-id': WEB_ID } });
    expect(r.status).toBe(200);
    expect(r.body).toBe('');
    expect(r.headers['content-type']).toContain('text/html');
  });

  it('names POST in the 405 it sends for a non-API route', async () => {
    const r = await post(`/${secret}/pair`, {});
    expect(r.status).toBe(405);
    expect(JSON.parse(r.body).error.message).toMatch(/POST/);
  });
});

describe('local pages without a web build', () => {
  let bareDir: string; let bare: LocalPages; let bareSecret: string;
  beforeEach(async () => {
    bareDir = mkdtempSync(join(tmpdir(), 'hub-noweb-'));
    const config = await HubConfig.load(bareDir);
    const bareStore = new FileStore(bareDir, 'hub-test');
    const site = new StaticSite(join(bareDir, 'web-dist'));
    await site.load();
    bare = new LocalPages(config, bareStore, {
      port: 0,
      lanUrl: () => 'https://192.168.1.10:47820',
      site,
      api: new WebApi(new SyncEngine(bareStore, config, new HlcClock('hub-test')), config),
    });
    await bare.start();
    bareSecret = (bare as unknown as { secret: string }).secret;
  });
  afterEach(async () => { await bare.stop(); rmSync(bareDir, { recursive: true, force: true }); });

  const bareCall = (path: string) => new Promise<{ status: number; body: string; headers: Record<string, string | string[] | undefined> }>((resolve, reject) => {
    const req = request({ host: '127.0.0.1', port: bare.port, path, method: 'GET', headers: { host: `127.0.0.1:${bare.port}` } }, (res) => {
      let b = ''; res.on('data', (c) => (b += c)); res.on('end', () => resolve({ status: res.statusCode!, body: b, headers: res.headers }));
    });
    req.on('error', reject);
    req.end();
  });

  it('reports no web app URL and serves the not-built page over HTTP without caching it', async () => {
    expect(bare.webAppUrl).toBeNull();
    const r = await bareCall(`/${bareSecret}/app/`);
    expect(r.status).toBe(503);
    expect(r.body).toContain('npm run build:web');
    expect(r.headers['cache-control']).toBe('no-store');
  });

  it('does not hand out a cacheable 301 to /app/ when there is nothing to redirect to', async () => {
    const r = await bareCall(`/${bareSecret}/app`);
    expect(r.status).toBe(503);
    expect(r.headers.location).toBeUndefined();
    expect(r.headers['cache-control']).toBe('no-store');
  });
});
