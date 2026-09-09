import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { StaticSite } from '../src/static-server.js';

let dir: string; let dist: string; let site: StaticSite;
const inject = { base: '/abc/app/', api: '/abc/api/', hubDeviceId: 'hub-test', dataFile: '/tmp/data.json' };

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), 'hub-static-'));
  dist = join(dir, 'web-dist');
  mkdirSync(join(dist, 'assets'), { recursive: true });
  writeFileSync(join(dist, 'index.html'), '<!doctype html><html><head><base href="$FLUTTER_BASE_HREF"><title>FRELOCATOR</title></head><body><script src="flutter_bootstrap.js" async></script></body></html>');
  writeFileSync(join(dist, 'main.dart.js'), 'console.log(1)');
  writeFileSync(join(dist, 'assets', 'font.woff2'), 'x');
  writeFileSync(join(dir, 'secret.txt'), 'do not serve me');
  symlinkSync(join(dir, 'secret.txt'), join(dist, 'escape.txt'));
  site = new StaticSite(dist);
  await site.load();
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

describe('StaticSite', () => {
  it('serves a file with its MIME type, a strong ETag and no-cache', async () => {
    const r = await site.serve('main.dart.js', inject);
    expect(r.status).toBe(200);
    expect(r.type).toBe('text/javascript; charset=utf-8');
    expect(r.headers?.['cache-control']).toBe('no-cache');
    expect(r.headers?.etag).toMatch(/^"[0-9a-f]{16}"$/);
  });

  it('answers 304 when the client already has that ETag', async () => {
    const first = await site.serve('main.dart.js', inject);
    const again = await site.serve('main.dart.js', inject, first.headers!.etag as string);
    expect(again.status).toBe(304);
    expect(again.body).toBe('');
  });

  it('rewrites <base> and injects __FRELOCATOR_HUB__ into index.html', async () => {
    const r = await site.serve('', inject);
    expect(r.status).toBe(200);
    expect(r.type).toBe('text/html; charset=utf-8');
    expect(String(r.body)).toContain('<base href="/abc/app/">');
    expect(String(r.body)).not.toContain('$FLUTTER_BASE_HREF');
    expect(String(r.body)).toContain('window.__FRELOCATOR_HUB__');
    expect(String(r.body)).toContain('"api": "/abc/api/"');
    // index.html は毎回生成するので ETag は付けない（秘密プレフィックスが起動ごとに変わる）。
    expect(r.headers?.etag).toBeUndefined();
  });

  it('falls back to index.html for extension-less paths (path URL strategy)', async () => {
    const r = await site.serve('sync/conflicts', inject);
    expect(r.status).toBe(200);
    expect(String(r.body)).toContain('<base href="/abc/app/">');
  });

  it('404s a missing file that looks like an asset', async () => {
    expect((await site.serve('assets/missing.png', inject)).status).toBe(404);
  });

  it('refuses traversal, encoded traversal and symlink escapes', async () => {
    for (const path of ['../secret.txt', '..%2fsecret.txt', '%2e%2e/secret.txt', 'assets/../../secret.txt', 'escape.txt']) {
      const r = await site.serve(path, inject);
      expect(r.status, path).toBe(403);
    }
  });

  it('reports itself as missing when web-dist does not exist', async () => {
    const empty = new StaticSite(join(dir, 'nope'));
    await empty.load();
    expect(empty.available).toBe(false);
    const r = await empty.serve('', inject);
    expect(r.status).toBe(503);
    expect(String(r.body)).toContain('npm run build:web');
  });

  it('replaces the base tag a real build already resolved, leaving exactly one', async () => {
    // `flutter build web` substitutes the placeholder at build time, so a real
    // web-dist arrives with `<base href="/">`. Leaving it in place would put
    // two base tags in the document and make the app depend on the browser
    // taking the first one.
    const built = mkdtempSync(join(tmpdir(), 'hub-static-built-'));
    writeFileSync(join(built, 'index.html'), '<!doctype html><html><head>\n  <base href="/">\n  <title>FRELOCATOR</title></head><body></body></html>');
    const real = new StaticSite(built);
    await real.load();
    const body = String((await real.serve('', inject)).body);
    expect(body.match(/<base /g)).toHaveLength(1);
    expect(body).toContain('<base href="/abc/app/">');
    expect(body).toContain('window.__FRELOCATOR_HUB__');
    rmSync(built, { recursive: true, force: true });
  });
});