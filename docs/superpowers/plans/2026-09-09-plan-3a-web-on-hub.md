# FRELOCATOR Plan 3a: ハブ上の Web 版（ローカル配信＋同一オリジン API）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ハブ（`tools/hub/`）が Flutter web ビルドを `http://127.0.0.1:<localPort>/<secret>/app/` から自分自身で配信し、そのブラウザが同一オリジンの JSON API 経由でハブの `data.json` を直接読み書きできるようにする。MCP の編集が数秒でブラウザに出て、ブラウザの編集が MCP とスマホの同期に流れる。公開 Web 版（`app.frelocator.riumu.net`）とスマホアプリの挙動は **一切変えない**。

**Architecture:** `scripts/build-web.mjs` がリポジトリ直下で `flutter build web` を回し `tools/hub/web-dist/` へ複製する（git 管理外、`BUILD_INFO.json` に git rev）。`src/static-server.ts`（`StaticSite`）が `web-dist/` を読み、パス検査・MIME・ETag/304・SPA フォールバック・`index.html` への `<base>` と `window.__FRELOCATOR_HUB__` 注入を担う。`src/web-api.ts`（`WebApi`）が `/api/document`・`/api/revision`・`/api/sync` を既存の `SyncEngine` にそのまま流す。両方とも既存の `LocalPages` にルートとして生え、`guard()` を API 用に広げる。Flutter 側は条件付きエクスポートの `HubMode` で `window.__FRELOCATOR_HUB__` を読み、hub モードなら `stateStoreProvider` が `HubBackedStore`（ローカル永続なし・2 秒ポーリング）を返す。

**Tech Stack:** Node 22 / TypeScript 5、`vitest`、既存の `node:http` サーバー（新規依存なし）。Flutter 3.47 / Dart 3.11、`package:http`（既存依存、web では `BrowserClient`）、`dart:js_interop`。

**設計書:** `docs/superpowers/specs/2026-09-09-frelocator-plan3-web-on-hub-and-conflicts.md` の A 節（A-1〜A-6）と F 節「Plan 3a」。未決事項は 5 件すべて推奨案で承認済み（hub モードにローカル控えを持たない／過検出寄り／上限 1000・200 と 30 日 TTL／ハブのローカルページに競合一覧を作らない／Web 擬似端末を purge のカットオフに入れない）。

**Plan 3b への申し送り:**
- `POST /api/sync` は LAN の `POST /sync` と **同じ `SyncEngine.sync()` を通す**。したがって Plan 3b が `SyncResult` に `conflicts` を足せば、Web 側の応答にも自動で乗る。`web-api.ts` は応答オブジェクトを組み立て直さず `SyncResult` をそのまま `JSON.stringify` すること。
- 端末 id は `web-<browserId>`（`browserId` は 16 桁 hex）。Plan 3b の競合レコードの `winner.deviceId` / `loser.deviceId` にこの形が入るので、UI のラベル出し分けは `deviceId.startsWith('web-')` で判定する。
- Web 擬似端末は `hub.json` の `devices` に **入れない**（purge のカットオフ計算対象外）。`webClients` は表示専用。

---

## ファイル構成

- Create: `tools/hub/scripts/build-web.mjs` — リポジトリ直下で `flutter build web` を実行し `web-dist/` へ複製、`BUILD_INFO.json` を書く。
- Create: `tools/hub/src/static-server.ts` — `StaticSite`: `web-dist/` の読み込み、MIME、ETag、`index.html` の生成、パス検査。
- Create: `tools/hub/src/web-api.ts` — `WebApi`: `/api/document`、`/api/revision`、`/api/sync`。
- Modify: `tools/hub/src/local-pages.ts` — `guard()` の拡張、`/app` と `/api` のルーティング、`Reply` に `headers` と `Buffer` ボディを許す。
- Modify: `tools/hub/src/tools.ts` — `LanInfo.webApp`、`SyncStatus.webClients`、`forget_device` を `webClients` にも効かせる。
- Modify: `tools/hub/src/config.ts` — `webClients` の記録（`hub.json` の任意キー）。
- Modify: `tools/hub/src/index.ts` — `LocalPages` に `StaticSite` / `WebApi` を渡す配線。
- Modify: `tools/hub/package.json` — `build:web` スクリプト。
- Modify: `tools/hub/scripts/smoke.mjs` — `sync_status.lan.webApp` と `/api/document` の往復。
- Modify: `tools/hub/README.md`、`docs/web_release_checklist.md`。
- Tests: `tools/hub/test/static-server.test.ts`、`tools/hub/test/web-api.test.ts`、`tools/hub/test/local-pages.web.test.ts`。
- Create: `lib/services/hub_mode/hub_mode.dart`、`hub_mode_web.dart`、`hub_mode_stub.dart`。
- Create: `lib/services/storage/hub_backed_store.dart`。
- Modify: `lib/features/task_master/data/task_master_repository.dart`（`stateStoreProvider` の分岐）、`lib/features/sync/presentation/sync_settings_screen.dart`（hub モードの表示）、`lib/app/app.dart`（未保存バナー）。
- Tests: `test/services/hub_mode_test.dart`、`test/services/storage/hub_backed_store_test.dart`。

共通の約束: API の応答は必ず `application/json`、エラーは既存と同じ `{ error: { code, message } }`。静的配信のパスは `/<secret>/app/...`、API は `/<secret>/api/...`。秘密プレフィックスはハブ起動ごとに変わり、`sync_status` からしか出さない。

---

### Task 1: `build-web.mjs` と `web-dist/`

**Files:**
- Create: `tools/hub/scripts/build-web.mjs`
- Modify: `tools/hub/package.json`（`"build:web": "node scripts/build-web.mjs"`）
- Test: `tools/hub/test/build-web.test.ts`（スクリプトの純粋関数部分だけを検証。実ビルドはテストしない）

- [ ] **Step 1: 失敗するテストを書く**

```ts
// tools/hub/test/build-web.test.ts
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
    expect(BUILD_WEB_ARGS.some((a) => a.startsWith('--base-href'))).toBe(false);
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
```

- [ ] **Step 2: 失敗を確認する**

Run: `cd tools/hub && npm test -- build-web`
Expected: FAIL（`scripts/build-web.mjs` が無い）

- [ ] **Step 3: 実装する**

