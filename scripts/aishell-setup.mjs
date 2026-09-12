#!/usr/bin/env node
import { setup } from './setup/setup.mjs';
import { SetupError } from './setup/mcp-client.mjs';
import { aiNames } from './setup/hosts.mjs';

try {
  const args = process.argv.slice(2);
  if (args.length === 1 && ['--help', '-h'].includes(args[0])) {
    console.log('aishell-setup [--ai claude,codex,grok,cursor] [--check]\n初回・再実行・更新後に管理アプリ準備、MCP登録、読戻し、実操作を確認します。\n省略時は導入済みAIを検出。--checkは設定変更と管理アプリ起動を行いません。');
  } else {
    const options = {};
    for (let index = 0; index < args.length; index++) {
      if (args[index] === '--check' && options.check === undefined) options.check = true;
      else if (args[index] === '--ai' && options.ais === undefined) {
        options.ais = (args[++index] ?? '').split(',');
        if (options.ais.some(ai => !aiNames.includes(ai)) || new Set(options.ais).size !== options.ais.length) throw new SetupError('AI_UNSUPPORTED', '--aiにはclaude,codex,grok,cursorを重複なしで指定してください。');
      } else throw new SetupError('ARGUMENT_INVALID', '引数を確認してください。aishell-setup --helpで使い方を表示できます。');
    }
    console.log(JSON.stringify(await setup(options)));
  }
} catch (error) {
  console.error(JSON.stringify({ ...(error.report ?? { schemaVersion: 'aishell.setup.v1', status: 'failed' }), error: { code: error.code ?? 'SETUP_FAILED', message: error instanceof SetupError ? error.message : 'setup中の入出力処理に失敗しました。設定fileの権限と導入状態を確認してください。' } }));
  process.exitCode = 1;
}
