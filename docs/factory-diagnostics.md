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
- 旧root件数の3フィールドは診断schema互換のため0を返す。登録機能や範囲制限はない。
- MCP stdio transport, protocol version, and catalog-validation readiness
- Manager application bundle readiness
- Typed issue codes

`paused`は操作停止を表す。設定ファイルがなくても`ready`になり、旧設定のフォルダが存在しなくても利用できる。JSONの読み取り失敗は製品の準備失敗として返す。

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
- Runtime schema: `aishell.runtime_configuration.v3`
- 旧`allowedRootPath`・`allowedRootPaths`は読み取り時に無視し、保存時に除去する。停止状態と更新日時は引き継ぐ。
- A schema change adds a new version; existing consumers are never silently reinterpreted
