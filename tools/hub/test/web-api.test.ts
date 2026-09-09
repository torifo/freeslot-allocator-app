import { describe, expect, it } from 'vitest';
import { WebApi } from '../src/web-api.js';

describe('WebApi.deviceIdOf', () => {
  it('accepts exactly 16 lowercase hex characters and prefixes them with web-', () => {
    expect(WebApi.deviceIdOf('00112233445566aa')).toBe('web-00112233445566aa');
  });

  it('refuses anything else, so a hostile id can never enter the HLC device space', () => {
    for (const value of ['', 'ZZZ', '00112233445566AA', '00112233445566a', '00112233445566aaa', 'web-00112233445566aa', '0011223344-566aa', undefined, 42, null]) {
      expect(WebApi.deviceIdOf(value), String(value)).toBeNull();
    }
  });

  it('reads only the first value when a header arrives repeated', () => {
    expect(WebApi.deviceIdOf(['00112233445566aa', 'ffffffffffffffff'])).toBe('web-00112233445566aa');
  });
});
