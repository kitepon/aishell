import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import AIShellCore

final class LocalChangeSetKeyTests: XCTestCase {
    func testKeyIsSharedAcrossConcurrentStartsAndPathAliases() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let keys = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<8 { group.addTask { try LocalChangeSetKey.loadOrCreate(in: base, encryptedStateExists: false) } }
            var keys: [Data] = []
            for try await key in group { keys.append(key) }
            return keys
        }
        XCTAssertEqual(Set(keys).count, 1)
        XCTAssertEqual(keys[0].count, 32)
        XCTAssertEqual(try LocalChangeSetKey.loadOrCreate(in: base.resolvingSymlinksInPath(), encryptedStateExists: true), keys[0])
        let info = try FileManager.default.attributesOfItem(atPath: base.appendingPathComponent(LocalChangeSetKey.filename).path)
        XCTAssertEqual((info[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testMissingKeyDoesNotReplaceEncryptedState() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let snapshot = base.appendingPathComponent("apply-change-set-state.enc.json")
        try Data("旧版の暗号化記録".utf8).write(to: snapshot)
        XCTAssertThrowsError(try LocalChangeSetKey.loadOrCreate(in: base, encryptedStateExists: true)) {
            XCTAssertEqual(($0 as? ApplyChangeSetError)?.code, .changeSetSecretStoreUnavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent(LocalChangeSetKey.filename).path))
        XCTAssertEqual(try String(contentsOf: snapshot, encoding: .utf8), "旧版の暗号化記録")
    }

    func testIdleLegacyNamespaceStartsWithoutReadingLegacyKey() async throws {
        let fixture = try LegacyFixture()
        defer { fixture.cleanup() }
        let oldSnapshot = try Data(contentsOf: fixture.legacy.appendingPathComponent("apply-change-set-state.enc.json"))
        let marker = try Data(contentsOf: fixture.namespace.appendingPathComponent("marker.json"))
        let runtime = RuntimeStore(baseDirectory: fixture.runtime)
        _ = try await ApplyChangeSetService.production(runtimeStore: runtime, root: fixture.root,
            stateDirectory: fixture.current, workspaceRuntime: WorkspaceStateRuntime(runtimeStore: runtime, startsFSEvents: false))
        XCTAssertEqual(try Data(contentsOf: fixture.legacy.appendingPathComponent("apply-change-set-state.enc.json")), oldSnapshot)
        XCTAssertEqual(try Data(contentsOf: fixture.namespace.appendingPathComponent("marker.json")), marker)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.current.appendingPathComponent(LocalChangeSetKey.filename).path))
        _ = try await ApplyChangeSetService.production(runtimeStore: runtime, root: fixture.root,
            stateDirectory: fixture.current, workspaceRuntime: WorkspaceStateRuntime(runtimeStore: runtime, startsFSEvents: false))
    }

    func testLegacyInFlightFilesAreNotDeletedOrAdopted() async throws {
        let fixture = try LegacyFixture()
        defer { fixture.cleanup() }
        let pending = fixture.namespace.appendingPathComponent("pending-transaction")
        try Data("編集中のファイル".utf8).write(to: pending)
        let runtime = RuntimeStore(baseDirectory: fixture.runtime)
        do {
            _ = try await ApplyChangeSetService.production(runtimeStore: runtime, root: fixture.root,
                stateDirectory: fixture.current, workspaceRuntime: WorkspaceStateRuntime(runtimeStore: runtime, startsFSEvents: false))
            XCTFail("未完了の旧編集は引き継いだ扱いにしない")
        } catch { XCTAssertEqual((error as? ApplyChangeSetError)?.code, .changeSetStoreCorrupt) }
        XCTAssertEqual(try String(contentsOf: pending, encoding: .utf8), "編集中のファイル")
    }

    private struct LegacyFixture {
        let base: URL
        let root: URL
        let runtime: URL
        let legacy: URL
        let current: URL
        let namespace: URL
        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
            root = base.appendingPathComponent("root")
            runtime = base.appendingPathComponent("state")
            let digest = SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined()
            legacy = runtime.appendingPathComponent("apply-change-set/" + digest)
            current = runtime.appendingPathComponent("apply-change-set-local-v1/" + digest)
            namespace = root.appendingPathComponent(".aishell-transactions")
            try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            // 移行先が旧暗号文を読もうとすれば必ず失敗するfixture。
            try Data("旧版の暗号化記録".utf8).write(to: legacy.appendingPathComponent("apply-change-set-state.enc.json"))
            var info = stat()
            XCTAssertEqual(lstat(root.path, &info), 0)
            try JSONSerialization.data(withJSONObject: ["schema": "aishell.apply-change-set-namespace.v1",
                "root": root.path, "generation": UUID().uuidString.lowercased(),
                "root_device": String(info.st_dev), "root_inode": String(info.st_ino)])
                .write(to: namespace.appendingPathComponent("marker.json"))
        }
        func cleanup() { try? FileManager.default.removeItem(at: base) }
    }
}
