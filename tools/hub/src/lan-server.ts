import { createServer, type Server } from 'node:https';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { z } from 'zod';
import type { HubConfig } from './config.js';
import { SCHEMA_VERSION, type SyncDocumentJson } from './model.js';
import { MdnsAdvertiser, lanAddress } from './net.js';
import { SyncRejected, type SyncEngine, type SyncMode } from './sync-engine.js';

export interface LanServerOptions { port: number; host: string; advertise: boolean; hubDeviceId?: string }

/** Bodies above this are refused with 413 rather than buffered. */
export const MAX_BODY = 20 * 1024 * 1024;

// `deviceName` is the field name Plan 2b's client sends; `name` is the shorter
// spelling used by the hub's own pages. Either is accepted, `name` wins.
const pairSchema = z.object({
  code: z.string().min(1),
  deviceId: z.string().min(1),
  name: z.string().max(80).optional(),
  deviceName: z.string().max(80).optional(),
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
    this.server = createServer({ cert: this.config.certPem, key: this.config.keyPem }, (req, res) => {
      void this.handle(req, res).catch((error) => fail(res, error));
    });
    await new Promise<void>((resolve, reject) => {
      this.server!.once('error', reject);
      this.server!.listen(this.options.port, this.options.host, () => resolve());
    });
    this.port = (this.server.address() as { port: number }).port;
    if (this.options.advertise) this.mdns.start(this.port, this.hubDeviceId);
  }

  async stop(): Promise<void> {
    await this.mdns.stop();
    await new Promise<void>((resolve) => (this.server ? this.server.close(() => resolve()) : resolve()));
    this.server = null;
  }

  private async handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = new URL(req.url ?? '/', 'https://local');
    if (req.method === 'POST' && url.pathname === '/pair') return this.pair(req, res);

    const token = (req.headers.authorization ?? '').replace(/^Bearer\s+/i, '');
    const device = token ? this.config.deviceForToken(token) : undefined;
    if (!device) return send(res, 401, { error: { code: 'unauthorized', message: 'missing or invalid token' } });

    if (req.method === 'GET' && url.pathname === '/health') {
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
    const parsed = pairSchema.safeParse(await readJson(req));
    if (!parsed.success) return send(res, 400, { error: { code: 'bad_request', message: parsed.error.message } });
    const name = parsed.data.name ?? parsed.data.deviceName ?? '';
    // Wrong / expired / over-budget codes arrive as SyncRejected(403). Anything else
    // (a failed hub.json write, say) is not the client's fault, so it stays a 500.
    const token = await this.config.redeemPairingCode(parsed.data.code, parsed.data.deviceId, name);
    return send(res, 200, { token, hubDeviceId: this.hubDeviceId, fingerprint: this.config.fingerprint });
  }
}

function fail(res: ServerResponse, error: unknown): void {
  if (res.headersSent) { res.end(); return; }
  if (error instanceof SyncRejected) return send(res, error.status, { error: { code: error.code, message: error.message } });
  if (error instanceof SyntaxError) return send(res, 400, { error: { code: 'bad_request', message: 'body is not valid JSON' } });
  return send(res, 500, { error: { code: 'internal', message: String((error as Error)?.message ?? error) } });
}

function send(res: ServerResponse, status: number, body: unknown): void {
  const text = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text) });
  res.end(text);
}

async function readJson(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    if (size > MAX_BODY) throw new SyncRejected(413, 'payload_too_large', `request body exceeds ${MAX_BODY} bytes`);
    chunks.push(chunk as Buffer);
  }
  const text = Buffer.concat(chunks).toString('utf8');
  return text ? JSON.parse(text) : {};
}
