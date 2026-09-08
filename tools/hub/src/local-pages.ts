import { createServer, type Server } from 'node:http';
import QRCode from 'qrcode';
import type { HubConfig } from './config.js';
import { lanAddresses } from './net.js';
import { encodeFrames } from './qr-codec.js';
import type { FileStore } from './store.js';

export interface LocalPagesOptions {
  port: number;
  /** `https://<host>:<port>` of the LAN server, or null when the host has no LAN address. */
  lanUrl: () => string | null;
  /** Every reachable LAN IPv4, best candidate first; the phone may need one the URL does not carry. */
  lanAddresses?: () => string[];
}

/** Frames above this are still served, but the page warns that LAN sync is the better route. */
const QR_WARN_FRAMES = 80;
/** Hard ceiling for a data QR: past this the animation takes longer than a re-pair. */
const QR_MAX_FRAMES = 200;

const esc = (s: string): string =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');

interface Reply { status: number; type: string; body: string }

/**
 * Loopback-only pages. Never bind this to a LAN interface: `/pair` prints the
 * pairing code in clear text, and anyone who can read it can pair a device.
 */
export class LocalPages {
  private server: Server | null = null;
  readonly host = '127.0.0.1';
  port = 0;

  constructor(
    private readonly config: HubConfig,
    private readonly store: FileStore,
    private readonly options: LocalPagesOptions,
  ) {}

  get listening(): boolean { return this.server !== null; }

  private addresses(): string[] {
    return (this.options.lanAddresses ?? (() => lanAddresses()))();
  }

  async start(): Promise<void> {
    const server = createServer((req, res) => {
      void this.handle(req.url ?? '/')
        .then(({ status, type, body }) => { res.writeHead(status, { 'content-type': type }); res.end(body); })
        .catch((error: unknown) => {
          // Diagnostics go to stderr: stdout carries the MCP stdio protocol.
          process.stderr.write(`[local-pages] request failed: ${String((error as Error).stack ?? error)}\n`);
          res.writeHead(500, { 'content-type': 'text/plain; charset=utf-8' });
          res.end('internal error');
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
    await new Promise<void>((resolve) => (server ? server.close(() => resolve()) : resolve()));
  }

  pairingUrl(code: string): string | null {
    const lan = this.options.lanUrl();
    if (!lan) return null;
    const u = new URL(lan);
    return `frelocator://pair?host=${u.hostname}&port=${u.port}&fp=${this.config.fingerprint}&code=${code}`;
  }

  private async handle(path: string): Promise<Reply> {
    // Query strings and fragments are ignored: these pages take no input.
    const route = path.split('?')[0].split('#')[0];
    if (route === '/' || route === '/pair') return this.pairPage();
    if (route === '/qr/frames.json') return this.framesJson();
    if (route === '/qr') return this.qrPage();
    return { status: 404, type: 'text/plain; charset=utf-8', body: 'not found' };
  }

  private async pairPage(): Promise<Reply> {
    // Reuse a code that is still valid: reloading this page (or opening it in a
    // second tab) must not silently invalidate the QR already on screen.
    const existing = this.config.pairingCode();
    const code = existing ? existing.code : await this.config.issuePairingCode();
    const expiresAt = existing ? existing.expiresAt : this.config.pairingCode()?.expiresAt ?? null;
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
    const expiry = expiresAt === null ? '' : `<p class="small">有効期限: <span class="mono">${esc(new Date(expiresAt).toISOString())}</span></p>`;
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
      frames = encodeFrames(doc, { maxFrames: QR_MAX_FRAMES });
    } catch (error) {
      return {
        status: 413,
        type: 'application/json',
        body: JSON.stringify({ error: { code: 'too_many_frames', message: String((error as Error).message ?? error) } }),
      };
    }
    const svgs = await Promise.all(frames.map((f) => QRCode.toString(f, { type: 'svg', errorCorrectionLevel: 'M', margin: 1 })));
    return {
      status: 200,
      type: 'application/json',
      body: JSON.stringify({ total: frames.length, warn: frames.length > QR_WARN_FRAMES, svgs }),
    };
  }

  private qrPage(): Reply {
    return {
      status: 200,
      type: 'text/html; charset=utf-8',
      body: page('QR でスマホに送る', `
        <p>スマホの「設定 › PC と同期 › QR で受け取る」でカメラをこの画面に向け続けてください。コマは繰り返し表示されます。</p>
        <div class="qr" id="frame"></div>
        <p class="mono" id="status">読み込み中…</p>
        <label>表示間隔 <input id="interval" type="range" min="200" max="1000" step="50" value="400"> <span id="ms">400</span> ms</label>
        <script>
          const status = document.getElementById('status'); const frame = document.getElementById('frame');
          const slider = document.getElementById('interval'); const ms = document.getElementById('ms');
          slider.oninput = () => { ms.textContent = slider.value; };
          fetch('/qr/frames.json')
            .then(async (r) => { const j = await r.json(); if (!r.ok) throw new Error(j.error ? j.error.message : r.status); return j; })
            .then(({ total, svgs, warn }) => {
              let i = 0;
              if (warn) status.textContent = 'コマ数が多いため時間がかかります。可能なら LAN 同期を使ってください。';
              const tick = () => {
                frame.innerHTML = svgs[i];
                status.textContent = 'コマ ' + (i + 1) + ' / ' + total + (warn ? '（多い）' : '');
                i = (i + 1) % total;
                setTimeout(tick, Number(slider.value));
              };
              tick();
            })
            .catch((e) => { status.textContent = 'エラー: ' + e.message; });
        </script>`),
    };
  }
}

function page(title: string, body: string): string {
  return `<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>${esc(title)}</title>
  <style>body{font-family:-apple-system,"Hiragino Sans",sans-serif;max-width:640px;margin:32px auto;padding:0 16px;color:#1b2733}.qr svg{width:min(90vw,480px);height:auto}.mono{font-family:Menlo,monospace}.small{font-size:12px;color:#5c6672}</style>
  </head><body><h1>${esc(title)}</h1>${body}</body></html>`;
}
