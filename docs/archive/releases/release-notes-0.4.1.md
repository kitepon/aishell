# AIShell 0.4.1

AIShell 0.4.1 fixes manager bundle resolution when the MCP server is launched by bare command
name, which is how MCP hosts and the factory reporter start it.

## Fixed

- `AIShell.app` is now located from the loaded executable path rather than `argv[0]`. When a
  host spawns `aishell-mcp` without a directory component, `argv[0]` carries no path, so the
  previous lookup resolved against the working directory and failed to find the bundle. That
  made `factory_diagnostics` report `manager.application_bundle_unavailable` and `ready: false`,
  and it made `runtime_open_manager` fail the same way, on an otherwise healthy installation.

## Added

- `scripts/verify-npm-package.mjs` now launches the packaged binary through a bare command name
  on `PATH` and asserts that `factory_diagnostics` resolves the manager bundle, keeps every
  privacy property false, and emits no absolute paths. The release gate fails if bundle
  resolution regresses.

## Compatibility

No public surface changes. The tool catalog is unchanged: 7 tools by default, 11 with
`AISHELL_CAPABILITY_SET=expanded-v1`, 25 with `AISHELL_TOOL_PROFILE=full` or `legacy`, and
1 with `AISHELL_TOOL_PROFILE=factory`.

## Why this shipped broken in 0.4.0

The defect predates 0.4.0 — `runtime_open_manager` used the same lookup — but no surface
reported it, so an installation that could not open its own manager still looked healthy. Adding
factory diagnostics made the condition observable, and the post-publish smoke of 0.4.0 caught it
on the first bare-name launch. The release gate now covers the launch form that hosts actually
use, rather than only the fully-qualified path used during local packaging.
