# Contributing to AIShell

Thanks for helping improve AIShell. Changes should advance its core purpose: own live macOS state below the model so AI development tasks need less rescanning, rereading, and repeated execution without weakening correctness.

## Before opening a pull request

1. Open an issue for changes that add a public tool, alter an MCP result, change path resolution or workspace boundaries, or expand process capabilities.
2. Keep domain behavior in `Sources/AIShellCore` and protocol translation in `Sources/AIShellMCP`.
3. Do not introduce shell-string evaluation. Keep executable, arguments, environment, and working directory separate.
4. Add or update focused tests for the contract being changed.

## Development setup

AIShell requires an Apple Silicon Mac running macOS 15 or later.

```sh
swift test
scripts/package-app.sh release
```

文書だけの変更ではSwift testを実行せず、`npm run test:repository-contract`と差分確認でリンク・配布文書の整合を検証する。

Use `xcodegen generate` only when the Xcode project needs regeneration. Do not commit derived build output.

## Pull request checklist

- Explain the user-visible or protocol-visible change.
- Identify the affected path resolution, workspace identity, file identity, process lifecycle, artifact, or freshness contract.
- Include focused test results and any relevant package-app verification.
- Update README, release notes, schemas, and fixtures when public behavior changes.
- Do not claim token or wall-time improvements without an isolated baseline using the same model, reasoning, fixture, prompt, and sandbox.

Small, focused pull requests are easier to verify and review.
