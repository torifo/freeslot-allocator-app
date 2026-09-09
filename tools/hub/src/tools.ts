import { readFile, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join, resolve as resolvePath, sep } from 'node:path';
import { z } from 'zod';
import type { DeviceRecord, HubConfig, WebClientRecord } from './config.js';
import { Hlc, HlcClock } from './hlc.js';
import { copyId, generateId } from './ids.js';
import { checkInvariants } from './invariants.js';
import { MAX_BODY } from './limits.js';
import { contentHash } from './hash.js';
import { isDeleted, isPcSide, TASK_KINDS, type ConflictJson, type ConflictSideJson, type Entity, type SyncDocumentJson } from './model.js';
import { FileStore } from './store.js';
import { SyncRejected, type SyncEngine, type SyncProgress, type SyncSummary } from './sync-engine.js';

/** What `sync_status` reports about the hub-served browser app (Plan 3a). */
export interface WebAppInfo {
  /** `http://127.0.0.1:<port>/<secret>/app/`, or null when there is nothing to serve. */
  url: string | null;
  built: boolean;
  gitRev: string | null;
  builtAt: string | null;
  /** True when BUILD_INFO.json names a different commit than the checkout's HEAD. */
  stale: boolean;
}

/** A BUILD_INFO.json value only counts when it is a string: the file sits in a directory the user can edit. */
const asString = (value: unknown): string | null => (typeof value === 'string' && value !== '' ? value : null);

/**
 * Folds the build stamp and the checkout's HEAD into what `sync_status` shows.
 *
 * `stale` is deliberately conservative: with no BUILD_INFO.json, no git, or an
 * unreadable field there is nothing to compare, and telling the user to rebuild
 * on a guess costs them a `flutter build web`. The revisions are compared by
 * prefix because BUILD_INFO.json may carry an abbreviated hash.
 */
export function webAppInfo(input: {
  built: boolean;
  url: string | null;
  build: Record<string, unknown> | null;
  headRev: string | null;
}): WebAppInfo {
  const gitRev = input.built ? asString(input.build?.gitRev) : null;
  const headRev = asString(input.headRev);
  const same = gitRev !== null && headRev !== null
    && (gitRev === headRev || headRev.startsWith(gitRev) || gitRev.startsWith(headRev));
  return {
    url: input.built ? input.url : null,
    built: input.built,
    gitRev,
    builtAt: input.built ? asString(input.build?.builtAt) : null,
    stale: gitRev !== null && headRev !== null && !same,
  };
}

/** What `sync_status` reports about the LAN listener. Never carries a device token. */
export interface LanInfo {
  listening: boolean;
  /** True when FRELOCATOR_LAN=off: the hub never tried to listen, this is not a failure. */
  disabled: boolean;
  url: string | null;
  addresses: string[];
  port: number | null;
  pairingPage: string | null;
  qrPage: string | null;
  webApp: WebAppInfo;
}

export interface HubToolsDeps {
  config: HubConfig;
  engine: SyncEngine;
  lan: () => LanInfo;
  /** Replaces the default `import_file` allowlist (store dir, ~/Downloads, FRELOCATOR_IMPORT_DIRS). */
  importDirs?: string[];
}

/** Expands a leading `~` and makes the path absolute; `import_file` compares only resolved paths. */
function resolveUserPath(input: string): string {
  const expanded = input === '~' || input.startsWith(`~${sep}`) || input.startsWith('~/')
    ? join(homedir(), input.slice(1))
    : input;
  return resolvePath(expanded);
}

function isInside(child: string, parent: string): boolean {
  return child === parent || child.startsWith(parent.endsWith(sep) ? parent : parent + sep);
}

export type DeviceStatus = Omit<DeviceRecord, 'token'> & { progress: SyncProgress | null };

export interface SyncStatus {
  dataFile: string;
  modifiedAt: string | null;
  warning: string | null;
  purgedBefore: string | null;
  lan: LanInfo | null;
  fingerprint: string | null;
  pairing: ReturnType<HubConfig['pairingState']>;
  devices: DeviceStatus[];
  /** Browsers that opened the hub-served app. Display only: they hold no local store, so they are not part of the purge cutoff. */
  webClients: WebClientRecord[];
  lastSync: SyncProgress | null;
  lanError: string | null;
  configError: string | null;
}

/** A user-facing failure: the request was rejected, nothing was written. */
export class ToolError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ToolError';
  }
}

const kindSchema = z.enum(TASK_KINDS);
const dateSchema = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'must be YYYY-MM-DD');
const taskFields = {
  title: z.string(),
  kind: kindSchema,
  priority: z.number().int().min(1).max(5).optional(),
  categoryId: z.string().optional(),
  estimatedMinutes: z.number().int().min(0).optional(),
  memo: z.string().optional(),
};
const taskPatchFields = {
  id: z.string(),
  title: z.string().optional(),
  kind: kindSchema.optional(),
  priority: z.number().int().min(1).max(5).optional(),
  categoryId: z.string().nullable().optional(),
  estimatedMinutes: z.number().int().min(0).optional(),
  memo: z.string().optional(),
};
/** Same four choices as Dart's `CategoryMergeStrategy`. */
const mergeStrategySchema = z.enum(['keepShorter', 'keepLonger', 'keepMustDo', 'keepWantToDo']);

export const schemas = {
  listTasks: z.object({
    kind: kindSchema.optional(),
    categoryId: z.string().optional(),
    query: z.string().optional(),
  }),
  addTask: z.object(taskFields),
  bulkAddTasks: z.object({ tasks: z.array(z.object(taskFields)).min(1).max(100) }),
  updateTask: z.object(taskPatchFields),
  deleteTask: z.object({ id: z.string() }),
  getTask: z.object({ id: z.string(), includeDeleted: z.boolean().optional() }),
  getEntity: z.object({ id: z.string(), includeDeleted: z.boolean().optional() }),
  reorderTasks: z.object({ kind: kindSchema, orderedIds: z.array(z.string()).min(1).max(500) }),
  bulkUpdateTasks: z.object({ updates: z.array(z.object(taskPatchFields)).min(1).max(100) }),
  bulkDeleteTasks: z.object({ ids: z.array(z.string()).min(1).max(100) }),
  listCategories: z.object({ kind: kindSchema.optional() }),
  addCategory: z.object({ kind: kindSchema, name: z.string() }),
  updateCategory: z.object({ kind: kindSchema, id: z.string(), name: z.string() }),
  deleteCategory: z.object({ kind: kindSchema, id: z.string() }),
  mergeCategories: z.object({ kind: kindSchema, sourceId: z.string(), targetId: z.string() }),
  getSettings: z.object({}),
  setShareCategories: z.object({ enabled: z.boolean(), strategy: mergeStrategySchema.optional() }),
  listDailyPlans: z.object({ from: dateSchema, to: dateSchema }),
  getDailyPlan: z.object({ date: dateSchema }),
  createDailyPlan: z.object({ date: dateSchema }),
  deleteDailyPlan: z.object({ date: dateSchema }),
  moveDailyPlan: z.object({
    fromDate: dateSchema,
    toDate: dateSchema,
    replaceExisting: z.boolean().optional(),
  }),
  addFreeSlot: z.object({
    date: dateSchema,
    startAt: z.string(),
    endAt: z.string(),
    label: z.string().optional(),
  }),
  updateFreeSlot: z.object({
    id: z.string(),
    startAt: z.string().optional(),
    endAt: z.string().optional(),
    label: z.string().optional(),
  }),
  deleteFreeSlot: z.object({ id: z.string() }),
  assignTask: z.object({
    slotId: z.string(),
    taskId: z.string(),
    startAt: z.string(),
    endAt: z.string(),
    memo: z.string().optional(),
  }),
  updateAssignment: z.object({
    id: z.string(),
    startAt: z.string().optional(),
    endAt: z.string().optional(),
    sortOrder: z.number().int().min(0).optional(),
    memo: z.string().optional(),
  }),
  unassign: z.object({ id: z.string() }),
  moveAssignment: z.object({
    id: z.string(),
    targetSlotId: z.string(),
    beforeAssignmentId: z.string().optional(),
  }),
  copyDailyPlan: z.object({
    fromDate: dateSchema,
    toDate: dateSchema,
    replaceExisting: z.boolean().optional(),
  }),
  weeklyReport: z.object({ weekStart: dateSchema }),
  importFile: z.object({ path: z.string() }),
  importData: z.object({
    document: z.record(z.string(), z.unknown()),
    mode: z.enum(['merge', 'replace']).optional(),
  }),
  purgeTombstones: z.object({}),
  forgetDevice: z.object({ deviceId: z.string() }),
  rotateToken: z.object({ deviceId: z.string() }),
  listConflicts: z.object({
    status: z.enum(['open', 'resolved', 'all']).optional(),
    entityType: z.string().optional(),
    limit: z.number().int().min(1).max(500).optional(),
  }),
  getConflict: z.object({ id: z.string() }),
  resolveConflict: z.object({ id: z.string(), adopt: z.enum(['hub', 'device', 'current']) }),
  resolveAllConflicts: z.object({
    adopt: z.enum(['hub', 'device', 'current']),
    entityType: z.string().optional(),
    dryRun: z.boolean().optional(),
  }),
};

