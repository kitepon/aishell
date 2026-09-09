# 製品単体setupの公開前CI

2026-09-10、実装commit `03e961bfb6fcde3e48696f7b8d7be4b4380c655d` の
[製品CI](https://github.com/kitepon/aishell/actions/runs/34376576245)が成功した。
所有境界、変更分類、`macos-native`の依存導入・製品full test・配布bundle作成を通過。
Mac jobの所要時間は5分48秒。公開前の技術検証を受け入れる。

[ローカル検証証跡](standalone-setup-20260910.json)にある2回の全体試験失敗は取り消さない。
失敗箇所はいずれも単独再確認で再現せず、原因未確定の変更は行っていない。
本CIの成功を、公開npm版のSSH導入確認の代わりにはしない。

npm認証はE401からの再認証待ち、対応MacのSSH接続先と共有AI設定の導入時間は未確認。
公開、GitHub Release、公開npm版のSSH導入、公開後smokeは未完了。
検証用の管理アプリは終了し、既存の公式npm導入先の管理アプリへ戻した。
実利用の共有AI設定と他repositoryは変更していない。
