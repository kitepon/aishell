# AIShell 0.4.4

> Correction: the `npm install` warning described below never runs. npm blocks install scripts by
> default — measured on npm 11.17.0, including a package installed globally on its own. 0.4.5 removes
> the script. The in-app detection below is unaffected and is the whole net.

AIShell 0.4.4 makes an upgrade visible to the window that the upgrade broke.

## Fixed

- A window left open across an install no longer fails silently. `npm install -g @quolu/aishell`
  renames the existing package to `@quolu/.aishell-XXXX` before deleting it, so a running window
  keeps holding an executable that no longer exists at its path. That window still draws, still
  accepts clicks, and still writes `runtime.json` — but every API that needs a resolvable bundle
  stops working. Pressing **rootを追加** opened no file panel and reported no error, which reads as
  "the button is dead" rather than "restart the app".

  The app now compares its executable's identity — device, inode, size, and modification time —
  against the identity captured at launch, and reports one of three states: intact, replaced at the
  same path, or removed. Path existence alone is not enough: an in-place replacement keeps the path
  and swaps the file underneath.

  When the executable was replaced or removed, a banner appears above the header naming the state,
  saying which operations are affected, and offering the way out. A replaced install can be
  restarted in place from the banner; a removed one cannot be relaunched from its own path, so the
  banner asks for a quit and a fresh `aishell-open`. A restart that fails to launch the new version
  keeps the failure on the banner and on stderr instead of letting it be cleared by the next refresh.

- `npm install` now warns when it replaces an install that a running window still holds. The
  postinstall check lists the affected pids and asks for the window to be reopened. Windows running
  from a live install path are left alone, so a local `npm install` does not produce a spurious
  warning. The check never fails the install.

## Changed

- The manager window now splits the area below the header between settings and activity history at a
  boundary you can drag. Previously the settings pane grew with the number of allowed roots and pushed
  the history off the bottom of the window — with a dozen roots the history was gone. The split starts
  at half and half, roots that no longer fit scroll inside their own pane, and adding a root never
  moves the boundary. Drag the grip to rebalance; the position is remembered across launches as a
  fraction of the window height, so resizing the window keeps the same proportions. Double-click the
  grip to return to half and half.

## Compatibility

No public surface changes. The tool catalog, schemas, and output shapes are unchanged: 7 tools by
default, 11 with `AISHELL_CAPABILITY_SET=expanded-v1`, 25 with `AISHELL_TOOL_PROFILE=full` or
`legacy`, and 1 with `AISHELL_TOOL_PROFILE=factory`.

The detection is observational only. It never blocks an operation, never quits on its own, and never
alters `runtime.json`. A window whose install is untouched behaves exactly as before.

## How this was found

A 0.4.3 install landed while a 0.4.2 window from three days earlier was still open. Adding a root
from that window did nothing at all — no panel, no error. `lsof` showed the process executing from
`@quolu/.aishell-N2ismJiF/dist/AIShell.app`, a directory the upgrade had already deleted, and
`runtime.json` had not been written since the window was launched. Quitting and relaunching from the
current install path fixed it immediately, which confirmed the diagnosis and showed the failure mode
was entirely invisible from inside the app.
