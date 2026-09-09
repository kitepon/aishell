# file-based Keychainの非対話操作

取得日: 2026-09-10。確度: 高（SDK宣言、Apple実装、停止時sample、修正版の実測）。

AIShellの取引鍵は既存のmacOS file-based Keychainにある。Data Protection Keychainへ
無断で切り替えると既存鍵が見えなくなるため、待機障害の修理で保存先を変えない。

`SecItemCopyMatching`は同期的に呼出しthreadを止める。既存鍵のアクセス認証で待機する場合、
MCPのtransport timeoutは処理中止を保証しない。今回はprocessのsampleでservice初期化前の
Keychain読取りを特定し、そのprocessの消滅を確認して遅延実行を止めた。

file-based Keychainの非対話設定は`SecKeychainSetUserInteractionAllowed(false)`で行う。
このAPIはdeprecatedだが、既存のfile-based鍵の所有APIであり、鍵・ACL・保存先を変えずに
認証待ちを禁止できる。process単位で一度だけ設定し、read/addの途中で再び許可しない。
修正版は同じ対象で524msで認証失敗を返した。これは認証の成功ではない。

出典:
- [SecItemCopyMatching](https://developer.apple.com/documentation/security/secitemcopymatching(_:_:))
- [macOS Keychainの実装区分](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
- [Apple SecItem.cpp](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_keychain/lib/SecItem.cpp)
- Xcode macOS SDKの`Security.framework/Headers/SecKeychain.h`と`SecItem.h`。