```js
// tools/hub/scripts/build-web.mjs
#!/usr/bin/env node
// リポジトリ直下で `flutter build web` を回し、成果物を tools/hub/web-dist/ へ複製する。
// build/web を直接配信しないのは、`flutter run -d chrome` や別ブランチのビルドが
// その場所を書き換えるため。web-dist/ はこのスクリプトでしか更新されない。
import { cpSync, existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const repoRoot = join(here, '..', '..', '..');
export const distDir = join(here, '..', 'web-dist');

/** `--base-href` は付けない: 秘密プレフィックスは起動ごとの乱数で、ハブが index.html を返すときに書き換える。 */
export const BUILD_WEB_ARGS = ['build', 'web', '--release', '--pwa-strategy=none', '--no-web-resources-cdn'];

/** 複製前に消す: 前回のビルドに残ったファイルが重なると「消したはずの資産」が配られる。 */
export function copyTree(src, dst) {
  rmSync(dst, { recursive: true, force: true });
  mkdirSync(dst, { recursive: true });
  cpSync(src, dst, { recursive: true });
}

export function writeBuildInfo(dst, info) {
  writeFileSync(join(dst, 'BUILD_INFO.json'), `${JSON.stringify(info, null, 2)}\n`);
}

const capture = (cmd, args, cwd) => {
  try {
    return execFileSync(cmd, args, { cwd, encoding: 'utf8' }).trim();
  } catch {
    return 'unknown';
  }
};

// import されただけのときはビルドしない（テストが関数だけを使う）。
if (process.argv[1] && process.argv[1].endsWith('build-web.mjs')) {
  console.log(`flutter ${BUILD_WEB_ARGS.join(' ')} (cwd: ${repoRoot})`);
  execFileSync('flutter', BUILD_WEB_ARGS, { cwd: repoRoot, stdio: 'inherit' });
  const built = join(repoRoot, 'build', 'web');
  if (!existsSync(join(built, 'index.html'))) throw new Error(`build/web/index.html not found after the build`);
  copyTree(built, distDir);
  writeBuildInfo(distDir, {
    gitRev: capture('git', ['rev-parse', 'HEAD'], repoRoot),
    flutterVersion: capture('flutter', ['--version', '--machine'], repoRoot).slice(0, 400),
    builtAt: new Date().toISOString(),
  });
  console.log(`copied to ${distDir}`);
}
```

`package.json` の `scripts` に追記:

```json
"build:web": "node scripts/build-web.mjs"
```

- [ ] **Step 4: `.git/info/exclude` に追記する**

`.gitignore` には書かない（ユーザー規約: ツール生成物の除外は `.git/info/exclude` に書き、コミットしない）。

```bash
printf '%s\n' 'tools/hub/web-dist/' >> .git/info/exclude
grep -n 'web-dist' .git/info/exclude
```

- [ ] **Step 5: テストを通す**

Run: `cd tools/hub && npm test -- build-web && npm run typecheck`
Expected: PASS

実ビルドの確認（1 回だけ手で）: `cd tools/hub && npm run build:web && ls web-dist/index.html web-dist/BUILD_INFO.json`

- [ ] **Step 6: コミット**

```bash
git add tools/hub/scripts/build-web.mjs tools/hub/test/build-web.test.ts tools/hub/package.json
git commit -m "build(hub): copy the flutter web build into web-dist for local serving / web ビルドを web-dist へ複製する"
```

**レビュー観点:** `--base-href` を付けていないか／`copyTree` が古い成果物を消しているか／`web-dist/` が `git status` に出ないか／`BUILD_INFO.json` に git rev が入るか。

---

### Task 2: 静的配信（`StaticSite`）とルーティング

**Files:**
- Create: `tools/hub/src/static-server.ts`
- Modify: `tools/hub/src/local-pages.ts`（`Reply` の拡張、`/app` ルート）
- Test: `tools/hub/test/static-server.test.ts`

- [ ] **Step 1: 失敗するテストを書く**

```ts
// tools/hub/test/static-server.test.ts
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
});
```

- [ ] **Step 2: 失敗を確認する**

Run: `cd tools/hub && npm test -- static-server`
Expected: FAIL

- [ ] **Step 3: 実装する**

```ts
// tools/hub/src/static-server.ts
import { createHash } from 'node:crypto';
import { readFile, readdir, realpath, stat } from 'node:fs/promises';
import { extname, join, normalize, resolve, sep } from 'node:path';

export interface Reply {
  status: number;
  type: string;
  body: string | Buffer;
  headers?: Record<string, string>;
}

/** What the page needs to know about the hub it is being served from. */
export interface HubInjection {
  base: string;
  api: string;
  hubDeviceId: string;
  dataFile: string;
}

/** Flutter web's output has no content hash in its file names, so the type table is fixed and small. */
const MIME: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.wasm': 'application/wasm',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff2': 'font/woff2',
  '.bin': 'application/octet-stream',
  '.symbols': 'application/octet-stream',
  '.txt': 'text/plain; charset=utf-8',
};

const missingPage = `<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>Web 版が未ビルドです</title></head><body>
<h1>Web 版がまだビルドされていません</h1>
<p><code>cd tools/hub &amp;&amp; npm run build:web</code> を実行してから、この画面を再読み込みしてください。</p></body></html>`;

/** Serves `web-dist/` under the hub's secret prefix. Pure of HTTP: the caller owns the socket. */
export class StaticSite {
  /** Real path of the dist root; every resolved file must stay inside it. */
  private root: string | null = null;
  private readonly etags = new Map<string, string>();
  private indexTemplate: string | null = null;

  constructor(private readonly dir: string) {}

  get available(): boolean { return this.root !== null; }

  /** Reads BUILD_INFO.json; null when the build is missing or the file is unreadable. */
  async buildInfo(): Promise<Record<string, unknown> | null> {
    if (!this.root) return null;
    try {
      return JSON.parse(await readFile(join(this.root, 'BUILD_INFO.json'), 'utf8')) as Record<string, unknown>;
    } catch {
      return null;
    }
  }

  /**
   * Resolves the dist root and hashes every file once, at startup: the ETag
   * has to be strong (Flutter's file names carry no hash), and hashing on
   * every request would re-read several MB per reload.
   */
  async load(): Promise<void> {
    this.etags.clear();
    this.indexTemplate = null;
    try {
      const root = await realpath(this.dir);
      if (!(await stat(join(root, 'index.html'))).isFile()) throw new Error('no index.html');
      this.root = root;
    } catch {
      this.root = null;
      return;
    }
    const walk = async (relative: string): Promise<void> => {
      for (const entry of await readdir(join(this.root!, relative), { withFileTypes: true })) {
        const next = relative ? `${relative}/${entry.name}` : entry.name;
        // Symlinks are skipped rather than followed: the hash table must only
        // describe files that actually live under the dist root.
        if (entry.isDirectory()) await walk(next);
        else if (entry.isFile()) {
          const bytes = await readFile(join(this.root!, next));
          this.etags.set(next, `"${createHash('sha256').update(bytes).digest('hex').slice(0, 16)}"`);
        }
      }
    };
    await walk('');
    this.indexTemplate = await readFile(join(this.root, 'index.html'), 'utf8');
  }

  /** `index.html` is rebuilt per request: the secret prefix changes every hub start. */
  private index(inject: HubInjection): Reply {
    const template = this.indexTemplate ?? '<!doctype html><html><head></head><body></body></html>';
    const script = `<base href="${inject.base}">\n<script>window.__FRELOCATOR_HUB__ = ${JSON.stringify({
      mode: 'hub',
      base: inject.base,
      api: inject.api,
      hubDeviceId: inject.hubDeviceId,
      schema: 2,
      dataFile: inject.dataFile,
    }, null, 2)};</script>`;
    const body = template.includes('<base href="$FLUTTER_BASE_HREF">')
      ? template.replace('<base href="$FLUTTER_BASE_HREF">', script)
      // A build whose index.html has no placeholder still needs the base tag first
      // in <head>, before any relative URL is resolved.
      : template.replace(/<head([^>]*)>/i, `<head$1>\n${script}`);
    return { status: 200, type: 'text/html; charset=utf-8', body, headers: { 'cache-control': 'no-cache' } };
  }

  /**
   * `path` is the part after `/<secret>/app/`, already URL-decoded by the caller.
   * `ifNoneMatch` is the request's `If-None-Match`, if any.
   */
  async serve(path: string, inject: HubInjection, ifNoneMatch?: string): Promise<Reply> {
    if (!this.root) return { status: 503, type: 'text/html; charset=utf-8', body: missingPage };
    if (path === '' || path === 'index.html') return this.index(inject);

    // Normalize first, then require the result to stay relative and inside the
    // root: `..`, `%2e%2e` (decoded by the caller) and absolute paths all die here.
    const relative = normalize(path);
    if (relative.startsWith('..') || relative.startsWith(sep) || relative.includes(`..${sep}`)) {
      return { status: 403, type: 'application/json', body: JSON.stringify({ error: { code: 'forbidden_path', message: 'path escapes the web root' } }) };
    }
    const target = resolve(this.root, relative);
    let real: string;
    try {
      real = await realpath(target);
    } catch {
      // Not a file: extension-less paths are SPA routes, anything else is a 404.
      return extname(relative) === ''
        ? this.index(inject)
        : { status: 404, type: 'application/json', body: JSON.stringify({ error: { code: 'not_found', message: 'not found' } }) };
    }
    // Symlinks are resolved before the containment check, so a link pointing
    // outside the dist root is refused even though its own path looks fine.
    if (real !== this.root && !real.startsWith(this.root + sep)) {
      return { status: 403, type: 'application/json', body: JSON.stringify({ error: { code: 'forbidden_path', message: 'path escapes the web root' } }) };
    }
    const etag = this.etags.get(relative.split(sep).join('/'));
    if (etag && ifNoneMatch === etag) {
      return { status: 304, type: MIME[extname(relative)] ?? 'application/octet-stream', body: '', headers: { etag, 'cache-control': 'no-cache' } };
    }
    const bytes = await readFile(real);
    return {
      status: 200,
      type: MIME[extname(relative)] ?? 'application/octet-stream',
      body: bytes,
      headers: { 'cache-control': 'no-cache', ...(etag ? { etag } : {}) },
    };
  }
}
```

