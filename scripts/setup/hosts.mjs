import { readFile, lstat, mkdir, writeFile, rename, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { parse } from 'smol-toml';
import { replaceTOMLRegistration, replaceTopLevelValue } from './toml-registration.mjs';
import { SetupError } from './mcp-client.mjs';

export const aiNames = ['claude', 'codex', 'grok', 'cursor'];
export function hostSpec(ai, home, env) {
  if (ai === 'cursor' && env.CURSOR_HOME && path.resolve(env.CURSOR_HOME) !== path.join(home, '.cursor')) {
    throw new SetupError('AI_CONFIG_LOCATION_UNSUPPORTED', 'CursorはCURSOR_HOMEを読みません。通常の~/.cursorを使う環境でsetupを実行してください。');
  }
  const bases = {
    claude: env.CLAUDE_CONFIG_DIR || path.join(home, '.claude'),
    codex: env.CODEX_HOME || path.join(home, '.codex'),
    grok: env.GROK_HOME || path.join(home, '.grok'),
    cursor: path.join(home, '.cursor'),
  };
  if (!aiNames.includes(ai)) throw new SetupError('AI_UNSUPPORTED', `未対応のAIです: ${ai}`);
  const base = path.resolve(bases[ai]);
  return {
    ai, base,
    file: ai === 'claude' ? (env.CLAUDE_CONFIG_DIR ? path.join(base, '.claude.json') : path.join(home, '.claude.json'))
      : path.join(base, ai === 'cursor' ? 'mcp.json' : 'config.toml'),
    format: ['codex', 'grok'].includes(ai) ? 'toml' : 'json',
    key: ['codex', 'grok'].includes(ai) ? 'mcp_servers' : 'mcpServers',
  };
}

function object(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new SetupError('CONFIG_INVALID', `${label}はobjectである必要があります。`);
  return value;
}

export function canonicalRegistration(current = {}, ai) {
  object(current, 'AIShell設定');
  const next = { ...current, command: 'aishell-mcp', args: [], env: { ...object(current.env ?? {}, 'AIShell env') } };
  delete next.env.AISHELL_CAPABILITY_SET;
  delete next.env.AISHELL_TOOL_PROFILE;
  if (Object.values(next.env).some(value => typeof value !== 'string')) throw new SetupError('CONFIG_INVALID', 'AIShell envの値は文字列である必要があります。');
  // transportの旧値はAIShellが所有する。利用者のtimeout・許可tool等は保持する。
  for (const key of ['url', 'http_headers', 'env_http_headers', 'bearer_token_env_var', 'headers']) delete next[key];
  if (ai === 'claude' || ai === 'cursor') next.type = 'stdio';
  else { delete next.type; next.enabled = true; }
  if ('enabled' in next) next.enabled = true;
  if ('disabled' in next) next.disabled = false;
  return next;
}

export function decode(text, spec) {
  try { return object(text.trim() ? (spec.format === 'toml' ? parse(text) : JSON.parse(text)) : {}, 'AI設定'); }
  catch (error) {
    if (error instanceof SetupError) throw error;
    throw new SetupError('CONFIG_INVALID', `${spec.ai}の設定を解析できません。`);
  }
}

export async function readHost(spec) {
  let info;
  try { info = await lstat(spec.file); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (info && !info.isFile()) throw new SetupError('CONFIG_PATH_UNSUPPORTED', `${spec.ai}の設定は通常fileである必要があります。`);
  const text = info ? await readFile(spec.file, 'utf8') : '';
  const data = decode(text, spec);
  const servers = object(data[spec.key] ?? {}, `${spec.ai} MCP設定`);
  return { text, data, info, registration: servers.aishell };
}

export async function planHost(spec) {
  const before = await readHost(spec);
  const registration = canonicalRegistration(before.registration, spec.ai);
  const data = { ...before.data, [spec.key]: { ...before.data[spec.key], aishell: registration } };
  if (spec.ai === 'grok' && data.disabled_mcp_servers !== undefined) {
    if (!Array.isArray(data.disabled_mcp_servers) || data.disabled_mcp_servers.some(name => typeof name !== 'string')) throw new SetupError('CONFIG_INVALID', 'Grokのdisabled_mcp_serversは文字列配列である必要があります。');
    data.disabled_mcp_servers = data.disabled_mcp_servers.filter(name => name !== 'aishell');
  }
  const changed = !isDeepStrictEqual(before.data, data);
  let text;
  try { text = changed ? (spec.format === 'toml' ? replaceTOMLRegistration(before.text, registration) : JSON.stringify(data, null, 2) + '\n') : before.text; }
  catch { throw new SetupError('CONFIG_INVALID', `${spec.ai}の設定形式を保持して更新できません。`); }
  if (!isDeepStrictEqual(before.data.disabled_mcp_servers, data.disabled_mcp_servers)) text = replaceTopLevelValue(text, 'disabled_mcp_servers', data.disabled_mcp_servers);
  // serializeで他の設定値が変わる形式は、書込み前に明示拒否する。
  if (!isDeepStrictEqual(decode(text, spec), data)) throw new SetupError('CONFIG_SERIALIZATION_LOSS', `${spec.ai}の設定値を保持できません。`);
  return { spec, before, text, data, registration, changed };
}

export async function backupFiles(files, backupDirectory, label) {
  if (!files.length) return;
  await mkdir(backupDirectory, { recursive: true, mode: 0o700 });
  // 設定の原本をtarへ保存してから更新する。秘密を含み得るため作成時から0600に限定する。
  const archive = path.join(backupDirectory, `${label}-${randomUUID()}.tar`);
  await writeFile(archive, '', { flag: 'wx', mode: 0o600 });
  execFileSync('/usr/bin/tar', ['-cf', archive, '-C', '/', ...files.map(file => file.slice(1))], { stdio: 'pipe' });
}

export async function writeHost(plan, backupDirectory) {
  if (!plan.changed) return;
  const { spec, before, text } = plan;
  if (before.info) await backupFiles([spec.file], backupDirectory, spec.ai);
  await mkdir(path.dirname(spec.file), { recursive: true, mode: 0o700 });
  const temporary = path.join(path.dirname(spec.file), `.aishell-${randomUUID()}.tmp`);
  try {
    await writeFile(temporary, text, { flag: 'wx', mode: before.info ? before.info.mode & 0o777 : 0o600 });
    const current = await readHost(spec);
    if (current.text !== before.text || Boolean(current.info) !== Boolean(before.info)) throw new SetupError('CONFIG_CHANGED', `${spec.ai}の設定が同時に更新されました。再実行してください。`);
    await rename(temporary, spec.file);
  } finally { await rm(temporary, { force: true }); }
}

export async function verifyHost(plan) {
  const actual = await readHost(plan.spec);
  if (!isDeepStrictEqual(actual.registration, plan.registration)) throw new SetupError('REGISTRATION_MISMATCH', `${plan.spec.ai}の登録読戻しが一致しません。`);
  if (!isDeepStrictEqual(actual.data, plan.data)) throw new SetupError('CONFIG_CHANGED', `${plan.spec.ai}の他設定が変更されました。`);
  return actual.registration;
}
