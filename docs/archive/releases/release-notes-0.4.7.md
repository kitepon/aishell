# AIShell 0.4.7

AIShell 0.4.7 hardens the release gate so every published package is reproducible from the
landed commit.

## Fixed

- `verify-release-commit` now rejects untracked files in addition to tracked modifications.
  npm builds its payload from the working tree, so an untracked file could previously enter a
  published package without belonging to the verified commit.
- The gate is exposed as a testable function and covered with a real temporary Git repository.
  The regression test proves that a clean landed commit passes and an untracked payload fails.

## Compatibility

No MCP surface or runtime behavior changes. The tool catalog, schemas, and output shapes are
unchanged. Only the product version and release-safety gate differ from 0.4.6.
