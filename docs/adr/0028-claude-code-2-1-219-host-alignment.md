# ADR 0028: Claude Code 2.1.219 に対するhost整合

> 0.5.0で許可フォルダの登録・範囲制限を廃止した。本書の許可rootに関する契約は[ADR 0030](0030-folder-registration-removal.md)で置き換えられた。本文は当時の設計・検証記録として保持する。

- Status: accepted
- Date: 2026-07-24（決定1・3）、2026-07-25（決定2の実装と前提条件の追記）
- 対象version: AIShell 0.4.1 (commit 3c51da8)

## 背景

Claude Code 2.1.219 に、MCP serverとして動作する `aishell-mcp` に影響する変更が入った。
影響を調査し、対応方針を決める。関係するのは次の3点で、それ以外（fast mode対象変更、
`workflowSizeGuideline`、HTTP接続時のstatus表示、Windows/Vim/screen系修正）は
stdio接続・macOSローカルの本製品には無関係である。

1. subagentのnested spawnが既定 depth 1 → 3
2. MCP接続失敗時のエラー本文表示（`claude mcp list` / `/mcp`）と、headlessの
   `mcp_server_errors` init event
3. `DirectoryAdded` hook の追加（`/add-dir` および SDK `register_repo_root` で発火）

なお 2.1.219 の changelog highlight にある「bashコマンドを実行するtoolを追加」
「agent起動toolを追加」は、changelogがsystem prompt差分から自動生成されたことによる
表記であり、実際には従来から存在するtoolのprompt文言変更である。`run_check` と競合する
新機能が追加されたわけではない。

## 決定

### 1. 起動時検証の失敗をstderrと非0 exitで通知する（採用・実装済み）

`MCPServer.run()` の起動時検証失敗は、`id: null` の JSON-RPC error を stdout に書いて
return し、processは exit code 0 で終了していた。これは `initialize` への応答ではないため、
host側からは「応答せずに終了した」としか見えず、`INVALID_CAPABILITY_SET` /
`INVALID_TOOL_PROFILE` / `FACTORY_PROFILE_CAPABILITY_SET_UNSUPPORTED` という型付き
メッセージがhostに届かない。

`run()` を `MCPServerOutcome` を返す形に変え、失敗時は

- 型付きメッセージを diagnostics sink（既定は stderr、`aishell-mcp: ` 前置）へ出力
- stdoutのJSON-RPC errorは互換のため従来どおり出力
- exit code `78`（`EX_CONFIG`）で終了

とする。exit codeは `MCPServerOutcome` からのみ決まり、`AIShellMCPMain` はそれを
`exit()` に渡すだけにする。sinkは注入可能にして、実stderrに書かずにテストできるようにした。

### 2. requestのlane分離（採用・実装済み）

#### 問題

`MCPRequestScheduler` は `startNextIfNeeded()` が `activeTask == nil` を条件とする厳密な
直列処理で、1度に1 requestしか実行しない。`run_check` の既定timeoutは120秒あるため、
その実行中は同一sessionの他agentが投げた `read_context` / `search_context` /
`runtime_status` がすべてqueueで待たされる。とくに `runtime_status` は「一時停止中でも
未設定でも答える」復旧用controlとして定義されているのに、実行系toolにブロックされる。

subagentのnestが depth 3 既定になったことで、1 sessionあたりの同時agent数が増え、その
全部が同じstdio processに集中する。depth 1 の頃は並列度が低く顕在化しにくかった。

#### 対応方針

lane を3つに分ける。

| lane | 対象 | 多重度 |
| --- | --- | --- |
| recovery | `runtime_status`, `runtime_open_manager` | 即時、他laneと独立 |
| read-only | `read_context`, `search_context`, `artifact_read`, `workspace_snapshot` | 並列 |
| execution | `run_check`, `run_observe`, `apply_change_set`, `workspace_wait`, `change_impact` | 直列（現状維持） |

表に無いtool（`files_*`、`apps_*`、`process_run`、`factory_diagnostics`）とmethodは
executionへ落とす。並列化は個別に安全性を確認したものだけへ与え、未知のものは従来どおり
直列に保つ。ただし `initialize` / `ping` / `tools/list` は不変stateだけを読む純粋な応答なので
recoveryへ入れる。とくに `ping` はliveness確認であり、詰まっている時にこそ答える必要がある。

`MCPRequestScheduler` の既存契約は維持する。すなわち同一 request id の重複検出、
`notifications/cancelled` によるcancel、`waitUntilIdle()` のshutdown契約を壊さない。
重複検出とcancelはlaneをまたいで効かせるため、request id由来のkeyから実行中tokenへの
索引をscheduler側に持つ。応答を書き終えるまでkeyは解放しない。

