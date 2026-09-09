import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { HlcClock } from '../src/hlc.js';
import { checkInvariants } from '../src/invariants.js';
import { FileStore } from '../src/store.js';
import { HubTools } from '../src/tools.js';

let dir: string;
let store: FileStore;
let tools: HubTools;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'hub-coverage-'));
  store = new FileStore(dir, 'hub-0000');
  tools = new HubTools(store, new HlcClock('hub-0000', () => 1000));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

const date = '2026-09-09';
const slotArgs = (day = date, from = '10:00', to = '14:00') => ({
  date: day,
  startAt: `${day}T${from}:00+09:00`,
  endAt: `${day}T${to}:00+09:00`,
});

const noViolations = async () => expect(checkInvariants(await store.read())).toEqual([]);

describe('get_task / get_entity', () => {
  it('returns one task by id and refuses an unknown id', async () => {
    const task = await tools.addTask({ title: 'a', kind: 'must_do' });
    expect((await tools.getTask({ id: String(task.id) })).title).toBe('a');
    await expect(tools.getTask({ id: 'nope' })).rejects.toThrow(/not found/);
  });

  it('hides a deleted task unless includeDeleted is set', async () => {
    const task = await tools.addTask({ title: 'a', kind: 'must_do' });
    await tools.deleteTask({ id: String(task.id) });
    await expect(tools.getTask({ id: String(task.id) })).rejects.toThrow(/deleted/);
    const tomb = await tools.getTask({ id: String(task.id), includeDeleted: true });
    expect(typeof tomb.deletedAt).toBe('string');
    expect(tomb.title).toBeUndefined();
  });

  it('finds any entity kind by id', async () => {
    const task = await tools.addTask({ title: 'a', kind: 'must_do' });
    const slot = await tools.addFreeSlot(slotArgs());
    const category = (await tools.listCategories({ kind: 'must_do' }))[0];
    expect((await tools.getEntity({ id: String(task.id) })).kind).toBe('task');
    expect((await tools.getEntity({ id: String(slot.id) })).kind).toBe('slot');
    expect((await tools.getEntity({ id: String(slot.dailyPlanId) })).kind).toBe('plan');
    const found = await tools.getEntity({ id: String(category.id) });
    expect(found.kind).toBe('category');
    expect(found.list).toBe('mustDoCategories');
    await expect(tools.getEntity({ id: 'nope' })).rejects.toThrow(/not found/);
  });
});

describe('reorder_tasks', () => {
  it('rewrites priority so the given order is the display order', async () => {
    const a = await tools.addTask({ title: 'a', kind: 'must_do' });
    const b = await tools.addTask({ title: 'b', kind: 'must_do' });
    const c = await tools.addTask({ title: 'c', kind: 'must_do' });
    const ordered = await tools.reorderTasks({
      kind: 'must_do',
      orderedIds: [String(c.id), String(a.id), String(b.id)],
    });
    expect(ordered.map((t) => t.title)).toEqual(['c', 'a', 'b']);
    expect(ordered.map((t) => t.priority)).toEqual([3, 2, 1]);
    await noViolations();
  });

  it('leaves omitted tasks after the listed ones and ignores the other kind', async () => {
    const a = await tools.addTask({ title: 'a', kind: 'must_do', priority: 1 });
    const b = await tools.addTask({ title: 'b', kind: 'must_do', priority: 5 });
    const other = await tools.addTask({ title: 'z', kind: 'want_to_do', priority: 2 });
    const ordered = await tools.reorderTasks({ kind: 'must_do', orderedIds: [String(a.id)] });
    expect(ordered.map((t) => t.title)).toEqual(['a', 'b']);
    expect(ordered.map((t) => t.priority)).toEqual([2, 1]);
    expect(String(b.id)).toBe(String(ordered[1].id));
    const untouched = (await tools.listTasks({ kind: 'want_to_do' }))[0];
    expect(untouched.priority).toBe(2);
    expect(untouched.clock).toBe(other.clock);
  });

  it('rejects an id that is not a live task of that kind', async () => {
    await tools.addTask({ title: 'a', kind: 'must_do' });
    await expect(tools.reorderTasks({ kind: 'must_do', orderedIds: ['nope'] })).rejects.toThrow(
      /not found/,
    );
  });
});

