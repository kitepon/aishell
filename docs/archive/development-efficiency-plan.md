---
title: AIShell 汎用開発機能拡張計画
updated: 2026-08-30
status: completed-archived
owner: AIShell
north_star: macOSの生きた状態を直接所有し、成功率を維持して開発課題あたりの総model tokenと所要時間を減らす
lattice_plan: aishell-capability-expansion
---

# AIShell 汎用開発機能拡張計画

> 2026-07-24に全8 Phaseを受け入れ、campaignは完結した。現行のnorth starと設計境界は
> [`AGENTS.md`](../../AGENTS.md)、公開利用・更新・release手順は[`README.md`](../../README.md)を正とする。
> 本文は判断と実装経緯を追跡するための履歴であり、現行工程の正本ではない。

## 0. 決定

初期高密度5 toolは3 sentinel × 3反復で両arm 9/9成功し、native Codex baseline比で
`tokens per solved task`を25.86%、平均wall timeを32.59%削減した。ただし小規模fixtureの結果であり、
30 task以上の代表suiteによる一般化は未完である。

2026-08-04の全project横断adoption監査では、日常利用の少なさをproduct fitだけで説明できないことを確認した。
Claudeのschema拒否、許可root外、Codexのdefault profile登録、cursorなし検索の既定失敗、全体routing正典の入口競合が
重なっていた。狭い単発検索ではnative `rg`の方が速く短いことも同時に実測したため、AIShellは反復・複数file・
大出力・process lifecycleへ限定して優先する。根拠と修理一覧は
[adoption監査](../../rag/development-adoption-audit-2026-08-04.md)を正とする。

2026-07-20のオーナー裁定により、初期5 toolを土台として、提案済みのS〜B機能をすべて実装対象へ入れる。
狙いは公開tool名の本数ではなく、高頻度の複数call、再scan、再読、再実行、待機を、macOSの生きた状態を
使う少数の高密度callへ置換することである。各機能は実装するが、default profileへの採用はcorrectnessと
paired benchmarkを通過したものに限る。効果不足の機能を成功扱いで既定化しない。

工程状態、依存、完了証拠の正本はLattice plan `aishell-capability-expansion`とする。このMarkdownは目的、
設計思想、非目標、受入条件、Latticeへの導線だけを所有し、Lattice登録後はcheckboxを工程状態として使わない。

### Lattice導線

- 現在地と次のready task: `lattice todo status`
- store・source inventory検証: `lattice todo verify --plan aishell-capability-expansion`
- Gantt再生成: `lattice todo gantt`
- 生成済み工程表示: [`.lattice/generated/gantt.html`](../../.lattice/generated/gantt.html)
- canonical plan: `lattice status --json`が返すactive revision（解決正本: `.lattice/todo/manifest.json`）
- 並列境界request: `.lattice/import/aishell-parallel-wave-request.json`、`.lattice/import/aishell-parallel-wave-b-request.json`
- fresh verify済みcompile receipt: `.lattice/evidence/aishell-parallel-wave-plan.json`、`.lattice/evidence/aishell-parallel-wave-b-plan.json`

## 1. 製品契約

優先順位は固定する。

1. 課題の成功と変更の正しさ
2. 成功課題あたりの総model token
3. wall time、first useful result、model/tool往復数
4. 日常課題での使用頻度とtool discovery成功率
5. host、MCP、既存利用者との互換性

Direct OSは交換可能なbackendではない。AIShellがfile identity、FSEvents観測とfilesystem照合、process
lifecycle、worktree、artifact、freshnessを所有するから削減が生まれる。Git、`rg`、compiler、test runner、
SourceKit-LSP、format parserはAIShellが直接起動・監視するworkerとして再利用し、本体を再実装しない。

主KPIは従来どおり次とする。

```text
tokens per solved task = 全試行のtotal model tokens合計 / oracle成功数
```

代表ベンチの各arm binaryはmanifestのSHA-256へ照合して`run/bindings/`へ原子的に保存し、再開時は
mutableなbuild出力ではなく保存済み実体だけを使う。部分完了後にcandidate bindingを変更する場合は、
他のmanifest条件が同一であることを機械検証し、native／current記録だけを再利用して旧candidate記録を
すべて再測定する。隣接する`aishell-run-supervisor`が存在する製品bindingでは、main binary SHAに結び付けた
companion binding receiptと一緒にhelperも凍結・再照合する。異なるcandidate binaryの記録を同一armへ
混在させない。agentの最終reportが不正でも
run全体を中断せず、その試行のprovider usageを全試行tokenへ含めてoracle失敗として記録する。process終了直後に
exit、timeout、wallを永続化し、後段observerの失敗で実測値を失わない。

