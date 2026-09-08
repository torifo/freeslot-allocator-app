import { networkInterfaces } from 'node:os';
import { Bonjour, type Service } from 'bonjour-service';

/** First non-internal IPv4 address, preferring en0/en1 (macOS Wi-Fi/Ethernet). */
export function lanAddress(): string | null {
  const ifaces = networkInterfaces();
  const names = Object.keys(ifaces).sort((a, b) => (a.startsWith('en') ? -1 : 0) - (b.startsWith('en') ? -1 : 0));
  for (const name of names) for (const i of ifaces[name] ?? []) if (i.family === 'IPv4' && !i.internal) return i.address;
  return null;
}

/** Publishes `_frelocator._tcp` so phones on the same LAN can find the hub without typing an address. */
export class MdnsAdvertiser {
  private bonjour: Bonjour | null = null;
  private service: Service | null = null;

  start(port: number, hubDeviceId: string): void {
    this.bonjour = new Bonjour();
    this.service = this.bonjour.publish({ name: 'frelocator-hub', type: 'frelocator', protocol: 'tcp', port, txt: { hub: hubDeviceId, v: '2' } });
  }

  async stop(): Promise<void> {
    await new Promise<void>((resolve) => { if (!this.service) return resolve(); this.service.stop(() => resolve()); });
    this.bonjour?.destroy();
    this.bonjour = null;
    this.service = null;
  }
}
