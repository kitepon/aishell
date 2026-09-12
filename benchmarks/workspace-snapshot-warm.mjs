import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { withMCP } from '../scripts/setup/mcp-client.mjs';

// 実repoの観測範囲を保ち、無変更・2file変更・restartを同じ要求で測る。
// 実行中は対象repoを編集しない。計測結果はrepo外へ保存する。
const command = process.argv[2] ?? 'aishell-mcp';
const output = process.argv[3] ?? join(tmpdir(), 'aishell-snapshot-warm.json');
const root = fileURLToPath(new URL('..', import.meta.url)).replace(/\/$/, '');
const state = await mkdtemp(join(tmpdir(), 'aishell-snapshot-warm-state-'));
const fixture = await mkdtemp(join(root, 'benchmarks/runtime-profile-'));
const request = {
  path: root, context_budget: 1800, entry_limit: 5,
  project_profile: { mode: 'none' },
  git_diff: {
    mode: 'branch', base_ref: '17d56c1642643099e669fe079ce2645cd2009afc^',
    include_patch: false, byte_budget: 3500,
  },
};
const measurements = [];
try {
  for (const name of ['a.txt', 'b.txt']) await writeFile(join(fixture, name), 'BEFORE\n');
  for (const processIndex of [0, 1]) {
    await withMCP({
      command, args: [],
      env: { AISHELL_CAPABILITY_SET: 'expanded-v1', AISHELL_STATE_DIRECTORY: state },
    }, async ({ initialized, call }) => {
      const phases = processIndex ? ['restart-warm'] : ['cold', 'unchanged-warm', 'two-file-change-warm'];
      for (const phase of phases) {
        if (phase === 'two-file-change-warm') {
          for (const name of ['a.txt', 'b.txt']) await writeFile(join(fixture, name), 'AFTER\n');
        }
        console.log(JSON.stringify({ phase, state: 'started' }));
        const start = performance.now();
        const body = (await call('workspace_snapshot', request)).structuredContent;
        const elapsedMs = Math.round(performance.now() - start);
        assert.equal(body.freshness, 'fresh');
        assert.equal(body.isFull, true);
        assert.equal(body.entries.length, 5);
        const entryCount = body.entries.length + body.omittedEntries;
        if (measurements.length) assert.equal(entryCount, measurements[0].entryCount);
        const measurement = {
          phase, version: initialized.serverInfo.version, elapsedMs, entryCount,
          returnedEntries: body.entries.length, checkpointState: body.checkpointState,
          freshness: body.freshness,
        };
        measurements.push(measurement);
        console.log(JSON.stringify(measurement));
        await writeFile(output, JSON.stringify({ request, measurements }, null, 2) + '\n');
      }
    }, { cwd: root, timeout: 240_000 });
  }
} finally {
  await rm(fixture, { recursive: true });
}
