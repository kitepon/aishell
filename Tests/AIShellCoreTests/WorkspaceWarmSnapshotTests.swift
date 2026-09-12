import CryptoKit
import XCTest
@testable import AIShellCore

final class WorkspaceWarmSnapshotTests: XCTestCase {
    func testFullSnapshotReconcilesMoreThanDeltaLimitThroughHardLinkIdentity() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("file-0.txt")
        try Data("before\n".utf8).write(to: original)
        for index in 1...5_000 {
            try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("file-\(index).txt"))
        }
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("state"))
        await store.setWorkingDirectoryForTesting(root)
        let runtime = WorkspaceStateRuntime(runtimeStore: store)
        _ = try await runtime.snapshot(contextBudget: 0)
        try Data("after!\n".utf8).write(to: original)
        await runtime.ingestObservedPaths([original.path])
        let updated = try await runtime.snapshot(entryLimit: 5_000, contextBudget: 0)
        let scans = await runtime.scanInvocationCountForTests()
        let expectedSHA = SHA256.hash(data: Data("after!\n".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(scans, 1)
        XCTAssertEqual(updated.entries.count + updated.omittedEntries, 5_001)
        XCTAssertTrue(updated.entries.allSatisfy { $0.sha256 == expectedSHA })
    }

    func testLiveFullSnapshotReusesUnchangedIndexAndReconcilesSmallChanges() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        let nested = root.appendingPathComponent("Old/Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for index in 0..<32 {
            try Data("before\n".utf8).write(to: root.appendingPathComponent("file-\(index).txt"))
        }
        try Data("leaf\n".utf8).write(to: nested.appendingPathComponent("Leaf.txt"))
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("state"))
        await store.setWorkingDirectoryForTesting(root)
        let runtime = WorkspaceStateRuntime(runtimeStore: store)
        let initial = try await runtime.snapshot(contextBudget: 0)
        let initialReads = await runtime.contentReadCountForTests()
        let unchanged = try await runtime.snapshot(entryLimit: 1, contextBudget: 0)
        let unchangedScans = await runtime.scanInvocationCountForTests()
        let unchangedReads = await runtime.contentReadCountForTests()
        XCTAssertEqual(unchanged.entries.count + unchanged.omittedEntries, initial.entries.count)
        XCTAssertEqual(unchangedScans, 1)
        XCTAssertEqual(unchangedReads, initialReads)
        XCTAssertEqual(unchanged.freshness, "fresh")
        XCTAssertNotEqual(unchanged.cursor.split(separator: ":")[3], initial.cursor.split(separator: ":")[3])

        // 同じsize・mtimeへ戻しても、観測された変更は内容を読み直す。
        let changed = root.appendingPathComponent("file-0.txt")
        let originalDate = try XCTUnwrap(changed.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try Data("after!\n".utf8).write(to: changed)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: changed.path)
        try FileManager.default.removeItem(at: root.appendingPathComponent("file-1.txt"))
        try FileManager.default.moveItem(at: root.appendingPathComponent("Old"), to: root.appendingPathComponent("Moved"))
        let updated = try await runtime.snapshot(contextBudget: 0)
        let changedScans = await runtime.scanInvocationCountForTests()
        let expectedSHA = SHA256.hash(data: Data("after!\n".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(changedScans, 1)
        XCTAssertEqual(updated.entries.first { $0.path == "file-0.txt" }?.sha256, expectedSHA)
        XCTAssertFalse(updated.entries.contains { $0.path == "file-1.txt" || $0.path == "Old" || $0.path.hasPrefix("Old/") }, "残ったpath: \(updated.entries.map(\.path))")
        XCTAssertTrue(updated.entries.contains { $0.path == "Moved/Nested/Leaf.txt" })
        XCTAssertEqual(updated.entries.count, initial.entries.count - 1)

        // 再取得で生成したcursorとwatermarkからrestart後のdeltaを続けられる。
        let restarted = try await WorkspaceStateRuntime(runtimeStore: store).snapshot(sinceCursor: updated.cursor, contextBudget: 0)
        XCTAssertTrue(restarted.changes.isEmpty, "restart差分: \(restarted.changes)")
    }

    func testFullSnapshotWithoutObserverStillMeasuresUnobservedChanges() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("State.txt")
        try Data("before\n".utf8).write(to: file)
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("state"))
        await store.setWorkingDirectoryForTesting(root)
        let runtime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        let initial = try await runtime.snapshot(contextBudget: 0)
        try Data("after\n".utf8).write(to: file)
        let updated = try await runtime.snapshot(contextBudget: 0)
        let scans = await runtime.scanInvocationCountForTests()
        XCTAssertEqual(scans, 2)
        XCTAssertNotEqual(initial.entries.first?.sha256, updated.entries.first?.sha256)
        XCTAssertEqual(updated.checkpointState, "rebuilt")
    }

    func testFullSnapshotRebuildsWhenUnappliedEventsLeaveRetention() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = (0..<3).map { root.appendingPathComponent("file-\($0).txt") }
        for file in files { try Data("before\n".utf8).write(to: file) }
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("state"))
        await store.setWorkingDirectoryForTesting(root)
        let runtime = WorkspaceStateRuntime(runtimeStore: store, journalLimit: 2)
        _ = try await runtime.snapshot(contextBudget: 0)
        for file in files { try Data("after\n".utf8).write(to: file) }
        await runtime.ingestObservedPaths(files.map(\.path))
        let updated = try await runtime.snapshot(contextBudget: 0)
        let scans = await runtime.scanInvocationCountForTests()
        let expectedSHA = SHA256.hash(data: Data("after\n".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(scans, 2)
        XCTAssertEqual(updated.checkpointState, "rebuilt")
        XCTAssertTrue(updated.entries.allSatisfy { $0.sha256 == expectedSHA })
    }
}
