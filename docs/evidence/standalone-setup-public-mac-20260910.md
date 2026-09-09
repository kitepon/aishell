# 公開版のMac実機受入

2026-09-10、公開npm版を実利用のMacへ導入した。オーナーの最新指示
「Macはこの端末だからSSHじゃなくて普通にやりな」により、SSH条件をこのMacの通常導入へ変更した。
Aitermの永続PTYで公式npm導入から製品setup・診断まで実行した。

## 公開物

- npm: `@quolu/aishell@0.6.0`。registryの`latest`も同版。
- 公開commit: `03c7ba33e074016e9ca752fa6beacbad43dae50b`。公開前に`origin/main`の祖先であることを確認。
- tarball SHA-1: `427843d3242d9120e317557069d84ed21c7c6dd7`。registryと公開処理の結果が一致。
- [GitHub Release](https://github.com/kitepon/aishell/releases/tag/v0.6.0)。同commitを対象として公開。

## 受入表

実機はmacOS 26.6.1、Apple Silicon arm64。実行時に他製品のsetup・MCP登録commandが
動作中でないことをprocess一覧で確認した。共有設定は製品のバックアップ・変更検出・読戻しを通して更新した。

| 工程 | 実測結果 |
|---|---|
| `npm install -g @quolu/aishell@latest && aishell-setup` | exit 0、`status: ready` |
| 管理アプリ | 導入済みbundleから起動。初回PID 15828、再実行後PID 18080 |
| `aishell-setup`再実行 | exit 0、4AIすべて`registration: unchanged` |
| `aishell-setup --check` | exit 0、4AIすべて`registration: verified` |
| 公開版の導入確認 | `npm list -g`が0.6.0を返し、管理アプリの実行pathも公式npm導入先と一致 |
| 工場専用profile | toolは`factory_diagnostics`の1件だけ |
| `factory_diagnostics`実操作 | version 0.6.0、`ready: true`、`issues: []` |

| AI | 初回登録 | 公式CLI確認 | MCP実操作 |
|---|---|---|---|
| Claude Code | unchanged | 成功 | 0.6.0、11 tools、`workspace_snapshot`成功 |
| Codex | updated | 成功 | 0.6.0、11 tools、`workspace_snapshot`成功 |
| Grok Build | updated | 成功 | 0.6.0、11 tools、`workspace_snapshot`成功 |
| Cursor | updated | 成功 | 0.6.0、11 tools、`workspace_snapshot`成功 |

MCP実操作は、各AI設定のbare command・args・envを読戻して起動し、protocol、能力、停止状態と、
一時folderの実fileを確認した。再実行・診断でも4AIの`hostVerified`と`ready`はすべてtrue。
工場診断は専用profileから呼び、対話用capability envを設定しなかった。
runtimeは`valid`、`compatible_on_read`、`operationReadiness: ready`、`isPaused: false`。
managerとMCPもreadyだった。

## 境界と検証の限界

初回・更新・旧登録・設定保持・非対応・失敗のfocused試験と別ベンダー反証は
[実装証跡](standalone-setup-20260910.json)と[ADR 0031](../adr/0031-standalone-setup.md)に保持する。
[製品CI](https://github.com/kitepon/aishell/actions/runs/34376576245)、
[同一実装の追加CI](https://github.com/kitepon/aishell/actions/runs/34376576671)、
[公開commitの文書CI](https://github.com/kitepon/aishell/actions/runs/34377342770)は成功。
ローカル全体試験で出た異なる2件の失敗は原因未確定の履歴として残し、CI成功で取り消さない。

Windows/Linuxへの導入、Intel Mac、macOS 15そのものの実機試験は実施していない。
非対応条件の拒否はfocused fixtureで確認済み。今回の実機受入はこのMacの4AIを対象とする。
dotagentsと他製品repoは変更していない。

公開版の実機受入が成立したため、工場はAIShell管理アプリの準備と4AIへのAIShell登録代行を外し、
公式npm導入後に`aishell-setup`を呼べる。Windows/LinuxにあるAIShell登録の撤去は工場担当の範囲。