/** What `list_conflicts` shows for one record. */
export interface ConflictBrief {
  id: string;
  entityType: string;
  entityId: string;
  /** One Japanese line naming the thing in conflict, e.g. `タスク「確定申告の書類を集める」`. */
  label: string;
  detectedAt: string;
  resolution: string | null;
}

export interface ResolvedConflict {
  id: string;
  adopted: string;
  /** False when only the record was stamped: `current`, or a side already live byte-for-byte. */
  wrote: boolean;
}

/** Japanese names for the entity kinds the app can draw; an unknown kind keeps its raw name. */
const ENTITY_LABELS: Record<string, string> = {
  task: 'タスク',
  category: 'カテゴリ',
  plan: '日次プラン',
  slot: '空き時間',
  assignment: '割り当て',
  settings: '設定',
};

/** Meta that belongs to sync bookkeeping, never to the comparison the user sees. */
const COMPARISON_SKIP = new Set(['id', 'clock', 'updatedAt', 'migrated']);

/** Parses any accepted datetime spelling into a UTC ISO string. */
const iso = (value: string): string => {
  const ms = Date.parse(value);
  if (Number.isNaN(ms)) throw new ToolError(`invalid datetime: ${value}`);
  return new Date(ms).toISOString();
};

const live = (list: Entity[]): Entity[] => list.filter((e) => !isDeleted(e));

/** Adds a live record, retiring any tombstone that already holds its id. */
export function pushLive(list: Entity[], entity: Entity): void {
  const index = list.findIndex((e) => e.id === entity.id);
  if (index >= 0) list.splice(index, 1);
  list.push(entity);
}

const overlaps = (aStart: string, aEnd: string, bStart: string, bEnd: string): boolean =>
  aStart < bEnd && aEnd > bStart;

/** One method per MCP tool, independent of the transport so it is testable. */
export class HubTools {
  constructor(
    private readonly store: FileStore,
    private readonly clock: HlcClock,
    private readonly now: () => Date = () => new Date(),
    /** Absent when hub.json is unusable: the local task tools still work, the LAN ones refuse. */
    private readonly deps?: HubToolsDeps,
  ) {}

  private requireDeps(): HubToolsDeps {
    if (!this.deps) throw new ToolError('LAN sync is not configured in this hub process');
    return this.deps;
  }

  private stamp(previous?: Entity): Pick<Entity, 'clock' | 'updatedAt' | 'deletedAt' | 'migrated'> {
    return {
      clock: this.clock.next().toString(),
      updatedAt: this.now().toISOString(),
      deletedAt: (previous?.deletedAt as string | null | undefined) ?? null,
      migrated: false,
    };
  }

  /** Replaces a record with a tombstone: id plus meta, nothing else. */
  private tomb(entity: Entity): Entity {
    const at = this.now().toISOString();
    return {
      id: entity.id,
      clock: this.clock.next().toString(),
      updatedAt: at,
      deletedAt: at,
      migrated: false,
    };
  }

  private observeAll(doc: SyncDocumentJson): void {
    const lists = [
      doc.taskMaster.tasks,
      doc.taskMaster.mustDoCategories,
      doc.taskMaster.wantToDoCategories,
      doc.dailyPlan.plans,
      doc.dailyPlan.slots,
      doc.dailyPlan.assignments,
    ];
    for (const list of lists) {
      for (const entity of list ?? []) {
        const hlc = Hlc.tryParse(entity.clock);
        if (hlc) this.clock.observe(hlc);
      }
    }
    const settingsClock = Hlc.tryParse(doc.taskMaster.settings?.clock);
    if (settingsClock) this.clock.observe(settingsClock);
  }

  /** Throws before the store writes, so a rejected call leaves data.json untouched. */
  private async mutate(fn: (doc: SyncDocumentJson) => void): Promise<SyncDocumentJson> {
    return this.store.update((doc) => {
      this.observeAll(doc);
      fn(doc);
      const violations = checkInvariants(doc);
      if (violations.length > 0) {
        throw new ToolError(
          `invariant violation: ${violations.map((v) => `${v.code} (${v.message})`).join('; ')}`,
        );
      }
      return doc;
    });
  }

  private cats(doc: SyncDocumentJson, kind: string): Entity[] {
    return kind === 'must_do' ? doc.taskMaster.mustDoCategories : doc.taskMaster.wantToDoCategories;
  }

  /** Both lists when categories are shared, otherwise just the named one. */
  private catLists(doc: SyncDocumentJson, kind: string): Entity[][] {
    if (doc.taskMaster.settings?.shareCategories) {
      return [doc.taskMaster.mustDoCategories, doc.taskMaster.wantToDoCategories];
    }
    return [this.cats(doc, kind)];
  }

  // ---- tasks ----

  async listTasks(input: z.infer<typeof schemas.listTasks>): Promise<Entity[]> {
    const doc = await this.store.read();
    const query = input.query?.toLowerCase();
    return live(doc.taskMaster.tasks).filter(
      (t) =>
        (!input.kind || t.kind === input.kind) &&
        (!input.categoryId || t.categoryId === input.categoryId) &&
        (!query ||
          String(t.title ?? '').toLowerCase().includes(query) ||
          String(t.memo ?? '').toLowerCase().includes(query)),
    );
  }

  async addTask(input: z.infer<typeof schemas.addTask>): Promise<Entity> {
    let created!: Entity;
    await this.mutate((doc) => {
      created = this.buildTask(doc, input);
      pushLive(doc.taskMaster.tasks, created);
    });
    return created;
  }

  async bulkAddTasks(input: z.infer<typeof schemas.bulkAddTasks>): Promise<Entity[]> {
    const created: Entity[] = [];
    await this.mutate((doc) => {
      created.length = 0;
      for (const task of input.tasks) {
        const entity = this.buildTask(doc, task);
        created.push(entity);
        pushLive(doc.taskMaster.tasks, entity);
      }
    });
    return created;
  }

  private buildTask(doc: SyncDocumentJson, input: z.infer<typeof schemas.addTask>): Entity {
    const title = input.title.trim();
    if (!title) throw new ToolError('title must not be empty');
    if (input.categoryId && !live(this.cats(doc, input.kind)).some((c) => c.id === input.categoryId)) {
      throw new ToolError(`unknown category ${input.categoryId} for ${input.kind}`);
    }
    const at = this.now().toISOString();
    return {
      id: generateId('task', this.store.deviceId),
      title,
      kind: input.kind,
      priority: input.priority ?? 3,
      createdAt: at,
      memo: input.memo ?? '',
      categoryId: input.categoryId ?? null,
      estimatedMinutes: input.estimatedMinutes ?? 0,
      ...this.stamp(),
    };
  }

  async updateTask(input: z.infer<typeof schemas.updateTask>): Promise<Entity> {
    let updated!: Entity;
    await this.mutate((doc) => {
      updated = this.applyTaskPatch(doc, input);
    });
    return updated;
  }

  /** One task patch inside an open mutation, so bulk callers share the semantics. */
  private applyTaskPatch(doc: SyncDocumentJson, input: z.infer<typeof schemas.updateTask>): Entity {
    const index = doc.taskMaster.tasks.findIndex((t) => t.id === input.id && !isDeleted(t));
    if (index < 0) throw new ToolError(`task ${input.id} not found`);
    const previous = doc.taskMaster.tasks[index];
    const kind = input.kind ?? String(previous.kind);
    if (input.title !== undefined && !input.title.trim()) {
      throw new ToolError('title must not be empty');
    }
    if (input.categoryId && !live(this.cats(doc, kind)).some((c) => c.id === input.categoryId)) {
      throw new ToolError(`unknown category ${input.categoryId} for ${kind}`);
    }
    const patch = Object.fromEntries(
      Object.entries(input).filter(([key, value]) => key !== 'id' && value !== undefined),
    );
    const updated: Entity = {
      ...previous,
      ...patch,
      title: input.title === undefined ? previous.title : input.title.trim(),
      ...this.stamp(previous),
    };
    // Mirrors `sanitizeTaskAgainstCategories`: a kind change must not keep a category the new kind lacks.
    if (
      updated.categoryId != null &&
      !live(this.cats(doc, String(updated.kind))).some((c) => c.id === updated.categoryId)
    ) {
      updated.categoryId = null;
    }
    doc.taskMaster.tasks[index] = updated;
    return updated;
  }

