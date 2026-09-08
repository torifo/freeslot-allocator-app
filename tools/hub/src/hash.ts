import { createHash } from 'node:crypto';

export const META_KEYS = ['clock', 'updatedAt', 'deletedAt', 'migrated'] as const;

const MAX_SAFE_INTEGER = 9007199254740992;

/**
 * Canonical JSON, byte-for-byte identical to lib/core/content_hash.dart:
 *  - object keys sorted by UTF-16 code unit (JS default sort),
 *  - non-ASCII left unescaped (JSON.stringify / Dart jsonEncode agree),
 *  - integral numbers emitted as integers (Dart normalizes integral doubles),
 *  - non-string keys are rejected.
 */
function canonicalize(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalize).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    const obj = value as Record<string, unknown>;
    for (const key of Reflect.ownKeys(obj)) {
      if (typeof key !== 'string') {
        throw new TypeError('contentHash only supports String map keys');
      }
    }
    const keys = Object.keys(obj).sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalize(obj[k])}`).join(',')}}`;
  }
  if (typeof value === 'number' && Number.isFinite(value) && Number.isInteger(value) && Math.abs(value) < MAX_SAFE_INTEGER) {
    return value.toFixed(0);
  }
  return JSON.stringify(value) ?? 'null';
}

/** Same algorithm as lib/core/content_hash.dart: drop meta keys, sort keys, SHA-256. */
export function contentHash(entity: Record<string, unknown>): string {
  const filtered: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(entity)) {
    if (!(META_KEYS as readonly string[]).includes(k)) filtered[k] = v;
  }
  return createHash('sha256').update(canonicalize(filtered), 'utf8').digest('hex');
}
