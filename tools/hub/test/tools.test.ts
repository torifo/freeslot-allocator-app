import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { HlcClock } from '../src/hlc.js';
import { FileStore } from '../src/store.js';
import { HubTools, pushLive } from '../src/tools.js';

let dir: string;
let store: FileStore;
let tools: HubTools;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'hub-tools-'));
  store = new FileStore(dir, 'hub-0000');
  tools = new HubTools(store, new HlcClock('hub-0000', () => 1000));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

const slotArgs = (date = '2026-09-09') => ({
  date,
  startAt: `${date}T10:00:00+09:00`,
  endAt: `${date}T12:00:00+09:00`,
});

describe('tasks', () => {
  it('add, list, update, delete round trip with tombstone', async () => {
    const added = await tools.addTask({ title: 'buy milk', kind: 'must_do', priority: 3 });
    expect(added.id).toMatch(/^task-\d+-0000-[0-9a-f]{6}$/);
    expect((await tools.listTasks({})).map((t) => t.title)).toEqual(['buy milk']);
    await tools.updateTask({ id: added.id, title: 'buy oat milk' });
    expect(await tools.listTasks({ query: 'oat' })).toHaveLength(1);
    await tools.deleteTask({ id: added.id });
    expect(await tools.listTasks({})).toEqual([]);
    const raw = await tools.exportData();
    expect(raw.taskMaster.tasks[0].deletedAt).not.toBeNull();
    expect(Object.keys(raw.taskMaster.tasks[0]).sort()).toEqual([
      'clock', 'deletedAt', 'id', 'migrated', 'updatedAt',
    ]);
  });

  it('rejects an empty title and an unknown category', async () => {
    await expect(tools.addTask({ title: '  ', kind: 'must_do' })).rejects.toThrow(/title/);
    await expect(tools.addTask({ title: 'x', kind: 'must_do', categoryId: 'nope' })).rejects.toThrow(/category/);
  });

  it('bulk adds and filters by kind and category', async () => {
    const created = await tools.bulkAddTasks({
      tasks: [
        { title: 'a', kind: 'must_do', categoryId: 'must-work' },
        { title: 'b', kind: 'want_to_do' },
      ],
    });
    expect(created).toHaveLength(2);
    expect(await tools.listTasks({ kind: 'want_to_do' })).toHaveLength(1);
    expect(await tools.listTasks({ categoryId: 'must-work' })).toHaveLength(1);
  });

  it('stamps every write with a fresh clock and no migrated flag', async () => {
    const first = await tools.addTask({ title: 'a', kind: 'must_do' });
    const second = await tools.addTask({ title: 'b', kind: 'must_do' });
    expect(first.migrated).toBe(false);
    expect(String(second.clock) > String(first.clock)).toBe(true);
    expect(first.deletedAt).toBeNull();
  });

  it('reports a missing task', async () => {
    await expect(tools.updateTask({ id: 'ghost' })).rejects.toThrow(/not found/);
    await expect(tools.deleteTask({ id: 'ghost' })).rejects.toThrow(/not found/);
  });
});

describe('categories', () => {
  it('rejects duplicate names within a kind', async () => {
    await expect(tools.addCategory({ kind: 'must_do', name: '仕事' })).rejects.toThrow(/duplicate/);
    const c = await tools.addCategory({ kind: 'must_do', name: '運動' });
    expect((await tools.listCategories({ kind: 'must_do' })).some((x) => x.id === c.id)).toBe(true);
  });

  it('renames and deletes, detaching the tasks that used it', async () => {
    const category = await tools.addCategory({ kind: 'must_do', name: '運動' });
    const task = await tools.addTask({ title: 'run', kind: 'must_do', categoryId: category.id });
    const renamed = await tools.updateCategory({ kind: 'must_do', id: category.id, name: '運動2' });
    expect(renamed.name).toBe('運動2');
    await tools.deleteCategory({ kind: 'must_do', id: category.id });
    expect(await tools.listCategories({ kind: 'must_do' })).toHaveLength(3);
    expect((await tools.listTasks({}))[0]).toMatchObject({ id: task.id, categoryId: null });
  });

  it('treats both lists as one namespace when categories are shared', async () => {
    await store.update((doc) => {
      doc.taskMaster.settings.shareCategories = true;
      return doc;
    });
    await expect(tools.addCategory({ kind: 'must_do', name: '趣味' })).rejects.toThrow(/duplicate/);
    const created = await tools.addCategory({ kind: 'must_do', name: '運動' });
    expect((await tools.listCategories({ kind: 'want_to_do' })).some((c) => c.id === created.id)).toBe(true);
  });
});

