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
npm install -g @quolu/aishell
aishell-open
codex mcp add aishell --env AISHELL_CAPABILITY_SET=expanded-v1 -- aishell-mcp
```

フォルダの事前登録は不要です。新しいCodex taskで対象フォルダを指定して実行します。

```text
Use workspace_snapshot for the initial workspace context. Run the focused tests with
run_check, and read retained output with artifact_read only if the summary omits evidence.
```

The default profile exposes five high-density development tools plus two always-available recovery controls:

| Tool | Purpose |
|---|---|
| `workspace_snapshot` | Bounded initial workspace preview, reconciled change delta, Git state, and primary context |
| `read_context` | Budgeted multi-file reads with SHA-256 identity and continuation |
| `search_context` | Budgeted lexical context from a directly launched `rg` worker, scoped to a directory or one regular file; the expanded capability also provides cursor-bound semantic definition/reference/symbol queries without lexical fallback |
| `run_check` | Direct process execution, primary diagnostics, and complete stdout/stderr artifacts |
| `artifact_read` | Range, tail, and pattern-centered reads from retained artifacts; the expanded capability also searches and compares finalized managed-run artifacts |
| `runtime_status` | Pause, relative-path base, and next-action state |
| `runtime_open_manager` | Open the manager app to pause or resume AI operations |

Set `AISHELL_CAPABILITY_SET=expanded-v1` on the MCP server process to opt in to the candidate surface. It exposes nine high-density development tools plus the two recovery controls. The added tools are `run_observe`, `workspace_wait`, `change_impact`, and `apply_change_set`; existing tools gain closed managed-run, artifact query, semantic search, project-profile, and Git branch/worktree modes. Cross-run artifact operations require an explicit project path and reject live, expired, legacy-unbound, or different-project evidence instead of silently falling back to partial logs.

For Codex, register the expanded surface explicitly:

```sh
codex mcp add aishell --env AISHELL_CAPABILITY_SET=expanded-v1 -- aishell-mcp
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
| Scope | macOS access permissions and explicit stop state | Depends on the surrounding shell and host policy |

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

The global package adds `aishell-mcp` and `aishell-open` to `PATH`. `aishell-open` opens the bundled manager app through LaunchServices. The package runs no install script.

Upgrading replaces the app bundle underneath any manager window left open, which breaks that window —
it keeps holding a deleted bundle and silently loses every operation that opens a file panel. The
window detects this itself and says so with a banner. When the new version sits at the same path, the
banner restarts the window into it in one click; otherwise it asks for a quit and a fresh
`aishell-open`. Verified against real `npm install -g` upgrades, not only simulated ones.

```sh
npm install -g @quolu/aishell
aishell-open
```

The current experimental build is not yet Developer ID signed or notarized.

## Build from source

```sh
git clone https://github.com/kitepon/aishell.git
cd aishell
swift test
scripts/package-app.sh release
open build/AIShell.app
```

The MCP executable is bundled at `build/AIShell.app/Contents/Helpers/aishell-mcp`.

フォルダ登録は不要です。絶対パスは指定した場所を、相対パスと省略時はMCP起動ディレクトリを基準にします。Git worktreeも直接指定できます。旧設定の許可フォルダ一覧は無視されます。

## Connect another AI host

For a global npm installation, register the executable name from `PATH` and the expanded development surface:

```sh
codex mcp add aishell --env AISHELL_CAPABILITY_SET=expanded-v1 -- aishell-mcp
claude mcp add --scope user aishell --env AISHELL_CAPABILITY_SET=expanded-v1 -- aishell-mcp
codex mcp get aishell
```

Remove the registration with:

```sh
codex mcp remove aishell
```

Without the expanded capability, the compatibility profile retains all 25 tools. The default seven are the five development tools plus the two recovery controls; full mode adds the remaining legacy primitives. With `expanded-v1`, development exposes 11 tools and full exposes 29:

