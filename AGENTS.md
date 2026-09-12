# AIShell project instructions

## 製品目的

AIShellは、AIがshellを介さずmacOSのOS操作を直接呼び、入力に対応した結果を受け取るためのMCPです。製品の責務は、要求された操作の実行、正確な結果・エラーの返却、使用ログの保存だけです。

2026-09-12のオーナー指示により、管理UI、キーチェーン認証、編集取引・復旧記録、所有者認証、workspace監視、checkpoint、独自cache、artifact管理、自動的な試験選択、専用診断とprofileを廃止しました。過去の計画・ADR・調査に記載されたこれらの機能を現行要件として復活させません。

## 実装

- Sources/AIShellCoreはファイル、process、他アプリの直接操作と使用ログを所有します。
- Sources/AIShellMCPはstdio JSON-RPC / MCP変換だけを所有します。
- 実行中の要求に必要な一時状態だけを持ちます。完了した編集やprocessを再実行・復旧する仕組みは持ちません。
- shell文字列を自動評価せず、実行ファイル、引数、作業directory、環境変数、標準入力を分離して渡します。指定された実行ファイルを名前で禁止しません。
- 絶対パスは指定した対象、相対パスと省略時はMCP起動directoryを使います。操作範囲はmacOSのアクセス権に従います。
- 値の黙った補正、出力の黙った省略、失敗の成功扱いをしません。任意の件数・深さ・時間制限は呼出しで指定された場合だけ適用します。
- 使用ログはactivity.jsonlへ追記します。内容・環境変数・復旧用コピーを保存しません。
- AIのreasoning、工程、thread、compaction、子agent、汎用PTYを再実装しません。

## 開発と配布

公開契約とrelease手順はREADME.md、登録手順はdocs/setup.md、文書索引はdocs/README.mdを参照します。旧設計はdocs/archive・docs/adr・docs/evidenceとragに履歴として残します。

変更中は対象のfocused testだけを実行し、個別確認後にnpm testとnpm run test:packageを実行します。MCPの変更はinitialize、tools/list、成功・失敗応答を確認します。文書だけの変更ではSwift testを実行しません。

配布物はdist/aishell-mcpと明示的なaishell-setupです。GUIアプリと常駐supervisorは配布しません。npm install lifecycleでprocessや認証画面を起動しません。

製品は本repo内でbuild、test、公開できる状態を保ちます。他製品の内部状態や運用を代行しません。新機能は、要求されたOS操作を正確に実行して返すために必要なものだけを採用します。
