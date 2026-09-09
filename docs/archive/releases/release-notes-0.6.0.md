# AIShell 0.6.0

## 明示setupで導入後の準備とAI登録を完結

`aishell-setup`を追加した。対応Macで管理アプリの準備、Claude Code・Codex・Grok Build・Cursorへの
MCP登録、設定の読戻し、登録内容によるMCP実操作までを一回で確認する。
初回と更新後に同じ入口を使い、`--check`で設定を変えず診断できる。

- bare `aishell-mcp`と`AISHELL_CAPABILITY_SET=expanded-v1`を維持する。
- 旧登録を移行し、利用者のenv・PATH・他server・AI本体設定を保持する。TOMLは他設定のコメントも保持する。
- npm install lifecycleは引き続き持たない。管理アプリの準備は明示setup時だけ実行し、LaunchAgent等を作らない。
- Windows/Linux、Intel Mac、macOS 14以前を準備前に拒否する。
- 工場は対応Macで公式npm導入後にsetupを呼べばよく、個別AI設定の代行は不要になる。
- bare起動の非同期`run_check`が同梱supervisorを誤った場所から探す問題を修正した。

操作契約は[製品単体の導入・診断契約](../../setup.md)を参照。
公開記録の正本はGitHub Releases。
