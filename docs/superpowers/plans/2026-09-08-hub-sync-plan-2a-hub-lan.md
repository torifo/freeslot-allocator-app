# FRELOCATOR Hub Sync — Plan 2a: ハブ側 LAN 同期・ペアリング・QR 配信・端末管理

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `tools/hub` に、Claude Code 起動中だけ開く LAN 向け HTTPS 同期エンドポイント（自己署名 TLS＋フィンガープリントのピン留め、短命ペアリングコード→端末別トークン、mDNS 広告）、localhost 限定のペアリング／データ QR 表示ページ、`import_file` / `purge_tombstones` / `forget_device` / `rotate_token` の実装、進捗付き `sync_status` を追加する。Plan 2b（Flutter 側）と組み合わせて端末間同期が完成する。

**Architecture:** `hub.json`（証明書・端末トークン・端末ごとの lastSyncAt）を `HubConfig` が管理。`LanServer`（https、0.0.0.0:47820）は `/pair` `/sync` `/health` を持ち、`SyncEngine` が Plan 1 の `merge` と `FileStore.update` でマージし `purgedBefore` を判定する。`LocalPages`（http、127.0.0.1:47821）は QR 画面を返す。`QrCodec` は gzip→base45→600 文字フレーム。すべて `index.ts` から起動し、MCP 終了で閉じる。

**Tech Stack:** Node 22 / TypeScript 5、`@modelcontextprotocol/sdk`、`zod`、`selfsigned`（自己署名証明書）、`qrcode`（SVG 生成）、`bonjour-service`（mDNS）、`vitest`。

**設計書:** `docs/superpowers/specs/2026-09-08-frelocator-hub-sync-design.md`（「LAN 同期プロトコル」「ネットワーク不一致時の副経路」「削除とゴミ掃除」「MCP ツール一覧」）。Plan 1 で `tools/hub/src/{model,hlc,hash,merge,invariants,store,ids,tools,index}.ts` は実装済み。

**Plan 2b への申し送り（バッチ 1 レビュー）:**
- クライアントは**フィンガープリントでピン留め**し、ホスト名検証はバイパスする（Dart は `HttpClient.badCertificateCallback` で証明書の SHA-256 を照合して判定する）。証明書には SAN（`frelocator-hub.local` / `localhost` / `127.0.0.1`）が入っているが、LAN の IP 直打ちでは一致しないため。
- **ワイヤ上の時刻は必ず UTC ISO-8601（`Z` 付き）**で送る。ハブは `Date.parse` の瞬間比較で判定するが、オフセット無しの文字列はハブのローカル時刻として解釈されるため、`Z` 無しの送信は禁止。

---

## ファイル構成（`tools/hub/`）

- Create `src/config.ts` — `HubConfig`: `hub.json` の読み書き（原子的）、証明書生成、ペアリングコード、端末トークン、`lastSyncAt`。
- Create `src/tls.ts` — 自己署名証明書の生成と SHA-256 フィンガープリント。
- Create `src/sync-engine.ts` — `SyncEngine`: `/sync` の本体（バージョン検査、`purgedBefore` 判定、マージ、保存、端末 `lastSyncAt` 更新、進捗記録、purge）。
- Create `src/lan-server.ts` — `LanServer`: https サーバー、Bearer 認証、ルーティング。
- Create `src/qr-codec.ts` — `encodeFrames` / `decodeFrames`、base45、crc32。
- Create `src/local-pages.ts` — `LocalPages`: 127.0.0.1 の `/pair` と `/qr` ページ（SVG QR、アニメーション）。
- Create `src/net.ts` — LAN IP の解決、mDNS 広告。
- Modify `src/tools.ts` — `importFile` / `purgeTombstones` / `forgetDevice` / `rotateToken` / `syncStatus` の実装、`SyncEngine` と `HubConfig` を受け取る。
- Modify `src/index.ts` — 起動順（config → engine → LAN → local pages → MCP）、終了処理。
- Modify `package.json` — 依存追加。
- Tests: `test/config.test.ts`、`test/tls.test.ts`、`test/sync-engine.test.ts`、`test/lan-server.test.ts`、`test/qr-codec.test.ts`、`test/local-pages.test.ts`、`test/tools.plan2.test.ts`。

共通の約束: 全 HTTP 応答は JSON（`Content-Type: application/json`）。エラーは `{ error: { code, message } }`。ポートは環境変数 `FRELOCATOR_LAN_PORT`（既定 47820）と `FRELOCATOR_LOCAL_PORT`（既定 47821）。

---

### Task 1: 自己署名 TLS と HubConfig

**Files:**
- Create: `src/tls.ts`、`src/config.ts`
- Modify: `package.json`（`selfsigned: ^2.4.1` を dependencies に、`@types/selfsigned` は不要）
- Test: `test/tls.test.ts`、`test/config.test.ts`

- [ ] **Step 1: 失敗するテストを書く**

```ts
// test/tls.test.ts
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
```

```ts
// test/config.test.ts
import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { HubConfig } from '../src/config.js';

let dir: string;
beforeEach(() => { dir = mkdtempSync(join(tmpdir(), 'hub-config-')); });
afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

describe('HubConfig', () => {
  it('creates hub.json with a certificate on first load and reuses it', async () => {
    const a = await HubConfig.load(dir);
    const b = await HubConfig.load(dir);
    expect(a.fingerprint).toBe(b.fingerprint);
    expect(JSON.parse(readFileSync(join(dir, 'hub.json'), 'utf8')).certPem).toContain('BEGIN CERTIFICATE');
  });

  it('issues a single-use pairing code that expires', async () => {
    let now = 1_000_000;
    const cfg = await HubConfig.load(dir, () => now);
    const code = await cfg.issuePairingCode();
    expect(code).toMatch(/^[A-Z0-9]{8}$/);
    now += 6 * 60 * 1000;
    await expect(cfg.redeemPairingCode(code, 'android-1', 'Pixel')).rejects.toThrow(/expired/);
    const fresh = await cfg.issuePairingCode();
    const token = await cfg.redeemPairingCode(fresh, 'android-1', 'Pixel');
    expect(token).toMatch(/^[a-f0-9]{64}$/);
    await expect(cfg.redeemPairingCode(fresh, 'android-2', 'x')).rejects.toThrow(/invalid/);
    expect(cfg.deviceForToken(token)?.deviceId).toBe('android-1');
  });

  it('rotates, forgets and records lastSyncAt', async () => {
    const cfg = await HubConfig.load(dir, () => 5_000);
    const token = await cfg.redeemPairingCode(await cfg.issuePairingCode(), 'android-1', 'Pixel');
    const rotated = await cfg.rotateToken('android-1');
    expect(rotated).not.toBe(token);
    expect(cfg.deviceForToken(token)).toBeUndefined();
    await cfg.recordSync('android-1', '2026-09-09T00:00:00.000Z');
    expect(cfg.devices()[0].lastSyncAt).toBe('2026-09-09T00:00:00.000Z');
    await cfg.forgetDevice('android-1');
    expect(cfg.devices()).toEqual([]);
    await expect(cfg.rotateToken('nope')).rejects.toThrow(/unknown device/);
  });

  it('stores hub.json with owner-only permissions', async () => {
    await HubConfig.load(dir);
    expect(statSync(join(dir, 'hub.json')).mode & 0o777).toBe(0o600);
  });

  it('recomputes the fingerprint instead of trusting the stored one', async () => {
    const a = await HubConfig.load(dir);
    const path = join(dir, 'hub.json');
    const json = JSON.parse(readFileSync(path, 'utf8'));
    json.fingerprint = 'DEADBEEF';
    writeFileSync(path, JSON.stringify(json));
    const b = await HubConfig.load(dir);
    expect(b.fingerprint).toBe(a.fingerprint);
  });

  it.each([
    ['corrupt JSON', 'not json at all'],
    ['an array root', '[]'],
    ['a missing certPem', JSON.stringify({ keyPem: 'x', devices: [] })],
    ['non-array devices', JSON.stringify({ certPem: 'x', keyPem: 'y', devices: {} })],
  ])('refuses to mint a new identity over %s', async (_label, text) => {
    const path = join(dir, 'hub.json');
    writeFileSync(path, text);
    await expect(HubConfig.load(dir)).rejects.toThrow(/hub identity lost/);
    const broken = readdirSync(dir).filter((f) => f.startsWith('hub.json.broken-'));
    expect(broken).toHaveLength(1);
    expect(readFileSync(join(dir, broken[0]), 'utf8')).toBe(text);
  });

  it('serializes concurrent recordSync calls into one parseable hub.json', async () => {
    const cfg = await HubConfig.load(dir, () => 5_000);
    const ids = Array.from({ length: 12 }, (_, i) => `android-${i}`);
    for (const id of ids) await cfg.redeemPairingCode(await cfg.issuePairingCode(), id, id);
    await Promise.all(ids.map((id, i) => cfg.recordSync(id, `2026-09-0${(i % 9) + 1}T00:00:00.000Z`)));
    const json = JSON.parse(readFileSync(join(dir, 'hub.json'), 'utf8'));
    expect(json.devices).toHaveLength(ids.length);
    for (const d of json.devices) expect(d.lastSyncAt).toMatch(/^2026-09-\d\dT/);
  });

  it('keeps a valid pairing code usable after a wrong attempt', async () => {
    const cfg = await HubConfig.load(dir, () => 5_000);
    const code = await cfg.issuePairingCode();
    await expect(cfg.redeemPairingCode('WRONGWRO', 'android-1', 'Pixel')).rejects.toThrow(/invalid/);
    expect(cfg.pairingCode()?.code).toBe(code);
    await expect(cfg.redeemPairingCode(code, 'android-1', 'Pixel')).resolves.toMatch(/^[a-f0-9]{64}$/);
  });

  it('clears an expired pairing code even on a wrong attempt', async () => {
    let now = 1_000_000;
    const cfg = await HubConfig.load(dir, () => now);
    await cfg.issuePairingCode();
    now += 6 * 60 * 1000;
    await expect(cfg.redeemPairingCode('WRONGWRO', 'android-1', 'Pixel')).rejects.toThrow(/expired/);
    expect(JSON.parse(readFileSync(join(dir, 'hub.json'), 'utf8')).pairing).toBeNull();
  });

  it('forgets a device token', async () => {
    const cfg = await HubConfig.load(dir, () => 5_000);
    const token = await cfg.redeemPairingCode(await cfg.issuePairingCode(), 'android-1', 'Pixel');
    expect(cfg.deviceForToken(token)?.deviceId).toBe('android-1');
    await cfg.forgetDevice('android-1');
    expect(cfg.deviceForToken(token)).toBeUndefined();
  });
});
```

