# AIShell 0.6.2

更新後のMCPが既存の編集鍵を読めないままsetupを成功扱いする問題を修正した。
`aishell-setup`は導入済みhelperで保存済み鍵のアクセスを確認し、必要な場合だけmacOSの認証を受ける。
認証後は別processの非対話読取りまで確認する。`--check`と通常のMCPは認証UIを開かない。

初回の保存directory作成前後で`/private/tmp`と`/tmp`の鍵accountが分かれる問題を修正した。
旧版の暗号化状態も既存鍵で認証して開き、別storeの鍵を上書きしない。
暗号化状態に対応する鍵がない場合は、新しい鍵を作らずに失敗を返す。

取引storeとclient registryの日時保存形式による精度差で、再起動時に期限の不一致を誤検出する問題を修正した。
保存されるepoch millisecondsで比較し、実際に異なる期限は引き続き拒否する。
