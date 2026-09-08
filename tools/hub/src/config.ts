import { randomBytes, randomInt } from 'node:crypto';
import { existsSync } from 'node:fs';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createSelfSignedCert } from './tls.js';

export interface DeviceRecord { deviceId: string; name: string; token: string; pairedAt: string; lastSyncAt: string | null; }
interface HubJson {
  certPem: string; keyPem: string; fingerprint: string;
  pairing: { code: string; expiresAt: number } | null;
  devices: DeviceRecord[];
}

const PAIRING_TTL_MS = 5 * 60 * 1000;
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/** hub.json: certificate, pairing state and paired devices. Not covered by data.lock (separate file, single writer = the hub). */
export class HubConfig {
  private constructor(private readonly path: string, private json: HubJson, private readonly now: () => number) {}

  static async load(directory: string, now: () => number = () => Date.now()): Promise<HubConfig> {
    await mkdir(directory, { recursive: true });
    const path = join(directory, 'hub.json');
    let json: HubJson;
    if (existsSync(path)) {
      json = JSON.parse(await readFile(path, 'utf8')) as HubJson;
      if (!json.certPem || !json.keyPem) Object.assign(json, createSelfSignedCert('frelocator-hub'));
      json.devices ??= []; json.pairing ??= null;
    } else {
      json = { ...createSelfSignedCert('frelocator-hub'), pairing: null, devices: [] };
    }
    const cfg = new HubConfig(path, json, now);
    await cfg.save();
    return cfg;
  }

  get certPem(): string { return this.json.certPem; }
  get keyPem(): string { return this.json.keyPem; }
  get fingerprint(): string { return this.json.fingerprint; }
  devices(): DeviceRecord[] { return this.json.devices.map((d) => ({ ...d })); }
  deviceForToken(token: string): DeviceRecord | undefined { return this.json.devices.find((d) => d.token === token); }
  device(deviceId: string): DeviceRecord | undefined { return this.json.devices.find((d) => d.deviceId === deviceId); }
  pairingCode(): { code: string; expiresAt: number } | null {
    const p = this.json.pairing;
    return p && p.expiresAt > this.now() ? { ...p } : null;
  }

  async issuePairingCode(): Promise<string> {
    const code = Array.from({ length: 8 }, () => CODE_ALPHABET[randomInt(CODE_ALPHABET.length)]).join('');
    this.json.pairing = { code, expiresAt: this.now() + PAIRING_TTL_MS };
    await this.save();
    return code;
  }

  /** Single use: the code is cleared on success or when expired. */
  async redeemPairingCode(code: string, deviceId: string, name: string): Promise<string> {
    const p = this.json.pairing;
    if (!p || p.code !== code) throw new Error('invalid pairing code');
    if (p.expiresAt <= this.now()) { this.json.pairing = null; await this.save(); throw new Error('pairing code expired'); }
    this.json.pairing = null;
    const token = randomBytes(32).toString('hex');
    const existing = this.json.devices.find((d) => d.deviceId === deviceId);
    const pairedAt = new Date(this.now()).toISOString();
    if (existing) { existing.token = token; existing.name = name; existing.pairedAt = pairedAt; existing.lastSyncAt = null; }
    else this.json.devices.push({ deviceId, name, token, pairedAt, lastSyncAt: null });
    await this.save();
    return token;
  }

  async rotateToken(deviceId: string): Promise<string> {
    const d = this.device(deviceId);
    if (!d) throw new Error(`unknown device ${deviceId}`);
    d.token = randomBytes(32).toString('hex');
    await this.save();
    return d.token;
  }

  async forgetDevice(deviceId: string): Promise<void> {
    if (!this.device(deviceId)) throw new Error(`unknown device ${deviceId}`);
    this.json.devices = this.json.devices.filter((d) => d.deviceId !== deviceId);
    await this.save();
  }

  async recordSync(deviceId: string, atIso: string): Promise<void> {
    const d = this.device(deviceId);
    if (!d) throw new Error(`unknown device ${deviceId}`);
    d.lastSyncAt = atIso;
    await this.save();
  }

  private async save(): Promise<void> {
    const tmp = `${this.path}.tmp`;
    await writeFile(tmp, JSON.stringify(this.json, null, 2), { mode: 0o600 });
    await rename(tmp, this.path);
  }
}
