# 0.7.4

## 修正

- snapshot後にfilesystem通知を受けてからsearch_contextを使うと、検索開始処理が保持中の変更履歴を破棄し、先のcursorをCURSOR_EXPIREDにしていた問題を修正した。
- 検索後も変更履歴と照合結果を保持する。実変更がない通知だけなら元のcursorで編集を続けられ、実変更が残る場合はWORKSPACE_CHANGEDで拒否する。
- 管理UI・Keychain認証の廃止と工場向け診断schemaは維持する。

## 検証

- 修正前にcursor失効を再現するfocused testが失敗し、修正後に成功した。workspace状態の関連テストも成功した。
- 隔離repoの公開MCP呼出しでsnapshot、読取り、検索、4ファイル編集を確認した。別processのfactory診断を挟んだ継続編集も成功した。
