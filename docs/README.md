# AIShell documentation map

このファイルはAIShell文書の唯一の現役索引である。AIShellは単独でinstall、設定、
状態管理、診断、復旧、更新、releaseでき、その契約は本repository内だけで完結する。
dotagentsは公開contractを使って製品横断wireと互換性を統合するが、AIShellの内部状態や
運用判断を所有・制御しない。

## 現役文書

- [../README.md](../README.md): 公開概要、install/update、接続、通常運用、制限、release入口。
- [../README.ja.md](../README.ja.md): 日本語版の公開概要と運用入口。
- [../AGENTS.md](../AGENTS.md): 製品目的、設計境界、開発・文書規約。
- [../CONTRIBUTING.md](../CONTRIBUTING.md): 変更提案、開発確認、文書更新の手順。
- [../SECURITY.md](../SECURITY.md): セキュリティ報告と操作境界。
- [../rag/INDEX.md](../rag/INDEX.md): 外部調査と実測の索引。
- [adr/0030-folder-registration-removal.md](adr/0030-folder-registration-removal.md): フォルダ登録廃止と旧設計資料の適用範囲。
- [factory-diagnostics.md](factory-diagnostics.md): 製品所有のnative factory diagnostics contract。
- [adr/](adr/): 恒久的な設計判断と受入記録。
- [evidence/](evidence/): 検証証跡。通常の実装・運用では読み込まず、判断根拠の追跡時だけ参照する。

## 履歴

- [archive/](archive/): 完了planと置換済み設計資料。
- [archive/development-efficiency-plan.md](archive/development-efficiency-plan.md): 全Phase受入済みの能力拡張campaign履歴。現行のnorth starと設計境界は`AGENTS.md`へ統合済み。
- [archive/releases/](archive/releases/): 過去のrelease notes。公開済みversionの外部正本はGitHub Releasesである。

archiveとevidenceは当時の説明・実測であり、現行挙動の正本ではない。許可rootに関する旧記録は[ADR 0030](adr/0030-folder-registration-removal.md)で置き換えられた。数値・エラー・当時の判断は履歴として保持する。

## 文書の寿命

- 現役文書はこの索引に列挙し、1つの目的を1文書が所有する。
- 同じ意味の現役文書は、対象contractに最も近い文書へmergeして全参照を更新する。
- 完了plan、release notes、handoff、置換済み設計は`archive/`へ移す。
- ADRとevidenceは履歴として保持するが、現在の操作手順をそこへ置かない。
- install、config、state/schema、migration、diagnostics、recovery、update、releaseは
  AIShell自身が所有し、dotagentsには製品横断の接続情報だけを置く。