  async bulkUpdateTasks(input: z.infer<typeof schemas.bulkUpdateTasks>): Promise<Entity[]> {
    const updated: Entity[] = [];
    await this.mutate((doc) => {
      updated.length = 0;
      for (const patch of input.updates) updated.push(this.applyTaskPatch(doc, patch));
    });
    return updated;
  }

  async deleteTask(input: z.infer<typeof schemas.deleteTask>): Promise<{ id: string; deleted: true }> {
    await this.mutate((doc) => this.applyTaskDelete(doc, input.id));
    return { id: input.id, deleted: true };
  }

  private applyTaskDelete(doc: SyncDocumentJson, id: string): void {
    const index = doc.taskMaster.tasks.findIndex((t) => t.id === id && !isDeleted(t));
    if (index < 0) throw new ToolError(`task ${id} not found`);
    doc.taskMaster.tasks[index] = this.tomb(doc.taskMaster.tasks[index]);
  }

  async bulkDeleteTasks(
    input: z.infer<typeof schemas.bulkDeleteTasks>,
  ): Promise<{ ids: string[]; deleted: number }> {
    await this.mutate((doc) => {
      for (const id of input.ids) this.applyTaskDelete(doc, id);
    });
    return { ids: input.ids, deleted: input.ids.length };
  }

  async getTask(input: z.infer<typeof schemas.getTask>): Promise<Entity> {
    const doc = await this.store.read();
    const found = doc.taskMaster.tasks.find((t) => t.id === input.id);
    if (!found) throw new ToolError(`task ${input.id} not found`);
    if (isDeleted(found) && !input.includeDeleted) {
      throw new ToolError(`task ${input.id} was deleted at ${String(found.deletedAt)}`);
    }
    return found;
  }

  /** Finds any record by id, whichever list holds it. */
  async getEntity(
    input: z.infer<typeof schemas.getEntity>,
  ): Promise<{ kind: string; list: string; entity: Entity }> {
    const doc = await this.store.read();
    const lists: Array<[string, string, Entity[]]> = [
      ['task', 'tasks', doc.taskMaster.tasks],
      ['category', 'mustDoCategories', doc.taskMaster.mustDoCategories],
      ['category', 'wantToDoCategories', doc.taskMaster.wantToDoCategories],
      ['plan', 'plans', doc.dailyPlan.plans],
      ['slot', 'slots', doc.dailyPlan.slots],
      ['assignment', 'assignments', doc.dailyPlan.assignments],
    ];
    for (const [kind, list, entities] of lists) {
      const found = (entities ?? []).find((e) => e.id === input.id);
      if (!found) continue;
      if (isDeleted(found) && !input.includeDeleted) {
        throw new ToolError(`${kind} ${input.id} was deleted at ${String(found.deletedAt)}`);
      }
      return { kind, list, entity: found };
    }
    throw new ToolError(`record ${input.id} not found`);
  }

  /** Mirrors `reorderTasks`: no sort field exists, so order is written as `priority` (count - index). */
  async reorderTasks(input: z.infer<typeof schemas.reorderTasks>): Promise<Entity[]> {
    let ordered: Entity[] = [];
    await this.mutate((doc) => {
      const ofKind = live(doc.taskMaster.tasks)
        .filter((t) => t.kind === input.kind)
        // The app's display order: priority descending, then title.
        .sort(
          (a, b) =>
            Number(b.priority) - Number(a.priority) ||
            String(a.title).localeCompare(String(b.title)),
        );
      const byId = new Map(ofKind.map((t) => [String(t.id), t]));
      const seen = new Set<string>();
      const sequence: Entity[] = [];
      for (const id of input.orderedIds) {
        const task = byId.get(id);
        if (!task) throw new ToolError(`task ${id} not found among live ${input.kind} tasks`);
        if (seen.has(id)) throw new ToolError(`task ${id} listed twice`);
        seen.add(id);
        sequence.push(task);
      }
      for (const task of ofKind) if (!seen.has(String(task.id))) sequence.push(task);
      ordered = sequence.map((task, index) => {
        const priority = sequence.length - index;
        if (Number(task.priority) === priority) return task;
        const updated: Entity = { ...task, priority, ...this.stamp(task) };
        const at = doc.taskMaster.tasks.findIndex((t) => t.id === task.id);
        doc.taskMaster.tasks[at] = updated;
        return updated;
      });
    });
    return ordered;
  }

  // ---- categories ----

  async listCategories(
    input: z.infer<typeof schemas.listCategories>,
  ): Promise<Array<Entity & { kind: string }>> {
    const doc = await this.store.read();
    const out: Array<Entity & { kind: string }> = [];
    for (const kind of TASK_KINDS) {
      if (input.kind && input.kind !== kind) continue;
      out.push(...live(this.cats(doc, kind)).map((c) => ({ ...c, kind })));
    }
    return out;
  }

  async addCategory(input: z.infer<typeof schemas.addCategory>): Promise<Entity> {
    let created!: Entity;
    await this.mutate((doc) => {
      const name = input.name.trim();
      if (!name) throw new ToolError('name must not be empty');
      this.assertCategoryNameFree(doc, input.kind, name, null);
      created = {
        id: generateId(input.kind === 'must_do' ? 'must' : 'want', this.store.deviceId),
        name,
        ...this.stamp(),
      };
      for (const list of this.catLists(doc, input.kind)) pushLive(list, { ...created });
    });
    return created;
  }

  async updateCategory(input: z.infer<typeof schemas.updateCategory>): Promise<Entity> {
    let updated!: Entity;
    await this.mutate((doc) => {
      const name = input.name.trim();
      if (!name) throw new ToolError('name must not be empty');
      const lists = this.catLists(doc, input.kind);
      if (!lists.some((list) => list.some((c) => c.id === input.id && !isDeleted(c)))) {
        throw new ToolError(`category ${input.id} not found`);
      }
      this.assertCategoryNameFree(doc, input.kind, name, input.id);
      for (const list of lists) {
        const index = list.findIndex((c) => c.id === input.id && !isDeleted(c));
        if (index < 0) continue;
        updated = { ...list[index], name, ...this.stamp(list[index]) };
        list[index] = updated;
      }
    });
    return updated;
  }

  async deleteCategory(
    input: z.infer<typeof schemas.deleteCategory>,
  ): Promise<{ id: string; deleted: true }> {
    await this.mutate((doc) => {
      const lists = this.catLists(doc, input.kind);
      let found = false;
      for (const list of lists) {
        const index = list.findIndex((c) => c.id === input.id && !isDeleted(c));
        if (index < 0) continue;
        found = true;
        list[index] = this.tomb(list[index]);
      }
      if (!found) throw new ToolError(`category ${input.id} not found`);
      doc.taskMaster.tasks = doc.taskMaster.tasks.map((t) =>
        !isDeleted(t) && t.categoryId === input.id
          ? { ...t, categoryId: null, ...this.stamp(t) }
          : t,
      );
    });
    return { id: input.id, deleted: true };
  }

  async mergeCategories(
    input: z.infer<typeof schemas.mergeCategories>,
  ): Promise<{ sourceId: string; targetId: string; movedTasks: number }> {
    let movedTasks = 0;
    await this.mutate((doc) => {
      movedTasks = 0;
      if (input.sourceId === input.targetId) {
        throw new ToolError('sourceId and targetId must differ');
      }
      const lists = this.catLists(doc, input.kind);
      const holds = (id: string) => lists.some((l) => l.some((c) => c.id === id && !isDeleted(c)));
      if (!holds(input.sourceId)) throw new ToolError(`category ${input.sourceId} not found`);
      if (!holds(input.targetId)) throw new ToolError(`category ${input.targetId} not found`);
      doc.taskMaster.tasks = doc.taskMaster.tasks.map((t) => {
        if (isDeleted(t) || t.categoryId !== input.sourceId) return t;
        movedTasks += 1;
        return { ...t, categoryId: input.targetId, ...this.stamp(t) };
      });
      for (const list of lists) {
        const index = list.findIndex((c) => c.id === input.sourceId && !isDeleted(c));
        if (index >= 0) list[index] = this.tomb(list[index]);
      }
    });
    return { sourceId: input.sourceId, targetId: input.targetId, movedTasks };
  }

  // ---- settings ----

