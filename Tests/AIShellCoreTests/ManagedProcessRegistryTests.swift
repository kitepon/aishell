import XCTest
@testable import AIShellCore

final class ManagedProcessRegistryTests: XCTestCase {
    private let runID = UUID(uuidString: "00000000-0000-0000-0000-00000000044a")!

    func testStartObserveAndRestartReconnectPreserveHandleRevisionAndCursor() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        let supervisor = RegistrySupervisorFixture(identity: identity())
        var registry: ManagedProcessRegistry? = try ManagedProcessRegistry(store: store, supervisor: supervisor)

        let started = try await registry!.start(
            clientRunKey: "compile-1",
            requestDigest: "sha256:request-a",
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            workingDirectoryURL: fixture.base,
            runID: runID
        )
        XCTAssertEqual(started.admission, .created(runID: runID))
        XCTAssertEqual(started.snapshot.state, .running)
        XCTAssertEqual(started.snapshot.stateRevision, 1)

        let cursor = try await registry!.recordEvidence(
            runHandle: started.runHandle,
            stdoutBytes: 7,
            stderrBytes: 3,
            diagnosticBytes: 5
        )
        XCTAssertEqual(cursor, ManagedEvidenceCursor(
            runID: runID,
            eventSequence: 1,
            stdoutOffset: 7,
            stderrOffset: 3,
            diagnosticOffset: 5
        ))

        registry = nil
        let restarted = try ManagedProcessRegistry(store: store, supervisor: supervisor)
        let beforeRecovery = try await restarted.observe(runHandle: started.runHandle)
        XCTAssertEqual(beforeRecovery.state, .running)
        XCTAssertEqual(beforeRecovery.stateRevision, 2)
        XCTAssertEqual(beforeRecovery.cursor, cursor)

