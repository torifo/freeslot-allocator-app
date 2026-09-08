#!/usr/bin/env node
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { HlcClock } from './hlc.js';
import { FileStore } from './store.js';
import { HubTools, ToolError, schemas } from './tools.js';

const directory = process.env.FRELOCATOR_DATA_DIR ?? FileStore.defaultDirectory();
const store = new FileStore(directory, `hub-${process.env.FRELOCATOR_HUB_ID ?? 'macos'}`);
const tools = new HubTools(store, new HlcClock(store.deviceId));
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

const notYet = () => wrap(async () => { throw new ToolError('available in Plan 2 (LAN sync)'); });

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
register('sync_status', 'Data file path, last modification, warnings, LAN status', {}, () => wrap(() => tools.syncStatus()));
register('import_file', 'Merge a v2 JSON file into the store (Plan 2)', schemas.importFile.shape, notYet);
register('purge_tombstones', 'Purge old tombstones (Plan 2)', {}, notYet);
register('forget_device', 'Forget a paired device (Plan 2)', schemas.forgetDevice.shape, notYet);
register('rotate_token', 'Rotate a device token (Plan 2)', schemas.rotateToken.shape, notYet);

await server.connect(new StdioServerTransport());