  async getSettings(): Promise<Entity> {
    const doc = await this.store.read();
    return { id: 'settings', ...doc.taskMaster.settings } as Entity;
  }

  /** Mirrors `setShareCategories`: turning sharing on merges both lists, off mirrors must-do into both. */
  async setShareCategories(input: z.infer<typeof schemas.setShareCategories>): Promise<Entity> {
    let settings!: Entity;
    await this.mutate((doc) => {
      const current = doc.taskMaster.settings?.shareCategories === true;
      if (current === input.enabled) {
        settings = { id: 'settings', ...doc.taskMaster.settings } as Entity;
        return;
      }
      const mustDo = live(doc.taskMaster.mustDoCategories);
      const wantToDo = live(doc.taskMaster.wantToDoCategories);
      const next = input.enabled
        ? this.mergedCategories(mustDo, wantToDo, input.strategy ?? 'keepLonger')
        : mustDo;
      const keptIds = new Set(next.map((c) => String(c.id)));
      if (input.enabled) this.retargetTasksByName(doc, keptIds, next);
      this.rebuildCategoryList(doc.taskMaster.mustDoCategories, next);
      this.rebuildCategoryList(doc.taskMaster.wantToDoCategories, next);
      doc.taskMaster.settings = {
        ...doc.taskMaster.settings,
        shareCategories: input.enabled,
        ...this.stamp(doc.taskMaster.settings as unknown as Entity),
      };
      settings = { id: 'settings', ...doc.taskMaster.settings } as Entity;
    });
    return settings;
  }

  private mergedCategories(mustDo: Entity[], wantToDo: Entity[], strategy: string): Entity[] {
    switch (strategy) {
      case 'keepMustDo':
        return mustDo;
      case 'keepWantToDo':
        return wantToDo;
      case 'keepShorter':
        return mustDo.length <= wantToDo.length ? mustDo : wantToDo;
      default:
        return mustDo.length >= wantToDo.length ? mustDo : wantToDo;
    }
  }

  /** A task whose category the merge dropped follows the same name, or loses its category. */
  private retargetTasksByName(doc: SyncDocumentJson, keptIds: Set<string>, kept: Entity[]): void {
    doc.taskMaster.tasks = doc.taskMaster.tasks.map((task) => {
      if (isDeleted(task) || task.categoryId == null || keptIds.has(String(task.categoryId))) {
        return task;
      }
      const previous = live(this.cats(doc, String(task.kind))).find((c) => c.id === task.categoryId);
      const matched = previous ? kept.find((c) => c.name === previous.name) : undefined;
      return { ...task, categoryId: matched ? matched.id : null, ...this.stamp(task) };
    });
  }

  /** Makes `list` hold exactly `next`: entries it already has keep their clock, the rest are stamped or tombstoned. */
  private rebuildCategoryList(list: Entity[], next: Entity[]): void {
    const keptIds = new Set(next.map((c) => String(c.id)));
    for (let i = 0; i < list.length; i += 1) {
      if (!isDeleted(list[i]) && !keptIds.has(String(list[i].id))) list[i] = this.tomb(list[i]);
    }
    for (const category of next) {
      if (list.some((c) => c.id === category.id && !isDeleted(c))) continue;
      pushLive(list, { id: category.id, name: category.name, ...this.stamp() } as Entity);
    }
  }

  /** Mirrors `validateCategoryNameUniqueness`; shared categories are one namespace. */
  private assertCategoryNameFree(
    doc: SyncDocumentJson,
    kind: string,
    name: string,
    ownId: string | null,
  ): void {
    for (const list of this.catLists(doc, kind)) {
      if (live(list).some((c) => c.id !== ownId && String(c.name) === name)) {
        throw new ToolError(`duplicate category name "${name}"`);
      }
    }
  }

  // ---- daily plan ----

  private planFor(doc: SyncDocumentJson, date: string): Entity | undefined {
    return live(doc.dailyPlan.plans).find((p) => p.date === date);
  }

  private ensurePlan(doc: SyncDocumentJson, date: string): Entity {
    const existing = this.planFor(doc, date);
    if (existing) return existing;
    const at = this.now().toISOString();
    const plan: Entity = {
      id: generateId('plan', this.store.deviceId),
      date,
      createdAt: at,
      ...this.stamp(),
    };
    pushLive(doc.dailyPlan.plans, plan);
    return plan;
  }

  private touchPlan(doc: SyncDocumentJson, planId: string): void {
    doc.dailyPlan.plans = doc.dailyPlan.plans.map((p) =>
      p.id === planId && !isDeleted(p) ? { ...p, ...this.stamp(p) } : p,
    );
  }

  /** Mirrors `normalizeAssignmentsForSlot`: only a moved entry is stamped. */
  private normalizeSlot(doc: SyncDocumentJson, slotId: string): void {
    const items = live(doc.dailyPlan.assignments)
      .filter((a) => a.slotId === slotId)
      .sort(
        (x, y) =>
          String(x.startAt).localeCompare(String(y.startAt)) ||
          String(x.endAt).localeCompare(String(y.endAt)) ||
          Number(x.sortOrder) - Number(y.sortOrder),
      );
    items.forEach((assignment, index) => {
      if (Number(assignment.sortOrder) === index) return;
      const at = doc.dailyPlan.assignments.findIndex((x) => x.id === assignment.id);
      doc.dailyPlan.assignments[at] = { ...assignment, sortOrder: index, ...this.stamp(assignment) };
    });
  }

  /** Mirrors `validateFreeTimeSlotAgainstPlan`. */
  private assertSlotFits(doc: SyncDocumentJson, slot: Entity): void {
    const start = String(slot.startAt);
    const end = String(slot.endAt);
    if (!(start < end)) throw new ToolError(`slot ${slot.id} must end after it starts`);
    for (const other of live(doc.dailyPlan.slots)) {
      if (other.id === slot.id || other.dailyPlanId !== slot.dailyPlanId) continue;
      if (overlaps(start, end, String(other.startAt), String(other.endAt))) {
        throw new ToolError(`slot ${slot.id} overlaps slot ${other.id}`);
      }
    }
  }

  /** Mirrors `validateAssignment`. */
  private assertAssignmentFits(doc: SyncDocumentJson, assignment: Entity): void {
    const start = String(assignment.startAt);
    const end = String(assignment.endAt);
    if (!(start < end)) throw new ToolError(`assignment ${assignment.id} must end after it starts`);
    const slot = live(doc.dailyPlan.slots).find((s) => s.id === assignment.slotId);
    if (!slot) throw new ToolError(`slot ${assignment.slotId} not found`);
    if (start < String(slot.startAt) || end > String(slot.endAt)) {
      throw new ToolError(
        `assignment_outside_slot: assignment ${assignment.id} exceeds slot ${slot.id}`,
      );
    }
    for (const other of live(doc.dailyPlan.assignments)) {
      if (other.id === assignment.id || other.slotId !== assignment.slotId) continue;
      if (overlaps(start, end, String(other.startAt), String(other.endAt))) {
        throw new ToolError(
          `assignment_overlap: assignment ${assignment.id} overlaps ${other.id}`,
        );
      }
    }
  }

  async listDailyPlans(input: z.infer<typeof schemas.listDailyPlans>): Promise<Entity[]> {
    const doc = await this.store.read();
    return live(doc.dailyPlan.plans)
      .filter((p) => String(p.date) >= input.from && String(p.date) <= input.to)
      .sort((a, b) => String(a.date).localeCompare(String(b.date)));
  }

  async getDailyPlan(input: z.infer<typeof schemas.getDailyPlan>): Promise<{
    date: string;
    plan: Entity | null;
    slots: Array<Entity & { assignments: Entity[] }>;
  }> {
    const doc = await this.store.read();
    const plan = this.planFor(doc, input.date);
    if (!plan) return { date: input.date, plan: null, slots: [] };
    const slots = live(doc.dailyPlan.slots)
      .filter((s) => s.dailyPlanId === plan.id)
      .sort((a, b) => String(a.startAt).localeCompare(String(b.startAt)));
    return {
      date: input.date,
      plan,
      slots: slots.map((s) => ({
        ...s,
        assignments: live(doc.dailyPlan.assignments)
          .filter((a) => a.slotId === s.id)
          .sort((x, y) => Number(x.sortOrder) - Number(y.sortOrder)),
      })),
    };
  }

  async addFreeSlot(input: z.infer<typeof schemas.addFreeSlot>): Promise<Entity> {
    let created!: Entity;
    await this.mutate((doc) => {
      const plan = this.ensurePlan(doc, input.date);
      created = {
        id: generateId('slot', this.store.deviceId),
        dailyPlanId: plan.id,
        startAt: iso(input.startAt),
        endAt: iso(input.endAt),
        label: input.label ?? '',
        ...this.stamp(),
      };
      pushLive(doc.dailyPlan.slots, created);
      this.assertSlotFits(doc, created);
      this.touchPlan(doc, plan.id);
    });
    return created;
  }