#### 前提条件1: `MCPServer` のmutable stateを畳む（実施済み）

`MCPServer` は `@unchecked Sendable` で、同期されていないmutable stateを持っていた。

- `private lazy var files` / `private lazy var processes`（初回アクセスで書き込みが起きる）
- `private var changeSetServices: [String: ApplyChangeSetService]`
- `private var managedRuns: ManagedRunService?`
- `private var catalogValidationSucceeded`

**この `@unchecked Sendable` が健全だったのは、schedulerの厳密な直列化がhandlerの同時実行を
禁じていたからである。** よってlane分離は、schedulerだけを変更しても成立しない。

stored propertyをすべて `let` へ畳み、可変stateは `MCPServiceRegistry` actorへ移した。
`ApplyChangeSetService` はrootごとのstate directoryを所有するため、同一rootへの同時要求が
別instanceを作ると整合性が壊れる。生成中のTaskをkeyに保持して同じinstanceへ合流させ、
生成失敗はcacheしない。結果として `@unchecked` を外した `Sendable` 適合がSwift 6 modeで
通り、安全性の根拠が外部条件からcompilerの検証へ移った。

#### 前提条件2: `MCPResponseWriter` のsink呼び出しを直列化する（実施済み）

lane分離の作業中に判明した、ADR初版に無かった前提である。

`MCPResponseWriter` はactorだが、`sink` が nonisolated な `@Sendable async` closureなので
`await sink(...)` でactorが解放される。直列schedulerの下では同時に1件しかwriteが無いため
顕在化しないが、laneを分けると2本の応答が同時に同じ出力先へ書き込みうる。1行がPIPE_BUFを
超えると混線し、JSON-linesが壊れる。

実際に直列化を外して測ったところ、4 KiB応答12件の並行writeでJSON parseが8件失敗した。
**仮説ではなく実在の破壊である。** sinkの呼び出しだけを1本のTask鎖へ直列化して塞いだ。
encodeはactor内で完了しているため、鎖へ繋ぐ順序がそのまま出力順になる。

#### 作業順序

「state安全化 → lane分離（writer直列化を含む）」とし、両者を同一commitに混ぜない。

### 3. `DirectoryAdded` hook 連携（実装しない・条件付きで再検討）

#### 調査結果

- allowed rootの追加は `RuntimeStore.addAllowedRoots(_:)` という通常のAPIで、GUI依存はない。
  manager appの `AppModel.addRoots()` は `NSOpenPanel` をこのAPIに被せているだけである。
- appはsandbox外で動く（`project.yml`: `ENABLE_APP_SANDBOX: NO`）。security-scoped
  bookmarkは使っておらず、configurationはpath文字列として保存される。
- npm packageの `bin` は `aishell-mcp` と `aishell-open` の2つだけで、root追加のCLI口はない。

#### 結論

CLI口の実装自体は既存APIの薄いwrapperで済む。しかしその容易さが、そのまま論点になる。

`NSOpenPanel` は技術的なaccess gateではなく、**人間の同意gate**として唯一機能している。
sandbox外である以上、CLIから `addAllowedRoots` を呼べば同意なしにAIの操作可能範囲が広がる。
hookはAI hostのlifecycleで発火するため、これは「AIが自分の権限境界を自分で広げられる」
経路になりうる。allowed rootはAIShellの安全性の土台であり、利便性と引き換えにできない。

よって直接追加型のCLIは実装しない。将来対応するなら、hookは *追加要求* を書き込むだけとし、
manager appがそれを承認UIとして提示する request/approve 方式に限る。この方式を採る場合は
別ADRで扱う。

## 影響しないと確認した項目

- **Opus 5 既定化・1M context**: AIShellの予算はmodel依存ではなく呼び出しごとの `byteBudget`
  で、既定64 KiB・上限1 MiB（`ContextCompilerService`）。技術的影響はない。ただし訴求は
  「context上限に入らないから絞る」ではなく「密度と証拠保持」に置く必要がある。
- **managed MCP allowlist/denylist の `${VAR}` 解決先変更**: 起動環境とmanaged settings由来に
  変わったが、AIShellはsettings fileのenvに依存していないため影響しない。
- **MCP設定値の前後空白に対するhost側警告**: `AISHELL_CAPABILITY_SET` に空白が混ざった値は
  現状も型付きerrorで起動失敗する（README記載の設計どおり）。host側で警告が出るようになった
  ぶん、利用者が自力で気づけるようになる。AIShell側の変更は不要。
