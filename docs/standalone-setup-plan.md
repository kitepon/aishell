# 製品単体setupの実装・公開計画

2026-09-10の依頼を正本とする。AIShell repoとAIShell所有の導入先だけを変更する。

## 受入

1. fetch、dirty、製品契約、公開packageの確認。開始時main=c3b934a、origin/mainと一致、dirty/stashなし。公開0.5.0、darwin/arm64、macOS 15+、install lifecycleなし。既存Node関連9試験成功。
2. 明示setup一回で対応判定、既存native管理アプリ準備、Claude/Codex/Grok/CursorのAIShell登録、読戻し、bareコマンドからMCP実操作を確認する。envと他設定を保持し、失敗は工程とtyped errorで返す。
3. 初回、再実行、更新、旧登録、設定保持、非対応、準備・登録失敗のfocused試験。別ベンダーによる公開契約の反証と親裁定。
4. 全文書点検、release gate、main統合、commit/push、npm/GitHub公開。AitermのSSHセッションで公式npm導入からsetup、MCP操作まで実行する。
5. 公開版、正規コマンド、実測対応、未実施、工場が撤去できる代行処理を報告する。

## 範囲と判断

- 症状: npm導入後の準備と登録を工場が補っている。状態の所有者: AIShell。導入・設定・診断を単体で所有する製品契約に従い、このrepoへ集約する。別ベンダーが境界と設定保持を反証する。
- F: 公開契約、設定保全、統合、公開、実端末への導入と受入。親が担当する。
- A: setupとfocused fixture。共通設定処理とMac準備が相互依存するため、同一writerで直列実装する。監査は書込み禁止で委譲する。
- H: 公開認証またはSSH接続先など、人の操作が必要な外部条件だけ。
- 統括理由: 受入が実装→公開→実端末導入へ連鎖し、境界変更の裁定証跡が必要。
- Windows/Linux開発、dotagents変更、自動常駐開始、他製品変更は含まない。共有AI設定への導入は他製品と重ねない。
- 既知の罠: bare起動時のbundle探索、npm更新で旧appが旧bundleを参照、env消失、TOML/JSON差、対応外への登録。

## 現在地

実装・focused試験・4AI公式CLIとMCPの隔離確認・別ベンダー反証を完了。
境界判断は[ADR 0031](adr/0031-standalone-setup.md)。Node 44件と正式な配布検証は成功。
ローカルの全体試験は2回とも569件中1件失敗し、失敗箇所はそれぞれ異なった。
両方とも単独再確認では再現していない。原因未確定の製品変更は行わず、
[検証証跡](evidence/standalone-setup-20260910.json)へ残した。mainの製品CIを確認して公開ゲートを判定する。

公開認証とSSH導入は未完了。npm認証がE401のため、公式ログイン画面での認証を依頼した。
localhostと127.0.0.1のSSHは接続拒否。main-serverはLinux/x86_64、windows-workstationはWindows/X64で対象外。
対応MacのSSH接続先と共有AI設定の更新が他製品と重ならない時間を問い合わせ中。
公開npm版をAitermのSSHセッションから導入する条件を保持し、ローカルの隔離試験で代替しない。
