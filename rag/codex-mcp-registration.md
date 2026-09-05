# AIShellをCodexの別タスクへ公開する

- 出典: [[raw/codex-global-mcp-config]]
- 取得・検証日: 2026-07-19、2026-09-06追記
- 確度: 高（公式仕様 + ローカル実測）

## 判断

AIShellはネットワークサーバーや常駐daemonにせず、アプリに同梱したMCP helperをCodexの個人設定へstdio serverとして登録する。これにより、同じMac上の新しいCodexタスクから利用でき、停止状態はAIShellのランタイム設定が保持する。操作対象フォルダの登録は不要で、パス解決は[ADR 0030](../docs/adr/0030-folder-registration-removal.md)に従う。

## 登録

```text
codex mcp add aishell --env AISHELL_CAPABILITY_SET=expanded-v1 -- aishell-mcp
```

## 接続後の確認

MCP接続後に`runtime_status`で`relativePathBase`と停止状態を確認する。グローバルinstallを更新した場合はMCPを再接続する。公開版の確認結果は[ADR 0030](../docs/adr/0030-folder-registration-removal.md)に記録した。

## 過去の実測

以下は各version当時の記録である。許可rootとGit worktree自動許可の仕様は0.5.0で廃止した。

- `codex mcp get aishell`: `enabled: true`、`transport: stdio`
- `codex mcp list`: `aishell` を有効なserverとして表示
- npm同梱helper: default `tools/list`で高密度5 toolと復旧control 2 tool、`AISHELL_TOOL_PROFILE=full`で25 tool
- 0.3.4の`AISHELL_CAPABILITY_SET=expanded-v1`: 高密度9 tool＋復旧control 2 tool、expanded fullは29 tool。未知・空のcapability/profile値はtyped startup errorで停止しsilent fallbackしない
- default/full両profileで`runtime_status`と停止中の`runtime_open_manager`を公開する。0.3.2以前のdefault 5面で回復toolを案内しながら非公開だった契約欠陥は0.3.3で修正
- 停止中: `process_run` をAIShell側で拒否
- 0.2.1: 設定rootに属するGit worktreeを `automaticGitWorktreePaths` と `effectiveAllowedRootPaths` へ自動反映し、worktree単位の追加依頼を不要化
- 0.3.1: npm global install後のhelperでinitialize version `0.3.1`、default 5/full 25 toolを再検証。shell/env basename拒否は安全境界ではなく、高密度な直接process経路へ誘導する製品レールとして明文化
- 0.3.3: default 5 development toolへ`runtime_status`と`runtime_open_manager`を復旧controlとして追加し、未設定・停止・許可root外の案内先を同じ公開catalog内でcallableにした。fullは25 toolのまま
- 0.3.4: managed run、workspace wait、impact解析、atomic change setと既存toolのv2 schemaを`expanded-v1`のopt-in面として公開。development 11/full 29、MCP `2025-11-25`のcandidate toolはtop-level object `outputSchema`を持つ
- 0.3.6: `run_observe`のstatus/read/wait/cancel応答へ`exitCode`・`signal`・`cancelAcknowledged`を追加。global install後の実測でnatural exitの`exitCode=1`、cancel後の`cancelAcknowledged=true`、orphan 0を確認。catalog・schema・tool数は不変
- 0.3.5: `apply_change_set`が変更ごとに`after_content`（UTF-8テキスト4KiB以下）を返し、冗長な`result: "applied"`を削除。tool数・schema・catalog digestは0.3.4と不変（`a7fb8c…`）。global install後の実測で`initialize` version `0.3.5`、`expanded-v1` 11 tool、input/output schema欠落0、実`apply_change_set`が`after_content: "A2\n"`を返し`result`は非存在
- 0.4.2: requestを3 laneへ分離し、`run_check`実行中でも復旧controlと読み取りが応答するようにした。catalog・schema・tool数は不変。global install後の実測で`initialize` version `0.4.2`、6秒の`run_check`を先行させた状態で`ping` 0.40s／`runtime_status` 0.41s／`search_context` 0.53s／`run_check` 6.12sの順に到着（0.4.1までは全て6.12s後）。あわせて起動時検証の失敗が`aishell-mcp: INVALID_CAPABILITY_SET: …`をstderrへ出しexit `78`（`EX_CONFIG`）で終了することを実測。stdoutの`id: null` JSON-RPC errorは互換のため維持されている
- 0.4.8: union schemaのtop-level `type: object`欠落を直し、Claude Code 2.1.221のfresh sessionで`expanded-v1` 11 tool loadと`runtime_status`実行を確認
- 0.4.9: 対話hostの正規登録をbare `aishell-mcp`＋`expanded-v1`へ統一。cursorなしlexical searchで省略rankingが暗黙に`changed`を選び失敗していたため、cursorなしは`tests`、cursorありは`changed, tests`を既定にした
- 0.4.10: 0.4.9公開後のfresh Codex smokeで、省略検索のsnapshot前処理が実repo全entryのsort比較ごとに`URL(fileURLWithPath:)`を生成し数分CPUを占有することを検出。priorityのdecorate-sort化に加え、cursor-free lexical searchの復元時full scan、未使用indexed-file projection、Git ignored manifest traversalを除去した。198,478 entry／74 MB checkpointの同一release queryは5.94秒。checkpointの全payload SHA・schema・entry invariant検証は維持
- 0.4.11: Aiterm 0.21.4由来のfresh managed Claudeがuser scope MCPを復元し、AIShell 11 toolと`runtime_status`を直接利用できることを確認。その実機smokeで`search_context(path:"README.md")`が実在regular fileを拒否したため、directoryに加えて単一fileをscopeとして受理する。lexical workerはfile自身だけへ`rg`を実行し、globもattested indexからexact fileだけを許す。公開・global install後のfresh sessionでは同じfile scope検索が成功し、7件・1,132 bytesを返した

`codex --strict-config mcp get aishell` は、現行CLIが `codex mcp` で `--strict-config` をサポートしないため検証経路として使用できなかった。通常の `get/list` は設定を正常に解析した。