`local-pages.ts` の変更（この Task ではルーティングと `Reply` だけ。ガードは Task 3）:

```ts
// src/local-pages.ts（抜粋）
import { StaticSite, type Reply } from './static-server.js';

export interface LocalPagesOptions {
  port: number;
  lanUrl: () => string | null;
  lanAddresses?: () => string[];
  maxFrames?: number;
  /** Absent when the hub was started without a web build. */
  site?: StaticSite;
}

// ローカルの Reply 型は static-server.ts の物に置き換える（headers と Buffer ボディを持つ）。
// start() の応答書き出しは headers を混ぜる形に:
//   res.writeHead(status, { 'content-type': type, ...(headers ?? {}) });
//   res.end(status === 304 || method === 'HEAD' ? undefined : body);

/** `http://127.0.0.1:<port>/<secret>/app/`; handed out by `sync_status` only. */
get webAppUrl(): string | null {
  return this.options.site?.available ? `http://${this.host}:${this.port}/${this.secret}/app/` : null;
}

// handle() のルーティングに追加（prefix = `/${this.secret}`）:
if (route === `${prefix}/app`) {
  // 末尾スラッシュが無いと <base href> 配下の相対 URL が 1 段上を指す。
  return { status: 301, type: 'text/plain', body: '', headers: { location: `${prefix}/app/` } };
}
if (route === `${prefix}/app/` || route.startsWith(`${prefix}/app/`)) {
  const site = this.options.site;
  if (!site) return jsonError(404, 'not_found', 'the web app is not served by this hub');
  let relative: string;
  try {
    relative = decodeURIComponent(route.slice(`${prefix}/app/`.length));
  } catch {
    // `%zz` のような壊れたエスケープ。デコードできない以上、検査もできない。
    return jsonError(400, 'bad_request', 'malformed path');
  }
  if (relative.includes('\0')) return jsonError(400, 'bad_request', 'malformed path');
  return site.serve(relative, this.injection(), req.headers['if-none-match']);
}
```

`injection()` は `{ base: `${prefix}/app/`, api: `${prefix}/api/`, hubDeviceId: this.store.deviceId, dataFile: this.store.filePath }` を返す小さな private メソッド。

- [ ] **Step 4: テストを通す**

Run: `cd tools/hub && npm test -- static-server local-pages && npm run typecheck`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add tools/hub/src/static-server.ts tools/hub/src/local-pages.ts tools/hub/test/static-server.test.ts
git commit -m "feat(hub): serve the flutter web build under the secret prefix / 秘密プレフィックス配下で web 版を配信する"
```

**レビュー観点:** デコード後に検査しているか（`%2e%2e` が通らないこと）／`realpath` 後の包含判定でシンボリックリンク脱出を弾いているか／`index.html` に ETag を付けていないか（秘密プレフィックスが変わる）／`304` と `HEAD` でボディを書いていないか／ディレクトリ一覧を返していないか。

---

### Task 3: 同一オリジン API（`WebApi`）とガードの拡張

**Files:**
- Create: `tools/hub/src/web-api.ts`
- Modify: `tools/hub/src/local-pages.ts`（`guard()`、POST ルート、ボディ読み出し）
- Modify: `tools/hub/src/config.ts`（`webClients` の記録）
- Test: `tools/hub/test/web-api.test.ts`、`tools/hub/test/local-pages.web.test.ts`

- [ ] **Step 1: 失敗するテストを書く**

```ts
// tools/hub/test/local-pages.web.test.ts
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
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
import { WebApi } from '../src/web-api.js';
import { emptyDocument } from '../src/model.js';

let dir: string; let pages: LocalPages; let store: FileStore; let secret: string;
const WEB_ID = '00112233445566aa';

const call = (method: string, path: string, options: { body?: string; headers?: Record<string, string> } = {}) =>
  new Promise<{ status: number; body: string; headers: Record<string, string | string[] | undefined> }>((resolve, reject) => {
    const req = request({ host: '127.0.0.1', port: pages.port, path, method, headers: {
      host: `127.0.0.1:${pages.port}`, ...options.headers,
    } }, (res) => { let b = ''; res.on('data', (c) => (b += c)); res.on('end', () => resolve({ status: res.statusCode!, body: b, headers: res.headers })); });
    req.on('error', reject);
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
});
```

- [ ] **Step 2: 失敗を確認する**

Run: `cd tools/hub && npm test -- local-pages.web`
Expected: FAIL

- [ ] **Step 3: 実装する**

