import { createHash } from 'node:crypto';
import { z } from 'zod';
import { Hlc } from './hlc.js';

export const SCHEMA_VERSION = 2;

export const META_KEY_LIST = ['clock', 'updatedAt', 'deletedAt', 'migrated'] as const;

export const EPOCH_ISO = '1970-01-01T00:00:00.000Z';

export interface SyncMetaJson {
  clock: string;
  updatedAt: string;
  deletedAt: string | null;
  migrated: boolean;
}

/** Any entity: its own fields plus meta. Tombstones carry only id + meta. */
export type Entity = { id: string } & SyncMetaJson & Record<string, unknown>;

export interface TaskMasterJson {
  tasks: Entity[];
  mustDoCategories: Entity[];
  wantToDoCategories: Entity[];
  settings: { shareCategories: boolean } & SyncMetaJson;
}

export interface DailyPlanJson {
  plans: Entity[];
  slots: Entity[];
  assignments: Entity[];
}

export interface SyncDocumentJson {
  version: number;
  exportedAt: string;
  deviceId: string;
  lastSyncAt?: string | null;
  purgedBefore?: string | null;
  taskMaster: TaskMasterJson;
  dailyPlan: DailyPlanJson;
  /**
   * Conflict records (Plan 3b). Optional and omitted when empty, so a document
   * written by a Plan 2b client — and one this hub writes with nothing to
   * record — stay byte-identical to what they were before this field existed.
   */
  conflicts?: ConflictJson[];
}

export interface ConflictSideJson {
  side: 'hub' | 'device';
  deviceId: string;
  clock: string;
  updatedAt: string;
  /** The whole record as it stood on that side; a tombstone is `{id, clock, updatedAt, deletedAt}`. */
  snapshot: { id: string } & Record<string, unknown>;
}

export type ConflictResolution = 'hub' | 'device' | 'current' | 'superseded';

export interface ConflictJson extends SyncMetaJson {
  id: string;
  entityType: string;
  entityId: string;
  detectedAt: string;
  detectedBy: string;
  winner: ConflictSideJson;
  loser: ConflictSideJson;
  resolution: ConflictResolution | string | null;
  resolvedAt: string | null;
  resolvedBy: string | null;
}

/**
 * `cf-<sha256(entityId \n winnerClock \n loserClock)[0..16]>`.
 *
 * Derived from content and never from time, so Dart and TypeScript detecting
 * the same conflict independently produce the same id, re-detection is
 * idempotent, and the shared fixtures can pin an exact expected id.
 */
export function conflictId(entityId: string, winnerClock: string, loserClock: string): string {
  return `cf-${createHash('sha256')
    .update(`${entityId}\n${winnerClock}\n${loserClock}`, 'utf8')
    .digest('hex')
    .slice(0, 16)}`;
}

const conflictSideSchema = z.object({
  side: z.string(),
  deviceId: z.string(),
  clock: z.string(),
  updatedAt: z.string(),
  snapshot: z.object({ id: z.string() }).passthrough(),
}).passthrough();

export const conflictSchema = z.object({
  id: z.string(),
  // A string, not an enum: a newer app may record a type this build cannot draw,
  // and dropping it would delete the other side's record on the round trip.
  entityType: z.string(),
  entityId: z.string(),
  detectedAt: z.string(),
  detectedBy: z.string().optional(),
  winner: conflictSideSchema,
  loser: conflictSideSchema,
  resolution: z.string().nullish(),
  resolvedAt: z.string().nullish(),
  resolvedBy: z.string().nullish(),
  clock: z.string(),
  updatedAt: z.string(),
  deletedAt: z.string().nullish(),
  migrated: z.boolean().optional(),
}).passthrough();

export const TASK_KINDS = ['must_do', 'want_to_do'] as const;
export type TaskKind = (typeof TASK_KINDS)[number];

