# AIShell 0.6.2

更新後のMCPが既存の編集鍵を読めないままsetupを成功扱いする問題を修正した。
`aishell-setup`は導入済みhelperで保存済み鍵のアクセスを確認し、必要な場合だけmacOSの認証を受ける。
認証後は別processの非対話読取りまで確認する。`--check`と通常のMCPは認証UIを開かない。

初回の保存directory作成前後で`/private/tmp`と`/tmp`の鍵accountが分かれる問題を修正した。
旧版の暗号化状態も既存鍵で認証して開き、別storeの鍵を上書きしない。
暗号化状態に対応する鍵がない場合は、新しい鍵を作らずに失敗を返す。

取引storeとclient registryの日時保存形式による精度差で、再起動時に期限の不一致を誤検出する問題を修正した。
保存されるepoch millisecondsで比較し、実際に異なる期限は引き続き拒否する。

`run_check` v2と`run_observe`が返す完全ログのhandleを、通常の`artifact_read`へ渡すと
`ARTIFACT_NOT_FOUND`になる配線漏れを修正した。range・tail・aroundと出力量制限を
共通の読取り処理へ接続し、別MCP processからも保存済みログを読める。
artifact索引にはrunと同じ保持期限を保存する。旧版が期限を省略した索引は、run所有の
保存済みretentionから期限を復元し、期限切れのログは拒否する。
