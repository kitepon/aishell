import Foundation
import XCTest
@testable import AIShellCore

final class WorkspaceReconciliationScaleTests: XCTestCase {
    func testOverlappingNestedDirectoryRenameAndDeletionKeepEveryDescendant() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        let old = root.appendingPathComponent("Old", isDirectory: true)
        let moved = root.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(at: old.appendingPathComponent("Nested/Deep"), withIntermediateDirectories: true)
        for path in ["Top.txt", "Nested/Deep/Leaf.txt"] {
            try Data("content\n".utf8).write(to: old.appendingPathComponent(path))
        }
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("state"))
        await store.setWorkingDirectoryForTesting(root)
        let runtime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        let initial = try await runtime.snapshot(contextBudget: 0)
        try FileManager.default.moveItem(at: old, to: moved)
        await runtime.ingestObservedPaths([moved.path, moved.appendingPathComponent("Nested").path, moved.path])
        let renamed = try await runtime.snapshot(sinceCursor: initial.cursor, entryLimit: 1, contextBudget: 0)
        for path in ["Top.txt", "Nested/Deep/Leaf.txt"] {
            XCTAssertTrue(renamed.changes.contains { $0.kind == .renamed && $0.path == "Moved/\(path)" && $0.previousPath == "Old/\(path)" })
        }
        XCTAssertEqual(Set(renamed.changes.map(\.path)).count, renamed.changes.count)
        let current = try await runtime.snapshot(contextBudget: 0)
        try FileManager.default.removeItem(at: moved)
        await runtime.ingestObservedPaths([moved.path, moved.appendingPathComponent("Nested").path, moved.path])
        let deleted = try await runtime.snapshot(sinceCursor: current.cursor, entryLimit: 1, contextBudget: 0)
        XCTAssertEqual(Set(deleted.changes.map(\.path)), Set(current.entries.map(\.path)))
        XCTAssertTrue(deleted.changes.allSatisfy { $0.kind == .deleted })
    }

    func testLargeIndexReconcilesOneDirectoryWithoutLosingChanges() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        let batch = root.appendingPathComponent("batch", isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        for index in 0..<64 {
            try Data("before\n".utf8).write(to: batch.appendingPathComponent("file-\(index).txt"))
        }
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("state"))
        await store.setWorkingDirectoryForTesting(root)
        let runtime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        let initial = try await runtime.snapshot(path: root.path, contextBudget: 0)
        // 変更範囲外の索引だけを固定生成する。cold scanの測定には数えない。
        let untouched = Dictionary(uniqueKeysWithValues: (0..<200_000).map { index in
            let path = "untouched/file-\(index).txt"
            return (path, WorkspaceEntry(path: path, identity: "untouched:\(index)", isDirectory: false,
                                         sizeBytes: 1, modifiedAt: nil, sha256: String(repeating: "0", count: 64)))
        })
        try await runtime.augmentEntriesForTests(untouched, rootPath: initial.root)
        for index in 0..<64 {
            try Data("after\n".utf8).write(to: batch.appendingPathComponent("file-\(index).txt"))
        }
        await runtime.ingestObservedPaths([batch.path, batch.path])
        let start = ContinuousClock.now
        let delta = try await runtime.snapshot(path: root.path, sinceCursor: initial.cursor, entryLimit: 100, contextBudget: 0)
        let elapsed = start.duration(to: .now)
        let modified = delta.changes.filter { $0.path.hasSuffix(".txt") }
        XCTAssertEqual(Set(modified.map(\.path)), Set((0..<64).map { "batch/file-\($0).txt" }))
        XCTAssertEqual(modified.count, 64)
        XCTAssertTrue(modified.allSatisfy { $0.kind == .modified })
        print("RECONCILIATION_SCALE entries=200065 changed_files=64 elapsed=\(elapsed)")
    }
}
