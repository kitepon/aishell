# AIShell 0.3.4

AIShell 0.3.4 ships the expanded development surface as an explicit opt-in while preserving the
0.3.3 default and full compatibility profiles.

## Added

- `AISHELL_CAPABILITY_SET=expanded-v1` exposes nine high-density development tools plus two
  recovery controls. `run_observe`, `workspace_wait`, `change_impact`, and `apply_change_set`
  join the existing surface.
- Managed-run observation, retained-artifact query and comparison, semantic context,
  project-profile/focused-check selection, and Git branch/worktree comparison are available
  through closed schemas.
- Expanded development exposes 11 tools; expanded full exposes 29. Existing profiles remain
  default 7 and full 25.

## Correctness

- Candidate tools use MCP `2025-11-25` structured results with top-level object output schemas.
- Workspace, run, cache, cursor, artifact, and change-set freshness failures stay typed instead
  of silently rescanning or switching backends.
- Unknown or empty capability-set and tool-profile values stop startup with typed errors instead
  of silently selecting another profile.

## Upgrade

```sh
npm install -g @quolu/aishell@0.3.4
codex mcp add aishell --env AISHELL_CAPABILITY_SET=expanded-v1 -- /opt/homebrew/bin/aishell-mcp
```

Start a new AI task after upgrading so the host refreshes the MCP tool catalog.
