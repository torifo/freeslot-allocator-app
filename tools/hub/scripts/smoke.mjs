// Drives the built stdio server over JSON-RPC against a throwaway data dir.
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const dir = mkdtempSync(join(tmpdir(), 'hub-smoke-'));
const client = new Client({ name: 'smoke', version: '0.0.0' });
const transport = new StdioClientTransport({
  command: process.execPath,
  args: [join(here, '..', 'dist', 'index.js')],
  env: { ...process.env, FRELOCATOR_DATA_DIR: dir, FRELOCATOR_HUB_ID: 'smoke' },
});

const json = (result) => JSON.parse(result.content[0].text);

try {
  await client.connect(transport);
  const { tools } = await client.listTools();
  console.log(`tools listed: ${tools.length}`);
  console.log(tools.map((t) => t.name).join(', '));

  const status = json(await client.callTool({ name: 'sync_status', arguments: {} }));
  console.log(`sync_status: ${JSON.stringify(status)}`);

  const added = json(await client.callTool({
    name: 'add_task',
    arguments: { title: 'smoke task', kind: 'must_do' },
  }));
  const listed = json(await client.callTool({ name: 'list_tasks', arguments: {} }));
  console.log(`add_task -> ${added.id}`);
  console.log(`list_tasks -> ${JSON.stringify(listed.map((t) => t.title))}`);

  const plan2 = await client.callTool({ name: 'purge_tombstones', arguments: {} });
  console.log(`purge_tombstones -> isError=${plan2.isError} ${plan2.content[0].text}`);

  const ok = listed.length === 1 && listed[0].id === added.id;
  console.log(ok ? 'ROUND TRIP OK' : 'ROUND TRIP FAILED');
  process.exitCode = ok ? 0 : 1;
} finally {
  await client.close().catch(() => {});
  rmSync(dir, { recursive: true, force: true });
}