  async updateFreeSlot(input: z.infer<typeof schemas.updateFreeSlot>): Promise<Entity> {
    let updated!: Entity;
    await this.mutate((doc) => {
      const index = doc.dailyPlan.slots.findIndex((s) => s.id === input.id && !isDeleted(s));
      if (index < 0) throw new ToolError(`slot ${input.id} not found`);
      const previous = doc.dailyPlan.slots[index];
      updated = {
        ...previous,
        startAt: input.startAt ? iso(input.startAt) : previous.startAt,
        endAt: input.endAt ? iso(input.endAt) : previous.endAt,
        label: input.label ?? previous.label,
        ...this.stamp(previous),
      };
      doc.dailyPlan.slots[index] = updated;
      this.assertSlotFits(doc, updated);
      for (const assignment of live(doc.dailyPlan.assignments).filter((a) => a.slotId === input.id)) {
        this.assertAssignmentFits(doc, assignment);
      }
      this.touchPlan(doc, String(previous.dailyPlanId));
    });
    return updated;
  }

  async deleteFreeSlot(
    input: z.infer<typeof schemas.deleteFreeSlot>,
  ): Promise<{ id: string; deleted: true }> {
    await this.mutate((doc) => {
      const index = doc.dailyPlan.slots.findIndex((s) => s.id === input.id && !isDeleted(s));
      if (index < 0) throw new ToolError(`slot ${input.id} not found`);
      const planId = String(doc.dailyPlan.slots[index].dailyPlanId);
      doc.dailyPlan.slots[index] = this.tomb(doc.dailyPlan.slots[index]);
      doc.dailyPlan.assignments = doc.dailyPlan.assignments.map((a) =>
        !isDeleted(a) && a.slotId === input.id ? this.tomb(a) : a,
      );
      this.touchPlan(doc, planId);
    });
    return { id: input.id, deleted: true };
  }

  async assignTask(input: z.infer<typeof schemas.assignTask>): Promise<Entity> {
    let created!: Entity;
    await this.mutate((doc) => {
      const slot = live(doc.dailyPlan.slots).find((s) => s.id === input.slotId);
      if (!slot) throw new ToolError(`slot ${input.slotId} not found`);
      const task = live(doc.taskMaster.tasks).find((t) => t.id === input.taskId);
      if (!task) throw new ToolError(`task ${input.taskId} not found`);
      const category = task.categoryId
        ? live(this.cats(doc, String(task.kind))).find((c) => c.id === task.categoryId)
        : undefined;
      const count = live(doc.dailyPlan.assignments).filter((a) => a.slotId === slot.id).length;
      created = {
        id: generateId('assignment', this.store.deviceId),
        dailyPlanId: slot.dailyPlanId,
        slotId: slot.id,
        taskId: task.id,
        taskTitle: task.title,
        taskKind: task.kind,
        startAt: iso(input.startAt),
        endAt: iso(input.endAt),
        sortOrder: count,
        categoryId: task.categoryId ?? null,
        categoryName: category?.name ?? null,
        memo: input.memo ?? '',
        ...this.stamp(),
      };
      pushLive(doc.dailyPlan.assignments, created);
      this.assertAssignmentFits(doc, created);
      this.normalizeSlot(doc, String(slot.id));
      this.touchPlan(doc, String(slot.dailyPlanId));
      created = doc.dailyPlan.assignments.find((a) => a.id === created.id)!;
    });
    return created;
  }

  async updateAssignment(input: z.infer<typeof schemas.updateAssignment>): Promise<Entity> {
    let updated!: Entity;
    await this.mutate((doc) => {
      const index = doc.dailyPlan.assignments.findIndex((a) => a.id === input.id && !isDeleted(a));
      if (index < 0) throw new ToolError(`assignment ${input.id} not found`);
      const previous = doc.dailyPlan.assignments[index];
      updated = {
        ...previous,
        startAt: input.startAt ? iso(input.startAt) : previous.startAt,
        endAt: input.endAt ? iso(input.endAt) : previous.endAt,
        sortOrder: input.sortOrder ?? previous.sortOrder,
        memo: input.memo ?? previous.memo,
        ...this.stamp(previous),
      };
      doc.dailyPlan.assignments[index] = updated;
      this.assertAssignmentFits(doc, updated);
      this.normalizeSlot(doc, String(previous.slotId));
      this.touchPlan(doc, String(previous.dailyPlanId));
      updated = doc.dailyPlan.assignments.find((a) => a.id === input.id)!;
    });
    return updated;
  }

  async unassign(input: z.infer<typeof schemas.unassign>): Promise<{ id: string; deleted: true }> {
    await this.mutate((doc) => {
      const index = doc.dailyPlan.assignments.findIndex((a) => a.id === input.id && !isDeleted(a));
      if (index < 0) throw new ToolError(`assignment ${input.id} not found`);
      const previous = doc.dailyPlan.assignments[index];
      doc.dailyPlan.assignments[index] = this.tomb(previous);
      this.normalizeSlot(doc, String(previous.slotId));
      this.touchPlan(doc, String(previous.dailyPlanId));
    });
    return { id: input.id, deleted: true };
  }

  async copyDailyPlan(input: z.infer<typeof schemas.copyDailyPlan>): Promise<{
    plan: Entity;
    slots: Entity[];
    assignments: Entity[];
  }> {
    let result!: { plan: Entity; slots: Entity[]; assignments: Entity[] };
    await this.mutate((doc) => {
      result = this.copyPlanWithin(doc, input);
    });
    return result;
  }

  /** The copy half of `copy_daily_plan`, shared with `move_daily_plan`. */
  private copyPlanWithin(
    doc: SyncDocumentJson,
    input: z.infer<typeof schemas.copyDailyPlan>,
  ): { plan: Entity; slots: Entity[]; assignments: Entity[] } {
    {
      if (input.fromDate === input.toDate) throw new ToolError('fromDate and toDate must differ');
      const source = this.planFor(doc, input.fromDate);
      if (!source) throw new ToolError(`no plan on ${input.fromDate}`);
      const target = this.ensurePlan(doc, input.toDate);
      if (input.replaceExisting) {
        doc.dailyPlan.slots = doc.dailyPlan.slots.map((s) =>
          !isDeleted(s) && s.dailyPlanId === target.id ? this.tomb(s) : s,
        );
        doc.dailyPlan.assignments = doc.dailyPlan.assignments.map((a) =>
          !isDeleted(a) && a.dailyPlanId === target.id ? this.tomb(a) : a,
        );
      }
      // Copied ids must not collide with anything that exists or ever existed,
      // so tombstoned ids are taken too.
      const taken = new Set([
        ...doc.dailyPlan.slots.map((s) => String(s.id)),
        ...doc.dailyPlan.assignments.map((a) => String(a.id)),
      ]);
      const nextId = (prefix: string, sourceId: string): string => {
        let generation = 0;
        while (taken.has(copyId(prefix, String(source.id), input.toDate, sourceId, generation))) {
          generation += 1;
        }
        const id = copyId(prefix, String(source.id), input.toDate, sourceId, generation);
        taken.add(id);
        return id;
      };
      const dayMs =
        Date.parse(`${input.toDate}T00:00:00Z`) - Date.parse(`${input.fromDate}T00:00:00Z`);
      const shift = (value: unknown): string =>
        new Date(Date.parse(String(value)) + dayMs).toISOString();

      const slotMap = new Map<string, string>();
      const slots: Entity[] = [];
      const assignments: Entity[] = [];
      const sourceSlots = live(doc.dailyPlan.slots).filter((s) => s.dailyPlanId === source.id);
      if (sourceSlots.length === 0) throw new ToolError(`no free time slots on ${input.fromDate}`);
      for (const slot of sourceSlots) {
        const id = nextId('slot', String(slot.id));
        slotMap.set(String(slot.id), id);
        const copy: Entity = {
          ...slot,
          id,
          dailyPlanId: target.id,
          startAt: shift(slot.startAt),
          endAt: shift(slot.endAt),
          ...this.stamp(),
        };
        pushLive(doc.dailyPlan.slots, copy);
        this.assertSlotFits(doc, copy);
        slots.push(copy);
      }
      const sourceAssignments = live(doc.dailyPlan.assignments)
        .filter((a) => a.dailyPlanId === source.id && slotMap.has(String(a.slotId)))
        .sort(
          (x, y) =>
            String(x.startAt).localeCompare(String(y.startAt)) ||
            Number(x.sortOrder) - Number(y.sortOrder),
        );
      for (const assignment of sourceAssignments) {
        const copy: Entity = {
          ...assignment,
          id: nextId('assignment', String(assignment.id)),
          dailyPlanId: target.id,
          slotId: slotMap.get(String(assignment.slotId))!,
          startAt: shift(assignment.startAt),
          endAt: shift(assignment.endAt),
          ...this.stamp(),
        };
        pushLive(doc.dailyPlan.assignments, copy);
        this.assertAssignmentFits(doc, copy);
        assignments.push(copy);
      }
      for (const slotId of slotMap.values()) this.normalizeSlot(doc, slotId);
      this.touchPlan(doc, String(target.id));
      return {
        plan: doc.dailyPlan.plans.find((p) => p.id === target.id)!,
        slots: slots.map((s) => doc.dailyPlan.slots.find((x) => x.id === s.id)!),
        assignments: assignments.map((a) => doc.dailyPlan.assignments.find((x) => x.id === a.id)!),
      };
    }
  }

