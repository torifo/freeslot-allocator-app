import { describe, expect, it } from 'vitest';
import { createPrivateKey, createPublicKey, sign, verify, X509Certificate } from 'node:crypto';
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

  it('carries the SANs the LAN clients connect by', () => {
    const x509 = new X509Certificate(createSelfSignedCert('frelocator-hub').certPem);
    const san = x509.subjectAltName ?? '';
    expect(san).toContain('DNS:frelocator-hub.local');
    expect(san).toContain('DNS:localhost');
    expect(san).toContain('IP Address:127.0.0.1');
  });

  it('emits a private key that matches the certificate public key', () => {
    const bundle = createSelfSignedCert('frelocator-hub');
    const privateKey = createPrivateKey(bundle.keyPem);
    const publicKey = new X509Certificate(bundle.certPem).publicKey;
    const payload = Buffer.from('frelocator');
    const signature = sign('sha256', payload, privateKey);
    expect(verify('sha256', payload, publicKey, signature)).toBe(true);
    expect(createPublicKey(privateKey).export({ type: 'spki', format: 'pem' }))
      .toBe(publicKey.export({ type: 'spki', format: 'pem' }));
  });
});
