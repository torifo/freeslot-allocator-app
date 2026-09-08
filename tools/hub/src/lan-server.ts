import { createServer, type Server } from 'node:https';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { z } from 'zod';
import type { HubConfig } from './config.js';
import { SCHEMA_VERSION, type SyncDocumentJson } from './model.js';
import { MdnsAdvertiser, lanAddress } from './net.js';
import { MAX_BODY, MAX_PAIR_BODY } from './limits.js';
import { SyncRejected, type SyncEngine, type SyncMode } from './sync-engine.js';

export { MAX_BODY, MAX_PAIR_BODY };

export interface LanServerOptions { port: number; host: string; advertise: boolean; hubDeviceId?: string }


/** Diagnostics go to stderr: stdout carries the MCP stdio protocol. */
function logError(context: string, error: unknown): void {
  const detail = error instanceof Error ? (error.stack ?? error.message) : String(error);
  process.stderr.write(`[lan-server] ${context}: ${detail}\n`);
}

// `deviceName` is the field name Plan 2b's client sends; `name` is the shorter
// spelling used by the hub's own pages. Either is accepted, `name` wins.
const pairSchema = z.object({
  code: z.string().min(1).max(64),
  deviceId: z.string().min(1).max(128),
  name: z.string().max(128).optional(),
  deviceName: z.string().max(128).optional(),
});
const syncQuery = z.enum(['merge', 'take_hub', 'take_phone']);

/** HTTPS endpoint for phones on the LAN: `/pair`, `/sync`, `/health`. */
export class LanServer {
  private server: Server | null = null;
  private readonly mdns = new MdnsAdvertiser();
  port = 0;

  constructor(
    private readonly config: HubConfig,
    private readonly engine: SyncEngine,
    private readonly options: LanServerOptions,
  ) {}

  get hubDeviceId(): string { return this.options.hubDeviceId ?? this.engine.store.deviceId; }

  get address(): string | null { return this.options.host === '0.0.0.0' ? lanAddress() : this.options.host; }

  async start(): Promise<void> {
    const server = createServer({
      cert: this.config.certPem,
      key: this.config.keyPem,
      minVersion: 'TLSv1.2',
      honorCipherOrder: true,
    }, (req, res) => {
      void this.handle(req, res).catch((error) => fail(req, res, error));
    });
    // A garbled request line never reaches `handle`, so answer it in the same JSON shape.
    server.on('clientError', (error: NodeJS.ErrnoException, socket) => {
      logError('client error', error);
      const writable = socket as { writable?: boolean; end: (data?: string) => void; destroy: () => void };
      if (!writable.writable) return writable.destroy();
      writable.end('HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{"error":{"code":"bad_request","message":"malformed request"}}');
    });
    this.server = server;
    try {
      await new Promise<void>((resolve, reject) => {
        const onError = (error: unknown) => reject(error);
        server.once('error', onError);
        server.listen(this.options.port, this.options.host, () => { server.removeListener('error', onError); resolve(); });
      });
    } catch (error) {
      this.server = null;
      throw error;
    }
    // Post-listen failures (an EPIPE on a dropped socket, say) must not crash the hub.
    server.on('error', (error) => logError('server error', error));
    this.port = (server.address() as { port: number }).port;
    if (this.options.advertise) this.mdns.start(this.port, this.hubDeviceId);
  }

  async stop(): Promise<void> {
    await this.mdns.stop();
    const server = this.server;
    this.server = null;
    if (!server) return;
    // `close()` alone waits out every idle keep-alive socket, so a phone that
    // keeps its connection open would stall hub shutdown.
    const closed = new Promise<void>((resolve) => server.close(() => resolve()));
    server.closeIdleConnections();
    server.closeAllConnections();
    await closed;
  }

  // No CORS headers, by design: the hub's self-signed certificate already stops
  // browsers (and DNS-rebinding attempts) from reaching these routes, and every
  // real client is the native app. Do not add `Access-Control-Allow-Origin`.
  private async handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = new URL(req.url ?? '/', 'https://local');
    if (req.method === 'POST' && url.pathname === '/pair') return this.pair(req, res);

    const token = (req.headers.authorization ?? '').replace(/^Bearer\s+/i, '');
    const device = token ? this.config.deviceForToken(token) : undefined;
    if (!device) return send(res, 401, { error: { code: 'unauthorized', message: 'missing or invalid token' } });

    if ((req.method === 'GET' || req.method === 'HEAD') && url.pathname === '/health') {
      return send(res, 200, {
        ok: true,
        hubDeviceId: this.hubDeviceId,
        fingerprint: this.config.fingerprint,
        version: SCHEMA_VERSION,
        schema: SCHEMA_VERSION,
        serverTime: new Date().toISOString(),
      });
    }
    if (req.method === 'GET' && url.pathname === '/sync') {
      const document = await this.engine.store.read();
      return send(res, 200, { document, hubDeviceId: this.hubDeviceId });
    }
    if (req.method === 'POST' && url.pathname === '/sync') {
      const mode = syncQuery.safeParse(url.searchParams.get('mode') ?? 'merge');
      if (!mode.success) return send(res, 400, { error: { code: 'bad_mode', message: 'mode must be merge|take_hub|take_phone' } });
      const body = await readJson(req);
      const result = await this.engine.sync(device.deviceId, body as SyncDocumentJson, mode.data as SyncMode);
      return send(res, 200, result);
    }
    return send(res, 404, { error: { code: 'not_found', message: `${req.method} ${url.pathname}` } });
  }

  private async pair(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const parsed = pairSchema.safeParse(await readJson(req, MAX_PAIR_BODY));
    if (!parsed.success) return send(res, 400, { error: { code: 'bad_request', message: parsed.error.message } });
    const name = parsed.data.name ?? parsed.data.deviceName ?? '';
    // Wrong / expired / over-budget codes arrive as SyncRejected(403). Anything else
    // (a failed hub.json write, say) is not the client's fault, so it stays a 500.
    const token = await this.config.redeemPairingCode(parsed.data.code, parsed.data.deviceId, name);
    return send(res, 200, { token, hubDeviceId: this.hubDeviceId, fingerprint: this.config.fingerprint });
  }
}

function fail(req: IncomingMessage, res: ServerResponse, error: unknown): void {
  if (res.headersSent) { res.end(); return; }
  if (error instanceof SyncRejected) {
    // A 413 is decided before the body is drained, so the socket still holds
    // undelivered bytes; keeping it alive would desync the next request on it.
    const close = error.status === 413;
    send(res, error.status, { error: { code: error.code, message: error.message } }, close);
    if (close) req.destroy();
    return;
  }
  if (error instanceof SyntaxError) return send(res, 400, { error: { code: 'bad_request', message: 'body is not valid JSON' } });
  // Paths, PIDs and stack frames stay on stderr; the client only learns that it failed.
  logError('request failed', error);
  return send(res, 500, { error: { code: 'internal', message: 'internal error' } });
}

function send(res: ServerResponse, status: number, body: unknown, close = false): void {
  const text = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json',
    'content-length': Buffer.byteLength(text),
    ...(close ? { connection: 'close' } : {}),
  });
  res.end(text);
}

async function readJson(req: IncomingMessage, max = MAX_BODY): Promise<unknown> {
  const tooLarge = () => new SyncRejected(413, 'payload_too_large', `request body exceeds ${max} bytes`);
  const declared = Number(req.headers['content-length']);
  // Refuse on the announced length before a single byte is buffered.
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