  async createDailyPlan(input: z.infer<typeof schemas.createDailyPlan>): Promise<Entity> {
    let plan!: Entity;
    await this.mutate((doc) => {
      plan = this.ensurePlan(doc, input.date);
    });
    return plan;
  }

  async deleteDailyPlan(input: z.infer<typeof schemas.deleteDailyPlan>): Promise<{
    date: string; deleted: true; slots: number; assignments: number;
  }> {
    let counts = { slots: 0, assignments: 0 };
    await this.mutate((doc) => {
      counts = this.deletePlanWithin(doc, input.date);
    });
    return { date: input.date, deleted: true, ...counts };
  }

  /** Tombstones a plan with everything hanging off it; shared with `move_daily_plan`. */
  private deletePlanWithin(
    doc: SyncDocumentJson,
    date: string,
  ): { slots: number; assignments: number } {
    const plan = this.planFor(doc, date);
    if (!plan) throw new ToolError(`no plan on ${date}`);
    const slotIds = new Set(
      live(doc.dailyPlan.slots).filter((s) => s.dailyPlanId === plan.id).map((s) => String(s.id)),
    );
    let slots = 0;
    let assignments = 0;
    doc.dailyPlan.assignments = doc.dailyPlan.assignments.map((a) => {
      if (isDeleted(a) || (a.dailyPlanId !== plan.id && !slotIds.has(String(a.slotId)))) return a;
      assignments += 1;
      return this.tomb(a);
    });
    doc.dailyPlan.slots = doc.dailyPlan.slots.map((s) => {
      if (isDeleted(s) || s.dailyPlanId !== plan.id) return s;
      slots += 1;
      return this.tomb(s);
    });
    const index = doc.dailyPlan.plans.findIndex((p) => p.id === plan.id && !isDeleted(p));
    doc.dailyPlan.plans[index] = this.tomb(doc.dailyPlan.plans[index]);
    return { slots, assignments };
  }

  async moveDailyPlan(input: z.infer<typeof schemas.moveDailyPlan>): Promise<{
    plan: Entity; slots: Entity[]; assignments: Entity[];
  }> {
    let result!: { plan: Entity; slots: Entity[]; assignments: Entity[] };
    await this.mutate((doc) => {
      result = this.copyPlanWithin(doc, input);
      this.deletePlanWithin(doc, input.fromDate);
    });
    return result;
  }

  /** Mirrors `moveAssignmentToSlot`: the target slot is repacked from its start, both slots renumbered. */
  async moveAssignment(input: z.infer<typeof schemas.moveAssignment>): Promise<Entity> {
    let moved!: Entity;
    await this.mutate((doc) => {
      const index = doc.dailyPlan.assignments.findIndex((a) => a.id === input.id && !isDeleted(a));
      if (index < 0) throw new ToolError(`assignment ${input.id} not found`);
      const assignment = doc.dailyPlan.assignments[index];
      const target = live(doc.dailyPlan.slots).find((s) => s.id === input.targetSlotId);
      if (!target) throw new ToolError(`slot ${input.targetSlotId} not found`);
      const sourceSlotId = String(assignment.slotId);
      const sourcePlanId = String(assignment.dailyPlanId);
      const others = live(doc.dailyPlan.assignments)
        .filter((a) => a.slotId === target.id && a.id !== assignment.id)
        .sort(
          (x, y) =>
            String(x.startAt).localeCompare(String(y.startAt)) ||
            Number(x.sortOrder) - Number(y.sortOrder),
        );
      const insertAt = input.beforeAssignmentId === undefined
        ? others.length
        : others.findIndex((a) => a.id === input.beforeAssignmentId);
      if (insertAt < 0) {
        throw new ToolError(
          `assignment ${input.beforeAssignmentId} is not in slot ${input.targetSlotId}`,
        );
      }
      const ordered = [...others.slice(0, insertAt), assignment, ...others.slice(insertAt)];
      let cursor = Date.parse(String(target.startAt));
      for (const item of ordered) {
        const span = Math.max(
          0,
          Math.floor((Date.parse(String(item.endAt)) - Date.parse(String(item.startAt))) / 60000),
        ) * 60000;
        const startAt = new Date(cursor).toISOString();
        const endAt = new Date(cursor + span).toISOString();
        cursor += span;
        if (item.startAt === startAt && item.endAt === endAt && item.slotId === target.id) continue;
        const at = doc.dailyPlan.assignments.findIndex((a) => a.id === item.id);
        doc.dailyPlan.assignments[at] = {
          ...item,
          dailyPlanId: target.dailyPlanId,
          slotId: target.id,
          startAt,
          endAt,
          ...this.stamp(item),
        };
      }
      for (const item of ordered) {
        this.assertAssignmentFits(doc, doc.dailyPlan.assignments.find((a) => a.id === item.id)!);
      }
      if (sourceSlotId !== target.id) this.normalizeSlot(doc, sourceSlotId);
      this.normalizeSlot(doc, String(target.id));
      this.touchPlan(doc, sourcePlanId);
      this.touchPlan(doc, String(target.dailyPlanId));
      moved = doc.dailyPlan.assignments.find((a) => a.id === input.id)!;
    });
    return moved;
  }

  async weeklyReport(input: z.infer<typeof schemas.weeklyReport>): Promise<{
    weekStart: string;
    days: number;
    freeMinutes: number;
    assignedMinutes: number;
    byKind: Record<string, number>;
    byCategory: Record<string, number>;
  }> {
    const doc = await this.store.read();
    const start = Date.parse(`${input.weekStart}T00:00:00Z`);
    const end = start + 7 * 86400000;
    const plans = live(doc.dailyPlan.plans).filter((p) => {
      const at = Date.parse(`${String(p.date)}T00:00:00Z`);
      return !Number.isNaN(at) && at >= start && at < end;
    });
    const planIds = new Set(plans.map((p) => String(p.id)));
    const minutes = (e: Entity): number =>
      Math.max(0, (Date.parse(String(e.endAt)) - Date.parse(String(e.startAt))) / 60000) || 0;
    const byKind: Record<string, number> = { must_do: 0, want_to_do: 0 };
    const byCategory: Record<string, number> = {};
    let freeMinutes = 0;
    for (const slot of live(doc.dailyPlan.slots).filter((s) => planIds.has(String(s.dailyPlanId)))) {
      freeMinutes += minutes(slot);
    }
    for (const a of live(doc.dailyPlan.assignments).filter((x) =>
      planIds.has(String(x.dailyPlanId)),
    )) {
      const kind = String(a.taskKind);
      byKind[kind] = (byKind[kind] ?? 0) + minutes(a);
      const category = a.categoryName == null ? '未分類' : String(a.categoryName);
      byCategory[category] = (byCategory[category] ?? 0) + minutes(a);
    }
    return {
      weekStart: input.weekStart,
      days: plans.length,
      freeMinutes,
      assignedMinutes: Object.values(byKind).reduce((a, b) => a + b, 0),
      byKind,
      byCategory,
    };
  }

  // ---- data ----

  async exportData(): Promise<SyncDocumentJson> {
    return this.store.read();
  }

  async undoLastWrite(): Promise<boolean> {
    return this.store.undoLastWrite();
  }

  /** Directories `import_file` may read from. Anything else is refused before the file is opened. */
  private importDirs(): string[] {
    const injected = this.deps?.importDirs;
    const dirs = injected ?? [
      dirname(resolveUserPath(this.store.filePath)),
      join(homedir(), 'Downloads'),
      ...(process.env.FRELOCATOR_IMPORT_DIRS ?? '').split(':').filter((d) => d.length > 0),
    ];
    return dirs.map(resolveUserPath);
  }