- [ ] **Step 2: 失敗を確認する**

Run: `cd tools/hub && npm install selfsigned@^2.4.1 && npm test`
Expected: FAIL（モジュール無し）

- [ ] **Step 3: 実装する**

```ts
// src/tls.ts
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
```

```ts
// src/config.ts
import { createHash, randomBytes, randomInt, timingSafeEqual } from 'node:crypto';
import { existsSync } from 'node:fs';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createSelfSignedCert, fingerprintOf } from './tls.js';

export interface DeviceRecord { deviceId: string; name: string; token: string; pairedAt: string; lastSyncAt: string | null; }
interface HubJson {
  certPem: string; keyPem: string; fingerprint: string;
  pairing: { code: string; expiresAt: number } | null;
  devices: DeviceRecord[];
}

const PAIRING_TTL_MS = 5 * 60 * 1000;
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

  /** Single use: cleared on success and once expired (even on a wrong code); a wrong attempt on a valid code leaves it usable. */
  async redeemPairingCode(code: string, deviceId: string, name: string): Promise<string> {
    const p = this.json.pairing;
    if (!p) throw new Error('invalid pairing code');
    if (p.expiresAt <= this.now()) { this.json.pairing = null; await this.save(); throw new Error('pairing code expired'); }
    if (!secretEquals(p.code, code)) throw new Error('invalid pairing code');
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
  try {
    // Never trust the stored fingerprint: it is only a cache of the certificate.
    json.fingerprint = fingerprintOf(json.certPem);
  } catch (error) {
    return broken(`certPem is not a valid certificate (${String((error as Error).message ?? error)})`);
  }
  return json;
}
```

- [ ] **Step 4: テストを通す**

Run: `npm test && npm run typecheck`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add tools/hub/package.json tools/hub/package-lock.json tools/hub/src/tls.ts tools/hub/src/config.ts tools/hub/test/tls.test.ts tools/hub/test/config.test.ts
git commit -m "feat(hub): self-signed TLS and hub.json config with pairing and device tokens / 自己署名 TLS とペアリング設定"
```

---

### Task 2: SyncEngine（/sync の本体、purgedBefore、purge、進捗）

**Files:**
- Create: `src/sync-engine.ts`
- Test: `test/sync-engine.test.ts`

- [ ] **Step 1: 失敗するテストを書く**

```ts
// test/sync-engine.test.ts
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { HubConfig } from '../src/config.js';
import { HlcClock } from '../src/hlc.js';
import { emptyDocument, type Entity, type SyncDocumentJson } from '../src/model.js';
import { FileStore } from '../src/store.js';
import { SyncEngine, SyncRejected } from '../src/sync-engine.js';

let dir: string; let engine: SyncEngine; let cfg: HubConfig; let store: FileStore; let now = 1_700_000_000_000;
const task = (id: string, clock: string, deleted = false): Entity => ({ id, title: id, kind: 'must_do', priority: 3, createdAt: 'x', memo: '', categoryId: null, estimatedMinutes: 0, clock, updatedAt: new Date(now).toISOString(), deletedAt: deleted ? new Date(now).toISOString() : null, migrated: false });
const phoneDoc = (tasks: Entity[], extra: Partial<SyncDocumentJson> = {}): SyncDocumentJson => ({ ...emptyDocument('android-1', new Date(now)), taskMaster: { ...emptyDocument('android-1').taskMaster, tasks }, ...extra });

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), 'hub-engine-'));
  cfg = await HubConfig.load(dir, () => now);
  store = new FileStore(dir, 'hub-0000');
  engine = new SyncEngine(store, cfg, new HlcClock('hub-0000', () => now), () => new Date(now));
  await cfg.redeemPairingCode(await cfg.issuePairingCode(), 'android-1', 'Pixel');
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

describe('SyncEngine.sync', () => {
  it('merges, saves, returns the merged document and records lastSyncAt', async () => {
    await store.update((d) => { d.taskMaster.tasks.push(task('hub-task', '10-0-hub')); return d; });
    const result = await engine.sync('android-1', phoneDoc([task('phone-task', '11-0-android-1')]));
    expect(result.document.taskMaster.tasks.map((t) => t.id).sort()).toEqual(['hub-task', 'phone-task']);
    expect(result.summary).toEqual({ added: 1, updated: 0, deleted: 0, removed: 0, warnings: 0 });
    expect(result.document.lastSyncAt).toBe(new Date(now).toISOString());
    expect((await store.read()).lastSyncAt).toBe(new Date(now).toISOString());
    expect(cfg.device('android-1')?.lastSyncAt).toBe(new Date(now).toISOString());
    expect((await store.read()).taskMaster.tasks).toHaveLength(2);
    expect(engine.lastSync?.stage).toBe('done');
  });

  it('rejects schema version < 2 with 426', async () => {
    await expect(engine.sync('android-1', { ...phoneDoc([]), version: 1 })).rejects.toMatchObject({ status: 426 });
  });

  it('rejects a client whose lastSyncAt is older than purgedBefore', async () => {
    await store.update((d) => { d.purgedBefore = '2026-09-01T00:00:00.000Z'; return d; });
    const err = await engine.sync('android-1', phoneDoc([], { lastSyncAt: '2026-08-01T00:00:00.000Z' })).catch((e) => e);
    expect(err).toBeInstanceOf(SyncRejected);
    expect(err.status).toBe(409);
    expect(err.code).toBe('purged_before');
  });

  it('exempts a device that never synced (first sync after pairing)', async () => {
    await store.update((d) => { d.purgedBefore = '2026-09-01T00:00:00.000Z'; return d; });
    await expect(engine.sync('android-1', phoneDoc([], { lastSyncAt: null }))).resolves.toBeTruthy();
  });

  it('replace mode overwrites the hub or the phone without merging', async () => {
    await store.update((d) => { d.taskMaster.tasks.push(task('hub-only', '10-0-hub')); return d; });
    const r1 = await engine.sync('android-1', phoneDoc([task('phone-only', '9-0-android-1')]), 'take_phone');
    expect(r1.document.taskMaster.tasks.map((t) => t.id)).toEqual(['phone-only']);
    expect(r1.summary).toMatchObject({ added: 1, removed: 1, deleted: 0 });
    const r2 = await engine.sync('android-1', phoneDoc([]), 'take_hub');
    expect(r2.document.taskMaster.tasks.map((t) => t.id)).toEqual(['phone-only']);
    expect(r2.summary).toMatchObject({ added: 0, updated: 0, removed: 0, deleted: 0 });
  });
});

describe('SyncEngine.purge', () => {
  it('purges tombstones older than the minimum lastSyncAt of known devices and sets purgedBefore', async () => {
    now = Date.parse('2026-09-10T00:00:00.000Z');
    await cfg.recordSync('android-1', '2026-09-05T00:00:00.000Z');
    await store.update((d) => {
      d.taskMaster.tasks.push({ ...task('old', '1-0-hub', true), deletedAt: '2026-09-01T00:00:00.000Z' });
      d.taskMaster.tasks.push({ ...task('new', '2-0-hub', true), deletedAt: '2026-09-08T00:00:00.000Z' });
      return d;
    });
    const result = await engine.purge();
    expect(result.purged).toBe(1);
    const doc = await store.read();
    expect(doc.taskMaster.tasks.map((t) => t.id)).toEqual(['new']);
    // The effective cutoff carries a 24h clock-skew margin (see PURGE_SKEW_MS).
    expect(doc.purgedBefore).toBe('2026-09-04T00:00:00.000Z');
    expect(result.purgedBefore).toBe('2026-09-04T00:00:00.000Z');
  });

  it('purges nothing when no device is known', async () => {
    await cfg.forgetDevice('android-1');
    expect((await engine.purge()).purged).toBe(0);
  });

  it('purges nothing while a known device has never synced', async () => {
    await store.update((d) => { d.taskMaster.tasks.push({ ...task('old', '1-0-hub', true), deletedAt: '2000-01-01T00:00:00.000Z' }); return d; });
    expect(await engine.purge()).toEqual({ purged: 0, purgedBefore: null });
    expect((await store.read()).taskMaster.tasks).toHaveLength(1);
  });

  it('keeps a tombstone deleted just before the cutoff and drops a clearly older one', async () => {
    now = Date.parse('2026-09-10T00:00:00.000Z');
    await cfg.recordSync('android-1', '2026-09-05T00:00:00.000Z');
    await store.update((d) => {
      d.taskMaster.tasks.push({ ...task('within-skew', '1-0-hub', true), deletedAt: '2026-09-04T23:00:00.000Z' });
      d.taskMaster.tasks.push({ ...task('beyond-skew', '2-0-hub', true), deletedAt: '2026-09-03T00:00:00.000Z' });
      return d;
    });
    expect((await engine.purge()).purged).toBe(1);
    expect((await store.read()).taskMaster.tasks.map((t) => t.id)).toEqual(['within-skew']);
  });

  it('never lowers purgedBefore', async () => {
    now = Date.parse('2026-09-10T00:00:00.000Z');
    await store.update((d) => { d.purgedBefore = '2026-09-20T00:00:00.000Z'; return d; });
    await cfg.recordSync('android-1', '2026-09-05T00:00:00.000Z');
    const result = await engine.purge();
    expect(result.purgedBefore).toBe('2026-09-20T00:00:00.000Z');
    expect((await store.read()).purgedBefore).toBe('2026-09-20T00:00:00.000Z');
  });

  it('takes the earliest lastSyncAt across devices regardless of string form', async () => {
    now = Date.parse('2026-09-10T00:00:00.000Z');
    await cfg.redeemPairingCode(await cfg.issuePairingCode(), 'android-2', 'Tab');
    await cfg.recordSync('android-1', '2026-09-08T00:00:00.000Z');
    await cfg.recordSync('android-2', '2026-09-06T09:00:00+09:00'); // 2026-09-06T00:00Z, the true minimum
    expect((await engine.purge()).purgedBefore).toBe('2026-09-05T00:00:00.000Z');
  });
});

