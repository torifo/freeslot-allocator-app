import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { copyTree, writeBuildInfo, BUILD_WEB_ARGS } from '../scripts/build-web.mjs';

let dir: string;
beforeEach(() => { dir = mkdtempSync(join(tmpdir(), 'hub-buildweb-')); });
afterEach(() => rmSync(dir, { recursive: true, force: true }));

describe('build-web', () => {
  it('builds without a base-href and without the CDN or a service worker', () => {
    // --base-href は起動ごとに変わる秘密プレフィックスに依存するので、ビルド時には決められない。
    expect(BUILD_WEB_ARGS).toEqual(['build', 'web', '--release', '--pwa-strategy=none', '--no-web-resources-cdn']);
    expect(BUILD_WEB_ARGS.some((a: string) => a.startsWith('--base-href'))).toBe(false);
  });

  it('copyTree replaces the destination instead of layering onto a stale build', () => {
    const src = join(dir, 'src'); const dst = join(dir, 'dst');
    mkdirSync(join(src, 'assets'), { recursive: true });
    writeFileSync(join(src, 'index.html'), '<html>new</html>');
    writeFileSync(join(src, 'assets', 'a.bin'), 'a');
    mkdirSync(dst, { recursive: true });
    writeFileSync(join(dst, 'stale.js'), 'old');
    copyTree(src, dst);
    expect(readFileSync(join(dst, 'index.html'), 'utf8')).toBe('<html>new</html>');
    expect(readFileSync(join(dst, 'assets', 'a.bin'), 'utf8')).toBe('a');
    expect(existsSync(join(dst, 'stale.js'))).toBe(false);
  });

  it('writeBuildInfo records the git rev so sync_status can call the build stale', () => {
    writeBuildInfo(dir, { gitRev: 'abc1234', flutterVersion: '3.47.2', builtAt: '2026-09-09T00:00:00.000Z' });
    const info = JSON.parse(readFileSync(join(dir, 'BUILD_INFO.json'), 'utf8'));
    expect(info).toEqual({ gitRev: 'abc1234', flutterVersion: '3.47.2', builtAt: '2026-09-09T00:00:00.000Z' });
  });
});
