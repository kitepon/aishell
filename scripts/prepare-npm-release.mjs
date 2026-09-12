#!/usr/bin/env node
import { cp, mkdir, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
execFileSync('swift', ['build', '-c', 'release'], { cwd: root, stdio: 'inherit' });
const bin = execFileSync('swift', ['build', '-c', 'release', '--show-bin-path'], { cwd: root, encoding: 'utf8' }).trim();
const dist = path.join(root, 'dist');
await rm(dist, { recursive: true, force: true });
await mkdir(dist, { recursive: true });
for (const name of ['aishell-mcp', 'aishell-run-supervisor']) {
  const target = path.join(dist, name);
  await cp(path.join(bin, name), target);
  execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', target], { stdio: 'inherit' });
}
console.log('MCPと実行監視の実行ファイルを生成しました。');
