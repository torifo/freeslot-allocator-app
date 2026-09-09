import { randomBytes } from 'node:crypto';
import { createServer, type IncomingMessage, type Server } from 'node:http';
import QRCode from 'qrcode';
import type { HubConfig } from './config.js';
import { lanAddresses } from './net.js';
import { encodeFrames } from './qr-codec.js';
import { StaticSite, type HubInjection, type Reply } from './static-server.js';
import type { FileStore } from './store.js';

export interface LocalPagesOptions {
  port: number;
  /** `https://<host>:<port>` of the LAN server, or null when the host has no LAN address. */
  lanUrl: () => string | null;
  /** Every reachable LAN IPv4, best candidate first; the phone may need one the URL does not carry. */
  lanAddresses?: () => string[];
  /** Hard frame ceiling for `/qr`; injectable so the 413 path is testable without a huge document. */
  maxFrames?: number;
  /** Absent when the hub was started without a web build. */
  site?: StaticSite;
}

/** Frames above this are still served, but the page warns that LAN sync is the better route. */
const QR_WARN_FRAMES = 80;
/** Hard ceiling for a data QR: past this the animation takes longer than a re-pair. */
const QR_MAX_FRAMES = 200;

const esc = (s: string): string =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');

const jsonError = (status: number, code: string, message: string): Reply => ({
  status,
  type: 'application/json',
  body: JSON.stringify({ error: { code, message } }),
});

interface FrameCache { hash: string; body: string }

/** Loopback-only pages: `/pair` prints the pairing code in clear text, so never bind this to a LAN interface. Routes live under a random secret prefix and `guard()` rejects non-loopback navigations. */
export class LocalPages {
  private server: Server | null = null;
  private frameCache: FrameCache | null = null;
  readonly host = '127.0.0.1';
  port = 0;
  /** Random per-process path prefix. Empty until `start()` mints one. */
  private secret = '';

  constructor(
    private readonly config: HubConfig,
    private readonly store: FileStore,
    private readonly options: LocalPagesOptions,
  ) {}

  get listening(): boolean { return this.server !== null; }

  /** `http://127.0.0.1:<port>/<secret>/pair`; the secret is only handed out by `sync_status`. */
  get pairingPage(): string { return `http://${this.host}:${this.port}/${this.secret}/pair`; }
  get qrPage(): string { return `http://${this.host}:${this.port}/${this.secret}/qr`; }

  /** `http://127.0.0.1:<port>/<secret>/app/`; handed out by `sync_status` only. */
  get webAppUrl(): string | null {
    return this.options.site?.available ? `http://${this.host}:${this.port}/${this.secret}/app/` : null;
  }

  /** What the served page is told about the hub it came from. */
  private injection(): HubInjection {
    return {
      base: `/${this.secret}/app/`,
      api: `/${this.secret}/api/`,
      hubDeviceId: this.store.deviceId,
      dataFile: this.store.filePath,
    };
  }

  private addresses(): string[] {
    return (this.options.lanAddresses ?? (() => lanAddresses()))();
  }

