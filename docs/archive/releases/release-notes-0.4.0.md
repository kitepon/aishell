# AIShell 0.4.0

AIShell 0.4.0 restores the factory diagnostics surface on `main` as a dedicated, opt-in tool
profile. The default development catalog is unchanged.

## Added

- `AISHELL_TOOL_PROFILE=factory` exposes exactly one read-only tool, `factory_diagnostics`,
  and nothing else. It reports product identity and version, platform support, runtime
  configuration schema and migration state, operation readiness, MCP readiness, and manager
  bundle readiness under the frozen schema `aishell.native_factory_diagnostics.v1`.
- Allowed roots, automatic Git worktrees, and effective roots are reported as **counts only**.
  The response carries no paths, no activity history, no file contents, and no process
  arguments, and it declares those four privacy properties explicitly.

## Changed

- `mcp.ready` is derived from startup catalog validation instead of being a hard-coded `true`.
- `AIShellProduct.version` is now the single source of truth for the product version. The MCP
  `serverInfo.version` reads that constant, and `scripts/verify-npm-package.mjs` fails when
  `package.json` and the Swift constant disagree.

## Compatibility

The tool catalog is unchanged for every existing entry point: 7 tools by default, 11 with
`AISHELL_CAPABILITY_SET=expanded-v1`, and 25 with `AISHELL_TOOL_PROFILE=full` or `legacy`.
`factory_diagnostics` appears in none of them and cannot be called from them, because
`tools/call` rejects any tool outside the listed catalog for the running profile.

`AISHELL_TOOL_PROFILE=factory` combined with `AISHELL_CAPABILITY_SET` fails startup with
`FACTORY_PROFILE_CAPABILITY_SET_UNSUPPORTED`. It never falls back to another profile.

## Why a new profile instead of the default catalog

The 0.3.0 package shipped `factory_diagnostics` in the default catalog from a branch that was
never an ancestor of `main`, so the surface disappeared when 0.3.1 redesigned the catalog and
shipped from `main`. Re-landing it in the default catalog would put an operations tool in front
of every model turn, which conflicts with keeping the catalog focused on tools that reduce
tokens per solved task. A dedicated profile keeps the diagnostics available to a factory
reporter at zero cost to development sessions.