describe('SyncEngine document validation', () => {
  it('rejects a structurally invalid document with 400 invalid_document', async () => {
    const err = await engine.sync('android-1', { version: 2 } as never).catch((e) => e);
    expect(err).toBeInstanceOf(SyncRejected);
    expect(err.status).toBe(400);
    expect(err.code).toBe('invalid_document');
  });

  it('accepts unknown extra fields so the schema can evolve', async () => {
    const doc = { ...phoneDoc([task('t1', '11-0-android-1')]), futureField: { anything: true } } as SyncDocumentJson;
    await expect(engine.sync('android-1', doc)).resolves.toBeTruthy();
  });

  it('rejects an unparsable lastSyncAt with 400 bad_timestamp', async () => {
    const err = await engine.sync('android-1', phoneDoc([], { lastSyncAt: 'yesterday' })).catch((e) => e);
    expect(err.status).toBe(400);
    expect(err.code).toBe('bad_timestamp');
  });
});

describe('SyncEngine timestamp handling', () => {
  // purgedBefore is 2026-09-01T00:00:00.000Z in every row.
  it.each([
    ['UTC Z, before', '2026-08-31T23:00:00.000Z', true],
    ['UTC Z, after', '2026-09-01T01:00:00.000Z', false],
    // No suffix is local time by definition, so these rows stay clear of any UTC offset.
    ['no suffix, before', '2026-08-30T12:00:00.000', true],
    ['no suffix, after', '2026-09-02T12:00:00.000', false],
    ['+09:00 offset, before', '2026-09-01T08:00:00+09:00', true],
    ['+09:00 offset, after', '2026-09-01T10:00:00+09:00', false],
    ['second precision, before', '2026-08-31T23:00:00Z', true],
    ['second precision, after', '2026-09-01T00:00:01Z', false],
  ])('compares %s as an instant', async (_label, lastSyncAt, rejected) => {
    await store.update((d) => { d.purgedBefore = '2026-09-01T00:00:00.000Z'; return d; });
    const outcome = await engine.sync('android-1', phoneDoc([], { lastSyncAt })).then(() => 'ok').catch((e) => e.code);
    expect(outcome).toBe(rejected ? 'purged_before' : 'ok');
  });
});

describe('SyncEngine concurrency', () => {
  it('does not lose an entity when two devices sync at once', async () => {
    await cfg.redeemPairingCode(await cfg.issuePairingCode(), 'android-2', 'Tab');
    const [a, b] = await Promise.all([
      engine.sync('android-1', phoneDoc([task('from-1', '11-0-android-1')])),
      engine.sync('android-2', { ...phoneDoc([task('from-2', '12-0-android-2')]), deviceId: 'android-2' }),
    ]);
    expect(a.document).toBeTruthy();
    expect(b.document).toBeTruthy();
    expect((await store.read()).taskMaster.tasks.map((t) => t.id).sort()).toEqual(['from-1', 'from-2']);
  });

  it('tracks progress per device and exposes the most recent as lastSync', async () => {
    await cfg.redeemPairingCode(await cfg.issuePairingCode(), 'android-2', 'Tab');
    await engine.sync('android-1', phoneDoc([]));
    await engine.sync('android-2', { ...phoneDoc([]), deviceId: 'android-2' });
    expect(engine.lastSync?.deviceId).toBe('android-2');
    expect(engine.progressFor('android-1')?.stage).toBe('done');
    expect(engine.progressFor('nobody')).toBeUndefined();
  });

  it('warns instead of failing when recording lastSyncAt fails', async () => {
    const boom = new Error('hub.json is read-only');
    const spy = vi.spyOn(cfg, 'recordSync').mockRejectedValueOnce(boom);
    const result = await engine.sync('android-1', phoneDoc([task('t1', '11-0-android-1')]));
    expect(result.warnings.some((w) => w.includes('hub.json is read-only'))).toBe(true);
    expect(result.summary.warnings).toBe(result.warnings.length);
    expect(engine.lastSync?.stage).toBe('done');
    spy.mockRestore();
  });
});
```

- [ ] **Step 2: 失敗を確認する**

Run: `npm test -- sync-engine`
Expected: FAIL

- [ ] **Step 3: 実装する**

```ts
// src/sync-engine.ts
import { z } from 'zod';
import type { HubConfig } from './config.js';
import { checkInvariants } from './invariants.js';
import { Hlc, HlcClock } from './hlc.js';
import { merge } from './merge.js';
import { isDeleted, SCHEMA_VERSION, toIsoUtc, type Entity, type SyncDocumentJson } from './model.js';
import type { FileStore } from './store.js';

export class SyncRejected extends Error {
  constructor(public readonly status: number, public readonly code: string, message: string) { super(message); }
}

export type SyncMode = 'merge' | 'take_hub' | 'take_phone';
export interface SyncSummary { added: number; updated: number; deleted: number; removed: number; warnings: number; }
export interface SyncResult { document: SyncDocumentJson; summary: SyncSummary; warnings: string[]; }
export interface SyncProgress { deviceId: string; stage: 'received' | 'merging' | 'saving' | 'done' | 'failed'; startedAt: string; finishedAt?: string; summary?: SyncSummary; error?: string; }

/** Tombstones are kept this much longer than the cutoff demands, to absorb device clock skew. */
export const PURGE_SKEW_MS = 24 * 60 * 60 * 1000;

const ENTITY_LISTS = (d: SyncDocumentJson): Entity[][] => [
  d.taskMaster.tasks, d.taskMaster.mustDoCategories, d.taskMaster.wantToDoCategories,
  d.dailyPlan.plans, d.dailyPlan.slots, d.dailyPlan.assignments,
];

const entitySchema = z.object({ id: z.string() }).passthrough();
const entityList = z.array(entitySchema);
/** Permissive on unknown fields so a newer client's extra keys survive instead of breaking sync. */
const documentSchema = z.object({
  version: z.number(),
  exportedAt: z.string().optional(),
  deviceId: z.string().optional(),
  lastSyncAt: z.string().nullish(),
  purgedBefore: z.string().nullish(),
  taskMaster: z.object({
    tasks: entityList,
    mustDoCategories: entityList,
    wantToDoCategories: entityList,
    settings: z.object({}).passthrough().optional(),
  }).passthrough(),
  dailyPlan: z.object({ plans: entityList, slots: entityList, assignments: entityList }).passthrough(),
}).passthrough();

/** Instant of an ISO string, whatever its offset or precision; NaN when unparsable. */
const instant = (value: unknown): number => (typeof value === 'string' ? Date.parse(value) : Number.NaN);

/** Implements POST /sync and tombstone purge. Pure of HTTP concerns. */
export class SyncEngine {
  private readonly progress = new Map<string, SyncProgress>();

  constructor(
    private readonly store: FileStore,
    private readonly config: HubConfig,
    private readonly clock: HlcClock,
    private readonly now: () => Date = () => new Date(),
  ) {}

  /** The most recently updated device's progress. */
  get lastSync(): SyncProgress | null {
    let last: SyncProgress | null = null;
    for (const p of this.progress.values()) last = p;
    return last;
  }

  progressFor(deviceId: string): SyncProgress | undefined {
    const p = this.progress.get(deviceId);
    return p ? { ...p } : undefined;
  }

  private setProgress(deviceId: string, patch: Partial<SyncProgress> & Pick<SyncProgress, 'stage'>): void {
    const previous = this.progress.get(deviceId);
    const next: SyncProgress = { deviceId, startedAt: previous?.startedAt ?? this.now().toISOString(), ...previous, ...patch };
    // Re-insert so Map iteration order tracks recency.
    this.progress.delete(deviceId);
    this.progress.set(deviceId, next);
  }

