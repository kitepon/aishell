import CryptoKit
import Foundation
import Security

/// 導入済みhelper自身で、保存済み状態に対応する鍵へのアクセスを確認する。
/// 対話を許すのはsetupの専用processだけ。鍵の内容とACLは変更しない。
public enum ChangeSetKeychainPreparation {
    public struct Result: Codable, Sendable {
        public let ready: Bool
        public let checkedKeys: Int
    }

    public static func run(baseDirectory: URL, allowInteraction: Bool) throws -> Result {
        let configuration = SecKeychainSetUserInteractionAllowed(allowInteraction)
        guard configuration == errSecSuccess else { throw failure(configuration) }
        defer { SecKeychainSetUserInteractionAllowed(false) }
        let directory = baseDirectory.appendingPathComponent("apply-change-set", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return Result(ready: true, checkedKeys: 0)
        }
        let children = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]).sorted { $0.path < $1.path }
        var checked = Set<String>()
        for child in children where try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            var paths = [child.path, child.standardizedFileURL.path]
            if let resolved = realpath(child.path, nil) {
                paths.append(String(cString: resolved))
                free(resolved)
            }
            var found = false
            for path in Set(paths).sorted() {
                let account = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
                if checked.contains(account) { found = true; continue }
                let query: [CFString: Any] = [
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: "dev.kitepon.aishell.apply-change-set",
                    kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne
                ]
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                if status == errSecItemNotFound { continue }
                guard status == errSecSuccess else { throw failure(status) }
                guard let key = item as? Data, key.count == 32 else {
                    throw ApplyChangeSetError(.changeSetSecretStoreUnavailable, "保存済みのKeychain項目が32byteの鍵ではありません。")
                }
                checked.insert(account)
                found = true
            }
            if !found && FileManager.default.fileExists(atPath: child.appendingPathComponent("apply-change-set-state.enc.json").path) {
                throw ApplyChangeSetError(.changeSetSecretStoreUnavailable, "既存の暗号化状態に対応するKeychainの鍵がありません。")
            }
        }
        return Result(ready: true, checkedKeys: checked.count)
    }

    private static func failure(_ status: OSStatus) -> ApplyChangeSetError {
        ApplyChangeSetError(.changeSetSecretStoreUnavailable,
            "Keychainの読取りを確認できません（\(status)）。aishell-setupを実行し、macOSの認証画面で導入済みhelperのアクセスを許可してください。")
    }
}
