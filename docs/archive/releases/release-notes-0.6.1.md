# AIShell 0.6.1

atomic編集の取引鍵をKeychainから取得する際、認証UIの待機でMCPが返答しなくなる問題を修正した。
既存file-based Keychainの認証が必要な場合は、待機せず`CHANGE_SET_SECRET_STORE_UNAVAILABLE`を返す。
鍵、ACL、保存先は変更しない。

取引開始前の鍵取得失敗では、structured errorに`request_status: aborted_before_side_effect`、
空の`changed_paths`、`next_action: authorize_keychain_access_then_retry`を返す。
これは当該要求が編集を開始しなかったことを示し、過去取引の復旧状態を推定しない。

状態保存先が`/private/tmp`などの別名パスの場合も、台帳と同じ正規形で旧世代を照合する。
同じ保存先の状態ファイルを新旧2世代とも有効として記録し、整合性検査に失敗する問題を修正した。
