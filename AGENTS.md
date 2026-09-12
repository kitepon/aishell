# AIShell project instructions

## 製品目的

AIShellのnorth starは、**macOSの生きた状態を直接所有し、その状態からAI開発に必要な最小情報と操作を生成して、成功課題あたりの総model tokenと所要時間を減らすこと**。

優先順位:

1. correctness / task success
2. total model tokens per solved task
3. wall time / model・tool往復
4. compatibility

Direct OSは交換可能なbackendではなく、効率化を生む設計上の根である。AIShellがfile identity、OS変更の観測・照合state、process lifecycle、worktree、artifactをモデルより下で所有する。TrashとSHA競合検出を維持するが、現在の最適化対象ではない。

操作対象フォルダの事前登録や許可一覧は持たない。絶対パスはその対象、相対パスと省略時はMCP起動ディレクトリを基準にする。

新機能は、OS状態を直接観測・保持して再scan、再読、再実行、model往復を減らせる場合だけ採用する。OS状態と無関係な便利toolや薄いwrapperを詰め込まない。

## 必要時の参照先

- 完了した能力拡張campaignの経緯が必要な時だけ`docs/archive/development-efficiency-plan.md`を読む。現行の製品目的と設計境界は本ファイルを正とする。
- 外部調査の前だけ`rag/INDEX.md`を検索する。
- 公開挙動、配布、利用手順を変える時だけ`README.md`を読む。
- 文書の所有と寿命を判断する時だけ`docs/README.md`を読む。
- legacy挙動の由来が必要な時だけ`docs/archive/direct-os-spike.md`を読む。今後のGUIロードマップには使わない。

削減率は、隔離された同一model snapshot、reasoning、fixture、prompt、sandboxでbaselineと比較できる場合だけ主張する。主KPIは失敗試行のtokenも含む`tokens per solved task`。wire bytesやtokenizer概算をprovider報告tokenと混ぜない。

## 操作機能と認証・UI

OS操作のツールと挙動を維持する。認証や管理UIの廃止を理由に、検索・一括読取り・変更待機・実行監視・影響解析・複数ファイル編集・artifact読取りを削らない。
管理UIと停止設定、Keychainアクセスは廃止した。`runtime_open_manager`は互換名だけを残し、廃止済みの明示エラーを返す。
編集状態は平文で保存し、新しい暗号鍵と所有者証明は作らない。旧暗号化記録の読取りと更新契約は`docs/setup.md`を参照する。使用ログは従来の`activity.jsonl`へ保存する。

## アーキテクチャ境界

- AIShellは単独でinstall、config、state/schema、migration、diagnostics、recovery、
  update、releaseできる契約を本repo内に持つ。dotagentsは製品横断wireと互換projectionを
  統合するだけで、AIShellの内部状態や運用判断を制御しない。
- 製品単体の準備・AI登録・読戻し・MCP実操作は`aishell-setup`が所有する。Mac/AI別の差は`scripts/setup/`へ置き、管理UIとKeychain認証は持たない。npm install lifecycleでは起動しない。公開契約は`docs/setup.md`を正とする。
- AI hostがreasoning、thread、compaction、sub-agent、汎用PTYを所有する。AIShellで再実装しない。
- AIShellはfile identity、FSEvents観測とfilesystem照合によるdelta、直接起動したprocess、完全log/artifact、freshnessを所有する。FSEvents単独を完全な履歴とは見なさない。
- Git、`rg`、compiler、test runner、SourceKit-LSPはAIShellが直接起動・監視するworkerとして再利用する。状態の所有者や公開toolの寄せ集めにはしない。
- shell文字列を評価せず、executable URL、引数、working directoryを分離したままprocessを起動する。shell群、`env`、`osascript`のbasename拒否は汎用shell wrapperへ退行させない製品上の設計レールであり、security boundaryではない。許可workerの子processや改名binaryまで阻止するものとして扱わない。
- `AIShellCore`へdomain機能、`AIShellMCP`へprotocol変換を置く。MCP handlerへ開発ロジックを埋め込まない。
- 既存20 primitiveは互換経路・下位実装としてfull profileに残す。baseline fullは高密度5＋control 2＋legacy 18の25 tool、`expanded-v1` fullは高密度9＋control 2＋legacy 18の29 toolである。

## Tool / result規約

- stable MCP 2025-11-25を実装基準にし、structured resultはtop-level objectと`outputSchema`を持たせる。
- schema、tool順、descriptionは決定的にする。timestamp、cwd、runtime状態をdefinitionへ混ぜない。
- 通常結果は短いsummaryとprimary evidenceだけ。完全結果は`expires_at`付きhandleで保持する。
- 省略可能なread/search/run系高密度出力にbudgetを設け、`omitted`、`has_more`、cursor、freshnessを明示する。
- silent truncation、silent full-scan fallback、silent backend fallbackは禁止する。advertised retention中の一次証拠を削除しない。
- cursor失効、内容変更、index staleは機械判定可能なerrorにする。
- 新しい公開toolは、既存toolとの重複とbaseline比較を示してから追加する。

## 開発と検証

主な構成:

- `Sources/AIShellCore`: file/process/runtime/domain service
- `Sources/AIShellMCP`: stdio JSON-RPC / MCP adapter
- `Sources/AIShellRunSupervisor`: 直接起動したprocessの監視
- `Tests/AIShellCoreTests`: focused unit/integration tests
- `docs/`: 現役索引、診断contract、ADR/evidence、archive
- `rag/`: 調査統合、`rag/raw/`: 一次資料変換物

標準確認:

```text
swift test
npm run build:npm
```

変更中は対象focused testだけを回し、完了時に関連testを1回確認する。MCP wire変更ではinitialize、tools/list、成功・失敗resultのfixtureを確認する。docs/RAG/AGENTSだけの変更ではSwift testを回さず、リンク、Markdown、diffを確認する。

外部仕様を調べた場合は、取得日・出典・確度付きで`rag/raw/`へ保存し、統合記事と`rag/INDEX.md`を更新する。撤回済み資料やvendor効果量を製品根拠へ昇格させない。

## 文書規約

- 現役文書は`docs/README.md`に列挙する。同じ目的の文書はcontractに最も近い1文書へmergeする。
- 完了plan、release notes、handoff、置換済み設計は`docs/archive/`へ移す。ADRとevidenceは専用folderに保持する。
- archiveを現行操作の正本にしない。release作業の入口はREADMEとproduct-owned script、公開記録はGitHub Releasesを正とする。