```ts
// src/web-api.ts
import { createHash } from 'node:crypto';
import type { IncomingMessage } from 'node:http';
import { z } from 'zod';
import type { HubConfig } from './config.js';
import { MAX_BODY } from './limits.js';
import type { SyncDocumentJson } from './model.js';
import type { Reply } from './static-server.js';
import { SyncRejected, type SyncEngine, type SyncMode } from './sync-engine.js';

/** `take_web` is the browser-facing spelling of the engine's `take_phone`. */
const webMode = z.enum(['merge', 'take_hub', 'take_web']);
const WEB_ID = /^[0-9a-f]{16}$/;

const json = (status: number, body: unknown, headers?: Record<string, string>): Reply => ({
  status, type: 'application/json', body: JSON.stringify(body), headers,
});
const error = (status: number, code: string, message: string, headers?: Record<string, string>): Reply =>
  json(status, { error: { code, message } }, headers);

/**
 * The browser half of the hub. Every write goes through the very same
 * `SyncEngine.sync` the LAN server uses, so the phone and the browser can
 * never diverge in merge behaviour, response shape or error codes.
 */
export class WebApi {
  constructor(private readonly engine: SyncEngine, private readonly config: HubConfig) {}

  /** `sha256(data.json)` prefix — the browser polls this instead of the whole document. */
  private revisionOf(doc: SyncDocumentJson): string {
    return createHash('sha256').update(JSON.stringify(doc), 'utf8').digest('hex').slice(0, 16);
  }

  /** `web-<16 hex>`; the shape check is what keeps a hostile id out of the HLC device space. */
  static deviceIdOf(header: unknown): string | null {
    const value = Array.isArray(header) ? header[0] : header;
    return typeof value === 'string' && WEB_ID.test(value) ? `web-${value}` : null;
  }

  async handle(req: IncomingMessage, route: string, search: URLSearchParams, deviceId: string): Promise<Reply> {
    const method = req.method ?? 'GET';
    if (method === 'GET' && route === 'document') {
      const document = await this.engine.store.read();
      await this.config.recordWebClient(deviceId, new Date().toISOString());
      return json(200, {
        document,
        hubDeviceId: this.engine.store.deviceId,
        revision: this.revisionOf(document),
        serverTime: new Date().toISOString(),
      });
    }
    if (method === 'GET' && route === 'revision') {
      const document = await this.engine.store.read();
      return json(200, {
        revision: this.revisionOf(document),
        modifiedAt: (await this.engine.store.modifiedAt())?.toISOString() ?? null,
      });
    }
    if (method === 'POST' && route === 'sync') {
      const mode = webMode.safeParse(search.get('mode') ?? 'merge');
      if (!mode.success) return error(400, 'bad_mode', 'mode must be merge|take_hub|take_web');
      let body: unknown;
      try {
        body = await readJson(req);
      } catch (e) {
        if (e instanceof SyncRejected) return error(e.status, e.code, e.message, e.status === 413 ? { connection: 'close' } : undefined);
        return error(400, 'bad_request', 'body is not valid JSON');
      }
      const engineMode: SyncMode = mode.data === 'take_web' ? 'take_phone' : mode.data;
      try {
        const result = await this.engine.sync(deviceId, body as SyncDocumentJson, engineMode);
        await this.config.recordWebClient(deviceId, new Date().toISOString());
        // Passed through verbatim so Plan 3b's `conflicts` field appears here
        // the moment SyncResult gains it.
        return json(200, result);
      } catch (e) {
        if (e instanceof SyncRejected) return error(e.status, e.code, e.message);
        throw e;
      }
    }
    return error(404, 'not_found', `${method} ${route}`);
  }
}

/** Same ceiling and same 413 semantics as `lan-server.ts`; duplicated deliberately so the two servers stay independent. */
async function readJson(req: IncomingMessage, max = MAX_BODY): Promise<unknown> {
  const tooLarge = () => new SyncRejected(413, 'payload_too_large', `request body exceeds ${max} bytes`);
  const declared = Number(req.headers['content-length']);
  if (Number.isFinite(declared) && declared > max) throw tooLarge();
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    if (size > max) throw tooLarge();
    chunks.push(chunk as Buffer);
  }
  const text = Buffer.concat(chunks).toString('utf8');
  return text ? JSON.parse(text) : {};
}
```

`local-pages.ts` の `guard()` を広げる（既存の 4 条件は維持し、API 用の緩和だけを足す）:

```ts
private guard(req: IncomingMessage, isApi: boolean): Reply | null {
  const method = req.method ?? 'GET';
  // POST は /<secret>/api/ 配下だけ。ページは今までどおり GET/HEAD のみ。
  if (method !== 'GET' && method !== 'HEAD' && !(isApi && method === 'POST')) {
    return jsonError(405, 'method_not_allowed', 'only GET and HEAD are accepted');
  }
  const host = String(req.headers.host ?? '');
  if (host !== `127.0.0.1:${this.port}` && host !== `localhost:${this.port}`) {
    return jsonError(403, 'forbidden_host', 'this page is only reachable as 127.0.0.1 or localhost');
  }
  // 以前は「Origin があれば一律 403」。同一オリジンの fetch は Origin を付けるため、
  // 完全一致だけを許す形に緩める。他は今までどおり拒否。
  const origin = req.headers.origin;
  if (origin !== undefined && origin !== `http://127.0.0.1:${this.port}` && origin !== `http://localhost:${this.port}`) {
    return jsonError(403, 'forbidden_origin', 'cross-origin requests are not accepted');
  }
  const site = req.headers['sec-fetch-site'];
  if (site !== undefined && site !== 'none' && site !== 'same-origin') {
    return jsonError(403, 'forbidden_site', 'cross-site requests are not accepted');
  }
  if (isApi) {
    // カスタムヘッダはプリフライト無しでクロスオリジン送信できない = 二重の壁。
    if (WebApi.deviceIdOf(req.headers['x-frelocator-web-id']) === null) {
      return jsonError(403, 'forbidden_client', 'X-FRELOCATOR-Web-Id must be 16 hex characters');
    }
    // フォームの simple request による CSRF を封じる。
    if (method === 'POST' && !String(req.headers['content-type'] ?? '').toLowerCase().startsWith('application/json')) {
      return jsonError(400, 'bad_request', 'Content-Type must be application/json');
    }
  }
  return null;
}
```

`handle()` に `/<secret>/api/<route>` を足し、`guard(req, isApi)` の `isApi` はルート判定の結果を渡す。403 で `Connection: close` は付けない（本文を読み切らない POST の 413 のみ）。

`config.ts` の追加（`hub.json` の任意キー。既存 `devices` には触らない）:

```ts
export interface WebClientRecord { id: string; lastSeenAt: string }

// json の型に `webClients?: WebClientRecord[]` を足す。

/** Display-only. Deliberately not part of `devices()`: a browser has no local store, so it must never hold back tombstone purge. */
webClients(): WebClientRecord[] { return (this.json.webClients ?? []).map((c) => ({ ...c })); }

async recordWebClient(id: string, atIso: string): Promise<void> {
  const list = this.json.webClients ?? (this.json.webClients = []);
  const existing = list.find((c) => c.id === id);
  if (existing) existing.lastSeenAt = atIso;
  else list.push({ id, lastSeenAt: atIso });
  await this.save();
}

