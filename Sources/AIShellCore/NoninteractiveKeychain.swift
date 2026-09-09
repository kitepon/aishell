import Security

/// 取引用のfile-based Keychainは、バックグラウンド要求で認証UIを待たない。
/// Data Protection Keychain用のquery optionは既存のfile-based項目には効かないため、
/// その所有APIでprocessの非対話方針を一度だけ設定する。鍵・ACL・検索先は変えない。
enum NoninteractiveKeychain {
    private static let configurationStatus = SecKeychainSetUserInteractionAllowed(false)

    static func configure() -> OSStatus { configurationStatus }
}
