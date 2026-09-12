# RAG Index

Keychainに関する資料は旧実装の履歴。現行版はKeychainを使わず、更新契約は[docs/setup.md](../docs/setup.md)を正とする。
- [file-based Keychainの非対話操作](keychain-noninteractive.md) — 認証UI待ちの停止点、既存鍵を移行せず待機を禁止するAPI、ad-hoc更新時のidentityとsetupでの認証確認（2026-09-10、確度: 高）

- [明示setupとAI設定の確認](standalone-setup-host-contracts.md) — Claude/Codex/Grokの専用home読戻し、CursorがCURSOR_HOMEを参照しない実測と公式設定場所（2026-09-10、確度: 高）

- [GitHub公開repository設定](github-public-repository-settings.md) — private vulnerability reportingのAPI契約とSocial previewのUI制約・受入方法を記録（2026-07-19、確度: 高）
- [GitHub Actions macOS CI選定](github-actions-macos-ci.md) — 初回CIの選定履歴と、GitHub管理Macを使うnpm自動公開jobの実測（2026-09-12更新、確度: 高）
- [AIShell macOS直結・開発効率ランタイム調査](development-efficiency-runtime.md) — Direct OS状態所有を根にした5 toolを実装。同一candidate 3×3 sentinelは両arm 9/9、token/solved task 25.86%減・平均wall 32.59%減（2026-07-19、確度: 中〜高）
- [macOS向けAI OSランタイム 初期機能調査 v0.2](macos-ai-os-runtime/research-synthesis.md) — Apple/MCP/OpenAI公式仕様、既存実装、macOS/OS操作ベンチマーク、安全性研究から初期採用・初期除外・受入条件を導出し、能力優先の製品判断を追記（2026-07-19、確度: 中〜高）
- [AIShellをCodexの別タスクへ公開する](codex-mcp-registration.md) — npm版stdio MCP登録、expanded-v1 11 tool、typed startup failure、フォルダ登録廃止後のパス解決、lane分離、0.4.8〜0.4.11のClaude互換・検索既定／性能／file scope実測（2026-09-06更新、確度: 高）
- [AIShell開発利用adoption監査](development-adoption-audit-2026-08-04.md) — Claude schema拒否、Aiterm MCP隔離、許可root、Codex profile drift、検索既定／file scope、全体routing、狭い検索costを全session・全project横断で分離し、修理境界を固定（2026-08-04、確度: 中〜高）
- [副作用型toolは結果状態を返す](side-effect-tool-result-state.md) — 書き換え系toolが状態語だけを返すと呼び出し側が結果を復元できず報告が劣化する。代表ベンチで実測した失敗と、結果状態を返す設計への修正（apply_change_set 0.3.5・run_observe 0.3.6）（2026-07-24、確度: 高）
- [AIShell npm配布判断](npm-distribution.md) — install lifecycle不採用の実測、公開時の2FA、Trusted Publishingの要件と自動公開の実測（2026-09-12更新、確度: 高）
- [起動中のmacOS appをupgradeで差し替えると無言で壊れる](macos-app-upgrade-window-staleness.md) — npmのrename退避で消えたbundleを掴んだ窓はNSOpenPanelだけ無反応になる。実体identityによる3状態検知と、install側警告を正にしない理由（2026-07-25、確度: 高）
- [FSEvents永続checkpointの連続性](fsevents-persistent-checkpoint-continuity.md) — volume UUID、event ID巻戻り、drop、scan中eventをfail-closedなwarm restore契約へ反映（2026-07-21、確度: 高）
- [FSEvents device timestamp boundaryの実測制約](fsevents-device-boundary-observation.md) — timestamp検索の6秒超遅延と、UUID＋processed callback IDを永続cursorに使う判断（2026-07-21、確度: 高）
- [Codex provider SSE観測](codex-provider-sse-observability.md) — requested modelを使わずprovider WebSocket受信frameからactual modelを証明し、MCP original wire bytesと分離して保持する（2026-07-22、確度: 高）
