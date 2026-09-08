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
}

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

function toIsoUtc(value: unknown): string | null {
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
