# AIShell 0.3.3

AIShell 0.3.3 restores the recovery path of the default MCP profile.

## Fixed

- The default profile now exposes `runtime_status` and `runtime_open_manager` alongside the five development tools. Errors for missing configuration, paused operation, and paths outside allowed roots no longer point to a tool hidden from the same profile.
- Both recovery controls publish structured output schemas. The full compatibility profile remains 25 tools.

## Upgrade

```sh
npm install -g @quolu/aishell@0.3.3
```

Start a new AI task after upgrading so the host refreshes its MCP tool catalog.
