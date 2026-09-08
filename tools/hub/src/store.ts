import { copyFile, mkdir, readFile, rename, stat, writeFile, unlink } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import lockfile from 'proper-lockfile';
import { emptyDocument, EPOCH_ISO, SCHEMA_VERSION, type SyncDocumentJson } from './model.js';

export class UnsupportedSchemaError extends Error {
  constructor(public readonly version: number) {
    super(`Unsupported schema version ${version} (hub supports up to ${SCHEMA_VERSION})`);
    this.name = 'UnsupportedSchemaError';
  }
}

/**
 * Lock options chosen to interoperate with the Dart `FileBackedStore`:
 * `proper-lockfile` creates the sentinel directory `data.lock.lock`, refreshes
 * its mtime every 2s and treats it as stale after 10s — exactly the protocol
 * lib/services/storage/file_backed_store.dart implements natively.
 */
const LOCK_OPTIONS = {
  stale: 10_000,
  update: 2_000,
  retries: { retries: 200, minTimeout: 50, maxTimeout: 200 },
} as const;

/** Owns data.json. Every read/update runs under the shared advisory lock. */
export class FileStore {
  lastWarning: string | null = null;
  private chain: Promise<unknown> = Promise.resolve();

  constructor(
    public readonly directory: string,
    public readonly deviceId: string,
  ) {}

  static defaultDirectory(): string {
    return join(process.env.HOME ?? '.', 'Library', 'Application Support', 'FRELOCATOR');
  }

  get filePath(): string {
    return join(this.directory, 'data.json');
  }

  private get lockPath(): string {
    return join(this.directory, 'data.lock');
  }

  /** Serializes calls in-process and takes the cross-process lock. */
  private async withLock<T>(body: () => Promise<T>): Promise<T> {
    const run = async () => {
      await mkdir(this.directory, { recursive: true });
      if (!existsSync(this.lockPath)) {
        try {
          await writeFile(this.lockPath, '');
        } catch {
          // Best-effort: proper-lockfile only needs the target path to exist.
        }
      }
      const release = await lockfile.lock(this.lockPath, LOCK_OPTIONS);
      try {
        return await body();
      } finally {
        await release();
      }
    };
    const next = this.chain.then(run, run);
    this.chain = next.catch(() => undefined);
    return next;
  }

  private async readLocked(): Promise<SyncDocumentJson> {
    if (!existsSync(this.filePath)) return emptyDocument(this.deviceId);
    const text = await readFile(this.filePath, 'utf8');
    if (text.trim().length === 0) {
      // Another process may be mid-write (tmp not yet renamed into place);
      // treat as "no data yet" without quarantining anything.
      return emptyDocument(this.deviceId);
    }
    let json: unknown;
    try {
      json = JSON.parse(text);
      if (json === null || typeof json !== 'object' || Array.isArray(json)) {
        throw new SyntaxError('root is not an object');
      }
    } catch (error) {
      const quarantine = `${this.filePath}.broken-${Date.now()}`;
      await rename(this.filePath, quarantine);
      this.lastWarning = `data.json was corrupt (${String(error)}); moved to ${quarantine} (broken file kept) and started empty.`;
      return emptyDocument(this.deviceId);
    }
    return parseDocument(json as Record<string, unknown>, this.deviceId);
  }

  private async writeLocked(doc: SyncDocumentJson): Promise<void> {
    const tmp = `${this.filePath}.tmp`;
    try {
      await writeFile(tmp, JSON.stringify(doc, null, 2), 'utf8');
      if (existsSync(this.filePath)) {
        const bakTmp = `${this.filePath}.bak.tmp`;
        await copyFile(this.filePath, bakTmp);
        await rename(bakTmp, `${this.filePath}.bak`);
      }
      await rename(tmp, this.filePath);
    } catch (error) {
      if (existsSync(tmp)) {
        try {
          await unlink(tmp);
        } catch {
          // best-effort cleanup
        }
      }
      throw error;
    }
  }

  read(): Promise<SyncDocumentJson> {
    return this.withLock(() => this.readLocked());
  }

  update(mutate: (doc: SyncDocumentJson) => SyncDocumentJson): Promise<SyncDocumentJson> {
    return this.withLock(async () => {
      const current = await this.readLocked();
      const next = mutate(structuredClone(current));
      next.version = SCHEMA_VERSION;
      next.exportedAt = new Date().toISOString();
      next.deviceId = this.deviceId;
      await this.writeLocked(next);
      return next;
    });
  }

