// Drives the built stdio server over JSON-RPC against a throwaway data dir.
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { mkdtempSync, rmSync } from 'node:fs';
import { request as httpRequest } from 'node:http';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const entry = join(here, '..', 'dist', 'index.js');
const json = (result) => JSON.parse(result.content[0].text);

const connect = async (dir, env) => {
  const client = new Client({ name: 'smoke', version: '0.0.0' });
  await client.connect(new StdioClientTransport({
    command: process.execPath,
    args: [entry],
    env: { ...process.env, FRELOCATOR_DATA_DIR: dir, FRELOCATOR_HUB_ID: 'smoke', ...env },
  }));
  return client;
};

let ok = true;
const check = (label, condition, detail) => {
  ok = ok && condition;
  console.log(`${condition ? 'OK  ' : 'FAIL'} ${label}${detail === undefined ? '' : `: ${detail}`}`);
};

// Run 1: LAN off. The MCP surface must work without opening a single port.
const dir1 = mkdtempSync(join(tmpdir(), 'hub-smoke-'));
let client = await connect(dir1, { FRELOCATOR_LAN: 'off' });
try {
  const { tools } = await client.listTools();
  console.log(`tools listed: ${tools.length}`);
  console.log(tools.map((t) => t.name).join(', '));
  check('tool count is 26', tools.length === 26, tools.length);

  const status = json(await client.callTool({ name: 'sync_status', arguments: {} }));
  console.log(`sync_status: ${JSON.stringify(status)}`);
  check('LAN not listening', status.lan.listening === false && status.lan.url === null);
  check('LAN reported as deliberately disabled', status.lan.disabled === true);
  check('lanError names FRELOCATOR_LAN=off', status.lanError === 'LAN disabled by FRELOCATOR_LAN=off', status.lanError);
  check('no configError', status.configError === null);
  check('fingerprint present', typeof status.fingerprint === 'string' && status.fingerprint.length === 64);
  check('no devices paired', Array.isArray(status.devices) && status.devices.length === 0);
  check('pairing code not issued', status.pairing.state === 'none');

  const added = json(await client.callTool({ name: 'add_task', arguments: { title: 'smoke task', kind: 'must_do' } }));
  const listed = json(await client.callTool({ name: 'list_tasks', arguments: {} }));
  console.log(`add_task -> ${added.id}`);
  console.log(`list_tasks -> ${JSON.stringify(listed.map((t) => t.title))}`);
  check('round trip', listed.length === 1 && listed[0].id === added.id);

  const purge = json(await client.callTool({ name: 'purge_tombstones', arguments: {} }));
  console.log(`purge_tombstones -> ${JSON.stringify(purge)}`);
  check('purge is a no-op with no synced device', purge.purged === 0);
} finally {
  await client.close().catch(() => {});
  rmSync(dir1, { recursive: true, force: true });
}

// Run 2: LAN on, ephemeral ports, no mDNS traffic.
const dir2 = mkdtempSync(join(tmpdir(), 'hub-smoke-lan-'));
client = await connect(dir2, { FRELOCATOR_LAN_PORT: '0', FRELOCATOR_LOCAL_PORT: '0', FRELOCATOR_MDNS: 'off' });
try {
  const status = json(await client.callTool({ name: 'sync_status', arguments: {} }));
  console.log(`sync_status (LAN): ${JSON.stringify(status)}`);
  check('LAN listening', status.lan.listening === true);
  check('pairing page on loopback', String(status.lan.pairingPage).startsWith('http://127.0.0.1:'), status.lan.pairingPage);
  check('QR page on loopback', String(status.lan.qrPage).startsWith('http://127.0.0.1:'), status.lan.qrPage);
  check('no lanError', status.lanError === null, status.lanError);
  check('LAN not reported as disabled', status.lan.disabled === false);
  // A host with no LAN address (offline CI) legitimately reports url: null.
  check(
    'LAN url matches the address candidates',
    status.lan.addresses.length === 0 ? status.lan.url === null : String(status.lan.url).startsWith('https://'),
    `${status.lan.url} ${JSON.stringify(status.lan.addresses)}`,
  );

  // The page URLs carry a random secret path segment; nothing else can guess them.
  const localOrigin = new URL(status.lan.pairingPage).origin;
  // `fetch` refuses to set Host, so the rebinding check needs a raw request.
  const page = (url, headers = {}) => new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = httpRequest(
      { host: u.hostname, port: u.port, path: u.pathname, method: 'GET', headers: { host: u.host, ...headers } },
      (res) => {
        let body = '';
        res.on('data', (c) => (body += c));
        res.on('end', () => resolve({ status: res.statusCode, body }));
      },
    );
    req.on('error', reject);
    req.end();
  });
  const pair = await page(status.lan.pairingPage);
  check('pairing page renders a QR', pair.status === 200 && pair.body.includes('<svg'), pair.status);

  const frames = await page(new URL('./qr/frames.json', status.lan.qrPage).href);
  const framesJson = frames.status === 200 ? JSON.parse(frames.body) : null;
  check('QR frames served', frames.status === 200 && framesJson.total >= 1, `${frames.status} ${framesJson?.total}`);

  const rebound = await page(status.lan.pairingPage, { host: 'evil.com' });
  check('rebound Host refused', rebound.status === 403, rebound.status);
  const unprefixed = await page(`${localOrigin}/pair`);
  check('pages are not served without the secret prefix', unprefixed.status === 404, unprefixed.status);
} finally {
  await client.close().catch(() => {});
  rmSync(dir2, { recursive: true, force: true });
}

console.log(ok ? 'SMOKE OK' : 'SMOKE FAILED');
process.exitCode = ok ? 0 : 1;
