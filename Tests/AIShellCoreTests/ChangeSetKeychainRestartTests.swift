import CryptoKit
import Foundation
import Security
import XCTest
@testable import AIShellCore

final class ChangeSetKeychainRestartTests: XCTestCase {
    func testLegacyAliasKeyAuthenticatesExistingStateWithoutReplacingEitherKey() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let canonicalKey = Data(repeating: 17, count: 32)
        let legacyKey = Data(repeating: 29, count: 32)
        try fixture.addKey(canonicalKey, path: fixture.state.standardizedFileURL.path)
        try fixture.addKey(legacyKey, path: fixture.state.path)
        try fixture.writeSnapshot(key: legacyKey)
        let original = try Data(contentsOf: fixture.snapshot)
        let store = try ApplyChangeSetSecretStore(baseDirectory: fixture.base, stateDirectory: fixture.state, root: fixture.root)
        let proof = try store.issueOwnerProof(controlRequestID: "fixture", action: .allocate,
            root: fixture.root, expiresAt: Date().addingTimeInterval(60)).split(separator: ".")
        let payload = try XCTUnwrap(Data(base64Encoded: String(proof[0])))
        XCTAssertEqual(Data(base64Encoded: String(proof[1])),
            Data(HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: legacyKey))))
        XCTAssertEqual(try Data(contentsOf: fixture.snapshot), original)
        XCTAssertEqual(try fixture.readKey(path: fixture.state.standardizedFileURL.path), canonicalKey)
        XCTAssertEqual(try fixture.readKey(path: fixture.state.path), legacyKey)
        let checked = try ChangeSetKeychainPreparation.run(baseDirectory: fixture.base, allowInteraction: false)
        XCTAssertEqual(checked.checkedKeys, 2)
        XCTAssertTrue(checked.ready)
    }

    func testMissingKeyForEncryptedStateFailsWithoutCreatingReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeSnapshot(key: Data(repeating: 29, count: 32))
        XCTAssertThrowsError(try ApplyChangeSetSecretStore(baseDirectory: fixture.base, stateDirectory: fixture.state, root: fixture.root)) {
            XCTAssertEqual(($0 as? ApplyChangeSetError)?.code, .changeSetSecretStoreUnavailable)
        }
        XCTAssertThrowsError(try ChangeSetKeychainPreparation.run(baseDirectory: fixture.base, allowInteraction: false))
        XCTAssertNil(try fixture.readKey(path: fixture.state.path))
        XCTAssertNil(try fixture.readKey(path: fixture.state.standardizedFileURL.path))
    }

    private struct Fixture {
        let base = URL(fileURLWithPath: "/private/tmp/aishell-key-restart-\(UUID().uuidString)", isDirectory: true)
        var root: URL { base.appendingPathComponent("root", isDirectory: true) }
        var state: URL { base.appendingPathComponent("apply-change-set/fixture", isDirectory: true) }
        var snapshot: URL { state.appendingPathComponent("apply-change-set-state.enc.json") }

        init() throws {
            XCTAssertEqual(NoninteractiveKeychain.configure(), errSecSuccess)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            XCTAssertNotEqual(state.path, state.standardizedFileURL.path)
        }

        func query(path: String) -> [CFString: Any] {
            [kSecClass: kSecClassGenericPassword, kSecAttrService: "dev.kitepon.aishell.apply-change-set",
             kSecAttrAccount: SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()]
        }

        func addKey(_ key: Data, path: String) throws {
            var query = query(path: path)
            query[kSecValueData] = key
            XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)
        }

        func readKey(path: String) throws -> Data? {
            var query = query(path: path)
            query[kSecReturnData] = true
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            XCTAssertEqual(status, errSecSuccess)
            return try XCTUnwrap(item as? Data)
        }

        func writeSnapshot(key: Data) throws {
            let payload: [String: Any] = [
                "schema": "aishell.apply-change-set-core-state.v1",
                "rootPath": root.standardizedFileURL.resolvingSymlinksInPath().path,
                "generation": "fixture", "head": 0, "capabilities": [], "reservations": [:],
                "tamperedReservations": [], "orphanPins": [:], "targetMutationReceipts": 0,
                "legacyExpired": false, "legacyReused": false
            ]
            let schema = "aishell.apply-change-set-state-envelope.v1"
            let box = try AES.GCM.seal(JSONSerialization.data(withJSONObject: payload),
                using: SymmetricKey(data: key), authenticating: Data(schema.utf8))
            try JSONSerialization.data(withJSONObject: ["schema": schema,
                "nonce": Data(box.nonce).base64EncodedString(), "ciphertext": box.ciphertext.base64EncodedString(),
                "tag": box.tag.base64EncodedString()]).write(to: snapshot)
        }

        func cleanup() {
            for path in Set([state.path, state.standardizedFileURL.path]) { SecItemDelete(query(path: path) as CFDictionary) }
            try? FileManager.default.removeItem(at: base)
        }
    }
}
