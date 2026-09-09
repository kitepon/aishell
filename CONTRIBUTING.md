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

導入・AI登録の変更は`npm run test:setup`、native準備処理の変更は`NativeApplicationServiceTests`を先に確認する。公開時は`npm test`と`npm run test:package`を通し、公開npm版を対応Macへ公式導入して`aishell-setup`の実操作まで確認する。製品単体の導入契約は[docs/setup.md](docs/setup.md)を参照する。

Use `xcodegen generate` only when the Xcode project needs regeneration. Do not commit derived build output.

## Pull request checklist

- Explain the user-visible or protocol-visible change.
- Identify the affected path resolution, workspace identity, file identity, process lifecycle, artifact, or freshness contract.
- Include focused test results and any relevant package-app verification.
- Update README, release notes, schemas, and fixtures when public behavior changes.
- Do not claim token or wall-time improvements without an isolated baseline using the same model, reasoning, fixture, prompt, and sandbox.

Small, focused pull requests are easier to verify and review.
