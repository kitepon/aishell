# ADR 0027: Phase 7受入

- Status: accepted
- Date: 2026-07-24
- Lattice plan: `aishell-capability-expansion`
- Lattice phase: `phase-7`

## Decision

Phase 7「product gate・知識還流」を受け入れる。代表ベンチ288試行（3 arm × 32 task × 3
repetition）は重複なく完走し、製品ゲート4条件をすべて満たした。

| 条件 | 実測 | 判定 |
| --- | --- | --- |
| baseline成功taskを落とさない | 退行 vs native / vs 0.3.3: なし | pass |
| tokens per solved task 30%以上削減 | 51.20%削減（対native） | pass |
| p50非悪化 | 42,044.5 <= 51,173 ms | pass |
| p95悪化10%以内 | 110,968.75 <= 261,926.5 ms | pass |
| silent fallback 0 | 禁止テレメトリ7項目合計0 | pass |

解決taskは candidate 25 / native 18 / current-0.3.3 15。

集計は baseline 2 arm 192試行と候補87試行がv10（0.3.4系候補）の記録、候補9試行が0.3.5での
再実行という混成である。9件は「`apply_change_set`を実際に呼ぶ全候補試行」という機械的基準で
選び、v10で成功していた3件も含めて全再実行した。候補87試行は`apply_change_set`を呼ばず、
tool catalog digestが修正前後で一致（`a7fb8c...`）するため流用が成立する。

ベンチはゲート判定のほかに製品欠陥1件を実際に検出・修正させた（`apply_change_set`が適用後の
内容を返さず、冗長な`result="applied"`が結論の顔をしていた→0.3.5で修正、該当9試行3/9→9/9）。
知識還流として、この欠陥分析・修正・release notesを`docs/`へ、一般化した設計知見を
`rag/side-effect-tool-result-state.md`（副作用型toolは結果状態を返す）へ、修正済み0.3.5をnpmへ還流した。

出荷物そのものの挙動も確認済みである。global installした`/opt/homebrew/bin/aishell-mcp`へ実際の
`apply_change_set`を投げ、`after_content="A2\n"`が返り per-change `result`が非存在であること、
実ファイルが更新されることを確認した（`docs/evidence/2026-07-24-phase-7-full-regression.md`）。

## Audit

policy `dotagents-heavy-v1`に従い、受入主張5件（288完走とcheckpoint一致・検証器変更の健全性・
混成集計の明記と9件選定の機械性・ゲート数値・0.3.5公開）を独立の敵対的監査で検証した。
監査者はcheckpoint/result一致をプログラムで確認し、ゲート数値を自前実装で再計算して全値一致、
「solved候補にnull adapter traceは0件」を実データで確認した。総合判定は妥当。

監査が記録した弱点と処置:

- 再実行9件の証拠が`/private/tmp`のみ → OS再起動で消えない
  `benchmarks/results/representative-production-20260723-v10/rerun-0.3.5/`へ probe-B.json
  （SHA256 `2c8d264f3c8e0dcb19f52df37d598357b749644631beda86546f6c9872e4831a`）とconfig.jsonを
  退避した。`benchmarks/results/`はv10 run本体（checkpoint 438MB）と同じくgit管理外の
  ローカル保全領域であり、git内の照合点は本ADRのSHA256と証拠文書の数表である。
- v10 attempt directoryはbaseline 2 armの先頭5 task分32件が欠落している。全288件の一次証拠
  （providerTrace/providerSSE/agentResult）は同ディレクトリのcheckpoint.jsonがbase64で内包する
  ため判定に影響しない。
- 集約段不変条件のend-to-end負テストは未整備（単体テストと実データ負検証のみ）。フォロー候補。

## Evidence

- `docs/evidence/2026-07-24-ace-070-representative-benchmark.md`
- `docs/evidence/2026-07-24-ace-071-product-gate.md`
- `docs/evidence/2026-07-23-ace-072-final-product-gate.md`
- `docs/evidence/2026-07-23-ace-073-release-finalization.md`
- `benchmarks/results/representative-production-20260723-v10/run/result-reassembly-receipt.json`
- `benchmarks/results/representative-production-20260723-v10/rerun-0.3.5/probe-B.json`
- `docs/archive/releases/release-notes-0.3.5.md`

## Consequences

aishell-capability-expansion campaignの全8 Phaseが受理され、campaignは完結する。0.3.5が
公開版であり、以後の測定は0.3.5を新baselineとする。単一バイナリでの通し288再測定は行わず、
次に代表ベンチを回す時（新機能のgate時）に0.3.5系で通しを取る。
