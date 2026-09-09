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

  it('escapes the injected JSON so a hostile data path cannot close the script tag', async () => {
    const hostile = {
      ...inject,
      dataFile: '/tmp/</script><img src=x onerror=alert(1)>/"quoted"/data.json',
    };
    const body = String((await site.serve('', hostile)).body);
    // `</script>` must not survive verbatim anywhere in the document.
    expect(body).not.toContain('</script><img');
    expect(body).toContain('\\u003c/script\\u003e');
    // No closing tag beyond the ones the template and our own block already carry.
    const clean = String((await site.serve('', inject)).body);
    expect(body.match(/<\/script>/g)!).toHaveLength(clean.match(/<\/script>/g)!.length);
  });

  it('escapes U+2028/U+2029, which JSON.stringify leaves as raw line terminators', async () => {
    const body = String((await site.serve('', { ...inject, dataFile: '/tmp/a\u2028b\u2029c.json' })).body);
    expect(body).not.toContain('\u2028');
    expect(body).not.toContain('\u2029');
    expect(body).toContain('\\u2028');
  });

  it('HTML-escapes the base attribute so the prefix cannot break out of href', async () => {
    const body = String((await site.serve('', { ...inject, base: '/a"><script>bad()</script>/' })).body);
    expect(body).toContain('<base href="/a&quot;&gt;&lt;script&gt;bad()&lt;/script&gt;/">');
    expect(body).not.toContain('<script>bad()');
  });

  it('carries a CSP and the shared hardening headers on the app HTML', async () => {
    const r = await site.serve('', inject);
    const csp = r.headers?.['content-security-policy'] ?? '';
    expect(csp).toContain("default-src 'self'");
    expect(csp).toContain("script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'");
    expect(csp).toContain("worker-src 'self' blob:");
    // Flutter downloads CJK fallback glyphs from fonts.gstatic.com; see the comment on CSP.
    expect(csp).toContain('https://fonts.gstatic.com');
  });

  it('re-hashes a file whose size or mtime moved after load(), so a rebuild is never served stale', async () => {
    const before = (await site.serve('main.dart.js', inject)).headers!.etag;
    // A rebuild writes new bytes without the server reloading.
    writeFileSync(join(dist, 'main.dart.js'), 'console.log(2);// rebuilt with a different length');
    const after = (await site.serve('main.dart.js', inject)).headers!.etag;
    expect(after).not.toBe(before);
    // And the stale ETag must no longer win a conditional request.
    expect((await site.serve('main.dart.js', inject, before as string)).status).toBe(200);
    expect((await site.serve('main.dart.js', inject, after as string)).status).toBe(304);
  });

  it('matches the MIME table case-insensitively without loosening the file lookup', async () => {
    writeFileSync(join(dist, 'LOUD.PNG'), 'x');
    const r = await site.serve('LOUD.PNG', inject);
    expect(r.status).toBe(200);
    expect(r.type).toBe('image/png');
    // Only the MIME key is folded; the path handed to the filesystem is untouched,
    // so a name that does not exist stays a 404 even with a known extension.
    expect((await site.serve('assets/Missing.PNG', inject)).status).toBe(404);
  });

  it('404s a real directory and any trailing slash instead of serving the SPA shell', async () => {
    for (const path of ['assets', 'assets/', 'sync/conflicts/']) {
      expect((await site.serve(path, inject)).status, path).toBe(404);
    }
    // The SPA rule still applies to an extension-less path that names nothing.
    expect((await site.serve('sync/conflicts', inject)).status).toBe(200);
  });

  it('tells the browser not to cache the not-built-yet page', async () => {
    const empty = new StaticSite(join(dir, 'nope'));
    await empty.load();
    const r = await empty.serve('', inject);
    expect(r.status).toBe(503);
    expect(r.headers?.['cache-control']).toBe('no-store');
  });
});
