# Factory diagnostics contract

This is the product-owned source of truth for AIShell diagnostics. Factory
integrators, including dotagents and BugHub, consume this read-only contract;
they do not own AIShell runtime state, schema migration, or readiness decisions.

AIShell exposes the read-only MCP tool `factory_diagnostics` only through the dedicated
`AISHELL_TOOL_PROFILE=factory` profile. This is a factory-reporter surface, not a development
profile: its catalog contains this tool alone. The response schema is fixed at
`aishell.native_factory_diagnostics.v1`.

`factory`起動時は`AISHELL_CAPABILITY_SET`を設定しない。対話用の`expanded-v1`との併用は`FACTORY_PROFILE_CAPABILITY_SET_UNSUPPORTED`で起動失敗する。

## Public state

- Product identifier and version
- Supported OS, architecture, minimum OS, and support decision
- Runtime configuration schema, migration status, configuration validity, and operation readiness
- 旧root件数の3フィールドは診断schema互換のため0を返す。登録機能や範囲制限はない。
- MCP stdio transport, protocol version, and catalog-validation readiness
- 管理UIの状態は`not_required`、互換用の`manager.ready`はtrueを返す。
- Typed issue codes

管理UIと停止設定は廃止した。`configurationState`と`migrationStatus`は`not_required`、`isPaused`はfalseを返す。旧JSONは操作と診断の条件にしない。

## Privacy

The diagnostic never exposes:

- workspace、Git worktree、MCP起動ディレクトリのパス
- Activity history, operation targets, or messages
- File contents
- Process executable paths, arguments, environment, stdout, or stderr

Interactive work that needs paths uses the existing `runtime_status` tool. Factory reporters and
BugHub ingest `factory_diagnostics` only.

## Version and migration

- Diagnostics schema: `aishell.native_factory_diagnostics.v1`
- Runtime schema: `aishell.runtime_configuration.v3`
- 旧runtime設定は保持するが読み込まない。
- A schema change adds a new version; existing consumers are never silently reinterpreted