/** Entity field names per model, mirroring each Dart model's `jsonKeys`. */
export const ENTITY_KEYS = {
  task: ['id', 'title', 'kind', 'priority', 'createdAt', 'memo', 'categoryId', 'estimatedMinutes'],
  category: ['id', 'name'],
  plan: ['id', 'date', 'createdAt'],
  slot: ['id', 'dailyPlanId', 'startAt', 'endAt', 'label'],
  assignment: [
    'id', 'dailyPlanId', 'slotId', 'taskId', 'taskTitle', 'taskKind',
    'startAt', 'endAt', 'sortOrder', 'categoryId', 'categoryName', 'memo',
  ],
  settings: ['shareCategories'],
  // Must stay identical to `ConflictRecord.jsonKeys` in
  // lib/services/sync/conflict_record.dart: the set decides what `contentHash`
  // sees, and a mismatch would split the hash between the two languages.
  conflict: [
    'id', 'entityType', 'entityId', 'detectedAt', 'detectedBy',
    'winner', 'loser', 'resolution', 'resolvedAt', 'resolvedBy',
  ],
  tombstone: ['id'],
} as const satisfies Record<string, readonly string[]>;

export type EntityKind = keyof typeof ENTITY_KEYS;

export function isDeleted(e: Record<string, unknown>): boolean {
  return typeof e.deletedAt === 'string';
}

/** Normalized meta, mirroring SyncMeta.fromJson in lib/core/sync_meta.dart. */
export interface SyncMeta {
  clock: Hlc;
  updatedAt: string;
  deletedAt: string | null;
  migrated: boolean;
  extra: Record<string, unknown>;
}

/** Any parsable timestamp string to UTC ISO-8601 with `Z`; null when it is not one. */
export function toIsoUtc(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const ms = Date.parse(value);
  return Number.isNaN(ms) ? null : new Date(ms).toISOString();
}

/**
 * Reads meta out of a raw entity map the same way Dart does: a record with no
 * String `clock` predates v2, so it is given the deterministic migrated
 * sentinel and no extras.
 */
export function readMeta(json: Record<string, unknown>, knownKeys: readonly string[]): SyncMeta {
  const rawClock = json.clock;
  const hasClock = typeof rawClock === 'string';
  const clock = hasClock ? Hlc.tryParse(rawClock) ?? Hlc.migrated : Hlc.migrated;
  const updatedAt = hasClock ? toIsoUtc(json.updatedAt) ?? EPOCH_ISO : EPOCH_ISO;
  const deletedAt = toIsoUtc(json.deletedAt);
  const migrated = !hasClock || (typeof json.migrated === 'boolean' ? json.migrated : false);
  const extra: Record<string, unknown> = {};
  if (hasClock) {
    for (const [k, v] of Object.entries(json)) {
      if (!knownKeys.includes(k) && !(META_KEY_LIST as readonly string[]).includes(k)) extra[k] = v;
    }
  }
  return { clock, updatedAt, deletedAt, migrated, extra };
}

/** Canonical serialization of meta — mirrors SyncMerger._metaKey in Dart. */
export function metaKey(meta: SyncMeta): string {
  const map: Record<string, unknown> = {
    ...meta.extra,
    clock: meta.clock.toString(),
    updatedAt: meta.updatedAt,
    deletedAt: meta.deletedAt,
    migrated: meta.migrated,
  };
  const keys = Object.keys(map).sort();
  return JSON.stringify(Object.fromEntries(keys.map((k) => [k, map[k]])));
}

export function emptyDocument(deviceId: string, now = new Date()): SyncDocumentJson {
  const migrated: SyncMetaJson = {
    clock: '0-0-migrated',
    updatedAt: EPOCH_ISO,
    deletedAt: null,
    migrated: true,
  };
  const cat = (id: string, name: string): Entity => ({ id, name, ...migrated });
  return {
    version: SCHEMA_VERSION,
    exportedAt: now.toISOString(),
    deviceId,
    lastSyncAt: null,
    purgedBefore: null,
    taskMaster: {
      tasks: [],
      mustDoCategories: [
        cat('must-work', '仕事'),
        cat('must-housework', '家事'),
        cat('must-admin', '雑務'),
      ],
      wantToDoCategories: [
        cat('want-hobby', '趣味'),
        cat('want-learning', '学習'),
        cat('want-health', '健康'),
      ],
      settings: { shareCategories: false, ...migrated },
    },
    dailyPlan: { plans: [], slots: [], assignments: [] },
  };
}
