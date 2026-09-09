import { describe, expect, it } from 'vitest';
import { merge } from '../src/merge.js';
import { conflictId, emptyDocument, type ConflictJson, type Entity, type SyncDocumentJson } from '../src/model.js';

const AGREED = '2026-09-09T00:00:00.000Z';
const OPTIONS = { lastAgreedAt: AGREED, detectedBy: 'hub-macos', detectedAt: '2026-09-09T03:00:00.000Z' };

const task = (title: string, clock: string, updatedAt: string): Entity => ({
  id: 'tsk-1', title, kind: 'must_do', priority: 3, createdAt: '2026-09-01T00:00:00.000Z',
  memo: '', categoryId: null, estimatedMinutes: 0,
  clock, updatedAt, deletedAt: null, migrated: false,
});

const doc = (deviceId: string, tasks: Entity[], extra: Partial<SyncDocumentJson> = {}): SyncDocumentJson => ({
  ...emptyDocument(deviceId, new Date('2026-09-08T00:00:00.000Z')),
  taskMaster: {
    tasks, mustDoCategories: [], wantToDoCategories: [],
    settings: { shareCategories: false, clock: '0-0-migrated', updatedAt: '1970-01-01T00:00:00.000Z', deletedAt: null, migrated: true },
  },
  ...extra,
});

const hub = task('hub edit', '20-0-hub-macos', '2026-09-09T02:00:00.000Z');
const device = task('device edit', '15-0-android-1', '2026-09-09T01:00:00.000Z');

