# AIShellへの変更

AIShellの責務は、AIが要求したOS操作の実行、結果とエラーの返却、使用ログの保存です。

- ファイル・process・他アプリの操作はSources/AIShellCore、MCP変換はSources/AIShellMCPへ置きます。
- 入力を黙って変更せず、出力を省略しません。制限を指定した場合は適用結果を返します。
- 管理UI、認証、編集履歴、復旧用の取引管理、監視・cacheを追加しません。
- 変更した操作をfocused testで確認し、最後にnpm testとnpm run test:packageを実行します。
- 文書だけの変更はnpm run test:repository-contractとdiffを確認します。
- 公開挙動の変更ではREADME、schema、fixture、release記録も更新します。

導入手順は[docs/setup.md](docs/setup.md)、公開手順は[README.md](README.md)を参照してください。
