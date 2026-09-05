<p align="center">
  <img src="https://raw.githubusercontent.com/kitepon/aishell/main/.github/og.png" alt="AIShell — AI開発へDirect OS contextを提供" width="100%">
</p>

# AIShell

[![CI](https://github.com/kitepon/aishell/actions/workflows/ci.yml/badge.svg)](https://github.com/kitepon/aishell/actions/workflows/ci.yml)
[![npm](https://img.shields.io/npm/v/@quolu/aishell)](https://www.npmjs.com/package/@quolu/aishell)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-111827)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138)

> AI開発hostへfreshなworkspace state、budget付きcontext、保持された実行証拠を渡すmacOS-native MCP runtime。すべての操作をshell文字列へ潰さず、OSに面する状態をモデルより下で所有する。

[English](README.md)

[kitepon.dev](https://kitepon.dev/)を運営する[クオ（@QLyun35332）](https://x.com/QLyun35332)が
開発・メンテナンスしています。

**所有境界:** 本repositoryはApple Silicon Mac向けruntimeのinstall、設定、
state/schema migration、診断、復旧、更新、releaseを単独で所有します。
[dotagents](https://github.com/kitepon/dotagents)は公開contractを使って製品横断wireと
互換性を統合しますが、AIShellの内部運用を制御しません。

AIShellはfile identity、filesystem照合state、直接起動したprocess、完全log、artifactを所有する。reasoning、thread、compaction、sub-agent、汎用terminalはAI hostの責務として残す。

## 30秒で試す

Apple Silicon Mac、macOS 15以降が必要。

```sh
npm install -g @quolu/aishell
aishell-open
codex mcp add aishell --env AISHELL_CAPABILITY_SET=expanded-v1 -- aishell-mcp
```

フォルダの事前登録は不要。新しいCodex taskで対象フォルダを指定して実行する。

```text
初回workspace contextはworkspace_snapshotで取得して。focused testはrun_checkで実行し、
summaryから省略された証拠だけartifact_readで読んで。
```

既定profileは5本の高密度development toolと、常時利用できる2本の復旧control toolを提供する。

| Tool | 役割 |
|---|---|
| `workspace_snapshot` | boundedな初回preview、照合済み変更delta、Git状態、主要context |
| `read_context` | SHA-256 identityとcontinuationを持つbudget付き複数file read |
| `search_context` | 直接起動した`rg` workerによるbudget付き検索context |
| `run_check` | 直接process実行、主要diagnostic、完全stdout/stderr artifact |
| `artifact_read` | 保持artifactのrange、tail、pattern周辺read |
| `runtime_status` | 停止状態、相対パスの基準、次操作の状態取得 |
| `runtime_open_manager` | AI操作の停止・再開のため管理アプリを開く |

MCP serverへ`AISHELL_CAPABILITY_SET=expanded-v1`を設定すると、candidate surfaceへ明示opt-inできる。
高密度development 9本と復旧control 2本を公開し、`run_observe`、`workspace_wait`、
`change_impact`、`apply_change_set`を追加する。既存toolにもmanaged run、artifact query、
semantic search、project profile、Git branch/worktree modeが加わる。

Codexでは次のように登録する。

```sh
codex mcp add aishell --env AISHELL_CAPABILITY_SET=expanded-v1 -- aishell-mcp
```

未知値または空の`AISHELL_CAPABILITY_SET`と`AISHELL_TOOL_PROFILE`はtyped errorでstartup停止し、
別profileへ黙ってfallbackしない。

lexical `search_context`は`ranking`を省略できる。workspace cursorなしではtest path、
`changed_since_cursor`ありでは変更pathとtest pathを優先する。`changed`を明示する場合だけcursorを必須とする。

## なぜAIShellか

statelessな連携では、モデルがworkspaceを何度もscanし、command出力から状態を再構成しやすい。AIShellは状態を持つOS側の仕事をモデルより下へ置き、後続turnが全再scanではなくdeltaと一次証拠を要求できるようにする。

| 論点 | AIShell | 一般的なshell-first連携 |
|---|---|---|
| Workspace state | file identity＋filesystem観測と照合 | commandを再実行してtextから再構成 |
| Context | budget・cursor付きstructured result | stdoutを手動または暗黙に切り詰める |
| Execution | executable URL、引数、cwd、lifecycleを分離 | shellが1本のcommand文字列を評価 |
| Evidence | 完全stdout/stderrを期限付きhandleで保持 | response truncation時に証拠が失われやすい |
| Scope | macOSのアクセス権と明示的stop状態 | 周囲のshellとhost policyに依存 |

AIShellはsandboxではなく、任意code実行を安全化しない。process railの目的はtyped executionと観測可能なlifecycleを維持することであり、改名binaryや許可workerが起動する子processを阻止することではない。

## Architecture

```mermaid
flowchart LR
    Host[AI host<br/>reasoning · threads · compaction] --> MCP[AIShellMCP<br/>MCP 2025-11-25]
    MCP --> Core[AIShellCore]
    Core --> State[File identity<br/>FSEvents + reconciliation]
    Core --> Process[Direct process lifecycle<br/>stdout · stderr · timeout]
    Core --> Evidence[Retained evidence<br/>artifacts · freshness]
    Process --> Workers[git · rg · compiler · tests]
    State --> macOS[macOS APIs]
    Evidence --> Host
```

`AIShellCore`がdomain挙動を所有し、`AIShellMCP`はprotocol request/resultだけを変換する。Git、ripgrep、compiler、test、SourceKit-LSPは新しいstate ownerにせず、直接起動するworkerとして再利用する。

## npmからinstall

global packageは`aishell-mcp`と`aishell-open`を`PATH`へ追加する。`aishell-open`は同梱された管理アプリをLaunchServicesで開く。install scriptは実行しない。

更新時に管理アプリを開いたままだと、旧processが置換前のbundleを参照し続ける。管理アプリは差し替えを検知してバナーを表示する。同じパスに新版があればバナーから再起動し、移動・削除されていれば終了後に`aishell-open`で開き直す。接続済みのMCPも、hostで再接続すると新版へ切り替わる。

```sh
npm install -g @quolu/aishell
aishell-open
```

現在の実験版はDeveloper ID署名・notarization前である。

## Sourceからbuild

```sh
git clone https://github.com/kitepon/aishell.git
cd aishell
swift test
scripts/package-app.sh release
open build/AIShell.app
```

MCP実行ファイルは`build/AIShell.app/Contents/Helpers/aishell-mcp`へ同梱される。

フォルダ登録は不要。絶対パスは指定した場所を、相対パスと省略時はMCP起動ディレクトリを基準にする。Git worktreeも直接指定でき、旧設定の許可フォルダ一覧は無視される。

## 別のAI hostへ接続

global npm install後は`PATH`上のcommand名とexpanded development surfaceを登録する。

```sh
codex mcp add aishell --env AISHELL_CAPABILITY_SET=expanded-v1 -- aishell-mcp
claude mcp add --scope user aishell --env AISHELL_CAPABILITY_SET=expanded-v1 -- aishell-mcp
codex mcp get aishell
```

解除:

```sh
codex mcp remove aishell
```

expanded capability未指定時の互換用full profileは全25 toolを提供する。既定7本は5本の
development toolと2本の復旧control toolで、full modeは残りのlegacy primitiveも公開する。
`expanded-v1`ではdevelopment 11本、full 29本を公開する。

```sh
AISHELL_TOOL_PROFILE=full /opt/homebrew/bin/aishell-mcp
AISHELL_CAPABILITY_SET=expanded-v1 AISHELL_TOOL_PROFILE=full /opt/homebrew/bin/aishell-mcp
```

full profileにはfile一覧・read、SHA-256競合検出付きatomic update、copy/move/rename/Trash、直接process実行、app discovery/launch、runtime status、管理アプリの前面化が含まれる。

## 実行と安全性の境界

- shell command文字列を評価しない。開発programを`PATH`からexecutable URLへ解決し、arguments、environment、working directoryと分離する。
- `sh`、`bash`、`zsh`、`env`、`osascript`等のbasename直接起動を製品上のrailとして拒否する。security boundaryとして宣伝しない。
- `run_check`はopen-world capabilityであり、許可workerはfile更新・子process・network accessを行い得る。AI hostによっては実行承認が必要になる。
- text更新はSHA-256または旧textを事前条件にできる。削除はTrashへ送る。
- 管理アプリから通常操作を一括停止できる。停止中もruntime statusと管理アプリの前面化は利用できる。

## 現在の制限

- stdio requestは復旧操作・読み取り・実行の3系統で処理する。読み取りと復旧操作は長時間の実行中も応答するが、実行系requestは直列化する。
- MCPの`notifications/cancelled`を受け付ける。管理対象processの明示的な停止は`run_observe`の`cancel`で行う。
- timeout時は直接所有するprocess treeを終了するが、終了までに許可workerがopen-worldな副作用を起こし得る。
- 初回workspace entryはbounded previewで、後続deltaはcursor pageになる。
- Developer ID署名とnotarizationは未設定。

## 運用・更新・release

単独installの更新は初回と同じ公式npm経路を使い、新版の管理アプリを開く。

```sh
npm install -g @quolu/aishell@latest
aishell-open
```

停止中の復旧入口は`runtime_status`と`runtime_open_manager`である。
工場consumerは専用`AISHELL_TOOL_PROFILE=factory` MCP surfaceから
`factory_diagnostics`を呼ぶ。schemaとprivacy境界は
[製品側diagnostics contract](https://github.com/kitepon/aishell/blob/main/docs/factory-diagnostics.md)が正である。

releaseでは`AIShellProduct.version`と`package.json`を一致させ、release記録を
[`docs/archive/releases/`](https://github.com/kitepon/aishell/tree/main/docs/archive/releases)へ追加して、次を実行する。

```sh
npm test
npm run test:package
git fetch origin
npm run verify:release-commit
npm whoami
npm publish --access public --browser=false
```

release gateはdirty treeと既定branchへ未着地のcommitを拒否する。publish後は対応する
GitHub Releaseを作り、`@quolu/aishell@latest`を再installしてMCP initializeと
`factory_diagnostics`をsmokeする。公開済みversionの正本はGitHub Releasesである。

### 公開認証と導入確認

`npm whoami`が認証エラーを返した場合は、対話端末で`npm login --registry=https://registry.npmjs.org/ --browser=false`を実行し、表示された新しいURLを利用するブラウザで開いて認証する。公開コマンドも対話端末で実行し、出力をファイルへリダイレクトしない。公開用の認証URLが表示された場合は、ログインとは別に認証する。URLが失効した場合はコマンドを再実行して新しいURLを使う。

npmのログインsessionは2時間で失効し、公開時には二要素認証が適用される（[npm公式説明](https://github.blog/changelog/2025-12-09-npm-classic-tokens-revoked-session-based-auth-and-cli-token-management-now-available/)）。公開の成功後に、registryとグローバルインストールを確認する。

```sh
npm view @quolu/aishell dist-tags.latest
npm install -g @quolu/aishell@latest
npm ls -g @quolu/aishell --depth=0
```

MCPを再接続し、`initialize`のversion、`runtime_status`、事前登録のない対象フォルダの検索と実行を確認する。工場診断は別processを`AISHELL_TOOL_PROFILE=factory`で起動し、`AISHELL_CAPABILITY_SET`を設定せずに確認する。

## 開発検証

```sh
swift test
scripts/package-app.sh release
```

`xcodegen generate`で`AIShell.xcodeproj`を再生成できる。実装の正本は`Sources/AIShellCore`、`Sources/AIShellMCP`、`Sources/AIShellApp`、focused testは`Tests/`に置く。

<details>
<summary>ローカルXcode検証時の注記</summary>

初回検証機ではXcode 26.6とCoreSimulatorのbuild versionが一致せず、`xcodebuild`はXCBuild開始前に停止した。同じSwift 6.3.3 toolchainを使うSwiftPMは通過した。このhost問題はsourceの成功扱いへ混ぜていない。

</details>

## ContributionとSecurity

変更提案前に[CONTRIBUTING.md](https://github.com/kitepon/aishell/blob/main/CONTRIBUTING.md)を確認してほしい。脆弱性はpublic issueへ書かず、[SECURITY.md](https://github.com/kitepon/aishell/blob/main/SECURITY.md)のprivate経路で報告する。

現役文書の索引は[`docs/README.md`](https://github.com/kitepon/aishell/blob/main/docs/README.md)、過去のrelease notesは
[`docs/archive/releases/`](https://github.com/kitepon/aishell/tree/main/docs/archive/releases)に置く。

## License

AIShellは[Apache License 2.0](LICENSE)で公開している。
