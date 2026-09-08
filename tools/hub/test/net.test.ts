import type { NetworkInterfaceInfo } from 'node:os';
import { describe, expect, it } from 'vitest';
import { MdnsAdvertiser, lanAddress, lanAddresses } from '../src/net.js';

type Ifaces = NodeJS.Dict<NetworkInterfaceInfo[]>;

const v4 = (address: string, internal = false): NetworkInterfaceInfo =>
  ({ address, family: 'IPv4', internal, netmask: '255.255.255.0', mac: '00:00:00:00:00:00', cidr: `${address}/24` }) as NetworkInterfaceInfo;
const v6 = (address: string): NetworkInterfaceInfo =>
  ({ address, family: 'IPv6', internal: false, netmask: 'ffff::', mac: '00:00:00:00:00:00', cidr: `${address}/64`, scopeid: 0 }) as NetworkInterfaceInfo;

const cases: Array<{ name: string; ifaces: Ifaces; expected: string[] }> = [
  {
    name: 'prefers en0 over docker0 and loopback',
    ifaces: { lo0: [v4('127.0.0.1', true)], docker0: [v4('172.17.0.1')], en0: [v4('192.168.1.20')] },
    expected: ['192.168.1.20'],
  },
  {
    name: 'accepts wlan0 when it is the only interface',
    ifaces: { wlan0: [v4('10.0.0.5')] },
    expected: ['10.0.0.5'],
  },
  {
    name: 'skips a docker-only host',
    ifaces: { lo: [v4('127.0.0.1', true)], docker0: [v4('172.17.0.1')], 'br-abc123': [v4('172.18.0.1')], veth9a: [v4('172.19.0.1')] },
    expected: [],
  },
  {
    name: 'skips link-local addresses',
    ifaces: { en0: [v4('169.254.11.22')] },
    expected: [],
  },
  {
    name: 'ignores IPv6-only interfaces',
    ifaces: { en0: [v6('fe80::1'), v6('2001:db8::1')] },
    expected: [],
  },
  {
    name: 'handles an empty interface map',
    ifaces: {},
    expected: [],
  },
  {
    name: 'skips VPN/virtual interfaces but keeps the physical one',
    ifaces: { utun4: [v4('10.8.0.2')], vmnet1: [v4('172.16.30.1')], awdl0: [v4('169.254.9.9')], en1: [v4('192.168.10.7')] },
    expected: ['192.168.10.7'],
  },
  {
    name: 'ranks en*/wl* ahead of other physical interfaces',
    ifaces: { eth7: [v4('192.168.5.5')], en0: [v4('192.168.1.2')] },
    expected: ['192.168.1.2', '192.168.5.5'],
  },
];

describe('lanAddresses', () => {
  for (const c of cases) {
    it(c.name, () => {
      expect(lanAddresses(c.ifaces)).toEqual(c.expected);
      expect(lanAddress(c.ifaces)).toBe(c.expected[0] ?? null);
    });
  }

  it('is callable with no arguments', () => {
    const value = lanAddress();
    expect(value === null || typeof value === 'string').toBe(true);
  });
});

class FakeBonjour {
  static destroyed = 0;
  published: unknown[] = [];
  publish(options: unknown): { stop: (cb: () => void) => void } {
    this.published.push(options);
    return { stop: (cb: () => void) => cb() };
  }
  destroy(): void { FakeBonjour.destroyed += 1; }
}

const advertiser = () => new MdnsAdvertiser(() => new FakeBonjour() as never);

describe('MdnsAdvertiser', () => {
  it('tolerates stop() before start()', async () => {
    await expect(advertiser().stop()).resolves.toBeUndefined();
  });

  it('tolerates stop() twice', async () => {
    const a = advertiser();
    a.start(1234, 'hub-0000');
    await a.stop();
    await expect(a.stop()).resolves.toBeUndefined();
  });

  it('tolerates start() twice without leaking the first instance', async () => {
    const before = FakeBonjour.destroyed;
    const a = advertiser();
    a.start(1234, 'hub-0000');
    expect(() => a.start(1235, 'hub-0000')).not.toThrow();
    expect(FakeBonjour.destroyed).toBe(before + 1);
    await a.stop();
    expect(FakeBonjour.destroyed).toBe(before + 2);
  });
});
