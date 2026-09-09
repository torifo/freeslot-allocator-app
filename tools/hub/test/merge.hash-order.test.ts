import { describe, expect, it, vi } from 'vitest';
import * as hash from '../src/hash.js';
import { merge } from '../src/merge.js';
import { emptyDocument, type Entity, type SyncDocumentJson } from '../src/model.js';

const now = 1_800_000_000_000;
const iso = (ms: number) => new Date(ms).toISOString();
const AGREED = iso(now - 60_000);

const task = (id: string, title: string, clock: string, updatedMs: number): Entity => ({
  id, title, kind: 'must_do', priority: 3, createdAt: 'x', memo: '', categoryId: null,
  estimatedMinutes: 0, clock, updatedAt: iso(updatedMs), deletedAt: null, migrated: false,
});

/** Two documents that differ only in their clocks, so nothing forces a hash. */
function pair(tasks: [Entity[], Entity[]]): [SyncDocumentJson, SyncDocumentJson] {
  const doc = (deviceId: string, list: Entity[], clock: string): SyncDocumentJson => {
    const base = emptyDocument(deviceId, new Date(now));
    return {
      ...base,
      taskMaster: {
        ...base.taskMaster,
        mustDoCategories: [],
        wantToDoCategories: [],
        tasks: list,
        // Distinct clocks: an equal-clock settings pair would reach `pick`'s
        // hash tie-break and hide the very call this test counts.
        settings: { shareCategories: false, clock, updatedAt: iso(now - 600_000), deletedAt: null, migrated: false },
      },
      lastSyncAt: AGREED,
    };
  };
  return [doc('hub-0000', tasks[0], '9-0-hub-0000'), doc('android-1', tasks[1], '8-0-android-1')];
}

describe('detection order', () => {
  it('does not hash an entity neither side touched since the agreement point', () => {
    const spy = vi.spyOn(hash, 'contentHash');
    // Both versions predate the agreement, so the timestamp guard alone
    // settles it — hashing here is pure cost on every entity of every sync.
    const old = now - 600_000;
    const [a, b] = pair([
      [task('tsk-1', 'hub title', '9-0-hub-0000', old)],
      [task('tsk-1', 'phone title', '8-0-android-1', old)],
    ]);
    const result = merge(a, b, { lastAgreedAt: AGREED, detectedBy: 'hub-0000', detectedAt: iso(now) });
    expect(result.conflicts).toEqual([]);
    expect(spy).not.toHaveBeenCalled();
    spy.mockRestore();
  });

  it('still hashes when both sides changed after the agreement point', () => {
    const spy = vi.spyOn(hash, 'contentHash');
    const [a, b] = pair([
      [task('tsk-1', 'hub title', '9-0-hub-0000', now)],
      [task('tsk-1', 'phone title', '8-0-android-1', now)],
    ]);
    const result = merge(a, b, { lastAgreedAt: AGREED, detectedBy: 'hub-0000', detectedAt: iso(now) });
    expect(result.conflicts).toHaveLength(1);
    expect(spy).toHaveBeenCalled();
    spy.mockRestore();
  });
});
