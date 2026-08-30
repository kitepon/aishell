# Factory diagnostics contract

This is the product-owned source of truth for AIShell diagnostics. Factory
integrators, including dotagents and BugHub, consume this read-only contract;
they do not own AIShell runtime state, schema migration, or readiness decisions.

AIShell exposes the read-only MCP tool `factory_diagnostics` only through the dedicated
`AISHELL_TOOL_PROFILE=factory` profile. This is a factory-reporter surface, not a development
profile: its catalog contains this tool alone. The response schema is fixed at
`aishell.native_factory_diagnostics.v1`.

## Public state

- Product identifier and version
- Supported OS, architecture, minimum OS, and support decision
- Runtime configuration schema, migration status, configuration validity, and operation readiness
- Counts of configured roots, automatic Git worktrees, and effective roots
- MCP stdio transport, protocol version, and catalog-validation readiness
- Manager application bundle readiness
- Typed issue codes

`paused` and `not_configured` are operation-readiness states, not product failures. A runtime
JSON decode failure or invalid root makes product readiness false.

## Privacy

The diagnostic never exposes:

- Allowed-root, Git-worktree, or effective-root paths
- Activity history, operation targets, or messages
- File contents
- Process executable paths, arguments, environment, stdout, or stderr

Interactive work that needs paths uses the existing `runtime_status` tool. Factory reporters and
BugHub ingest `factory_diagnostics` only.

## Version and migration

- Diagnostics schema: `aishell.native_factory_diagnostics.v1`
- Runtime schema: `aishell.runtime_configuration.v2`
- The legacy single `allowedRootPath` remains compatible-on-read as multiple `allowedRootPaths`
- A schema change adds a new version; existing consumers are never silently reinterpreted
