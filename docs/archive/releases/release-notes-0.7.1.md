# AIShell 0.7.1

0.7.0で誤って削除した操作機能を復元しました。削除変更全体をrevertした後、認証と管理UIの廃止に変更を限定しています。

- workspace観測・変更待機、複数ファイル読取り、一括検索、影響解析、実行監視、artifact読取り、複数ファイル編集と基本OS操作を復元しました。
- 削除前の全tool名とprofileを維持します。管理画面用の`runtime_open_manager`は互換名を残し、`MANAGER_REMOVED`を返します。
- Keychainの読取り・書込みとsetupの認証画面を廃止しました。編集処理の内部鍵はOSユーザー専用の通常ファイルで管理します。
- 管理アプリと停止設定を廃止しました。旧`runtime.json`の状態にかかわらず操作できます。
- 使用ログは既存の`activity.jsonl`へ保存します。MCPと実行監視の実行ファイルを配布し、`aishell-open`は配布しません。
- 旧版の編集用ファイルが残る対象は破棄せずエラーを返します。未完了の編集がない対象は新しい状態で操作でき、旧暗号化履歴はそのまま残ります。詳細は`docs/setup.md`を参照してください。

更新は`npm install -g @quolu/aishell@latest && aishell-setup`で行います。既存AIセッションのMCPを再接続してください。

検証: npm test、npm run test:package、導入設定の35件が成功しました。配布packageの全tool名、Keychain API非依存、複数ファイル編集、直接実行と監視、UI不要の診断を確認しました。
