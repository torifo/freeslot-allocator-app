#!/usr/bin/env node
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { HubConfig } from './config.js';
import { HlcClock } from './hlc.js';
import { LanServer } from './lan-server.js';
import { LocalPages } from './local-pages.js';
import { lanAddresses } from './net.js';
import { FileStore } from './store.js';
import { SyncEngine } from './sync-engine.js';
import { HubTools, ToolError, schemas } from './tools.js';

/** Diagnostics go to stderr: stdout carries the MCP stdio protocol and nothing else. */
const log = (message: string): void => void process.stderr.write(`[hub] ${message}\n`);

const directory = process.env.FRELOCATOR_DATA_DIR ?? FileStore.defaultDirectory();
const store = new FileStore(directory, `hub-${process.env.FRELOCATOR_HUB_ID ?? 'macos'}`);
const clock = new HlcClock(store.deviceId);
const lanPort = Number(process.env.FRELOCATOR_LAN_PORT ?? 47820);
const localPort = Number(process.env.FRELOCATOR_LOCAL_PORT ?? 47821);
const lanEnabled = process.env.FRELOCATOR_LAN !== 'off';

// A quarantined hub.json rejects here. The MCP server still starts so the local
// task tools keep working; only LAN sync is disabled, reported as configError.
let configError: string | null = null;
let config: HubConfig | null = null;
try {
  config = await HubConfig.load(directory);
} catch (error) {
  configError = String((error as Error).message ?? error);
  log(`hub.json unusable: ${configError}`);
}

const engine = config ? new SyncEngine(store, config, clock) : null;
const lan = config && engine
  ? new LanServer(config, engine, { port: lanPort, host: '0.0.0.0', advertise: process.env.FRELOCATOR_MDNS !== 'off', hubDeviceId: store.deviceId })
  : null;
const pages = config && lan
  ? new LocalPages(config, store, {
      port: localPort,
      lanUrl: () => (lan.address ? `https://${lan.address}:${lan.port}` : null),
      lanAddresses: () => lanAddresses(),
    })
  : null;

let lanError: string | null = configError ? 'hub.json is unusable; LAN sync is disabled' : null;
let listening = false;
if (lanEnabled && lan && pages) {
  try {
    await lan.start();
    await pages.start();
    listening = true;
  } catch (error) {
    lanError = String((error as Error).message ?? error);
    log(`LAN sync disabled: ${lanError}`);
    await pages.stop().catch(() => {});
    await lan.stop().catch(() => {});
  }
}

const tools = config && engine && lan && pages
  ? new HubTools(store, clock, () => new Date(), {
      config,
      engine,
      lan: () => ({
        listening,
        url: listening && lan.address ? `https://${lan.address}:${lan.port}` : null,
        addresses: lanAddresses(),
        port: listening ? lan.port : null,
        pairingPage: listening ? `http://127.0.0.1:${pages.port}/pair` : null,
        qrPage: listening ? `http://127.0.0.1:${pages.port}/qr` : null,
      }),
    })
  : new HubTools(store, clock);
const server = new McpServer({ name: 'frelocator-hub', version: '0.1.0' });

const text = (value: unknown) => ({
  content: [{ type: 'text' as const, text: JSON.stringify(value, null, 2) }],
});

const wrap = <T>(fn: () => Promise<T>) =>
  fn()
    .then(text)
    .catch((error: unknown) => ({
      isError: true,
      content: [
        {
          type: 'text' as const,
          text: error instanceof ToolError ? error.message : String(error),
        },
      ],
    }));

const register = (
  name: string,
  description: string,
  inputSchema: Record<string, unknown>,
  handler: (input: never) => Promise<unknown>,
): void => {
  server.registerTool(
    name,
    { description, inputSchema: inputSchema as never },
    handler as never,
  );
};

