#!/usr/bin/env node
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const metadata = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
const source = await readFile(path.join(root, 'Sources/AIShellCore/Product.swift'), 'utf8');
assert.equal(metadata.version, source.match(/public\s+static\s+let\s+version\s*=\s*"([^"]+)"/)?.[1]);
assert.equal(metadata.bin['aishell-mcp'], 'dist/aishell-mcp');
assert.equal(metadata.bin['aishell-open'], undefined);
for (const name of ['preinstall', 'install', 'postinstall']) assert.equal(metadata.scripts[name], undefined);

const temporary = await mkdtemp(path.join(tmpdir(), 'aishell-package-'));
try {
  const packed = Object.values(JSON.parse(execFileSync('npm',
    ['pack', '--ignore-scripts', '--json', '--pack-destination', temporary],
    { cwd: root, encoding: 'utf8', timeout: 120000 })));
  assert.equal(packed.length, 1);
  const contents = packed[0].files.map(file => file.path);
  assert.ok(contents.includes('dist/aishell-mcp'));
  assert.ok(!contents.some(file => file.includes('.app/') || file.includes('aishell-open') || file.includes('supervisor')));
  const installed = path.join(temporary, 'installed');
  execFileSync('npm', ['install', '--prefix', installed, '--ignore-scripts', '--no-audit', '--no-fund',
    path.join(temporary, packed[0].filename)], { encoding: 'utf8', timeout: 120000 });
  const bin = path.join(installed, 'node_modules/.bin');
  const packageRoot = path.join(installed, 'node_modules/@quolu/aishell');
  const env = { PATH: bin + ':' + process.env.PATH, AISHELL_STATE_DIRECTORY: path.join(temporary, 'logs') };
  assert.equal(execFileSync(path.join(bin, 'aishell-mcp'), ['--version'], { encoding: 'utf8' }).trim(), metadata.version);
  const removed = spawnSync(path.join(bin, 'aishell-mcp'), ['--prepare-keychain'], { encoding: 'utf8', timeout: 5000 });
  assert.equal(removed.status, 64);
  assert.equal(removed.stdout, '');
  const { setup } = await import(pathToFileURL(path.join(packageRoot, 'scripts/setup/setup.mjs')));
  const dependencies = { home: path.join(temporary, 'home'), env };
  const result = await setup({ ais: ['codex'] }, dependencies);
  assert.equal(result.status, 'ready');
  assert.equal(result.hosts[0].toolCount, 18);
  assert.equal(result.manager, undefined);
  assert.equal(result.keychain, undefined);
  assert.equal((await setup({ ais: ['codex'], check: true }, dependencies)).status, 'ready');
  const { withMCP } = await import(pathToFileURL(path.join(packageRoot, 'scripts/setup/mcp-client.mjs')));
  const work = path.join(temporary, 'work');
  await mkdir(work);
  await withMCP({ command: 'aishell-mcp', args: [] }, async ({ call, request }) => {
    const tools = (await request('tools/list', {})).tools;
    assert.equal(tools.length, 18);
    assert.ok(tools.every(tool => tool.outputSchema.type === 'object'));
    const running = (await call('apps_list_running')).structuredContent.applications;
    const applications = (await call('apps_list_installed')).structuredContent.applications;
    assert.ok(Array.isArray(running));
    assert.ok(Array.isArray(applications));
    await call('files_create_directory', { path: 'nested' });
    await call('files_create_text', { path: 'nested/empty', content: '' });
    const text = '入力通り\r\n$HOME; *\n';
    await call('files_write_text', { path: 'nested/empty', content: text });
    assert.equal((await call('files_read_text', { path: 'nested/empty' })).structuredContent.text, text);
    const copied = (await call('files_copy', { source: 'nested/empty', destination: 'copy' })).structuredContent;
    assert.equal(copied.name, 'copy');
    await call('files_rename', { path: 'copy', new_name: 'renamed' });
    await call('files_move', { source: 'renamed', destination: 'nested/moved' });
    assert.equal((await call('files_search', { query: 'moved' })).structuredContent.entries.length, 1);
    assert.equal((await call('files_stat', { path: 'nested/moved', include_hash: true })).structuredContent.sha256.length, 64);
    assert.equal((await call('files_tree', { path: 'nested' })).structuredContent.entries.length, 2);
    await call('files_replace_text', { path: 'nested/moved', old_text: '$HOME', new_text: 'literal' });
    assert.ok((await call('files_read_text', { path: 'nested/moved' })).structuredContent.text.includes('literal'));
    const listed = (await call('files_list')).structuredContent.entries;
    assert.deepEqual(listed.map(entry => entry.name), ['nested']);
    const echo = (await call('process_run', { executable: '/bin/cat', stdin: text })).structuredContent;
    assert.equal(echo.stdout.encoding, 'utf8');
    assert.equal(echo.stdout.data, text);
  }, { cwd: work, env });
  assert.deepEqual(await readdir(env.AISHELL_STATE_DIRECTORY), ['activity.jsonl']);
  const records = (await readFile(path.join(env.AISHELL_STATE_DIRECTORY, 'activity.jsonl'), 'utf8')).trim().split('\n').map(JSON.parse);
  assert.ok(records.length >= 20);
  assert.ok(records.every(record => record.success === true));
  console.log('配布した実行ファイルだけで、AI登録・OS操作・完全な応答・使用ログを確認しました。');
} finally {
  await rm(temporary, { recursive: true, force: true });
}
