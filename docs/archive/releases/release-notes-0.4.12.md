# AIShell 0.4.12

AIShell 0.4.12 aligns the public package and repository surface with the canonical
`kitepon/aishell` project and closes the completed capability-expansion document.

## Changed

- npm repository, issue, homepage, README clone, CI badge, and private security-report links now use
  `github.com/kitepon/aishell`.
- The completed development-efficiency plan moved to `docs/archive/`; its current north star and
  architectural boundaries live once in `AGENTS.md`.
- The tool catalog documentation now distinguishes baseline full (25 tools) from
  `expanded-v1` full (29 tools), matching the executable catalog tests.
- CI calls a product-owned reusable workflow and rejects a return to an external mutable factory
  workflow.
- The documentation gate installs its own development parser and checks CommonMark/GFM reference
  links and HTML assets, including `srcset`, inside both the repository and the npm tarball.
- Main-branch product CI now runs to completion even when a later push arrives; only superseded pull
  request runs are cancelled.
- The Linux documentation job overrides the package's macOS arm64 platform restriction only for a
  script-disabled development-dependency install.
- README hero images use an absolute public URL, so the npm page no longer points outside the
  published tarball.

## Release gate

- Keep `AIShellProduct.version`, `package.json`, and the application bundle version aligned.
- Require the Swift suite, repository-contract test, packaged application, npm payload verification,
  GitHub Release, fresh global install, MCP initialize, and `factory_diagnostics` smoke before marking
  this version published.

## Compatibility

Runtime behavior, MCP tool names, schemas, profile selection, and stored state are unchanged from
0.4.11.