describe('bulk task tools', () => {
  it('updates many tasks in one write', async () => {
    const a = await tools.addTask({ title: 'a', kind: 'must_do' });
    const b = await tools.addTask({ title: 'b', kind: 'must_do' });
    const updated = await tools.bulkUpdateTasks({
      updates: [
        { id: String(a.id), memo: 'x' },
        { id: String(b.id), estimatedMinutes: 30 },
      ],
    });
    expect(updated.map((t) => t.title)).toEqual(['a', 'b']);
    expect(updated[0].memo).toBe('x');
    expect(updated[0].estimatedMinutes).toBe(0);
    expect(updated[1].estimatedMinutes).toBe(30);
  });

  it('writes nothing when one update is invalid', async () => {
    const a = await tools.addTask({ title: 'a', kind: 'must_do' });
    await expect(
      tools.bulkUpdateTasks({
        updates: [
          { id: String(a.id), memo: 'x' },
          { id: 'nope', memo: 'y' },
        ],
      }),
    ).rejects.toThrow(/not found/);
    expect((await tools.getTask({ id: String(a.id) })).memo).toBe('');
  });

  it('tombstones many tasks at once and writes nothing on an unknown id', async () => {
    const a = await tools.addTask({ title: 'a', kind: 'must_do' });
    const b = await tools.addTask({ title: 'b', kind: 'must_do' });
    await expect(
      tools.bulkDeleteTasks({ ids: [String(a.id), 'nope'] }),
    ).rejects.toThrow(/not found/);
    expect(await tools.listTasks({})).toHaveLength(2);
    const result = await tools.bulkDeleteTasks({ ids: [String(a.id), String(b.id)] });
    expect(result.deleted).toBe(2);
    expect(await tools.listTasks({})).toHaveLength(0);
    const doc = await store.read();
    expect(doc.taskMaster.tasks.every((t) => typeof t.deletedAt === 'string')).toBe(true);
  });
});

describe('update_task category sanitising', () => {
  it('drops a category that does not belong to the new kind', async () => {
    const category = await tools.addCategory({ kind: 'must_do', name: '仕事X' });
    const task = await tools.addTask({
      title: 'a',
      kind: 'must_do',
      categoryId: String(category.id),
    });
    const moved = await tools.updateTask({ id: String(task.id), kind: 'want_to_do' });
    expect(moved.kind).toBe('want_to_do');
    expect(moved.categoryId).toBeNull();
  });

  it('keeps the category when the lists are shared', async () => {
    await tools.setShareCategories({ enabled: true });
    const category = await tools.addCategory({ kind: 'must_do', name: '共有X' });
    const task = await tools.addTask({
      title: 'a',
      kind: 'must_do',
      categoryId: String(category.id),
    });
    const moved = await tools.updateTask({ id: String(task.id), kind: 'want_to_do' });
    expect(moved.categoryId).toBe(String(category.id));
  });
});

describe('merge_categories', () => {
  it('moves tasks onto the target and tombstones the source', async () => {
    const source = await tools.addCategory({ kind: 'must_do', name: '元' });
    const target = await tools.addCategory({ kind: 'must_do', name: '先' });
    const task = await tools.addTask({
      title: 'a',
      kind: 'must_do',
      categoryId: String(source.id),
    });
    const result = await tools.mergeCategories({
      kind: 'must_do',
      sourceId: String(source.id),
      targetId: String(target.id),
    });
    expect(result.movedTasks).toBe(1);
    expect((await tools.getTask({ id: String(task.id) })).categoryId).toBe(String(target.id));
    const ids = (await tools.listCategories({ kind: 'must_do' })).map((c) => c.id);
    expect(ids).toContain(String(target.id));
    expect(ids).not.toContain(String(source.id));
    await noViolations();
  });

  it('refuses merging a category into itself or an unknown id', async () => {
    const source = await tools.addCategory({ kind: 'must_do', name: '元' });
    await expect(
      tools.mergeCategories({ kind: 'must_do', sourceId: String(source.id), targetId: String(source.id) }),
    ).rejects.toThrow(/differ/);
    await expect(
      tools.mergeCategories({ kind: 'must_do', sourceId: String(source.id), targetId: 'nope' }),
    ).rejects.toThrow(/not found/);
  });
});

