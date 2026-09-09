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

const forbidden = (): Reply => ({
  status: 403,
  type: 'application/json',
  body: JSON.stringify({ error: { code: 'forbidden_path', message: 'path escapes the web root' } }),
});

/**
 * A path the caller already decoded must not carry another layer of escapes:
 * `%2e%2e/…` only exists to survive one decode and become `../…` in the next.
 */
const DOUBLE_ENCODED = /%2e|%2f|%5c/i;

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
    // `flutter build web` resolves the placeholder at build time, so a real
    // dist arrives with `<base href="/">`. Whichever spelling is there is
    // replaced rather than merely preceded: two base tags would leave the app
    // depending on the browser honouring the first one.
    const existing = /<base\s[^>]*>/i;
    const body = template.includes('<base href="$FLUTTER_BASE_HREF">')
      ? template.replace('<base href="$FLUTTER_BASE_HREF">', script)
      : existing.test(template)
        ? template.replace(existing, script)
        // A build whose index.html has no base tag at all still needs one first
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
    if (DOUBLE_ENCODED.test(path)) return forbidden();

    // Normalize first, then require the result to stay relative and inside the
    // root: `..`, `%2e%2e` (refused above) and absolute paths all die here.
    const relative = normalize(path);
    if (relative.startsWith('..') || relative.startsWith(sep) || relative.includes(`..${sep}`)) {
      return forbidden();
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
    if (real !== this.root && !real.startsWith(this.root + sep)) return forbidden();
    if (!(await stat(real)).isFile()) {
      // A directory is never listed; an extension-less one is still an SPA route.
      return extname(relative) === ''
        ? this.index(inject)
        : { status: 404, type: 'application/json', body: JSON.stringify({ error: { code: 'not_found', message: 'not found' } }) };
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
