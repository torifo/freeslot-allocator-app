import { mkdtempSync, rmSync } from 'node:fs';
import { get } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { HubConfig } from '../src/config.js';
import { LocalPages } from '../src/local-pages.js';
import { FileStore } from '../src/store.js';

let dir: string;
let pages: LocalPages;
let cfg: HubConfig;

const fetchText = (path: string) =>
  new Promise<{ status: number; body: string; type: string }>((resolve, reject) => {
    get({ host: '127.0.0.1', port: pages.port, path }, (res) => {
      let b = '';
      res.on('data', (c) => (b += c));
      res.on('end', () => resolve({ status: res.statusCode!, body: b, type: String(res.headers['content-type']) }));
    }).on('error', reject);
  });

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), 'hub-pages-'));
  cfg = await HubConfig.load(dir);
  pages = new LocalPages(cfg, new FileStore(dir, 'hub-0000'), {
    port: 0,
    lanUrl: () => 'https://192.168.1.10:47820',
    lanAddresses: () => ['192.168.1.10', '10.0.0.5'],
  });
  await pages.start();
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
    await cfg.redeemPairingCode(await cfg.issuePairingCode(), 'android-1', 'Pixel');
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
      const r = await new Promise<string>((resolve, reject) => {
        get({ host: '127.0.0.1', port: hostile.port, path: '/pair' }, (res) => {
          let b = '';
          res.on('data', (c) => (b += c));
          res.on('end', () => resolve(b));
        }).on('error', reject);
      });
      expect(r).not.toContain('<script>alert(1)</script>');
      expect(r).toContain('&lt;script&gt;alert(1)&lt;/script&gt;');
    } finally {
      await hostile.stop();
    }
  });

  it('/pair reports a missing LAN address instead of rendering a broken QR', async () => {
    const offline = new LocalPages(cfg, new FileStore(dir, 'hub-0000'), { port: 0, lanUrl: () => null, lanAddresses: () => [] });
    await offline.start();
    try {
      const r = await new Promise<number>((resolve, reject) => {
        get({ host: '127.0.0.1', port: offline.port, path: '/pair' }, (res) => {
          res.resume();
          res.on('end', () => resolve(res.statusCode!));
        }).on('error', reject);
      });
      expect(r).toBe(503);
    } finally {
      await offline.stop();
    }
  });

  it('/qr renders animated frames as JSON for the page script and /qr/frames.json lists them', async () => {
    const page = await fetchText('/qr');
    expect(page.status).toBe(200);
    expect(page.body).toContain('id="frame"');
    const frames = await fetchText('/qr/frames.json');
    expect(frames.status).toBe(200);
    expect(frames.type).toContain('application/json');
    const json = JSON.parse(frames.body);
    expect(json.total).toBeGreaterThan(0);
    expect(json.svgs).toHaveLength(json.total);
    expect(json.svgs[0]).toContain('<svg');
  });

  it('unknown paths are 404', async () => {
    expect((await fetchText('/nope')).status).toBe(404);
  });

  it('is not reachable on 0.0.0.0 semantics: binds 127.0.0.1 only', () => {
    expect(pages.host).toBe('127.0.0.1');
  });
});
