# ADR 0030: 操作対象フォルダの登録と範囲制限を廃止

- 決定日: 2026-09-05
- 状態: 採用済み（0.5.0）
- 根拠: オーナーの削除指示、`PathResolver`・`RuntimeConfiguration`の実装、公開版MCPの実測

## 決定

操作対象フォルダの事前登録、許可一覧、その範囲に基づく拒否を廃止する。macOSのアクセス権で操作できるパスを直接指定できる。管理アプリは停止・再開と操作履歴を提供する。

絶対パスはその対象へ、相対パスと省略時はMCP起動ディレクトリへ解決する。既存パスと作成先の既存祖先はsymlinkを解決する。Git worktreeの事前登録や許可root familyの照合は行わない。

## 状態と操作境界

- Runtime設定は`isPaused`と`updatedAt`だけを保持する。設定ファイルなしで利用できる。
- 旧`allowedRootPath`・`allowedRootPaths`は読み取り時に無視し、次の保存時に除去する。旧登録先が存在しなくても起動できる。壊れたJSONは診断エラーとして扱う。
- `runtime_status`は`relativePathBase`、`isPaused`、`updatedAt`、`managerTool`、`nextAction`を返す。
- 設定schemaは`aishell.runtime_configuration.v3`。工場診断schemaはv1を維持し、旧root件数は0を返す。
- snapshot・検索・profileの対象はrequestで指定したworkspaceを基準にする。cursorやtransactionの対象workspaceとの照合は引き続き行う。
- 停止、Trash、SHA競合検出、`.aishell-transactions`の内部領域保護は維持する。フォルダ登録の廃止は操作ごとのworkspace境界を廃止するものではない。

## 旧文書との関係

以前のADRにある許可rootの登録・選択・包含チェック・Git worktree自動許可、および設定rootを相対パスの基準とする記述を本決定で置き換える。特にADR 0028の「allowed rootは安全性の土台」という判断は撤回する。旧ADRのそれ以外の契約と当時の検証記録は保持する。

公開操作は[README](../../README.md)、診断は[factory-diagnostics](../archive/factory-diagnostics.md)を参照する。

## 公開・検証記録

- 対象commit: `32dbfef038bfb4200882e215a62ff292d27f1dc5`。`main`へpush後に公開した。
- Swift test 568件、repository contract 8件、package検証が成功した。
- `@quolu/aishell@0.5.0`のnpm公開が成功し、registryからグローバルインストールした。
- 公開版でinitialize、expanded-v1の11 tool、旧登録先の無視、未登録フォルダの検索・直接実行、エラー応答、工場診断を確認した。
- 管理アプリでフォルダ登録UIの撤去と停止・再開・履歴の表示を確認した。
- 公開記録: [GitHub Release v0.5.0](https://github.com/kitepon/aishell/releases/tag/v0.5.0)。
