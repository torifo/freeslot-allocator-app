import { networkInterfaces, type NetworkInterfaceInfo } from 'node:os';
import { Bonjour, type Service } from 'bonjour-service';

export type NetworkInterfaceMap = NodeJS.Dict<NetworkInterfaceInfo[]>;

/**
 * Interfaces that never carry the address a phone on the LAN can reach:
 * container bridges (docker/br-/veth/virbr), VPN and utility tunnels
 * (utun/tun/tap), hypervisor networks (vmnet/bridge) and Apple's peer-to-peer
 * links (awdl/llw).
 */
const EXCLUDED = /^(docker|br-|veth|virbr|utun|tun|tap|vmnet|bridge|awdl|llw)/;
/** macOS `en*` and Linux `wl*` are the usual Wi-Fi/Ethernet names; prefer them. */
const PREFERRED = /^(en|wl)/;

/** LAN-reachable IPv4 addresses, best candidate first. */
export function lanAddresses(ifaces: NetworkInterfaceMap = networkInterfaces()): string[] {
  const names = Object.keys(ifaces).filter((name) => !EXCLUDED.test(name));
  const ranked = [...names].sort((a, b) => Number(PREFERRED.test(b)) - Number(PREFERRED.test(a)));
  const out: string[] = [];
  for (const name of ranked) {
    for (const i of ifaces[name] ?? []) {
      // `family` is 'IPv4' on Node >= 18; the numeric 4 appears on older typings.
      if (i.family !== 'IPv4' && (i.family as unknown as number) !== 4) continue;
      if (i.internal) continue;
      if (i.address.startsWith('169.254.')) continue; // link-local: not routable for pairing
      out.push(i.address);
    }
  }
  return out;
}

/** Best LAN IPv4 address, or null when the host has none. */
export function lanAddress(ifaces?: NetworkInterfaceMap): string | null {
  return lanAddresses(ifaces)[0] ?? null;
}

/** Publishes `_frelocator._tcp` so phones on the same LAN can find the hub without typing an address. */
export class MdnsAdvertiser {
  private bonjour: Bonjour | null = null;
  private service: Service | null = null;

  /** The factory is injectable so tests can avoid real mDNS traffic. */
  constructor(private readonly createBonjour: () => Bonjour = () => new Bonjour()) {}

  start(port: number, hubDeviceId: string): void {
    if (this.bonjour) this.teardown(); // start() twice must not leak the first instance
    this.bonjour = this.createBonjour();
    this.service = this.bonjour.publish({ name: 'frelocator-hub', type: 'frelocator', protocol: 'tcp', port, txt: { hub: hubDeviceId, v: '2' } });
  }

  async stop(): Promise<void> {
    const service = this.service;
    if (service) await new Promise<void>((resolve) => service.stop(() => resolve()));
    this.service = null;
    this.teardown();
  }

  private teardown(): void {
    this.service?.stop?.(() => undefined);
    this.bonjour?.destroy();
    this.bonjour = null;
    this.service = null;
  }
}
