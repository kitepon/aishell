# ADR 0032: 製品単体setupの公開・実機受入

日付: 2026-09-10。状態: 受入済み。

[ADR 0031](0031-standalone-setup.md)の設計と別ベンダー反証に基づく実装を公開し、
[公開版のMac実機受入](../evidence/standalone-setup-public-mac-20260910.md)で
公式npm導入、4AI登録、再実行、診断、MCP実操作、工場診断が成立した。
当初のSSH指定はオーナーの明示指示でこのMacへの通常導入へ変更された。

公開commitは`03c7ba33e074016e9ca752fa6beacbad43dae50b`、公開版は0.6.0。
親は実装・公開・実機導入の受入連鎖を完了と判定する。
必要な操作契約と対応範囲は[setup契約](../setup.md)、調査知識は
[RAG](../../rag/standalone-setup-host-contracts.md)へ還流済み。
実装時のローカル全体試験の非再現失敗は証跡に保持し、原因未確定の修正を加えない。

工場は公開済みの製品入口を利用でき、AIShell内部の準備とAI登録の代行を外せる。
Windows/Linux登録の撤去を含む工場repoの変更は本受入に含めない。
