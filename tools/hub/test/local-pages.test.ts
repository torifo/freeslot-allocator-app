import { mkdtempSync, rmSync } from 'node:fs';
import { Agent, get, request, type OutgoingHttpHeaders } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { HubConfig } from '../src/config.js';
import { LocalPages } from '../src/local-pages.js';
import { FileStore } from '../src/store.js';

let dir: string;
let pages: LocalPages;
let cfg: HubConfig;
/** The random path prefix `LocalPages.start()` minted, recovered from the advertised URL. */
let secret: string;

interface Res { status: number; body: string; type: string }

const fetchRaw = (
  path: string,
  options: { port?: number; method?: string; headers?: OutgoingHttpHeaders } = {},
): Promise<Res> =>
  new Promise((resolve, reject) => {
    const port = options.port ?? pages.port;
    const req = request(
      {
        host: '127.0.0.1',
        port,
        path,
        method: options.method ?? 'GET',
        headers: { host: `127.0.0.1:${port}`, ...options.headers },
      },
      (res) => {
        let b = '';
        res.on('data', (c) => (b += c));
        res.on('end', () => resolve({ status: res.statusCode!, body: b, type: String(res.headers['content-type']) }));
      },
    );
    req.on('error', reject);
    req.end();
  });

const fetchText = (path: string) => fetchRaw(`/${secret}${path}`);

const prefixOf = (page: LocalPages): string => new URL(page.pairingPage).pathname.split('/')[1];

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), 'hub-pages-'));
  cfg = await HubConfig.load(dir);
  pages = new LocalPages(cfg, new FileStore(dir, 'hub-0000'), {
    port: 0,
    lanUrl: () => 'https://192.168.1.10:47820',
    lanAddresses: () => ['192.168.1.10', '10.0.0.5'],
  });
  await pages.start();
  secret = prefixOf(pages);
});

afterEach(async () => {
  await pages.stop();
  rmSync(dir, { recursive: true, force: true });
});

