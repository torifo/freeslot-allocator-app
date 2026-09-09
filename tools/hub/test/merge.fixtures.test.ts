import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { merge, type MergeOptions } from '../src/merge.js';
import type { ConflictJson, SyncDocumentJson } from '../src/model.js';

const here = dirname(fileURLToPath(import.meta.url));
const dir = join(here, '../../../test/fixtures/sync_merge');
const manifest = JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8')) as string[];

function normalize(value: unknown): unknown {
  if (Array.isArray(value)) {
    const items = value.map(normalize) as Array<Record<string, unknown>>;
    if (items.every((i) => i && typeof i === 'object' && 'id' in i)) {
      items.sort((a, b) => String(a.id).localeCompare(String(b.id)));
    }
    return items;
  }
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>).map(([k, v]) => [k, normalize(v)]),
    );
  }
  return value;
}

/**
 * Every id a document holds, live or tombstoned — conflict records included,
 * because they are ordinary entities as far as the merge is concerned and
 * losing one loses the user's only record of a version that was overwritten.
 */
function idsOf(doc: SyncDocumentJson): Set<string> {
  const out = new Set<string>();
  for (const section of [doc.taskMaster, doc.dailyPlan] as unknown as Array<Record<string, unknown>>) {
    for (const value of Object.values(section)) {
      if (!Array.isArray(value)) continue;
      for (const entry of value) {
        const id = (entry as { id?: unknown }).id;
        if (typeof id === 'string') out.add(id);
      }
    }
  }
  for (const c of doc.conflicts ?? []) out.add(c.id);
  return out;
}

/** The subset of a conflict record the fixtures pin; snapshots are checked elsewhere. */
const briefOf = (c: ConflictJson) => ({
  id: c.id,
  entityType: c.entityType,
  entityId: c.entityId,
  winner: { side: c.winner.side, deviceId: c.winner.deviceId, clock: c.winner.clock },
  loser: { side: c.loser.side, deviceId: c.loser.deviceId, clock: c.loser.clock },
  resolution: c.resolution ?? null,
});

describe('merge fixtures', () => {
  for (const name of manifest) {
    const fx = JSON.parse(readFileSync(join(dir, name), 'utf8'));
    it(fx.name, () => {
      const a = fx.a as SyncDocumentJson;
      const b = fx.b as SyncDocumentJson;
      // A fixture with no `options` merges exactly as it did before Plan 3b:
      // detection is off, and that is what keeps the first eight cases honest.
      const options = fx.options as MergeOptions | undefined;
      const ab = merge(a, b, options);
      const ba = merge(b, a, options);
      expect(normalize(ab.document.taskMaster)).toEqual(normalize(fx.expected.taskMaster));
      expect(normalize(ab.document.dailyPlan)).toEqual(normalize(fx.expected.dailyPlan));
      expect(normalize(ba.document.taskMaster)).toEqual(normalize(ab.document.taskMaster));
      expect(normalize(ba.document.dailyPlan)).toEqual(normalize(ab.document.dailyPlan));
      expect(ab.warnings).toEqual(fx.expectedWarnings ?? []);
      expect(normalize(merge(ab.document, b, options).document.taskMaster)).toEqual(
        normalize(ab.document.taskMaster),
      );

      // Nothing is ever dropped: every id either side held survives the merge,
      // live or as a tombstone (design B-2). Applied to every fixture, old
      // ones included, so a new case gets the guard for free.
      const before = new Set([...idsOf(a), ...idsOf(b)]);
      for (const id of before) expect(idsOf(ab.document).has(id)).toBe(true);
      for (const id of before) expect(idsOf(ba.document).has(id)).toBe(true);

      // Detection is not commutative in the id — swapping the arguments swaps
      // which side is `hub` — but the set of entities in conflict is.
      expect(ab.conflicts.map((c) => c.entityId).sort()).toEqual(
        ba.conflicts.map((c) => c.entityId).sort(),
      );
      if (fx.expectedConflicts) {
        expect((ab.document.conflicts ?? []).map(briefOf)).toEqual(fx.expectedConflicts);
      } else {
        expect(ab.document.conflicts).toBeUndefined();
      }
      if (fx.expectedDetectedIds) {
        expect(ab.conflicts.map((c) => c.id)).toEqual(fx.expectedDetectedIds);
      }

      // The records themselves are fully commutative: `side` is read off the
      // HLC device id, so swapping the arguments no longer swaps the labels.
      expect(normalize(ba.document.conflicts ?? [])).toEqual(normalize(ab.document.conflicts ?? []));

      // Cross-language snapshot parity: the fixture pins the exact map each
      // side stored, and the Dart runner asserts the very same JSON.
      if (fx.expectedSnapshots) {
        const snapshots = Object.fromEntries(
          (ab.document.conflicts ?? []).map((c) => [
            c.id,
            { winner: c.winner.snapshot, loser: c.loser.snapshot },
          ]),
        );
        expect(snapshots).toEqual(fx.expectedSnapshots);
      }
    });
  }
});

