# AIShell 0.4.11

AIShell 0.4.11 lets `search_context` use one existing regular file as its search scope.

## Fixed

- `search_context(path: ...)` previously accepted only directories, while its public schema called the field a
  search root and did not expose that restriction. A fresh managed Claude therefore selected the valid tracked
  `README.md` file and received `INVALID_PATH` instead of search results.
- Lexical fixed-string and regex queries now pass a file directly to the `rg` worker while using its parent as the
  worker's current directory. They do not widen the search to sibling files.
- Glob queries use the attested workspace index as before, but a file scope admits only that exact indexed file.
- The public tool schema and README now state that the scope may be a directory or one regular file.
- `ApplyChangeSetService` now constrains operation-gate results to `Sendable`, preserving the existing serialized
  execution contract while restoring compilation with the release CI's Swift 6.1 strict-concurrency checker.

## Verification

- Focused core coverage fixes both lexical and glob file scopes and proves that a sibling file is not returned.
- The MCP wire fixture covers the legacy single-`query` request used by Claude and proves that it does not widen
  a file scope to a sibling containing the same text.
- Full Swift regression passed 567/567; the release-gate fixture passed 1/1 and the release app packaged successfully.
- Release CI run `30874932377` passed on commit `eb7e36ff6ae3` with Swift 6.1.2, including the full Swift test,
  application package, and npm payload gates.
- The published `@quolu/aishell@0.4.11` is npm `latest` with git head `eb7e36ff6ae3`, integrity
  `sha512-1O9H6NigRo+eRRMVDT7aWBp19TSQQ2EAmXgylu9wFe59Ry9iIc+3hFgXQWx6laL/hqSKzCofEV1UL0VVrBaJTg==`, and
  shasum `44ef71f8354bd633624d3c56b3f3b91ce7330193`.
- The globally installed package and application bundle both report `0.4.11`; the manager restarted from that
  bundle successfully.
- A fresh Aiterm 0.21.4-managed Claude session discovered all 11 AIShell tools and called the installed MCP
  directly without shell fallback. `runtime_status` succeeded, and `search_context(query: "AIShell", path:
  "README.md", byte_budget: 1200)` succeeded with 7 returned matches and 1,132 bytes. The smoke session was
  closed and left no matching temporary state.

## Compatibility

Directory-scoped searches, ranking defaults, cursors, result shapes, and all tool names remain unchanged from 0.4.10.
