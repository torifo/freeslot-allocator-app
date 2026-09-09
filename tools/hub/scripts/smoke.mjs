// Drives the built stdio server over JSON-RPC against a throwaway data dir.
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { mkdtempSync, rmSync } from 'node:fs';
import { request as httpRequest } from 'node:http';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { checkInvariants } from '../dist/invariants.js';

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
  check('tool count is 39', tools.length === 39, tools.length);
  const names = new Set(tools.map((t) => t.name));
  const missing = [
    'get_task', 'get_entity', 'reorder_tasks', 'bulk_update_tasks', 'bulk_delete_tasks',
    'merge_categories', 'get_settings', 'set_share_categories', 'create_daily_plan',
    'delete_daily_plan', 'move_daily_plan', 'move_assignment', 'import_data',
  ].filter((name) => !names.has(name));
  check('every tool of this round is registered', missing.length === 0, missing.join(', '));

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

  // ---- full lifecycle over the real stdio protocol ----
  // `call` fails the run on a tool error and on any response that is not JSON.
  const call = async (name, args = {}) => {
    const result = await client.callTool({ name, arguments: args });
    const raw = result?.content?.[0]?.text;
    if (result.isError) throw new Error(`${name} failed: ${raw}`);
    try {
      return JSON.parse(raw);
    } catch (error) {
      throw new Error(`${name} did not answer with JSON: ${raw} (${error})`);
    }
  };
  const refused = async (name, args) => {
    const result = await client.callTool({ name, arguments: args });
    return result.isError === true;
  };
  const day = '2026-09-09';
  const at = (date, time) => `${date}T${time}:00+09:00`;
  let invariantFailures = 0;
  const document = async (label) => {
    const doc = await call('export_data');
    const violations = checkInvariants(doc);
    if (violations.length > 0) {
      invariantFailures += 1;
      console.log(`     invariants after ${label}: ${JSON.stringify(violations)}`);
    }
    return doc;
  };

  const category = await call('add_category', { kind: 'must_do', name: 'スモーク' });
  const other = await call('add_category', { kind: 'must_do', name: 'スモーク2' });
  const one = await call('add_task', { title: 'one', kind: 'must_do', categoryId: category.id });
  const two = await call('add_task', { title: 'two', kind: 'must_do' });
  const three = await call('add_task', { title: 'three', kind: 'must_do' });

  const reordered = await call('reorder_tasks', { kind: 'must_do', orderedIds: [three.id, one.id, two.id] });
  check('reorder_tasks puts the listed ids first', reordered.slice(0, 3).map((t) => t.title).join(',') === 'three,one,two', JSON.stringify(reordered.map((t) => t.title)));

  await call('update_task', { id: one.id, memo: 'partial' });
  const fetched = await call('get_task', { id: one.id });
  check('update_task is partial', fetched.memo === 'partial' && fetched.title === 'one' && fetched.categoryId === category.id, JSON.stringify(fetched));
  check('get_entity finds a category', (await call('get_entity', { id: category.id })).kind === 'category');

  const bulk = await call('bulk_update_tasks', { updates: [{ id: two.id, estimatedMinutes: 15 }, { id: three.id, memo: 'b' }] });
  check('bulk_update_tasks touches every id', bulk.length === 2 && bulk[0].estimatedMinutes === 15 && bulk[1].memo === 'b');
  check('bulk_update_tasks is all or nothing', await refused('bulk_update_tasks', { updates: [{ id: two.id, memo: 'x' }, { id: 'nope', memo: 'y' }] }));
  check('the rejected bulk wrote nothing', (await call('get_task', { id: two.id })).memo === '');

  const merged = await call('merge_categories', { kind: 'must_do', sourceId: other.id, targetId: category.id });
  check('merge_categories tombstones the source', merged.targetId === category.id && !(await call('list_categories', { kind: 'must_do' })).some((c) => c.id === other.id));

  check('get_settings starts unshared', (await call('get_settings')).shareCategories === false);
  await call('set_share_categories', { enabled: true, strategy: 'keepMustDo' });
  const shared = await call('list_categories', { kind: 'want_to_do' });
  check('set_share_categories mirrors the must-do list', shared.some((c) => c.name === 'スモーク'), JSON.stringify(shared.map((c) => c.name)));
  await call('set_share_categories', { enabled: false });

  const plan = await call('create_daily_plan', { date: day });
  check('create_daily_plan is idempotent', (await call('create_daily_plan', { date: day })).id === plan.id);
  const early = await call('add_free_slot', { date: day, startAt: at(day, '09:00'), endAt: at(day, '12:00'), label: '午前' });
  const late = await call('add_free_slot', { date: day, startAt: at(day, '13:00'), endAt: at(day, '18:00') });
  const first = await call('assign_task', { slotId: early.id, taskId: one.id, startAt: at(day, '09:00'), endAt: at(day, '10:00') });
  const second = await call('assign_task', { slotId: early.id, taskId: two.id, startAt: at(day, '10:00'), endAt: at(day, '11:00') });
  await document('assign_task');

  const moved = await call('move_assignment', { id: second.id, targetSlotId: late.id });
  check('move_assignment repacks into the target slot', moved.slotId === late.id && moved.startAt === '2026-09-09T04:00:00.000Z', JSON.stringify(moved));
  const reinserted = await call('move_assignment', { id: moved.id, targetSlotId: early.id, beforeAssignmentId: first.id });
  check('move_assignment can insert before another entry', reinserted.sortOrder === 0, JSON.stringify(reinserted));
  await document('move_assignment');

  await call('unassign', { id: reinserted.id });
  const afterUnassign = await call('get_daily_plan', { date: day });
  check('unassign leaves only the other entry', afterUnassign.slots.flatMap((s) => s.assignments).length === 1);

  await call('delete_free_slot', { id: late.id });
  check('delete_free_slot removes it from the plan', !(await call('get_daily_plan', { date: day })).slots.some((s) => s.id === late.id));

  await call('delete_task', { id: three.id });
  const doc = await document('delete_task');
  check('a deleted task disappears from list_tasks', !(await call('list_tasks', {})).some((t) => t.id === three.id));
  const tombstone = doc.taskMaster.tasks.find((t) => t.id === three.id);
  check('the deleted id stays in the document as a tombstone', tombstone !== undefined && typeof tombstone.deletedAt === 'string' && tombstone.title === undefined, JSON.stringify(tombstone));
  check('the tombstone carries an HLC and a UTC timestamp', /^\d+-\d+-/.test(String(tombstone?.clock)) && String(tombstone?.deletedAt).endsWith('Z'));

  check('undo_last_write reports a restore', (await call('undo_last_write')) === true);
  check('the undone delete brought the task back', (await call('list_tasks', {})).some((t) => t.id === three.id));
  await call('bulk_delete_tasks', { ids: [three.id] });
  check('bulk_delete_tasks tombstones the id again', !(await call('list_tasks', {})).some((t) => t.id === three.id));

  const exported = await document('bulk_delete_tasks');
  const liveTitles = exported.taskMaster.tasks.filter((t) => !t.deletedAt).map((t) => t.title).sort();
  check('export_data reflects the whole lifecycle', JSON.stringify(liveTitles) === JSON.stringify(['one', 'smoke task', 'two']), JSON.stringify(liveTitles));
  check('export_data keeps the slot tombstone', exported.dailyPlan.slots.some((s) => s.id === late.id && s.deletedAt));

  const movedPlan = await call('move_daily_plan', { fromDate: day, toDate: '2026-09-10' });
  check('move_daily_plan shifts the slots by a day', movedPlan.slots[0].startAt === '2026-09-10T00:00:00.000Z', JSON.stringify(movedPlan.slots.map((s) => s.startAt)));
  check('move_daily_plan empties the source date', (await call('get_daily_plan', { date: day })).plan === null);
  const removed = await call('delete_daily_plan', { date: '2026-09-10' });
  check('delete_daily_plan takes the slots with it', removed.deleted === true && removed.slots >= 1, JSON.stringify(removed));
  await document('delete_daily_plan');

  // A device that synced just now moves the purge cutoff to 24h ago, so
  // tombstones written during this run must survive.
  const inline = await call('export_data');
  const imported = await call('import_data', { document: { ...inline, deviceId: 'smoke-phone' } });
  check('import_data merges an inline document', imported.deviceId === 'smoke-phone' && imported.summary.added === 0, JSON.stringify(imported.summary));
  const purgeAfter = await call('purge_tombstones');
  const margin = Date.now() - Date.parse(purgeAfter.purgedBefore);
  check('purge keeps the 24h margin', margin > 23.5 * 3600_000 && margin < 24.5 * 3600_000, `${Math.round(margin / 60_000)} min`);
  check('purge kept this run\'s fresh tombstones', purgeAfter.purged === 0, purgeAfter.purged);
  check('every tombstone is still in the document', (await call('export_data')).taskMaster.tasks.some((t) => t.id === three.id));
  check('checkInvariants never failed', invariantFailures === 0, invariantFailures);
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