  async sync(deviceId: string, incoming: SyncDocumentJson, mode: SyncMode = 'merge'): Promise<SyncResult> {
    const startedAt = this.now().toISOString();
    this.progress.delete(deviceId);
    this.setProgress(deviceId, { stage: 'received', startedAt, finishedAt: undefined, summary: undefined, error: undefined });
    try {
      const parsed = documentSchema.safeParse(incoming);
      if (!parsed.success) {
        throw new SyncRejected(400, 'invalid_document', `document does not match the sync schema: ${parsed.error.issues.map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`).join('; ')}`);
      }
      if (typeof incoming.version !== 'number' || incoming.version < SCHEMA_VERSION) {
        throw new SyncRejected(426, 'upgrade_required', `client schema ${incoming.version} is older than ${SCHEMA_VERSION}; update the app`);
      }
      if (incoming.version > SCHEMA_VERSION) {
        throw new SyncRejected(400, 'unsupported_version', `client schema ${incoming.version} is newer than the hub`);
      }
      const incomingLastSync = incoming.lastSyncAt ?? null;
      if (incomingLastSync !== null && Number.isNaN(instant(incomingLastSync))) {
        throw new SyncRejected(400, 'bad_timestamp', `lastSyncAt ${JSON.stringify(incomingLastSync)} is not a parsable timestamp; send UTC ISO-8601`);
      }

      const at = this.now().toISOString();
      let summary: SyncSummary = { added: 0, updated: 0, deleted: 0, removed: 0, warnings: 0 };
      let warnings: string[] = [];
      this.setProgress(deviceId, { stage: 'merging' });
      // Guard, merge, check and summarize all run inside the one locked read-modify-write,
      // so a concurrent sync cannot merge against a document that is already stale.
      const saved = await this.store.update((current) => {
        const purgedBefore = instant(current.purgedBefore);
        if (mode === 'merge' && incomingLastSync !== null && !Number.isNaN(purgedBefore) && instant(incomingLastSync) < purgedBefore) {
          throw new SyncRejected(409, 'purged_before', `this device last synced at ${incomingLastSync}, before the hub purged tombstones at ${current.purgedBefore}; choose take_hub or take_phone`);
        }
        for (const list of [...ENTITY_LISTS(current), ...ENTITY_LISTS(incoming)]) for (const e of list) { const h = Hlc.tryParse(e.clock); if (h) this.clock.observe(h); }

        let merged: SyncDocumentJson;
        let mergeWarnings: string[] = [];
        if (mode === 'take_phone') merged = { ...incoming, deviceId: current.deviceId, purgedBefore: current.purgedBefore ?? null };
        else if (mode === 'take_hub') merged = current;
        else { const r = merge(current, incoming); merged = r.document; mergeWarnings = r.warnings; }
        merged.lastSyncAt = at;
        warnings = [...mergeWarnings, ...checkInvariants(merged).map((v) => `${v.code}: ${v.message}`)];
        summary = summarize(current, merged, warnings.length);
        return merged;
      });
      this.setProgress(deviceId, { stage: 'saving' });

      try {
        await this.config.recordSync(deviceId, at);
      } catch (error) {
        // The document is already durable; a failed bookkeeping write must not undo it.
        warnings = [...warnings, `record_sync_failed: ${String((error as Error).message ?? error)}`];
        summary = { ...summary, warnings: warnings.length };
      }
      this.setProgress(deviceId, { stage: 'done', finishedAt: at, summary });
      return { document: saved, summary, warnings };
    } catch (error) {
      this.setProgress(deviceId, { stage: 'failed', finishedAt: this.now().toISOString(), error: String((error as Error).message ?? error) });
      throw error;
    }
  }

  /** Drops tombstones whose device-authored `deletedAt` is PURGE_SKEW_MS before the earliest device lastSyncAt; a clock slower than that margin can still lose a tombstone early. Nothing is purged while a device has never synced or none is known. */
  async purge(): Promise<{ purged: number; purgedBefore: string | null }> {
    const devices = this.config.devices();
    if (devices.length === 0 || devices.some((d) => !d.lastSyncAt)) return { purged: 0, purgedBefore: null };
    const earliest = Math.min(...devices.map((d) => instant(d.lastSyncAt)));
    if (Number.isNaN(earliest)) return { purged: 0, purgedBefore: null };
    const cutoffMs = earliest - PURGE_SKEW_MS;
    const cutoff = new Date(cutoffMs).toISOString();
    let purged = 0;
    let effective = cutoff;
    await this.store.update((doc) => {
      const keep = (list: Entity[]) => list.filter((e) => { const drop = isDeleted(e) && instant(e.deletedAt) < cutoffMs; if (drop) purged += 1; return !drop; });
      doc.taskMaster.tasks = keep(doc.taskMaster.tasks);
      doc.taskMaster.mustDoCategories = keep(doc.taskMaster.mustDoCategories);
      doc.taskMaster.wantToDoCategories = keep(doc.taskMaster.wantToDoCategories);
      doc.dailyPlan.plans = keep(doc.dailyPlan.plans);
      doc.dailyPlan.slots = keep(doc.dailyPlan.slots);
      doc.dailyPlan.assignments = keep(doc.dailyPlan.assignments);
      // Monotonic: purgedBefore only ever moves forward.
      const previous = instant(doc.purgedBefore);
      effective = !Number.isNaN(previous) && previous > cutoffMs ? toIsoUtc(doc.purgedBefore) ?? cutoff : cutoff;
      doc.purgedBefore = effective;
      return doc;
    });
    return { purged, purgedBefore: effective };
  }
}

function summarize(before: SyncDocumentJson, after: SyncDocumentJson, warnings: number): SyncSummary {
  const index = (d: SyncDocumentJson) => new Map(ENTITY_LISTS(d).flat().map((e) => [e.id, e]));
  const a = index(before); const b = index(after);
  let added = 0, updated = 0, deleted = 0, removed = 0;
  for (const [id, e] of b) {
    const prev = a.get(id);
    if (!prev) { if (!isDeleted(e)) added += 1; continue; }
    if (isDeleted(e) && !isDeleted(prev)) deleted += 1;
    else if (!isDeleted(e) && e.clock !== prev.clock) updated += 1;
  }
  for (const id of a.keys()) if (!b.has(id)) removed += 1;
  return { added, updated, deleted, removed, warnings };
}
```

- [ ] **Step 4: テストを通す**

Run: `npm test -- sync-engine && npm run typecheck`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add tools/hub/src/sync-engine.ts tools/hub/test/sync-engine.test.ts
git commit -m "feat(hub): sync engine with purgedBefore guard and tombstone purge / 同期エンジンと墓標掃除"
```

#### レビュー反映（バッチ 1）

上のコードブロックはレビュー指摘を反映済みの最終形。指摘と対応は以下（コミット `fix(hub): serialize sync inside the store lock and compare timestamps as instants`）。

- **C1**: `purgedBefore` 判定・HLC observe・マージ・不変条件・集計を 1 回の `store.update((current) => ...)` の中で実行し、同時 `sync` でのデータ喪失を解消（`update` は throw をそのまま伝播するので 409 はそのまま動く）。
- **C2**: 時刻比較を全て `Date.parse` の瞬間比較に変更（`Z` 無し・`+09:00` 付き・秒精度も正しく判定）。解釈不能な `lastSyncAt` は `SyncRejected(400, 'bad_timestamp')`。`model.ts` の `toIsoUtc` を export して境界で正規化。
- **I1**: 受信文書を zod スキーマ（`passthrough`＝未知フィールドは許容）で検証し、不正なら `400 invalid_document`。
- **I2**: `purge()` の `purgedBefore` を単調増加（後退させない）にし、実効値を返す。
- **I3**: 墓標掃除のカットオフから 24 時間のスキュー余裕（`PURGE_SKEW_MS`）を引く。`deletedAt` は端末が書く値なので、doc コメントで「これ以上遅れた時計は依然として早期削除され得る」と正直に明記。
- **I4**: `SyncSummary` に `removed`（before に在り after に無い件数）を追加（加算のみ、既存フィールドは維持）。`take_hub` / `take_phone` の削除件数が 0 に見えていた問題を解消。
- **I5**: `hub.json` の保存を「一意な tmp 名（pid＋乱数）＋ rename」＋インスタンス内 Promise チェーンで直列化。単一ディレクトリ単一インスタンス前提をクラスコメントに明記。
- **I6**: `hub.json` の `JSON.parse` をガードし、`certPem` / `keyPem` が文字列・`devices` が配列であることを検証。壊れていたら `hub.json.broken-<ts>` に退避してエラー（証明書の黙示再生成をやめ、ピン留め全滅を防ぐ）。`fingerprint` は毎回 `certPem` から再計算。
- **I7**: 自己署名証明書に SAN（`frelocator-hub.local` / `localhost` / IP `127.0.0.1`）と `basicConstraints` / `keyUsage` を付与。秘密鍵が証明書の公開鍵と対応することを署名検証でテスト。
- **I8**: 端末トークンとペアリングコードの比較を sha256 ダイジェスト＋`timingSafeEqual` の定数時間比較に変更（早期 return もしない）。
- **軽微**: 期限切れペアリングコードは誤コード入力でも無条件に破棄／有効コードは誤入力後も使える、進捗は `Map<deviceId, SyncProgress>`（`lastSync` getter＋`progressFor`）、`config.recordSync` の失敗は warning にして同期は成功扱い、`lastSyncAt = at` を同じ `store.update` で永続化。

---

### Task 3: LanServer（HTTPS、/pair /sync /health）

**Files:**
- Create: `src/lan-server.ts`、`src/net.ts`
- Modify: `package.json`（`bonjour-service: ^1.3.0`）
- Test: `test/lan-server.test.ts`

> **NOTE（バッチ 1 レビューの申し送り）:** 以下は本タスクの実装時に必ず入れること。
> - `/pair` の失敗回数に上限を設ける（例: 10 回失敗でそのコードを無効化）。`HubConfig` 側でコード単位に失敗回数を持つ。
> - リクエストボディにサイズ上限を設ける（例: 16 MB 超は `413`）。ストリーム受信中に打ち切る。
> - `SyncRejected` の 400 系（`invalid_document` / `bad_timestamp` / `unsupported_version`）も `{ error: { code, message } }` エンベロープにマップする（現状の 409 / 426 と同様）。

- [ ] **Step 1: 失敗するテストを書く**

```ts
// test/lan-server.test.ts
import { mkdtempSync, rmSync } from 'node:fs';
import { Agent, request } from 'node:https';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { HubConfig } from '../src/config.js';
import { HlcClock } from '../src/hlc.js';
import { LanServer } from '../src/lan-server.js';
import { emptyDocument } from '../src/model.js';
import { FileStore } from '../src/store.js';
import { SyncEngine } from '../src/sync-engine.js';
import { fingerprintOf } from '../src/tls.js';

let dir: string; let server: LanServer; let cfg: HubConfig;
const call = (method: string, path: string, body?: unknown, token?: string, expectFp?: string) => new Promise<{ status: number; json: any }>((resolve, reject) => {
  const agent = new Agent({ rejectUnauthorized: false, checkServerIdentity: () => undefined });
  const req = request({ host: '127.0.0.1', port: server.port, method, path, agent, headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) } }, (res) => {
    if (expectFp) expect(fingerprintOf(`-----BEGIN CERTIFICATE-----\n${(res.socket as any).getPeerCertificate().raw.toString('base64')}\n-----END CERTIFICATE-----`)).toBe(expectFp);
    let data = ''; res.on('data', (c) => (data += c)); res.on('end', () => resolve({ status: res.statusCode!, json: data ? JSON.parse(data) : null }));
  });
  req.on('error', reject);
  if (body) req.write(JSON.stringify(body));
  req.end();
});

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), 'hub-lan-'));
  cfg = await HubConfig.load(dir);
  const store = new FileStore(dir, 'hub-0000');
  server = new LanServer(cfg, new SyncEngine(store, cfg, new HlcClock('hub-0000')), { port: 0, host: '127.0.0.1', advertise: false });
  await server.start();
});
afterEach(async () => { await server.stop(); rmSync(dir, { recursive: true, force: true }); });

