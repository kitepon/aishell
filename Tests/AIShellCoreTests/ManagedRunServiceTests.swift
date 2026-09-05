import Foundation
import XCTest
@testable import AIShellCore

final class ManagedRunServiceTests: XCTestCase {
    func testStartReadWaitFinalizeAndRestartKeepOneManagedRun() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let service = try fixture.service()
        let started = try await service.start(
            clientRunKey: "managed-service-e2e",
            requestDigest: String(repeating: "a", count: 64),
            executable: "/usr/bin/python3",
            arguments: [
                "-c",
                "import sys,time; print('first',flush=True); time.sleep(.25); print('second',flush=True); print('problem',file=sys.stderr,flush=True)"
            ],
            workingDirectory: fixture.workspace.path,
            environment: ["AISHELL_TEST_SECRET": "must-not-leak"],
            timeoutSeconds: 5,
            retentionSeconds: 3_600
        )
        XCTAssertEqual(started.schemaVersion, "aishell.run-check.v2")
        XCTAssertEqual(started.dispatch, "start")
        XCTAssertEqual(started.executable, "/usr/bin/python3")
        XCTAssertEqual(started.workingDirectory, fixture.workspace.path)
        XCTAssertEqual(started.environmentDigest.count, 64)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(started), as: UTF8.self).contains("must-not-leak"))
        XCTAssertEqual(started.state, "running")
        let firstRead = try await waitForRead(service, handle: started.runHandle)
        XCTAssertTrue(firstRead.chunks.contains { $0.text?.contains("first") == true })
        let waited = try await service.wait(
            runHandle: started.runHandle,
            afterStateRevision: firstRead.status.stateRevision,
            cursor: firstRead.cursor,
            timeoutMilliseconds: 5_000
        )
        XCTAssertEqual(waited.outcome, .changed)

        let terminal = try await waitForTerminal(service, handle: started.runHandle)
        XCTAssertEqual(terminal.state, "passed")
        XCTAssertEqual(terminal.terminationCause, "natural_exit")
        // The observation surfaces the terminal result state itself, so a caller can confirm and
        // restate the outcome (exit code, cancel acknowledgment) without reconstructing it.
        XCTAssertEqual(terminal.exitCode, 0)
        XCTAssertEqual(terminal.cancelAcknowledged, false)
        XCTAssertNotNil(terminal.stdoutArtifact)
        XCTAssertNotNil(terminal.stderrArtifact)
        XCTAssertNotNil(terminal.diagnosticArtifact)
        let terminalCancel = try await service.cancel(runHandle: started.runHandle)
        XCTAssertEqual(terminalCancel.stateRevision, terminal.stateRevision)
        XCTAssertEqual(terminalCancel.state, terminal.state)
        let rest = try await service.read(
            runHandle: started.runHandle, cursor: firstRead.cursor, byteBudget: 65_536
        )
        XCTAssertTrue(rest.chunks.contains { $0.text?.contains("second") == true })
        XCTAssertTrue(rest.chunks.contains { $0.text?.contains("problem") == true })

        let restarted = try fixture.service()
        let recovered = try await restarted.status(runHandle: started.runHandle)
        XCTAssertEqual(recovered.runID, terminal.runID)
        XCTAssertEqual(recovered.state, "passed")
        XCTAssertEqual(recovered.stdoutArtifact, terminal.stdoutArtifact)
        let retried = try await restarted.start(
            clientRunKey: "managed-service-e2e",
            requestDigest: String(repeating: "a", count: 64),
            executable: "/usr/bin/python3",
            arguments: [
                "-c",
                "import sys,time; print('first',flush=True); time.sleep(.25); print('second',flush=True); print('problem',file=sys.stderr,flush=True)"
            ],
            workingDirectory: fixture.workspace.path,
            environment: ["AISHELL_TEST_SECRET": "must-not-leak"],
            timeoutSeconds: 5,
            retentionSeconds: 3_600
        )
        XCTAssertEqual(retried.runHandle, started.runHandle)
        XCTAssertEqual(retried.startedAt, started.startedAt)
        XCTAssertEqual(retried.environmentDigest, started.environmentDigest)
    }

    func testSidecarTimeoutSurvivesWithoutAdapterTimer() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let service = try fixture.service()
        let started = try await service.start(
            clientRunKey: "managed-timeout-e2e",
            requestDigest: String(repeating: "b", count: 64),
            executable: "/bin/sleep",
            arguments: ["30"],
            workingDirectory: fixture.workspace.path,
            timeoutSeconds: 0.15,
            retentionSeconds: 3_600
        )
        let terminal = try await waitForTerminal(service, handle: started.runHandle)
        XCTAssertEqual(terminal.state, "timed_out")
        XCTAssertEqual(terminal.terminationCause, "timed_out")
    }

    func testTamperedAndCrossRunCursorsAreRejected() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let service = try fixture.service()
        let first = try await service.start(
            clientRunKey: "cursor-first", requestDigest: "first",
            executable: "/bin/echo", arguments: ["one"],
            workingDirectory: fixture.workspace.path, timeoutSeconds: 5, retentionSeconds: 3_600
        )
        let second = try await service.start(
            clientRunKey: "cursor-second", requestDigest: "second",
            executable: "/bin/echo", arguments: ["two"],
            workingDirectory: fixture.workspace.path, timeoutSeconds: 5, retentionSeconds: 3_600
        )
        let read = try await service.read(runHandle: first.runHandle)
        await assertManagedRunThrows(
            try await service.read(runHandle: first.runHandle, cursor: read.cursor + "x")
        ) { XCTAssertEqual($0 as? ManagedRunServiceError, .invalidCursor) }
        await assertManagedRunThrows(
            try await service.read(runHandle: second.runHandle, cursor: read.cursor)
        ) { XCTAssertEqual($0 as? ManagedRunServiceError, .cursorRunMismatch) }
        await assertManagedRunThrows(
            try await service.wait(
                runHandle: second.runHandle,
                afterStateRevision: 0,
                cursor: read.cursor,
                timeoutMilliseconds: 100
            )
        ) { XCTAssertEqual($0 as? ManagedRunServiceError, .cursorRunMismatch) }
        _ = try await waitForTerminal(service, handle: first.runHandle)
        _ = try await waitForTerminal(service, handle: second.runHandle)
    }

    private func waitForRead(
        _ service: ManagedRunService,
        handle: String
    ) async throws -> ManagedRunReadResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            let result = try await service.read(runHandle: handle)
            if !result.chunks.isEmpty { return result }
            try await clock.sleep(for: .milliseconds(20))
        }
        throw ManagedRunSupervisorError.acknowledgementTimedOut
    }

    private func waitForTerminal(
        _ service: ManagedRunService,
        handle: String
    ) async throws -> ManagedRunStatusResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            let result = try await service.status(runHandle: handle)
            if ["passed", "failed", "timed_out", "cancelled", "interrupted"].contains(result.state) {
                return result
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        throw ManagedRunSupervisorError.acknowledgementTimedOut
    }
}

private func assertManagedRunThrows<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("エラーが必要です。", file: file, line: line)
    } catch {
        verify(error)
    }
}

private struct Fixture {
    let root: URL
    let workspace: URL
    let runtimeStore: RuntimeStore
    let supervisorBinary: URL

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIShellManagedRunService-\(UUID().uuidString)", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        runtimeStore = RuntimeStore(baseDirectory: root.appendingPathComponent("state", isDirectory: true))
        await runtimeStore.setWorkingDirectoryForTesting(workspace)
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            projectRoot.appendingPathComponent(".build/debug/aishell-run-supervisor"),
            projectRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/aishell-run-supervisor")
        ]
        guard let binary = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else { throw XCTSkip("aishell-run-supervisor productを先にbuildしてください。") }
        supervisorBinary = binary
    }

    func service() throws -> ManagedRunService {
        try ManagedRunService(runtimeStore: runtimeStore, supervisorExecutableURL: supervisorBinary)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
