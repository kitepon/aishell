# AIShell 0.3.0 release notes

Date: 2026-07-19

AIShell 0.3.0 adds a privacy-bounded native diagnostics surface for factory and installation checks.

## Added

- Read-only MCP tool `factory_diagnostics`.
- Versioned `aishell.native_factory_diagnostics.v1` result covering platform, MCP, runtime store, manager readiness, and pause state.
- Diagnostics that deliberately omit allowed-root paths, file contents, operation history, and process arguments.

## Fixed

- `process_run` now closes child-process stdin explicitly so stdin readers such as `codex exec` receive EOF.

## Compatibility

- macOS 15 or later.
- Apple Silicon (`arm64`).
- The full MCP catalog contains 21 tools in this release.

## Verification

- Swift tests: 20/20.
- Release package consistency check.
- Live MCP 21-tool handshake.
- A real Codex session called candidate `factory_diagnostics` once and confirmed schema v1, ready state, zero reported issues, and no private path or operation disclosure.

This note describes the published npm 0.3.0 package and existing `v0.3.0` tag. The later five-tool development runtime first shipped publicly in 0.3.1.
