import { createHash } from 'node:crypto';
import { stat } from 'node:fs/promises';
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

  /** Last computed revision, keyed on the data.json stat it was computed from. */
  private cachedRevision: { key: string; revision: string; modifiedAt: string | null } | null = null;

  /** `sha256(data.json)` prefix — the browser polls this instead of the whole document. */
  private revisionOf(doc: SyncDocumentJson): string {
    return createHash('sha256').update(JSON.stringify(doc), 'utf8').digest('hex').slice(0, 16);
  }

  /** `{mtimeMs, size}` of data.json, or `absent` while it has never been written. */
  private async statKey(): Promise<string> {
    try {
      const info = await stat(this.engine.store.filePath);
      return `${info.mtimeMs}:${info.size}`;
    } catch {
      return 'absent';
    }
  }

  /**
   * The browser polls this on a timer. Taking the data lock and re-hashing the
   * whole document every few seconds would contend with the phone's syncs for
   * no new information, so the answer is cached against `data.json`'s
   * `{mtimeMs, size}` and only recomputed when that stat moves. `stat` itself is
   * lock-free, and the store publishes by rename, so a torn read is impossible.
   */
  private async revision(): Promise<{ revision: string; modifiedAt: string | null }> {
    const before = await this.statKey();
    const cached = this.cachedRevision;
    if (cached && cached.key === before) return { revision: cached.revision, modifiedAt: cached.modifiedAt };
    const document = await this.engine.store.read();
    const revision = this.revisionOf(document);
    const modifiedAt = (await this.engine.store.modifiedAt())?.toISOString() ?? null;
    // Only cache when the file did not move under the read: otherwise the entry
    // would claim a revision the current bytes never produced.
    const after = await this.statKey();
    this.cachedRevision = after === before ? { key: after, revision, modifiedAt } : null;
    return { revision, modifiedAt };
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
    if (method === 'GET' && route === 'revision') return json(200, await this.revision());
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
        // No bookkeeping: `web-…` is deliberately not a paired device, so the
        // per-device `lastSyncAt` write has nothing to write to. `recordWebClient`
        // below is the browser's own, display-only equivalent.
        const result = await this.engine.sync(deviceId, body as SyncDocumentJson, engineMode, { bookkeep: false });
        // A write within the same millisecond and to the same length would leave
        // the stat unchanged; dropping the entry here removes that window for
        // the one writer we know about.
        this.cachedRevision = null;
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
