import { describe, expect, it } from 'vitest';
import { X509Certificate } from 'node:crypto';
import { createSelfSignedCert, fingerprintOf } from '../src/tls.js';

describe('tls', () => {
  it('creates a cert valid for 10 years with a sha256 fingerprint', () => {
    const cert = createSelfSignedCert('frelocator-hub');
    const x509 = new X509Certificate(cert.certPem);
    expect(x509.subject).toContain('CN=frelocator-hub');
    const years = (new Date(x509.validTo).getTime() - new Date(x509.validFrom).getTime()) / (365 * 86400000);
    expect(years).toBeGreaterThan(9.9);
    expect(cert.fingerprint).toMatch(/^[0-9A-F]{64}$/);
    expect(fingerprintOf(cert.certPem)).toBe(cert.fingerprint);
  });
});