describe('settings', () => {
  it('reads and flips shareCategories, bumping the clock', async () => {
    const before = await tools.getSettings();
    expect(before.shareCategories).toBe(false);
    const after = await tools.setShareCategories({ enabled: true });
    expect(after.shareCategories).toBe(true);
    expect(after.clock).not.toBe(before.clock);
    expect(after.migrated).toBe(false);
    expect((await tools.getSettings()).shareCategories).toBe(true);
  });

  it('is a no-op when the value already matches', async () => {
    const before = await tools.getSettings();
    const same = await tools.setShareCategories({ enabled: false });
    expect(same.clock).toBe(before.clock);
  });

  it('merges both category lists into one namespace when sharing is enabled', async () => {
    await tools.addCategory({ kind: 'must_do', name: '長い方' });
    const wantOnly = await tools.listCategories({ kind: 'want_to_do' });
    const task = await tools.addTask({
      title: 'a',
      kind: 'want_to_do',
      categoryId: String(wantOnly[0].id),
    });
    await tools.setShareCategories({ enabled: true, strategy: 'keepMustDo' });
    const must = await tools.listCategories({ kind: 'must_do' });
    const want = await tools.listCategories({ kind: 'want_to_do' });
    expect(want.map((c) => c.name).sort()).toEqual(must.map((c) => c.name).sort());
    // The want-to-do category the merge dropped must not stay referenced.
    expect((await tools.getTask({ id: String(task.id) })).categoryId).toBeNull();
    await noViolations();
  });

  it('keeps the must-do snapshot in both lists when sharing is turned off', async () => {
    await tools.setShareCategories({ enabled: true });
    await tools.addCategory({ kind: 'must_do', name: '共有Y' });
    await tools.setShareCategories({ enabled: false });
    const must = (await tools.listCategories({ kind: 'must_do' })).map((c) => c.name).sort();
    const want = (await tools.listCategories({ kind: 'want_to_do' })).map((c) => c.name).sort();
    expect(want).toEqual(must);
    expect(must).toContain('共有Y');
    await noViolations();
  });
});

describe('daily plan lifecycle', () => {
  it('creates a plan for a date idempotently', async () => {
    const plan = await tools.createDailyPlan({ date });
    const again = await tools.createDailyPlan({ date });
    expect(again.id).toBe(plan.id);
    expect((await tools.listDailyPlans({ from: date, to: date })).length).toBe(1);
  });

  it('deletes a plan with its slots and assignments', async () => {
    const slot = await tools.addFreeSlot(slotArgs());
    const task = await tools.addTask({ title: 'a', kind: 'must_do' });
    await tools.assignTask({
      slotId: String(slot.id),
      taskId: String(task.id),
      startAt: `${date}T10:00:00+09:00`,
      endAt: `${date}T11:00:00+09:00`,
    });
    const result = await tools.deleteDailyPlan({ date });
    expect(result).toEqual({ date, deleted: true, slots: 1, assignments: 1 });
    expect(await tools.listDailyPlans({ from: date, to: date })).toEqual([]);
    const doc = await store.read();
    expect(doc.dailyPlan.slots.every((s) => typeof s.deletedAt === 'string')).toBe(true);
    expect(doc.dailyPlan.assignments.every((a) => typeof a.deletedAt === 'string')).toBe(true);
    await expect(tools.deleteDailyPlan({ date })).rejects.toThrow(/no plan/);
    await noViolations();
  });

  it('moves a plan to another day and empties the source', async () => {
    const slot = await tools.addFreeSlot(slotArgs());
    const task = await tools.addTask({ title: 'a', kind: 'must_do' });
    await tools.assignTask({
      slotId: String(slot.id),
      taskId: String(task.id),
      startAt: `${date}T10:00:00+09:00`,
      endAt: `${date}T11:00:00+09:00`,
    });
    const moved = await tools.moveDailyPlan({ fromDate: date, toDate: '2026-09-10' });
    expect(moved.plan.date).toBe('2026-09-10');
    expect(moved.slots).toHaveLength(1);
    expect(moved.assignments).toHaveLength(1);
    expect(String(moved.slots[0].startAt)).toBe('2026-09-10T01:00:00.000Z');
    const source = await tools.getDailyPlan({ date });
    expect(source.plan).toBeNull();
    const target = await tools.getDailyPlan({ date: '2026-09-10' });
    expect(target.slots[0].assignments).toHaveLength(1);
    await noViolations();
  });

  it('copies a plan backwards in time too', async () => {
    await tools.addFreeSlot(slotArgs());
    const copied = await tools.copyDailyPlan({ fromDate: date, toDate: '2026-09-08' });
    expect(String(copied.slots[0].startAt)).toBe('2026-09-08T01:00:00.000Z');
  });
});

