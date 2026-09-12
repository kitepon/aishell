#!/usr/bin/env node
import { chmod, copyFile, mkdir, rm } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
if (process.platform !== 'darwin' || process.arch !== 'arm64') throw new Error('配布buildにはApple SiliconのMacが必要です。');
const build = spawnSync('swift', ['build', '-c', 'release', '--product', 'aishell-mcp'], { cwd: root, stdio: 'inherit' });
if (build.error) throw build.error;
if (build.status !== 0) throw new Error('Swiftのrelease buildに失敗しました。');
const location = spawnSync('swift', ['build', '-c', 'release', '--show-bin-path'], { cwd: root, encoding: 'utf8' });
if (location.error) throw location.error;
if (location.status !== 0) throw new Error('実行ファイルの保存先を取得できません。');
const dist = path.join(root, 'dist');
await mkdir(dist, { recursive: true });
// 旧配布形式の生成物を残さない。
await rm(path.join(dist, 'AIShell.app'), { recursive: true, force: true });
await copyFile(path.join(location.stdout.trim(), 'aishell-mcp'), path.join(dist, 'aishell-mcp'));
await chmod(path.join(dist, 'aishell-mcp'), 0o755);
console.log(path.join(dist, 'aishell-mcp'));
