import { createHash, X509Certificate } from 'node:crypto';
import selfsigned from 'selfsigned';

export interface CertBundle { certPem: string; keyPem: string; fingerprint: string; }

/** Names the certificate is valid for: mDNS host, loopback name and loopback address. */
export const HUB_SAN_DNS = ['frelocator-hub.local', 'localhost'] as const;
export const HUB_SAN_IP = ['127.0.0.1'] as const;

/** SHA-256 over the DER certificate, upper-case hex without separators. */
export function fingerprintOf(certPem: string): string {
  return createHash('sha256').update(new X509Certificate(certPem).raw).digest('hex').toUpperCase();
}

export function createSelfSignedCert(commonName: string): CertBundle {
  const pems = selfsigned.generate([{ name: 'commonName', value: commonName }], {
    days: 3650,
    keySize: 2048,
    algorithm: 'sha256',
    extensions: [
      { name: 'basicConstraints', cA: false },
      { name: 'keyUsage', digitalSignature: true, keyEncipherment: true },
      {
        name: 'subjectAltName',
        // node-forge altName types: 2 = dNSName, 7 = iPAddress.
        altNames: [
          ...HUB_SAN_DNS.map((value) => ({ type: 2, value })),
          ...HUB_SAN_IP.map((ip) => ({ type: 7, ip })),
        ],
      },
    ],
  });
  return { certPem: pems.cert, keyPem: pems.private, fingerprint: fingerprintOf(pems.cert) };
}
