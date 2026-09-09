# atomic編集のKeychain待ち修理

2026-09-10。工場担当から、公開0.6.0の6ファイル編集が300秒でtransport timeoutとなり、
結果が確定しない問題を受領した。所有範囲はAIShellだけ。

PID 35816の2回のsampleで、service初期化中の`SecItemCopyMatching`が停止点と確認した。
`ApplyChangeSetState`生成・bootstrap・applyManagedより前。TERMで終了しなかったためKILLし、
`ps`で消滅を確認。要求の遅延実行は停止した。対象6ファイルの差分は工場担当のapply_patchによるもの。

修理はmacOSの既存file-based Keychainに対する非対話操作だけ。鍵の保存先、ACL、暗号化、
既存鍵を変更しない。Security APIが認証を要求する場合はtyped errorと当該要求の適用前中止を返す。
focused試験、MCP実測、release gate、公開、公開版smokeまで行う。工場のファイルは変更しない。