describe('LanServer', () => {
  it('serves the hub certificate and requires a token for /health', async () => {
    expect((await call('GET', '/health', undefined, undefined, cfg.fingerprint)).status).toBe(401);
  });

  it('pairs with a valid code and then syncs', async () => {
    const code = await cfg.issuePairingCode();
    const pair = await call('POST', '/pair', { code, deviceId: 'android-1', name: 'Pixel' });
    expect(pair.status).toBe(200);
    expect(pair.json.token).toMatch(/^[a-f0-9]{64}$/);
    expect(pair.json.hubDeviceId).toBe('hub-0000');
    expect((await call('POST', '/pair', { code, deviceId: 'android-2', name: 'x' })).status).toBe(403);

    const health = await call('GET', '/health', undefined, pair.json.token);
    expect(health.status).toBe(200);
    expect(health.json.ok).toBe(true);
    expect(health.json).not.toHaveProperty('deviceId');

    const sync = await call('POST', '/sync', emptyDocument('android-1'), pair.json.token);
    expect(sync.status).toBe(200);
    expect(sync.json.document.version).toBe(2);
    expect(sync.json.summary).toBeTruthy();
    const get = await call('GET', '/sync', undefined, pair.json.token);
    expect(get.status).toBe(200);
    expect(get.json.document.deviceId).toBe('hub-0000');
  });

  it('maps engine rejections to their status codes', async () => {
    const token = await cfg.redeemPairingCode(await cfg.issuePairingCode(), 'android-1', 'Pixel');
    const r = await call('POST', '/sync', { ...emptyDocument('android-1'), version: 1 }, token);
    expect(r.status).toBe(426);
    expect(r.json.error.code).toBe('upgrade_required');
  });

  it('rejects wrong tokens and unknown routes', async () => {
    expect((await call('GET', '/sync', undefined, 'deadbeef')).status).toBe(401);
    const token = await cfg.redeemPairingCode(await cfg.issuePairingCode(), 'android-1', 'Pixel');
    expect((await call('GET', '/nope', undefined, token)).status).toBe(404);
  });
});
```

- [ ] **Step 2: 失敗を確認する**

Run: `npm install bonjour-service@^1.3.0 && npm test -- lan-server`
Expected: FAIL

- [ ] **Step 3: 実装する**

```ts
// src/net.ts
import { networkInterfaces } from 'node:os';
import { Bonjour, type Service } from 'bonjour-service';

/** First non-internal IPv4 address, preferring en0/en1 (macOS Wi-Fi/Ethernet). */
export function lanAddress(): string | null {
  const ifaces = networkInterfaces();
  const names = Object.keys(ifaces).sort((a, b) => (a.startsWith('en') ? -1 : 0) - (b.startsWith('en') ? -1 : 0));
  for (const name of names) for (const i of ifaces[name] ?? []) if (i.family === 'IPv4' && !i.internal) return i.address;
  return null;
}

export class MdnsAdvertiser {
  private bonjour: Bonjour | null = null; private service: Service | null = null;
  start(port: number, hubDeviceId: string): void {
    this.bonjour = new Bonjour();
    this.service = this.bonjour.publish({ name: 'frelocator-hub', type: 'frelocator', protocol: 'tcp', port, txt: { hub: hubDeviceId, v: '2' } });
  }
  async stop(): Promise<void> {
    await new Promise<void>((resolve) => { if (!this.service) return resolve(); this.service.stop(() => resolve()); });
    this.bonjour?.destroy(); this.bonjour = null; this.service = null;
  }
}
```

```ts
// src/lan-server.ts
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:https';
import { z } from 'zod';
import type { HubConfig } from './config.js';
import { MdnsAdvertiser, lanAddress } from './net.js';
import { SyncEngine, SyncRejected, type SyncMode } from './sync-engine.js';
import type { SyncDocumentJson } from './model.js';

export interface LanServerOptions { port: number; host: string; advertise: boolean; hubDeviceId?: string; }
const MAX_BODY = 20 * 1024 * 1024;
const pairSchema = z.object({ code: z.string().min(1), deviceId: z.string().min(1), name: z.string().max(80).default('') });
const syncQuery = z.enum(['merge', 'take_hub', 'take_phone']);

export class LanServer {
  private server: Server | null = null;
  private readonly mdns = new MdnsAdvertiser();
  port = 0;

  constructor(private readonly config: HubConfig, private readonly engine: SyncEngine, private readonly options: LanServerOptions) {}

  get hubDeviceId(): string { return this.options.hubDeviceId ?? 'hub-0000'; }
  get address(): string | null { return this.options.host === '0.0.0.0' ? lanAddress() : this.options.host; }

  async start(): Promise<void> {
    this.server = createServer({ cert: this.config.certPem, key: this.config.keyPem }, (req, res) => void this.handle(req, res).catch((e) => send(res, 500, { error: { code: 'internal', message: String(e) } })));
    await new Promise<void>((resolve, reject) => { this.server!.once('error', reject); this.server!.listen(this.options.port, this.options.host, () => resolve()); });
    this.port = (this.server.address() as { port: number }).port;
    if (this.options.advertise) this.mdns.start(this.port, this.hubDeviceId);
  }

  async stop(): Promise<void> {
    await this.mdns.stop();
    await new Promise<void>((resolve) => (this.server ? this.server.close(() => resolve()) : resolve()));
    this.server = null;
  }

  private async handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = new URL(req.url ?? '/', 'https://local');
    if (req.method === 'POST' && url.pathname === '/pair') return this.pair(req, res);
    const token = (req.headers.authorization ?? '').replace(/^Bearer\s+/i, '');
    const device = token ? this.config.deviceForToken(token) : undefined;
    if (!device) return send(res, 401, { error: { code: 'unauthorized', message: 'missing or invalid token' } });
    if (req.method === 'GET' && url.pathname === '/health') return send(res, 200, { ok: true, serverTime: new Date().toISOString(), schema: 2 });
    if (req.method === 'GET' && url.pathname === '/sync') {
      const document = await this.engine['store'].read();
      return send(res, 200, { document, hubDeviceId: this.hubDeviceId });
    }
    if (req.method === 'POST' && url.pathname === '/sync') {
      const mode = syncQuery.safeParse(url.searchParams.get('mode') ?? 'merge');
      if (!mode.success) return send(res, 400, { error: { code: 'bad_mode', message: 'mode must be merge|take_hub|take_phone' } });
      const body = await readJson(req);
      try {
        const result = await this.engine.sync(device.deviceId, body as SyncDocumentJson, mode.data as SyncMode);
        return send(res, 200, result);
      } catch (error) {
        if (error instanceof SyncRejected) return send(res, error.status, { error: { code: error.code, message: error.message } });
        throw error;
      }
    }
    return send(res, 404, { error: { code: 'not_found', message: `${req.method} ${url.pathname}` } });
  }

  private async pair(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const parsed = pairSchema.safeParse(await readJson(req));
    if (!parsed.success) return send(res, 400, { error: { code: 'bad_request', message: parsed.error.message } });
    try {
      const token = await this.config.redeemPairingCode(parsed.data.code, parsed.data.deviceId, parsed.data.name);
      return send(res, 200, { token, hubDeviceId: this.hubDeviceId, fingerprint: this.config.fingerprint });
    } catch (error) {
      return send(res, 403, { error: { code: 'pairing_failed', message: String((error as Error).message) } });
    }
  }
}

function send(res: ServerResponse, status: number, body: unknown): void {
  const text = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text) });
  res.end(text);
}

async function readJson(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = []; let size = 0;
  for await (const chunk of req) { size += (chunk as Buffer).length; if (size > MAX_BODY) throw new Error('body too large'); chunks.push(chunk as Buffer); }
  const text = Buffer.concat(chunks).toString('utf8');
  return text ? JSON.parse(text) : {};
}
```

`SyncEngine` に `get store()` を公開して `this.engine['store']` のブラケットアクセスをやめる（`readonly store` を public にする）。

- [ ] **Step 4: テストを通す**

Run: `npm test -- lan-server && npm run typecheck`
Expected: PASS（`bonjour-service` はテストでは `advertise: false`）

- [ ] **Step 5: コミット**

```bash
git add tools/hub/package.json tools/hub/package-lock.json tools/hub/src/net.ts tools/hub/src/lan-server.ts tools/hub/src/sync-engine.ts tools/hub/test/lan-server.test.ts
git commit -m "feat(hub): HTTPS LAN server with pairing, bearer tokens and mDNS / LAN サーバーとペアリング"
```

---

### Task 4: QrCodec（gzip → base45 → CRC32 付きフレーム）

**Files:**
- Create: `src/qr-codec.ts`
- Test: `test/qr-codec.test.ts`

フレーム形式（設計書）: `FRL2:<全体 SHA-256 先頭 16 文字（大文字 hex）>:<index>:<total>:<CRC32（大文字 hex 8 桁）>:<chunk>`。全文字が QR 英数モード集合 `0-9 A-Z 空白 $%*+-./:` に収まること。base45（RFC 9285）は大文字英数と ` $%*+-./:` のみを使うので条件を満たす。

- [ ] **Step 1: 失敗するテストを書く**

```ts
// test/qr-codec.test.ts
import { describe, expect, it } from 'vitest';
import { base45Decode, base45Encode, crc32, decodeFrames, encodeFrames, FrameSet } from '../src/qr-codec.js';

const ALNUM = /^[0-9A-Z $%*+\-./:]*$/;

describe('base45', () => {
  it('round-trips RFC 9285 vectors', () => {
    expect(base45Encode(Buffer.from('AB'))).toBe('BB8');
    expect(base45Encode(Buffer.from('Hello!!'))).toBe('%69 VD92EX0');
    expect(base45Encode(Buffer.from('base-45'))).toBe('UJCLQE7W581');
    expect(base45Decode('QED8WEX0').toString()).toBe('ietf!');
    expect(() => base45Decode('GGW')).toThrow();
  });
});

describe('crc32', () => {
  it('matches the standard check value', () => {
    expect(crc32(Buffer.from('123456789'))).toBe('CBF43926');
  });
});

