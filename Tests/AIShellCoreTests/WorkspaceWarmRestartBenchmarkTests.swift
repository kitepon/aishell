import Foundation
import XCTest
@testable import AIShellCore

final class WorkspaceWarmRestartBenchmarkTests: XCTestCase {
    func testWarmRestartReducesContentReadsAndPreservesDeltaOracle() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        for index in 0..<120 {
            try "let value\(index) = \(index)\n".write(
                to: sources.appendingPathComponent("File\(index).swift"),
                atomically: false,
                encoding: .utf8
            )
        }
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(root)

        let clock = ContinuousClock()
        let coldRuntime = WorkspaceStateRuntime(runtimeStore: store)
        let coldStart = clock.now
        let cold = try await coldRuntime.snapshot(entryLimit: 500, contextBudget: 0)
        let coldDuration = coldStart.duration(to: clock.now)
        let coldReads = await coldRuntime.contentReadCountForTests()

        let warmRuntime = WorkspaceStateRuntime(runtimeStore: store)
        let warmStart = clock.now
        let warm = try await warmRuntime.snapshot(entryLimit: 500, contextBudget: 0)
        let warmDuration = warmStart.duration(to: clock.now)
        let warmReads = await warmRuntime.contentReadCountForTests()

        XCTAssertEqual(cold.entries.count, warm.entries.count)
        XCTAssertEqual(coldReads, 120)
        XCTAssertEqual(warmReads, 0)
        XCTAssertEqual(warm.cursor, cold.cursor)

        let modified = sources.appendingPathComponent("File0.swift")
        let renamedFrom = sources.appendingPathComponent("File1.swift")
        let renamedTo = sources.appendingPathComponent("Renamed.swift")
        let deleted = sources.appendingPathComponent("File2.swift")
        try "let value0 = 999\n".write(to: modified, atomically: false, encoding: .utf8)
        try FileManager.default.moveItem(at: renamedFrom, to: renamedTo)
        try FileManager.default.removeItem(at: deleted)

        let deltaRuntime = WorkspaceStateRuntime(runtimeStore: store)
        let delta = try await deltaRuntime.snapshot(sinceCursor: warm.cursor, entryLimit: 500, contextBudget: 0)
        let observed = Set(delta.changes.map { "\($0.kind.rawValue):\($0.previousPath ?? "-")->\($0.path)" })
        XCTAssertTrue(observed.contains("modified:-->Sources/File0.swift"))
        XCTAssertTrue(observed.contains("renamed:Sources/File1.swift->Sources/Renamed.swift"))
        XCTAssertTrue(observed.contains("deleted:-->Sources/File2.swift"))

        let result: [String: Any] = [
            "schema": "aishell.workspace-warm-restart-benchmark.v1",
            "files": 120,
            "cold_content_reads": coldReads,
            "warm_content_reads": warmReads,
            "content_read_reduction_percent": 100.0 * Double(coldReads - warmReads) / Double(coldReads),
            "cold_wall": String(describing: coldDuration),
            "warm_wall": String(describing: warmDuration),
            "delta_oracle": "passed",
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
