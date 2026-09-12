import { access, mkdtemp, rm } from 'node:fs/promises';
import { constants } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { homedir, tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { aiNames, hostSpec, planHost, verifyHost, writeHost } from './hosts.mjs';
import { SetupError, withMCP } from './mcp-client.mjs';

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

export async function smoke(registration, expectedVersion, { env = process.env } = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), 'aishell-setup-smoke-'));
  try {
    return await withMCP(registration, async ({ initialized, request, call }) => {
      if (initialized?.serverInfo?.version !== expectedVersion) throw new SetupError('MCP_VERSION_MISMATCH', '登録先のMCP版が導入済みpackageと一致しません。PATHを確認してください。');
      const list = await request('tools/list', {});
      const names = list?.tools?.map(tool => tool.name) ?? [];
      if (!['files_write_text', 'files_read_text', 'process_run'].every(name => names.includes(name))) throw new SetupError('MCP_CAPABILITY_MISMATCH', 'ファイル操作とprocess実行を利用できません。');
      const content = 'AIShell setup smoke\n日本語 $HOME; *';
      await call('files_write_text', { path: 'probe.txt', content });
      const read = (await call('files_read_text', { path: 'probe.txt' })).structuredContent;
      if (read?.text !== content) throw new SetupError('MCP_SMOKE_FAILED', '書き込んだ内容と読取り結果が一致しません。');
      const run = (await call('process_run', { executable: '/usr/bin/printf', arguments: ['%s', content] })).structuredContent;
      if (run?.exitCode !== 0 || run.stdout?.encoding !== 'utf8' || run.stdout.data !== content) throw new SetupError('MCP_SMOKE_FAILED', '直接実行の出力が一致しません。');
      return { version: initialized.serverInfo.version, toolCount: names.length, operations: ['files_write_text', 'files_read_text', 'process_run'], ready: true };
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
  const report = { schemaVersion: 'aishell.setup.v2', mode: options.check ? 'diagnose' : 'setup', platform: { os: platform, arch, version: macVersion }, hosts: [], skipped: aiNames.filter(ai => !chosen.some(spec => spec.ai === ai)) };
  const version = dependencies.version ?? JSON.parse(await (await import('node:fs/promises')).readFile(path.join(packageDirectory, 'package.json'), 'utf8')).version;
  const backupDirectory = path.join(home, 'Library/Application Support/AIShell/setup-backups');
  let stage = 'preflight';
  try {
    // 全対象を先に解析し、既存設定を保持して登録する。
    const plans = [];
    for (const spec of chosen) plans.push(await planHost(spec));
    for (const plan of plans) {
      stage = `register:${plan.spec.ai}`;
      if (!options.check) await (dependencies.write ?? writeHost)(plan, backupDirectory);
      else if (plan.changed) throw new SetupError('REGISTRATION_MISMATCH', `${plan.spec.ai}のAIShell登録が正規契約と一致しません。setupを実行してください。`);
      const registration = await verifyHost(plan);
      const host = { ai: plan.spec.ai, registration: options.check ? 'verified' : plan.changed ? 'updated' : 'unchanged', ready: false };
      report.hosts.push(host);
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