describe('conflict detection', () => {
  it('does not detect anything when lastAgreedAt is absent', () => {
    expect(merge(doc('a', [hub]), doc('b', [device])).conflicts).toEqual([]);
    expect(merge(doc('a', [hub]), doc('b', [device]), { detectedBy: 'hub-macos' }).conflicts).toEqual([]);
    expect(merge(doc('a', [hub]), doc('b', [device]), { lastAgreedAt: null }).conflicts).toEqual([]);
    expect(merge(doc('a', [hub]), doc('b', [device]), { lastAgreedAt: 'not a date' }).conflicts).toEqual([]);
  });

  it('does not detect when the two sides hold identical content', () => {
    // Same content, different meta: nothing for the user to choose between.
    const other = { ...hub, clock: '19-0-android-1', updatedAt: '2026-09-09T01:59:00.000Z' };
    expect(merge(doc('a', [hub]), doc('b', [other]), OPTIONS).conflicts).toEqual([]);
  });

  it('uses max(updatedAt, clock.physical) so a lagging wall clock still counts as changed', () => {
    // updatedAt is a year behind the agreement, but the HLC's physical part is
    // past it — within a device the HLC only ever moves forward.
    const lagging = task('device edit', `${Date.parse('2026-09-09T01:00:00.000Z')}-0-android-1`, '2025-01-01T00:00:00.000Z');
    expect(merge(doc('a', [hub]), doc('b', [lagging]), OPTIONS).conflicts).toHaveLength(1);
  });

  it('compares with >= so a change exactly at lastAgreedAt is treated as a conflict', () => {
    const exact = task('device edit', '15-0-android-1', AGREED);
    const hubExact = task('hub edit', '20-0-hub-macos', AGREED);
    expect(merge(doc('a', [hubExact]), doc('b', [exact]), OPTIONS).conflicts).toHaveLength(1);
  });

  it('records the winner, the loser and the whole losing snapshot', () => {
    const [conflict] = merge(doc('a', [hub]), doc('b', [device]), OPTIONS).conflicts;
    expect(conflict.id).toBe(conflictId('tsk-1', '20-0-hub-macos', '15-0-android-1'));
    expect(conflict.entityType).toBe('task');
    expect(conflict.winner).toMatchObject({ side: 'hub', deviceId: 'hub-macos', clock: '20-0-hub-macos' });
    expect(conflict.loser).toMatchObject({ side: 'device', deviceId: 'android-1', clock: '15-0-android-1' });
    expect(conflict.loser.snapshot).toEqual(device);
    expect(conflict.detectedBy).toBe('hub-macos');
    expect(conflict.detectedAt).toBe(OPTIONS.detectedAt);
    expect(conflict.resolution).toBeNull();
    expect(conflict.clock).toBe('20-0-hub-macos');
  });

  it('records a delete against an edit, keeping the tombstone shape', () => {
    const tomb: Entity = { id: 'tsk-1', clock: '18-0-android-1', updatedAt: '2026-09-09T01:30:00.000Z', deletedAt: '2026-09-09T01:30:00.000Z', migrated: false };
    const [conflict] = merge(doc('a', [hub]), doc('b', [tomb]), OPTIONS).conflicts;
    expect(conflict.loser.snapshot).toEqual(tomb);
    expect(conflict.winner.snapshot).toEqual(hub);
  });

  it('treats settings as entityId "settings"', () => {
    const a = doc('a', []);
    const b = doc('b', []);
    a.taskMaster.settings = { shareCategories: false, clock: '20-0-hub-macos', updatedAt: '2026-09-09T02:00:00.000Z', deletedAt: null, migrated: false };
    b.taskMaster.settings = { shareCategories: true, clock: '15-0-android-1', updatedAt: '2026-09-09T01:00:00.000Z', deletedAt: null, migrated: false };
    const [conflict] = merge(a, b, OPTIONS).conflicts;
    expect(conflict.entityId).toBe('settings');
    expect(conflict.entityType).toBe('settings');
    expect(conflict.id).toBe(conflictId('settings', '20-0-hub-macos', '15-0-android-1'));
  });

  it('re-detecting the same pair produces the same id and does not add a second record', () => {
    const first = merge(doc('a', [hub]), doc('b', [device]), OPTIONS);
    const again = merge(first.document, doc('b', [device]), { ...OPTIONS, detectedAt: '2026-09-09T04:00:00.000Z' });
    expect(again.document.conflicts).toHaveLength(1);
    // The stored record keeps its original detection time: re-detection is a no-op.
    expect(again.document.conflicts![0].detectedAt).toBe(OPTIONS.detectedAt);
  });

  it('unions existing conflict records by id, letting the larger clock win', () => {
    const base = merge(doc('a', [hub]), doc('b', [device]), OPTIONS).document.conflicts![0];
    const resolved: ConflictJson = { ...base, resolution: 'device', resolvedAt: '2026-09-09T05:00:00.000Z', resolvedBy: 'android-1', clock: '99-0-android-1' };
    const out = merge(doc('a', [hub], { conflicts: [base] }), doc('b', [device], { conflicts: [resolved] }), OPTIONS);
    expect(out.document.conflicts).toHaveLength(1);
    expect(out.document.conflicts![0].resolution).toBe('device');
    // Newly detected is what this merge found, not the union.
    expect(out.conflicts).toEqual([]);
  });

  it('marks a conflict superseded when the live entity clock is greater than both sides', () => {
    const later = task('a later edit', '40-0-hub-macos', '2026-09-09T02:30:00.000Z');
    const open = merge(doc('a', [hub]), doc('b', [device]), OPTIONS).document.conflicts![0];
    const out = merge(doc('a', [later], { conflicts: [open] }), doc('b', [later]), OPTIONS);
    expect(out.document.conflicts![0].resolution).toBe('superseded');
    expect(out.document.conflicts![0].resolvedBy).toBe('hub-macos');
    expect(out.document.conflicts![0].resolvedAt).toBe(OPTIONS.detectedAt);
  });

  it('leaves an already resolved record alone and omits the key when there is nothing to record', () => {
    const out = merge(doc('a', []), doc('b', []), OPTIONS);
    expect(out.document.conflicts).toBeUndefined();
    expect(JSON.stringify(out.document)).not.toContain('conflicts');
  });
});