補助指標は成功率、p50/p95 wall time、first useful result、tool call、model turn、retry、artifact再読、
filesystem entries rescanned、bytes reread、process reexecution、cache hit、change-journal hit、tool adoptionとする。

## 2. 公開surface

既存5 toolを拡張する。

| Tool | 追加する機能 |
|---|---|
| `workspace_snapshot` | 永続workspace index、Git diff context、project profile、worktree比較 |
| `search_context` | 複数query、regex、glob、symbol/変更/test優先、LSP統合 |
| `read_context` | line/symbol range、expected SHA、関連context、継続cursor |
| `run_check` | freshness cache、focused pipeline、非同期開始、structured diagnostic |
| `artifact_read` | 複数artifact横断検索、run比較、diagnostic group |

新規公開toolは役割が重複しない4本に限定する。

| Tool | 一回で返す成果 |
|---|---|
| `change_impact` | 変更symbol、参照、dependency、関連test、推奨focused checkと根拠 |
| `run_observe` | run状態、incremental diagnostic、tail、完了待機、cancel |
| `apply_change_set` | expected SHA付き複数file transaction、diff、更新後cursor |
| `workspace_wait` | cursor以後のOS変更をtimeout/cancel可能な待機結果として返す |

default development profileは最大9 tool、full profileはlegacy 20 toolを加えた最大29 toolを上限とする。
新しい能力を細粒度toolへ分割せず、既存5本または新規4本の成果単位へ統合する。

## 3. 非目標

- 独自AI agent、model hosting、thread、compaction、長期memory
- 汎用shell grammar、PTY、Terminal代替
- GUI操作、Accessibility、画面認識
- 独自tool router、compiler、parser、汎用多言語semantic engineの再実装
- FSEvents単独を完全な変更履歴とみなすこと
- stale cache、stale index、cursor失効時のsilent fallback
- benchmarkで改善しない機能をdefault化すること
- push、release、notarization、配布先変更。これらはH操作として別途明示承認を得る

## 4. 統括campaign

本計画は多段の受入連鎖と公開MCP契約の裁定証跡を要するため、`orchestrate`統括レーンで実行する。

- **F**: identity/cursor/freshness/cache意味論、process cancellation、multi-file transaction、公開MCP schema、
  default profile採否、benchmark gate、Phase accept/reject、Control Decision。
- **A**: Fで固定した仕様に基づくcore実装、adapter、fixture、focused test、benchmark runner、文書同期。
- **H**: push、release、notarization、外部配布。本campaignの実装完了条件には含めない。

実装campaign開始時にControlをinitし、最初のTask前にriskとbehavior laneを固定する。契約クリティカルな
Phase完了時だけ独立反証を行い、受入Decisionは不変ADRへ残す。

統合実装前の横断gateとして、benchmark v2のtask集合、fixture、exact request、observer projection、
harness-only oracle、集計式、expected digestを独立freezeする。freezeは実装candidateを起動せず、既存v1のbytesを
変更しない。search context統合とmanaged process／workspace wait統合はこのfreezeをhard predecessorとし、
変更が必要なら別F revisionと再freezeを要求する。root-scoped retained observationはcontextとwaitで別実装にせず、
共通`WorkspaceDeltaJournal`を正本にする。工程上のtask IDと現在状態はLattice active revisionだけを参照する。

Phase受入の順序は維持するが、将来PhaseのF契約、安全網、専用fileへ分離したCoreは、ACE-003後から
先行pipelineしてよい。共有serviceとMCP公開面へ書く統合Taskだけを前Phase受入とCore完了のjoinへ従属させる。
2026-07-20のLattice 0.7.0 compile/verifyでは、10個のCore責務を新規production/test fileへ分離し、
全境界のunknown 0・conflict 0をfresh Codegraph symbol evidenceで確認した。工程は49 Task、48 hard edge、
6 join、24 dependency waveで、旧revisionの39 Task、30 waveから受入順を崩さず20%短縮した。

同一repo writerを2本以上走らせる場合はLattice `plan compile`→`run start`と専用worktreeを必須にする。
runtime compileは最大8 node、実行capacityは既定4なので、11 Taskがreadyになる契約waveも一括dispatchせず、
domain別のbounded runへ分ける。まだ存在しないpathはCodegraph所有証拠に偽装せず、manual write scopeと
既存分離元symbolのCodegraph receiptを組み合わせる。

## 5. Lattice工程

以下の行は初期Lattice登録とper-ToDo source cutoverに使うsource ledgerである。登録後は各行からcheckboxを
除去し、状態はLatticeだけで更新する。

### Phase 0 — 再baselineと契約固定

