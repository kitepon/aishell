import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { verifyHostCLI } from './host-cli.mjs';
import { hostSpec } from './hosts.mjs';

const registration = { command: 'aishell-mcp', args: [], env: { AISHELL_CAPABILITY_SET: 'expanded-v1' } };
const outputs = {
  codex: JSON.stringify({ enabled: true, transport: { type: 'stdio', ...registration } }),
  grok: JSON.stringify([{ name: 'aishell', enabled: true, ...registration }]),
  claude: '  Command: aishell-mcp\n  Status: ✓ Connected\n  AISHELL_CAPABILITY_SET=expanded-v1\n',
  agent: 'Tools for aishell (11):\n- runtime_status ()\n- workspace_snapshot ()\n- apply_change_set ()',
};

for (const ai of ['codex', 'grok', 'claude', 'cursor']) test(`${ai}本体の読戻しとCursor有効化を確認する`, async t => {
  const home = await mkdtemp(path.join(tmpdir(), 'aishell-cli-test-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  const calls = [];
  const options = { env: {}, cwd: home, backupDirectory: path.join(home, 'backups'), run(command, args) { calls.push([command, ...args]); return outputs[command]; } };
  assert.deepEqual(await verifyHostCLI(hostSpec(ai, home, {}), registration, options), { hostVerified: true });
  if (ai === 'cursor') assert.deepEqual(calls, [['agent', 'mcp', 'enable', 'aishell'], ['agent', 'mcp', 'list-tools', 'aishell']]);
  else assert.equal(calls.length, 1);
});

test('Cursor診断ではenableせず、既存承認のtool取得だけ確認する', async t => {
  const home = await mkdtemp(path.join(tmpdir(), 'aishell-cli-check-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  const spec = hostSpec('cursor', home, {});
  await mkdir(spec.base);
  await writeFile(path.join(spec.base, 'cli-config.json'), '{}');
  const calls = [];
  await verifyHostCLI(spec, registration, { check: true, env: {}, cwd: home, run(command, args) { calls.push(args); return outputs.agent; } });
  assert.deepEqual(calls, [['mcp', 'list-tools', 'aishell']]);
  assert.deepEqual(await readdir(home), ['.cursor']);
});

test('本体の旧登録・無効化・tool欠落を成功にしない', async () => {
  for (const [ai, output] of [
    ['codex', JSON.stringify({ enabled: false, transport: { type: 'stdio', ...registration } })],
    ['codex', JSON.stringify({ enabled: true, transport: { type: 'stdio', ...registration, command: '/old/aishell-mcp' } })],
    ['grok', '[]'], ['claude', 'Command: aishell-mcp\nStatus: Failed\nexpanded-v1'],
  ]) await assert.rejects(verifyHostCLI(hostSpec(ai, '/tmp', {}), registration, { env: {}, cwd: '/tmp', run: () => output }), { code: 'AI_REGISTRATION_MISMATCH' });
});