describe('LocalPages', () => {
  it('/pair issues a code, renders an SVG QR of the frelocator://pair URL and shows the fingerprint', async () => {
    const r = await fetchText('/pair');
    expect(r.status).toBe(200);
    expect(r.type).toContain('text/html');
    expect(r.body).toContain('<svg');
    const code = cfg.pairingCode();
    expect(code).not.toBeNull();
    expect(r.body).toContain(
      `frelocator://pair?host=192.168.1.10&amp;port=47820&amp;fp=${cfg.fingerprint}&amp;code=${code!.code}`,
    );
    expect(r.body).toContain(code!.code);
    expect(r.body).toContain(cfg.fingerprint);
  });

  it('/pair lists every LAN address candidate and the port, and never leaks a device token', async () => {
    await cfg.redeemPairingCode((await cfg.issuePairingCode()).code, 'android-1', 'Pixel');
    const token = cfg.device('android-1')!.token;
    const r = await fetchText('/pair');
    expect(r.body).toContain('192.168.1.10');
    expect(r.body).toContain('10.0.0.5');
    expect(r.body).toContain('47820');
    expect(r.body).not.toContain(token);
  });

  it('/pair reuses a still-valid pairing code instead of invalidating the one already on screen', async () => {
    const first = await fetchText('/pair');
    const code = cfg.pairingCode()!.code;
    const second = await fetchText('/pair');
    expect(cfg.pairingCode()!.code).toBe(code);
    expect(first.body).toContain(code);
    expect(second.body).toContain(code);
  });

  it('/pair escapes hostile values coming from the LAN URL', async () => {
    const hostile = new LocalPages(cfg, new FileStore(dir, 'hub-0000'), {
      port: 0,
      lanUrl: () => 'https://192.168.1.10:47820',
      lanAddresses: () => ['<script>alert(1)</script>'],
    });
    await hostile.start();
    try {
      const r = await fetchRaw(`/${prefixOf(hostile)}/pair`, { port: hostile.port });
      expect(r.body).not.toContain('<script>alert(1)</script>');
      expect(r.body).toContain('&lt;script&gt;alert(1)&lt;/script&gt;');
    } finally {
      await hostile.stop();
    }
  });

  it('/pair reports a missing LAN address instead of rendering a broken QR', async () => {
    const offline = new LocalPages(cfg, new FileStore(dir, 'hub-0000'), { port: 0, lanUrl: () => null, lanAddresses: () => [] });
    await offline.start();
    try {
      expect((await fetchRaw(`/${prefixOf(offline)}/pair`, { port: offline.port })).status).toBe(503);
    } finally {
      await offline.stop();
    }
  });

  it('/qr renders animated frames as JSON for the page script and /qr/frames.json lists them', async () => {
    const page = await fetchText('/qr');
    expect(page.status).toBe(200);
    expect(page.body).toContain('id="frame"');
    // The fetch must stay relative so it resolves under the secret prefix.
    expect(page.body).toContain("fetch('./qr/frames.json')");
    expect(page.body).toContain('id="reload"');
    const frames = await fetchText('/qr/frames.json');
    expect(frames.status).toBe(200);
    expect(frames.type).toContain('application/json');
    const json = JSON.parse(frames.body);
    expect(json.total).toBeGreaterThan(0);
    expect(json.svgs).toHaveLength(json.total);
    expect(json.svgs[0]).toContain('<svg');
  });

  it('/qr/frames.json serves byte-identical output while the document is unchanged', async () => {
    // A persisted data.json makes reads stable; without one every read stamps a
    // fresh `exportedAt` and the cache key legitimately changes.
    const store = new FileStore(dir, 'hub-0000');
    await store.update((d) => d);
    const cached = new LocalPages(cfg, store, { port: 0, lanUrl: () => 'https://192.168.1.10:47820' });
    await cached.start();
    try {
      const prefix = prefixOf(cached);
      const first = await fetchRaw(`/${prefix}/qr/frames.json`, { port: cached.port });
      const second = await fetchRaw(`/${prefix}/qr/frames.json`, { port: cached.port });
      expect(first.status).toBe(200);
      expect(second.body).toBe(first.body);
    } finally {
      await cached.stop();
    }
  });

  it('/qr/frames.json answers 413 too_many_frames when the document needs more frames than allowed', async () => {
    const tight = new LocalPages(cfg, new FileStore(dir, 'hub-0000'), {
      port: 0,
      lanUrl: () => 'https://192.168.1.10:47820',
      maxFrames: 0,
    });
    await tight.start();
    try {
      const r = await fetchRaw(`/${prefixOf(tight)}/qr/frames.json`, { port: tight.port });
      expect(r.status).toBe(413);
      expect(r.type).toContain('application/json');
      expect(JSON.parse(r.body).error.code).toBe('too_many_frames');
    } finally {
      await tight.stop();
    }
  });

  it('unknown paths are 404 with a JSON envelope', async () => {
    const r = await fetchText('/nope');
    expect(r.status).toBe(404);
    expect(r.type).toContain('application/json');
    expect(JSON.parse(r.body).error.code).toBe('not_found');
  });

  it('serves nothing outside the secret prefix', async () => {
    for (const path of ['/pair', '/qr', '/qr/frames.json', '/']) {
      expect((await fetchRaw(path)).status).toBe(404);
    }
    expect((await fetchRaw('/deadbeefdeadbeefdeadbeefdeadbeef/pair')).status).toBe(404);
  });

  it('refuses a rebound Host header so a browser on evil.com cannot read the pairing code', async () => {
    const r = await fetchRaw(`/${secret}/pair`, { headers: { host: 'evil.com' } });
    expect(r.status).toBe(403);
    expect(JSON.parse(r.body).error.code).toBe('forbidden_host');
    expect(r.body).not.toContain(cfg.fingerprint);
  });

  it('accepts localhost as a Host but refuses any cross-origin or cross-site request', async () => {
    expect((await fetchRaw(`/${secret}/pair`, { headers: { host: `localhost:${pages.port}` } })).status).toBe(200);
    const origin = await fetchRaw(`/${secret}/qr/frames.json`, { headers: { origin: 'http://evil.com' } });
    expect(origin.status).toBe(403);
    expect(JSON.parse(origin.body).error.code).toBe('forbidden_origin');
    const site = await fetchRaw(`/${secret}/qr/frames.json`, { headers: { 'sec-fetch-site': 'cross-site' } });
    expect(site.status).toBe(403);
    expect(JSON.parse(site.body).error.code).toBe('forbidden_site');
    expect((await fetchRaw(`/${secret}/pair`, { headers: { 'sec-fetch-site': 'same-origin' } })).status).toBe(200);
  });

  it('refuses state-changing methods: POST /pair issues no code, GET /pair does', async () => {
    const r = await fetchRaw(`/${secret}/pair`, { method: 'POST' });
    expect(r.status).toBe(405);
    expect(JSON.parse(r.body).error.code).toBe('method_not_allowed');
    expect(cfg.pairingCode()).toBeNull();
    expect((await fetchText('/pair')).status).toBe(200);
    expect(cfg.pairingCode()).not.toBeNull();
  });

  it('stop() resolves promptly even with an idle keep-alive connection open', async () => {
    const agent = new Agent({ keepAlive: true });
    await new Promise<void>((resolve, reject) => {
      get({ host: '127.0.0.1', port: pages.port, path: `/${secret}/pair`, agent }, (res) => {
        res.resume();
        res.on('end', () => resolve());
      }).on('error', reject);
    });
    const started = Date.now();
    await pages.stop();
    expect(Date.now() - started).toBeLessThan(2000);
    agent.destroy();
  });

  it('is not reachable on 0.0.0.0 semantics: binds 127.0.0.1 only', () => {
    expect(pages.host).toBe('127.0.0.1');
  });
});
