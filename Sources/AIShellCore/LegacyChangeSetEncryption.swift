import CryptoKit
import Foundation

/// 公開済みの暗号化記録を読むためだけの互換処理。鍵や暗号化記録は作らない。
enum LegacyChangeSetEncryption {
    private struct Envelope: Decodable {
        let nonce: Data
        let ciphertext: Data
        let tag: Data
    }

    static func key(in directory: URL) throws -> Data? {
        let url = directory.appendingPathComponent("state-key")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count == 32 else {
            throw ApplyChangeSetError(.changeSetSecretStoreUnavailable, "旧編集記録の鍵を読み取れません。")
        }
        return data
    }

    static func decode(_ data: Data, key: Data?, derived: Bool = false, aad: Data = Data()) throws -> Data {
        guard let key else {
            throw ApplyChangeSetError(.changeSetSecretStoreUnavailable, "旧暗号化記録を読む鍵がありません。既存データは保持しています。")
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let box = try AES.GCM.SealedBox(nonce: .init(data: envelope.nonce),
            ciphertext: envelope.ciphertext, tag: envelope.tag)
        let material = derived ? Data(SHA256.hash(data: key)) : key
        return try AES.GCM.open(box, using: SymmetricKey(data: material), authenticating: aad)
    }

    static func schema(_ data: Data) throws -> String? {
        (try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any])?["schema"] as? String
    }
}