describe('frames', () => {
  const doc = { version: 2, taskMaster: { tasks: Array.from({ length: 200 }, (_, i) => ({ id: `t${i}`, title: `タスク ${i}`, memo: 'x'.repeat(40) })) } };

  it('encodes into alphanumeric-only frames of <= 600 payload chars and decodes in any order', () => {
    const frames = encodeFrames(doc);
    expect(frames.length).toBeGreaterThan(1);
    for (const f of frames) { expect(f).toMatch(ALNUM); expect(f.split(':')[5].length).toBeLessThanOrEqual(600); expect(f.startsWith('FRL2:')).toBe(true); }
    const set = new FrameSet();
    for (const f of [...frames].reverse()) set.add(f);
    expect(set.isComplete).toBe(true);
    expect(set.received).toBe(frames.length);
    expect(decodeFrames(set)).toEqual(doc);
  });

  it('reports progress and ignores corrupted or foreign frames', () => {
    const frames = encodeFrames(doc);
    const set = new FrameSet();
    set.add(frames[0]);
    expect(set.total).toBe(frames.length);
    expect(set.missing()).toEqual(Array.from({ length: frames.length - 1 }, (_, i) => i + 1));
    const corrupted = frames[1].slice(0, -1) + (frames[1].endsWith('A') ? 'B' : 'A');
    expect(set.add(corrupted)).toBe('crc_mismatch');
    const foreign = encodeFrames({ other: true })[0];
    expect(set.add(foreign)).toBe('different_payload');
    expect(set.add(frames[0])).toBe('duplicate');
  });

  it('warns above 80 frames', () => {
    const big = { blob: 'y'.repeat(80 * 600) };
    expect(() => encodeFrames(big, { maxFrames: 80 })).toThrow(/80 frames/);
  });
});
```

- [ ] **Step 2: 失敗を確認する**

Run: `npm test -- qr-codec`
Expected: FAIL

- [ ] **Step 3: 実装する**

```ts
// src/qr-codec.ts
import { createHash } from 'node:crypto';
import { gunzipSync, gzipSync } from 'node:zlib';

const B45 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:';

export function base45Encode(buf: Buffer): string {
  let out = '';
  for (let i = 0; i < buf.length; i += 2) {
    if (i + 1 < buf.length) {
      const n = buf[i] * 256 + buf[i + 1];
      const e = Math.floor(n / (45 * 45)); const d = Math.floor((n % (45 * 45)) / 45); const c = n % 45;
      out += B45[c] + B45[d] + B45[e];
    } else {
      const n = buf[i]; out += B45[n % 45] + B45[Math.floor(n / 45)];
    }
  }
  return out;
}

export function base45Decode(text: string): Buffer {
  const vals = [...text].map((ch) => { const v = B45.indexOf(ch); if (v < 0) throw new Error(`invalid base45 char ${JSON.stringify(ch)}`); return v; });
  const out: number[] = [];
  for (let i = 0; i < vals.length; i += 3) {
    if (i + 2 < vals.length) {
      const n = vals[i] + vals[i + 1] * 45 + vals[i + 2] * 45 * 45;
      if (n > 0xffff) throw new Error('invalid base45 triplet');
      out.push(n >> 8, n & 0xff);
    } else if (i + 1 < vals.length) {
      const n = vals[i] + vals[i + 1] * 45;
      if (n > 0xff) throw new Error('invalid base45 pair');
      out.push(n);
    } else throw new Error('invalid base45 length');
  }
  return Buffer.from(out);
}

const CRC_TABLE = (() => { const t = new Uint32Array(256); for (let n = 0; n < 256; n += 1) { let c = n; for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
export function crc32(buf: Buffer | string): string {
  const b = typeof buf === 'string' ? Buffer.from(buf, 'utf8') : buf;
  let c = 0xffffffff;
  for (const byte of b) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return ((c ^ 0xffffffff) >>> 0).toString(16).toUpperCase().padStart(8, '0');
}

export const CHUNK_CHARS = 600;
export interface EncodeOptions { chunkChars?: number; maxFrames?: number; }

/** `FRL2:<sha16>:<i>:<n>:<crc>:<chunk>` — all characters in the QR alphanumeric set. */
export function encodeFrames(value: unknown, options: EncodeOptions = {}): string[] {
  const chunkChars = options.chunkChars ?? CHUNK_CHARS;
  const json = Buffer.from(JSON.stringify(value), 'utf8');
  const text = base45Encode(gzipSync(json, { level: 9 }));
  const hash = createHash('sha256').update(json).digest('hex').slice(0, 16).toUpperCase();
  const total = Math.max(1, Math.ceil(text.length / chunkChars));
  if (options.maxFrames && total > options.maxFrames) throw new Error(`payload needs ${total} frames, more than ${options.maxFrames} frames; use LAN sync instead`);
  const frames: string[] = [];
  for (let i = 0; i < total; i += 1) {
    const chunk = text.slice(i * chunkChars, (i + 1) * chunkChars);
    const frame = `FRL2:${hash}:${i}:${total}:${crc32(chunk)}:${chunk}`;
    if (!/^[0-9A-Z $%*+\-./:]*$/.test(frame)) throw new Error('frame contains a non-alphanumeric-mode character');
    frames.push(frame);
  }
  return frames;
}

export type AddResult = 'added' | 'duplicate' | 'crc_mismatch' | 'different_payload' | 'malformed';

export class FrameSet {
  hash: string | null = null; total = 0;
  private chunks = new Map<number, string>();
  get received(): number { return this.chunks.size; }
  get isComplete(): boolean { return this.total > 0 && this.chunks.size === this.total; }
  missing(): number[] { return Array.from({ length: this.total }, (_, i) => i).filter((i) => !this.chunks.has(i)); }

  add(frame: string): AddResult {
    const parts = frame.split(':');
    if (parts.length !== 6 || parts[0] !== 'FRL2') return 'malformed';
    const [, hash, iStr, nStr, crc, chunk] = parts;
    const i = Number(iStr); const n = Number(nStr);
    if (!Number.isInteger(i) || !Number.isInteger(n) || i < 0 || i >= n) return 'malformed';
    if (this.hash && this.hash !== hash) return 'different_payload';
    if (crc32(chunk) !== crc) return 'crc_mismatch';
    if (!this.hash) { this.hash = hash; this.total = n; }
    if (this.chunks.has(i)) return 'duplicate';
    this.chunks.set(i, chunk);
    return 'added';
  }

  reset(): void { this.hash = null; this.total = 0; this.chunks.clear(); }
}

export function decodeFrames(set: FrameSet): unknown {
  if (!set.isComplete) throw new Error(`incomplete: missing frames ${set.missing().join(',')}`);
  const text = Array.from({ length: set.total }, (_, i) => set['chunks'].get(i)!).join('');
  const json = gunzipSync(base45Decode(text));
  const hash = createHash('sha256').update(json).digest('hex').slice(0, 16).toUpperCase();
  if (hash !== set.hash) throw new Error('payload hash mismatch after reassembly');
  return JSON.parse(json.toString('utf8'));
}
```

`set['chunks']` はテストと同様のブラケットアクセスになるので、`FrameSet` に `chunkAt(i): string | undefined` を公開してそれを使う。

- [ ] **Step 4: テストを通す**

Run: `npm test -- qr-codec && npm run typecheck`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add tools/hub/src/qr-codec.ts tools/hub/test/qr-codec.test.ts
git commit -m "feat(hub): QR frame codec (gzip, base45, crc32) / QR フレームコーデック"
```

---

### Task 5: LocalPages（127.0.0.1 のペアリング QR とデータ QR）

**Files:**
- Create: `src/local-pages.ts`
- Modify: `package.json`（`qrcode: ^1.5.4`、`@types/qrcode: ^1.5.5` を devDependencies）
- Test: `test/local-pages.test.ts`

- [ ] **Step 1: 失敗するテストを書く**

```ts
// test/local-pages.test.ts
import { mkdtempSync, rmSync } from 'node:fs';
import { get } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { HubConfig } from '../src/config.js';
import { LocalPages } from '../src/local-pages.js';
import { FileStore } from '../src/store.js';

let dir: string; let pages: LocalPages; let cfg: HubConfig;
const fetchText = (path: string) => new Promise<{ status: number; body: string; type: string }>((resolve, reject) => {
  get({ host: '127.0.0.1', port: pages.port, path }, (res) => { let b = ''; res.on('data', (c) => (b += c)); res.on('end', () => resolve({ status: res.statusCode!, body: b, type: String(res.headers['content-type']) })); }).on('error', reject);
});

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), 'hub-pages-'));
  cfg = await HubConfig.load(dir);
  pages = new LocalPages(cfg, new FileStore(dir, 'hub-0000'), { port: 0, lanUrl: () => 'https://192.168.1.10:47820' });
  await pages.start();
});
afterEach(async () => { await pages.stop(); rmSync(dir, { recursive: true, force: true }); });

describe('LocalPages', () => {
  it('/pair issues a code, renders an SVG QR of the frelocator://pair URL and shows the fingerprint', async () => {
    const r = await fetchText('/pair');
    expect(r.status).toBe(200);
    expect(r.type).toContain('text/html');
    expect(r.body).toContain('<svg');
    const code = cfg.pairingCode();
    expect(code).not.toBeNull();
    expect(r.body).toContain(`frelocator://pair?host=192.168.1.10&amp;port=47820&amp;fp=${cfg.fingerprint}&amp;code=${code!.code}`);
    expect(r.body).toContain(code!.code);
  });

  it('/qr renders animated frames as JSON for the page script and /qr/frames.json lists them', async () => {
    const page = await fetchText('/qr');
    expect(page.status).toBe(200);
    expect(page.body).toContain('id="frame"');
    const frames = await fetchText('/qr/frames.json');
    expect(frames.status).toBe(200);
    const json = JSON.parse(frames.body);
    expect(json.total).toBeGreaterThan(0);
    expect(json.svgs).toHaveLength(json.total);
    expect(json.svgs[0]).toContain('<svg');
  });

  it('is not reachable on 0.0.0.0 semantics: binds 127.0.0.1 only', () => {
    expect(pages.host).toBe('127.0.0.1');
  });
});
```

- [ ] **Step 2: 失敗を確認する**

Run: `npm install qrcode@^1.5.4 && npm install -D @types/qrcode@^1.5.5 && npm test -- local-pages`
Expected: FAIL

- [ ] **Step 3: 実装する**

```ts
// src/local-pages.ts
import { createServer, type Server } from 'node:http';
import QRCode from 'qrcode';
import type { HubConfig } from './config.js';
import { encodeFrames } from './qr-codec.js';
import type { FileStore } from './store.js';

