import { describe, expect, it } from 'vitest';
import { copyId, deviceFragment, generateId } from '../src/ids.js';

describe('ids', () => {
  it('matches the Dart format with a device fragment', () => {
    expect(generateId('task', 'hub-1234abcd')).toMatch(/^task-\d+-1234-[0-9a-f]{6}$/);
  });
  it('falls back the same way as lib/core/id_generator.dart', () => {
    expect(deviceFragment(undefined)).toBe('loc0');
    expect(deviceFragment('')).toBe('loc0');
    expect(deviceFragment('android-ab12cd34')).toBe('ab12');
    expect(deviceFragment('hub')).toBe('hub0');
    expect(deviceFragment('mac-ab')).toBe('ab00');
  });
  it('copyId is deterministic and generation-aware', () => {
    const a = copyId('slot', 'plan-1', '2026-09-09', 'slot-1', 0);
    expect(a).toBe(copyId('slot', 'plan-1', '2026-09-09', 'slot-1', 0));
    expect(a).not.toBe(copyId('slot', 'plan-1', '2026-09-09', 'slot-1', 1));
    expect(a).toMatch(/^slot-[0-9a-f]{16}$/);
  });
});
