<p align="center">
  <img src="https://raw.githubusercontent.com/kitepon/aishell/main/.github/og.png" alt="AIShell — Direct OS context for AI development" width="100%">
</p>

# AIShell

[![CI](https://github.com/kitepon/aishell/actions/workflows/ci.yml/badge.svg)](https://github.com/kitepon/aishell/actions/workflows/ci.yml)
[![npm](https://img.shields.io/npm/v/@quolu/aishell)](https://www.npmjs.com/package/@quolu/aishell)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-111827)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138)

> A macOS-native MCP runtime that gives AI development hosts fresh workspace state, bounded context, and retained execution evidence—without collapsing every operation into a shell string.

[日本語](README.ja.md)

Built and maintained by [Quo](https://x.com/QLyun35332) at [kitepon.dev](https://kitepon.dev/en).

**Ownership boundary:** this repository owns the standalone macOS Apple Silicon
runtime, including installation, configuration, state/schema migration,
diagnostics, recovery, updates, and releases.
[dotagents](https://github.com/kitepon/dotagents) consumes the public contract
for cross-product wiring and compatibility; it does not control AIShell's
internal operation.

AIShell owns the OS-facing state below the model: file identity, filesystem reconciliation, directly launched processes, complete logs, and retained artifacts. The AI host remains responsible for reasoning, threads, compaction, sub-agents, and general-purpose terminal work.

## Try it in 30 seconds

Requires an Apple Silicon Mac running macOS 15 or later.

```sh
npm install -g @quolu/aishell && aishell-setup
```

フォルダの事前登録は不要です。新しいCodex taskで対象フォルダを指定して実行します。

```text
Use workspace_snapshot for the initial workspace context. Run the focused tests with
run_check, and read retained output with artifact_read only if the summary omits evidence.
```

The default profile exposes five high-density development tools, runtime status, and the retired manager entrypoint:

| Tool | Purpose |
|---|---|
| `workspace_snapshot` | Bounded initial workspace preview, reconciled change delta, Git state, and primary context |
| `read_context` | Budgeted multi-file reads with SHA-256 identity and continuation |
| `search_context` | Budgeted lexical context from a directly launched `rg` worker, scoped to a directory or one regular file; the expanded capability also provides cursor-bound semantic definition/reference/symbol queries without lexical fallback |
| `run_check` | Direct process execution, primary diagnostics, and complete stdout/stderr artifacts |
| `artifact_read` | Range, tail, and pattern-centered reads from retained artifacts; the expanded capability also searches and compares finalized managed-run artifacts |
| `runtime_status` | 実行状態と相対パスの基準 |
| `runtime_open_manager` | 互換用の旧入口。管理UIの廃止を`MANAGER_REMOVED`で返す |

Set `AISHELL_CAPABILITY_SET=expanded-v1` on the MCP server process to opt in to the candidate surface. It exposes nine high-density development tools, runtime status, and the retired manager entrypoint. The added tools are `run_observe`, `workspace_wait`, `change_impact`, and `apply_change_set`; existing tools gain closed managed-run, artifact query, semantic search, project-profile, and Git branch/worktree modes. Cross-run artifact operations require an explicit project path and reject live, expired, legacy-unbound, or different-project evidence instead of silently falling back to partial logs.

For Codex, register the expanded surface explicitly:

```sh
aishell-setup --ai codex
```

Unknown or empty `AISHELL_CAPABILITY_SET` and `AISHELL_TOOL_PROFILE` values fail startup with typed errors; they never fall back to another profile.

For lexical `search_context`, omitting `ranking` is valid: requests without a workspace cursor prioritize tests, while requests with `changed_since_cursor` prioritize changed paths and tests. Explicit `changed` ranking still requires that cursor.

`AISHELL_TOOL_PROFILE=factory` is a separate, one-tool surface for factory reporters rather than development work. It exposes only `factory_diagnostics`, a path- and activity-free native readiness report.

## Why AIShell

Typical stateless integrations repeatedly ask the model to rediscover workspace state and interpret command output. AIShell keeps the stateful, OS-facing part below the model so later turns can ask for deltas and primary evidence instead of rescanning everything.

| Concern | AIShell | Typical shell-first integration |
|---|---|---|
| Workspace state | File identity plus filesystem observation and reconciliation | Re-run commands and reconstruct state from text |
| Context | Bounded, cursor-based structured results | Unbounded or manually truncated stdout |
| Execution | Executable URL, arguments, working directory, and lifecycle remain separate | A shell evaluates one command string |
| Evidence | Complete stdout/stderr retained behind expiring handles | Evidence often disappears when the response is truncated |
| Scope | macOS access permissions | Depends on the surrounding shell and host policy |

AIShell is not a sandbox and does not make arbitrary code execution safe. Its process rails exist to preserve typed execution and observable lifecycle—not to stop renamed binaries or child processes launched by an allowed worker.

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

`AIShellCore` owns domain behavior. `AIShellMCP` only translates protocol requests and results. Git, ripgrep, compilers, tests, and SourceKit-LSP remain directly launched workers rather than becoming new state owners.

## Install from npm

global packageは`aishell-mcp`、`aishell-setup`を`PATH`へ追加する。npm install自体ではスクリプトも管理アプリも起動しない。

対象AIのCLI（`claude`、`codex`、`grok`、Cursorの`agent`）を先に導入する。setupは各CLIからの読戻しも確認する。

`aishell-setup`は導入済みのClaude Code・Codex・Grok Build・Cursorを検出し、MCP登録、設定の読戻し、実際のMCP操作まで確認する。登録はbare `aishell-mcp`＋`AISHELL_CAPABILITY_SET=expanded-v1`。利用者のenv、PATH、他の設定を保持する。`--ai`で対象を指定でき、`--check`は設定を変更せず診断する。Windows/LinuxとIntel Macは対象外。詳細は[製品単体の導入契約](https://github.com/kitepon/aishell/blob/main/docs/setup.md)を参照。

更新後も同じ`aishell-setup`を実行する。登録保持・読戻し・MCP実操作まで確認する。管理UIとKeychain認証は不要。接続済みのMCPは、hostで再接続すると新版へ切り替わる。


```sh
npm install -g @quolu/aishell && aishell-setup
```

The current experimental build is not yet Developer ID signed or notarized.

## Build from source

```sh
git clone https://github.com/kitepon/aishell.git
cd aishell
swift test
npm run build:npm
```

実行ファイルは`dist/aishell-mcp`と`dist/aishell-run-supervisor`へ生成する。

フォルダ登録は不要です。絶対パスは指定した場所を、相対パスと省略時はMCP起動ディレクトリを基準にします。Git worktreeも直接指定できます。旧設定の許可フォルダ一覧は無視されます。

## Connect another AI host

For a global npm installation, register the executable name from `PATH` and the expanded development surface:

```sh
aishell-setup --ai claude,codex,grok,cursor
aishell-setup --check
```

Remove the registration with:

```sh
codex mcp remove aishell
```

Without the expanded capability, the compatibility profile retains all 25 tools. The default seven are the five development tools plus runtime status and the retired manager entrypoint; full mode adds the remaining legacy primitives. With `expanded-v1`, development exposes 11 tools and full exposes 29:

```sh
AISHELL_TOOL_PROFILE=full /opt/homebrew/bin/aishell-mcp
AISHELL_CAPABILITY_SET=expanded-v1 AISHELL_TOOL_PROFILE=full /opt/homebrew/bin/aishell-mcp
```

The full profile includes file listing and reads, atomic SHA-256-guarded updates, copy/move/rename/Trash, direct process execution, app discovery and launch, runtime status.

`apply_change_set`は編集状態を通常のJSONとして保存し、新しい暗号鍵や所有者証明を作らない。競合検出、差分、再起動後の継続を維持する。
ローカル鍵を使っていた旧版の記録は必要になった時に読み取り、通常の編集で更新する記録から平文へ切り替える。旧鍵や履歴の一括削除は行わない。
使用ログは`~/Library/Application Support/AIShell/activity.jsonl`へ保存する。詳しくは[導入契約](https://github.com/kitepon/aishell/blob/main/docs/setup.md)を参照。

## Execution and safety boundaries

- AIShell never evaluates a shell command string. It resolves a development program from `PATH` to an executable URL and keeps arguments, environment, and working directory separate.
- Direct launch of shell and wrapper basenames such as `sh`, `bash`, `zsh`, `env`, and `osascript` is rejected as a product rail, not advertised as a security boundary.
- `run_check` is an open-world capability: an allowed worker may update files, launch child processes, or access the network. AI hosts may require approval before execution.
- npm projects may opt a `build`, `test`, or `lint` check into freshness caching with the closed
  direct-Node `package.json` declaration documented in `docs/adr/0009-project-profile-contract.md`. Ordinary npm
  scripts remain executable but cache-ineligible; AIShell does not infer arguments, inputs, or effects
  from shell script text.
- Text updates may use SHA-256 or expected old text as a precondition. Deletes go to Trash.
- 管理UIと停止設定は廃止した。旧`runtime.json`は操作の条件にしない。

## Current limitations

- stdio requestは復旧操作・読み取り・実行の3系統で処理する。読み取りと復旧操作は長時間の実行中も応答するが、実行系requestは直列化する。
- MCPの`notifications/cancelled`を受け付ける。管理対象processの明示的な停止は`run_observe`の`cancel`で行う。
- A timeout terminates the directly owned process tree, but an allowed worker remains capable of open-world side effects before termination.
- Initial workspace entries are a bounded preview; later deltas are cursor-paged.
- Developer ID signing and notarization are not yet configured.

## Operations, updates, and releases

Upgrade a standalone installation through the same official npm path used for
initial installation, then run the explicit setup:

```sh
npm install -g @quolu/aishell@latest && aishell-setup
```

`runtime_status`で実行状態を確認できる。管理UIは廃止済み。
Factory consumers call `factory_diagnostics`
through the dedicated `AISHELL_TOOL_PROFILE=factory` MCP surface; its schema and
privacy boundary are owned by [the product contract](https://github.com/kitepon/aishell/blob/main/docs/factory-diagnostics.md).

For a release, keep `AIShellProduct.version` and `package.json` aligned, add the
release record under [`docs/archive/releases/`](https://github.com/kitepon/aishell/tree/main/docs/archive/releases), and run:

```sh
npm test
npm run test:package
git fetch origin
npm run verify:release-commit
npm whoami
npm publish --access public --browser=false
```

The release gate rejects a dirty tree or a commit that has not landed on the
default branch. After publishing, create the matching GitHub Release, reinstall
`@quolu/aishell@latest`, run `aishell-setup` and `aishell-setup --check`, and separately smoke `factory_diagnostics`.
GitHub Releases are the public record of shipped versions.

### 公開認証と導入確認

`npm whoami`が認証エラーを返した場合は、対話端末で`npm login --registry=https://registry.npmjs.org/ --browser=false`を実行し、表示された新しいURLを利用するブラウザで開いて認証する。公開コマンドも対話端末で実行し、出力をファイルへリダイレクトしない。公開用の認証URLが表示された場合は、ログインとは別に認証する。URLが失効した場合はコマンドを再実行して新しいURLを使う。

npmのログインsessionは2時間で失効し、公開時には二要素認証が適用される（[npm公式説明](https://github.blog/changelog/2025-12-09-npm-classic-tokens-revoked-session-based-auth-and-cli-token-management-now-available/)）。公開の成功後に、registryとグローバルインストールを確認する。

```sh
npm view @quolu/aishell dist-tags.latest
npm install -g @quolu/aishell@latest
npm ls -g @quolu/aishell --depth=0
```

MCPを再接続し、`initialize`のversion、`runtime_status`、事前登録のない対象フォルダの検索と実行を確認する。工場診断は別processを`AISHELL_TOOL_PROFILE=factory`で起動し、`AISHELL_CAPABILITY_SET`を設定せずに確認する。

## Development

```sh
swift test
npm run build:npm
```

実装は`Sources/AIShellCore`、`Sources/AIShellMCP`、`Sources/AIShellRunSupervisor`に置き、SwiftPMでbuildする。

## Contributing and security

See [CONTRIBUTING.md](https://github.com/kitepon/aishell/blob/main/CONTRIBUTING.md) before proposing a change. Please report vulnerabilities through the private process in [SECURITY.md](https://github.com/kitepon/aishell/blob/main/SECURITY.md), not through a public issue.

The current documentation map is [`docs/README.md`](https://github.com/kitepon/aishell/blob/main/docs/README.md). Historical
release notes live in [`docs/archive/releases/`](https://github.com/kitepon/aishell/tree/main/docs/archive/releases).

## License

AIShell is licensed under the [Apache License 2.0](LICENSE).
