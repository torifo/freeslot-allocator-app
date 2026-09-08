/// Hybrid logical clock value: `<physicalMillis>-<counter>-<deviceId>`.
///
/// Mirrors lib/core/hlc.dart exactly: ordering is physical, then counter,
/// then deviceId (lexicographic), which makes the order total.
export class Hlc {
  constructor(
    public readonly physical: number,
    public readonly counter: number,
    public readonly deviceId: string,
  ) {}

  /** Sentinel for entities migrated from schema v1 (no clock recorded). */
  static readonly migrated = new Hlc(0, 0, 'migrated');

  static parse(value: string): Hlc {
    const first = value.indexOf('-');
    const second = value.indexOf('-', first + 1);
    if (first <= 0 || second <= first) throw new Error(`Invalid HLC: ${value}`);
    const physical = parseIntStrict(value.slice(0, first));
    const counter = parseIntStrict(value.slice(first + 1, second));
    const deviceId = value.slice(second + 1);
    if (physical === null || physical < 0 || counter === null || counter < 0 || deviceId.length === 0) {
      throw new Error(`Invalid HLC: ${value}`);
    }
    return new Hlc(physical, counter, deviceId);
  }

  static tryParse(value: unknown): Hlc | null {
    if (typeof value !== 'string') return null;
    try {
      return Hlc.parse(value);
    } catch {
      return null;
    }
  }

  static compare(a: Hlc, b: Hlc): number {
    if (a.physical !== b.physical) return a.physical - b.physical;
    if (a.counter !== b.counter) return a.counter - b.counter;
    return compareStrings(a.deviceId, b.deviceId);
  }

  get isMigrated(): boolean {
    return this.physical === 0 && this.counter === 0 && this.deviceId === 'migrated';
  }

  toString(): string {
    return `${this.physical}-${this.counter}-${this.deviceId}`;
  }
}

/** `int.tryParse` semantics: whole string must be an integer literal. */
function parseIntStrict(value: string): number | null {
  if (!/^[+-]?\d+$/.test(value)) return null;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) ? parsed : null;
}

/** Dart's String.compareTo: UTF-16 code unit order. */
export function compareStrings(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

/** Issues monotonically increasing [Hlc] values for one device. */
export class HlcClock {
  private lastPhysical: number;
  private lastCounter: number;

  constructor(
    public readonly deviceId: string,
    private readonly now: () => number = () => Date.now(),
    last?: Hlc,
  ) {
    this.lastPhysical = last?.physical ?? 0;
    this.lastCounter = last?.counter ?? 0;
  }

  get last(): Hlc {
    return new Hlc(this.lastPhysical, this.lastCounter, this.deviceId);
  }

  next(): Hlc {
    const wall = this.now();
    if (wall > this.lastPhysical) {
      this.lastPhysical = wall;
      this.lastCounter = 0;
    } else {
      this.lastCounter += 1;
    }
    return this.last;
  }

  /** Folds a remote clock in so the next issued value is strictly greater. */
  observe(remote: Hlc): void {
    if (remote.physical > this.lastPhysical) {
      this.lastPhysical = remote.physical;
      this.lastCounter = remote.counter;
    } else if (remote.physical === this.lastPhysical && remote.counter > this.lastCounter) {
      this.lastCounter = remote.counter;
    }
  }
}
