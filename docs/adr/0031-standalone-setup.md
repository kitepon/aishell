# ADR 0031: 製品単体の明示setup

日付: 2026-09-10。判断: 採用。対象: AIShellの導入・設定・診断の所有境界。
この判断は実装契約を受け入れる。公開npm版のSSH導入受入は[工程](../archive/standalone-setup-plan.md)で別に追跡する。

## 決定

対応Macで`aishell-setup`を一回呼び、管理アプリ準備、AI登録、読戻し、公式AI CLIの確認、
MCPの実操作まで実行する。全対象が成功した場合だけ`ready`を返す。
現行の操作契約は[setup.md](../setup.md)だけを正とする。

症状は、npm導入後の管理アプリ準備とMacのMCP登録を工場が代行していたこと。
状態の所有者はAIShellであり、製品単体でinstall/config/update/diagnosticsを所有する既存契約に従う。
dotagentsは製品横断の呼出しと互換projectionを所有し、本変更では編集しない。

- npm install lifecycleは追加しない。管理アプリを開くのは明示setupだけ。LaunchAgentやlogin itemは作らない。
- 設定処理はNodeの共通部分とAI別adapter、Macの起動完了は既存native serviceへ置く。
- bare commandとexpanded能力を維持する。利用者のenvと他設定を保持し、変更前にtarを保存する。
- 対応外OS/CPUでは設定と常駐processを作らない。別OS版や汎用shellは追加しない。
- 別project・組織設定・AI本体の承認を黙って書き換えず、実効確認に失敗したら工程付きerrorを返す。

## 別ベンダーの反証と裁定

xAI Grok 4.6をAitermのread-only sessionで起動した。
監査sessionは`e9800350-b6ea-4f9e-8761-67579babf217`、最終回答は2026-09-09T15:57:28.570Z。
公開契約・設定保持を反証し、親が実コードと隔離実測に基づいて裁定した。

| 指摘 | 親の裁定と根拠 |
|---|---|
| Grokの`disabled_mcp_servers`が残る | 採用。公式CLIで無効状態を再現し、`aishell`だけ除去する修正とfocused testを追加した。 |
| Cursor未選択でも不正な`CURSOR_HOME`が他AIを妨げる | 採用。検出後に対象Cursorだけを検証し、他AI単独の試験を追加した。 |
| 管理アプリ準備がhelperを自己終了する | 棄却。返却PIDは実際のGUIで、自己終了は再現しなかった。 |
| Grokの同名user/projectが2件返る | 棄却。公式1.0.13の隔離実測は実効project登録1件だけを返した。userだけを見る変更は実効確認を弱めるため採らない。 |
| 直接MCP確認だけでAI本体の登録成功を判定する | 公式CLIの実効読戻しを追加。4AIで初回・再実行・診断を通した。 |
| Cursor初回承認 | 公式`agent mcp enable`を使用し、CLI設定とproject承認fileを事前保存する。HOMEを隔離した実CLIで11 toolの取得を確認した。 |

親が別に再現した管理アプリの競合も反証対象へ追加した。LaunchServicesの返却PIDを直後に再検索すると
`nil`になるが、そのPIDのGUIは生存していた。起動が返した`NSRunningApplication`自身の
`isFinishedLaunching`を観測し、終了とbundle一致を確認するよう修正した。
修正後はhelperの12回連続再実行が成功した。監査の最終判定は「残る実証可能な欠陥はない」。

最終検証中、bare起動したMCPの非同期`run_check`が同梱supervisorをcwdから探す既存欠陥も再現した。
原因は`CommandLine.arguments[0]`を絶対パスとみなしたことだった。
`Bundle.main.executableURL`から兄弟helperを解決し、配布packageのbare起動から
`run_check`→`run_observe`が`passed`になる回帰確認を配布gateへ追加した。
これは既存の起動場所解決の修正で、process所有境界は変更しない。

## 検証の区別

開発Mac（macOS 26.6.1/arm64）で、Claude Code 2.1.259、Codex 0.150.1、Grok Build 1.0.13、
Cursor CLI 2026.09.02-c22c1a3の隔離設定を使用した。各AIの公式CLI確認と
`initialize`・`tools/list`・`runtime_status`・一時fileの`workspace_snapshot`が成功した。
再実行は登録`unchanged`、診断は`verified`で、全AIの`hostVerified`と`ready`がtrueだった。

focused試験は初回、再実行、更新、旧登録、env・他設定保持、対応外、準備・登録・読戻し失敗、
MCP起動・timeout、TOML各形式、Cursor承認を扱う。これは公開npm版をSSH導入した証拠ではない。
外部仕様の根拠は[調査記録](../../rag/standalone-setup-host-contracts.md)に残す。
