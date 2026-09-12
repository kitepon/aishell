# 製品単体の導入・診断契約

AIShellの明示入口は`aishell-setup`。macOS 15以降のApple Silicon（arm64）で、
AIへのMCP登録、設定の読戻し、登録内容による実操作を順に確認する。
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

## 管理UIと認証

管理UI、停止設定、Keychainアクセスは廃止した。npm installには`preinstall`、`install`、`postinstall`を持たせず、setupも認証画面や管理アプリを起動しない。
配布物は`dist/aishell-mcp`と`dist/aishell-run-supervisor`。`aishell-open`は配布しない。
`runtime_open_manager`は既存呼出元の互換名として残し、`MANAGER_REMOVED`を返す。
旧`runtime.json`は保持するが、停止状態や不正な内容で操作を妨げない。

`--check`はAI設定を変更せず、一時的なMCPで実操作を確認して終了する。
使用ログは`~/Library/Application Support/AIShell/activity.jsonl`へ保存する。

## 編集状態の更新

複数ファイル編集、競合検出、差分の保持、再起動後の継続は維持する。
新しい編集状態は`AISHELL_STATE_DIRECTORY`（省略時は`~/Library/Application Support/AIShell`）の
`apply-change-set-local-v1/`へ保存する。内部の鍵は0600の`state-key`に保存し、同時起動時も同じ鍵を共有する。Keychainへの読取り・書込み・認証は行わない。

旧`apply-change-set/`の暗号化履歴とKeychain項目は変更しない。
旧作業領域に`marker.json`だけがある対象では、rootの実体と記録の一致を確認して新しい状態を開始する。
旧版の作業ファイルが残っている場合は`CHANGE_SET_STORE_CORRUPT`で停止し、ファイルを消さない。
その場合は旧版で未完了編集を解決してから更新する必要がある。
旧client receiptと編集取引の履歴は新しい状態へ移さない。通常のファイルと使用ログは維持する。

新しい暗号化状態に対応する`state-key`が欠けた場合は`CHANGE_SET_SECRET_STORE_UNAVAILABLE`で終了し、別の鍵で上書きしない。
取引開始前の失敗は`error.request_status: aborted_before_side_effect`と空の`changed_paths`で確認できる。

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
`initialize`のprotocolとpackage版、`tools/list`のexpanded能力、`runtime_status`の利用可能状態を確認し、
事前登録のない一時folderに置いたfileを`workspace_snapshot`で確認する。
設定読戻しだけ、process起動要求だけ、CI成功だけを実端末の導入成功とはしない。
既存AIセッションのMCPは再接続または新しいセッションで新版へ切り替わる。
projectや組織による設定上書き・AIの承認操作は各AIが所有する。

代表的な失敗は`CONFIG_INVALID`、`CONFIG_CHANGED`、`REGISTRATION_MISMATCH`、
`MCP_START_FAILED`、`MCP_VERSION_MISMATCH`、`MCP_CAPABILITY_MISMATCH`、`MCP_TIMEOUT`。
利用者が保持したPATHやprofileのため接続できない場合も、別経路へ切り替えず失敗を返す。

## 工場との境界

工場は対応Macで公式npm導入後に`aishell-setup`を呼べばよい。
Claude/Codexの追加・削除による登録補正、Grok/Cursor設定内のAIShell項目の生成を
代行する必要はない。Windows/Linux向け工場設定からのAIShell削除は工場担当が行う。
AIShellは工場repoと他製品の設定を編集しない。工場専用`factory_diagnostics`のschemaは
[既存契約](factory-diagnostics.md)を維持し、対話host登録へfactory profileを混ぜない。
