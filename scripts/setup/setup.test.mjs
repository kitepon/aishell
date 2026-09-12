import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, readdir, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { stringify } from 'smol-toml';
import { setup, supportedPlatform } from './setup.mjs';
import { aiNames, hostSpec, readHost, planHost, writeHost } from './hosts.mjs';
import { withMCP, SetupError } from './mcp-client.mjs';

async function fixture(t) {
  const home = await mkdtemp(path.join(tmpdir(), 'aishell-setup-test-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  const events = [];
  const dependencies = {
    home, env: { PATH: '' }, platform: 'darwin', arch: 'arm64', macVersion: '15.0', version: 'fixture',
    prepare: async () => { events.push('prepare'); return { ready: true, processIdentifier: 42 }; },
    keychain: async () => ({ ready: true, checkedKeys: 0 }),
    verifyCLI: async () => ({ hostVerified: true }),
    smoke: async (registration, version) => { events.push('smoke'); assert.equal(registration.command, 'aishell-mcp'); assert.equal(registration.env.AISHELL_CAPABILITY_SET, 'expanded-v1'); return { ready: true, version }; },
  };
  return { home, dependencies, events, spec: ai => hostSpec(ai, home, dependencies.env) };
}

test('管理UIとKeychainの準備を呼ばず登録と実操作まで進む', async t => {
  const f = await fixture(t);
  f.dependencies.prepare = f.dependencies.keychain = async () => { throw new Error('廃止した処理'); };
  const result = await setup({ ais: ['codex'] }, f.dependencies);
  assert.equal(result.status, 'ready');
  assert.equal(result.manager, undefined);
  assert.equal(result.keychain, undefined);
  assert.deepEqual(f.events, ['smoke']);
});

for (const ai of aiNames) {
  test(`${ai}: 初回・再実行・診断・更新で登録と実操作を確認する`, async t => {
    const f = await fixture(t);
    const first = await setup({ ais: [ai] }, f.dependencies);
    assert.equal(first.hosts[0].registration, 'updated');
    assert.deepEqual(f.events, ['smoke']);
    const original = await readFile(f.spec(ai).file, 'utf8');
    const second = await setup({ ais: [ai] }, f.dependencies);
    assert.equal(second.hosts[0].registration, 'unchanged');
    assert.equal(await readFile(f.spec(ai).file, 'utf8'), original);
    f.events.length = 0;
    const checked = await setup({ ais: [ai], check: true }, f.dependencies);
    assert.equal(checked.status, 'ready');
    assert.deepEqual(f.events, ['smoke']);
    f.dependencies.version = 'updated-fixture';
    const updated = await setup({ ais: [ai] }, f.dependencies);
    assert.equal(updated.hosts[0].version, 'updated-fixture');
    assert.equal(updated.hosts[0].registration, 'unchanged');
  });

  test(`${ai}: 旧登録を移行しenv・他server・利用者設定を保持する`, async t => {
    const f = await fixture(t), spec = f.spec(ai);
    const original = {
      theme: 'custom', nested: { value: [1, 2], enabled: true },
      [spec.key]: {
        other: { command: 'keep-me', env: { SECRET: 'fixture' } },
        aishell: { command: '/old/bin/aishell-mcp', args: ['--old'], env: { PATH: '/custom/bin:/usr/bin', KEEP: 'fixture', AISHELL_CAPABILITY_SET: 'legacy' }, enabled: false, startup_timeout_sec: 55 },
      },
    };
    await mkdir(path.dirname(spec.file), { recursive: true });
    await writeFile(spec.file, spec.format === 'toml' ? stringify(original) : JSON.stringify(original));
    await setup({ ais: [ai] }, f.dependencies);
    const actual = await readHost(spec);
    assert.deepEqual(actual.data.nested, original.nested);
    assert.equal(actual.data.theme, original.theme);
    assert.deepEqual(actual.data[spec.key].other, original[spec.key].other);
    assert.equal(actual.registration.env.PATH, '/custom/bin:/usr/bin');
    assert.equal(actual.registration.env.KEEP, 'fixture');
    assert.equal(actual.registration.startup_timeout_sec, 55);
    assert.deepEqual(actual.registration.args, []);
    const backup = await readdir(path.join(f.home, 'Library/Application Support/AIShell/setup-backups'));
    assert.equal(backup.filter(name => name.endsWith('.tar')).length, 1);
  });
}

test('OS/CPU/最低OSを拒否し設定とprocessを作らない', async t => {
  for (const [platform, arch, macVersion] of [['win32', 'x64', null], ['linux', 'arm64', null], ['darwin', 'x64', '26.0'], ['darwin', 'arm64', '14.9']]) {
    const f = await fixture(t);
    await assert.rejects(setup({ ais: aiNames }, { ...f.dependencies, platform, arch, macVersion }), { code: 'PLATFORM_UNSUPPORTED' });
    assert.deepEqual(await readdir(f.home), []);
    assert.deepEqual(f.events, []);
  }
  assert.doesNotThrow(() => supportedPlatform('darwin', 'arm64', '26.0.1'));
});

test('壊れた設定は全対象の書込み・準備前に拒否する', async t => {
  const f = await fixture(t), spec = f.spec('grok');
  await mkdir(path.dirname(spec.file));
  await writeFile(spec.file, '[broken');
  await assert.rejects(setup({ ais: aiNames }, f.dependencies), { code: 'CONFIG_INVALID' });
  assert.deepEqual(f.events, []);
  assert.deepEqual(await readdir(f.home), ['.grok']);
});

test('登録失敗を成功にせず、実操作と後続AIの更新を止める', async t => {
  const f = await fixture(t);
  f.dependencies.write = async () => { throw new SetupError('REGISTRATION_FAILED', 'fixture'); };
  await assert.rejects(setup({ ais: aiNames }, f.dependencies), error => error.code === 'REGISTRATION_FAILED' && error.report.stage === 'register:claude');
  assert.deepEqual(f.events, []);
  assert.deepEqual(await readdir(f.home), []);
});

test('読戻し不一致とMCP失敗を報告する', async t => {
  const f = await fixture(t);
  f.dependencies.write = async () => {};
  await assert.rejects(setup({ ais: ['cursor'] }, f.dependencies), { code: 'REGISTRATION_MISMATCH' });
  delete f.dependencies.write;
  f.dependencies.smoke = async () => { throw new SetupError('MCP_VERSION_MISMATCH', 'fixture'); };
  await assert.rejects(setup({ ais: ['cursor'] }, f.dependencies), error => error.code === 'MCP_VERSION_MISMATCH' && error.report.stage === 'smoke:cursor');
});

test('同時更新を上書きしない', async t => {
  const f = await fixture(t), spec = f.spec('cursor');
  await mkdir(path.dirname(spec.file));
  await writeFile(spec.file, '{}');
  const plan = await planHost(spec);
  await writeFile(spec.file, '{"user":"changed"}');
  await assert.rejects(writeHost(plan, path.join(f.home, 'backups')), { code: 'CONFIG_CHANGED' });
  assert.equal(await readFile(spec.file, 'utf8'), '{"user":"changed"}');
});

test('symlink設定は変更しない', async t => {
  const f = await fixture(t), spec = f.spec('cursor');
  await mkdir(path.dirname(spec.file));
  await writeFile(path.join(f.home, 'target'), '{}');
  await symlink(path.join(f.home, 'target'), spec.file);
  await assert.rejects(setup({ ais: ['cursor'] }, f.dependencies), { code: 'CONFIG_PATH_UNSUPPORTED' });
  assert.deepEqual(f.events, []);
});

test('AI別のhome指定と既存AI検出を尊重する', async t => {
  const f = await fixture(t);
  f.dependencies.env = { PATH: '', CODEX_HOME: path.join(f.home, 'custom-codex') };
  await mkdir(f.dependencies.env.CODEX_HOME);
  const result = await setup({}, f.dependencies);
  assert.deepEqual(result.hosts.map(host => host.ai), ['codex']);
  assert.deepEqual(result.skipped, ['claude', 'grok', 'cursor']);
  assert.ok(await readFile(path.join(f.dependencies.env.CODEX_HOME, 'config.toml')));
});

test('診断は未登録を拒否し設定を作らない', async t => {
  const f = await fixture(t);
  await assert.rejects(setup({ ais: ['cursor'], check: true }, f.dependencies), { code: 'REGISTRATION_MISMATCH' });
  assert.deepEqual(await readdir(f.home), []);
  assert.deepEqual(f.events, []);
});

test('Cursor本体が読まないCURSOR_HOMEへ登録しない', async t => {
  const f = await fixture(t);
  f.dependencies.env.CURSOR_HOME = path.join(f.home, 'custom-cursor');
  await assert.rejects(setup({ ais: ['cursor'] }, f.dependencies), { code: 'AI_CONFIG_LOCATION_UNSUPPORTED' });
  assert.deepEqual(await readdir(f.home), []);
  assert.deepEqual(f.events, []);
  assert.equal((await setup({ ais: ['codex'] }, f.dependencies)).status, 'ready');
  assert.deepEqual((await setup({}, f.dependencies)).hosts.map(host => host.ai), ['codex']);
});

test('Grokの無効化リストからAIShellだけを除き他の名前を保持する', async t => {
  const f = await fixture(t), spec = f.spec('grok');
  await mkdir(path.dirname(spec.file));
  await writeFile(spec.file, '# 利用者設定\ndisabled_mcp_servers=["aishell", "other"] # 保持\n[mcp_servers.aishell]\ncommand="aishell-mcp"\nargs=[]\nenabled=true\n[mcp_servers.aishell.env]\nAISHELL_CAPABILITY_SET="expanded-v1"\n');
  await assert.rejects(setup({ ais: ['grok'], check: true }, f.dependencies), { code: 'REGISTRATION_MISMATCH' });
  assert.equal((await setup({ ais: ['grok'] }, f.dependencies)).status, 'ready');
  assert.deepEqual((await readHost(spec)).data.disabled_mcp_servers, ['other']);
  assert.ok((await readFile(spec.file, 'utf8')).includes('# 保持'));
  assert.equal((await setup({ ais: ['grok'] }, f.dependencies)).hosts[0].registration, 'unchanged');
});

test('MCPは初期化・順序付き呼出しを行い子processを回収する', async t => {
  const f = await fixture(t), script = path.join(f.home, 'mcp.mjs');
  await writeFile(script, `import{createInterface}from'node:readline';createInterface({input:process.stdin}).on('line',l=>{let m=JSON.parse(l);if(m.id)console.log(JSON.stringify({jsonrpc:'2.0',id:m.id,result:m.method==='initialize'?{protocolVersion:'2025-11-25',serverInfo:{version:'test'}}:{structuredContent:{ready:true}}}));});`);
  const result = await withMCP({ command: process.execPath, args: [script] }, async ({ call }) => (await call('probe')).structuredContent);
  assert.deepEqual(result, { ready: true });
});

test('MCP起動失敗・timeout・tool errorを明示する', async t => {
  const f = await fixture(t), script = path.join(f.home, 'mcp.mjs');
  await assert.rejects(withMCP({ command: path.join(f.home, 'absent') }, async () => {}), { code: 'MCP_START_FAILED' });
  await writeFile(script, 'setInterval(()=>{},1000);');
  await assert.rejects(withMCP({ command: process.execPath, args: [script] }, async () => {}, { timeout: 50 }), { code: 'MCP_TIMEOUT' });
  await writeFile(script, `import{createInterface}from'node:readline';createInterface({input:process.stdin}).on('line',l=>{let m=JSON.parse(l);if(m.id)console.log(JSON.stringify({jsonrpc:'2.0',id:m.id,result:m.method==='initialize'?{protocolVersion:'2025-11-25'}:{isError:true}}));});`);
  await assert.rejects(withMCP({ command: process.execPath, args: [script] }, async ({ call }) => call('probe')), { code: 'MCP_OPERATION_FAILED' });
});