describe('daily plan', () => {
  it('creates slots and assignments and enforces invariants', async () => {
    const slot = await tools.addFreeSlot({ ...slotArgs(), label: 'morning' });
    const task = await tools.addTask({ title: 'read', kind: 'want_to_do' });
    const a = await tools.assignTask({
      slotId: slot.id, taskId: task.id,
      startAt: '2026-09-09T10:00:00+09:00', endAt: '2026-09-09T11:00:00+09:00',
    });
    expect(a.sortOrder).toBe(0);
    await expect(tools.assignTask({
      slotId: slot.id, taskId: task.id,
      startAt: '2026-09-09T11:30:00+09:00', endAt: '2026-09-09T13:00:00+09:00',
    })).rejects.toThrow(/assignment_outside_slot/);
    const plan = await tools.getDailyPlan({ date: '2026-09-09' });
    expect(plan.slots[0].assignments).toHaveLength(1);
    expect(await tools.listDailyPlans({ from: '2026-09-01', to: '2026-09-30' })).toHaveLength(1);
  });

  it('rejects overlapping slots and reversed times', async () => {
    await tools.addFreeSlot(slotArgs());
    await expect(tools.addFreeSlot({
      date: '2026-09-09',
      startAt: '2026-09-09T11:00:00+09:00', endAt: '2026-09-09T13:00:00+09:00',
    })).rejects.toThrow(/overlaps/);
    await expect(tools.addFreeSlot({
      date: '2026-09-10',
      startAt: '2026-09-10T13:00:00+09:00', endAt: '2026-09-10T11:00:00+09:00',
    })).rejects.toThrow(/end after it starts/);
  });

  it('rejects overlapping assignments in one slot', async () => {
    const slot = await tools.addFreeSlot(slotArgs());
    const task = await tools.addTask({ title: 'read', kind: 'want_to_do' });
    await tools.assignTask({
      slotId: slot.id, taskId: task.id,
      startAt: '2026-09-09T10:00:00+09:00', endAt: '2026-09-09T11:00:00+09:00',
    });
    await expect(tools.assignTask({
      slotId: slot.id, taskId: task.id,
      startAt: '2026-09-09T10:30:00+09:00', endAt: '2026-09-09T11:30:00+09:00',
    })).rejects.toThrow(/assignment_overlap/);
  });

  it('normalizes sortOrder to time order and unassigns', async () => {
    const slot = await tools.addFreeSlot(slotArgs());
    const task = await tools.addTask({ title: 'read', kind: 'want_to_do' });
    const late = await tools.assignTask({
      slotId: slot.id, taskId: task.id,
      startAt: '2026-09-09T11:00:00+09:00', endAt: '2026-09-09T11:30:00+09:00',
    });
    const early = await tools.assignTask({
      slotId: slot.id, taskId: task.id,
      startAt: '2026-09-09T10:00:00+09:00', endAt: '2026-09-09T10:30:00+09:00',
    });
    expect(early.sortOrder).toBe(0);
    const plan = await tools.getDailyPlan({ date: '2026-09-09' });
    expect(plan.slots[0].assignments.map((x) => x.id)).toEqual([early.id, late.id]);
    const moved = await tools.updateAssignment({ id: early.id, memo: 'later' });
    expect(moved.memo).toBe('later');
    await tools.unassign({ id: late.id });
    expect((await tools.getDailyPlan({ date: '2026-09-09' })).slots[0].assignments).toHaveLength(1);
  });

  it('updates and deletes a slot, tombstoning its assignments', async () => {
    const slot = await tools.addFreeSlot(slotArgs());
    const task = await tools.addTask({ title: 'read', kind: 'want_to_do' });
    await tools.assignTask({
      slotId: slot.id, taskId: task.id,
      startAt: '2026-09-09T10:00:00+09:00', endAt: '2026-09-09T11:00:00+09:00',
    });
    const updated = await tools.updateFreeSlot({ id: slot.id, label: 'am' });
    expect(updated.label).toBe('am');
    await tools.deleteFreeSlot({ id: slot.id });
    const doc = await tools.exportData();
    expect(doc.dailyPlan.slots.every((s) => s.deletedAt !== null)).toBe(true);
    expect(doc.dailyPlan.assignments.every((a) => a.deletedAt !== null)).toBe(true);
  });

  it('copy_daily_plan uses deterministic ids', async () => {
    await tools.addFreeSlot(slotArgs());
    const first = await tools.copyDailyPlan({ fromDate: '2026-09-09', toDate: '2026-09-10' });
    expect(first.slots[0].id).toMatch(/^slot-[0-9a-f]{16}$/);
    expect(first.slots[0].startAt).toBe('2026-09-10T01:00:00.000Z');
    await expect(tools.copyDailyPlan({ fromDate: '2026-09-09', toDate: '2026-09-09' }))
      .rejects.toThrow(/must differ/);
  });

  it('shifts assignments by the day offset and replaces the target day', async () => {
    const slot = await tools.addFreeSlot(slotArgs());
    const task = await tools.addTask({ title: 'read', kind: 'want_to_do' });
    await tools.assignTask({
      slotId: slot.id, taskId: task.id,
      startAt: '2026-09-09T10:00:00+09:00', endAt: '2026-09-09T11:00:00+09:00',
    });
    const copied = await tools.copyDailyPlan({ fromDate: '2026-09-09', toDate: '2026-09-11' });
    expect(copied.assignments[0].startAt).toBe('2026-09-11T01:00:00.000Z');
    const again = await tools.copyDailyPlan({
      fromDate: '2026-09-09', toDate: '2026-09-11', replaceExisting: true,
    });
    expect((await tools.getDailyPlan({ date: '2026-09-11' })).slots).toHaveLength(1);
    expect(again.slots[0].id).not.toBe(copied.slots[0].id);
  });

  it('bumps the copy generation after copy -> delete -> copy', async () => {
    await tools.addFreeSlot(slotArgs());
    const first = await tools.copyDailyPlan({ fromDate: '2026-09-09', toDate: '2026-09-10' });
    await tools.deleteFreeSlot({ id: first.slots[0].id });
    const second = await tools.copyDailyPlan({ fromDate: '2026-09-09', toDate: '2026-09-10' });
    expect(second.slots[0].id).not.toBe(first.slots[0].id);
    await tools.deleteFreeSlot({ id: second.slots[0].id });
    const third = await tools.copyDailyPlan({ fromDate: '2026-09-09', toDate: '2026-09-10' });
    expect(new Set([first.slots[0].id, second.slots[0].id, third.slots[0].id]).size).toBe(3);
  });
});

