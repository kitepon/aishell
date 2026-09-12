# GitHub Actions macOS CI selection

- 取得日: 2026-07-19、2026-09-12追記
- 確度: 高
- 一次資料: [[raw/github-hosted-runners-2026-07-19]], [[raw/github-macos-15-runner-image-2026-07-19]], [[raw/github-actions-checkout-2026-07-19]]

## 初回CI選定の履歴

以下は初回CIを選んだ時の記録。現役の通常CIは[製品workflow](../.github/workflows/ci.yml)が所有する。

AIShellの公開CIは`macos-15`を明示する。GitHub公式の標準runner一覧では、公開repository向け`macos-15`はM1 arm64、3 CPU、7 GB RAM、14 GB SSDとして提供される。Apple Silicon Macを対象とするAIShellの配布条件と一致し、Intel runnerで代替する理由がない。

2026-07-19取得時点のrunner-images資料ではmacOS 15 imageにXcode 26.3系が含まれる。runner imageは更新されるため、workflowは特定patchへ依存せず、ログへ`swift --version`と`xcodebuild -version`を出して実効toolchainを証拠化する。

## Workflow方針

- `pull_request`と`main`への`push`で実行する。
- repository checkoutは取得時点の公式READMEが案内する`actions/checkout@v6`を使う。
- `swift test`と`npm pack --dry-run`を通常gateにする。
- `scripts/package-app.sh release`も実行し、配布appの組立失敗を検出する。
- `macos-15` imageには`rg`が入っていない実測runがあるため、test前にHomebrewでripgrepを明示導入し、versionをログへ残す。
- code signing、notarization、npm publish、GitHub Release作成はcredentialと外部変異を伴うためCIへ混ぜない。
- `macos-latest`は指すOSが将来変わるため使わない。

## 留意点

GitHubは`-latest`をvendorの最新OSと同義にしていない。またrunner image内のXcode patchは置換される。特定toolchainが必須になった場合は、利用可能なXcode pathを一次資料とjob logで再確認してから`DEVELOPER_DIR`を固定する。

初回公開run `29688176713`では42 test中、実`rg` workerを使う2 testだけが`workerUnavailable("rg")`で失敗した。このため、runner imageの暗黙tool inventoryへ依存せずworkflowが必要workerを所有する。

## npm公開専用job（2026-09-12）

- [npm公開workflow](../.github/workflows/publish.yml)はGitHub管理の`macos-15` arm64で動かす。Trusted Publishingがself-hosted runnerに対応していないため、公開jobをこの環境へ置いた。
- [GitHub公式runner仕様](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)と[macOS 15 image](https://raw.githubusercontent.com/actions/runner-images/main/images/macos/macos-15-arm64-Readme.md)を再確認した（[[raw/github-macos-publish-20260912]]）。image既定のXcodeと公開用toolchainを混同せず、workflowでXcode 26.3を指定した。
- [setup-node公式資料](https://github.com/actions/setup-node)に従い、Node.js 24とnpm cache無効を指定した。標準imageのnpm 10はOIDC公開の必要版を満たさないため、そのまま使わない。
- [初回公開run](https://github.com/kitepon/aishell/actions/runs/34692592310)で、配布物検査とnpm公開が成功した。通常CIの実行環境は変更していない。