// forgetDevice: 既知の端末でなければ webClients を見る。
async forgetDevice(deviceId: string): Promise<void> {
  const web = (this.json.webClients ?? []).findIndex((c) => c.id === deviceId);
  if (!this.device(deviceId) && web < 0) throw new Error(`unknown device ${deviceId}`);
  if (web >= 0) this.json.webClients!.splice(web, 1);
  this.json.devices = this.json.devices.filter((d) => d.deviceId !== deviceId);
  await this.save();
}
```

- [ ] **Step 4: テストを通す**

Run: `cd tools/hub && npm test && npm run typecheck && npm run build`
Expected: PASS（既存の `local-pages.test.ts` も含め全部）

- [ ] **Step 5: コミット**

```bash
git add tools/hub/src/web-api.ts tools/hub/src/local-pages.ts tools/hub/src/config.ts tools/hub/test/web-api.test.ts tools/hub/test/local-pages.web.test.ts
git commit -m "feat(hub): same-origin JSON API for the browser app / ブラウザ向け同一オリジン API"
```

**レビュー観点:** `SyncEngine.sync` をそのまま通しているか（応答の再構築をしていないか）／`take_web` → `take_phone` の写像が API 層だけに閉じているか／`Origin` が「無い」か「完全一致」だけ通るか／`X-FRELOCATOR-Web-Id` の形検査が `web-<16hex>` を保証しているか／既存 `local-pages.test.ts` の 403/405 期待が壊れていないか／`webClients` が `devices()` に混ざっていないか。

---

### Task 4: `sync_status` の `webApp` / `webClients` と配線

**Files:**
- Modify: `tools/hub/src/tools.ts`（`LanInfo.webApp`、`SyncStatus.webClients`）
- Modify: `tools/hub/src/index.ts`（`StaticSite` / `WebApi` の生成と `LocalPages` への注入、`lan()` に `webApp`）
- Modify: `tools/hub/README.md`、`docs/mcp_hub_guide.md`（あれば。無ければ README のみ）
- Test: `tools/hub/test/tools.web.test.ts`

- [ ] **Step 1: 失敗するテストを書く**

```ts
// tools/hub/test/tools.web.test.ts（抜粋）
it('sync_status reports the web app URL, its build info and the browsers that touched it', async () => {
  const status = await tools.syncStatus();
  expect(status.lan!.webApp).toEqual({
    url: `http://127.0.0.1:${pages.port}/${secret}/app/`,
    built: true,
    gitRev: 'abc1234',
    stale: true, // BUILD_INFO.json の rev が現在の HEAD と違う
    builtAt: expect.any(String),
  });
  expect(status.webClients).toEqual([{ id: `web-${WEB_ID}`, lastSeenAt: expect.any(String) }]);
});

it('forget_device also drops a display-only web client', async () => {
  await tools.forgetDevice({ deviceId: `web-${WEB_ID}` });
  expect((await tools.syncStatus()).webClients).toEqual([]);
});

it('reports built:false with no URL when the hub was started without a web build', async () => {
  const status = await toolsWithoutSite.syncStatus();
  expect(status.lan!.webApp).toEqual({ url: null, built: false, gitRev: null, stale: false, builtAt: null });
});
```

- [ ] **Step 2: 失敗を確認する**

Run: `cd tools/hub && npm test -- tools.web`
Expected: FAIL

- [ ] **Step 3: 実装する**

```ts
// src/tools.ts（抜粋）
export interface WebAppInfo {
  url: string | null;
  built: boolean;
  gitRev: string | null;
  builtAt: string | null;
  /** True when BUILD_INFO.json names a different commit than the checkout's HEAD. */
  stale: boolean;
}

export interface LanInfo {
  listening: boolean;
  disabled: boolean;
  url: string | null;
  addresses: string[];
  port: number | null;
  pairingPage: string | null;
  qrPage: string | null;
  webApp: WebAppInfo;
}

export interface SyncStatus {
  // …既存…
  /** Browsers that opened the hub-served app. Display only: they hold no local store, so they are not part of the purge cutoff. */
  webClients: WebClientRecord[];
}
```

`syncStatus()` の戻りに `webClients: this.deps ? this.deps.config.webClients() : []` を足す。`deps` が無い経路（hub.json が壊れている）でも `webClients: []` を返すこと。

```ts
// src/index.ts（抜粋）
import { StaticSite } from './static-server.js';
import { WebApi } from './web-api.js';

const site = new StaticSite(join(dirname(fileURLToPath(import.meta.url)), '..', 'web-dist'));
await site.load();
const webApi = config && engine ? new WebApi(engine, config) : null;
const pages = config && lan
  ? new LocalPages(config, store, {
      port: localPort,
      lanUrl: () => (lan.address ? `https://${lan.address}:${lan.port}` : null),
      lanAddresses: () => lanAddresses(),
      site,
      api: webApi ?? undefined,
    })
  : null;

// lan() の戻りに:
webApp: await webAppInfo(site, pages, listening),
```

`webAppInfo` は `BUILD_INFO.json` の `gitRev` と `git rev-parse HEAD`（`execFile`、失敗は `null`）を比べて `stale` を決める小さなヘルパ。`lan()` は同期関数なので、git rev は起動時に一度だけ読んでキャッシュする（`sync_status` のたびに `git` を起こさない）。

- [ ] **Step 4: README と MCP 案内に追記する**

```markdown
## ハブ上の Web 版（Plan 3a）

- 準備: `cd tools/hub && npm run build:web`（リポジトリ直下で `flutter build web` を回して `web-dist/` に置く。`web-dist/` は git 管理外）。
- 開き方: `sync_status` の `lan.webApp.url`（`http://127.0.0.1:47821/<secret>/app/`）をブラウザで開く。URL には起動ごとに変わる秘密プレフィックスが入るので、ブラウザの履歴から開き直さず毎回 `sync_status` から取り直す。
- このブラウザは PC の `data.json` を **直接** 編集する。ブラウザ内に控えは持たない（リロードで未送信の編集は失われる）。
- MCP の編集は 2 秒間隔のポーリングで画面に出る。タブが隠れている間はポーリングを止める。
- `sync_status.lan.webApp.stale` が `true` のときは、`web-dist/` が今の HEAD と違うコミットで作られている。`npm run build:web` を実行し直す。
- `sync_status.webClients` は画面を開いたブラウザの一覧（表示専用）。墓標の掃除（`purge_tombstones`）のカットオフ計算には **入らない**。不要になったら `forget_device` で消せる。
```

- [ ] **Step 5: テストを通す**

Run: `cd tools/hub && npm test && npm run typecheck && npm run build`
Expected: PASS

- [ ] **Step 6: コミット**

```bash
git add tools/hub/src/tools.ts tools/hub/src/index.ts tools/hub/test/tools.web.test.ts tools/hub/README.md
git commit -m "feat(hub): report the web app URL, build staleness and web clients in sync_status / sync_status に web 版の情報を出す"
```

**レビュー観点:** `webApp.url` に秘密プレフィックスが入っており、それ以外の場所（ログ・エラー）に漏れていないか／`webClients` が `devices` と別枠のままか／`stale` の git rev がキャッシュされていて `sync_status` が `git` を毎回起こしていないか／`web-dist` 無しでもハブが起動するか。

---

### Task 5: Flutter の hub モード（`HubMode` と `HubBackedStore`）

**Files:**
- Create: `lib/services/hub_mode/hub_mode.dart`、`lib/services/hub_mode/hub_mode_web.dart`、`lib/services/hub_mode/hub_mode_stub.dart`
- Create: `lib/services/storage/hub_backed_store.dart`
- Modify: `lib/features/task_master/data/task_master_repository.dart`（`stateStoreProvider`）
- Modify: `lib/features/sync/presentation/sync_settings_screen.dart`（hub モードの表示）、`lib/app/app.dart`（未保存バナー）
- Test: `test/services/hub_mode_test.dart`、`test/services/storage/hub_backed_store_test.dart`

- [ ] **Step 1: 失敗するテストを書く**

```dart
// test/services/storage/hub_backed_store_test.dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/services/hub_mode/hub_mode.dart';
import 'package:frelocator/services/storage/hub_backed_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const hub = HubMode(
  base: '/abc/app/',
  api: '/abc/api/',
  hubDeviceId: 'hub-macos',
  dataFile: '/tmp/data.json',
);