describe('weekly report', () => {
  it('sums free and assigned minutes by kind and category', async () => {
    const slot = await tools.addFreeSlot(slotArgs());
    const task = await tools.addTask({ title: 'read', kind: 'want_to_do', categoryId: 'want-hobby' });
    await tools.assignTask({
      slotId: slot.id, taskId: task.id,
      startAt: '2026-09-09T10:00:00+09:00', endAt: '2026-09-09T11:00:00+09:00',
    });
    const report = await tools.weeklyReport({ weekStart: '2026-09-07' });
    expect(report).toMatchObject({ days: 1, freeMinutes: 120, assignedMinutes: 60 });
    expect(report.byKind.want_to_do).toBe(60);
    expect(report.byCategory['趣味']).toBe(60);
  });
});

describe('durability', () => {
  it('does not persist a document that violates an invariant', async () => {
    const slot = await tools.addFreeSlot(slotArgs());
    const before = readFileSync(store.filePath, 'utf8');
    await expect(tools.updateFreeSlot({
      id: slot.id, startAt: '2026-09-09T14:00:00+09:00',
    })).rejects.toThrow();
    expect(readFileSync(store.filePath, 'utf8')).toBe(before);
    expect((await tools.exportData()).dailyPlan.slots[0].startAt).toBe(slot.startAt);
  });

  it('retires a tombstone when its id comes back as a live record', () => {
    const tombstone = {
      id: 'slot-1', clock: '1-0-hub-0000',
      updatedAt: '2026-09-09T00:00:00.000Z', deletedAt: '2026-09-09T00:00:00.000Z', migrated: false,
    };
    const list = [tombstone, { ...tombstone, id: 'slot-2' }];
    pushLive(list, { ...tombstone, deletedAt: null, label: 'back' });
    expect(list.map((e) => e.id)).toEqual(['slot-2', 'slot-1']);
    expect(list.filter((e) => e.id === 'slot-1')).toHaveLength(1);
    expect(list[1]).toMatchObject({ deletedAt: null, label: 'back' });
  });

  it('keeps a deleted copy tombstoned when the same day is copied again', async () => {
    await tools.addFreeSlot(slotArgs());
    const first = await tools.copyDailyPlan({ fromDate: '2026-09-09', toDate: '2026-09-10' });
    await tools.deleteFreeSlot({ id: first.slots[0].id });
    const second = await tools.copyDailyPlan({ fromDate: '2026-09-09', toDate: '2026-09-10' });
    const doc = await tools.exportData();
    const ids = doc.dailyPlan.slots.map((s) => s.id);
    expect(new Set(ids).size).toBe(ids.length);
    expect(doc.dailyPlan.slots.find((s) => s.id === first.slots[0].id)?.deletedAt).not.toBeNull();
    expect(doc.dailyPlan.slots.find((s) => s.id === second.slots[0].id)?.deletedAt).toBeNull();
  });

  it('reports file path and undoes the last write', async () => {
    await tools.addTask({ title: 'a', kind: 'must_do' });
    await tools.addTask({ title: 'b', kind: 'must_do' });
    expect(await tools.undoLastWrite()).toBe(true);
    expect(await tools.listTasks({})).toHaveLength(1);
    const status = await tools.syncStatus();
    expect(status.dataFile).toContain('data.json');
    expect(status).toMatchObject({ warning: null, lan: null, fingerprint: null, devices: [] });
    expect(typeof status.modifiedAt).toBe('string');
  });
});
