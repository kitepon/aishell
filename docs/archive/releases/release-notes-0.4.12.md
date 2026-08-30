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

## Release gate

- Keep `AIShellProduct.version`, `package.json`, and the application bundle version aligned.
- Require the Swift suite, repository-contract test, packaged application, npm payload verification,
  GitHub Release, fresh global install, MCP initialize, and `factory_diagnostics` smoke before marking
  this version published.

## Compatibility

Runtime behavior, MCP tool names, schemas, profile selection, and stored state are unchanged from
0.4.11.
