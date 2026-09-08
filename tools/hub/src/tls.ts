import { createHash, X509Certificate } from 'node:crypto';
import selfsigned from 'selfsigned';

export interface CertBundle { certPem: string; keyPem: string; fingerprint: string; }

/** SHA-256 over the DER certificate, upper-case hex without separators. */
export function fingerprintOf(certPem: string): string {
  return createHash('sha256').update(new X509Certificate(certPem).raw).digest('hex').toUpperCase();
}

export function createSelfSignedCert(commonName: string): CertBundle {
  const pems = selfsigned.generate([{ name: 'commonName', value: commonName }], {
    days: 3650,
    keySize: 2048,
    algorithm: 'sha256',
    extensions: [{ name: 'basicConstraints', cA: false }, { name: 'keyUsage', digitalSignature: true, keyEncipherment: true }],
  });
  return { certPem: pems.cert, keyPem: pems.private, fingerprint: fingerprintOf(pems.cert) };
}