```sh
AISHELL_TOOL_PROFILE=full /opt/homebrew/bin/aishell-mcp
AISHELL_CAPABILITY_SET=expanded-v1 AISHELL_TOOL_PROFILE=full /opt/homebrew/bin/aishell-mcp
```

The full profile includes file listing and reads, atomic SHA-256-guarded updates, copy/move/rename/Trash, direct process execution, app discovery and launch, runtime status, and manager activation.

## Execution and safety boundaries

- AIShell never evaluates a shell command string. It resolves a development program from `PATH` to an executable URL and keeps arguments, environment, and working directory separate.
- Direct launch of shell and wrapper basenames such as `sh`, `bash`, `zsh`, `env`, and `osascript` is rejected as a product rail, not advertised as a security boundary.
- `run_check` is an open-world capability: an allowed worker may update files, launch child processes, or access the network. AI hosts may require approval before execution.
- npm projects may opt a `build`, `test`, or `lint` check into freshness caching with the closed
  direct-Node `package.json` declaration documented in `docs/adr/0009-project-profile-contract.md`. Ordinary npm
  scripts remain executable but cache-ineligible; AIShell does not infer arguments, inputs, or effects
  from shell script text.
- Text updates may use SHA-256 or expected old text as a precondition. Deletes go to Trash.
- The manager app can stop normal operations globally. Runtime status and manager activation remain available while stopped.

## Current limitations

- The stdio server handles one request at a time.
- MCP cancellation and concurrent run polling are not implemented.
- A timeout terminates the directly owned process tree, but an allowed worker remains capable of open-world side effects before termination.
- Initial workspace entries are a bounded preview; later deltas are cursor-paged.
- Developer ID signing and notarization are not yet configured.

## Operations, updates, and releases

Upgrade a standalone installation through the same official npm path used for
initial installation, then open the newly installed manager:

```sh
npm install -g @quolu/aishell@latest
aishell-open
```

`runtime_status` and `runtime_open_manager` are the recovery entrypoints for an
paused runtime. Factory consumers call `factory_diagnostics`
through the dedicated `AISHELL_TOOL_PROFILE=factory` MCP surface; its schema and
privacy boundary are owned by [the product contract](https://github.com/kitepon/aishell/blob/main/docs/factory-diagnostics.md).

For a release, keep `AIShellProduct.version` and `package.json` aligned, add the
release record under [`docs/archive/releases/`](https://github.com/kitepon/aishell/tree/main/docs/archive/releases), and run:

```sh
npm test
npm run test:package
git fetch origin
npm run verify:release-commit
npm publish --access public
```

The release gate rejects a dirty tree or a commit that has not landed on the
default branch. After publishing, create the matching GitHub Release, reinstall
`@quolu/aishell@latest`, and smoke MCP initialize plus `factory_diagnostics`.
GitHub Releases are the public record of shipped versions.

## Development

```sh
swift test
scripts/package-app.sh release
```

Run `xcodegen generate` to regenerate `AIShell.xcodeproj`. The authoritative implementation lives under `Sources/AIShellCore`, `Sources/AIShellMCP`, and `Sources/AIShellApp`; focused tests live under `Tests/`.

<details>
<summary>Local Xcode verification note</summary>

On the original verification machine, Xcode 26.6 and the installed CoreSimulator build version did not match, so `xcodebuild` stalled before XCBuild began. The same Swift 6.3.3 toolchain passed through SwiftPM. That host issue was not counted as source success.

</details>

## Contributing and security

See [CONTRIBUTING.md](https://github.com/kitepon/aishell/blob/main/CONTRIBUTING.md) before proposing a change. Please report vulnerabilities through the private process in [SECURITY.md](https://github.com/kitepon/aishell/blob/main/SECURITY.md), not through a public issue.

The current documentation map is [`docs/README.md`](https://github.com/kitepon/aishell/blob/main/docs/README.md). Historical
release notes live in [`docs/archive/releases/`](https://github.com/kitepon/aishell/tree/main/docs/archive/releases).

## License

AIShell is licensed under the [Apache License 2.0](LICENSE).
