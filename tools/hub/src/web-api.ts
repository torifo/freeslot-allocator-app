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
        // A 413 is decided before the body is drained, so the socket still holds
        // undelivered bytes; keeping it alive would desync the next request on it.
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
