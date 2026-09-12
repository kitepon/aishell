import XCTest
@testable import AIShellCore

final class WorkspaceWaitServiceTests: XCTestCase {
    func testDurableCursorReplayReturnsChangedImmediatelyAfterRestart() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("State.swift")
        try "let value = 1\n".write(to: file, atomically: false, encoding: .utf8)
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(root)
        let runtime = WorkspaceStateRuntime(runtimeStore: store)
        let initial = try await runtime.snapshot()

        try "let value = 2\n".write(to: file, atomically: false, encoding: .utf8)
        await runtime.ingestObservedPaths([file.path])
        let first = try await runtime.workspaceWait(
            path: root.path,
            fromCursor: initial.cursor,
            timeoutSeconds: 1
        )
        let restarted = WorkspaceStateRuntime(runtimeStore: store)
        let replayed = try await restarted.workspaceWait(
            path: root.path,
            fromCursor: initial.cursor,
            timeoutSeconds: 0
        )

        XCTAssertEqual(first.status, .changed)
        XCTAssertEqual(replayed.status, .changed)
        XCTAssertEqual(replayed.observedFrom, first.observedFrom)
        XCTAssertNotEqual(replayed.observedThrough, initial.cursor)
        XCTAssertGreaterThanOrEqual(replayed.headSequence, first.headSequence)
        XCTAssertEqual(replayed.changedPaths, ["State.swift"])
    }

    func testExpiredCursorFailsWithoutFullScanFallback() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(root)
        let runtime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false, journalLimit: 1)
        let initial = try await runtime.snapshot()
        for name in ["A.txt", "B.txt"] {
            let file = root.appendingPathComponent(name)
            try name.write(to: file, atomically: false, encoding: .utf8)
            await runtime.ingestObservedPaths([file.path])
        }

        do {
            _ = try await runtime.workspaceWait(
                path: root.path,
                fromCursor: initial.cursor,
                timeoutSeconds: 0
            )
            XCTFail("retention外cursorを待機できました。")
        } catch {
            guard case AIShellError.cursorExpired = error else {
                return XCTFail("想定外のerror: \(error)")
            }
        }
        let scanCount = await runtime.scanInvocationCountForTests()
        XCTAssertEqual(scanCount, 1)
    }

    func testTimeoutReturnsStableNonAdvancingObservation() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(root)
        let runtime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        let initial = try await runtime.snapshot()

        let result = try await runtime.workspaceWait(
            path: root.path,
            fromCursor: initial.cursor,
            timeoutSeconds: 0.03,
            pollInterval: .milliseconds(5)
        )

        XCTAssertEqual(result.status, .timedOut)
        XCTAssertEqual(result.observedFrom, initial.cursor)
        XCTAssertEqual(result.observedThrough, initial.cursor)
        XCTAssertEqual(result.changedPaths, [])
    }

    func testCancellationInterruptsWaitWithoutChangingJournal() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(root)
        let runtime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        let initial = try await runtime.snapshot()
        let task = Task {
            try await runtime.workspaceWait(
                path: root.path,
                fromCursor: initial.cursor,
                timeoutSeconds: 10,
                pollInterval: .milliseconds(5)
            )
        }

        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled waitが成功しました。")
        } catch is CancellationError {
            // expected
        }

        let after = try await runtime.workspaceDeltaObservation(
            path: root.path,
            fromCursor: initial.cursor,
            deliveryGrace: .zero
        )
        XCTAssertEqual(after.observedThrough, initial.cursor)
        XCTAssertEqual(after.changedPaths, [])
    }
}
