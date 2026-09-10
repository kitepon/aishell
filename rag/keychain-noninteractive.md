# file-based Keychainの非対話操作

取得日: 2026-09-10。確度: 高（SDK宣言、Apple実装、停止時sample、修正版の実測）。

AIShellの取引鍵は既存のmacOS file-based Keychainにある。Data Protection Keychainへ
無断で切り替えると既存鍵が見えなくなるため、待機障害の修理で保存先を変えない。

`SecItemCopyMatching`は同期的に呼出しthreadを止める。既存鍵のアクセス認証で待機する場合、
MCPのtransport timeoutは処理中止を保証しない。今回はprocessのsampleでservice初期化前の
Keychain読取りを特定し、そのprocessの消滅を確認して遅延実行を止めた。

file-based Keychainの非対話設定は`SecKeychainSetUserInteractionAllowed(false)`で行う。
このAPIはdeprecatedだが、既存のfile-based鍵の所有APIであり、鍵・ACL・保存先を変えずに
認証待ちを禁止できる。通常のMCPではprocess単位で一度だけ設定し、read/addの途中で再び許可しない。
修正版は同じ対象で524msで認証失敗を返した。これは認証の成功ではない。

Apple TN3127はad-hoc署名のDRが特定のcode版に結び付くと説明する。
本端末の既存鍵のACLに保存されたcdhashと更新後helperのcdhashも異なっていた。
したがって、非対話化だけでは更新後の鍵アクセス成立を保証できない。
明示setupの専用processだけで利用者の認証を受け、その後に別processの非対話readを確認する。
既存鍵を全appへ開放したり、署名identityを根拠なく置き換えたりしない。
一次資料の該当部分は[Apple TN3127抜粋](raw/apple-tn3127-ad-hoc-identity.md)に保存した。

出典:
- [SecItemCopyMatching](https://developer.apple.com/documentation/security/secitemcopymatching(_:_:))
- [macOS Keychainの実装区分](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
- [Apple SecItem.cpp](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_keychain/lib/SecItem.cpp)
- Xcode macOS SDKの`Security.framework/Headers/SecKeychain.h`と`SecItem.h`。
- [Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