  async importFile(input: z.infer<typeof schemas.importFile>): Promise<{
    summary: SyncSummary; warnings: string[]; deviceId: string;
  }> {
    this.requireDeps();
    const path = resolveUserPath(input.path);
    if (!this.importDirs().some((dir) => isInside(path, dir))) {
      // Deliberately terse: a probe must not learn whether the file exists.
      throw new ToolError(`path not allowed: ${path}`);
    }
    let size: number;
    try {
      size = (await stat(path)).size;
    } catch {
      // ENOENT and EACCES are collapsed: the difference is only useful to a prober.
      throw new ToolError('cannot read file');
    }
    if (size > MAX_BODY) {
      throw new ToolError(`file is larger than the ${MAX_BODY / (1024 * 1024)} MB import limit`);
    }
    let text: string;
    try {
      text = await readFile(path, 'utf8');
    } catch {
      throw new ToolError('cannot read file');
    }
    let json: unknown;
    try {
      json = JSON.parse(text);
    } catch {
      // The parser message quotes the offending bytes, which would echo file content.
      throw new ToolError('not valid JSON');
    }
    return this.mergeIncoming(json, 'merge', 'file-import');
  }

  async importData(input: z.infer<typeof schemas.importData>): Promise<{
    summary: SyncSummary; warnings: string[]; deviceId: string;
  }> {
    return this.mergeIncoming(
      input.document,
      input.mode === 'replace' ? 'take_phone' : 'merge',
      'inline-import',
    );
  }

  /** Runs one incoming v2 document through the sync engine, as `import_file` and `import_data` both do. */
  private async mergeIncoming(
    json: unknown,
    mode: 'merge' | 'take_phone',
    fallbackDeviceId: string,
  ): Promise<{ summary: SyncSummary; warnings: string[]; deviceId: string }> {
    const { config, engine } = this.requireDeps();
    const doc = json as SyncDocumentJson;
    if (typeof doc?.version !== 'number' || doc.version < 2) {
      throw new ToolError(`unsupported schema version ${String(doc?.version)}: export the file from an app with schema v2`);
    }
    const deviceId = typeof doc.deviceId === 'string' && doc.deviceId ? doc.deviceId : fallbackDeviceId;
    const known = config.device(deviceId) !== undefined;
    let result;
    try {
      result = await engine.sync(deviceId, doc, mode);
    } catch (error) {
      if (error instanceof SyncRejected) throw new ToolError(`${error.code}: ${error.message}`);
      throw error;
    }
    let { summary, warnings } = result;
    if (!known) {
      // Registered only now, so a rejected import leaves no device holding back purge.
      await config.registerDevice(deviceId, 'file import');
      await config.recordSync(deviceId, this.now().toISOString());
      // `engine.sync` warned that it could not record the sync; we just did.
      warnings = warnings.filter((w) => !w.startsWith('record_sync_failed:'));
      summary = { ...summary, warnings: warnings.length };
    }
    return { summary, warnings, deviceId };
  }

  async purgeTombstones(): Promise<{ purged: number; purgedBefore: string | null }> {
    return this.requireDeps().engine.purge();
  }

  async forgetDevice(input: z.infer<typeof schemas.forgetDevice>): Promise<{ deviceId: string; forgotten: true }> {
    try {
      await this.requireDeps().config.forgetDevice(input.deviceId);
    } catch (error) {
      throw error instanceof ToolError ? error : new ToolError(String((error as Error).message));
    }
    return { deviceId: input.deviceId, forgotten: true };
  }

  /** The new token is never returned: MCP results end up in logs and chat, and only the phone needs it. */
  async rotateToken(input: z.infer<typeof schemas.rotateToken>): Promise<{ deviceId: string; rotated: true; note: string }> {
    try {
      await this.requireDeps().config.rotateToken(input.deviceId);
    } catch (error) {
      throw error instanceof ToolError ? error : new ToolError(String((error as Error).message));
    }
    return {
      deviceId: input.deviceId,
      rotated: true,
      note: 'the old token is invalid; the phone must pair again by scanning a new pairing QR',
    };
  }

  // ---- conflicts (Plan 3b) ----

  /** The records a user can still act on; a tombstoned one is housekeeping, not a choice. */
  private conflictsOf(doc: SyncDocumentJson): ConflictJson[] {
    return (doc.conflicts ?? []).filter((c) => !isDeleted(c as unknown as Record<string, unknown>));
  }

  /** One Japanese line naming the thing in conflict, for a list the user reads. */
  private static label(conflict: ConflictJson): string {
    const noun = ENTITY_LABELS[conflict.entityType] ?? conflict.entityType;
    if (conflict.entityType === 'settings') return noun;
    const named = (side: ConflictSideJson): string | null => {
      const snapshot = side.snapshot as Record<string, unknown>;
      for (const key of ['title', 'name', 'date']) {
        const value = snapshot[key];
        if (typeof value === 'string' && value !== '') return value;
      }
      return null;
    };
    // A tombstone winner carries no fields at all, so the loser's snapshot is
    // the only place the name survives.
    const name = named(conflict.winner) ?? named(conflict.loser);
    return name === null ? `${noun}（${conflict.entityId}）` : `${noun}「${name}」`;
  }

  /**
   * The recorded side `adopt` names. `hub` means the PC — the MCP hub itself
   * and the browser it serves alike — and `device` the phone; the labels come
   * from the HLC device id, never from which merge argument carried the
   * version, so the same record reads the same way on both ends.
   */
  private static sideFor(conflict: ConflictJson, adopt: 'hub' | 'device'): ConflictSideJson {
    const wanted = (side: string) => (adopt === 'hub' ? isPcSide(side) : !isPcSide(side));
    return wanted(conflict.winner.side) ? conflict.winner : conflict.loser;
  }

  /** Only the fields whose values differ; sync meta is excluded, `deletedAt` deliberately is not. */
  private static differences(conflict: ConflictJson): Array<{ field: string; hub: unknown; device: unknown }> {
    const snapshotOf = (want: 'hub' | 'device'): Record<string, unknown> =>
      HubTools.sideFor(conflict, want).snapshot as Record<string, unknown>;
    const hub = snapshotOf('hub');
    const device = snapshotOf('device');
    const fields = [...new Set([...Object.keys(hub), ...Object.keys(device)])]
      .filter((field) => !COMPARISON_SKIP.has(field))
      .sort();
    const out: Array<{ field: string; hub: unknown; device: unknown }> = [];
    for (const field of fields) {
      const a = hub[field] ?? null;
      const b = device[field] ?? null;
      if (JSON.stringify(a) === JSON.stringify(b)) continue;
      out.push({ field, hub: a, device: b });
    }
    return out;
  }

  /** Whichever list holds the id, or null when nothing does (settings is handled separately). */
  private locate(doc: SyncDocumentJson, entityId: string): { list: Entity[]; entity: Entity } | null {
    const lists: Entity[][] = [
      doc.taskMaster.tasks, doc.taskMaster.mustDoCategories, doc.taskMaster.wantToDoCategories,
      doc.dailyPlan.plans, doc.dailyPlan.slots, doc.dailyPlan.assignments,
    ];
    for (const list of lists) {
      const entity = (list ?? []).find((e) => e.id === entityId);
      if (entity) return { list, entity };
    }
    return null;
  }

  /** True when adopting that side would write exactly what is already stored. */
  private static sameAsLive(
    snapshot: Record<string, unknown>,
    live: Record<string, unknown> | undefined,
    entityType: string,
  ): boolean {
    const deletedSnapshot = isDeleted(snapshot);
    const deletedLive = live === undefined || isDeleted(live);
    if (deletedSnapshot !== deletedLive) return false;
    // Two tombstones say the same thing whatever meta they carry.
    if (deletedSnapshot) return true;
    const contentOf = (e: Record<string, unknown>): Record<string, unknown> =>
      entityType === 'settings' ? { shareCategories: e.shareCategories } : e;
    return contentHash(contentOf(snapshot)) === contentHash(contentOf(live as Record<string, unknown>));
  }

