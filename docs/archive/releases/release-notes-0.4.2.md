# AIShell 0.4.2

AIShell 0.4.2 keeps the server responsive when one MCP session drives many concurrent agents,
and makes startup misconfiguration visible to the host instead of silent.

## Changed

- Requests are now dispatched on three lanes instead of one serial queue. A long `run_check` no
  longer blocks unrelated work from the same session.

  | lane | tools | concurrency |
  | --- | --- | --- |
  | recovery | `runtime_status`, `runtime_open_manager`, plus `initialize` / `ping` / `tools/list` | immediate, independent of other lanes |
  | read-only | `read_context`, `search_context`, `artifact_read`, `workspace_snapshot` | parallel |
  | execution | `run_check`, `run_observe`, `apply_change_set`, `workspace_wait`, `change_impact` | serial, unchanged |

  Tools outside the table (`files_*`, `apps_*`, `process_run`, `factory_diagnostics`) stay on the
  execution lane. Concurrency is granted only where it was individually verified.

  `runtime_status` matters most here. It is the recovery control that answers while the runtime is
  paused or unconfigured, so every other tool failing is exactly when it is needed. Queuing it
  behind a 120-second `run_check` made the recovery path unavailable precisely when it had to
  work.

- Startup validation failures are reported on stderr with an `aishell-mcp: ` prefix and exit with
  `78` (`EX_CONFIG`). The `id: null` JSON-RPC error on stdout is retained for compatibility.
  Because that error is not a reply to `initialize`, hosts previously saw only "exited without
  responding" and never received `INVALID_CAPABILITY_SET`, `INVALID_TOOL_PROFILE`, or
  `FACTORY_PROFILE_CAPABILITY_SET_UNSUPPORTED`. Claude Code 2.1.219 and later display the error
  body from `claude mcp list` and `/mcp`, so this text now reaches the operator.

## Fixed

- Concurrent responses can no longer interleave on stdout. `MCPResponseWriter` is an actor, but
  its sink is a `nonisolated` `@Sendable async` closure, so `await sink(...)` released the actor
  and allowed a second response to enter. That was harmless while requests were serialized and
  became a corruption risk once lanes ran in parallel: any response line above `PIPE_BUF` could be
  split by another write. Measured before the fix, twelve concurrent 4 KiB responses produced
  eight JSON parse failures. Sink invocation is now serialized independently of actor isolation.

## Internal

- `MCPServer` no longer carries unsynchronized mutable state. Its stored properties are all
  immutable, and lazily created services moved to a dedicated actor that coalesces concurrent
  requests for the same workspace root onto a single instance. The class now satisfies `Sendable`
  under compiler checking rather than an `@unchecked` assertion, so its thread-safety no longer
  depends on the scheduler happening to be serial.

## Compatibility

No public surface changes. Existing scheduler contracts are preserved: duplicate request ids are
still rejected across lanes, `notifications/cancelled` still cancels an in-flight or queued
request, and shutdown still drains every lane. The tool catalog is unchanged: 7 tools by default,
11 with `AISHELL_CAPABILITY_SET=expanded-v1`, 25 with `AISHELL_TOOL_PROFILE=full` or `legacy`, and
1 with `AISHELL_TOOL_PROFILE=factory`.

Responses may now arrive out of submission order. JSON-RPC matches replies by `id`, so compliant
hosts are unaffected.

## Why this shipped now

Claude Code 2.1.219 raised the default nested subagent spawn depth from 1 to 3. One session can
now fan out into many concurrent agents, and all of them funnel into a single stdio process. The
serial scheduler was not only a latency cost under that load — it was also what made the server's
`@unchecked Sendable` claim true. Splitting lanes therefore required consolidating that state
first, so the safety argument moved from "nothing runs concurrently" to a property the compiler
checks. See `docs/adr/0028-claude-code-2-1-219-host-alignment.md`.
