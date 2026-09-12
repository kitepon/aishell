import Darwin
import Foundation
import XCTest
@testable import AIShellCore

final class ExternalProcessSupervisorTests: XCTestCase {
    func testSidecarOwnsChildAfterAdmissionAndPersistsSpoolAndTerminalRecord() async throws {
        let binary = try supervisorBinary()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIShellExternalSupervisor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RuntimeStore(baseDirectory: root.appendingPathComponent("state", isDirectory: true))
        let supervisor = try ExternalProcessSupervisor(
            runtimeStore: store, supervisorExecutableURL: binary
        )
        let registry = try ManagedProcessRegistry(store: store, supervisor: supervisor)
        let registration = try await registry.start(
            clientRunKey: "sidecar-e2e",
            requestDigest: "request-digest",
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import sys,time; print('out', flush=True); print('err', file=sys.stderr, flush=True); time.sleep(.4)"],
            workingDirectoryURL: root
        )
        XCTAssertEqual(registration.snapshot.state, .running)
        let paths = supervisor.paths(runID: registration.snapshot.runID)
        let acknowledgement = try JSONDecoder().decode(
            ManagedRunSupervisorAcknowledgement.self,
            from: Data(contentsOf: paths.acknowledgement)
        )
        XCTAssertNotEqual(acknowledgement.supervisorProcessIdentifier, getpid())
        XCTAssertNotEqual(acknowledgement.supervisorProcessIdentifier, acknowledgement.identity.processIdentifier)
        let proof = try await supervisor.reconnect(
            runID: registration.snapshot.runID,
            expectedIdentity: registration.snapshot.identity!
        )
        XCTAssertEqual(proof.expected, registration.snapshot.identity)

        let terminal = try await waitForTerminal(supervisor, runID: registration.snapshot.runID)
        XCTAssertEqual(terminal.exitCode, 0)
        XCTAssertNil(terminal.signal)
        XCTAssertEqual(String(decoding: try Data(contentsOf: paths.stdout), as: UTF8.self), "out\n")
        XCTAssertEqual(String(decoding: try Data(contentsOf: paths.stderr), as: UTF8.self), "err\n")
    }

    func testRegistryCancelSignalsOnlyVerifiedSidecarOwnedProcessGroup() async throws {
        let binary = try supervisorBinary()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIShellExternalSupervisorCancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RuntimeStore(baseDirectory: root.appendingPathComponent("state", isDirectory: true))
        let supervisor = try ExternalProcessSupervisor(runtimeStore: store, supervisorExecutableURL: binary)
        let registry = try ManagedProcessRegistry(store: store, supervisor: supervisor)
        let registration = try await registry.start(
            clientRunKey: "cancel-e2e",
            requestDigest: "request-digest",
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            workingDirectoryURL: root
        )
        let cancelling = try await registry.cancel(runHandle: registration.runHandle)
        XCTAssertEqual(cancelling.state, .cancelling)
        let terminal = try await waitForTerminal(supervisor, runID: registration.snapshot.runID)
        XCTAssertNotNil(terminal.signal)
        XCTAssertNotEqual(terminal.exitCode, 0)
    }

    private func waitForTerminal(
        _ supervisor: ExternalProcessSupervisor,
        runID: UUID
    ) async throws -> ManagedRunSupervisorTerminal {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if let terminal = try await supervisor.terminal(runID: runID) { return terminal }
            try await clock.sleep(for: .milliseconds(20))
        }
        throw ManagedRunSupervisorError.acknowledgementTimedOut
    }

    private func supervisorBinary() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            root.appendingPathComponent(".build/debug/aishell-run-supervisor"),
            root.appendingPathComponent(".build/arm64-apple-macosx/debug/aishell-run-supervisor")
        ]
        guard let binary = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw XCTSkip("aishell-run-supervisor productを先にbuildしてください。")
        }
        return binary
    }
}