register('list_tasks', 'List live tasks, optionally filtered by kind/category/query', schemas.listTasks.shape, (i) => wrap(() => tools.listTasks(i)));
register('add_task', 'Add a task', schemas.addTask.shape, (i) => wrap(() => tools.addTask(i)));
register('bulk_add_tasks', 'Add many tasks at once', schemas.bulkAddTasks.shape, (i) => wrap(() => tools.bulkAddTasks(i)));
register('update_task', 'Update fields of a task', schemas.updateTask.shape, (i) => wrap(() => tools.updateTask(i)));
register('delete_task', 'Delete (tombstone) a task', schemas.deleteTask.shape, (i) => wrap(() => tools.deleteTask(i)));
register('list_categories', 'List categories', schemas.listCategories.shape, (i) => wrap(() => tools.listCategories(i)));
register('add_category', 'Add a category', schemas.addCategory.shape, (i) => wrap(() => tools.addCategory(i)));
register('update_category', 'Rename a category', schemas.updateCategory.shape, (i) => wrap(() => tools.updateCategory(i)));
register('delete_category', 'Delete a category and detach its tasks', schemas.deleteCategory.shape, (i) => wrap(() => tools.deleteCategory(i)));
register('list_daily_plans', 'List plans in a date range (YYYY-MM-DD, the hub machine\'s local calendar days)', schemas.listDailyPlans.shape, (i) => wrap(() => tools.listDailyPlans(i)));
register('get_daily_plan', 'Get plan, slots and assignments for a date (YYYY-MM-DD, the hub machine\'s local calendar day; times are returned as UTC ISO strings)', schemas.getDailyPlan.shape, (i) => wrap(() => tools.getDailyPlan(i)));
register('add_free_slot', 'Add a free time slot, creating the plan if needed (date is YYYY-MM-DD, the hub machine\'s local calendar day; startAt/endAt accept any ISO offset and are stored as UTC)', schemas.addFreeSlot.shape, (i) => wrap(() => tools.addFreeSlot(i)));
register('update_free_slot', 'Update a slot', schemas.updateFreeSlot.shape, (i) => wrap(() => tools.updateFreeSlot(i)));
register('delete_free_slot', 'Delete a slot and its assignments', schemas.deleteFreeSlot.shape, (i) => wrap(() => tools.deleteFreeSlot(i)));
register('assign_task', 'Assign a task into a slot', schemas.assignTask.shape, (i) => wrap(() => tools.assignTask(i)));
register('update_assignment', 'Update an assignment', schemas.updateAssignment.shape, (i) => wrap(() => tools.updateAssignment(i)));
register('unassign', 'Remove an assignment', schemas.unassign.shape, (i) => wrap(() => tools.unassign(i)));
register('copy_daily_plan', 'Copy slots and assignments from one date to another', schemas.copyDailyPlan.shape, (i) => wrap(() => tools.copyDailyPlan(i)));
register('weekly_report', 'Aggregate time by kind/category for a week', schemas.weeklyReport.shape, (i) => wrap(() => tools.weeklyReport(i)));
register('export_data', 'Return the full v2 document', {}, () => wrap(() => tools.exportData()));
register('undo_last_write', 'Restore data.json.bak (one generation)', {}, () => wrap(() => tools.undoLastWrite()));
register('sync_status', 'Data file, LAN URL and certificate fingerprint, pairing/QR page URLs (localhost), paired devices, last sync progress', {}, () => wrap(async () => ({ ...(await tools.syncStatus()), lanError, configError })));
register('import_file', 'Merge a v2 JSON file exported from the phone into the hub data (records the file\'s deviceId for purge accounting; invalidates any pairing code on screen)', schemas.importFile.shape, (i) => wrap(() => tools.importFile(i)));
register('purge_tombstones', 'Physically delete tombstones deleted before min(lastSyncAt of paired devices) - 24h; sets purgedBefore', {}, () => wrap(() => tools.purgeTombstones()));
register('forget_device', 'Remove a paired device so it no longer holds back tombstone purge', schemas.forgetDevice.shape, (i) => wrap(() => tools.forgetDevice(i)));
register('rotate_token', 'Invalidate a device token; the phone must pair again', schemas.rotateToken.shape, (i) => wrap(() => tools.rotateToken(i)));

let shuttingDown = false;
const shutdown = async (): Promise<void> => {
  if (shuttingDown) return;
  shuttingDown = true;
  await pages?.stop().catch(() => {});
  await lan?.stop().catch(() => {}); // also stops the mDNS advertisement
  process.exit(0);
};
process.on('SIGINT', () => void shutdown());
process.on('SIGTERM', () => void shutdown());
process.stdin.on('close', () => void shutdown());

await server.connect(new StdioServerTransport());
