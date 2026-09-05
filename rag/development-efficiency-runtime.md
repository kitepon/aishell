---
title: AIShell macOS直結・開発効率ランタイム調査
source: オーナー裁定（Direct OS state ownershipを製品の根とする）、rag/raw/development-efficiency-runtime/SOURCES.md、AIShell 0.2.1ローカル実装
acquired: 2026-07-19
confidence: 中〜高。外部仕様とローカル実装事実は高、製品効果と削減率は未検証
status: 初期5 tool実装・M1実測済み。3-task sentinelでtoken 25.86%減、平均wall 32.59%減
---

> 本書は調査・実測時点の記録。フォルダ登録と許可範囲に関する現行仕様は[ADR 0030](../docs/adr/0030-folder-registration-removal.md)を参照する。現在の操作手順はREADMEに従う。

# AIShell macOS直結・開発効率ランタイム調査

## 2026-07-19 実装・実測の還流

初期仮説の5 toolをすべて実装し、default development profileを5本、互換full profileを25本に分離した。FSEventsは変更候補だけをjournalへ入れ、snapshot時に現在のfile identity・metadata・SHA-256と照合する。processはFoundation `Process`で直接起動し、stdout/stderrの完全byte列をTTL/quota付きartifactへ保持する。Gitと`rg`は引き続きworkerであり、公開面の根にはしていない。

shell群、`env`、`osascript`のbasename拒否はsecurity boundaryにならない。改名binaryや許可workerの子processは実行可能だからである。採用理由は、AIを汎用`zsh -lc` wrapperへ戻さず、executable、arguments、working directory、lifecycle、artifactが分離された高密度経路へ誘導する製品レールとして有効なためである。安全性や権限制御をこのlistへ依存させない。

実装中、FSEventsがtemporary directoryを`/private/var/...`で通知する一方、許可rootが`/var/...`になる実体path aliasを確認した。文字列prefixだけでroot包含を判定すると正しいイベントを捨てるため、event pathとrootの双方をsymlink解決してからboundary比較する。これはFSEventsを信頼するのでなく、現在filesystemと照合する設計の一部である。

探索runではPATH解決不足や過剰routingが追加turnを生むことを確認し、異なるcandidateの混成集計を無効として棄却した。最終candidate `a0c22c3` はprompt、manifest、binary、tool catalog、repository、config、PATHのhashとRTK不在を固定し、AIShell armの必須tool成功、agent正常終了、timeoutなしをoracle gateへ含めた。同一candidateの3 task × 3反復で両arm 9/9、AIShellはtoken/solved taskを25.86%、平均wallを32.59%削減した。noisy compileはtoken 36.65%減、反復workspaceは20.10%減。小規模・bypass隔離fixtureの結果であり、一般化には30-task suiteが必要。

## 研究課題

AIShellを、AIによるソフトウェア開発の成功率を維持しながら、総tokenと所要時間を減らす製品へ転換するには何を作るべきか。

## 製品判断の訂正

当初の統合では「OSへ直接命令することは目的ではなく、情報圧縮が本体」と結論した。これは因果関係を逆にした誤りだった。

OS直結を外して開発効率だけを目的にすると、検索、Git、LSP、test、編集などの便利toolを際限なく詰め込むことになる。そこにはAIShell固有の境界がなく、既存hostや専門toolの劣化再実装になる。

正しい因果は次である。

> **AIShellがmacOSの生きたfilesystem・process・worktree・artifact状態を直接所有する。だから全量の再観測を避け、AIへ最小情報と高密度な操作を返せる。**

情報圧縮は製品の根ではなく、Direct OS state ownershipから生まれる効果である。

## 結論

AIShellの本命は、**macOSの生きた状態をモデルより下で継続的に所有するAI開発ランタイム**である。

- FSEventsで変更候補を受け、現在のfile identityとcontent hashへ照合した変更差分を保持する。FSEvents単独を完全な履歴とは見なさない。
- executable URLと引数を分離してprocessを直接起動し、lifecycle、timeout、exit、stdout/stderrを所有する。MCP cancellationは0.3未実装。
- 許可root、Git worktree、完全artifact、freshnessを同じruntime stateとして結合する。
- Git、`rg`、compiler、test runner、SourceKit-LSPは専門workerとして借りる。
- worker結果とOS状態を結合し、通常contextには短い結論だけ、完全証拠は期限付きhandleで返す。

圧縮はlossyなログ切捨てではない。モデルの通常contextへは短い結論と主要証拠だけを載せ、完全stdout/stderrはartifact storeに保持する。read/searchはcontinuation、workspace deltaはcursorで続行する。初回snapshot entriesはbounded previewであり、full snapshot artifactは0.3未実装である。

## 現行実装から分かったこと