  undoLastWrite(): Promise<boolean> {
    return this.withLock(async () => {
      const bak = `${this.filePath}.bak`;
      if (!existsSync(bak)) return false;
      await copyFile(bak, `${this.filePath}.tmp`);
      await rename(`${this.filePath}.tmp`, this.filePath);
      return true;
    });
  }

  async modifiedAt(): Promise<Date | null> {
    return existsSync(this.filePath) ? (await stat(this.filePath)).mtime : null;
  }
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/**
 * Same strictness as `SyncDocument.fromJson(strict: true)` in Dart: a
 * structurally invalid document is an error, never silently emptied.
 */
function parseDocument(json: Record<string, unknown>, deviceId: string): SyncDocumentJson {
  const rawVersion = json.version;
  if (!Number.isInteger(rawVersion)) {
    throw new Error(`version must be an int, got ${JSON.stringify(rawVersion) ?? 'undefined'}`);
  }
  const version = rawVersion as number;
  if (version > SCHEMA_VERSION) throw new UnsupportedSchemaError(version);
  const isV1 = version < SCHEMA_VERSION;

  const section = (key: string): Record<string, unknown> => {
    const value = json[key];
    if (!isPlainObject(value)) {
      throw new Error(`${key} must be a JSON object, got ${JSON.stringify(value) ?? 'undefined'}`);
    }
    return value;
  };
  const taskJson = section(isV1 ? 'task_master' : 'taskMaster');
  const planJson = section(isV1 ? 'daily_plan' : 'dailyPlan');

  const exportedRaw = json[isV1 ? 'exported_at' : 'exportedAt'];
  const exportedAt = typeof exportedRaw === 'string' && !Number.isNaN(Date.parse(exportedRaw))
    ? new Date(exportedRaw).toISOString()
    : null;
  if (exportedAt === null) {
    throw new Error(`exportedAt missing or unparsable, got ${JSON.stringify(exportedRaw) ?? 'undefined'}`);
  }

  const rawDeviceId = json.deviceId;
  if (!isV1 && typeof rawDeviceId !== 'string') {
    throw new Error(`deviceId must be a String, got ${JSON.stringify(rawDeviceId) ?? 'undefined'}`);
  }

  if (isV1) return upgradeV1(json, taskJson, planJson, deviceId, exportedAt);

  return {
    ...(json as unknown as SyncDocumentJson),
    version: SCHEMA_VERSION,
    exportedAt,
    deviceId: rawDeviceId as string,
    lastSyncAt: typeof json.lastSyncAt === 'string' ? json.lastSyncAt : null,
    purgedBefore: typeof json.purgedBefore === 'string' ? json.purgedBefore : null,
    taskMaster: taskJson as unknown as SyncDocumentJson['taskMaster'],
    dailyPlan: planJson as unknown as SyncDocumentJson['dailyPlan'],
  };
}

/**
 * Minimal v1 → v2: rename envelope keys and fill entity meta with the
 * deterministic migrated sentinel. `{...migrated, ...e}` keeps the v1 record's
 * own `updatedAt` while forcing the migrated clock — the same rule as Dart.
 */
function upgradeV1(
  doc: Record<string, unknown>,
  tm: Record<string, unknown>,
  dp: Record<string, unknown>,
  deviceId: string,
  exportedAt: string,
): SyncDocumentJson {
  const base = emptyDocument(deviceId);
  const migrated = { clock: '0-0-migrated', updatedAt: EPOCH_ISO, deletedAt: null, migrated: true };
  const fill = (list: unknown) =>
    (Array.isArray(list) ? list : []).map((e) => ({ ...migrated, ...(e as object) }));
  const rawShare = tm.shareCategories ?? doc.shareCategories;
  return {
    ...base,
    exportedAt,
    // v1 carried no device id, so it is attributed to the migrated device.
    deviceId: 'migrated',
    taskMaster: {
      tasks: fill(tm.tasks) as SyncDocumentJson['taskMaster']['tasks'],
      mustDoCategories: fill(tm.mustDoCategories) as SyncDocumentJson['taskMaster']['tasks'],
      wantToDoCategories: fill(tm.wantToDoCategories) as SyncDocumentJson['taskMaster']['tasks'],
      settings: { shareCategories: rawShare === true, ...migrated },
    },
    dailyPlan: {
      plans: fill(dp.plans) as SyncDocumentJson['dailyPlan']['plans'],
      slots: fill(dp.slots) as SyncDocumentJson['dailyPlan']['plans'],
      assignments: fill(dp.assignments) as SyncDocumentJson['dailyPlan']['plans'],
    },
  };
}