export interface LocalPagesOptions { port: number; lanUrl: () => string | null; }
const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

/** Loopback-only pages. Never bind this to a LAN interface: /pair prints the pairing code. */
export class LocalPages {
  private server: Server | null = null;
  readonly host = '127.0.0.1';
  port = 0;

  constructor(private readonly config: HubConfig, private readonly store: FileStore, private readonly options: LocalPagesOptions) {}

  async start(): Promise<void> {
    this.server = createServer((req, res) => void this.handle(req.url ?? '/').then(({ status, type, body }) => { res.writeHead(status, { 'content-type': type }); res.end(body); }).catch((e) => { res.writeHead(500, { 'content-type': 'text/plain' }); res.end(String(e)); }));
    await new Promise<void>((resolve) => this.server!.listen(this.options.port, this.host, () => resolve()));
    this.port = (this.server.address() as { port: number }).port;
  }

  async stop(): Promise<void> { await new Promise<void>((r) => (this.server ? this.server.close(() => r()) : r())); this.server = null; }

  pairingUrl(code: string): string | null {
    const lan = this.options.lanUrl(); if (!lan) return null;
    const u = new URL(lan);
    return `frelocator://pair?host=${u.hostname}&port=${u.port}&fp=${this.config.fingerprint}&code=${code}`;
  }

  private async handle(path: string): Promise<{ status: number; type: string; body: string }> {
    if (path === '/pair') {
      const code = await this.config.issuePairingCode();
      const url = this.pairingUrl(code);
      if (!url) return { status: 503, type: 'text/html; charset=utf-8', body: page('ペアリング', '<p>LAN の IP アドレスが見つかりません。Wi-Fi に接続してから再読み込みしてください。</p>') };
      const svg = await QRCode.toString(url, { type: 'svg', errorCorrectionLevel: 'M', margin: 1 });
      return { status: 200, type: 'text/html; charset=utf-8', body: page('FRELOCATOR とペアリング', `
        <p>スマホの FRELOCATOR で「設定 › PC と同期 › PC とペアリング」を開き、この QR を読み取ってください。5 分で無効になります。</p>
        <div class="qr">${svg}</div>
        <p class="mono">コード: <b>${esc(code)}</b></p>
        <p class="mono small">URL: ${esc(url)}</p>
        <p class="small">証明書フィンガープリント（SHA-256）: <span class="mono">${esc(this.config.fingerprint)}</span></p>`) };
    }
    if (path === '/qr/frames.json') {
      const doc = await this.store.read();
      const frames = encodeFrames(doc, { maxFrames: 200 });
      const svgs = await Promise.all(frames.map((f) => QRCode.toString(f, { type: 'svg', errorCorrectionLevel: 'M', margin: 1 })));
      return { status: 200, type: 'application/json', body: JSON.stringify({ total: frames.length, warn: frames.length > 80, svgs }) };
    }
    if (path === '/qr') {
      return { status: 200, type: 'text/html; charset=utf-8', body: page('QR でスマホに送る', `
        <p>スマホの「設定 › PC と同期 › QR で受け取る」でカメラをこの画面に向け続けてください。コマは繰り返し表示されます。</p>
        <div class="qr" id="frame"></div>
        <p class="mono" id="status">読み込み中…</p>
        <label>表示間隔 <input id="interval" type="range" min="200" max="1000" step="50" value="400"> <span id="ms">400</span> ms</label>
        <script>
          const status = document.getElementById('status'); const frame = document.getElementById('frame');
          const slider = document.getElementById('interval'); const ms = document.getElementById('ms');
          slider.oninput = () => { ms.textContent = slider.value; };
          fetch('/qr/frames.json').then(r => r.json()).then(({ total, svgs, warn }) => {
            let i = 0;
            if (warn) status.textContent = 'コマ数が多いため時間がかかります。可能なら LAN 同期を使ってください。';
            const tick = () => { frame.innerHTML = svgs[i]; status.textContent = 'コマ ' + (i + 1) + ' / ' + total + (warn ? '（多い）' : ''); i = (i + 1) % total; setTimeout(tick, Number(slider.value)); };
            tick();
          }).catch(e => { status.textContent = 'エラー: ' + e; });
        </script>`) };
    }
    return { status: 404, type: 'text/plain', body: 'not found' };
  }
}

function page(title: string, body: string): string {
  return `<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>${esc(title)}</title>
  <style>body{font-family:-apple-system,"Hiragino Sans",sans-serif;max-width:640px;margin:32px auto;padding:0 16px;color:#1b2733}.qr svg{width:min(90vw,480px);height:auto}.mono{font-family:Menlo,monospace}.small{font-size:12px;color:#5c6672}</style>
  </head><body><h1>${esc(title)}</h1>${body}</body></html>`;
}
```

- [ ] **Step 4: テストを通す**

Run: `npm test -- local-pages && npm run typecheck`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add tools/hub/package.json tools/hub/package-lock.json tools/hub/src/local-pages.ts tools/hub/test/local-pages.test.ts
git commit -m "feat(hub): loopback pages for pairing QR and animated data QR / ペアリングとデータ QR のローカルページ"
```

---

### Task 6: MCP ツールの完成（import_file / purge / forget / rotate / sync_status）と起動配線

**Files:**
- Modify: `src/tools.ts`、`src/index.ts`
- Test: `test/tools.plan2.test.ts`
- Modify: `scripts/smoke.mjs`（`sync_status` の `lan` が URL を含むことを確認）

- [ ] **Step 1: 失敗するテストを書く**

```ts
// test/tools.plan2.test.ts
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { HubConfig } from '../src/config.js';
import { HlcClock } from '../src/hlc.js';
import { emptyDocument } from '../src/model.js';
import { FileStore } from '../src/store.js';
import { SyncEngine } from '../src/sync-engine.js';
import { HubTools } from '../src/tools.js';

let dir: string; let tools: HubTools; let cfg: HubConfig;
beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), 'hub-tools2-'));
  cfg = await HubConfig.load(dir);
  const store = new FileStore(dir, 'hub-0000');
  const clock = new HlcClock('hub-0000');
  tools = new HubTools(store, clock, () => new Date(), { config: cfg, engine: new SyncEngine(store, cfg, clock), lan: () => ({ url: 'https://192.168.1.10:47820', pairingPage: 'http://127.0.0.1:47821/pair', qrPage: 'http://127.0.0.1:47821/qr' }) });
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

describe('plan 2 tools', () => {
  it('import_file merges a v2 file and reports counts', async () => {
    const path = join(dir, 'phone.json');
    const doc = emptyDocument('android-1');
    doc.taskMaster.tasks.push({ id: 'imported', title: 'x', kind: 'must_do', priority: 3, createdAt: 'c', memo: '', categoryId: null, estimatedMinutes: 0, clock: '5-0-android-1', updatedAt: '2026-09-09T00:00:00.000Z', deletedAt: null, migrated: false });
    writeFileSync(path, JSON.stringify(doc));
    const r = await tools.importFile({ path });
    expect(r.summary.added).toBe(1);
    expect((await tools.listTasks({})).map((t) => t.id)).toEqual(['imported']);
    await expect(tools.importFile({ path: join(dir, 'missing.json') })).rejects.toThrow(/not found|ENOENT/);
    writeFileSync(path, '{"version": 1}');
    await expect(tools.importFile({ path })).rejects.toThrow(/version/);
  });

  it('forget_device, rotate_token and purge_tombstones delegate to config/engine', async () => {
    const token = await cfg.redeemPairingCode(await cfg.issuePairingCode(), 'android-1', 'Pixel');
    const rotated = await tools.rotateToken({ deviceId: 'android-1' });
    expect(rotated.token).not.toBe(token);
    expect((await tools.purgeTombstones()).purged).toBe(0);
    expect((await tools.forgetDevice({ deviceId: 'android-1' })).forgotten).toBe(true);
    await expect(tools.forgetDevice({ deviceId: 'android-1' })).rejects.toThrow(/unknown device/);
  });

  it('sync_status exposes LAN url, fingerprint, pairing page, devices and last sync', async () => {
    await cfg.redeemPairingCode(await cfg.issuePairingCode(), 'android-1', 'Pixel');
    const s = await tools.syncStatus();
    expect(s.lan).toEqual({ url: 'https://192.168.1.10:47820', pairingPage: 'http://127.0.0.1:47821/pair', qrPage: 'http://127.0.0.1:47821/qr' });
    expect(s.fingerprint).toBe(cfg.fingerprint);
    expect(s.devices[0]).toMatchObject({ deviceId: 'android-1', name: 'Pixel', lastSyncAt: null });
    expect(s.devices[0]).not.toHaveProperty('token');
    expect(s.lastSync).toBeNull();
  });
});
```

- [ ] **Step 2: 失敗を確認する**

Run: `npm test -- tools.plan2`
Expected: FAIL（`HubTools` の第 4 引数が無い）

- [ ] **Step 3: 実装する**

`src/tools.ts` の変更点:

