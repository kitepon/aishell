# AIShell 0.4.9

AIShell 0.4.9 fixes the shortest lexical search path and aligns interactive host setup with the expanded development surface.

## Fixed

- `search_context` no longer chooses `changed` ranking when both `ranking` and `changed_since_cursor` are omitted. Cursor-free requests now default to test-path prioritization; cursor-bound requests retain changed-then-test prioritization.
- Explicit `changed` ranking without `changed_since_cursor` still fails with `INVALID_ARGUMENT`.
- The SourceKit-LSP worker closes parent-owned unused pipe ends after launch. A timed-out or exited child can now deliver EOF instead of leaving the request task blocked indefinitely, and cleanup no longer performs a redundant synchronous exit wait that could deadlock after termination was already observed.

## Integration

- The documented Claude and Codex registration uses the bare `aishell-mcp` command with `AISHELL_CAPABILITY_SET=expanded-v1`.
- The cross-project adoption audit records the repaired allowed-root, host-registration, schema, and routing boundaries without treating narrow one-shot shell work as an AIShell target.

## Compatibility

Tool names, request fields, result fields, tool counts, and profile names are unchanged. Only the omitted-ranking default changes for lexical search requests that do not provide a workspace cursor.