        let recovery = try await restarted.recoverAfterServerRestart()
        XCTAssertEqual(recovery.count, 1)
        XCTAssertEqual(recovery[0].state, .reconnected)
        XCTAssertEqual(recovery[0].snapshot.state, .running)
        XCTAssertEqual(recovery[0].snapshot.stateRevision, 4)
        XCTAssertEqual(recovery[0].snapshot.cursor, cursor)
        let observedAfterRecovery = try await restarted.observe(runHandle: started.runHandle)
        let reconnectCount = await supervisor.reconnectCount()
        XCTAssertEqual(observedAfterRecovery, recovery[0].snapshot)
        XCTAssertEqual(reconnectCount, 1)
    }

    func testClientRunKeyReplayDoesNotRelaunchAndDigestConflictFailsClosed() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let supervisor = RegistrySupervisorFixture(identity: identity())
        let registry = try ManagedProcessRegistry(
            store: RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime")),
            supervisor: supervisor
        )

        let first = try await registry.start(
            clientRunKey: "same-key",
            requestDigest: "sha256:same",
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            workingDirectoryURL: fixture.base,
            runID: runID
        )
        let replay = try await registry.start(
            clientRunKey: "same-key",
            requestDigest: "sha256:same",
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            workingDirectoryURL: fixture.base
        )
        XCTAssertEqual(replay.admission, .existing(runID: runID))
        XCTAssertEqual(replay.runHandle, first.runHandle)
        var launchCount = await supervisor.launchCount()
        XCTAssertEqual(launchCount, 1)

        do {
            _ = try await registry.start(
                clientRunKey: "same-key",
                requestDigest: "sha256:different",
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                workingDirectoryURL: fixture.base
            )
            XCTFail("別request digestで同じkeyを再利用しました。")
        } catch {
            XCTAssertEqual(error as? ManagedProcessProtocolError, .runKeyConflict)
        }
        launchCount = await supervisor.launchCount()
        XCTAssertEqual(launchCount, 1)
    }

    func testCancelPersistsCauseBeforeVerifiedStopAndRepeatedCancelIsIdempotent() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let supervisor = RegistrySupervisorFixture(identity: identity())
        let registry = try ManagedProcessRegistry(
            store: RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime")),
            supervisor: supervisor
        )
        let started = try await registry.start(
            clientRunKey: "cancel-key",
            requestDigest: "sha256:cancel",
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            workingDirectoryURL: fixture.base,
            runID: runID
        )
        let acceptedAt = Date(timeIntervalSince1970: 1_000)

        let first = try await registry.cancel(runHandle: started.runHandle, acceptedAt: acceptedAt)
        let repeated = try await registry.cancel(
            runHandle: started.runHandle,
            acceptedAt: acceptedAt.addingTimeInterval(30)
        )
        XCTAssertEqual(first, repeated)
        XCTAssertEqual(first.state, .cancelling)
        XCTAssertEqual(first.terminationCause, .cancellation(acceptedAt: acceptedAt))
        let stopCount = await supervisor.stopCount()
        let reconnectCount = await supervisor.reconnectCount()
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(reconnectCount, 1)
    }

    func testCancelIdentityMismatchNeverStopsAndRestartKeepsRecoveryRequired() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let expected = identity()
        let mismatched = identity(start: "pid-reused")
        let supervisor = RegistrySupervisorFixture(identity: expected)
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        var registry: ManagedProcessRegistry? = try ManagedProcessRegistry(store: store, supervisor: supervisor)
        let started = try await registry!.start(
            clientRunKey: "mismatch-key",
            requestDigest: "sha256:mismatch",
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            workingDirectoryURL: fixture.base,
            runID: runID
        )
        await supervisor.setReconnectIdentity(mismatched)

        do {
            _ = try await registry!.cancel(runHandle: started.runHandle, acceptedAt: Date(timeIntervalSince1970: 2_000))
            XCTFail("identity不一致のprocessを停止しました。")
        } catch {
            XCTAssertEqual(error as? ManagedProcessRegistryError, .runRecoveryRequired)
        }
        let recoveryRequired = try await registry!.observe(runHandle: started.runHandle)
        XCTAssertEqual(recoveryRequired.state, .recoveryRequired)
        XCTAssertEqual(recoveryRequired.terminationCause, .cancellation(acceptedAt: Date(timeIntervalSince1970: 2_000)))
        var stopCount = await supervisor.stopCount()
        XCTAssertEqual(stopCount, 0)

        registry = nil
        let restarted = try ManagedProcessRegistry(store: store, supervisor: supervisor)
        let restored = try await restarted.observe(runHandle: started.runHandle)
        XCTAssertEqual(restored, recoveryRequired)
        let outcomes = try await restarted.recoverAfterServerRestart()
        XCTAssertEqual(outcomes.map(\.state), [.recoveryRequired])
        stopCount = await supervisor.stopCount()
        XCTAssertEqual(stopCount, 0)
    }

    func testRecoveryOfPersistedCancellingRunReissuesVerifiedStop() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let supervisor = RegistrySupervisorFixture(identity: identity())
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        var registry: ManagedProcessRegistry? = try ManagedProcessRegistry(store: store, supervisor: supervisor)
        let started = try await registry!.start(
            clientRunKey: "restart-cancel-key",
            requestDigest: "sha256:restart-cancel",
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            workingDirectoryURL: fixture.base,
            runID: runID
        )
        _ = try await registry!.cancel(runHandle: started.runHandle, acceptedAt: Date(timeIntervalSince1970: 3_000))
        var stopCount = await supervisor.stopCount()
        XCTAssertEqual(stopCount, 1)

        registry = nil
        let restarted = try ManagedProcessRegistry(store: store, supervisor: supervisor)
        let outcomes = try await restarted.recoverAfterServerRestart()
        XCTAssertEqual(outcomes.map(\.state), [.reconnected])
        XCTAssertEqual(outcomes[0].snapshot.state, .cancelling)
        stopCount = await supervisor.stopCount()
        XCTAssertEqual(stopCount, 2)
    }

    func testRestartStopFailureReturnsAndPersistsRecoveryRequiredSnapshot() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let supervisor = RegistrySupervisorFixture(identity: identity())
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        var registry: ManagedProcessRegistry? = try ManagedProcessRegistry(store: store, supervisor: supervisor)
        let started = try await registry!.start(
            clientRunKey: "restart-stop-failure",
            requestDigest: "sha256:restart-stop-failure",
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            workingDirectoryURL: fixture.base,
            runID: runID
        )
        _ = try await registry!.cancel(runHandle: started.runHandle, acceptedAt: Date(timeIntervalSince1970: 3_100))
        registry = nil
        await supervisor.setStopFailure(true)

        let restarted = try ManagedProcessRegistry(store: store, supervisor: supervisor)
        let outcomes = try await restarted.recoverAfterServerRestart()
        XCTAssertEqual(outcomes.map(\.state), [.recoveryRequired])
        XCTAssertEqual(outcomes[0].snapshot.state, .recoveryRequired)
        let observed = try await restarted.observe(runHandle: started.runHandle)
        XCTAssertEqual(observed, outcomes[0].snapshot)
    }

    func testHandleTamperCrossStoreAndTerminalExpiryAreTyped() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let supervisor = RegistrySupervisorFixture(identity: identity())
        let firstStore = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime-a"))
        let first = try ManagedProcessRegistry(store: firstStore, supervisor: supervisor)
        let started = try await first.start(
            clientRunKey: "handle-key",
            requestDigest: "sha256:handle",
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            workingDirectoryURL: fixture.base,
            retentionSeconds: 0,
            runID: runID
        )

        let replacement = started.runHandle.last == "A" ? "B" : "A"
        let tampered = String(started.runHandle.dropLast()) + replacement
        do {
            _ = try await first.observe(runHandle: tampered)
            XCTFail("改ざんhandleを受理しました。")
        } catch {
            XCTAssertEqual(error as? ManagedProcessRegistryError, .invalidRunHandle)
        }

        let second = try ManagedProcessRegistry(
            store: RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime-b")),
            supervisor: supervisor
        )
        do {
            _ = try await second.observe(runHandle: started.runHandle)
            XCTFail("別storeのhandleを受理しました。")
        } catch {
            XCTAssertEqual(error as? ManagedProcessRegistryError, .runStoreMismatch)
        }

        _ = try await first.record(runHandle: started.runHandle, event: .naturalExit(exitCode: 0, signal: nil))
        _ = try await first.record(runHandle: started.runHandle, event: .commitFinalization(bundle(at: Date(timeIntervalSince1970: 4_000))))
        do {
            _ = try await first.observe(runHandle: started.runHandle)
            XCTFail("期限切れrunを観測しました。")
        } catch {
            XCTAssertEqual(error as? ManagedProcessRegistryError, .runExpired)
        }
    }

    func testFinalizingRejectsCancelAndTerminalRestartDoesNotReconnectOrMutate() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let supervisor = RegistrySupervisorFixture(identity: identity())
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        var registry: ManagedProcessRegistry? = try ManagedProcessRegistry(store: store, supervisor: supervisor)
        let started = try await registry!.start(
            clientRunKey: "terminal-key",
            requestDigest: "sha256:terminal",
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            workingDirectoryURL: fixture.base,
            retentionSeconds: 60,
            runID: runID
        )
        _ = try await registry!.record(runHandle: started.runHandle, event: .naturalExit(exitCode: 0, signal: nil))
        do {
            _ = try await registry!.cancel(runHandle: started.runHandle)
            XCTFail("finalizing runをcancelしました。")
        } catch {
            XCTAssertEqual(error as? ManagedProcessRegistryError, .runNotCancellable)
        }

        let finalizedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let terminal = try await registry!.record(
            runHandle: started.runHandle,
            event: .commitFinalization(bundle(at: finalizedAt))
        )
        let afterCancel = try await registry!.cancel(runHandle: started.runHandle)
        XCTAssertEqual(afterCancel, terminal)
        registry = nil

        let restarted = try ManagedProcessRegistry(store: store, supervisor: supervisor)
        let outcomes = try await restarted.recoverAfterServerRestart()
        XCTAssertEqual(outcomes.map(\.state), [.terminal])
        XCTAssertEqual(outcomes[0].snapshot, terminal)
        let reconnectCount = await supervisor.reconnectCount()
        let stopCount = await supervisor.stopCount()
        XCTAssertEqual(reconnectCount, 0)
        XCTAssertEqual(stopCount, 0)
    }

    func testRestartRejectsPartialJournalInsteadOfUsingValidPrefix() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        let supervisor = RegistrySupervisorFixture(identity: identity())
        var registry: ManagedProcessRegistry? = try ManagedProcessRegistry(store: store, supervisor: supervisor)
        _ = try await registry!.start(
            clientRunKey: "corrupt-key",
            requestDigest: "sha256:corrupt",
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            workingDirectoryURL: fixture.base,
            runID: runID
        )
        registry = nil

        let journal = store.baseDirectory
            .appendingPathComponent("managed-runs/runs/\(runID.uuidString.lowercased())/journal.jsonl")
        let handle = try FileHandle(forWritingTo: journal)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"partial\"".utf8))
        try handle.close()

        XCTAssertThrowsError(try ManagedProcessRegistry(store: store, supervisor: supervisor)) { error in
            XCTAssertEqual(error as? ManagedProcessRegistryError, .runStoreCorrupt("partial journal record"))
        }
    }

    private func identity(start: String = "pid-start-44a") -> ManagedProcessIdentity {
        ManagedProcessIdentity(
            processIdentifier: 44,
            processStartIdentity: start,
            processGroupIdentifier: 44,
            bootSessionIdentity: "boot-44a",
            supervisorNonce: "nonce-44a"
        )
    }

    private func bundle(at date: Date) -> ManagedFinalizationBundle {
        ManagedFinalizationBundle(
            stdout: .init(handle: "stdout", sizeBytes: 0, sha256: "sha256:stdout"),
            stderr: .init(handle: "stderr", sizeBytes: 0, sha256: "sha256:stderr"),
            diagnostics: .init(handle: "diagnostics", sizeBytes: 0, sha256: "sha256:diagnostics"),
            runIndexDigest: "sha256:index",
            finalizedAt: date
        )
    }

}

