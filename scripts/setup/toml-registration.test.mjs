import test from 'node:test';
import assert from 'node:assert/strict';
import { parse } from 'smol-toml';
import { replaceTOMLRegistration } from './toml-registration.mjs';

const registration = { command: 'aishell-mcp', args: [], env: { KEEP: 'fixture' }, enabled: true };
for (const input of [
  '[mcp_servers.aishell]\ncommand="old"\n[mcp_servers.aishell.env]\nKEEP="fixture"\n',
  '[mcp_servers."aishell"]\ncommand="old"\nenv={KEEP="fixture"}\n',
  '[mcp_servers]\naishell={command="old", env={KEEP="fixture"}}\n',
  'mcp_servers.aishell.command="old"\nmcp_servers.aishell.env.KEEP="fixture"\n',
  'mcp_servers={aishell={command="old",env={KEEP="fixture"}},other={command="other"}}\n',
  'mcp_servers={other={command="other"}}\n',
  '',
]) {
  test(`TOML登録形式: ${input.split('\n')[0] || '初回'}`, () => {
    const result = replaceTOMLRegistration(input, registration);
    assert.deepEqual(parse(result).mcp_servers.aishell, registration);
    assert.deepEqual(parse(result).mcp_servers.other, parse(input).mcp_servers?.other);
  });
}

test('他設定のコメント・数値表記・複数行文字列を保持する', () => {
  const first = '# 利用者コメント\nthreshold=1.0\ntext="""\n[mcp_servers.aishell]\ncommand="fake"\n"""\n';
  const last = '\n# 別server\n[mcp_servers.other]\ncommand="other"\nfloat=2.0 # コメント\n';
  const result = replaceTOMLRegistration(first + '[mcp_servers.aishell]\ncommand="old"\n' + last, registration);
  assert.ok(result.startsWith(first));
  assert.ok(result.includes(last));
  assert.deepEqual(parse(result).mcp_servers.aishell, registration);
});
