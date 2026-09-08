import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { merge } from '../src/merge.js';
import type { SyncDocumentJson } from '../src/model.js';

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

describe('merge fixtures', () => {
  for (const name of manifest) {
    const fx = JSON.parse(readFileSync(join(dir, name), 'utf8'));
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