Map<String, dynamic> emptyDoc() => <String, dynamic>{
      'version': 2,
      'exportedAt': '2026-09-09T00:00:00.000Z',
      'deviceId': 'hub-macos',
      'lastSyncAt': null,
      'purgedBefore': null,
      'taskMaster': {
        'tasks': [],
        'mustDoCategories': [],
        'wantToDoCategories': [],
        'settings': {'shareCategories': false, 'clock': '0-0-migrated', 'updatedAt': '1970-01-01T00:00:00.000Z', 'deletedAt': null, 'migrated': true},
      },
      'dailyPlan': {'plans': [], 'slots': [], 'assignments': []},
    };

void main() {
  test('reads come from the snapshot fetched once, not from a request per read', () async {
    var documentCalls = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/api/document')) {
        documentCalls += 1;
        return http.Response(jsonEncode({'document': emptyDoc(), 'hubDeviceId': 'hub-macos', 'revision': 'aaaaaaaaaaaaaaaa', 'serverTime': '2026-09-09T00:00:00.000Z'}), 200, headers: {'content-type': 'application/json'});
      }
      throw StateError('unexpected ${request.url}');
    });
    final store = HubBackedStore(hub: hub, webId: '00112233445566aa', client: client);
    await store.readTaskMaster();
    await store.readDailyPlan();
    expect(documentCalls, 1);
  });

  test('writeAll debounces and single-flights into one POST /api/sync', () async {
    final posted = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        return http.Response(jsonEncode({'document': emptyDoc(), 'hubDeviceId': 'hub-macos', 'revision': 'aaaaaaaaaaaaaaaa', 'serverTime': '2026-09-09T00:00:00.000Z'}), 200, headers: {'content-type': 'application/json'});
      }
      expect(request.headers['x-frelocator-web-id'], '00112233445566aa');
      expect(request.headers['content-type'], contains('application/json'));
      expect(request.url.queryParameters['mode'], 'merge');
      posted.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(jsonEncode({'document': emptyDoc(), 'summary': {'added': 0, 'updated': 0, 'deleted': 0, 'removed': 0, 'warnings': 0}, 'warnings': <String>[]}), 200, headers: {'content-type': 'application/json'});
    });
    final store = HubBackedStore(hub: hub, webId: '00112233445566aa', client: client, debounce: const Duration(milliseconds: 20));
    await store.readTaskMaster();
    unawaited(store.writeAll(tasksA, plansA));
    unawaited(store.writeAll(tasksB, plansB));
    await store.flush();
    expect(posted, hasLength(1), reason: '400 ms のデバウンスで 1 回にまとまる');
  });

  test('a failed POST raises the unsent flag and keeps the local snapshot', () async {
    final store = HubBackedStore(hub: hub, webId: '00112233445566aa', client: MockClient((r) async => r.method == 'GET'
        ? http.Response(jsonEncode({'document': emptyDoc(), 'hubDeviceId': 'hub-macos', 'revision': 'a' * 16, 'serverTime': '2026-09-09T00:00:00.000Z'}), 200, headers: {'content-type': 'application/json'})
        : http.Response('{"error":{"code":"internal","message":"boom"}}', 500, headers: {'content-type': 'application/json'})));
    await store.readTaskMaster();
    await store.writeAll(tasksA, plansA);
    await store.flush();
    expect(store.hasUnsentEdits.value, isTrue);
    // 送信に失敗しても画面の内容は消さない（次の再送で送る）。
    expect((await store.readTaskMaster()).tasks, tasksA.tasks);
  });

  test('changedSinceLastRead flips once the poller sees a new revision', () async {
    var revision = 'a' * 16;
    final store = HubBackedStore(hub: hub, webId: '00112233445566aa', client: MockClient((r) async => http.Response(
        jsonEncode(r.url.path.endsWith('/api/revision')
            ? {'revision': revision, 'modifiedAt': null}
            : {'document': emptyDoc(), 'hubDeviceId': 'hub-macos', 'revision': revision, 'serverTime': '2026-09-09T00:00:00.000Z'}),
        200, headers: {'content-type': 'application/json'})));
    await store.readTaskMaster();
    expect(await store.changedSinceLastRead(), isFalse);
    revision = 'b' * 16;
    await store.pollOnce();
    expect(await store.changedSinceLastRead(), isTrue);
  });
}
```

```dart
// test/services/hub_mode_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/services/hub_mode/hub_mode.dart';