- ACE-001 現行0.3.3の同期状態、42 test green、M1証拠を固定し、Controlをinitしてrisk・behavior laneを記録する。（工程状態はLattice正本）
- ACE-002 30件以上の代表suite、各機能のcapability fixture、current-AIShell比較arm、oracle、集計式を実装前に凍結する。（工程状態はLattice正本）
- ACE-003 default 9 toolの名称、責務、schema version、互換期間、feature flag、tool discovery日英probeをF裁定する。（工程状態はLattice正本）
- ACE-004 root/generation/exclusion/cursor、file identity、rename/delete、event gap、retentionの未完契約とcharacterization testを閉じる。（工程状態はLattice正本）

### Phase 1 — 永続workspace state

- ACE-010 永続checkpointのroot identity、entry metadata/hash、FSEvents event ID、generation、schema migration、quota契約をF裁定する。（工程状態はLattice正本）
- ACE-011 cold start、warm restore、offline変更、event gap、root置換、corrupt checkpointをfail closedで固定する安全網を先行実装する。（工程状態はLattice正本）
- ACE-012 RuntimeStore配下へpersistent workspace indexとobservation journal checkpointを実装し、OS現在状態との照合を正本にする。（工程状態はLattice正本）
- ACE-013 warm restart microbenchで全量content再読を削減し、delta/rename/delete oracleと既存suite非回帰を確認してPhase 1を受け入れる。（工程状態はLattice正本）

### Phase 2 — 高頻度context統合

- ACE-020 staged/unstaged/untracked/base差分、rename、budget、continuation、SHAを持つGit diff context契約をF裁定する。（工程状態はLattice正本）
- ACE-021 manifest、toolchain、target、既知のbuild/test/lint入口を保持し変更時だけ失効するproject profile契約をF裁定する。（工程状態はLattice正本）
- ACE-022 複数query、regex、glob、case、前後行、共有budget、dedup、変更/test優先を持つsearch_context v2契約をF裁定する。（工程状態はLattice正本）
- ACE-023 workspace_snapshot、search_context、read_contextへGit diff、project profile、一括検索・range読取を実装する。（工程状態はLattice正本）
- ACE-024 diff recall、search recall、continuation integrity、model-visible budget、native複数call比較を検証してPhase 2を受け入れる。（工程状態はLattice正本）

### Phase 3 — freshness cacheと変更影響

- ACE-030 executable、arguments、cwd、environment、toolchain、relevant input hashを束縛するrun_check freshness cache契約をF裁定する。（工程状態はLattice正本）
- ACE-031 false-fresh 0件、変更理由付き失効、cache corruption、TTL/quota、success/failure再利用を固定する安全網を先行実装する。（工程状態はLattice正本）
- ACE-032 changed path/symbolからreference、dependency、related test、build target、根拠、freshnessを返すchange_impact契約をF裁定する。（工程状態はLattice正本）
- ACE-033 manifestとimpact evidenceからfocused check候補を返し、呼出側指定時だけpipeline実行する契約をF裁定する。（工程状態はLattice正本）
- ACE-034 freshness cache、change_impact、focused pipelineを共有`DevelopmentRuntimeService`へ統合し、caller supplied catalog/hash、silent test selection、silent cache fallbackを禁止する。公開wireはlegacy v1を維持し、focused setのprepare/verifyを加算的に提供する。（工程状態はLattice正本）
- ACE-035 repeated-check、multi-file change、stale-after-edit fixtureで再実行・tool call・tokenを比較しPhase 3を受け入れる。（工程状態はLattice正本）

### Phase 4 — 非同期processとartifact

- ACE-040 run handle、status、wait、incremental evidence、terminal state、retentionを持つ非同期process契約をF裁定する。（工程状態はLattice正本）
- ACE-041 cancel/timeout race、PID reuse、descendant process、server restart、artifact完全性を固定する安全網を先行実装する。（工程状態はLattice正本）
- ACE-042 複数stdout/stderr/runをpattern・diagnostic・差分で横断するartifact query/history compare契約をF裁定する。（工程状態はLattice正本）
- ACE-043 cursor以後のOS変更をtimeout/cancel可能に待つworkspace_wait契約とFSEvents gap時の明示errorをF裁定する。（工程状態はLattice正本）
- ACE-044 run_observe、artifact横断検索・比較、workspace_waitを実装し、MCP request受付とjob lifecycleを分離する。（工程状態はLattice正本）
- ACE-045 long build、cancel、incremental failure、external edit fixtureでfirst useful resultとwall timeを比較しPhase 4を受け入れる。（工程状態はLattice正本）

### Phase 5 — transaction付き編集loop

- ACE-050 expected SHA、複数file all-or-nothing、create/delete/rename、rollback、result diff、workspace cursorを持つapply_change_set契約をF裁定する。（工程状態はLattice正本）
- ACE-051 stale SHA、途中失敗、symlink/root escape、同一file重複、crash recoveryでpartial write 0件を固定する安全網を先行実装する。（工程状態はLattice正本）
- ACE-052 apply_change_setを実装し、成功後のdeltaと影響候補を追加scanなしでworkspace runtimeへ反映する。（工程状態はLattice正本）
- ACE-053 host apply_patch比較でcorrectnessを維持し、編集・確認・再snapshot callを削減できることを確認してPhase 5を受け入れる。（工程状態はLattice正本）

