import { describe, expect, it } from 'vitest';
import { conflictId, conflictSchema, emptyDocument } from '../src/model.js';
import { documentSchema } from '../src/sync-engine.js';

const side = (deviceId: string, clock: string) => ({
  side: deviceId.startsWith('hub-') ? 'hub' : 'device',
  deviceId,
  clock,
  updatedAt: '2026-09-09T01:00:00.000Z',
  snapshot: { id: 'tsk-1', title: 'x' },
});

describe('conflict model', () => {
  it('derives the id from entityId and both clocks, and nothing else', () => {
    const id = conflictId('tsk-1', '10-0-hub-macos', '9-2-android-3f2a');
    expect(id).toMatch(/^cf-[0-9a-f]{16}$/);
    expect(conflictId('tsk-1', '10-0-hub-macos', '9-2-android-3f2a')).toBe(id);
    expect(conflictId('tsk-2', '10-0-hub-macos', '9-2-android-3f2a')).not.toBe(id);
    // Swapping winner and loser is a different conflict, not a re-detection of the same pair.
    expect(conflictId('tsk-1', '9-2-android-3f2a', '10-0-hub-macos')).not.toBe(id);
  });

  it('pins the exact digest both languages must produce', () => {
    // The Dart test in test/services/sync/conflict_record_test.dart asserts the
    // very same string; a change on one side alone breaks the id parity.
    expect(conflictId('tsk-1', '10-0-hub-macos', '9-2-android-3f2a')).toBe(
      'cf-e47c5a64e1b598dd',
    );
  });

  it('accepts unknown entityType and unknown resolution values (forward compatible)', () => {
    const record = {
      id: 'cf-0000000000000000', entityType: 'quantum-thing', entityId: 'q-1',
      detectedAt: '2026-09-09T02:00:00.000Z', detectedBy: 'hub-macos',
      winner: side('hub-macos', '10-0-hub-macos'), loser: side('android-1', '9-0-android-1'),
      resolution: null, resolvedAt: null, resolvedBy: null,
      clock: '11-0-hub-macos', updatedAt: '2026-09-09T02:00:00.000Z', deletedAt: null, migrated: false,
    };
    expect(conflictSchema.safeParse(record).success).toBe(true);
    expect(conflictSchema.safeParse({ ...record, resolution: 'zzz' }).success).toBe(true);
    expect(conflictSchema.safeParse({ ...record, id: 42 }).success).toBe(false);
    expect(conflictSchema.safeParse({ ...record, winner: { side: 'hub' } }).success).toBe(false);
  });

  it('documentSchema keeps conflicts optional so a Plan 2b client still validates', () => {
    const doc = emptyDocument('a');
    expect('conflicts' in doc).toBe(false);
    expect(documentSchema.safeParse(doc).success).toBe(true);
    expect(documentSchema.safeParse({ ...doc, conflicts: [] }).success).toBe(true);
    expect(documentSchema.safeParse({ ...doc, conflicts: [{ id: 1 }] }).success).toBe(false);
  });
});