void main() {
  test('the non-web build never enters hub mode', () {
    // Android / macOS / テストは stub 側を取り込むので、この分岐は死んでいる。
    expect(readHubMode(), isNull);
  });
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `flutter test test/services/hub_mode_test.dart test/services/storage/hub_backed_store_test.dart`
Expected: FAIL

- [ ] **Step 3: 実装する**

```dart
// lib/services/hub_mode/hub_mode.dart
/// Whether this build is being served by the local MCP hub.
///
/// The conditional export is inverted compared with `lan_sync_client.dart`:
/// the web file is the default and `dart:io` picks the stub, so the Android
/// and macOS builds provably contain no `dart:js_interop` code path.
library;

export 'hub_mode_web.dart' if (dart.library.io) 'hub_mode_stub.dart';
```

```dart
// lib/services/hub_mode/hub_mode_types.dart（両実装が共有する型）
/// The `window.__FRELOCATOR_HUB__` object the hub injects into index.html.
class HubMode {
  const HubMode({
    required this.base,
    required this.api,
    required this.hubDeviceId,
    required this.dataFile,
    this.schema = 2,
  });

  final String base;
  final String api;
  final String hubDeviceId;
  final String dataFile;
  final int schema;
}
```

```dart
// lib/services/hub_mode/hub_mode_stub.dart
export 'hub_mode_types.dart';

/// Always null off the web: the public web build and the phone builds keep
/// their existing `PrefsStateStore` / `FileBackedStore` path untouched.
HubMode? readHubMode() => null;

String? readWebId() => null;
void saveWebId(String id) {}
```

```dart
// lib/services/hub_mode/hub_mode_web.dart
import 'dart:js_interop';

export 'hub_mode_types.dart';

import 'hub_mode_types.dart';

@JS('window.__FRELOCATOR_HUB__')
external JSObject? get _hubGlobal;

@JS('window.localStorage')
external JSObject get _localStorage;

extension type _Storage(JSObject o) implements JSObject {
  external String? getItem(String key);
  external void setItem(String key, String value);
}

extension type _Hub(JSObject o) implements JSObject {
  external String? get base;
  external String? get api;
  external String? get hubDeviceId;
  external String? get dataFile;
  external int? get schema;
}

/// Null on `app.frelocator.riumu.net`: the public build has no such global,
/// so it stays on `PrefsStateStore` exactly as before.
HubMode? readHubMode() {
  final raw = _hubGlobal;
  if (raw == null) return null;
  final hub = _Hub(raw);
  final api = hub.api;
  final base = hub.base;
  if (api == null || base == null) return null;
  return HubMode(
    base: base,
    api: api,
    hubDeviceId: hub.hubDeviceId ?? 'hub',
    dataFile: hub.dataFile ?? '',
    schema: hub.schema ?? 2,
  );
}

const _webIdKey = 'frelocator.webId';

/// The only thing this browser persists. Business data deliberately stays in
/// memory: two copies of the truth would turn every reload into a three-way
/// merge against whatever MCP did while the tab was closed.
String? readWebId() => _Storage(_localStorage).getItem(_webIdKey);
void saveWebId(String id) => _Storage(_localStorage).setItem(_webIdKey, id);
```

```dart
// lib/services/storage/hub_backed_store.dart（骨子）
/// A [StateStore] that lives directly on the hub's data.json.
///
/// Reads answer from the last fetched snapshot; writes update the snapshot and
/// are pushed to `POST /api/sync?mode=merge` after a short debounce, so a burst
/// of edits is one request and MCP's concurrent edits come back already merged.
class HubBackedStore implements StateStore {
  HubBackedStore({
    required HubMode hub,
    required String webId,
    http.Client? client,
    Duration debounce = const Duration(milliseconds: 400),
    Duration pollInterval = const Duration(seconds: 2),
  });

  /// True while an edit has not reached the hub. The app draws a red banner and
  /// registers a `beforeunload` handler while this is set.
  final ValueNotifier<bool> hasUnsentEdits;

  Future<TaskMasterStateData> readTaskMaster();
  Future<DailyPlanStateData> readDailyPlan();
  Future<void> writeTaskMaster(TaskMasterStateData state);   // → writeAll(state, 現在のプラン)
  Future<void> writeDailyPlan(DailyPlanStateData state);     // → writeAll(現在のタスク, state)
  Future<void> writeAll(TaskMasterStateData tasks, DailyPlanStateData plans);
  Future<bool> changedSinceLastRead();
  String? get lastWarning;

  /// Sends any pending edit now (tests and the unload path use it).
  Future<void> flush();
  /// One `/api/revision` round trip; the poller calls it every [pollInterval]
  /// while the tab is visible and stops while it is hidden.
  Future<void> pollOnce();
}
```

実装上の要点:
- 送信は single-flight: 走っている POST があれば「もう一度送る」フラグだけ立て、完了後に 1 回だけ再送する。
- POST は `SyncDocument(...).toJson()` をそのまま送る（LAN と同一の payload）。`deviceId` は `web-<webId>`、`lastSyncAt` は直近の応答の `document.lastSyncAt`。
- 応答の `document` を新しいスナップショットにし、`_observeClocks` 相当で `DeviceClock` を進める（`SyncService._observeClocks` と同じ処理を共通関数に切り出して両方から呼ぶ。片方だけを直して割れるのを防ぐ）。
- `webId` は `readWebId()`、無ければ 16 桁 hex を作って `saveWebId`。**業務データは `localStorage` に書かない**。
- ポーリングは `document.visibilityState` を見る（`hub_mode_web.dart` に `onVisibilityChange` の seam を置き、stub は何もしない）。

`stateStoreProvider` の分岐:

```dart
final stateStoreProvider = Provider<StateStore>((ref) {
  final hub = readHubMode();
  if (hub != null) {
    return HubBackedStore(hub: hub, webId: ensureWebId(), );
  }
  if (!kIsWeb && Platform.isMacOS) { /* 既存のまま */ }
  return PrefsStateStore();
});
```

`Platform` の参照は現状 `dart:io` の直接 import なので、web ビルドでは `kIsWeb` の短絡で評価されない現行の形を崩さないこと（`readHubMode()` の判定を **先に** 置く）。

- [ ] **Step 4: hub モードの UI 調整**

- `sync_settings_screen.dart`: hub モードでは LAN／ペアリング／QR／ファイルの節を隠し、「このブラウザは PC の `data.json` を直接編集しています」＋ 保存先パス（`hub.dataFile`）＋ 最終保存時刻を出す。
- `app.dart`: `HubBackedStore.hasUnsentEdits` を購読して赤帯「PC に保存できていません（再試行）」を出し、`beforeunload` を登録する（登録自体は `hub_mode_web.dart` の seam 経由、stub は no-op）。「未送信の編集はリロードで失われます」を帯の中に書く。

- [ ] **Step 5: テストを通す**

Run: `flutter analyze && flutter test`
Expected: PASS

- [ ] **Step 6: コミット**

```bash
git add lib/services/hub_mode lib/services/storage/hub_backed_store.dart lib/features/task_master/data/task_master_repository.dart lib/features/sync/presentation/sync_settings_screen.dart lib/app/app.dart test/services/hub_mode_test.dart test/services/storage/hub_backed_store_test.dart
git commit -m "feat(app): hub mode store that edits the PC data.json live / hub モードで PC の data.json を直接編集する"
```

**レビュー観点:** `readHubMode()` が web 以外で必ず `null` か（Android の AAB に `dart:js_interop` 経路が入らないこと）／業務データを `localStorage` に書いていないか／single-flight とデバウンスが両方効いているか／送信失敗でスナップショットを捨てていないか／公開 Web 版の経路（`PrefsStateStore`）が 1 行も変わっていないか。

---

### Task 6: 往復スモークと動作確認・ドキュメント

**Files:**
- Modify: `tools/hub/scripts/smoke.mjs`
- Modify: `docs/web_release_checklist.md`
- Modify: `tools/hub/README.md`（Task 4 で書いた節への補足）

- [ ] **Step 1: スモークに往復を足す**

```js
// scripts/smoke.mjs（run 2 = LAN 有効の側に追加）
const status2 = json(await client.callTool({ name: 'sync_status', arguments: {} }));
const webApp = status2.lan.webApp;
check('web app info is reported', typeof webApp === 'object' && webApp !== null);
if (webApp.built) {
  const base = webApp.url;                       // http://127.0.0.1:<port>/<secret>/app/
  const api = base.replace(/\/app\/$/, '/api/');
  const webId = '00112233445566aa';
  const headers = { 'x-frelocator-web-id': webId, origin: new URL(base).origin };

  const index = await httpGet(base, headers);
  check('the hub serves index.html', index.status === 200 && index.body.includes('window.__FRELOCATOR_HUB__'), index.status);
  check('index.html carries the rewritten base href', index.body.includes(`<base href="${new URL(base).pathname}">`));

  // MCP → ブラウザ
  const task = await call('add_task', { title: 'web smoke', kind: 'must_do' });
  const doc = JSON.parse((await httpGet(`${api}document`, headers)).body);
  check('an MCP edit shows up in GET /api/document', doc.document.taskMaster.tasks.some((t) => t.id === task.id));
  check('revision is a 16 hex digest', /^[0-9a-f]{16}$/.test(doc.revision));

  // ブラウザ → MCP
  doc.document.taskMaster.tasks.push({ ...doc.document.taskMaster.tasks[0], id: 'web-smoke-1', title: 'from the browser', clock: `${Date.now()}-0-web-${webId}`, updatedAt: new Date().toISOString() });
  const synced = await httpPost(`${api}sync?mode=merge`, doc.document, { ...headers, 'content-type': 'application/json' });
  check('POST /api/sync answers 200 with a summary', synced.status === 200 && JSON.parse(synced.body).summary !== undefined, synced.status);
  const after = await call('list_tasks', {});
  check('a browser edit shows up in list_tasks', after.some((t) => t.id === 'web-smoke-1'));

  const forbidden = await httpPost(`${api}sync`, {}, { ...headers, origin: 'http://evil.example', 'content-type': 'application/json' });
  check('a cross-origin POST is refused', forbidden.status === 403, forbidden.status);
} else {
  console.log('SKIP web app checks: run `npm run build:web` first');
}
```

`web-dist/` が無い環境（CI・素のクローン）ではスキップして緑のままにする。手元では `npm run build:web` 済みで走らせること。

- [ ] **Step 2: 実行して確認する**

Run: `cd tools/hub && npm run build:web && npm run smoke`
Expected: すべて OK（web の節も含めて）

- [ ] **Step 3: web ビルドの健全性を確認する**

```bash
flutter analyze
flutter test
flutter build web            # 公開 Web 版のビルドが引き続き通ること
flutter build appbundle      # hub モードの分岐が Android ビルドを壊していないこと（成果物は main チェックアウトでのみ）
```

- [ ] **Step 4: 手動確認（ユーザー規約のクロスブラウザ確認）**

- Chrome と Safari で `sync_status` の `lan.webApp.url` を開く。
- MCP から `add_task` → 数秒で画面に出ること。
- ブラウザで編集 → スマホの「PC と同期」に出ること。
- タブを隠す → `/api/revision` が止まること（Network タブ）。
- 保存前にリロード → 未送信バナーと離脱警告が出ること。

- [ ] **Step 5: `docs/web_release_checklist.md` に追記する**

```markdown
## ハブ上の Web 版との関係（Plan 3a）

`app.frelocator.riumu.net` の公開 Web 版は **無変更**。ハブ配信版は
`window.__FRELOCATOR_HUB__` が注入されている場合にだけ hub モードに入り、
公開ビルドにはこの global が無いので従来どおりブラウザローカル
（`PrefsStateStore`）で動く。公開デプロイの手順は今までどおりで、
`tools/hub/web-dist/` は git 管理外なのでデプロイ対象にも入らない。
```

- [ ] **Step 6: コミット**

```bash
git add tools/hub/scripts/smoke.mjs docs/web_release_checklist.md tools/hub/README.md
git commit -m "test(hub): smoke the browser round trip and document the hub-served web app / ブラウザ往復のスモークと手順書"
```

**レビュー観点:** `web-dist` 無しでスモークが落ちないか／往復が MCP → ブラウザ・ブラウザ → MCP の両方向を見ているか／`flutter build web` と `flutter build appbundle` が通るか／公開 Web 版の手順が変わっていないか。

---

## 自己レビュー

- 設計書カバレッジ: A-1 `build-web.mjs` と `BUILD_INFO.json`（Task 1, 4）、A-2 静的配信（パス検査・MIME・ETag/304・SPA フォールバック・`<base>` 注入・503 ページ）（Task 2）、A-3 三つの API と `revision` ポーリング・`take_web` 写像・`browserId`（Task 3, 5）、A-4 ガード（Host / Origin 完全一致 / `Sec-Fetch-Site` / `Content-Type` / web-id / 20 MB / 秘密プレフィックス）（Task 3）、A-5 hub モードの判定・`HubBackedStore`・未送信バナー・HLC の observe・画面の出し分け（Task 5）、A-6 `FileStore.update` の単一ロック・`webClients` を purge 対象外（Task 3, 4）。
- 型の整合（実コードで確認済み）: `SyncEngine.sync(deviceId, incoming, mode) → {document, summary, warnings}`、`SyncRejected(status, code, message)`、`SyncMode = 'merge'|'take_hub'|'take_phone'`、`FileStore.read/update/modifiedAt/filePath/deviceId`、`LocalPages(config, store, options)` と private `secret` / `guard()` / `handle(req)`、`HubToolsDeps { config, engine, lan, importDirs? }`、`LanInfo`、`SyncStatus`、`MAX_BODY`（`limits.ts`）、Dart 側 `StateStore`（`readTaskMaster` / `writeTaskMaster` / `readDailyPlan` / `writeDailyPlan` / `writeAll` / `changedSinceLastRead` / `lastWarning`）、`stateStoreProvider`（`lib/features/task_master/data/task_master_repository.dart`）、`SyncDocument.toJson()`、`DeviceClock`。
- 未決・注意: `dart:js_interop` の条件付きエクスポートは既存 3 ファイル（`lan_sync_client` ほか）と **向きが逆**（web が既定、`dart.library.io` で stub）。理由はコメントに残す。`StaticSite.load()` は起動時に全ファイルを読んで SHA-256 を取るので、web-dist が数 MB あると起動が数十 ms 伸びる。`npm run build:web` のあとハブを再起動しないと ETag が古いままになるため、README に明記する。

---

## 実装者への注意

- **worktree で作業する。** `superpowers:using-git-worktrees` で隔離した作業ツリーを作り、そこで実装する。main のチェックアウトは触らない。
- **TDD を守る。** 各 Task は「失敗するテストを書く → 失敗を確認する → 実装する → 通す → コミット」の順。テストを後から書かない。
- **コミットメッセージに Claude / Anthropic の情報を一切入れない。** `Co-Authored-By: Claude …`、`🤖 Generated with Claude Code`、その他の署名・帰属行は禁止。本文は Conventional Commits の EN / JA 併記のまま。
- **共有フィクスチャ（`test/fixtures/sync_merge/`）の既存ケースは絶対に変更しない。** 追加だけ。Plan 3a では触らない想定。
- **Dart / TS のパリティを保つ。** 片方だけに規則を足さない。この Plan では `SyncEngine` を再利用するだけなので、マージ規則には手を入れないこと。
- **検証コマンド:** `cd tools/hub && npm test && npm run typecheck && npm run build && npm run smoke`、リポジトリ直下で `flutter analyze && flutter test`。全部緑になるまで完了と言わない。
- **リリース成果物（AAB / macOS / web の配布ビルド）は main のチェックアウトでのみ作る。** 署名鍵の `android/key.properties` は worktree に無い。
- **`macos/` の無関係な差分は戻す。** Xcode / CocoaPods が勝手に書き換えたファイルはコミットに含めない。
- **`web-dist/` を git に入れない。** 除外は `.git/info/exclude` に書く（`.gitignore` は編集もコミットもしない）。