| 事実 | 開発効率への影響 | 判断 |
|---|---|---|
| 20 toolの`tools/list`は約10.1 KB | catalog費用はあるが、hostの遅延ロードとcache次第でモデルtokenは変わる | 独自tool routerより先に実hostで測る |
| 成功JSONを`content.text`と`structuredContent`へ併記 | wire上は重複。モデルへ二重投入されるかはhost依存 | 互換性を壊して片方を消す前にprobeする |
| 一部resultはtop-level array | stable MCP 2025-11-25のobject-shaped structured resultと不整合 | object envelopeと`outputSchema`を先に整える |
| `files_read_text`は最大1 MiB全文 | 欲しい数行のために巨大本文を返し得る | range、budget、hash、cursorを追加する |
| `process_run`はstdout/stderrを各1 MiBまで本文返却 | catalogより桁違いのcontext汚染源になり得る | 完全ログ保存 + preview + handleを最優先する |
| process終了後にscratchを削除 | 切り捨てたログへ戻れない | TTLとquotaを持つevidence storeを作る |
| list/search/treeの打切りに継続情報がない | 全件と誤認し、探索や再試行を増やす | `has_more`、omitted、opaque cursorを返す |
| MCP request loopは長時間process中に塞がる | poll、cancel、並列観測を阻害する | request受付とjob実行を分離する |
| `initialize` instructionsが最初の`runtime_status`を推奨 | host/modelが従う場合はbootstrapを1 call増やす | 実call率を測り、追加往復になっている場合だけ通常resultへ統合 |

最大の改善候補は、約2.5k token相当と概算されたtool catalogより、最大MiB級のfile/process出力である。ただし「wire byte削減 = model token削減」とは見なさず、host変換後のusageで検証する。

## 外部一次資料から得た設計判断

### Tool discoveryは上流を利用する

OpenAI Tool Searchはtool schemaを遅延ロードし、prompt cacheを維持する構成を説明している。これはcatalog常時投入を減らす方向を支持するが、20 toolのAIShellで得られる効果量は示していない。

したがってAIShell独自のcatalog検索は作らない。手元Codexでdeferred loadingの有無、日本語promptからの発見率、tool missによる追加turnをprobeし、tool名・説明・parameter metadataの品質を上げる。

### Prompt cacheはcontext削減ではない

OpenAIのprompt cacheはexact prefix matchingを使い、tool definitionもcache対象になる。schema、順序、説明を決定的に保ち、timestamp、cwd、権限状態のような動的値をtool definitionへ入れない。

cached inputは料金やprefill latencyを下げ得るが、context windowから消えるわけではない。benchmarkではuncached input、cached read、cache writeを分け、Codex CLIからhit/missを強制できない場合は観測cached比率で事後層別する。

### Contextは「多いほど良い」ではない

ContextBenchは、agentが見たcontextと実際に解決に必要だったcontextの差を、recall、precision、efficiencyとして評価する。ChromaのContext Rot実験も、無関係な長いcontextが性能を落とす方向を示す。

AIShellは「関連候補を全部返す」のではなく、明示されたtoken budget内で、taskとの関連、symbol関係、変更近接性、診断の一次性を使って順位付けする。省いた候補はhandleから回収可能にする。

### Repository mapとsemantic indexは再利用する

Aiderは定義・参照graphを順位付けし、token budget内にrepository mapを収める。Serenaはsymbol単位の取得とLSP再利用を実装済みで、SourceKit-LSPはSwift/C系の高精度indexを提供する。

よって、AIShellがparserや汎用semantic engineを一から作る理由はない。初期は`rg`の機械可読出力とGit差分を圧縮し、Swiftのsemantic pathはSourceKit-LSPへの薄いadapterとして試す。既存経路より同一成功率でtokenまたは時間が改善しないadapterは採用しない。

### AGENTS.mdは短く、非冗長にする

AGENTS.md研究は方向が割れている。一方は124 PRの観察で実行時間中央値28.64%、出力token中央値16.58%の減少との関連を報告した。別研究は複数agent/modelで、context fileが成功率を有意に改善せず、費用を20%以上増やす場合を報告した。

共通して言えるのは、repositoryから発見できない重要情報だけを、人が短く明示すること。今回作るproject `AGENTS.md`は、製品north star、評価規約、境界、主要コマンドだけに限定する。

## 役割分担

| 層 | 所有者 | AIShellの方針 |
|---|---|---|
| 会話、推論、thread、compaction、sub-agent | Codex等のAI host | 作らない |
| 汎用PTY、shell grammar、Terminal session | hostまたは既存shell tool | 置換しない |
| file identity、FSEvents観測、filesystem照合、許可root、worktree | AIShell | 現在状態を正本として作る |
| 直接起動したprocess、exit、timeout、完全output | AIShell | lifecycleとartifactを所有する。MCP cancellationは将来拡張 |
| Git、compiler、test runner、`rg`、LSP | 既存ローカルtool | AIShell管理下のworkerとして再利用する |
| 結果圧縮、evidence、artifact、freshness、delta | AIShell | OS stateから導出する公開価値として作る |
| macOS許可root、停止、Trash等の安全床 | 現行AIShell | 維持するが当面の最適化対象にしない |