### Phase 6 — adapter・semantic・worktree

- ACE-060 Xcode/xcresultを先頭に、SARIF、Cargo JSON、Bazel BEPを共通diagnostic schemaへ変換するadapterを需要順に実装する。（工程状態はLattice正本）
- ACE-061 SourceKit-LSPのdefinition/reference/symbol/diagnosticをOS file hashへ束縛しfresh/stale/indexing/unavailableを明示する。（工程状態はLattice正本）
- ACE-062 build manifest、depfile、LSPをworkerとして使うdependency/affected-test providerを実装し、heuristic provenanceを返す。（工程状態はLattice正本）
- ACE-063 workspace_snapshotへworktree/branch比較modeを追加し、root identity、base、dirty state、budget付きdiffを返す。（工程状態はLattice正本）
- ACE-064 lexical、semantic、dependency adapterのablationとstale-after-edit検証を行い、改善しない経路は利用可能でもdefault routingへ入れない。（工程状態はLattice正本）
- ACE-065 default 9/full 29 tool profile、schema、instructions、日英tool discovery、互換性を統合しPhase 6を受け入れる。（工程状態はLattice正本）

### Phase 7 — product gateと還流

- ACE-070 native、現行0.3.3、拡張candidateを30 task以上×事前登録反復で比較し、全試行token、成功率、wall、tool adoptionを集計する。（工程状態はLattice正本）
- ACE-071 baseline成功taskを落とさずtokens per solved task 30%以上削減、p50非悪化、p95悪化10%以内、silent fallback 0をproduct gateとする。（工程状態はLattice正本）
- ACE-072 Phase maintenanceを一回だけ処理し、関連test、swift test、package-app、MCP wire fixture、最終独立監査を通す。（工程状態はLattice正本）
- ACE-073 README、MCP instructions、RAG、release notes、公開schemaを同期し、Phase Decision ADRとControl finalization証拠を残す。（工程状態はLattice正本）

## 6. Phase gate共通条件

各Phaseは次を満たすまで後続へ進めない。

- baselineが成功したtaskを落とさない。
- silent truncation、silent full scan、silent cache hit、silent backend fallback、一次証拠消失を0件にする。
- cursor、cache、index、artifact、run handleのstale/expired/corruptをtyped errorで判定できる。
- capability fixtureで少なくとも1つの再scan、再読、再実行、tool call、model turn、又は待機時間を削減する。
- focused testを変更中に回し、Phase完了時に関連testを1回、契約クリティカル範囲だけ独立反証する。
- 効果不足でも実装済みを成功扱いでdefault化せず、計測値と採否理由をDecisionへ残す。

## 7. 主なリスク

| リスク | fail-closed方針 |
|---|---|
| 永続journalがoffline変更を取りこぼす | event gap/root identity不一致を`RESCAN_REQUIRED`にし、黙ってrestoreしない |
| freshness cacheがstale成功を返す | relevant input binding不足はcache miss。false-freshを最重要回帰として固定 |
| impact heuristicが必要testを落とす | 候補と根拠を返し、自動実行範囲は呼出側が明示。推測を完全性として表示しない |
| async cancelがdescendantを残す | process identityとstart timeを照合し、terminal state前にartifactを確定しない |
| multi-file editがpartialになる | durable intent、preflight、atomic replace、rollback/recoveryをtransaction契約に含める |
| semantic indexがstale | OS hashとdocument versionを束縛し、lexical切替を結果へ明示する |
| tool増加でrouting/cacheが悪化 | default最大9本、schema順固定、日英discoveryとprompt cacheを実測する |
| adapter拡張が長尾化する | 共通schemaとprovider seamを固定し、需要fixtureがあるadapterだけdefault候補にする |

## 8. 完了の定義

全Lattice taskがevidence付きdoneで、全Phase gateがacceptされ、30 task以上のproduct gateを通過し、
default profileが最大9 toolでS〜B能力へ到達した時に本計画を完了する。push、release、notarizationは
別のH承認であり、この完了判定へ混ぜない。

## 9. 根拠

- [AIShell開発効率ランタイム調査](../../rag/development-efficiency-runtime.md)
- [M1 benchmark evidence](../evidence/aishell-efficiency-m1-benchmark.md)
- [初期surface ADR](../adr/0001-os-owned-high-density-runtime.md)
- [現行公開挙動](../../README.md)

未検証の削減率、host挙動、semantic index効果は本文の期待ではなく、Lattice taskが保持するpaired benchmark
evidenceを正とする。
