import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { request } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { HubConfig } from '../src/config.js';
import { HlcClock } from '../src/hlc.js';
import { LocalPages } from '../src/local-pages.js';
import { StaticSite } from '../src/static-server.js';
import { FileStore } from '../src/store.js';
import { SyncEngine } from '../src/sync-engine.js';
import { HubTools, webAppInfo } from '../src/tools.js';
import { WebApi } from '../src/web-api.js';

const WEB_ID = '00112233445566aa';
const HEAD = 'fedcba9876543210fedcba9876543210fedcba98';

let dir: string;
let pages: LocalPages;
let tools: HubTools;
let toolsWithoutSite: HubTools;
let secret: string;
let site: StaticSite;

/** One GET against the local pages server, with the headers a same-origin browser would send. */
const get = (path: string) =>
  new Promise<{ status: number; body: string }>((resolve, reject) => {
    const req = request(
      {
        host: '127.0.0.1',
        port: pages.port,
        path,
        method: 'GET',
        headers: { host: `127.0.0.1:${pages.port}`, 'x-frelocator-web-id': WEB_ID, origin: `http://127.0.0.1:${pages.port}` },
      },
      (res) => { let b = ''; res.on('data', (c) => (b += c)); res.on('end', () => resolve({ status: res.statusCode!, body: b })); },
    );
    req.on('error', reject);
    req.end();
  });

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), 'hub-toolsweb-'));
  const dist = join(dir, 'web-dist');
  mkdirSync(dist, { recursive: true });
  writeFileSync(join(dist, 'index.html'), '<!doctype html><html><head><base href="$FLUTTER_BASE_HREF"></head><body></body></html>');
  writeFileSync(join(dist, 'BUILD_INFO.json'), JSON.stringify({ gitRev: 'abc1234', builtAt: '2026-09-09T00:00:00.000Z' }));
  const config = await HubConfig.load(dir);
  const store = new FileStore(dir, 'hub-test');
  const clock = new HlcClock('hub-test');
  const engine = new SyncEngine(store, config, clock);
  site = new StaticSite(dist);
  await site.load();
  pages = new LocalPages(config, store, {
    port: 0,
    lanUrl: () => 'https://192.168.1.10:47820',
    lanAddresses: () => ['192.168.1.10'],
    site,
    api: new WebApi(engine, config),
  });
  await pages.start();
  secret = new URL(pages.webAppUrl!).pathname.split('/')[1];
  const build = await site.buildInfo();
  const lan = (available: boolean) => () => ({
    listening: true,
    disabled: false,
    url: 'https://192.168.1.10:47820',
    addresses: ['192.168.1.10'],
    port: 47820,
    pairingPage: pages.pairingPage,
    qrPage: pages.qrPage,
    webApp: webAppInfo({
      built: available,
      url: available ? pages.webAppUrl : null,
      build: available ? build : null,
      headRev: HEAD,
    }),
  });
  tools = new HubTools(store, clock, () => new Date(), { config, engine, lan: lan(true) });
  toolsWithoutSite = new HubTools(store, clock, () => new Date(), { config, engine, lan: lan(false) });
});

afterEach(async () => { await pages.stop(); rmSync(dir, { recursive: true, force: true }); });

describe('sync_status and the hub-served web app', () => {
  it('reports the web app URL, its build info and the browsers that touched it', async () => {
    // Opening the app is what registers the browser; nothing else writes webClients.
    expect((await get(`/${secret}/api/document`)).status).toBe(200);
    const status = await tools.syncStatus();
    expect(status.lan!.webApp).toEqual({
      url: `http://127.0.0.1:${pages.port}/${secret}/app/`,
      built: true,
      gitRev: 'abc1234',
      // BUILD_INFO.json names a commit the checkout is no longer on.
      stale: true,
      builtAt: '2026-09-09T00:00:00.000Z',
    });
    expect(status.webClients).toEqual([{ id: `web-${WEB_ID}`, lastSeenAt: expect.any(String) }]);
  });

  it('forget_device also drops a display-only web client', async () => {
    await get(`/${secret}/api/document`);
    await tools.forgetDevice({ deviceId: `web-${WEB_ID}` });
    expect((await tools.syncStatus()).webClients).toEqual([]);
  });

  it('reports built:false with no URL when the hub was started without a web build', async () => {
    const status = await toolsWithoutSite.syncStatus();
    expect(status.lan!.webApp).toEqual({ url: null, built: false, gitRev: null, stale: false, builtAt: null });
  });

  it('web clients are reported apart from the paired devices, so purge never waits on a browser', async () => {
    await get(`/${secret}/api/document`);
    const status = await tools.syncStatus();
    expect(status.devices).toEqual([]);
    expect(status.webClients).toHaveLength(1);
  });

  it('a hub with no LAN deps still answers sync_status with an empty web client list', async () => {
    const bare = new HubTools(new FileStore(dir, 'hub-test'), new HlcClock('hub-test'));
    expect((await bare.syncStatus()).webClients).toEqual([]);
  });
});

describe('webAppInfo', () => {
  it('is not stale when the build names the checked-out commit, even abbreviated', () => {
    expect(webAppInfo({ built: true, url: 'u', build: { gitRev: 'fedcba9', builtAt: 'b' }, headRev: HEAD }).stale).toBe(false);
    expect(webAppInfo({ built: true, url: 'u', build: { gitRev: HEAD, builtAt: 'b' }, headRev: HEAD }).stale).toBe(false);
  });

  it('never claims staleness it cannot prove', () => {
    // No BUILD_INFO.json, or no git: reporting `stale: true` would send the
    // user rebuilding for nothing.
    expect(webAppInfo({ built: true, url: 'u', build: null, headRev: HEAD }).stale).toBe(false);
    expect(webAppInfo({ built: true, url: 'u', build: { gitRev: 'abc1234' }, headRev: null }).stale).toBe(false);
  });

  it('ignores a BUILD_INFO.json whose fields are not strings', () => {
    expect(webAppInfo({ built: true, url: 'u', build: { gitRev: 42, builtAt: {} }, headRev: HEAD }))
      .toEqual({ url: 'u', built: true, gitRev: null, builtAt: null, stale: false });
  });
});
