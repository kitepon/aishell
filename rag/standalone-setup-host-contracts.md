# 明示setupとAI設定の確認

- 取得・検証日: 2026-09-10
- 確度: 高（Codex/Claude/Cursor公式資料、導入済みCLIの隔離設定読戻し）
- 一次資料: `raw/standalone-setup-host-contracts.md`（引用と出典。再配布対象外）

## 設定場所と読戻し

Codexは`mcp_servers`をTOMLへ保存し、CLIとdesktopで共有する。
`CODEX_HOME`を隔離したCodex 0.150.1の`mcp get aishell --json`は、製品の登録を認識した。
[公式MCP設定](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)。

Claude Codeのuser scopeは`~/.claude.json`の`mcpServers`。
`CLAUDE_CONFIG_DIR`を隔離した2.1.259の`mcp get aishell`でも登録を認識した。
[公式のscope説明](https://code.claude.com/docs/en/mcp#user-scope)。

Grok Build 1.0.13は`GROK_HOME/config.toml`の`mcp_servers`を
`grok mcp list --json`で読戻し、user scope、command、args、env、enabledを返した。
公式Webの推測URLは取得できなかったため、導入済み公式CLIのhelpと実測を根拠とする。
同名登録をuserとprojectの両方へ置いた隔離実測では、JSONは`scope: project`の1件だけを返した。
`disabled_mcp_servers`に`aishell`があると、tableの`enabled: true`にかかわらず無効になることも確認した。

Cursorは`~/.cursor/mcp.json`を読む。CLI 2026.09.02-c22c1a3でHOMEを隔離し、
CURSOR_HOMEだけにmarkerを置いた場合は未登録と報告した。CURSOR_HOMEはCursor本体の設定homeとして扱えない。
[公式の設定場所](https://cursor.com/docs/mcp#configuration-locations)。
初回のtool取得には`agent mcp enable aishell`が必要だった。公式CLIは`~/.cursor/cli-config.json`と
`~/.cursor/projects/<project>/mcp-approvals.json`へ保存し、有効化後の`mcp list-tools aishell`で11 toolを返した。

## 管理アプリの起動完了

macOS 26.6.1/arm64で、`NSWorkspace.openApplication`の返却PIDを即座に
`NSRunningApplication(processIdentifier:)`へ渡すと、GUIが生存していても一時的に`nil`となった。
反復の3回目・7回目で再現した。PID 11244について、直後の`ps`はAIShell GUIの生存を示した。
返却された`NSRunningApplication`自身の`isFinishedLaunching`で完了を観測する。
このpropertyは`NSApplicationDidFinishLaunchingNotification`への到達に対応する。
[Apple公式仕様](https://developer.apple.com/documentation/appkit/nsrunningapplication/isfinishedlaunching)。
OSのprocess起動要求とAppKitの起動完了を同一視しない。

製品の現行コマンドと対応範囲は[setup契約](../docs/setup.md)を正とする。
他設定の値・TOMLコメントを維持し、MCPを直接起動するsmokeと、AI本体の設定読戻しを分けて検証する。
上書き優先順位やAIの承認はAI本体が所有する。
