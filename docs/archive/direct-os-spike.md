# Direct OS Spike 実装計画

更新日: 2026-07-19
対象: macOS 15以降、初期検証機 macOS 26.5.2

> 状態: 0.2.1で完了した技術スパイク。Direct OS基盤を継承した能力拡張campaignは[macOS直結・開発効率ランタイム 開発計画](development-efficiency-plan.md)で完結し、現行契約は[`AGENTS.md`](../../AGENTS.md)へ統合済み。下記「次の段階」のGUI/Accessibility案は置き換え済み。

## 目的

AIがshell、Terminal、AppleScript、JXA、任意コード実行を介さず、SwiftのmacOS APIを通してファイルとアプリを直接操作できる一本目の経路を完成させる。

## 今回の成功条件

- ネイティブ管理アプリから操作対象フォルダを選択できる。
- AIクライアントがMCP経由で、許可フォルダ内の一覧・検索・読取・作成・copy・move・rename・Trashを実行できる。
- AIクライアントがアプリの列挙・起動・前面化を実行できる。
- 初回スパイクではshell、AppleScript、JXA、任意プロセス実行を持たず、OS直接操作の経路を先に証明する。
- 管理アプリからAI操作を停止・再開できる。
- 管理アプリで直近の操作履歴を確認できる。
- 許可フォルダ外のファイル操作をfocused testで拒否できる。

## 構成

```text
AIクライアント
  └─ AIShellMCP（MCP stdio、形式変換のみ）
       └─ AIShellCore
            ├─ NativeFileService → FileManager / NSFileCoordinator
            ├─ NativeApplicationService → NSWorkspace
            └─ RuntimeStore → Application Support/AIShell

AIShell.app
  ├─ 操作対象フォルダの選択
  ├─ AI操作の停止／再開
  └─ 操作履歴の表示
```

MCPアダプターと管理アプリは同じ `AIShellCore` を使用する。ランタイム設定はユーザーのApplication Support内に置き、他ツールの管理領域には置かない。

## 最低限の安全策

- ファイル操作は管理アプリで選んだルート内だけ。
- symlink解決後もルート外へ出る操作を拒否する。
- 完全削除APIは公開せず、Trashだけを提供する。
- 管理アプリの停止状態を各操作直前に確認する。
- 操作名、対象、成否、時刻をローカル履歴へ残す。

## 初回スパイクでは作らないもの

- Accessibility、クリック、キーボード入力、画面認識
- 署名クライアント認証、期限付きgrant、細粒度policy
- root、LaunchDaemon、常駐特権helper
- ネットワーク通信、外部サービス操作
- 独自AIエージェントやモデル
- 配布・notarization・自動更新

## 開発ツール拡張（2026-07-19）

初回スパイク後の評価で、開発用途には既存ファイル編集とビルド／テスト実行が不足していると判断した。GUIは増やさず、MCPへ次を追加する。

- stat、SHA-256、再帰tree
- 競合検出付きの原子的テキスト更新
- 旧テキストを事前条件とする部分置換
- executable URLと引数配列をFoundationのprocess APIへ直接渡す実行
- working directory、環境変数、timeout、stdout、stderr、終了コード

process実行は開発能力として追加するが、`/bin/sh -c`、コマンド文字列の解析、パイプ、リダイレクト、shell展開は実装しない。これはTerminalやshellの操作ではなく、指定された実行ファイルをmacOSのprocess APIで直接起動する能力である。shell群、`env`、`osascript`のbasename拒否はこの製品境界を保つ設計レールであり、安全境界ではない。改名binaryや許可workerの子processまで阻止するものではない。

## 次の段階

この経路が実機で動いた後、ウインドウ観察、クリップボード、Accessibility、選択ウインドウの画面取得を一つずつ追加する。各段階で新しい直接操作能力を完成させ、安全機構だけの段階は作らない。

## 実装結果（2026-07-19）

- 完了: Swiftネイティブのファイル／アプリ操作コア
- 完了: 20操作を公開するMCP stdioアダプター
- 完了: フォルダ選択、停止／再開、履歴表示を持つmacOS管理アプリ
- 完了: `.app` 内へのMCP helper同梱とad-hoc署名
- 完了: Codex個人設定への `aishell` stdio MCP登録
- 完了: GitHub `kitepon-rgb/aishell` 公開と `@quolu/aishell@0.2.0` npm release
- 完了: npm global install後のnative MCPをCodex個人設定へ接続
- 検証済み: 一覧、検索、読取、フォルダ／テキスト作成、copy、move、rename
- 検証済み: `NSWorkspace`による実行中アプリ一覧をMCPから取得
- 検証済み: 停止中はファイル／アプリ操作を双方拒否
- 検証済み: parent traversalとsymlinkによる許可ルート脱出を拒否
- 検証済み: 既存ファイルを上書きしない
- 検証済み: stat、SHA-256、再帰tree、競合検出付き更新、旧テキスト事前条件付き置換
- 検証済み: `wc` と `swift --version` の直接実行、標準出力、終了コード
- 検証済み: timeout、許可ルート外working directory、shell本体のbasenameによる直接起動を拒否（製品上の設計レールであり、安全境界ではない）
- 未実機検証: Trash操作（実装・コンパイル済み。不要なTrash項目を増やさないため今回スキップ）

実機デモでは `DemoWorkspace` を許可ルートに設定し、MCP経由で作成したファイルを管理アプリの操作履歴へ反映した。検証終了時はAI操作を停止状態にした。

## 複数rootと停止時bootstrap（0.2.0）

- 単一root設定を複数root配列へ自動移行する。
- 絶対パスはいずれかの許可rootへ照合し、相対パスは先頭rootを基準にする。
- 管理アプリからrootを複数選択し、個別に追加・削除できる。
- `runtime_status` は停止中も複数root、基準root、次の操作を返す。
- `runtime_open_manager` は停止中も管理アプリを前面化する。
- 停止解除とroot変更は管理画面に残し、MCP自身には権限拡張を許さない。

## Git worktree自動認識（0.2.1）

- 設定rootがGitリポジトリなら `.git/worktrees/*/gitdir` をFoundationで直接読む。
- worktree側 `.git` との相互参照が一致し、worktreeが実在する場合だけ実効rootへ自動追加する。
- 未登録の兄弟フォルダや相互参照を偽装したフォルダは拒否する。
- `runtime_status` は `automaticGitWorktreePaths` と `effectiveAllowedRootPaths` を返し、AIへ手動追加が不要だと明示する。