describe('move_assignment', () => {
  const setup = async () => {
    const early = await tools.addFreeSlot(slotArgs(date, '09:00', '12:00'));
    const late = await tools.addFreeSlot(slotArgs(date, '13:00', '18:00'));
    const one = await tools.addTask({ title: 'one', kind: 'must_do' });
    const two = await tools.addTask({ title: 'two', kind: 'must_do' });
    const a = await tools.assignTask({
      slotId: String(early.id),
      taskId: String(one.id),
      startAt: `${date}T09:00:00+09:00`,
      endAt: `${date}T10:00:00+09:00`,
    });
    const b = await tools.assignTask({
      slotId: String(late.id),
      taskId: String(two.id),
      startAt: `${date}T13:00:00+09:00`,
      endAt: `${date}T14:00:00+09:00`,
    });
    return { early, late, a, b };
  };

  it('moves an assignment into another slot, repacking from the slot start', async () => {
    const { early, late, a } = await setup();
    const moved = await tools.moveAssignment({
      id: String(a.id),
      targetSlotId: String(late.id),
    });
    expect(moved.slotId).toBe(String(late.id));
    // Appended after the one hour that already sits at the head of the slot.
    expect(String(moved.startAt)).toBe('2026-09-09T05:00:00.000Z');
    expect(String(moved.endAt)).toBe('2026-09-09T06:00:00.000Z');
    expect(moved.sortOrder).toBe(1);
    const plan = await tools.getDailyPlan({ date });
    const earlySlot = plan.slots.find((s) => s.id === early.id)!;
    expect(earlySlot.assignments).toHaveLength(0);
    await noViolations();
  });

  it('inserts before a named assignment, reordering inside one slot', async () => {
    const { late, a, b } = await setup();
    const moved = await tools.moveAssignment({
      id: String(a.id),
      targetSlotId: String(late.id),
      beforeAssignmentId: String(b.id),
    });
    expect(moved.sortOrder).toBe(0);
    expect(String(moved.startAt)).toBe('2026-09-09T04:00:00.000Z');
    const plan = await tools.getDailyPlan({ date });
    const lateSlot = plan.slots.find((s) => s.id === late.id)!;
    expect(lateSlot.assignments.map((x) => x.id)).toEqual([String(a.id), String(b.id)]);
    await noViolations();
  });

  it('moves an assignment to a slot on another day', async () => {
    const { a } = await setup();
    const other = await tools.addFreeSlot(slotArgs('2026-09-11', '08:00', '12:00'));
    const moved = await tools.moveAssignment({
      id: String(a.id),
      targetSlotId: String(other.id),
    });
    expect(moved.dailyPlanId).toBe(String(other.dailyPlanId));
    expect(String(moved.startAt)).toBe('2026-09-10T23:00:00.000Z');
    await noViolations();
  });

  it('refuses unknown ids and a target that cannot hold the assignment', async () => {
    const { late, a } = await setup();
    await expect(
      tools.moveAssignment({ id: 'nope', targetSlotId: String(late.id) }),
    ).rejects.toThrow(/assignment nope not found/);
    await expect(
      tools.moveAssignment({ id: String(a.id), targetSlotId: 'nope' }),
    ).rejects.toThrow(/slot nope not found/);
    await expect(
      tools.moveAssignment({
        id: String(a.id),
        targetSlotId: String(late.id),
        beforeAssignmentId: 'nope',
      }),
    ).rejects.toThrow(/nope/);
    const tiny = await tools.addFreeSlot(slotArgs('2026-09-12', '08:00', '08:30'));
    await expect(
      tools.moveAssignment({ id: String(a.id), targetSlotId: String(tiny.id) }),
    ).rejects.toThrow(/exceeds slot/);
  });
});