describe('hub-only fixtures', () => {
  const hubOnlyDir = join(here, 'fixtures/hub-only/sync_merge');
  const hubOnlyNames = ['09_assignment_without_slot_id.json'];

  for (const name of hubOnlyNames) {
    const fx = JSON.parse(readFileSync(join(hubOnlyDir, name), 'utf8'));
    it(fx.name, () => {
      const a = fx.a as SyncDocumentJson;
      const b = fx.b as SyncDocumentJson;
      const ab = merge(a, b);
      const ba = merge(b, a);
      expect(normalize(ab.document.taskMaster)).toEqual(normalize(fx.expected.taskMaster));
      expect(normalize(ab.document.dailyPlan)).toEqual(normalize(fx.expected.dailyPlan));
      expect(normalize(ba.document.taskMaster)).toEqual(normalize(ab.document.taskMaster));
      expect(normalize(ba.document.dailyPlan)).toEqual(normalize(ab.document.dailyPlan));
      expect(ab.warnings).toEqual(fx.expectedWarnings ?? []);
      expect(normalize(merge(ab.document, b).document.taskMaster)).toEqual(
        normalize(ab.document.taskMaster),
      );
    });
  }
});

describe('merge determinism', () => {
  const base = (deviceId: string): SyncDocumentJson => ({
    version: 2,
    exportedAt: '2026-09-08T00:00:00.000Z',
    deviceId,
    taskMaster: {
      tasks: [],
      mustDoCategories: [],
      wantToDoCategories: [],
      settings: {
        shareCategories: false,
        clock: '0-0-migrated',
        updatedAt: '1970-01-01T00:00:00.000Z',
        deletedAt: null,
        migrated: true,
      },
    },
    dailyPlan: { plans: [], slots: [], assignments: [] },
  });

  it('breaks a clock+hash tie on the smaller canonical meta key', () => {
    const a = base('a');
    const b = base('b');
    a.taskMaster.mustDoCategories = [
      { id: 'c1', name: '仕事', clock: '0-0-migrated', updatedAt: '2026-01-02T00:00:00.000Z', deletedAt: null, migrated: true },
    ];
    b.taskMaster.mustDoCategories = [
      { id: 'c1', name: '仕事', clock: '0-0-migrated', updatedAt: '2026-01-01T00:00:00.000Z', deletedAt: null, migrated: true },
    ];
    // Both records carry the migrated clock and identical content, so the
    // smaller serialized meta (the earlier updatedAt) wins in both directions.
    expect(merge(a, b).document.taskMaster.mustDoCategories[0].updatedAt).toBe('2026-01-01T00:00:00.000Z');
    expect(merge(b, a).document.taskMaster.mustDoCategories[0].updatedAt).toBe('2026-01-01T00:00:00.000Z');
  });

  it('keeps the envelope identity of the first argument', () => {
    const a = { ...base('a'), lastSyncAt: '2026-09-08T01:00:00.000Z', purgedBefore: '2026-01-01T00:00:00.000Z' };
    const b = { ...base('b'), exportedAt: '2026-09-09T00:00:00.000Z', lastSyncAt: null, purgedBefore: '2026-02-01T00:00:00.000Z' };
    const out = merge(a, b).document;
    expect(out.deviceId).toBe('a');
    expect(out.lastSyncAt).toBe('2026-09-08T01:00:00.000Z');
    expect(out.exportedAt).toBe('2026-09-09T00:00:00.000Z');
    expect(out.purgedBefore).toBe('2026-02-01T00:00:00.000Z');
    expect(out.version).toBe(2);
  });
});
