# AIShell 0.4.5

AIShell 0.4.5 removes the install script that 0.4.4 added, because npm never runs it.

## Removed

- The `postinstall` check introduced in 0.4.4 is gone. It was meant to warn, at install time, that a
  manager window was still running from the install being replaced. It never ran.

  npm blocks install scripts by default. Measured on npm 11.17.0 with `allow-scripts` unset in both
  user and project config — the default — installing this package globally printed only:

  ```
  npm warn allow-scripts 1 package has install scripts not yet covered by allowScripts:
  npm warn allow-scripts   @quolu/aishell@0.4.4 (postinstall: node scripts/check-running-instances.mjs)
  ```

  The published guidance said dependency lifecycle scripts become opt-in with npm 12; in practice
  11.17.0 already blocks the scripts of a package installed globally on its own. So the warning stayed
  permanently silent by default, while the `allow-scripts` notice appeared on every install of the
  package — all cost, no benefit. The package declares no `preinstall`, `install`, or `postinstall` again, and
  `scripts/verify-npm-package.mjs` now asserts their absence so this cannot come back unnoticed.

  Nothing about the detection is lost. The window itself compares its executable identity against the
  one captured at launch and shows the banner — that was always the reliable net, and it is untouched.

## Compatibility

No public surface changes. The tool catalog, schemas, and output shapes are unchanged: 7 tools by
default, 11 with `AISHELL_CAPABILITY_SET=expanded-v1`, 25 with `AISHELL_TOOL_PROFILE=full` or
`legacy`, and 1 with `AISHELL_TOOL_PROFILE=factory`.

Installing 0.4.5 no longer prints the `allow-scripts` warning. If you added
`allow-scripts=@quolu/aishell` to your npm config for 0.4.4, it is no longer needed.
