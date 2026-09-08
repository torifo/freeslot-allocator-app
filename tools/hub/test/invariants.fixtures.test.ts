import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { checkInvariants } from '../src/invariants.js';

const here = dirname(fileURLToPath(import.meta.url));
const dir = join(here, '../../../test/fixtures/sync_invariants');
const manifest = JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8')) as string[];

describe('invariant fixtures', () => {
  for (const name of manifest) {
    const fx = JSON.parse(readFileSync(join(dir, name), 'utf8'));
    it(fx.name, () => {
      expect(checkInvariants(fx.document).map((v) => v.code)).toEqual(fx.expectedCodes);
    });
  }
});
