# 製品単体の導入・診断契約

AIShellの明示入口は`aishell-setup`。macOS 15以降のApple Silicon（arm64）で、
管理アプリの準備、AIへのMCP登録、設定の読戻し、登録内容による実操作を順に確認する。
Windows、Linux、Intel Mac、macOS 14以前は`PLATFORM_UNSUPPORTED`で終了し、設定も常駐processも作らない。
npm packageの`os`/`cpu`制約も維持する。

## 正規コマンド

初回:

```sh
npm install -g @quolu/aishell && aishell-setup
```

再実行・対象AIの指定:

```sh
aishell-setup
aishell-setup --ai claude,codex,grok,cursor
```

更新:

```sh
npm install -g @quolu/aishell@latest && aishell-setup
```

診断:

```sh
aishell-setup --check
aishell-setup --check --ai codex
```

AI未指定時は設定directory/fileまたはCLIが存在するAIを選ぶ。未検出AIは`skipped`へ出す。
明示指定なら初回設定を作れる。AIが一つも見つからなければ`AI_NOT_FOUND`で終了する。
セットアップはJSONで結果を返し、全対象成功だけexit 0。失敗はexit 1と工程名・error codeを返す。
envや他の設定内容は診断へ出さない。
対象AIのCLI（`claude`、`codex`、`grok`、Cursorの`agent`）が必要。設定folderだけが残りCLIがない場合は
`AI_CLI_NOT_FOUND`で終了し、AI本体で未確認の登録を成功扱いにしない。

## 管理アプリ

npm installには`preinstall`、`install`、`postinstall`を持たせない。
`aishell-setup`を明示実行した時だけ、bundle内のnative helperが既存の
`NativeApplicationService`を使い、旧管理アプリを正常終了して導入済みアプリを開く。
更新前のbundleを参照する窓を残さず、LaunchServicesが返した実processとbundleを確認する。
終了・起動の失敗を`MANAGER_PREPARATION_FAILED`として返し、設定登録へ進まない。
LaunchAgentやlogin itemは作らない。`aishell-open`は管理アプリを開く既存入口として残る。

`--check`はアプリの起動・再起動とAI設定変更を行わない。MCPの一時processを起動し、
実操作後に回収する。AIShellの停止状態は保持し、停止中は`RUNTIME_NOT_READY`で再開方法を案内する。
診断のための一時folderは削除する。MCPが所有する通常の活動記録・保持stateは製品契約に従う。
AI本体の診断CLIが作るcache等は各AIが所有する。

## AI設定

| AI | 設定場所 | 登録先 |
|---|---|---|
| Claude Code | `~/.claude.json`（`CLAUDE_CONFIG_DIR`指定時はその下の`.claude.json`） | user scopeの`mcpServers.aishell` |
| Codex | `${CODEX_HOME:-~/.codex}/config.toml` | `mcp_servers.aishell` |
| Grok Build | `${GROK_HOME:-~/.grok}/config.toml` | `mcp_servers.aishell` |
| Cursor | `~/.cursor/mcp.json` | `mcpServers.aishell` |

Cursor本体は`CURSOR_HOME`を参照しない。Cursorが対象に含まれ、通常と異なる`CURSOR_HOME`が指定されている場合は、
その場所へ書いて成功扱いにせず`AI_CONFIG_LOCATION_UNSUPPORTED`で終了する。

登録するcommandはbare `aishell-mcp`、argsは空、envの`AISHELL_CAPABILITY_SET`は`expanded-v1`。
旧絶対パス・旧args・HTTP transportをstdio登録へ更新し、無効化済みのAIShell登録を有効にする。
Grokの`disabled_mcp_servers`では`aishell`だけを除き、他serverの無効化を保持する。
それ以外のenv、PATH、timeout、tool設定、他server、AI本体の設定値を保持する。
TOMLは構文木でAIShell部分だけを置換し、他設定のコメントと数値表記も保持する。
JSONは設定値を保持して整形する。シンボリックリンクや解析不能な設定は、上書きせず明示拒否する。

全対象を先に解析し、既存fileの変更前に`~/Library/Application Support/AIShell/setup-backups/`へ
0600のtarを保存する。内容変化を検出したら`CONFIG_CHANGED`で終了する。
再実行時に登録が同じなら設定fileを書かず、読戻しとMCP実操作を再確認する。
後続AIで失敗した場合、先に完了したAIは結果に残す。設定を無断で巻き戻さない。
同一端末の共有AI設定への導入は、他製品の設定更新が完了してから行う。

Cursor CLIはprojectごとにMCP承認を保存する。明示setupは現在のdirectoryから公式の
`agent mcp enable aishell`を呼び、AIShellだけを有効化する。既存CLI設定と承認fileは事前にtarへ保存する。
`--check`では有効化せず、既存承認でtoolを取得できることを確認する。別projectで必要な初回承認はCursorの仕様に従う。

## 実操作の成功条件

各AIの設定を読戻し、command・args・envでMCPを実際に起動する。
Codexの`mcp get`、Grokの`mcp list`、Claudeの`mcp get`で本体の実効登録を照合し、
Cursorは`mcp list-tools`でexpanded toolの利用を確認する。本体の確認失敗もsetup失敗になる。
`initialize`のprotocolとpackage版、`tools/list`のexpanded能力、`runtime_status`の停止状態を確認し、
事前登録のない一時folderに置いたfileを`workspace_snapshot`で確認する。
設定読戻しだけ、process起動要求だけ、CI成功だけを実端末の導入成功とはしない。
既存AIセッションのMCPは再接続または新しいセッションで新版へ切り替わる。
projectや組織による設定上書き・AIの承認操作は各AIが所有する。

代表的な失敗は`CONFIG_INVALID`、`CONFIG_CHANGED`、`REGISTRATION_MISMATCH`、
`MCP_START_FAILED`、`MCP_VERSION_MISMATCH`、`MCP_CAPABILITY_MISMATCH`、`MCP_TIMEOUT`。
利用者が保持したPATHやprofileのため接続できない場合も、別経路へ切り替えず失敗を返す。

## 工場との境界

工場は対応Macで公式npm導入後に`aishell-setup`を呼べばよい。
管理アプリの準備、Claude/Codexの追加・削除による登録補正、Grok/Cursor設定内のAIShell項目の生成を
代行する必要はない。Windows/Linux向け工場設定からのAIShell削除は工場担当が行う。
AIShellは工場repoと他製品の設定を編集しない。工場専用`factory_diagnostics`のschemaは
[既存契約](factory-diagnostics.md)を維持し、対話host登録へfactory profileを混ぜない。
