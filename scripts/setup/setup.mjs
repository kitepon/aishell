import { access, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { constants } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { homedir, tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { aiNames, hostSpec, planHost, verifyHost, writeHost } from './hosts.mjs';
import { SetupError, withMCP } from './mcp-client.mjs';
import { verifyHostCLI } from './host-cli.mjs';

export const packageDirectory = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

export function supportedPlatform(platform, arch, macVersion) {
  if (platform !== 'darwin' || arch !== 'arm64' || !/^\d+(\.\d+)*$/.test(macVersion ?? '') || Number(macVersion.split('.')[0]) < 15) {
    throw new SetupError('PLATFORM_UNSUPPORTED', '対応環境はmacOS 15以降のApple Silicon（arm64）だけです。設定・processは作成しません。');
  }
}

async function exists(file, mode) {
  try { await access(file, mode); return true; }
  catch (error) { if (['ENOENT', 'EACCES'].includes(error.code)) return false; throw error; }
}

async function installed(spec, env) {
  if (await exists(spec.base) || await exists(spec.file)) return true;
  const commands = spec.ai === 'cursor' ? ['cursor', 'agent'] : [spec.ai];
  for (const directory of (env.PATH ?? '').split(path.delimiter)) {
    if (!directory) continue;
    for (const command of commands) if (await exists(path.join(directory, command), constants.X_OK)) return true;
  }
  return false;
}

export function prepareManager() {
  const binary = path.join(packageDirectory, 'dist/AIShell.app/Contents/Helpers/aishell-mcp');
  let value;
  try { value = JSON.parse(execFileSync(binary, ['--prepare-manager'], { encoding: 'utf8', timeout: 30000, stdio: ['ignore', 'pipe', 'pipe'] })); }
  catch { throw new SetupError('MANAGER_PREPARATION_FAILED', '管理アプリの準備に失敗しました。aishell-openで状態を確認してください。'); }
  if (!Number.isInteger(value.processIdentifier) || value.processIdentifier <= 0) throw new SetupError('MANAGER_PREPARATION_FAILED', '管理アプリの実行確認が返りませんでした。');
  return { ready: true, processIdentifier: value.processIdentifier };
}

export function prepareKeychain({ check, env }, run = execFileSync) {
  const binary = path.join(packageDirectory, 'dist/AIShell.app/Contents/Helpers/aishell-mcp');
  const invoke = argument => {
    const result = JSON.parse(run(binary, [argument], {
      env, encoding: 'utf8', timeout: argument === '--prepare-keychain' ? 300000 : 30000,
      stdio: ['ignore', 'pipe', 'pipe'],
    }));
    if (result.ready !== true || !Number.isInteger(result.checkedKeys) || result.checkedKeys < 0) throw new Error('invalid keychain result');
    return result;
  };
  try {
    if (!check) invoke('--prepare-keychain');
    // 対話processだけの一時許可をreadyとしない。別processで非対話の読取りを確認する。
    return invoke('--check-keychain');
  } catch {
    throw new SetupError('KEYCHAIN_NOT_READY', '導入済みhelperから既存の鍵の読取りを確認できません。aishell-setupを実行し、macOSの認証画面が出た場合は「常に許可」を選んでください。');
  }
}

export async function smoke(registration, expectedVersion, { env = process.env } = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), 'aishell-setup-smoke-'));
  try {
    await writeFile(path.join(directory, 'probe.txt'), 'AIShell setup smoke\n');
    return await withMCP(registration, async ({ initialized, request, call }) => {
      if (initialized?.serverInfo?.version !== expectedVersion) throw new SetupError('MCP_VERSION_MISMATCH', '登録先のMCP版が導入済みpackageと一致しません。PATHを確認してください。');
      const list = await request('tools/list', {});
      if (!list?.tools?.some(tool => tool.name === 'workspace_snapshot') || !list.tools.some(tool => tool.name === 'apply_change_set')) throw new SetupError('MCP_CAPABILITY_MISMATCH', 'expanded-v1の開発toolを利用できません。AISHELL_TOOL_PROFILEなどのenvを確認してください。');
      const status = (await call('runtime_status')).structuredContent;
      if (status?.isPaused !== false) throw new SetupError('RUNTIME_NOT_READY', 'AIShellが停止中か、状態を確認できません。管理アプリで再開してから再実行してください。');
      const snapshot = (await call('workspace_snapshot', { path: directory, context_budget: 0, entry_limit: 10, project_profile: { mode: 'none' } })).structuredContent;
      if (snapshot?.freshness !== 'fresh' || !snapshot.entries?.some(entry => entry.path === 'probe.txt' || entry.relativePath === 'probe.txt' || entry.path === path.join(directory, 'probe.txt'))) throw new SetupError('MCP_SMOKE_FAILED', '未登録フォルダの実fileをMCPで確認できません。');
      return { version: initialized.serverInfo.version, toolCount: list.tools.length, operation: 'workspace_snapshot', ready: true };
    }, { cwd: directory, env });
  } finally { await rm(directory, { recursive: true, force: true }); }
}

