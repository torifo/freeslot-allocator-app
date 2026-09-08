import { describe, expect, it } from 'vitest';
import { contentHash } from '../src/hash.js';

describe('contentHash', () => {
  it('ignores key order and meta keys', () => {
    const a = contentHash({ name: '仕事', id: 'c1', clock: '1-0-a', updatedAt: 'x' });
    const b = contentHash({ id: 'c1', name: '仕事', migrated: true, deletedAt: null });
    expect(a).toBe(b);
    expect(a).toHaveLength(64);
  });
  it('matches the Dart implementation for a known input', () => {
    // Value produced by `dart run tool/print_hash.dart '{"id":"c1","name":"仕事"}'`.
    expect(contentHash({ id: 'c1', name: '仕事' })).toBe(
      'a59ddd5f01304a0c7fe38a5a72abc49de7fc684b5e39e05a88ee074c3ae0ef37',
    );
  });
  it('matches the hashes recorded in the shared merge fixture 06', () => {
    expect(contentHash({ id: 'must-work', name: '仕事' })).toBe(
      'd52c6f93377b26b41073d9d8038ac76777e218b54cba9b759f2090381adee524',
    );
    expect(contentHash({ id: 'must-work', name: '業務' })).toBe(
      '19fd2bf2f1cb5f982902e7e248cbbed76908c40ddbfdf11a68cf56afa509c410',
    );
  });
  it('emits integral numbers as integers and keeps nesting stable', () => {
    expect(contentHash({ a: 1.0, b: [2, { c: 3 }] })).toBe(contentHash({ b: [2, { c: 3 }], a: 1 }));
  });
});