```ts
import { readFile } from 'node:fs/promises';
import type { HubConfig } from './config.js';
import type { SyncEngine } from './sync-engine.js';

export interface LanInfo { url: string | null; pairingPage: string | null; qrPage: string | null; }
export interface HubToolsDeps { config: HubConfig; engine: SyncEngine; lan: () => LanInfo; }

export class HubTools {
  constructor(
    private readonly store: FileStore,
    private readonly clock: HlcClock,
    private readonly now: () => Date = () => new Date(),
    private readonly deps?: HubToolsDeps,
  ) {}

  private requireDeps(): HubToolsDeps {
    if (!this.deps) throw new ToolError('LAN sync is not configured in this hub process');
    return this.deps;
  }

  async importFile(input: z.infer<typeof schemas.importFile>) {
    const { engine } = this.requireDeps();
    let text: string;
    try { text = await readFile(input.path, 'utf8'); } catch (e) { throw new ToolError(`file not found: ${input.path} (${String((e as Error).message)})`); }
    let json: unknown;
    try { json = JSON.parse(text); } catch (e) { throw new ToolError(`not valid JSON: ${String((e as Error).message)}`); }
    const doc = json as SyncDocumentJson;
    if (typeof doc.version !== 'number' || doc.version < 2) throw new ToolError(`unsupported schema version ${String(doc.version)}: export the file from an app with schema v2`);
    const deviceId = typeof doc.deviceId === 'string' ? doc.deviceId : 'file-import';
    if (!this.deps!.config.device(deviceId)) {
      // A file import is an out-of-band transfer; register the device so purge accounting sees it.
      await this.deps!.config.redeemPairingCode(await this.deps!.config.issuePairingCode(), deviceId, 'file import');
    }
    const result = await engine.sync(deviceId, doc, 'merge');
    return { summary: result.summary, warnings: result.warnings, deviceId };
  }

  async purgeTombstones() { return this.requireDeps().engine.purge(); }
  async forgetDevice(input: z.infer<typeof schemas.forgetDevice>) { await this.requireDeps().config.forgetDevice(input.deviceId).catch((e) => { throw new ToolError(String((e as Error).message)); }); return { deviceId: input.deviceId, forgotten: true }; }
  async rotateToken(input: z.infer<typeof schemas.rotateToken>) { const token = await this.requireDeps().config.rotateToken(input.deviceId).catch((e) => { throw new ToolError(String((e as Error).message)); }); return { deviceId: input.deviceId, token, note: 'the phone must pair again with the new token (or scan a new pairing QR)' }; }

  async syncStatus() {
    const base = { dataFile: this.store.filePath, modifiedAt: (await this.store.modifiedAt())?.toISOString() ?? null, warning: this.store.lastWarning };
    if (!this.deps) return { ...base, lan: null, fingerprint: null, devices: [], lastSync: null };
    const { config, engine, lan } = this.deps;
    return { ...base, lan: lan(), fingerprint: config.fingerprint, devices: config.devices().map(({ token: _t, ...d }) => d), lastSync: engine.lastSync };
  }
}
```

`rotateToken` の設計上の注意: 旧トークンは即失効するので、スマホ側は再ペアリングが必要。戻り値の `note` に明記する（MCP の説明文にも書く）。

`src/index.ts` を次に置き換える（登録部分は既存の `register` 呼び出しを維持し、Plan 2 の 4 ツールを実装に差し替える）:

```ts
#!/usr/bin/env node
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { HubConfig } from './config.js';
import { HlcClock } from './hlc.js';
import { LanServer } from './lan-server.js';
import { LocalPages } from './local-pages.js';
import { FileStore } from './store.js';
import { SyncEngine } from './sync-engine.js';
import { HubTools, ToolError, schemas } from './tools.js';

const directory = process.env.FRELOCATOR_DATA_DIR ?? FileStore.defaultDirectory();
const hubDeviceId = `hub-${process.env.FRELOCATOR_HUB_ID ?? 'macos'}`;
const lanPort = Number(process.env.FRELOCATOR_LAN_PORT ?? 47820);
const localPort = Number(process.env.FRELOCATOR_LOCAL_PORT ?? 47821);
const lanEnabled = process.env.FRELOCATOR_LAN !== 'off';

const store = new FileStore(directory, hubDeviceId);
const clock = new HlcClock(hubDeviceId);
const config = await HubConfig.load(directory);
const engine = new SyncEngine(store, config, clock);
const lan = new LanServer(config, engine, { port: lanPort, host: '0.0.0.0', advertise: true, hubDeviceId });
const pages = new LocalPages(config, store, { port: localPort, lanUrl: () => (lan.address ? `https://${lan.address}:${lan.port}` : null) });

let lanError: string | null = null;
if (lanEnabled) {
  try { await lan.start(); await pages.start(); } catch (error) { lanError = String((error as Error).message); }
}

const tools = new HubTools(store, clock, () => new Date(), {
  config, engine,
  lan: () => ({
    url: lanError ? null : (lan.address ? `https://${lan.address}:${lan.port}` : null),
    pairingPage: lanError ? null : `http://127.0.0.1:${pages.port}/pair`,
    qrPage: lanError ? null : `http://127.0.0.1:${pages.port}/qr`,
  }),
});

// …既存の text / wrap / register 定義と 22 個の register(...) 呼び出しはそのまま…
register('import_file', 'Merge a v2 JSON file exported from the phone into the hub data (records the file\'s deviceId for purge accounting)', schemas.importFile.shape, (i) => wrap(() => tools.importFile(i)));
register('purge_tombstones', 'Physically delete tombstones older than every paired device\'s last sync; sets purgedBefore', {}, () => wrap(() => tools.purgeTombstones()));
register('forget_device', 'Remove a paired device so it no longer holds back tombstone purge', schemas.forgetDevice.shape, (i) => wrap(() => tools.forgetDevice(i)));
register('rotate_token', 'Invalidate a device token; the phone must pair again', schemas.rotateToken.shape, (i) => wrap(() => tools.rotateToken(i)));
register('sync_status', 'Data file, LAN URL and certificate fingerprint, pairing/QR page URLs (localhost), paired devices, last sync progress', {}, () => wrap(async () => ({ ...(await tools.syncStatus()), lanError })));

const shutdown = async () => { await pages.stop().catch(() => {}); await lan.stop().catch(() => {}); process.exit(0); };
process.on('SIGINT', () => void shutdown());
process.on('SIGTERM', () => void shutdown());
process.stdin.on('close', () => void shutdown());

await server.connect(new StdioServerTransport());
```

`scripts/smoke.mjs` に `FRELOCATOR_LAN=off` を設定して起動し（CI でポートを開かない）、`sync_status` の `lan` が `null` で `lanError` が `null` であることを確認する。さらに `FRELOCATOR_LAN` 未設定・`FRELOCATOR_LAN_PORT=0`・`FRELOCATOR_LOCAL_PORT=0` で 2 回目の起動をし、`sync_status.lan.url` が `https://` で始まり `pairingPage` が `http://127.0.0.1:` で始まることを確認する。

- [ ] **Step 4: テスト・ビルド・smoke**

Run: `npm test && npm run typecheck && npm run smoke`
Expected: 全 PASS。smoke の 2 回目で LAN URL が出る。

- [ ] **Step 5: コミット**

```bash
git add tools/hub/src/tools.ts tools/hub/src/index.ts tools/hub/test/tools.plan2.test.ts tools/hub/scripts/smoke.mjs
git commit -m "feat(hub): implement import_file, purge, device tools and LAN-aware sync_status; start LAN and local pages / Plan 2 ツールと起動配線"
```

---

### Task 7: ドキュメント

**Files:**
- Modify: `tools/hub/README.md`
- Modify: `docs/superpowers/specs/2026-09-08-frelocator-hub-sync-design.md`（「LAN 同期プロトコル」に実装済みの応答形式 `{ document, summary, warnings }`、`mode` クエリ、`/pair` の `hubDeviceId`、`import_file` が端末を自動登録する点を追記）

- [ ] **Step 1: README に追記する**

```markdown
## LAN 同期（Plan 2a）

- ハブ起動中は `https://<LAN IP>:47820` で同期を受け付ける（自己署名証明書。スマホはペアリング時のフィンガープリントをピン留めする）。
- ペアリング: `sync_status` の `lan.pairingPage`（`http://127.0.0.1:47821/pair`）をブラウザで開き、スマホで QR を読む。コードは 5 分・1 回限り。
- QR でスマホに送る: `lan.qrPage`（`http://127.0.0.1:47821/qr`）。
- スマホから PC へは、スマホの「PC へ書き出す」で作った JSON を `import_file` で取り込む。
- 端末管理: `forget_device`、`rotate_token`、`purge_tombstones`。
- 環境変数: `FRELOCATOR_LAN=off`（LAN を開かない）、`FRELOCATOR_LAN_PORT`、`FRELOCATOR_LOCAL_PORT`。
- `hub.json`（証明書・端末トークン）は `data.json` と同じディレクトリ。権限 600。
```

- [ ] **Step 2: コミット**

```bash
git add tools/hub/README.md docs/superpowers/specs/2026-09-08-frelocator-hub-sync-design.md
git commit -m "docs(hub): LAN sync, pairing and device management / LAN 同期の使い方"
```

---

## 自己レビュー

- 設計書カバレッジ: 自己署名 TLS＋フィンガープリント（Task 1, 3）、短命コード→端末トークン（Task 1, 3）、`/pair` `/sync` `/health`・426・`purgedBefore` 判定・置き換えモード（Task 2, 3）、mDNS（Task 3）、ローカル限定ページ（Task 5）、QR フレーム形式と 80 コマ警告（Task 4, 5）、purge＝既知端末の最小 lastSyncAt・初回同期免除・forget_device（Task 2, 6）、rotate_token / import_file / sync_status の進捗（Task 6）。
- 型の整合: `SyncEngine.sync(deviceId, doc, mode) → SyncResult{document, summary, warnings}`、`SyncRejected(status, code)`、`HubConfig` のメソッド名、`LanServer(config, engine, options)`、`LocalPages(config, store, {port, lanUrl})`、`HubTools(store, clock, now, deps)`、`FrameSet.add → AddResult`。Plan 2b の Flutter 側はこれらの HTTP 形式（`/pair` の戻り `{token, hubDeviceId, fingerprint}`、`/sync?mode=` の戻り `{document, summary, warnings}`、エラー `{error:{code,message}}`、426/409/401/403）を前提にする。
- 未決: `lanAddress()` は最初の非内部 IPv4 を返すだけなので、複数インターフェースがある Mac では意図しない IP になり得る。`sync_status` に全候補を出す改善は 2b の手入力 host で吸収する。