export async function setup(options = {}, dependencies = {}) {
  const env = dependencies.env ?? process.env;
  const platform = dependencies.platform ?? process.platform;
  const arch = dependencies.arch ?? process.arch;
  // 対応外OSではmacOS commandを含めて一切の準備処理を実行しない。
  const macVersion = platform === 'darwin' ? (dependencies.macVersion ?? execFileSync('/usr/bin/sw_vers', ['-productVersion'], { encoding: 'utf8' }).trim()) : null;
  supportedPlatform(platform, arch, macVersion);
  const home = dependencies.home ?? homedir();
  const chosen = options.ais ? options.ais.map(ai => hostSpec(ai, home, env)) : [];
  if (!options.ais) for (const ai of aiNames) {
    const spec = hostSpec(ai, home, { ...env, CURSOR_HOME: undefined });
    if (await installed(spec, env)) chosen.push(hostSpec(ai, home, env));
  }
  if (!chosen.length) throw new SetupError('AI_NOT_FOUND', '対応AIを検出できません。対象を--ai claude,codex,grok,cursorで指定してください。');
  const report = { schemaVersion: 'aishell.setup.v1', mode: options.check ? 'diagnose' : 'setup', platform: { os: platform, arch, version: macVersion }, manager: null, hosts: [], skipped: aiNames.filter(ai => !chosen.some(spec => spec.ai === ai)) };
  const version = dependencies.version ?? JSON.parse(await (await import('node:fs/promises')).readFile(path.join(packageDirectory, 'package.json'), 'utf8')).version;
  const backupDirectory = path.join(home, 'Library/Application Support/AIShell/setup-backups');
  let stage = 'preflight';
  try {
    // 全対象を先に解析する。壊れた設定があるままappや別AIを更新しない。
    const plans = [];
    for (const spec of chosen) plans.push(await planHost(spec));
    if (!options.check) {
      stage = 'prepare';
      report.manager = await (dependencies.prepare ?? prepareManager)();
    }
    stage = 'keychain';
    const keychains = new Map();
    report.keychain = [];
    for (const plan of plans) {
      const keychainEnv = { ...env, ...plan.registration.env };
      const statePath = keychainEnv.AISHELL_STATE_DIRECTORY ?? '';
      if (!keychains.has(statePath)) {
        const result = await (dependencies.keychain ?? prepareKeychain)({ check: Boolean(options.check), env: keychainEnv });
        keychains.set(statePath, result);
        report.keychain.push(result);
      }
    }
    for (const plan of plans) {
      stage = `register:${plan.spec.ai}`;
      if (!options.check) await (dependencies.write ?? writeHost)(plan, backupDirectory);
      else if (plan.changed) throw new SetupError('REGISTRATION_MISMATCH', `${plan.spec.ai}のAIShell登録が正規契約と一致しません。setupを実行してください。`);
      const registration = await verifyHost(plan);
      const host = { ai: plan.spec.ai, registration: options.check ? 'verified' : plan.changed ? 'updated' : 'unchanged', ready: false };
      report.hosts.push(host);
      stage = `host:${plan.spec.ai}`;
      Object.assign(host, await (dependencies.verifyCLI ?? verifyHostCLI)(plan.spec, registration, { check: options.check, env, cwd: dependencies.cwd ?? process.cwd(), backupDirectory }));
      stage = `smoke:${plan.spec.ai}`;
      const result = await (dependencies.smoke ?? smoke)(registration, version, { env });
      Object.assign(host, result);
    }
    return { ...report, status: 'ready' };
  } catch (error) {
    error.report = { ...report, status: 'failed', stage };
    throw error;
  }
}
