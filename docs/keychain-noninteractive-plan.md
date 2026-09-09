# atomic編集のKeychain待ち修理

2026-09-10。工場担当から、公開0.6.0の6ファイル編集が300秒でtransport timeoutとなり、
結果が確定しない問題を受領した。所有範囲はAIShellだけ。

PID 35816の2回のsampleで、service初期化中の`SecItemCopyMatching`が停止点と確認した。
`ApplyChangeSetState`生成・bootstrap・applyManagedより前。TERMで終了しなかったためKILLし、
`ps`で消滅を確認。要求の遅延実行は停止した。対象6ファイルの差分は工場担当のapply_patchによるもの。

修理はmacOSの既存file-based Keychainに対する非対話操作だけ。鍵の保存先、ACL、暗号化、
既存鍵を変更しない。Security APIが認証を要求する場合はtyped errorと当該要求の適用前中止を返す。
focused試験、MCP実測、release gate、公開、公開版smokeまで行う。工場のファイルは変更しない。

## 現在地

修理commit `0209f9a4883c58c23d31ee590ad1c23e46227eed` をmainへpushした。
Keychain方針1件、atomic編集wire7件、旧互換store14件のfocused試験と文書検査が成功。
[CI](https://github.com/kitepon/aishell/actions/runs/34418082684)のMac全体試験・配布検証も成功。
修正版MCPは同じ対象の鍵取得失敗を524msで返し、`request_status: aborted_before_side_effect`、
空の`changed_paths`を確認した。

このMacの既定Keychainは`SecKeychainGetStatus`がflags=2（unlock bitなし）を返した。
6ファイル正常系の実バイナリ試験は鍵の新規保存が-25293で即時失敗し、適用前中止を返した。
これは正常系成功とは数えない。オーナーのKeychain解除を依頼し、解除後に公開版で確認する。
npm 0.6.1は公開用の追加認証待ち。認証、公開、公開版導入・smokeは未完了。
