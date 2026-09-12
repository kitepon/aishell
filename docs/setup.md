# AIShellの導入・登録

製品の準備はnpmによる導入とaishell-setupで完結します。管理アプリと認証画面はありません。対応環境はmacOS 15以降、Apple Siliconです。

## 入口

~~~sh
npm install -g @quolu/aishell@latest
aishell-setup
aishell-setup --ai claude,codex,grok,cursor
aishell-setup --check
~~~

対象を省略すると設定ファイルとPATHから導入済みAIを検出します。--checkは設定を変更せず、登録内容とMCP実操作を確認します。npm install lifecycleはprocessを起動しません。

## 登録

| AI | 設定ファイル | 登録先 |
|---|---|---|
| Claude Code | ~/.claude.json。CLAUDE_CONFIG_DIR指定時はその下の.claude.json | mcpServers.aishell |
| Codex | ~/.codex/config.toml。CODEX_HOME指定時はその下 | mcp_servers.aishell |
| Grok Build | ~/.grok/config.toml。GROK_HOME指定時はその下 | mcp_servers.aishell |
| Cursor | ~/.cursor/mcp.json | mcpServers.aishell |

commandはaishell-mcp、argsは空です。旧AISHELL_CAPABILITY_SETとAISHELL_TOOL_PROFILEを除去し、他のenv、PATH、timeout、tool許可、他serverの設定を保持します。AIShell登録の旧絶対パス、transport、無効化設定は現在のstdio登録へ更新します。

既存ファイルの書込み前に、~/Library/Application Support/AIShell/setup-backupsへtarを保存します。解析不能・symlink・同時更新は明示エラーにします。登録が同じ場合は設定を書き換えません。

Cursorが参照しない独自CURSOR_HOMEへの登録は拒否します。AI本体のログイン・承認・project設定は各AIが扱います。aishell-setupはAI本体のCLIやGUIを起動しません。

## 動作確認

設定を読戻し、そのcommand・args・envでMCPを起動します。initializeのprotocolとversion、tools/list、files_write_text、files_read_text、process_runを確認します。書込み・読取り・標準出力の実内容が一致して初めてreadyを返します。

結果schemaはaishell.setup.v2です。対象AIごとに登録結果、version、tool数、確認した操作、readyを返します。失敗はstageとerrorに残し、既に成功した登録を巻き戻しません。

更新後は既存のAIセッションを再接続するか、新しいセッションを開いてください。

## 旧版からの更新

管理UI、キーチェーン認証、編集取引の記録と復旧、監視、cache、専用診断、tool profileを廃止しました。旧toolへの呼出しには未定義toolとしてエラーを返します。

旧停止設定や暗号化記録を現在の操作へ読み込みません。鍵の移行と認証は不要です。使用ログは既存のactivity.jsonlへ追記します。旧版のウィンドウが開いている場合は終了してください。

工場やその他の呼出元も、通常のinitializeと必要なOS操作を利用します。AIShellは他製品の内部状態を管理しません。
