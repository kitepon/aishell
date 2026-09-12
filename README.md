# AIShell

AIがmacOSを直接操作するためのMCPです。ファイル操作、プログラム実行、アプリ操作を受け付け、結果とエラーを返します。使用ログを保存します。

対応環境はApple SiliconのMac、macOS 15以降です。

## 導入・更新

~~~sh
npm install -g @quolu/aishell@latest
aishell-setup
~~~

aishell-setupは導入済みのClaude Code・Codex・Grok Build・Cursorを検出し、MCP登録、設定の読戻し、ファイルの書込み・読取り・プログラム実行を確認します。対象を指定する場合は次のように実行します。

~~~sh
aishell-setup --ai codex
aishell-setup --check
~~~

管理画面やキーチェーン認証はありません。既存のAIセッションはMCPを再接続するか、新しいセッションへ切り替えてください。詳細は[導入契約](https://github.com/kitepon/aishell/blob/main/docs/setup.md)を参照してください。

手動登録は実行コマンドをaishell-mcp、引数を空にします。profileやcapabilityの設定は不要です。

## できる操作

| 対象 | ツール |
|---|---|
| ファイルの一覧・検索・読取り・情報取得 | files_list、files_search、files_read_text、files_stat、files_tree |
| ファイルの作成・書込み・部分置換 | files_create_directory、files_create_text、files_write_text、files_replace_text |
| ファイルのコピー・移動・改名・Trash移動 | files_copy、files_move、files_rename、files_trash |
| 他のアプリの一覧・起動・前面化 | apps_list_running、apps_list_installed、apps_open、apps_activate |
| プログラムの直接実行 | process_run |

絶対パスは指定した場所、相対パスと省略時はMCPを起動したディレクトリを使います。フォルダの事前登録は不要です。

files_write_textは指定内容をそのまま書き込みます。expected_sha256を指定した場合だけ、既存内容の一致を確認します。files_create_textとコピー・移動は既存項目を上書きしません。

files_listは隠しファイルを含みます。files_searchとfiles_treeのlimit、files_treeのmax_depthは省略すると制限しません。件数を制限した結果にはhasMoreを返します。検索はファイル名の部分一致です。

process_runは実行ファイル、引数配列、作業ディレクトリ、環境変数、stdinを直接渡します。shell展開は行いません。timeout_secondsは指定時だけ適用します。終了コードと完全なstdout・stderrを返し、UTF-8として読めない出力はbase64と明示します。

~~~json
{
  "executable": "/usr/bin/printf",
  "arguments": ["%s", "$HOME; * はそのまま渡る"],
  "timeout_seconds": 10
}
~~~

MCPはstdio、protocol 2025-11-25を使います。結果はstructuredContentのobjectで返し、入力不正・OSエラー・非0終了はisErrorで区別します。実行中の要求はMCPのキャンセル通知で中止できます。

## 使用ログ

通常は次のファイルへ日時、操作名、対象、成功・失敗を追記します。

    ~/Library/Application Support/AIShell/activity.jsonl

AISHELL_STATE_DIRECTORYを設定した場合はそのディレクトリへ保存します。ファイル内容、環境変数、編集前のコピーは保存しません。ログ保存に失敗した場合は、操作の実結果とlogging_errorを返します。

旧版の停止設定、暗号化された編集記録、キーチェーン項目を読み取る処理はありません。使用ログは同じ保存先を引き継ぎます。

## 開発・公開

実装はSources/AIShellCore、MCP変換はSources/AIShellMCPに置きます。SwiftPMでbuildします。

~~~sh
swift build --product aishell-mcp
npm test
npm run test:package
~~~

配布物はdist/aishell-mcpと登録用scriptです。npm install時にscriptを起動しません。

公開時はSources/AIShellCore/Product.swiftとpackage.jsonのversionを揃え、[公開記録](https://github.com/kitepon/aishell/tree/main/docs/archive/releases)を追加します。検証後に既定ブランチへcommitを着地させ、次を実行します。

~~~sh
git fetch origin
npm run verify:release-commit
npm whoami
npm publish --access public --browser=false
~~~

npmが公開認証を要求した場合は、対話端末に表示された新しいURLで認証します。公開後はGitHub Releaseを作成し、通常のnpm更新とaishell-setup、aishell-setup --checkで配布版を確認します。

[文書索引](https://github.com/kitepon/aishell/blob/main/docs/README.md)・[開発への参加](https://github.com/kitepon/aishell/blob/main/CONTRIBUTING.md)・[脆弱性報告](https://github.com/kitepon/aishell/blob/main/SECURITY.md)

## ライセンス

[Apache License 2.0](LICENSE)
