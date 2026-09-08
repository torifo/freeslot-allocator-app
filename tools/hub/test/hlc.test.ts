import { describe, expect, it } from 'vitest';
import { Hlc, HlcClock } from '../src/hlc.js';

describe('Hlc', () => {
  it('parses and prints', () => {
    const h = Hlc.parse('1725760000000-3-android-ab12');
    expect(h.physical).toBe(1725760000000);
    expect(h.counter).toBe(3);
    expect(h.deviceId).toBe('android-ab12');
    expect(h.toString()).toBe('1725760000000-3-android-ab12');
  });
  it('orders physical, counter, deviceId', () => {
    expect(Hlc.compare(Hlc.parse('10-0-b'), Hlc.parse('10-1-a'))).toBeLessThan(0);
    expect(Hlc.compare(Hlc.parse('10-0-a'), Hlc.parse('10-0-b'))).toBeLessThan(0);
    expect(Hlc.compare(Hlc.parse('11-0-a'), Hlc.parse('10-9-z'))).toBeGreaterThan(0);
  });
  it('rejects malformed values like the Dart parser', () => {
    expect(() => Hlc.parse('10-0-')).toThrow();
    expect(() => Hlc.parse('x-0-a')).toThrow();
    expect(() => Hlc.parse('-1-0-a')).toThrow();
    expect(Hlc.tryParse('nope')).toBeNull();
    expect(Hlc.tryParse(null)).toBeNull();
  });
  it('clock is monotonic and observes remote', () => {
    let now = 1000;
    const clock = new HlcClock('hub', () => now);
    const a = clock.next();
    now = 500;
    const b = clock.next();
    expect(Hlc.compare(b, a)).toBeGreaterThan(0);
    clock.observe(Hlc.parse('5000-2-x'));
    expect(clock.next().toString()).toBe('5000-3-hub');
  });
});
