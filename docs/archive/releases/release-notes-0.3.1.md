# AIShell 0.3.1 release notes

Date: 2026-07-19

AIShell 0.3.1 turns the direct-OS experiment into a stateful macOS runtime for AI development. It replaces the default 0.3.0 catalog with five high-density development tools while retaining the original 20 primitives through the full compatibility profile.

## Added

- Default five-tool development profile: `workspace_snapshot`, `read_context`, `search_context`, `run_check`, and `artifact_read`.
- Workspace journal backed by FSEvents and reconciled against current file identity, metadata, and SHA-256.
- Filesystem-backed evidence store with TTL, quota, SHA-256, complete stdout/stderr retention, and bounded reads.
- Budgeted multi-file context reads and `rg`-backed search context.
- Isolated Codex benchmark runner with deterministic fixtures, usage records, raw events, and task oracles.

## Changed

- The default MCP catalog now exposes the five high-density tools. Set `AISHELL_TOOL_PROFILE=full` for the 25-tool compatibility surface.
- `run_check` accepts an executable name, resolves it through `PATH`, and preserves executable, arguments, environment, working directory, and lifecycle as separate values.
- MCP server and distribution versions are now 0.3.1.

This changes the default tool catalog relative to 0.3.0. Hosts that depend on the original primitives must opt into the full profile.

## Execution boundary clarification

- Direct launch of `sh`, `bash`, `zsh`, `dash`, `ksh`, `csh`, `tcsh`, `fish`, `env`, and `osascript` basenames is rejected to prevent regression into a general command-string wrapper.
- The basename list is a product design rail, not a security boundary. It does not stop renamed binaries or descendants launched by an allowed worker.
- `run_check` remains a destructive, open-world capability. Isolation and safety must not depend on basename rejection.

## Measured result

The final same-binary, same-manifest three-task sentinel solved 9/9 tasks in both arms. Against the native Codex baseline, AIShell used 25.86% fewer tokens per solved task, reduced mean wall time by 32.59%, and reduced p95 wall time by 39.93%.

This is a controlled three-task result using disposable fixtures and an isolated, matched model configuration—not a product-wide performance claim. The noisy compile task showed the clearest causal win; a broader representative suite remains future work.

## Known limits

- Initial workspace entries are a bounded preview; `omittedEntries` reports excluded rows and later deltas are cursor-paged.
- The stdio server processes one request at a time.
- MCP cancellation and concurrent run polling are not implemented.
- `run_check` terminates its directly owned process tree on timeout, but an allowed worker may perform open-world side effects before termination.
- Developer ID signing and notarization are not yet configured.

The npm 0.3.1 package records Git commit `20ef0ce8fb6ef6551e42e64c6240977d7c28339d` as its `gitHead`.
