import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { FileStore, UnsupportedSchemaError } from '../src/store.js';

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'hub-store-'));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

describe('FileStore', () => {
  it('creates an empty v2 document when missing', async () => {
    const store = new FileStore(dir, 'hub');
    const doc = await store.read();
    expect(doc.version).toBe(2);
    expect(doc.taskMaster.mustDoCategories).toHaveLength(3);
    expect(doc.taskMaster.wantToDoCategories).toHaveLength(3);
    expect(doc.taskMaster.settings.shareCategories).toBe(false);
    expect(existsSync(join(dir, 'data.json'))).toBe(false);
  });

  it('update() writes atomically, keeps .bak, and undo restores it', async () => {
    const store = new FileStore(dir, 'hub');
    await store.update((d) => { d.taskMaster.settings.shareCategories = true; return d; });
    await store.update((d) => { d.taskMaster.settings.shareCategories = false; return d; });
    expect(JSON.parse(readFileSync(join(dir, 'data.json'), 'utf8')).taskMaster.settings.shareCategories).toBe(false);
    expect(JSON.parse(readFileSync(join(dir, 'data.json.bak'), 'utf8')).taskMaster.settings.shareCategories).toBe(true);
    await store.undoLastWrite();
    expect((await store.read()).taskMaster.settings.shareCategories).toBe(true);
    expect(existsSync(join(dir, 'data.json.tmp'))).toBe(false);
    expect(await store.modifiedAt()).toBeInstanceOf(Date);
    expect(store.filePath).toBe(join(dir, 'data.json'));
    expect(store.deviceId).toBe('hub');
  });

  it('quarantines corrupt data and reports a warning', async () => {
    writeFileSync(join(dir, 'data.json'), '{bad');
    const store = new FileStore(dir, 'hub');
    const doc = await store.read();
    expect(doc.taskMaster.tasks).toEqual([]);
    expect(store.lastWarning).toContain('broken');
    expect(readdirSync(dir).some((f) => f.startsWith('data.json.broken-'))).toBe(true);
  });

  it('treats an empty file as no data yet without quarantining', async () => {
    writeFileSync(join(dir, 'data.json'), '   \n');
    const store = new FileStore(dir, 'hub');
    expect((await store.read()).version).toBe(2);
    expect(store.lastWarning).toBeNull();
    expect(readdirSync(dir).some((f) => f.startsWith('data.json.broken-'))).toBe(false);
  });

  it('rejects a document with a newer schema version', async () => {
    writeFileSync(join(dir, 'data.json'), JSON.stringify({ version: 3 }));
    await expect(new FileStore(dir, 'hub').read()).rejects.toThrow(/version 3/);
    await expect(new FileStore(dir, 'hub').read()).rejects.toBeInstanceOf(UnsupportedSchemaError);
  });

  it('rejects a structurally invalid document instead of emptying it', async () => {
    const base = {
      version: 2,
      exportedAt: '2026-09-08T00:00:00.000Z',
      deviceId: 'a',
      taskMaster: { tasks: [], mustDoCategories: [], wantToDoCategories: [], settings: {} },
      dailyPlan: { plans: [], slots: [], assignments: [] },
    };
    const write = (patch: Record<string, unknown>) =>
      writeFileSync(join(dir, 'data.json'), JSON.stringify({ ...base, ...patch }));

    write({ version: '2' });
    await expect(new FileStore(dir, 'hub').read()).rejects.toThrow(/version must be an int/);
    write({ exportedAt: 'not a date' });
    await expect(new FileStore(dir, 'hub').read()).rejects.toThrow(/exportedAt/);
    write({ deviceId: 7 });
    await expect(new FileStore(dir, 'hub').read()).rejects.toThrow(/deviceId must be a String/);
    write({ taskMaster: [] });
    await expect(new FileStore(dir, 'hub').read()).rejects.toThrow(/taskMaster must be a JSON object/);
    write({ dailyPlan: 'x' });
    await expect(new FileStore(dir, 'hub').read()).rejects.toThrow(/dailyPlan must be a JSON object/);
    // Not quarantined: the file is valid JSON, just wrong.
    expect(readdirSync(dir).some((f) => f.startsWith('data.json.broken-'))).toBe(false);
  });

  it('upgrades a v1 document to v2 with migrated meta', async () => {
    writeFileSync(
      join(dir, 'data.json'),
      JSON.stringify({
        version: 1,
        exported_at: '2026-09-08T00:00:00.000Z',
        task_master: {
          tasks: [{ id: 't1', title: 'old' }],
          mustDoCategories: [{ id: 'c1', name: '仕事' }],
          wantToDoCategories: [],
          shareCategories: true,
        },
        daily_plan: { plans: [], slots: [], assignments: [] },
      }),
    );
    const doc = await new FileStore(dir, 'hub').read();
    expect(doc.version).toBe(2);
    expect(doc.taskMaster.tasks[0]).toMatchObject({ id: 't1', title: 'old', clock: '0-0-migrated', migrated: true });
    expect(doc.taskMaster.settings.shareCategories).toBe(true);
    expect(doc.taskMaster.mustDoCategories).toHaveLength(1);
  });

  it('serializes concurrent updates', async () => {
    const store = new FileStore(dir, 'hub');
    await Promise.all(
      Array.from({ length: 10 }, (_, i) =>
        store.update((d) => {
          d.taskMaster.tasks.push({ id: `t${i}`, title: 'x', clock: `${i}-0-hub`, updatedAt: 'x', deletedAt: null, migrated: false });
          return d;
        }),
      ),
    );
    expect((await store.read()).taskMaster.tasks).toHaveLength(10);
  });

  it('blocks while another process holds the data.lock.lock sentinel', async () => {
    const sentinel = join(dir, 'data.lock.lock');
    writeFileSync(join(dir, 'data.lock'), '');
    mkdirSync(sentinel);
    const store = new FileStore(dir, 'hub');
    let done = false;
    const pending = store.update((d) => { d.taskMaster.settings.shareCategories = true; return d; }).then((doc) => { done = true; return doc; });
    await sleep(300);
    expect(done).toBe(false);
    expect(existsSync(join(dir, 'data.json'))).toBe(false);
    rmSync(sentinel, { recursive: true });
    const doc = await pending;
    expect(doc.taskMaster.settings.shareCategories).toBe(true);
  });

  it('reclaims a stale sentinel older than 10 seconds', async () => {
    const sentinel = join(dir, 'data.lock.lock');
    writeFileSync(join(dir, 'data.lock'), '');
    mkdirSync(sentinel);
    const old = new Date(Date.now() - 20_000);
    utimesSync(sentinel, old, old);
    const store = new FileStore(dir, 'hub');
    const doc = await store.update((d) => { d.taskMaster.settings.shareCategories = true; return d; });
    expect(doc.taskMaster.settings.shareCategories).toBe(true);
    expect(existsSync(sentinel)).toBe(false);
  });
});
