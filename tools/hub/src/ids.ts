import { createHash, randomBytes } from 'node:crypto';

/** Same rule as `deviceFragment` in lib/core/id_generator.dart. */
export function deviceFragment(deviceId?: string | null): string {
  if (!deviceId) return 'loc0';
  const dash = deviceId.indexOf('-');
  const body = dash >= 0 ? deviceId.slice(dash + 1) : deviceId;
  return body.length >= 4 ? body.slice(0, 4) : body.padEnd(4, '0');
}

// Module-level counter so ids generated within the same millisecond still
// sort strictly increasing (Date.now() alone only has ms resolution).
let idCounter = 0n;

/** `<prefix>-<microsSinceEpoch>-<device fragment>-<6 hex>` — same as lib/core/id_generator.dart. */
export function generateId(prefix: string, deviceId?: string | null): string {
  const micros = BigInt(Date.now()) * 1000n + (idCounter++ % 1000n);
  return `${prefix}-${micros}-${deviceFragment(deviceId)}-${randomBytes(3).toString('hex')}`;
}

/** Same as DailyPlanController.copyId in Dart. */
export function copyId(
  prefix: string,
  sourcePlanId: string,
  targetDate: string,
  sourceEntityId: string,
  generation: number,
): string {
  const digest = createHash('sha256')
    .update(`${sourcePlanId}|${targetDate}|${sourceEntityId}|${generation}`, 'utf8')
    .digest('hex');
  return `${prefix}-${digest.slice(0, 16)}`;
}
