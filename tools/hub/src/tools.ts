import { z } from 'zod';
import { Hlc, HlcClock } from './hlc.js';
import { copyId, generateId } from './ids.js';
import { checkInvariants } from './invariants.js';
import { isDeleted, TASK_KINDS, type Entity, type SyncDocumentJson } from './model.js';
import { FileStore } from './store.js';

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

export const schemas = {
  listTasks: z.object({
    kind: kindSchema.optional(),
    categoryId: z.string().optional(),
    query: z.string().optional(),
  }),
  addTask: z.object(taskFields),
  bulkAddTasks: z.object({ tasks: z.array(z.object(taskFields)).min(1).max(100) }),
  updateTask: z.object({
    id: z.string(),
    title: z.string().optional(),
    kind: kindSchema.optional(),
    priority: z.number().int().min(1).max(5).optional(),
    categoryId: z.string().nullable().optional(),
    estimatedMinutes: z.number().int().min(0).optional(),
    memo: z.string().optional(),
  }),
  deleteTask: z.object({ id: z.string() }),
  listCategories: z.object({ kind: kindSchema.optional() }),
  addCategory: z.object({ kind: kindSchema, name: z.string() }),
  updateCategory: z.object({ kind: kindSchema, id: z.string(), name: z.string() }),
  deleteCategory: z.object({ kind: kindSchema, id: z.string() }),
  listDailyPlans: z.object({ from: dateSchema, to: dateSchema }),
  getDailyPlan: z.object({ date: dateSchema }),
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
  copyDailyPlan: z.object({
    fromDate: dateSchema,
    toDate: dateSchema,
    replaceExisting: z.boolean().optional(),
  }),
  weeklyReport: z.object({ weekStart: dateSchema }),
  importFile: z.object({ path: z.string() }),
  purgeTombstones: z.object({}),
  forgetDevice: z.object({ deviceId: z.string() }),
  rotateToken: z.object({ deviceId: z.string() }),
};

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
  ) {}

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
      updated = {
        ...previous,
        ...patch,
        title: input.title === undefined ? previous.title : input.title.trim(),
        ...this.stamp(previous),
      };
      doc.taskMaster.tasks[index] = updated;
    });
    return updated;
  }

  async deleteTask(input: z.infer<typeof schemas.deleteTask>): Promise<{ id: string; deleted: true }> {
    await this.mutate((doc) => {
      const index = doc.taskMaster.tasks.findIndex((t) => t.id === input.id && !isDeleted(t));
      if (index < 0) throw new ToolError(`task ${input.id} not found`);
      doc.taskMaster.tasks[index] = this.tomb(doc.taskMaster.tasks[index]);
    });
    return { id: input.id, deleted: true };
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
      result = {
        plan: doc.dailyPlan.plans.find((p) => p.id === target.id)!,
        slots: slots.map((s) => doc.dailyPlan.slots.find((x) => x.id === s.id)!),
        assignments: assignments.map((a) => doc.dailyPlan.assignments.find((x) => x.id === a.id)!),
      };
    });
    return result;
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

  async syncStatus(): Promise<{
    dataFile: string;
    modifiedAt: string | null;
    warning: string | null;
    lan: string;
  }> {
    return {
      dataFile: this.store.filePath,
      modifiedAt: (await this.store.modifiedAt())?.toISOString() ?? null,
      warning: this.store.lastWarning,
      lan: 'not started (Plan 2)',
    };
  }
}