  /**
   * Applies one decision inside an open mutation.
   *
   * Adopting a side writes it back as a *new* edit rather than rewinding the
   * clock: the id stays, `clock` advances, `updatedAt` becomes now and
   * `migrated` is false, so an ordinary merge carries the decision to the phone
   * and to the browser. Adopting a tombstone deletes the entity again.
   */
  private applyResolution(
    doc: SyncDocumentJson,
    record: ConflictJson,
    adopt: 'hub' | 'device' | 'current',
  ): { record: ConflictJson; wrote: boolean; effect: 'none' | 'added' | 'updated' | 'deleted' } {
    const at = this.now().toISOString();
    const stamped: ConflictJson = {
      ...record,
      resolution: adopt,
      resolvedAt: at,
      resolvedBy: this.store.deviceId,
      // A new clock, so this decision beats the detection — and any older one — on merge.
      clock: this.clock.next().toString(),
      updatedAt: at,
    };
    if (adopt === 'current') return { record: stamped, wrote: false, effect: 'none' };

    const side = HubTools.sideFor(record, adopt);
    const snapshot = side.snapshot as Record<string, unknown>;

    if (record.entityType === 'settings') {
      const current = doc.taskMaster.settings as unknown as Record<string, unknown>;
      if (HubTools.sameAsLive(snapshot, current, 'settings')) {
        return { record: stamped, wrote: false, effect: 'none' };
      }
      doc.taskMaster.settings = {
        ...(snapshot as unknown as SyncDocumentJson['taskMaster']['settings']),
        shareCategories: Boolean(snapshot.shareCategories),
        clock: this.clock.next().toString(),
        updatedAt: at,
        deletedAt: null,
        migrated: false,
      };
      return { record: stamped, wrote: true, effect: 'updated' };
    }

    const located = this.locate(doc, record.entityId);
    if (HubTools.sameAsLive(snapshot, located?.entity, record.entityType)) {
      return { record: stamped, wrote: false, effect: 'none' };
    }
    if (!located) {
      // Purge can drop a record the conflict still names; a category id alone
      // does not even say which of the two lists it belonged to, so refuse
      // rather than guess. `adopt: 'current'` still closes the record.
      throw new ToolError(
        `${record.entityType} ${record.entityId} is no longer in the document; resolve it with adopt: "current"`,
      );
    }
    const index = located.list.findIndex((e) => e.id === record.entityId);
    const previouslyLive = !isDeleted(located.entity);
    if (isDeleted(snapshot)) {
      located.list[index] = this.tomb(located.entity);
      return { record: stamped, wrote: true, effect: 'deleted' };
    }
    located.list[index] = {
      ...(snapshot as Entity),
      id: record.entityId,
      clock: this.clock.next().toString(),
      updatedAt: at,
      deletedAt: null,
      migrated: false,
    };
    return { record: stamped, wrote: true, effect: previouslyLive ? 'updated' : 'added' };
  }

  private static summaryOf(effect: 'none' | 'added' | 'updated' | 'deleted'): SyncSummary {
    return {
      added: effect === 'added' ? 1 : 0,
      updated: effect === 'updated' ? 1 : 0,
      deleted: effect === 'deleted' ? 1 : 0,
      removed: 0,
      // Nothing is written unless `checkInvariants` passes, so a returned
      // summary never carries a warning.
      warnings: 0,
      conflicts: 0,
    };
  }

  async listConflicts(input: z.infer<typeof schemas.listConflicts>): Promise<{
    open: number; resolved: number; conflicts: ConflictBrief[];
  }> {
    const all = this.conflictsOf(await this.store.read());
    const open = all.filter((c) => c.resolution == null);
    const resolved = all.filter((c) => c.resolution != null);
    const status = input.status ?? 'open';
    const chosen = status === 'open' ? open : status === 'resolved' ? resolved : all;
    const filtered = input.entityType
      ? chosen.filter((c) => c.entityType === input.entityType)
      : chosen;
    return {
      // The two totals count every record on file, whatever this call filtered to.
      open: open.length,
      resolved: resolved.length,
      conflicts: filtered.slice(0, input.limit ?? 100).map((c) => ({
        id: c.id,
        entityType: c.entityType,
        entityId: c.entityId,
        label: HubTools.label(c),
        detectedAt: c.detectedAt,
        resolution: c.resolution ?? null,
      })),
    };
  }

  async getConflict(input: z.infer<typeof schemas.getConflict>): Promise<{
    conflict: ConflictJson;
    differences: Array<{ field: string; hub: unknown; device: unknown }>;
    current: { clock: string | null; deletedAt: string | null; supersedes: boolean };
  }> {
    const doc = await this.store.read();
    const conflict = this.conflictsOf(doc).find((c) => c.id === input.id);
    if (!conflict) throw new ToolError(`conflict ${input.id} not found`);
    const live: Entity | undefined =
      conflict.entityType === 'settings'
        ? (doc.taskMaster.settings as unknown as Entity)
        : this.locate(doc, conflict.entityId)?.entity;
    const clock = live ? String(live.clock) : null;
    const current = Hlc.tryParse(clock);
    const winner = Hlc.tryParse(conflict.winner.clock);
    const loser = Hlc.tryParse(conflict.loser.clock);
    return {
      conflict,
      differences: HubTools.differences(conflict),
      current: {
        clock,
        deletedAt: live && isDeleted(live) ? String(live.deletedAt) : null,
        // A later edit already overwrote both versions: there is nothing left to choose.
        supersedes: Boolean(
          current && winner && loser && Hlc.compare(current, winner) > 0 && Hlc.compare(current, loser) > 0,
        ),
      },
    };
  }

  async resolveConflict(input: z.infer<typeof schemas.resolveConflict>): Promise<{
    id: string; adopted: string; wrote: boolean; summary: SyncSummary;
  }> {
    let wrote = false;
    let effect: 'none' | 'added' | 'updated' | 'deleted' = 'none';
    await this.mutate((doc) => {
      const list = doc.conflicts ?? [];
      const index = list.findIndex(
        (c) => c.id === input.id && !isDeleted(c as unknown as Record<string, unknown>),
      );
      if (index < 0) throw new ToolError(`conflict ${input.id} not found`);
      const record = list[index];
      if (record.resolution != null) {
        throw new ToolError(
          `conflict ${input.id} is already resolved as ${record.resolution}: すでに解決済みです`,
        );
      }
      const applied = this.applyResolution(doc, record, input.adopt);
      list[index] = applied.record;
      doc.conflicts = list;
      wrote = applied.wrote;
      effect = applied.effect;
    });
    return { id: input.id, adopted: input.adopt, wrote, summary: HubTools.summaryOf(effect) };
  }

  async resolveAllConflicts(input: z.infer<typeof schemas.resolveAllConflicts>): Promise<{
    resolved: number; skipped: number; results: ResolvedConflict[];
  }> {
    const run = (doc: SyncDocumentJson): { resolved: number; skipped: number; results: ResolvedConflict[] } => {
      const list = doc.conflicts ?? [];
      const results: ResolvedConflict[] = [];
      let skipped = 0;
      for (let index = 0; index < list.length; index += 1) {
        const record = list[index];
        if (isDeleted(record as unknown as Record<string, unknown>)) continue;
        if (input.entityType && record.entityType !== input.entityType) continue;
        if (record.resolution != null) { skipped += 1; continue; }
        const applied = this.applyResolution(doc, record, input.adopt);
        list[index] = applied.record;
        results.push({ id: record.id, adopted: input.adopt, wrote: applied.wrote });
      }
      if (list.length > 0) doc.conflicts = list;
      return { resolved: results.length, skipped, results };
    };
    if (input.dryRun) {
      // A rehearsal on a copy of the document: nothing is stored. The HLC does
      // advance, which is harmless — it only ever has to move forward.
      return run(structuredClone(await this.store.read()));
    }
    // One `store.update`: if any single id fails, nothing at all is written.
    let out: { resolved: number; skipped: number; results: ResolvedConflict[] } | undefined;
    await this.mutate((doc) => { out = run(doc); });
    return out as { resolved: number; skipped: number; results: ResolvedConflict[] };
  }

  async syncStatus(): Promise<SyncStatus> {
    const base = {
      dataFile: this.store.filePath,
      modifiedAt: (await this.store.modifiedAt())?.toISOString() ?? null,
      warning: this.store.lastWarning,
      purgedBefore: (await this.store.read()).purgedBefore ?? null,
      lanError: null as string | null,
      configError: null as string | null,
    };
    if (!this.deps) {
      return { ...base, lan: null, fingerprint: null, pairing: { state: 'none', expiresAt: null, failures: 0 }, devices: [], webClients: [], lastSync: null };
    }
    const { config, engine, lan } = this.deps;
    return {
      ...base,
      lan: lan(),
      fingerprint: config.fingerprint,
      pairing: config.pairingState(),
      // Tokens never leave hub.json: they are dropped here, not merely omitted from a type.
      devices: config.devices().map(({ token: _token, ...device }) => ({
        ...device,
        progress: engine.progressFor(device.deviceId) ?? null,
      })),
      webClients: config.webClients(),
      lastSync: engine.lastSync,
    };
  }
}