## 推奨する共通result envelope

```json
{
  "status": "failed",
  "summary": "型変更後、3箇所が旧signatureのまま",
  "evidence": [
    {
      "path": "Sources/A.swift",
      "line": 42,
      "kind": "compiler_error",
      "message": "missing argument"
    }
  ],
  "artifact": {
    "handle": "aishell://runs/abc/stderr",
    "bytes": 91240,
    "sha256": "...",
    "expires_at": "2026-07-20T00:00:00Z"
  },
  "omitted": {
    "lines": 1842,
    "bytes": 88012
  },
  "freshness": {
    "workspace_cursor": "c17",
    "index": "ready"
  },
  "meta": {
    "request_id": "...",
    "duration_ms": 1842
  }
}
```

必須性質:

- top-levelはobjectで、stableな`outputSchema`を持つ。
- 成功時は短い。失敗時はprimary diagnosticと位置を優先する。
- 省略と`expires_at`を隠さず、advertised retention中は完全証拠へ戻れるhandleを返す。
- cursor失効、内容変更、index staleを機械判定可能なcodeで返す。
- 黙ったfull scan、黙った同期実行、黙った別backendへの切替をしない。

## 初期の公開tool仮説

既存20 primitiveをすぐ削除せず、下位実装またはlegacy profileへ残す。development profileの候補は次の5本を中心にする。

1. `workspace_snapshot(since_cursor?)`: repository構造、Git状態、変更、主要entry pointをbudget内で返す。
2. `search_context(query, budget, detail)`: 本文、symbol、関連test、変更近接性を束ねる。
3. `run_check(kind, scope, budget)`: focused build/testを実行し、成功を1行、失敗を主要診断へ圧縮する。
4. `artifact_read(handle, selector, budget)`: range、tail、pattern周辺を再取得する。
5. `read_context(targets, budget)`: 複数file/symbolの必要範囲とhashを一度に読む。

`apply_patch`、独自`tool_search`、汎用process sessionは、hostの既存能力に明確な不足があり、paired benchmarkで改善する場合だけ公開面へ追加する。

## Benchmarkで守ること

主KPIは削減率単体ではなく、**全試行の総model token合計 / oracle成功数**。失敗試行のtokenも分子へ残す。correctnessを第一に、隔離された同じmodel snapshot、reasoning effort、prompt、fixture、sandbox、timeout、output capでpaired比較する。

最低限分けて記録する値:

- inputとoutput、および内数としてcached input、reasoning output。cache writeは費用分析用の別列
- tool schema bytes、tool result wire bytes、hostがmodelへ見せたbytes
- tool call、model turn、retry、truncation、artifact再読、compaction
- task success、oracle result、wall time、first useful result
- model、host、AIShell、toolset、repository commit、config hash

`codex exec --json --ephemeral`のJSONLは、`turn.completed.usage`にinput、cached input、output、reasoning outputを出せる。Codexでは主集計を`input_tokens + output_tokens`とし、cached inputとreasoning outputを二重加算しない。host traceが不足する場合はOpenTelemetry eventを併用する。tokenizer概算は補助値として明記し、provider報告値と混ぜない。

## 棄却した方向

- OS state ownershipを外し、汎用開発効率toolを集積する。
- Direct OS APIの本数だけを価値指標にする。価値は所有した状態から削減した再観測とmodel負荷で測る。
- shell不使用やshell basename拒否を安全性・成功条件にする。正本は直接process lifecycleと状態をAIShellが所有し、tokenと時間を削減できたかで判断する。
- 独自AI agent、thread store、compactionを作る。
- raw logを削除して短く見せる。
- 最初から全言語のsemantic indexを作る。
- 外部のTool Search削減率をAIShellの削減見込みとして掲げる。
- withdrawn済みFastContextの主張を使う。

## 未確定事項

- 手元Codex 0.144.6がMCP schemaをどの条件で遅延ロードするか。
- `structuredContent`と互換TextContentが各hostでmodel contextへどう投入されるか。
- MCP resource linkを各hostが自動追跡するか。
- SourceKit-LSPのtoolchain/build-system別coverageとindex freshness。
- context budgetの最適値と、追加read callとの損益分岐。
- durable artifactのTTL、quota、GC、機密logの扱い。

これらは設計会議で推測して確定せず、開発計画のPhase 0〜2で実機probeする。
