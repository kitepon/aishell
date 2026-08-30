# AIShell 0.4.6

AIShell 0.4.6 carries no functional change. It records what the 0.4.4 detection actually does on a
real upgrade, now that it has been through one.

## Verified

- The stale-window banner and its one-click restart were exercised against real
  `npm install -g @quolu/aishell` upgrades, not only against simulated bundle replacement. Installing
  over a running window raised the banner, and the restart button ended the old process and brought up
  a new one from the replaced bundle — twice, at 19:46:03 and 19:53:59 during the 0.4.5 rollout.

- A process outlives the replacement of its own executable. The binary's inode changed underneath a
  running window (48308211 → 48308499) and the process was still there three seconds later. macOS does
  not kill an app whose bundle was swapped, so **a broken window staying open is the default outcome**,
  not an edge case. That is what makes the in-app detection the whole net rather than a nicety.

## Documentation

- `README` (en/ja) now describes what the banner offers in each state: restart in place when the new
  version sits at the same path, quit and reopen when the path is gone.
- The research note behind the fix records the real-install measurements above, plus two verification
  traps: the first click on an inactive window is spent activating it, and re-installing a package to
  observe the stale-window state creates a fresh instance of that state — which is a good way to
  misread a restart that in fact worked.

## Compatibility

No public surface changes. The tool catalog, schemas, and output shapes are unchanged: 7 tools by
default, 11 with `AISHELL_CAPABILITY_SET=expanded-v1`, 25 with `AISHELL_TOOL_PROFILE=full` or
`legacy`, and 1 with `AISHELL_TOOL_PROFILE=factory`. The app binary differs from 0.4.5 only by its
version string.
