import { execFileSync } from 'node:child_process';
import { lstat, readdir } from 'node:fs/promises';
import path from 'node:path';
import { backupFiles } from './hosts.mjs';
import { SetupError } from './mcp-client.mjs';

export function runHostCLI(command, args, options) {
  try { return execFileSync(command, args, { ...options, encoding: 'utf8', timeout: 45000, stdio: ['ignore', 'pipe', 'pipe'] }); }
  catch (error) {
    throw new SetupError(error.code === 'ENOENT' ? 'AI_CLI_NOT_FOUND' : 'AI_VERIFICATION_FAILED', `${command}によるMCP確認に失敗しました。AI本体の導入・接続・承認状態を確認してください。`);
  }
}

async function present(file) {
  try {
    const info = await lstat(file);
    if (!info.isFile()) throw new SetupError('CONFIG_PATH_UNSUPPORTED', 'Cursorの設定は通常fileである必要があります。');
    return true;
  } catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}

async function backupCursor(spec, backupDirectory) {
  const files = [];
  const config = path.join(spec.base, 'cli-config.json');
  if (await present(config)) files.push(config);
  const directory = path.join(spec.base, 'projects');
  let entries;
  try { entries = await readdir(directory, { withFileTypes: true }); }
  catch (error) { if (error.code !== 'ENOENT') throw error; entries = []; }
  for (const entry of entries) if (entry.isDirectory()) {
    const file = path.join(directory, entry.name, 'mcp-approvals.json');
    if (await present(file)) files.push(file);
  }
  await backupFiles(files, backupDirectory, 'cursor-approval');
}

export async function verifyHostCLI(spec, registration, { check, env, cwd, backupDirectory, run = runHostCLI }) {
  const options = { env: { ...env, NO_COLOR: '1', TERM: 'dumb' }, cwd };
  let actual;
  if (spec.ai === 'codex') {
    const value = JSON.parse(run('codex', ['mcp', 'get', 'aishell', '--json'], options));
    if (value.enabled !== true || value.transport?.type !== 'stdio') throw new SetupError('AI_REGISTRATION_MISMATCH', 'Codexの実効登録が有効なstdioではありません。');
    actual = value.transport;
  } else if (spec.ai === 'grok') {
    const values = JSON.parse(run('grok', ['mcp', 'list', '--json'], options)).filter(item => item.name === 'aishell');
    if (values.length !== 1 || values[0].enabled !== true) throw new SetupError('AI_REGISTRATION_MISMATCH', 'Grokの実効登録を一意に確認できません。');
    actual = values[0];
  } else if (spec.ai === 'claude') {
    const output = run('claude', ['mcp', 'get', 'aishell'], options);
    if (!/^\s*Command: aishell-mcp\s*$/m.test(output) || !output.includes('expanded-v1') || !/Status:.*Connected/.test(output)) throw new SetupError('AI_REGISTRATION_MISMATCH', 'Claudeの実効登録またはMCP接続が一致しません。');
  } else {
    if (!check) {
      await backupCursor(spec, backupDirectory);
      run('agent', ['mcp', 'enable', 'aishell'], options);
    } else if (!await present(path.join(spec.base, 'cli-config.json'))) {
      throw new SetupError('AI_VERIFICATION_FAILED', 'Cursor CLIが未準備です。aishell-setupを実行してください。');
    }
    const output = run('agent', ['mcp', 'list-tools', 'aishell'], options);
    if (!['runtime_status', 'workspace_snapshot', 'apply_change_set'].every(name => output.includes(name))) throw new SetupError('AI_REGISTRATION_MISMATCH', 'Cursorからexpanded-v1のtoolを確認できません。');
  }
  if (actual && (actual.command !== registration.command || (actual.args ?? []).length !== 0 || actual.env?.AISHELL_CAPABILITY_SET !== 'expanded-v1')) throw new SetupError('AI_REGISTRATION_MISMATCH', `${spec.ai}の実効登録が製品登録と一致しません。project設定の上書きも確認してください。`);
  return { hostVerified: true };
}
