import { createHash, randomBytes, randomInt, timingSafeEqual } from 'node:crypto';
import { existsSync } from 'node:fs';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { SyncRejected } from './sync-engine.js';
import { createSelfSignedCert, fingerprintOf } from './tls.js';

export interface DeviceRecord { deviceId: string; name: string; token: string; pairedAt: string; lastSyncAt: string | null; }
interface HubJson {
  certPem: string; keyPem: string; fingerprint: string;
  pairing: PairingState | null;
  devices: DeviceRecord[];
}

/** `code` is wiped once the attempt budget is spent, so the record only remembers the lockout. */
interface PairingState { code: string; expiresAt: number; failures: number }

const PAIRING_TTL_MS = 5 * 60 * 1000;
/** Wrong-code attempts allowed per issued pairing code before it is burned. */
export const MAX_PAIR_FAILURES = 10;
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/** Constant-time secret comparison over sha256 digests (fixed length, leaks no length). */
function secretEquals(a: string, b: string): boolean {
  const digest = (s: string) => createHash('sha256').update(s, 'utf8').digest();
  return timingSafeEqual(digest(a), digest(b));
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/** Structural check for hub.json. A file that fails this is never silently replaced. */
function validateHubJson(value: unknown): void {
  if (!isPlainObject(value)) throw new Error('root is not a JSON object');
  if (typeof value.certPem !== 'string' || value.certPem.length === 0) throw new Error('certPem is missing or not a string');
  if (typeof value.keyPem !== 'string' || value.keyPem.length === 0) throw new Error('keyPem is missing or not a string');
  if (value.devices !== undefined && !Array.isArray(value.devices)) throw new Error('devices is not an array');
}

/** hub.json: certificate, pairing state and paired devices (not covered by data.lock). One instance per directory is required — saves are serialized inside this object only. */
export class HubConfig {
  /** Serializes save() so concurrent mutations can never publish a partial file. */
  private chain: Promise<unknown> = Promise.resolve();

  private constructor(private readonly path: string, private json: HubJson, private readonly now: () => number) {}

  static async load(directory: string, now: () => number = () => Date.now()): Promise<HubConfig> {
    await mkdir(directory, { recursive: true });
    const path = join(directory, 'hub.json');
    const json = existsSync(path)
      ? await readHubJson(path)
      : { ...createSelfSignedCert('frelocator-hub'), pairing: null, devices: [] };
    const cfg = new HubConfig(path, json, now);
    await cfg.save();
    return cfg;
  }

  get certPem(): string { return this.json.certPem; }
  get keyPem(): string { return this.json.keyPem; }
  get fingerprint(): string { return this.json.fingerprint; }
  devices(): DeviceRecord[] { return this.json.devices.map((d) => ({ ...d })); }

  /** Constant-time lookup: every device is compared, with no early exit. */
  deviceForToken(token: string): DeviceRecord | undefined {
    let found: DeviceRecord | undefined;
    for (const d of this.json.devices) if (secretEquals(d.token, token)) found = d;
    return found;
  }

  device(deviceId: string): DeviceRecord | undefined { return this.json.devices.find((d) => d.deviceId === deviceId); }

  /** The usable code, or null once it expired or spent its attempt budget. */
  pairingCode(): { code: string; expiresAt: number } | null {
    const p = this.json.pairing;
    if (!p || p.expiresAt <= this.now() || p.failures >= MAX_PAIR_FAILURES) return null;
    return { code: p.code, expiresAt: p.expiresAt };
  }

  /** Reportable pairing state. Never carries the code itself: `sync_status` output ends up in logs and chat. */
  pairingState(): { state: 'none' | 'issued' | 'expired' | 'locked'; expiresAt: string | null; failures: number } {
    const p = this.json.pairing;
    if (!p) return { state: 'none', expiresAt: null, failures: 0 };
    const expiresAt = new Date(p.expiresAt).toISOString();
    if (p.failures >= MAX_PAIR_FAILURES) return { state: 'locked', expiresAt, failures: p.failures };
    if (p.expiresAt <= this.now()) return { state: 'expired', expiresAt, failures: p.failures };
    return { state: 'issued', expiresAt, failures: p.failures };
  }

  /** Returns the issued record so callers (the pairing page) need no second read. */
  async issuePairingCode(): Promise<{ code: string; expiresAt: number }> {
    const code = Array.from({ length: 8 }, () => CODE_ALPHABET[randomInt(CODE_ALPHABET.length)]).join('');
    const expiresAt = this.now() + PAIRING_TTL_MS;
    this.json.pairing = { code, expiresAt, failures: 0 };
    await this.save();
    return { code, expiresAt };
  }

  /**
   * Adds or updates a device WITHOUT touching pairing state: file imports must not
   * spend the code shown on the pairing page, nor reset its failure budget.
   * A token is still minted because `DeviceRecord` requires one; the device only
   * learns it by pairing over the LAN, so this grants no new access.
   */
  async registerDevice(deviceId: string, name: string): Promise<DeviceRecord> {
    const existing = this.json.devices.find((d) => d.deviceId === deviceId);
    if (existing) existing.name = name;
    else {
      this.json.devices.push({
        deviceId,
        name,
        token: randomBytes(32).toString('hex'),
        pairedAt: new Date(this.now()).toISOString(),
        lastSyncAt: null,
      });
    }
    await this.save();
    return { ...this.device(deviceId)! };
  }

  /**
   * Counts a wrong attempt against the current code and burns the code once the
   * budget is spent: the secret is wiped but the record is kept, so later
   * attempts are answered `too_many_attempts` instead of a bare `pairing_failed`.
   */
  async recordPairFailure(): Promise<number> {
    const p = this.json.pairing;
    if (!p) return 0;
    p.failures += 1;
    if (p.failures >= MAX_PAIR_FAILURES) p.code = '';
    await this.save();
    return p.failures;
  }

  /** Single use: cleared on success and once expired (even on a wrong code); a wrong attempt on a valid code leaves it usable until the failure budget runs out. */
  async redeemPairingCode(code: string, deviceId: string, name: string): Promise<string> {
    const p = this.json.pairing;
    if (!p) throw new SyncRejected(403, 'pairing_failed', 'invalid pairing code');
    if (p.expiresAt <= this.now()) { this.json.pairing = null; await this.save(); throw new SyncRejected(403, 'pairing_code_expired', 'pairing code expired'); }
    if (p.failures >= MAX_PAIR_FAILURES) throw new SyncRejected(403, 'too_many_attempts', `too many failed pairing attempts; issue a new code`);
    if (!secretEquals(p.code, code)) {
      await this.recordPairFailure();
      throw new SyncRejected(403, 'pairing_failed', 'invalid pairing code');
    }
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

  /** Unique tmp + rename, serialized: a concurrent caller can never publish a truncated hub.json. */
  private save(): Promise<void> {
    const run = async () => {
      const tmp = `${this.path}.tmp-${process.pid}-${randomBytes(4).toString('hex')}`;
      await writeFile(tmp, JSON.stringify(this.json, null, 2), { mode: 0o600 });
      await rename(tmp, this.path);
    };
    const next = this.chain.then(run, run);
    this.chain = next.catch(() => undefined);
    return next;
  }
}

/** A present-but-unusable hub.json is kept as `hub.json.broken-<ts>` and reported: regenerating here would invalidate every pinned fingerprint. */
async function readHubJson(path: string): Promise<HubJson> {
  const broken = async (reason: string): Promise<never> => {
    const quarantine = `${path}.broken-${Date.now()}`;
    await rename(path, quarantine);
    throw new Error(
      `hub.json is unusable (${reason}); moved to ${quarantine}. No certificate was regenerated. `
      + 'Restore that file from a backup, otherwise the hub identity lost with it means '
      + 'every device must re-pair.',
    );
  };
  const text = await readFile(path, 'utf8');
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
    validateHubJson(parsed);
  } catch (error) {
    return broken(String((error as Error).message ?? error));
  }
  const json = parsed as HubJson;
  json.devices ??= [];
  json.pairing ??= null;
  // Older hub.json files predate the attempt counter.
  if (json.pairing) json.pairing.failures ??= 0;
  try {
    // Never trust the stored fingerprint: it is only a cache of the certificate.
    json.fingerprint = fingerprintOf(json.certPem);
  } catch (error) {
    return broken(`certPem is not a valid certificate (${String((error as Error).message ?? error)})`);
  }
  return json;
}