  async start(): Promise<void> {
    this.secret = randomBytes(16).toString('hex');
    const server = createServer((req, res) => {
      void this.handle(req)
        .then(({ status, type, body, headers }) => {
          res.writeHead(status, { 'content-type': type, ...(headers ?? {}) });
          // A 304 carries no body, and a HEAD answer must repeat the headers without one.
          res.end(status === 304 || (req.method ?? 'GET') === 'HEAD' ? undefined : body);
        })
        .catch((error: unknown) => {
          // Diagnostics go to stderr: stdout carries the MCP stdio protocol.
          process.stderr.write(`[local-pages] request failed: ${String((error as Error).stack ?? error)}\n`);
          res.writeHead(500, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: { code: 'internal', message: 'internal error' } }));
        });
    });
    this.server = server;
    try {
      await new Promise<void>((resolve, reject) => {
        const onError = (error: unknown) => reject(error);
        server.once('error', onError);
        server.listen(this.options.port, this.host, () => { server.removeListener('error', onError); resolve(); });
      });
    } catch (error) {
      this.server = null;
      throw error;
    }
    server.on('error', (error) => process.stderr.write(`[local-pages] server error: ${String(error)}\n`));
    this.port = (server.address() as { port: number }).port;
  }

  async stop(): Promise<void> {
    const server = this.server;
    this.server = null;
    if (!server) return;
    // `close()` alone waits for every idle keep-alive socket to go away, which
    // hangs shutdown for as long as a browser keeps its connection open.
    const closed = new Promise<void>((resolve) => server.close(() => resolve()));
    server.closeIdleConnections();
    server.closeAllConnections();
    await closed;
  }

  pairingUrl(code: string): string | null {
    const lan = this.options.lanUrl();
    if (!lan) return null;
    const u = new URL(lan);
    return `frelocator://pair?host=${u.hostname}&port=${u.port}&fp=${this.config.fingerprint}&code=${code}`;
  }

  /** Blocks DNS rebinding (`Host: evil.com`) and cross-origin fetches, which always carry `Origin` or a cross-site `Sec-Fetch-Site`. */
  private guard(req: IncomingMessage): Reply | null {
    const method = req.method ?? 'GET';
    if (method !== 'GET' && method !== 'HEAD') {
      return jsonError(405, 'method_not_allowed', 'only GET and HEAD are accepted');
    }
    const host = String(req.headers.host ?? '');
    if (host !== `127.0.0.1:${this.port}` && host !== `localhost:${this.port}`) {
      return jsonError(403, 'forbidden_host', 'this page is only reachable as 127.0.0.1 or localhost');
    }
    if (req.headers.origin !== undefined) {
      return jsonError(403, 'forbidden_origin', 'cross-origin requests are not accepted');
    }
    const site = req.headers['sec-fetch-site'];
    if (site !== undefined && site !== 'none' && site !== 'same-origin') {
      return jsonError(403, 'forbidden_site', 'cross-site requests are not accepted');
    }
    return null;
  }

  private async handle(req: IncomingMessage): Promise<Reply> {
    const blocked = this.guard(req);
    if (blocked) return blocked;
    // Query strings and fragments are ignored: these pages take no input.
    const route = (req.url ?? '/').split('?')[0].split('#')[0];
    const prefix = `/${this.secret}`;
    if (route === prefix || route === `${prefix}/pair`) return this.pairPage();
    if (route === `${prefix}/qr/frames.json`) return this.framesJson();
    if (route === `${prefix}/qr`) return this.qrPageHtml();
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
      const ifNoneMatch = req.headers['if-none-match'];
      return site.serve(relative, this.injection(), Array.isArray(ifNoneMatch) ? ifNoneMatch[0] : ifNoneMatch);
    }
    return jsonError(404, 'not_found', 'not found');
  }

  private async pairPage(): Promise<Reply> {
    // Reuse a code that is still valid: reloading this page (or opening it in a
    // second tab) must not silently invalidate the QR already on screen.
    const { code, expiresAt } = this.config.pairingCode() ?? await this.config.issuePairingCode();
    const url = this.pairingUrl(code);
    if (!url) {
      return {
        status: 503,
        type: 'text/html; charset=utf-8',
        body: page('ペアリング', '<p>LAN の IP アドレスが見つかりません。Wi-Fi に接続してから再読み込みしてください。</p>'),
      };
    }
    const lanUrl = new URL(this.options.lanUrl()!);
    const svg = await QRCode.toString(url, { type: 'svg', errorCorrectionLevel: 'M', margin: 1 });
    const candidates = this.addresses();
    const others = candidates.filter((a) => a !== lanUrl.hostname);
    const list = candidates.length > 1
      ? `<p class="small">LAN アドレス候補: <span class="mono">${candidates.map(esc).join(' / ')}</span>${
        others.length > 0 ? '<br>QR が繋がらない場合は、別の候補のアドレスを手入力してください。' : ''}</p>`
      : `<p class="small">LAN アドレス: <span class="mono">${esc(candidates[0] ?? lanUrl.hostname)}</span></p>`;
    const expiry = `<p class="small">有効期限: <span class="mono">${esc(new Date(expiresAt).toISOString())}</span></p>`;
    return {
      status: 200,
      type: 'text/html; charset=utf-8',
      body: page('FRELOCATOR とペアリング', `
        <p>スマホの FRELOCATOR で「設定 › PC と同期 › PC とペアリング」を開き、この QR を読み取ってください。5 分で無効になります。</p>
        <div class="qr">${svg}</div>
        <p class="mono">コード: <b>${esc(code)}</b></p>
        <p class="mono small">URL: ${esc(url)}</p>
        ${list}
        <p class="small">ポート: <span class="mono">${esc(lanUrl.port)}</span></p>
        <p class="small">証明書フィンガープリント（SHA-256）: <span class="mono">${esc(this.config.fingerprint)}</span></p>
        ${expiry}`),
    };
  }

  private async framesJson(): Promise<Reply> {
    const doc = await this.store.read();
    let frames: string[];
    try {
      frames = encodeFrames(doc, { maxFrames: this.options.maxFrames ?? QR_MAX_FRAMES });
    } catch (error) {
      return jsonError(413, 'too_many_frames', String((error as Error).message ?? error));
    }
    // Every frame carries the document's content hash, so an unchanged document
    // means the rendered SVGs are still valid — and rendering them is the slow part.
    const hash = frames[0].split(':')[1];
    if (this.frameCache?.hash !== hash) {
      const svgs = await Promise.all(
        frames.map((f) => QRCode.toString(f, { type: 'svg', errorCorrectionLevel: 'M', margin: 1 })),
      );
      this.frameCache = {
        hash,
        body: JSON.stringify({ total: frames.length, warn: frames.length > QR_WARN_FRAMES, svgs }),
      };
    }
    return { status: 200, type: 'application/json', body: this.frameCache.body };
  }

  private qrPageHtml(): Reply {
    return {
      status: 200,
      type: 'text/html; charset=utf-8',
      body: page('QR でスマホに送る', `
        <p>スマホの「設定 › PC と同期 › QR で受け取る」でカメラをこの画面に向け続けてください。コマは繰り返し表示されます。</p>
        <div class="qr" id="frame"></div>
        <p class="mono" id="status">読み込み中…</p>
        <p><button id="reload" type="button">再読み込み</button></p>
        <label>表示間隔 <input id="interval" type="range" min="200" max="1000" step="50" value="400"> <span id="ms">400</span> ms</label>
        <script>
          const status = document.getElementById('status'); const frame = document.getElementById('frame');
          const slider = document.getElementById('interval'); const ms = document.getElementById('ms');
          const reload = document.getElementById('reload');
          slider.oninput = () => { ms.textContent = slider.value; };
          let run = 0;
          const load = () => {
            const mine = ++run;
            frame.innerHTML = ''; status.textContent = '読み込み中…';
            // Relative on purpose: this page lives under a random secret prefix.
            fetch('./qr/frames.json')
              .then(async (r) => {
                let j = null;
                try { j = await r.json(); } catch (e) { j = null; }
                if (!r.ok) throw new Error(j && j.error ? j.error.message : 'HTTP ' + r.status);
                return j;
              })
              .then(({ total, svgs, warn }) => {
                let i = 0;
                if (warn) status.textContent = 'コマ数が多いため時間がかかります。可能なら LAN 同期を使ってください。';
                const tick = () => {
                  if (mine !== run) return;
                  frame.innerHTML = svgs[i];
                  status.textContent = 'コマ ' + (i + 1) + ' / ' + total + (warn ? '（多い）' : '');
                  i = (i + 1) % total;
                  setTimeout(tick, Number(slider.value));
                };
                tick();
              })
              .catch((e) => { if (mine === run) status.textContent = 'エラー: ' + e.message; });
          };
          reload.onclick = load;
          load();
        </script>`),
    };
  }
}

function page(title: string, body: string): string {
  return `<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>${esc(title)}</title>
  <style>body{font-family:-apple-system,"Hiragino Sans",sans-serif;max-width:640px;margin:32px auto;padding:0 16px;color:#1b2733}.qr svg{width:min(90vw,480px);height:auto}.mono{font-family:Menlo,monospace}.small{font-size:12px;color:#5c6672}</style>
  </head><body><h1>${esc(title)}</h1>${body}</body></html>`;
}