private actor RegistrySupervisorFixture: ProcessSupervisorSeam {
    private let launchedIdentity: ManagedProcessIdentity
    private var observedIdentity: ManagedProcessIdentity
    private var launches = 0
    private var reconnects = 0
    private var stops = 0
    private var stopShouldFail = false

    init(identity: ManagedProcessIdentity) {
        launchedIdentity = identity
        observedIdentity = identity
    }

    func launch(_ request: ManagedSupervisorLaunchRequest) -> ManagedProcessIdentity {
        launches += 1
        return launchedIdentity
    }

    func reconnect(runID: UUID, expectedIdentity: ManagedProcessIdentity) -> ManagedProcessIdentityProof {
        reconnects += 1
        return ManagedProcessIdentityProof(runID: runID, expected: expectedIdentity, observed: observedIdentity)
    }

    func stop(runID _: UUID, proof _: ManagedProcessIdentityProof) throws -> ManagedSupervisorStopReport {
        stops += 1
        if stopShouldFail { throw RegistrySupervisorFixtureError.stopFailed }
        return ManagedSupervisorStopReport(termWasSent: true, killWasSent: false, processGroupIsGone: true)
    }

    func setReconnectIdentity(_ identity: ManagedProcessIdentity) { observedIdentity = identity }
    func setStopFailure(_ shouldFail: Bool) { stopShouldFail = shouldFail }
    func launchCount() -> Int { launches }
    func reconnectCount() -> Int { reconnects }
    func stopCount() -> Int { stops }
}

private enum RegistrySupervisorFixtureError: Error {
    case stopFailed
}
