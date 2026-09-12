# 0.7.6

- snapshotの通常再取得で全ファイルの列挙と内容hashを繰り返す問題を修正した。稼働中の観測と保持された通知が連続する場合、既存の一覧へ実ファイルの差分を照合し、`checkpointState: "reconciled"`を返す。
- 重なったdirectory通知とrenameの照合で全索引・子孫を繰り返し探索する問題を修正した。削除後のmacOS物理パスも、存在する親から正規化して変更通知に残す。
- ファイル観測時に同じパスを何度も正規化する処理を減らした。restartのfilesystem照合と未変更hashの再利用を維持する。
- 通知欠落、保持範囲超過、root置換は引き続き再構築または明示エラーになる。出力予算によって観測範囲を狭めない。

実repoのcold・無変更warm・2file変更warm・restartと、削除・rename・同size同mtime変更の検証は`docs/evidence/workspace-snapshot-warm-20260913.md`に記録する。
