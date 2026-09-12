import XCTest
import CryptoKit
import Darwin
@testable import AIShellCore

final class ManagedProcessSafetyNetTests: XCTestCase {
    private let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
    private let acceptedAt = Date(timeIntervalSince1970: 100)

    func testNaturalExitCancelTimeoutRaceAcceptsOnlyFirstCause() async throws {
        let naturalFirst = DeterministicManagedProcessHarness(runID: runID)
        _ = try await naturalFirst.accept(.launchSucceeded(identity()))
        let naturalResults = await naturalFirst.race([
            .naturalExit(exitCode: 0, signal: nil),
            .cancel(acceptedAt: acceptedAt),
            .timeout(deadline: acceptedAt)
        ])
        XCTAssertEqual(naturalResults.count, 3)
        let naturalSnapshot = await naturalFirst.snapshot()
        XCTAssertEqual(naturalSnapshot.state, .finalizing)
        XCTAssertEqual(naturalSnapshot.terminationCause, .naturalExit(exitCode: 0, signal: nil))

        let cancelFirst = DeterministicManagedProcessHarness(runID: runID)
        _ = try await cancelFirst.accept(.launchSucceeded(identity()))
        _ = await cancelFirst.race([
            .cancel(acceptedAt: acceptedAt),
            .naturalExit(exitCode: 0, signal: nil),
            .timeout(deadline: acceptedAt)
        ])
        let cancelSnapshot = await cancelFirst.snapshot()
        XCTAssertEqual(cancelSnapshot.state, .finalizing)
        XCTAssertEqual(cancelSnapshot.terminationCause, .cancellation(acceptedAt: acceptedAt))

        let timeoutFirst = DeterministicManagedProcessHarness(runID: runID)
        _ = try await timeoutFirst.accept(.launchSucceeded(identity()))
        _ = await timeoutFirst.race([
            .timeout(deadline: acceptedAt),
            .cancel(acceptedAt: acceptedAt),
            .naturalExit(exitCode: 0, signal: nil)
        ])
        let timeoutSnapshot = await timeoutFirst.snapshot()
        XCTAssertEqual(timeoutSnapshot.state, .finalizing)
        XCTAssertEqual(timeoutSnapshot.terminationCause, .timeout(deadline: acceptedAt))
    }

    func testRepeatedCancelIsIdempotentAndTerminalCancelReturnsSameSnapshot() async throws {
        let harness = DeterministicManagedProcessHarness(runID: runID)
        _ = try await harness.accept(.launchSucceeded(identity()))
        let first = try await harness.accept(.cancel(acceptedAt: acceptedAt))
        let repeated = try await harness.accept(.cancel(acceptedAt: acceptedAt.addingTimeInterval(5)))
        XCTAssertEqual(repeated, first)

        _ = try await harness.accept(.beginFinalization)
        let terminal = try await harness.accept(.commitFinalization(bundle(at: acceptedAt)))
        let afterTerminal = try await harness.accept(.cancel(acceptedAt: acceptedAt.addingTimeInterval(10)))
        XCTAssertEqual(afterTerminal, terminal)
        XCTAssertEqual(afterTerminal.state, .cancelled)
    }

    func testLaunchFailureKeepsRunAndFinalizesEmptyArtifacts() async throws {
        let harness = DeterministicManagedProcessHarness(runID: runID)
        let failed = try await harness.accept(
            .launchFailed(stage: .spawn, osErrorCategory: "not_found")
        )
        XCTAssertEqual(failed.state, .finalizing)
        XCTAssertEqual(
            failed.terminationCause,
            .launchFailed(stage: .spawn, osErrorCategory: "not_found")
        )
        XCTAssertEqual(failed.runID, runID)

        let finalized = try await harness.accept(.commitFinalization(bundle(at: acceptedAt, emptyStreams: true)))
        XCTAssertEqual(finalized.state, .failed)
        XCTAssertEqual(finalized.finalization?.stdout.sizeBytes, 0)
        XCTAssertEqual(finalized.finalization?.stderr.sizeBytes, 0)
    }

    func testEvidenceCursorCountsRawBytesWithoutLossAcrossAppends() async throws {
        let harness = DeterministicManagedProcessHarness(runID: runID)
        _ = try await harness.accept(.launchSucceeded(identity()))
        let first = try await harness.appendEvidence(stdoutBytes: 3, stderrBytes: 2, diagnosticBytes: 7)
        let second = try await harness.appendEvidence(stdoutBytes: 5, stderrBytes: 11, diagnosticBytes: 0)

        XCTAssertEqual(first.stdoutOffset, 3)
        XCTAssertEqual(first.stderrOffset, 2)
        XCTAssertEqual(second.stdoutOffset, 8)
        XCTAssertEqual(second.stderrOffset, 13)
        XCTAssertEqual(second.diagnosticOffset, 7)
        XCTAssertEqual(second.eventSequence, 2)
        XCTAssertEqual(second.runID, runID)
    }

    func testFinalizationPublishesArtifactsAndTerminalStateAtomically() async throws {
        let harness = DeterministicManagedProcessHarness(runID: runID, retentionSeconds: 60)
        _ = try await harness.accept(.launchSucceeded(identity()))
        let beforeCommit = try await harness.accept(.naturalExit(exitCode: 0, signal: nil))
        XCTAssertEqual(beforeCommit.state, .finalizing)
        XCTAssertNil(beforeCommit.finalization)
        XCTAssertNil(beforeCommit.expiresAt)

        let committed = try await harness.accept(.commitFinalization(bundle(at: acceptedAt)))
        XCTAssertEqual(committed.state, .passed)
        XCTAssertNotNil(committed.finalization)
        XCTAssertEqual(committed.expiresAt, acceptedAt.addingTimeInterval(60))
        XCTAssertEqual(committed.stateRevision, beforeCommit.stateRevision + 1)
        XCTAssertFalse(beforeCommit.isEligibleForGarbageCollection(at: acceptedAt.addingTimeInterval(600)))
        XCTAssertFalse(committed.isEligibleForGarbageCollection(at: acceptedAt.addingTimeInterval(59)))
        XCTAssertTrue(committed.isEligibleForGarbageCollection(at: acceptedAt.addingTimeInterval(60)))
    }

    func testRecoveryRequiresExactProcessStartAndBootIdentity() async throws {
        let harness = DeterministicManagedProcessHarness(runID: runID)
        _ = try await harness.accept(.launchSucceeded(identity()))
        _ = try await harness.accept(.supervisorUnavailable)

        do {
            _ = try await harness.accept(.recover(identity: identity(start: "reused-pid")))
            XCTFail("PID再利用identityを受理しました。")
        } catch {
            XCTAssertEqual(error as? ManagedProcessProtocolError, .identityMismatch)
        }
        let recoveryRequired = await harness.snapshot()
        XCTAssertEqual(recoveryRequired.state, .recoveryRequired)

        let recovered = try await harness.accept(.recover(identity: identity()))
        XCTAssertEqual(recovered.state, .running)
        XCTAssertEqual(recovered.identity, identity())
    }

    func testUnrecoverableRunFailsClosedToInterruptedAfterStopConfirmation() async throws {
        let harness = DeterministicManagedProcessHarness(runID: runID)
        _ = try await harness.accept(.launchSucceeded(identity()))
        _ = try await harness.accept(.supervisorUnavailable)
        let finalizing = try await harness.accept(.recoveredProcessStopped)
        XCTAssertEqual(finalizing.terminationCause, .recoveryInterrupted)
        XCTAssertEqual(finalizing.state, .finalizing)

        let terminal = try await harness.accept(.commitFinalization(bundle(at: acceptedAt)))
        XCTAssertEqual(terminal.state, .interrupted)
    }

    func testAdmissionLedgerReturnsSameRunAndRejectsDigestConflict() throws {
        var ledger = ManagedRunAdmissionLedger()
        var creationCount = 0
        let first = try ledger.admit(clientRunKey: "request-1", requestDigest: "sha256:a") {
            creationCount += 1
            return runID
        }
        let replay = try ledger.admit(clientRunKey: "request-1", requestDigest: "sha256:a") {
            creationCount += 1
            return UUID()
        }

        XCTAssertEqual(first, .created(runID: runID))
        XCTAssertEqual(replay, .existing(runID: runID))
        XCTAssertEqual(creationCount, 1)
        XCTAssertThrowsError(
            try ledger.admit(clientRunKey: "request-1", requestDigest: "sha256:b", makeRunID: UUID.init)
        ) { error in
            XCTAssertEqual(error as? ManagedProcessProtocolError, .runKeyConflict)
        }
    }

    func testIllegalTransitionDoesNotAdvanceRevision() async throws {
        let harness = DeterministicManagedProcessHarness(runID: runID)
        let before = await harness.snapshot()
        do {
            _ = try await harness.accept(.commitFinalization(bundle(at: acceptedAt)))
            XCTFail("startingからterminalを直接公開しました。")
        } catch {
            guard case .illegalTransition = error as? ManagedProcessProtocolError else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }
        let after = await harness.snapshot()
        XCTAssertEqual(after, before)
    }

    func testRecoveryCancelRequiresVerifiedIdentityAndMismatchNeverSignals() async throws {
        let supervisor = MacOSProcessSupervisorFixture()
        let request = ManagedSupervisorLaunchRequest(
            runID: runID,
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["0.1"],
            workingDirectoryURL: FileManager.default.temporaryDirectory
        )
        // signal検証専用recordを作る。短命process自体はstop対象にしない。
        let observed = try await supervisor.launch(request)
        let harness = DeterministicManagedProcessHarness(runID: runID)
        _ = try await harness.accept(.launchSucceeded(observed))
        _ = try await harness.accept(.supervisorUnavailable)

        do {
            _ = try await harness.accept(.cancel(acceptedAt: acceptedAt))
            XCTFail("identity proofなしでrecovery_requiredをcancelしました。")
        } catch {
            XCTAssertEqual(error as? ManagedProcessProtocolError, .runRecoveryRequired)
        }

        let mismatched = ManagedProcessIdentity(
            processIdentifier: observed.processIdentifier,
            processStartIdentity: "pid-reused",
            processGroupIdentifier: observed.processGroupIdentifier,
            bootSessionIdentity: observed.bootSessionIdentity,
            supervisorNonce: observed.supervisorNonce
        )
        let invalidProof = ManagedProcessIdentityProof(runID: runID, expected: observed, observed: mismatched)
        do {
            _ = try await harness.accept(
                .cancelAfterRecoveryVerification(acceptedAt: acceptedAt, proof: invalidProof)
            )
            XCTFail("mismatch proofでrecovery_requiredをcancelしました。")
        } catch {
            XCTAssertEqual(error as? ManagedProcessProtocolError, .runRecoveryRequired)
        }
        let afterMismatch = await harness.snapshot()
        XCTAssertEqual(afterMismatch.state, .recoveryRequired)
        do {
            _ = try await supervisor.stop(runID: runID, proof: invalidProof)
            XCTFail("PID/start mismatchでsignalを送りました。")
        } catch {
            XCTAssertEqual(error as? ProcessSupervisorFixtureError, .identityMismatch)
        }
        let signalAttempts = await supervisor.signalAttemptCount()
        XCTAssertEqual(signalAttempts, 0)

        let validProof = ManagedProcessIdentityProof(runID: runID, expected: observed, observed: observed)
        let cancelling = try await harness.accept(
            .cancelAfterRecoveryVerification(acceptedAt: acceptedAt, proof: validProof)
        )
        XCTAssertEqual(cancelling.state, .cancelling)
        try await Task.sleep(for: .milliseconds(150))
        await supervisor.reapWithoutSignalIfExited()
    }

    func testRealProcessGroupTermKillAndAdapterReconnect() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3がありません。")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIShellManagedSupervisor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptURL = directory.appendingPathComponent("process_tree.py")
        try processTreeScript.write(to: scriptURL, atomically: true, encoding: .utf8)

        let supervisor = MacOSProcessSupervisorFixture()
        let firstAdapter = ProcessSupervisorAdapterFixture(supervisor: supervisor)
        let request = ManagedSupervisorLaunchRequest(
            runID: runID,
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [scriptURL.path, "root", directory.path],
            workingDirectoryURL: directory
        )
        let launched = try await firstAdapter.launch(request)
        try await waitForFiles([
            directory.appendingPathComponent("child.pid"),
            directory.appendingPathComponent("grandchild.pid")
        ])

        // MCP adapter instanceを破棄・再生成しても同じsupervisor identityへ接続する。
        let secondAdapter = ProcessSupervisorAdapterFixture(supervisor: supervisor)
        let proof = try await secondAdapter.reconnect(runID: runID, expectedIdentity: launched)
        XCTAssertEqual(proof.expected, launched)
        XCTAssertEqual(proof.observed, launched)

        let childPID = try pid(from: directory.appendingPathComponent("child.pid"))
        let grandchildPID = try pid(from: directory.appendingPathComponent("grandchild.pid"))
        let report = try await secondAdapter.stop(runID: runID, proof: proof)
        XCTAssertTrue(report.termWasSent)
        XCTAssertTrue(report.killWasSent, "TERMを無視するfixtureへKILLを送っていません。")
        XCTAssertTrue(report.processGroupIsGone)
        XCTAssertFalse(isRunningProcess(childPID), "childがKILL後も実行中です。")
        XCTAssertFalse(isRunningProcess(grandchildPID), "grandchildがKILL後も実行中です。")
    }

    func testRealSpoolReadbackAndAtomicPublicationFailureInjection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIShellManagedSpool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("stdout.spool")
        let stderrURL = directory.appendingPathComponent("stderr.spool")
        let stdout = Data([0x00, 0xff, 0x0a, 0x41, 0x0a])
        let stderr = Data([0x80, 0x42, 0x0a, 0x43])
        try writeAndFsync(stdout, to: stdoutURL)
        try writeAndFsync(stderr, to: stderrURL)

        let inspector = RealSpoolFinalizerFixture(failure: nil)
        let inspection = try await inspector.fsyncAndInspect(stdoutURL: stdoutURL, stderrURL: stderrURL)
        XCTAssertEqual(inspection.stdout.sizeBytes, UInt64(stdout.count))
        XCTAssertEqual(inspection.stdout.lineCount, 2)
        XCTAssertEqual(inspection.stdout.sha256, digest(stdout))
        XCTAssertEqual(inspection.stderr.sizeBytes, UInt64(stderr.count))
        XCTAssertEqual(inspection.stderr.lineCount, 1)
        XCTAssertEqual(inspection.stderr.sha256, digest(stderr))

        for failure in [SpoolPublicationFailure.secondArtifact, .indexCommit] {
            let failing = RealSpoolFinalizerFixture(failure: failure)
            let harness = DeterministicManagedProcessHarness(runID: runID)
            _ = try await harness.accept(.launchSucceeded(identity()))
            _ = try await harness.accept(.naturalExit(exitCode: 0, signal: nil))
            do {
                _ = try await failing.publishAtomically(
                    inspection: inspection,
                    diagnostics: ManagedArtifactIdentity(handle: "diagnostics", sizeBytes: 0, sha256: digest(Data())),
                    finalizedAt: acceptedAt
                )
                XCTFail("failure injectionを成功扱いしました: \(failure)")
            } catch {
                XCTAssertEqual(error as? SpoolPublicationFailure, failure)
            }
            let published = await failing.publishedBundle()
            XCTAssertNil(published)
            let snapshot = await harness.snapshot()
            XCTAssertEqual(snapshot.state, .finalizing)
            XCTAssertNil(snapshot.finalization)
        }

        let bundle = try await inspector.publishAtomically(
            inspection: inspection,
            diagnostics: ManagedArtifactIdentity(handle: "diagnostics", sizeBytes: 0, sha256: digest(Data())),
            finalizedAt: acceptedAt
        )
        let successful = DeterministicManagedProcessHarness(runID: runID)
        _ = try await successful.accept(.launchSucceeded(identity()))
        _ = try await successful.accept(.naturalExit(exitCode: 0, signal: nil))
        let terminal = try await successful.accept(.commitFinalization(bundle))
        XCTAssertEqual(terminal.state, .passed)
        XCTAssertEqual(terminal.finalization?.stdout.sha256, digest(stdout))
        XCTAssertEqual(terminal.finalization?.stderr.sha256, digest(stderr))
    }

    func testBarrierReleasesIndependentTasksIntoDurableRegistryOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIShellManagedRace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workflow = DiskTerminationWorkflowFixture(directory: directory)
        let registry = IntegratedCauseRaceFixture(
            runID: runID,
            identity: identity(),
            acceptedSignal: SIGKILL,
            workflow: workflow
        )
        let barrier = AsyncBarrierFixture(participants: 3)
        let raceDate = acceptedAt

        let cancel = Task {
            await barrier.arriveAndWait()
            return try await registry.acceptTerminalCandidate(.cancellation(acceptedAt: raceDate))
        }
        let timeout = Task {
            await barrier.arriveAndWait()
            return try await registry.acceptTerminalCandidate(.timeout(deadline: raceDate))
        }
        let natural = Task {
            await barrier.arriveAndWait()
            return try await registry.acceptTerminalCandidate(
                .naturalExit(exitCode: 0, signal: nil, observedAt: raceDate)
            )
        }
        let records = try await [cancel.value, timeout.value, natural.value]
        XCTAssertEqual(records[0].cause, records[1].cause)
        XCTAssertEqual(records[1].cause, records[2].cause)
        let durable = try XCTUnwrap(workflow.recover(runID: runID))
        XCTAssertEqual(durable.cause, records[0].cause)
        XCTAssertEqual(durable.state, .causePersisted)
        XCTAssertTrue(try workflow.signalAttempts().isEmpty)
    }

    func testIntegratedTerminationWorkflowCoversAllCausesAndCrashWindows() async throws {
        let causeSpecs: [(ManagedDurableTerminalCause, [String], Bool)] = [
            (.cancellation, ["30"], true),
            (.timeout, ["30"], true),
            (.naturalExit(exitCode: 0, signal: nil), ["0.05"], false)
        ]
        for (cause, arguments, expectsSignal) in causeSpecs {
          for crashPoint in SignalReconcileCrash.allCases {
            let caseRunID = UUID()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AIShellSignalOutbox-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let supervisor = MacOSProcessSupervisorFixture()
            let launched = try await supervisor.launch(ManagedSupervisorLaunchRequest(
                runID: caseRunID,
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: arguments,
                workingDirectoryURL: directory
            ))
            if !expectsSignal { try await Task.sleep(for: .milliseconds(100)) }
            let workflow = DiskTerminationWorkflowFixture(directory: directory)
            _ = try workflow.persistCause(ManagedTerminationWorkflowRecord(
                runID: caseRunID,
                cause: cause,
                acceptedAt: acceptedAt,
                identity: launched,
                signal: SIGKILL,
                state: .causePersisted
            ))
            let first = TerminationWorkflowReconcilerFixture(workflow: workflow)
            do {
                try first.reconcile(runID: caseRunID, crash: crashPoint)
                XCTFail("crash injectionが発火しませんでした: \(crashPoint)")
            } catch {
                XCTAssertEqual(error as? SignalReconcileError, .injectedCrash)
            }

            // crash後は新instanceがpending/observationを読み、lost signalなしで完遂する。
            let recovered = TerminationWorkflowReconcilerFixture(workflow: workflow)
            try recovered.reconcile(runID: caseRunID, crash: nil)
            XCTAssertEqual(try workflow.recover(runID: caseRunID)?.state, .acknowledged)
            let oppositeCause: ManagedDurableTerminalCause = cause == .cancellation ? .timeout : .cancellation
            let opposite = try workflow.persistCause(ManagedTerminationWorkflowRecord(
                runID: caseRunID,
                cause: oppositeCause,
                acceptedAt: acceptedAt.addingTimeInterval(1),
                identity: launched,
                signal: SIGKILL,
                state: .causePersisted
            ))
            XCTAssertEqual(opposite.cause, cause)
            XCTAssertFalse(isRunningProcess(launched.processIdentifier))
            let attempts = try workflow.signalAttempts()
            if expectsSignal {
                XCTAssertGreaterThanOrEqual(attempts.count, 1)
                XCTAssertLessThanOrEqual(attempts.count, 2)
                if attempts.count == 2 {
                    XCTAssertTrue(attempts.contains(0), "duplicate signal前に実signal成功がありません。")
                }
            } else {
                XCTAssertTrue(attempts.isEmpty)
            }
          }
        }
    }

    func testPreSpawnCancelAndTimeoutAbortSpawnWithoutIdentityOrSignal() async throws {
        for cause in [ManagedDurableTerminalCause.cancellation, .timeout] {
            for crash in [
                SignalReconcileCrash.afterCauseBeforeOutbox,
                .afterOutboxBeforeSignal,
                .afterObservationBeforeAck
            ] {
                let caseRunID = UUID()
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("AIShellPreSpawn-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let workflow = DiskTerminationWorkflowFixture(directory: directory)
                _ = try workflow.persistCause(ManagedTerminationWorkflowRecord(
                    runID: caseRunID,
                    cause: cause,
                    acceptedAt: acceptedAt,
                    processPhase: .preSpawn,
                    signal: SIGKILL,
                    state: .causePersisted
                ))
                do {
                    try TerminationWorkflowReconcilerFixture(workflow: workflow)
                        .reconcile(runID: caseRunID, crash: crash)
                    XCTFail("pre-spawn crash injectionが発火しませんでした。")
                } catch {
                    XCTAssertEqual(error as? SignalReconcileError, .injectedCrash)
                }
                try TerminationWorkflowReconcilerFixture(workflow: workflow)
                    .reconcile(runID: caseRunID, crash: nil)
                let completed = try XCTUnwrap(workflow.recover(runID: caseRunID))
                XCTAssertEqual(completed.state, .acknowledged)
                XCTAssertEqual(completed.processPhase, .preSpawn)
                XCTAssertTrue(try workflow.signalAttempts().isEmpty)
            }
        }

    }

    func testSpawnReservationLinearizesBothWinnersAndCarriesCancelAcrossIdentityPublication() async throws {
        // cancel wins: 同じactor transactionがspawnAbortedへ進め、launcherは呼ばれない。
        let cancelDirectory = try makeTemporaryDirectory(prefix: "AIShellCancelWins")
        defer { try? FileManager.default.removeItem(at: cancelDirectory) }
        let cancelRunID = UUID()
        let cancelWorkflow = try DurableSpawnReservationWorkflowFixture(
            runID: cancelRunID,
            directory: cancelDirectory
        )
        let cancelBarrier = AsyncBarrierFixture(participants: 2)
        let causeCommitted = AsyncGateFixture()
        let raceDate = acceptedAt
        let cancel = Task {
            await cancelBarrier.arriveAndWait()
            let record = try await cancelWorkflow.admitPreSpawnCause(
                runID: cancelRunID, cause: .cancellation, acceptedAt: raceDate
            )
            await causeCommitted.open()
            return record
        }
        let deniedSpawn = Task {
            await cancelBarrier.arriveAndWait()
            await causeCommitted.wait()
            return try await cancelWorkflow.reserveSpawn(runID: cancelRunID)
        }
        let cancelRecord = try await cancel.value
        let deniedDecision = try await deniedSpawn.value
        XCTAssertEqual(cancelRecord.state, .spawnAborted)
        XCTAssertEqual(deniedDecision, .deniedByPreSpawnCause(.cancellation))

        // spawn wins、identity publication前にcancel: causeをreservationへ保持し、実spawn後へ引き継ぐ。
        try await assertSpawnWinnerCarriesCancel(
            directory: try makeTemporaryDirectory(prefix: "AIShellSpawnWinsBeforeIdentity"),
            cancelBeforeIdentityPublication: true
        )
        // spawn wins、identity publication後にcancel: 同じrecordのspawned identityへcauseを付与する。
        try await assertSpawnWinnerCarriesCancel(
            directory: try makeTemporaryDirectory(prefix: "AIShellSpawnWinsAfterIdentity"),
            cancelBeforeIdentityPublication: false
        )
    }

    func testSpawnReservationRestoresAndSupervisorReconnectsWithoutDuplicateSpawn() async throws {
        let directory = try makeTemporaryDirectory(prefix: "AIShellReservationReconnect")
        defer { try? FileManager.default.removeItem(at: directory) }
        let reservationDirectory = directory.appendingPathComponent("reservation", isDirectory: true)
        let supervisorDirectory = directory.appendingPathComponent("supervisor", isDirectory: true)
        try FileManager.default.createDirectory(at: reservationDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: supervisorDirectory, withIntermediateDirectories: true)
        let caseRunID = UUID()

        let firstRegistry = try DurableSpawnReservationWorkflowFixture(
            runID: caseRunID,
            directory: reservationDirectory
        )
        let decision = try await firstRegistry.reserveSpawn(runID: caseRunID)
        guard case let .reserved(reservationID) = decision else {
            return XCTFail("spawn reservationを取得できませんでした。")
        }

        // reservation永続化直後のactor crash: 新actorは既存recordを上書きせず復元する。
        let restoredRegistry = try DurableSpawnReservationWorkflowFixture(
            runID: caseRunID,
            directory: reservationDirectory
        )
        let restoredReservation = try await restoredRegistry.snapshot(runID: caseRunID)
        XCTAssertEqual(restoredReservation.revision, 1)
        XCTAssertEqual(restoredReservation.state, .spawnReserved(reservationID: reservationID))

        let request = ManagedSupervisorLaunchRequest(
            runID: caseRunID,
            spawnReservationID: reservationID,
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            workingDirectoryURL: directory
        )
        let firstSupervisor = DurableReservationSupervisorFixture(directory: supervisorDirectory)
        let launched = try await firstSupervisor.launchOrReconnect(request, requestDigest: "request-sha")
        let firstBinding = try await firstSupervisor.binding(reservationID: reservationID)
        XCTAssertEqual(
            firstBinding,
            ManagedSupervisorLaunchBinding(
                runID: caseRunID,
                reservationID: reservationID,
                requestDigest: "request-sha",
                state: .spawned(launched),
                spawnCount: 1
            )
        )

        // spawn成功・registryへのidentity公開前のcrash: 新supervisorは同じidentityを返し、再spawnしない。
        let crashRestoredRegistry = try DurableSpawnReservationWorkflowFixture(
            runID: caseRunID,
            directory: reservationDirectory
        )
        let crashRestoredReservation = try await crashRestoredRegistry.snapshot(runID: caseRunID)
        XCTAssertEqual(
            crashRestoredReservation.state,
            .spawnReserved(reservationID: reservationID)
        )
        let restoredSupervisor = DurableReservationSupervisorFixture(directory: supervisorDirectory)
        let reconnected = try await restoredSupervisor.launchOrReconnect(request, requestDigest: "request-sha")
        let reconnectedBinding = try await restoredSupervisor.binding(reservationID: reservationID)
        XCTAssertEqual(reconnected, launched)
        XCTAssertEqual(reconnectedBinding?.spawnCount, 1)

        let published = try await crashRestoredRegistry.publishSpawnIdentity(
            runID: caseRunID,
            reservationID: reservationID,
            identity: reconnected
        )
        XCTAssertEqual(published.state, .spawned(reservationID: reservationID, identity: launched))
        let secondReconnect = try await restoredSupervisor.launchOrReconnect(request, requestDigest: "request-sha")
        let secondReconnectBinding = try await restoredSupervisor.binding(reservationID: reservationID)
        XCTAssertEqual(secondReconnect, launched)
        XCTAssertEqual(secondReconnectBinding?.spawnCount, 1)

        let terminationDirectory = directory.appendingPathComponent("termination", isDirectory: true)
        try FileManager.default.createDirectory(at: terminationDirectory, withIntermediateDirectories: true)
        let termination = DiskTerminationWorkflowFixture(directory: terminationDirectory)
        _ = try termination.persistCause(ManagedTerminationWorkflowRecord(
            runID: caseRunID,
            cause: .cancellation,
            acceptedAt: acceptedAt,
            identity: launched,
            signal: SIGKILL,
            state: .causePersisted
        ))
        try TerminationWorkflowReconcilerFixture(workflow: termination)
            .reconcile(runID: caseRunID, crash: nil)
        XCTAssertEqual(try termination.recover(runID: caseRunID)?.state, .acknowledged)
    }

    func testUnknownReservationOwnerBecomesRecoveryRequiredAndNeverRespawns() async throws {
        let directory = try makeTemporaryDirectory(prefix: "AIShellReservationOwnerUnknown")
        defer { try? FileManager.default.removeItem(at: directory) }
        let reservationDirectory = directory.appendingPathComponent("reservation", isDirectory: true)
        let supervisorDirectory = directory.appendingPathComponent("supervisor", isDirectory: true)
        try FileManager.default.createDirectory(at: reservationDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: supervisorDirectory, withIntermediateDirectories: true)
        let caseRunID = UUID()
        let registry = try DurableSpawnReservationWorkflowFixture(
            runID: caseRunID,
            directory: reservationDirectory
        )
        let decision = try await registry.reserveSpawn(runID: caseRunID)
        guard case let .reserved(reservationID) = decision else {
            return XCTFail("spawn reservationを取得できませんでした。")
        }
        let sideEffect = directory.appendingPathComponent("must-not-exist")
        let request = ManagedSupervisorLaunchRequest(
            runID: caseRunID,
            spawnReservationID: reservationID,
            executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
            arguments: [sideEffect.path],
            workingDirectoryURL: directory
        )
        let firstSupervisor = DurableReservationSupervisorFixture(directory: supervisorDirectory)
        try await firstSupervisor.persistUnknownOwnerForTest(
            runID: caseRunID,
            reservationID: reservationID,
            requestDigest: "request-sha"
        )

        let restoredSupervisor = DurableReservationSupervisorFixture(directory: supervisorDirectory)
        do {
            _ = try await restoredSupervisor.launchOrReconnect(request, requestDigest: "request-sha")
            XCTFail("owner不明のreservationを再spawnしました。")
        } catch {
            XCTAssertEqual(error as? ReservationSupervisorFixtureError, .recoveryRequired)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sideEffect.path))
        let binding = try await restoredSupervisor.binding(reservationID: reservationID)
        XCTAssertEqual(binding?.state, .recoveryRequired)
        XCTAssertEqual(binding?.spawnCount, 0)
        let reservation = try await registry.snapshot(runID: caseRunID)
        XCTAssertEqual(
            reservation.state,
            .spawnReserved(reservationID: reservationID)
        )
    }

    func testSignalReconciliationRefusesPGIDOnlyAndReusedPIDWithoutSignalling() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIShellSignalIdentity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let supervisor = MacOSProcessSupervisorFixture()
        let launched = try await supervisor.launch(ManagedSupervisorLaunchRequest(
            runID: runID,
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            workingDirectoryURL: directory
        ))
        let invalidIdentities = [
            ManagedProcessIdentity(
                processIdentifier: 999_999,
                processStartIdentity: "unavailable",
                processGroupIdentifier: launched.processGroupIdentifier,
                bootSessionIdentity: launched.bootSessionIdentity,
                supervisorNonce: launched.supervisorNonce
            ),
            ManagedProcessIdentity(
                processIdentifier: launched.processIdentifier,
                processStartIdentity: "reused-pid-start",
                processGroupIdentifier: launched.processGroupIdentifier,
                bootSessionIdentity: launched.bootSessionIdentity,
                supervisorNonce: launched.supervisorNonce
            )
        ]
        for (index, invalidIdentity) in invalidIdentities.enumerated() {
            let caseDirectory = directory.appendingPathComponent("case-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: caseDirectory, withIntermediateDirectories: true)
            let workflow = DiskTerminationWorkflowFixture(directory: caseDirectory)
            _ = try workflow.persistCause(ManagedTerminationWorkflowRecord(
                runID: runID,
                cause: .cancellation,
                acceptedAt: acceptedAt,
                identity: invalidIdentity,
                signal: SIGKILL,
                state: .causePersisted
            ))
            do {
                try TerminationWorkflowReconcilerFixture(workflow: workflow).reconcile(runID: runID, crash: nil)
                XCTFail("identityを証明できないPGIDへsignalしました。")
            } catch {
                XCTAssertEqual(error as? SignalReconcileError, .recoveryRequired)
            }
            XCTAssertTrue(try workflow.signalAttempts().isEmpty)
            XCTAssertTrue(isRunningProcess(launched.processIdentifier))
            XCTAssertEqual(try workflow.recover(runID: runID)?.state, .outboxPending)
        }
        let permissionDirectory = directory.appendingPathComponent("case-eperm", isDirectory: true)
        try FileManager.default.createDirectory(at: permissionDirectory, withIntermediateDirectories: true)
        let permissionWorkflow = DiskTerminationWorkflowFixture(directory: permissionDirectory)
        _ = try permissionWorkflow.persistCause(ManagedTerminationWorkflowRecord(
            runID: runID,
            cause: .timeout,
            acceptedAt: acceptedAt,
            identity: invalidIdentities[0],
            signal: SIGKILL,
            state: .causePersisted
        ))
        do {
            try TerminationWorkflowReconcilerFixture(
                workflow: permissionWorkflow,
                processGroupProbe: FixedProcessGroupProbeFixture(result: .permissionDenied)
            ).reconcile(runID: runID, crash: nil)
            XCTFail("EPERMをgroup消滅としてackしました。")
        } catch {
            XCTAssertEqual(error as? SignalReconcileError, .recoveryRequired)
        }
        XCTAssertTrue(try permissionWorkflow.signalAttempts().isEmpty)
        XCTAssertEqual(try permissionWorkflow.recover(runID: runID)?.state, .outboxPending)
        let proof = ManagedProcessIdentityProof(runID: runID, expected: launched, observed: launched)
        _ = try await supervisor.stop(runID: runID, proof: proof)
    }

    func testSignalDeliveryClassificationFailsClosedAndReapIsBounded() async throws {
        let failures: [ManagedSignalDeliveryResult] = [
            .permissionDenied,
            .failed(errno: EIO),
            .processGroupAbsentESRCH
        ]
        for (index, failure) in failures.enumerated() {
            let caseRunID = UUID()
            let directory = try makeTemporaryDirectory(prefix: "AIShellSignalFailure-\(index)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let supervisor = MacOSProcessSupervisorFixture()
            let launched = try await supervisor.launch(ManagedSupervisorLaunchRequest(
                runID: caseRunID,
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                workingDirectoryURL: directory
            ))
            let workflow = DiskTerminationWorkflowFixture(directory: directory)
            _ = try workflow.persistCause(ManagedTerminationWorkflowRecord(
                runID: caseRunID,
                cause: .cancellation,
                acceptedAt: acceptedAt,
                identity: launched,
                signal: SIGKILL,
                state: .causePersisted
            ))
            let started = Date()
            do {
                try TerminationWorkflowReconcilerFixture(
                    workflow: workflow,
                    signalDelivery: FixedSignalDeliveryFixture(result: failure),
                    reapAttempts: 5,
                    reapPollMicroseconds: 10_000
                ).reconcile(runID: caseRunID, crash: nil)
                XCTFail("signal failureを成功扱いしました: \(failure)")
            } catch {
                XCTAssertEqual(error as? SignalReconcileError, .recoveryRequired)
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "waitpidがdeadlineを超えてblockしました。")
            XCTAssertTrue(isRunningProcess(launched.processIdentifier))
            XCTAssertEqual(try workflow.recover(runID: caseRunID)?.state, .outboxPending)
            let attempts = try workflow.signalAttempts()
            switch failure {
            case .permissionDenied: XCTAssertEqual(attempts, [-EPERM])
            case let .failed(errorNumber): XCTAssertEqual(attempts, [-errorNumber])
            case .processGroupAbsentESRCH: XCTAssertEqual(attempts, [-ESRCH])
            case .delivered: XCTFail("failure fixtureへdeliveredが混入しました。")
            }
            let proof = ManagedProcessIdentityProof(runID: caseRunID, expected: launched, observed: launched)
            _ = try await supervisor.stop(runID: caseRunID, proof: proof)
        }
    }

    func testLegacySignalDispatchedMigratesToPendingReconciliationNotAcknowledged() {
        let migrated = ManagedTerminationWorkflowRecord(
            migrating: ManagedLegacyTerminalCauseRecordV1(
                runID: runID,
                cause: .cancellation,
                acceptedAt: acceptedAt,
                signalDispatched: true
            ),
            identity: identity(),
            signal: SIGKILL
        )
        XCTAssertEqual(migrated.state, .outboxPending)
        XCTAssertNotEqual(migrated.state, .acknowledged)
    }

    func testNewAdapterInstancesRecoverFromDurableRecordAndFailClosed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIShellAdapterRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = directory.appendingPathComponent("supervisor.endpoint")
        let recordURL = directory.appendingPathComponent("run-record.json")
        let durableCursor = ManagedEvidenceCursor(
            runID: runID,
            eventSequence: 7,
            stdoutOffset: 31,
            stderrOffset: 17,
            diagnosticOffset: 5
        )
        let record = ManagedAdapterRecoveryRecord(
            runID: runID,
            runHandle: "authenticated-run-handle",
            stateRevision: 19,
            cursor: durableCursor,
            processIdentity: identity(),
            supervisorEndpoint: endpoint.path
        )
        try writeJSONAndFsync(record, to: recordURL)
        try writeJSONAndFsync(
            SupervisorEndpointFixture(
                supervisorNonce: identity().supervisorNonce,
                bootSessionIdentity: identity().bootSessionIdentity,
                processStartIdentity: identity().processStartIdentity
            ),
            to: endpoint
        )

        let first = DurableAdapterRecoveryFixture(recordURL: recordURL, sessionNonce: "transport-session-1")
        let firstResult = try await first.reconnect(runID: runID)
        let second = DurableAdapterRecoveryFixture(recordURL: recordURL, sessionNonce: "transport-session-2")
        let secondResult = try await second.reconnect(runID: runID)
        XCTAssertNotEqual(firstResult.transportSessionNonce, secondResult.transportSessionNonce)
        XCTAssertEqual(firstResult.record.runHandle, secondResult.record.runHandle)
        XCTAssertEqual(firstResult.record.stateRevision, secondResult.record.stateRevision)
        XCTAssertEqual(firstResult.record.cursor, secondResult.record.cursor)

        try FileManager.default.removeItem(at: endpoint)
        let afterSupervisorLoss = DurableAdapterRecoveryFixture(recordURL: recordURL, sessionNonce: "transport-session-3")
        await assertReconnectFailsClosed(afterSupervisorLoss)

        try writeJSONAndFsync(
            SupervisorEndpointFixture(
                supervisorNonce: identity().supervisorNonce,
                bootSessionIdentity: "different-boot",
                processStartIdentity: identity().processStartIdentity
            ),
            to: endpoint
        )
        let afterBootChange = DurableAdapterRecoveryFixture(recordURL: recordURL, sessionNonce: "transport-session-4")
        await assertReconnectFailsClosed(afterBootChange)
    }

    func testUnixSocketReconnectReobservesLiveIdentityAndNegativeRecoveryBecomesInterrupted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIShellUnixRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let supervisor = MacOSProcessSupervisorFixture()
        let launched = try await supervisor.launch(ManagedSupervisorLaunchRequest(
            runID: runID,
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            workingDirectoryURL: directory
        ))
        let socketURL = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("aishell-\(UUID().uuidString.prefix(12)).sock")
        defer { try? FileManager.default.removeItem(at: socketURL) }
        let recordURL = directory.appendingPathComponent("socket-run-record.json")
        let authenticationKeyURL = directory.appendingPathComponent("supervisor-auth.key")
        let authenticationKey = Data("fixture-supervisor-only-secret".utf8)
        let authenticationMaterial = ManagedSupervisorAuthenticationMaterial(
            runID: runID,
            supervisorNonce: launched.supervisorNonce,
            secret: authenticationKey,
            allowedEffectiveUserIdentifier: geteuid(),
            allowedEffectiveGroupIdentifier: getegid()
        )
        try createExclusiveAuthenticationMaterial(authenticationMaterial, at: authenticationKeyURL)
        let record = ManagedAdapterRecoveryRecord(
            runID: runID,
            runHandle: "socket-bound-handle",
            stateRevision: 23,
            cursor: ManagedEvidenceCursor(runID: runID, eventSequence: 9, stdoutOffset: 4),
            processIdentity: launched,
            supervisorEndpoint: socketURL.path
        )
        try writeJSONAndFsync(record, to: recordURL)

        let liveServer = try UnixSupervisorSocketFixture(
            socketURL: socketURL,
            runID: runID,
            identity: launched,
            authenticationMaterial: authenticationMaterial,
            responseBootIdentity: launched.bootSessionIdentity,
            expectedConnections: 2
        )
        let first = UnixSocketAdapterRecoveryFixture(
            recordURL: recordURL, authenticationKeyURL: authenticationKeyURL, sessionNonce: "unix-session-1"
        )
        let second = UnixSocketAdapterRecoveryFixture(
            recordURL: recordURL, authenticationKeyURL: authenticationKeyURL, sessionNonce: "unix-session-2"
        )
        let firstResult = try await first.reconnect(runID: runID)
        let secondResult = try await second.reconnect(runID: runID)
        XCTAssertEqual(firstResult.record.runHandle, secondResult.record.runHandle)
        XCTAssertEqual(firstResult.record.stateRevision, secondResult.record.stateRevision)
        XCTAssertEqual(firstResult.record.cursor, secondResult.record.cursor)
        XCTAssertNotEqual(firstResult.transportSessionNonce, secondResult.transportSessionNonce)
        try await liveServer.waitUntilFinished()
        let receivedSessions = await liveServer.receivedSessionNonces()
        XCTAssertEqual(receivedSessions, ["unix-session-1", "unix-session-2"])

        let socketLoss = UnixSocketAdapterRecoveryFixture(
            recordURL: recordURL, authenticationKeyURL: authenticationKeyURL, sessionNonce: "unix-session-3"
        )
        let lossHarness = DeterministicManagedProcessHarness(runID: runID)
        _ = try await lossHarness.accept(.launchSucceeded(launched))
        _ = try await lossHarness.accept(.supervisorUnavailable)
        await assertUnixReconnectFailsAndStaysRecovery(socketLoss, harness: lossHarness, runID: runID)

        let changedBootServer = try UnixSupervisorSocketFixture(
            socketURL: socketURL,
            runID: runID,
            identity: launched,
            authenticationMaterial: authenticationMaterial,
            responseBootIdentity: "different-boot",
            expectedConnections: 1
        )
        let bootMismatch = UnixSocketAdapterRecoveryFixture(
            recordURL: recordURL, authenticationKeyURL: authenticationKeyURL, sessionNonce: "unix-session-4"
        )
        let bootHarness = DeterministicManagedProcessHarness(runID: runID)
        _ = try await bootHarness.accept(.launchSucceeded(launched))
        _ = try await bootHarness.accept(.supervisorUnavailable)
        await assertUnixReconnectFailsAndStaysRecovery(bootMismatch, harness: bootHarness, runID: runID)
        try await changedBootServer.waitUntilFinished()

        let wrongSocketServer = try UnixSupervisorSocketFixture(
            socketURL: socketURL,
            runID: runID,
            identity: launched,
            authenticationMaterial: ManagedSupervisorAuthenticationMaterial(
                runID: runID,
                supervisorNonce: launched.supervisorNonce,
                secret: Data("wrong-socket-secret".utf8),
                allowedEffectiveUserIdentifier: geteuid(),
                allowedEffectiveGroupIdentifier: getegid()
            ),
            responseBootIdentity: launched.bootSessionIdentity,
            expectedConnections: 1
        )
        let wrongSocket = UnixSocketAdapterRecoveryFixture(
            recordURL: recordURL, authenticationKeyURL: authenticationKeyURL, sessionNonce: "unix-session-5"
        )
        let wrongSocketHarness = DeterministicManagedProcessHarness(runID: runID)
        _ = try await wrongSocketHarness.accept(.launchSucceeded(launched))
        _ = try await wrongSocketHarness.accept(.supervisorUnavailable)
        await assertUnixReconnectFailsAndStaysRecovery(wrongSocket, harness: wrongSocketHarness, runID: runID)
        try? await wrongSocketServer.waitUntilFinished()

        let proof = ManagedProcessIdentityProof(runID: runID, expected: launched, observed: launched)
        let stopped = try await supervisor.stop(runID: runID, proof: proof)
        XCTAssertTrue(stopped.processGroupIsGone)
        await finalizeInterruptedAfterRealStop(lossHarness)
        await finalizeInterruptedAfterRealStop(bootHarness)
        await finalizeInterruptedAfterRealStop(wrongSocketHarness)
    }

    func testSeparateAdapterProcessesReconnectWithNewPIDAndShortLivedSignedCredential() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3がありません。")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIShellExternalAdapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let caseRunID = UUID()
        let supervisor = MacOSProcessSupervisorFixture()
        let launched = try await supervisor.launch(ManagedSupervisorLaunchRequest(
            runID: caseRunID,
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            workingDirectoryURL: directory
        ))
        let socketURL = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("aishell-ext-\(UUID().uuidString.prefix(10)).sock")
        defer { try? FileManager.default.removeItem(at: socketURL) }
        let materialURL = directory.appendingPathComponent("owner-auth.json")
        let material = ManagedSupervisorAuthenticationMaterial(
            runID: caseRunID,
            supervisorNonce: launched.supervisorNonce,
            secret: Data("external-adapter-secret".utf8),
            allowedEffectiveUserIdentifier: geteuid(),
            allowedEffectiveGroupIdentifier: getegid()
        )
        try createExclusiveAuthenticationMaterial(material, at: materialURL)
        XCTAssertThrowsError(try createExclusiveAuthenticationMaterial(material, at: materialURL))
        let server = try UnixSupervisorSocketFixture(
            socketURL: socketURL,
            runID: caseRunID,
            identity: launched,
            authenticationMaterial: material,
            responseBootIdentity: launched.bootSessionIdentity,
            expectedConnections: 2
        )
        let scriptURL = directory.appendingPathComponent("adapter_client.py")
        try externalAdapterScript.write(to: scriptURL, atomically: true, encoding: .utf8)

        let firstPIDURL = directory.appendingPathComponent("first.pid")
        let secondPIDURL = directory.appendingPathComponent("second.pid")
        let first = try launchExternalAdapter(
            scriptURL: scriptURL, socketURL: socketURL, runID: caseRunID,
            materialURL: materialURL, session: "external-session-1", pidURL: firstPIDURL
        )
        let second = try launchExternalAdapter(
            scriptURL: scriptURL, socketURL: socketURL, runID: caseRunID,
            materialURL: materialURL, session: "external-session-2", pidURL: secondPIDURL
        )
        first.waitUntilExit()
        second.waitUntilExit()
        XCTAssertEqual(first.terminationStatus, 0)
        XCTAssertEqual(second.terminationStatus, 0)
        try await server.waitUntilFinished()
        let firstPID = try pid(from: firstPIDURL)
        let secondPID = try pid(from: secondPIDURL)
        XCTAssertNotEqual(firstPID, secondPID)
        let sessions = await server.receivedSessionNonces()
        XCTAssertEqual(Set(sessions), Set(["external-session-1", "external-session-2"]))

        let proof = ManagedProcessIdentityProof(runID: caseRunID, expected: launched, observed: launched)
        _ = try await supervisor.stop(runID: caseRunID, proof: proof)
    }

    func testDiskPublicationIsAllOrNoneAcrossEveryWriteFsyncAndRenameFailure() async throws {
        let stdout = Data([0x00, 0xff, 0x0a, 0x41])
        let stderr = Data([0x80, 0x42, 0x0a])
        for failure in DiskPublicationFailure.allCases {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AIShellAtomicPublish-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let stdoutURL = directory.appendingPathComponent("stdout.spool")
            let stderrURL = directory.appendingPathComponent("stderr.spool")
            let diagnosticURL = directory.appendingPathComponent("diagnostic.spool")
            try writeAndFsync(stdout, to: stdoutURL)
            try writeAndFsync(stderr, to: stderrURL)
            try writeAndFsync(Data(), to: diagnosticURL)

            let failing = DiskAtomicPublisherFixture(
                root: directory, runID: runID, requestDigest: "request-sha",
                stdoutURL: stdoutURL, stderrURL: stderrURL, diagnosticURL: diagnosticURL, failure: failure
            )
            let inspection = try await failing.fsyncAndInspect(stdoutURL: stdoutURL, stderrURL: stderrURL)
            do {
                _ = try await failing.publishAtomically(
                    inspection: inspection,
                    diagnostics: ManagedArtifactIdentity(handle: "diagnostics", sizeBytes: 0, sha256: digest(Data())),
                    finalizedAt: acceptedAt
                )
                XCTFail("failure injectionを成功扱いしました: \(failure)")
            } catch {
                XCTAssertEqual(error as? DiskPublicationFailure, failure)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: failing.publicRunURL.path))

            let retry = DiskAtomicPublisherFixture(
                root: directory, runID: runID, requestDigest: "request-sha",
                stdoutURL: stdoutURL, stderrURL: stderrURL, diagnosticURL: diagnosticURL, failure: nil
            )
            let published = try await retry.publishAtomically(
                inspection: inspection,
                diagnostics: ManagedArtifactIdentity(handle: "diagnostics", sizeBytes: 0, sha256: digest(Data())),
                finalizedAt: acceptedAt
            )
            let replay = try await retry.publishAtomically(
                inspection: inspection,
                diagnostics: ManagedArtifactIdentity(handle: "diagnostics", sizeBytes: 0, sha256: digest(Data())),
                finalizedAt: acceptedAt
            )
            XCTAssertEqual(replay, published)
            let publicEntries = try FileManager.default.contentsOfDirectory(
                at: retry.publicRootURL,
                includingPropertiesForKeys: nil
            )
            XCTAssertEqual(publicEntries.map(\.lastPathComponent), [runID.uuidString.lowercased()])
            XCTAssertEqual(
                Set(try FileManager.default.contentsOfDirectory(atPath: retry.publicRunURL.path)),
                Set(["stdout.artifact", "stderr.artifact", "diagnostic.artifact", "metadata.json", "registry-index.json"])
            )
            XCTAssertEqual(try Data(contentsOf: retry.publicRunURL.appendingPathComponent("stdout.artifact")), stdout)
            XCTAssertEqual(try Data(contentsOf: retry.publicRunURL.appendingPathComponent("stderr.artifact")), stderr)
        }
    }

    func testDiskPublicationReplayRejectsEveryBindingMismatchAndPreservesOriginalTime() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIShellReplayBinding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("stdout.spool")
        let stderrURL = directory.appendingPathComponent("stderr.spool")
        let diagnosticURL = directory.appendingPathComponent("diagnostic.spool")
        try writeAndFsync(Data("stdout\n".utf8), to: stdoutURL)
        try writeAndFsync(Data("stderr\n".utf8), to: stderrURL)
        let diagnosticData = Data("diag".utf8)
        try writeAndFsync(diagnosticData, to: diagnosticURL)
        let diagnostics = ManagedArtifactIdentity(
            handle: "diagnostics", sizeBytes: UInt64(diagnosticData.count), sha256: digest(diagnosticData)
        )
        let publisher = DiskAtomicPublisherFixture(
            root: directory, runID: runID, requestDigest: "request-a",
            stdoutURL: stdoutURL, stderrURL: stderrURL, diagnosticURL: diagnosticURL, failure: nil
        )
        let inspection = try await publisher.fsyncAndInspect(stdoutURL: stdoutURL, stderrURL: stderrURL)
        let original = try await publisher.publishAtomically(
            inspection: inspection, diagnostics: diagnostics, finalizedAt: acceptedAt
        )

        let changedInspection = ManagedSpoolInspection(
            stdout: ManagedArtifactIdentity(
                handle: inspection.stdout.handle,
                sizeBytes: inspection.stdout.sizeBytes,
                lineCount: inspection.stdout.lineCount,
                sha256: "changed-stdout-sha"
            ),
            stderr: inspection.stderr
        )
        await assertReplayCorrupt {
            try await publisher.publishAtomically(
                inspection: changedInspection, diagnostics: diagnostics, finalizedAt: acceptedAt
            )
        }
        await assertReplayCorrupt {
            try await publisher.publishAtomically(
                inspection: inspection,
                diagnostics: ManagedArtifactIdentity(handle: "diagnostics", sizeBytes: 4, sha256: "other-diagnostic"),
                finalizedAt: acceptedAt
            )
        }
        await assertReplayCorrupt {
            try await publisher.publishAtomically(
                inspection: inspection, diagnostics: diagnostics,
                finalizedAt: acceptedAt.addingTimeInterval(1)
            )
        }
        let differentRequest = DiskAtomicPublisherFixture(
            root: directory, runID: runID, requestDigest: "request-b",
            stdoutURL: stdoutURL, stderrURL: stderrURL, diagnosticURL: diagnosticURL, failure: nil
        )
        await assertReplayCorrupt {
            try await differentRequest.publishAtomically(
                inspection: inspection, diagnostics: diagnostics, finalizedAt: acceptedAt
            )
        }

        let exactReplay = try await publisher.publishAtomically(
            inspection: inspection, diagnostics: diagnostics, finalizedAt: acceptedAt
        )
        XCTAssertEqual(exactReplay.finalizedAt, original.finalizedAt)
        XCTAssertEqual(exactReplay.finalizedAt, acceptedAt)

        let publishedDiagnostic = publisher.publicRunURL.appendingPathComponent("diagnostic.artifact")
        try FileManager.default.removeItem(at: publishedDiagnostic)
        await assertReplayCorrupt {
            try await publisher.publishAtomically(
                inspection: inspection, diagnostics: diagnostics, finalizedAt: acceptedAt
            )
        }
        try writeAndFsync(diagnosticData, to: publishedDiagnostic)
        try writeAndFsync(Data("tampered-diagnostic".utf8), to: publishedDiagnostic)
        await assertReplayCorrupt {
            try await publisher.publishAtomically(
                inspection: inspection, diagnostics: diagnostics, finalizedAt: acceptedAt
            )
        }
        try writeAndFsync(diagnosticData, to: publishedDiagnostic)
        try writeAndFsync(Data("tampered\n".utf8), to: publisher.publicRunURL.appendingPathComponent("stdout.artifact"))
        await assertReplayCorrupt {
            try await publisher.publishAtomically(
                inspection: inspection, diagnostics: diagnostics, finalizedAt: acceptedAt
            )
        }
    }

    private func identity(start: String = "pid-start-1") -> ManagedProcessIdentity {
        ManagedProcessIdentity(
            processIdentifier: 41,
            processStartIdentity: start,
            processGroupIdentifier: 41,
            bootSessionIdentity: "boot-1",
            supervisorNonce: "nonce-1"
        )
    }

    private func bundle(at date: Date, emptyStreams: Bool = false) -> ManagedFinalizationBundle {
        ManagedFinalizationBundle(
            stdout: ManagedArtifactIdentity(
                handle: "stdout",
                sizeBytes: emptyStreams ? 0 : 8,
                sha256: emptyStreams ? "empty" : "stdout-sha"
            ),
            stderr: ManagedArtifactIdentity(
                handle: "stderr",
                sizeBytes: emptyStreams ? 0 : 13,
                sha256: emptyStreams ? "empty" : "stderr-sha"
            ),
            diagnostics: ManagedArtifactIdentity(handle: "diagnostics", sizeBytes: 0, sha256: "empty"),
            runIndexDigest: "index-sha",
            finalizedAt: date
        )
    }

    private func writeAndFsync(_ data: Data, to url: URL) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func assertSpawnWinnerCarriesCancel(
        directory: URL,
        cancelBeforeIdentityPublication: Bool
    ) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let caseRunID = UUID()
        let reservation = try DurableSpawnReservationWorkflowFixture(
            runID: caseRunID,
            directory: directory
        )
        let barrier = AsyncBarrierFixture(participants: 2)
        let reservedGate = AsyncGateFixture()
        let identityGate = AsyncGateFixture()
        let raceDate = acceptedAt
        let reserveTask = Task {
            await barrier.arriveAndWait()
            let decision = try await reservation.reserveSpawn(runID: caseRunID)
            await reservedGate.open()
            return decision
        }
        let cancelTask = Task {
            await barrier.arriveAndWait()
            if cancelBeforeIdentityPublication {
                await reservedGate.wait()
            } else {
                await identityGate.wait()
            }
            return try await reservation.admitPreSpawnCause(
                runID: caseRunID,
                cause: .cancellation,
                acceptedAt: raceDate
            )
        }
        let decision = try await reserveTask.value
        guard case let .reserved(reservationID) = decision else {
            return XCTFail("spawn winner fixtureでreservationを取得できませんでした。")
        }
        if cancelBeforeIdentityPublication { _ = try await cancelTask.value }

        let supervisor = MacOSProcessSupervisorFixture()
        let launched = try await supervisor.launch(ManagedSupervisorLaunchRequest(
            runID: caseRunID,
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            workingDirectoryURL: directory
        ))
        let published = try await reservation.publishSpawnIdentity(
            runID: caseRunID,
            reservationID: reservationID,
            identity: launched
        )
        await identityGate.open()
        if !cancelBeforeIdentityPublication { _ = try await cancelTask.value }
        let durable = try await reservation.snapshot(runID: caseRunID)
        XCTAssertEqual(durable.terminationCause, .cancellation)
        guard case let .spawned(_, durableIdentity) = durable.state else {
            return XCTFail("spawn identityがdurable recordへ公開されていません。")
        }
        XCTAssertEqual(durableIdentity, launched)
        if cancelBeforeIdentityPublication {
            XCTAssertEqual(published.terminationCause, .cancellation)
        }

        let terminationDirectory = directory.appendingPathComponent("termination", isDirectory: true)
        try FileManager.default.createDirectory(at: terminationDirectory, withIntermediateDirectories: true)
        let termination = DiskTerminationWorkflowFixture(directory: terminationDirectory)
        _ = try termination.persistCause(ManagedTerminationWorkflowRecord(
            runID: caseRunID,
            cause: .cancellation,
            acceptedAt: try XCTUnwrap(durable.causeAcceptedAt),
            identity: durableIdentity,
            signal: SIGKILL,
            state: .causePersisted
        ))
        try TerminationWorkflowReconcilerFixture(workflow: termination)
            .reconcile(runID: caseRunID, crash: nil)
        XCTAssertEqual(try termination.recover(runID: caseRunID)?.state, .acknowledged)
    }

    private func writeJSONAndFsync<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writeAndFsync(try encoder.encode(value), to: url)
    }

    private func assertReconnectFailsClosed(_ adapter: DurableAdapterRecoveryFixture) async {
        do {
            _ = try await adapter.reconnect(runID: runID)
            XCTFail("supervisor/boot identity不一致をrunningへ推測復帰しました。")
        } catch {
            XCTAssertEqual(error as? AdapterRecoveryFixtureError, .recoveryRequired)
        }
    }

    private func assertUnixReconnectFailsAndStaysRecovery(
        _ adapter: UnixSocketAdapterRecoveryFixture,
        harness: DeterministicManagedProcessHarness,
        runID: UUID
    ) async {
        do {
            _ = try await adapter.reconnect(runID: runID)
            XCTFail("socket/boot failureをrunningへ復帰しました。")
        } catch {
            XCTAssertEqual(error as? AdapterRecoveryFixtureError, .recoveryRequired)
        }
        let stillRecovery = await harness.snapshot()
        XCTAssertEqual(stillRecovery.state, .recoveryRequired)
    }

    private func finalizeInterruptedAfterRealStop(_ harness: DeterministicManagedProcessHarness) async {
        do {
            _ = try await harness.accept(.recoveredProcessStopped)
            let terminal = try await harness.accept(.commitFinalization(bundle(at: acceptedAt)))
            XCTAssertEqual(terminal.state, .interrupted)
        } catch {
            XCTFail("recovery_required→interruptedに確定できません: \(error)")
        }
    }

    private func assertReplayCorrupt(
        _ operation: () async throws -> ManagedFinalizationBundle
    ) async {
        do {
            _ = try await operation()
            XCTFail("異なるfinalization bindingを既存publicationとして再利用しました。")
        } catch {
            XCTAssertEqual(error as? DiskReplayError, .bindingMismatch)
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func waitForFiles(_ urls: [URL]) async throws {
        for _ in 0..<100 {
            if urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ProcessSupervisorFixtureError.fixtureTimeout
    }

    private func pid(from url: URL) throws -> pid_t {
        guard let value = pid_t(String(decoding: try Data(contentsOf: url), as: UTF8.self)) else {
            throw ProcessSupervisorFixtureError.invalidPID
        }
        return value
    }

    private func isRunningProcess(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let returned = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(size))
        }
        guard returned == size else { return false }
        return info.pbi_status != SZOMB
    }

    private var processTreeScript: String {
        """
        import os, signal, subprocess, sys, time
        role, directory = sys.argv[1], sys.argv[2]
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if role == "root":
            child = subprocess.Popen([sys.executable, __file__, "child", directory])
            open(os.path.join(directory, "child.pid"), "w").write(str(child.pid))
        elif role == "child":
            grandchild = subprocess.Popen([sys.executable, __file__, "grandchild", directory])
            open(os.path.join(directory, "grandchild.pid"), "w").write(str(grandchild.pid))
        time.sleep(30)
        """
    }

    private func launchExternalAdapter(
        scriptURL: URL,
        socketURL: URL,
        runID: UUID,
        materialURL: URL,
        session: String,
        pidURL: URL
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            scriptURL.path,
            socketURL.path,
            runID.uuidString.lowercased(),
            materialURL.path,
            session,
            pidURL.path
        ]
        try process.run()
        return process
    }

    private var externalAdapterScript: String {
        """
        import base64, hashlib, hmac, json, os, socket, sys, time, uuid
        socket_path, run_id, material_path, session, pid_path = sys.argv[1:]
        with open(material_path, "r") as stream:
            material = json.load(stream)
        key = base64.b64decode(material["secret"])
        pid = os.getpid()
        expires = int(time.time() * 1000) + 30000
        challenge = str(uuid.uuid4()).lower()
        request = {
            "runID": run_id,
            "transportSessionNonce": session,
            "clientChallenge": challenge,
            "adapterProcessIdentifier": pid,
            "credentialExpiresAtUnixMilliseconds": expires,
        }
        def proof(label, server_challenge):
            message = f"{label}\\0{run_id.lower()}\\0{session}\\0{challenge}\\0{pid}\\0{expires}\\0{server_challenge}".encode()
            return base64.b64encode(hmac.new(key, message, hashlib.sha256).digest()).decode()
        with open(pid_path, "w") as stream:
            stream.write(str(pid))
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.connect(socket_path)
        stream = connection.makefile("rwb", buffering=0)
        stream.write(json.dumps(request, separators=(",", ":")).encode() + b"\\n")
        server = json.loads(stream.readline())
        if not hmac.compare_digest(server["supervisorProof"], proof("supervisor", server["supervisorChallenge"])):
            raise RuntimeError("server proof mismatch")
        response = {"clientProof": proof("client", server["supervisorChallenge"])}
        stream.write(json.dumps(response, separators=(",", ":")).encode() + b"\\n")
        final = json.loads(stream.readline())
        if final["supervisorNonce"] != material["supervisorNonce"]:
            raise RuntimeError("supervisor identity mismatch")
        connection.close()
        """
    }
}

private struct ProcessSupervisorAdapterFixture: Sendable {
    let supervisor: any ProcessSupervisorSeam

    func launch(_ request: ManagedSupervisorLaunchRequest) async throws -> ManagedProcessIdentity {
        try await supervisor.launch(request)
    }

    func reconnect(runID: UUID, expectedIdentity: ManagedProcessIdentity) async throws -> ManagedProcessIdentityProof {
        try await supervisor.reconnect(runID: runID, expectedIdentity: expectedIdentity)
    }

    func stop(runID: UUID, proof: ManagedProcessIdentityProof) async throws -> ManagedSupervisorStopReport {
        try await supervisor.stop(runID: runID, proof: proof)
    }
}

private enum ProcessSupervisorFixtureError: Error, Equatable {
    case spawnFailed(Int32)
    case identityUnavailable
    case identityMismatch
    case unknownRun
    case fixtureTimeout
    case invalidPID
}

private actor MacOSProcessSupervisorFixture: ProcessSupervisorSeam {
    private struct Record {
        let identity: ManagedProcessIdentity
        let pid: pid_t
        let processGroup: pid_t
    }

    private var records: [UUID: Record] = [:]
    private var signalAttempts = 0

    func launch(_ request: ManagedSupervisorLaunchRequest) throws -> ManagedProcessIdentity {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attributes)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawn_file_actions_addchdir_np(&actions, request.workingDirectoryURL.path)

        let values = [request.executableURL.path] + request.arguments
        var argv = values.map { strdup($0) } + [nil]
        defer { argv.dropLast().forEach { free($0) } }
        var pid: pid_t = 0
        let result = request.executableURL.path.withCString { executable in
            argv.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(&pid, executable, &actions, &attributes, buffer.baseAddress, environ)
            }
        }
        guard result == 0 else { throw ProcessSupervisorFixtureError.spawnFailed(result) }
        guard let observed = Self.observe(pid: pid, processGroup: pid) else {
            _ = Darwin.kill(-pid, SIGKILL)
            throw ProcessSupervisorFixtureError.identityUnavailable
        }
        let identity = ManagedProcessIdentity(
            processIdentifier: pid,
            processStartIdentity: observed,
            processGroupIdentifier: pid,
            bootSessionIdentity: "fixture-boot-session",
            supervisorNonce: "fixture-supervisor-nonce"
        )
        records[request.runID] = Record(identity: identity, pid: pid, processGroup: pid)
        return identity
    }

    func reconnect(runID: UUID, expectedIdentity: ManagedProcessIdentity) throws -> ManagedProcessIdentityProof {
        guard let record = records[runID] else { throw ProcessSupervisorFixtureError.unknownRun }
        guard let start = Self.observe(pid: record.pid, processGroup: record.processGroup) else {
            throw ProcessSupervisorFixtureError.identityUnavailable
        }
        let observed = ManagedProcessIdentity(
            processIdentifier: record.pid,
            processStartIdentity: start,
            processGroupIdentifier: record.processGroup,
            bootSessionIdentity: record.identity.bootSessionIdentity,
            supervisorNonce: record.identity.supervisorNonce
        )
        guard expectedIdentity == record.identity, observed == record.identity else {
            throw ProcessSupervisorFixtureError.identityMismatch
        }
        return ManagedProcessIdentityProof(runID: runID, expected: expectedIdentity, observed: observed)
    }

    func stop(runID: UUID, proof: ManagedProcessIdentityProof) async throws -> ManagedSupervisorStopReport {
        guard let record = records[runID] else { throw ProcessSupervisorFixtureError.unknownRun }
        guard proof.runID == runID,
              proof.expected == record.identity,
              proof.observed == record.identity,
              Self.observe(pid: record.pid, processGroup: record.processGroup) == record.identity.processStartIdentity
        else {
            throw ProcessSupervisorFixtureError.identityMismatch
        }

        signalAttempts += 1
        let termWasSent = Darwin.kill(-record.processGroup, SIGTERM) == 0
        try await Task.sleep(for: .milliseconds(100))
        let stillRunning = Self.observe(pid: record.pid, processGroup: record.processGroup) != nil
        var killWasSent = false
        if stillRunning {
            signalAttempts += 1
            killWasSent = Darwin.kill(-record.processGroup, SIGKILL) == 0
        }
        var status: Int32 = 0
        var didReap = false
        for _ in 0..<100 {
            let result = waitpid(record.pid, &status, WNOHANG)
            if result == record.pid || (result == -1 && errno == ECHILD) {
                didReap = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard didReap else { throw ProcessSupervisorFixtureError.fixtureTimeout }
        for _ in 0..<100
            where DarwinProcessGroupProbeFixture().probe(processGroupIdentifier: record.processGroup) != .absentESRCH
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        let gone = DarwinProcessGroupProbeFixture().probe(
            processGroupIdentifier: record.processGroup
        ) == .absentESRCH
        records.removeValue(forKey: runID)
        return ManagedSupervisorStopReport(
            termWasSent: termWasSent,
            killWasSent: killWasSent,
            processGroupIsGone: gone
        )
    }

    func signalAttemptCount() -> Int { signalAttempts }

    func reapWithoutSignalIfExited() {
        for (runID, record) in records {
            var status: Int32 = 0
            if waitpid(record.pid, &status, WNOHANG) == record.pid {
                records.removeValue(forKey: runID)
            }
        }
    }

    private static func observe(pid: pid_t, processGroup: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let returned = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(size))
        }
        guard returned == size, getpgid(pid) == processGroup else { return nil }
        return "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }
}

private enum SpoolPublicationFailure: Error, Equatable {
    case secondArtifact
    case indexCommit
}

private actor RealSpoolFinalizerFixture: ManagedSpoolFinalizationSeam {
    private let failure: SpoolPublicationFailure?
    private var published: ManagedFinalizationBundle?

    init(failure: SpoolPublicationFailure?) {
        self.failure = failure
    }

    func fsyncAndInspect(stdoutURL: URL, stderrURL: URL) throws -> ManagedSpoolInspection {
        ManagedSpoolInspection(
            stdout: try inspect(url: stdoutURL, handle: "stdout"),
            stderr: try inspect(url: stderrURL, handle: "stderr")
        )
    }

    func publishAtomically(
        inspection: ManagedSpoolInspection,
        diagnostics: ManagedArtifactIdentity,
        finalizedAt: Date
    ) throws -> ManagedFinalizationBundle {
        // local stagingは失敗時に公開面へ現れない。
        let stagedStdout = inspection.stdout
        if failure == .secondArtifact { throw SpoolPublicationFailure.secondArtifact }
        let stagedStderr = inspection.stderr
        if failure == .indexCommit { throw SpoolPublicationFailure.indexCommit }
        let bundle = ManagedFinalizationBundle(
            stdout: stagedStdout,
            stderr: stagedStderr,
            diagnostics: diagnostics,
            runIndexDigest: digest(Data("\(stagedStdout.sha256):\(stagedStderr.sha256)".utf8)),
            finalizedAt: finalizedAt
        )
        published = bundle
        return bundle
    }

    func publishedBundle() -> ManagedFinalizationBundle? { published }

    private func inspect(url: URL, handle: String) throws -> ManagedArtifactIdentity {
        let file = try FileHandle(forUpdating: url)
        try file.synchronize()
        try file.seek(toOffset: 0)
        let data = try file.readToEnd() ?? Data()
        try file.close()
        return ManagedArtifactIdentity(
            handle: handle,
            sizeBytes: UInt64(data.count),
            lineCount: UInt64(data.reduce(into: 0) { count, byte in
                if byte == 0x0a { count += 1 }
            }),
            sha256: digest(data)
        )
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private actor AsyncBarrierFixture {
    private let participants: Int
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participants: Int) { self.participants = participants }

    func arriveAndWait() async {
        arrivals += 1
        if arrivals == participants {
            let ready = waiters
            waiters.removeAll()
            ready.forEach { $0.resume() }
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor AsyncGateFixture {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let ready = waiters
        waiters.removeAll()
        ready.forEach { $0.resume() }
    }
}

private enum SpawnReservationFixtureError: Error {
    case runMismatch
    case invalidReservation
}

private actor DurableSpawnReservationWorkflowFixture: ManagedSpawnReservationWorkflowSeam {
    private let recordURL: URL
    private let directory: URL
    private var record: ManagedSpawnReservationRecord

    init(runID: UUID, directory: URL) throws {
        self.directory = directory
        recordURL = directory.appendingPathComponent("spawn-reservation.json")
        if FileManager.default.fileExists(atPath: recordURL.path) {
            let restored = try JSONDecoder().decode(
                ManagedSpawnReservationRecord.self,
                from: Data(contentsOf: recordURL)
            )
            guard restored.runID == runID else { throw SpawnReservationFixtureError.runMismatch }
            record = restored
        } else {
            let initial = ManagedSpawnReservationRecord(
                runID: runID,
                revision: 0,
                state: .preSpawn,
                terminationCause: nil,
                causeAcceptedAt: nil
            )
            try Self.createInitial(initial, at: recordURL, directory: directory)
            record = initial
        }
    }

    func reserveSpawn(runID: UUID) throws -> ManagedSpawnReservationDecision {
        try requireRun(runID)
        if let cause = record.terminationCause { return .deniedByPreSpawnCause(cause) }
        switch record.state {
        case .preSpawn:
            let reservationID = UUID()
            try replace(state: .spawnReserved(reservationID: reservationID))
            return .reserved(reservationID: reservationID)
        case let .spawnReserved(reservationID), let .spawned(reservationID, _):
            return .reserved(reservationID: reservationID)
        case .spawnAborted:
            throw SpawnReservationFixtureError.invalidReservation
        }
    }

    func admitPreSpawnCause(
        runID: UUID,
        cause: ManagedDurableTerminalCause,
        acceptedAt: Date
    ) throws -> ManagedSpawnReservationRecord {
        try requireRun(runID)
        if record.terminationCause != nil { return record }
        let nextState: ManagedSpawnReservationState = record.state == .preSpawn ? .spawnAborted : record.state
        try replace(state: nextState, cause: cause, acceptedAt: acceptedAt)
        return record
    }

    func publishSpawnIdentity(
        runID: UUID,
        reservationID: UUID,
        identity: ManagedProcessIdentity
    ) throws -> ManagedSpawnReservationRecord {
        try requireRun(runID)
        guard case let .spawnReserved(current) = record.state, current == reservationID else {
            throw SpawnReservationFixtureError.invalidReservation
        }
        try replace(state: .spawned(reservationID: reservationID, identity: identity))
        return record
    }

    func snapshot(runID: UUID) throws -> ManagedSpawnReservationRecord {
        try requireRun(runID)
        return record
    }

    private func requireRun(_ runID: UUID) throws {
        guard record.runID == runID else { throw SpawnReservationFixtureError.runMismatch }
    }

    private func replace(
        state: ManagedSpawnReservationState,
        cause: ManagedDurableTerminalCause? = nil,
        acceptedAt: Date? = nil
    ) throws {
        let updated = ManagedSpawnReservationRecord(
            runID: record.runID,
            revision: record.revision + 1,
            state: state,
            terminationCause: cause ?? record.terminationCause,
            causeAcceptedAt: acceptedAt ?? record.causeAcceptedAt
        )
        try Self.persist(updated, to: recordURL, directory: directory)
        record = updated
    }

    private static func persist(
        _ record: ManagedSpawnReservationRecord,
        to recordURL: URL,
        directory: URL
    ) throws {
        let temporary = directory.appendingPathComponent("spawn-reservation.tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        _ = FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.write(contentsOf: encoder.encode(record))
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporary.path, recordURL.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try fsyncDirectory(directory)
    }

    private static func createInitial(
        _ record: ManagedSpawnReservationRecord,
        at recordURL: URL,
        directory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        let descriptor = Darwin.open(recordURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteFileExists) }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                guard written > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += written
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try fsyncDirectory(directory)
    }
}

private enum ReservationSupervisorFixtureError: Error, Equatable {
    case reservationRequired
    case requestConflict
    case recoveryRequired
    case spawnFailed(Int32)
    case identityUnavailable
}

private actor DurableReservationSupervisorFixture: ManagedReservationBoundSupervisorSeam {
    private let directory: URL

    init(directory: URL) { self.directory = directory }

    func launchOrReconnect(
        _ request: ManagedSupervisorLaunchRequest,
        requestDigest: String
    ) throws -> ManagedProcessIdentity {
        guard let reservationID = request.spawnReservationID else {
            throw ReservationSupervisorFixtureError.reservationRequired
        }
        if let existing = try load(reservationID: reservationID) {
            guard existing.runID == request.runID, existing.requestDigest == requestDigest else {
                throw ReservationSupervisorFixtureError.requestConflict
            }
            switch existing.state {
            case let .spawned(identity):
                guard processStartIdentity(
                    pid: identity.processIdentifier,
                    expectedProcessGroup: identity.processGroupIdentifier
                ) == identity.processStartIdentity else {
                    try persist(ManagedSupervisorLaunchBinding(
                        runID: existing.runID,
                        reservationID: existing.reservationID,
                        requestDigest: existing.requestDigest,
                        state: .recoveryRequired,
                        spawnCount: existing.spawnCount
                    ))
                    throw ReservationSupervisorFixtureError.recoveryRequired
                }
                return identity
            case .boundBeforeSpawn:
                // spawn済みか判別できないwindowでは再spawnしない。
                try persist(ManagedSupervisorLaunchBinding(
                    runID: existing.runID,
                    reservationID: existing.reservationID,
                    requestDigest: existing.requestDigest,
                    state: .recoveryRequired,
                    spawnCount: existing.spawnCount
                ))
                throw ReservationSupervisorFixtureError.recoveryRequired
            case .recoveryRequired:
                throw ReservationSupervisorFixtureError.recoveryRequired
            }
        }

        try persist(ManagedSupervisorLaunchBinding(
            runID: request.runID,
            reservationID: reservationID,
            requestDigest: requestDigest,
            state: .boundBeforeSpawn,
            spawnCount: 0
        ))
        let identity = try spawn(request)
        try persist(ManagedSupervisorLaunchBinding(
            runID: request.runID,
            reservationID: reservationID,
            requestDigest: requestDigest,
            state: .spawned(identity),
            spawnCount: 1
        ))
        return identity
    }

    func binding(reservationID: UUID) throws -> ManagedSupervisorLaunchBinding? {
        try load(reservationID: reservationID)
    }

    func persistUnknownOwnerForTest(
        runID: UUID,
        reservationID: UUID,
        requestDigest: String
    ) throws {
        try persist(ManagedSupervisorLaunchBinding(
            runID: runID,
            reservationID: reservationID,
            requestDigest: requestDigest,
            state: .boundBeforeSpawn,
            spawnCount: 0
        ))
    }

    private func spawn(_ request: ManagedSupervisorLaunchRequest) throws -> ManagedProcessIdentity {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attributes)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawn_file_actions_addchdir_np(&actions, request.workingDirectoryURL.path)
        var arguments = ([request.executableURL.path] + request.arguments).map { strdup($0) } + [nil]
        defer { arguments.dropLast().forEach { free($0) } }
        var pid: pid_t = 0
        let result = request.executableURL.path.withCString { executable in
            arguments.withUnsafeMutableBufferPointer {
                posix_spawn(&pid, executable, &actions, &attributes, $0.baseAddress, environ)
            }
        }
        guard result == 0 else { throw ReservationSupervisorFixtureError.spawnFailed(result) }
        guard let start = processStartIdentity(pid: pid, expectedProcessGroup: pid) else {
            _ = Darwin.kill(-pid, SIGKILL)
            throw ReservationSupervisorFixtureError.identityUnavailable
        }
        return ManagedProcessIdentity(
            processIdentifier: pid,
            processStartIdentity: start,
            processGroupIdentifier: pid,
            bootSessionIdentity: "reservation-supervisor-boot",
            supervisorNonce: "reservation-supervisor-nonce"
        )
    }

    private func load(reservationID: UUID) throws -> ManagedSupervisorLaunchBinding? {
        let url = bindingURL(reservationID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ManagedSupervisorLaunchBinding.self, from: Data(contentsOf: url))
    }

    private func persist(_ binding: ManagedSupervisorLaunchBinding) throws {
        let url = bindingURL(binding.reservationID)
        let temporary = directory.appendingPathComponent("supervisor-binding.tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        _ = FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.write(contentsOf: encoder.encode(binding))
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try fsyncDirectory(directory)
    }

    private func bindingURL(_ reservationID: UUID) -> URL {
        directory.appendingPathComponent("supervisor-\(reservationID.uuidString.lowercased()).json")
    }
}

private actor IntegratedCauseRaceFixture: ManagedTerminationCauseAdmissionSeam {
    let runID: UUID
    let identity: ManagedProcessIdentity
    let acceptedSignal: Int32
    let workflow: DiskTerminationWorkflowFixture

    init(
        runID: UUID,
        identity: ManagedProcessIdentity,
        acceptedSignal: Int32,
        workflow: DiskTerminationWorkflowFixture
    ) {
        self.runID = runID
        self.identity = identity
        self.acceptedSignal = acceptedSignal
        self.workflow = workflow
    }

    func acceptTerminalCandidate(
        _ candidate: ManagedTerminalCandidate
    ) throws -> ManagedTerminationWorkflowRecord {
        if let existing = try workflow.recover(runID: runID) { return existing }
        let cause: ManagedDurableTerminalCause
        let acceptedAt: Date
        switch candidate {
        case let .cancellation(date):
            cause = .cancellation
            acceptedAt = date
        case let .timeout(date):
            cause = .timeout
            acceptedAt = date
        case let .naturalExit(exitCode, signal, date):
            cause = .naturalExit(exitCode: exitCode, signal: signal)
            acceptedAt = date
        }
        return try workflow.persistCause(ManagedTerminationWorkflowRecord(
            runID: runID,
            cause: cause,
            acceptedAt: acceptedAt,
            identity: identity,
            signal: acceptedSignal,
            state: .causePersisted
        ))
    }
}

private enum SignalReconcileCrash: String, CaseIterable {
    case afterCauseBeforeOutbox
    case afterOutboxBeforeSignal
    case afterTerminationActionBeforeObservation
    case afterObservationBeforeAck
}

private enum SignalReconcileError: Error, Equatable {
    case injectedCrash
    case recoveryRequired
}

private struct DarwinProcessGroupProbeFixture: ManagedProcessGroupProbeSeam {
    func probe(processGroupIdentifier: Int32) -> ManagedProcessGroupProbeResult {
        errno = 0
        if Darwin.kill(-processGroupIdentifier, 0) == 0 { return .exists }
        switch errno {
        case ESRCH: return .absentESRCH
        case EPERM: return .permissionDenied
        default: return .failed(errno: errno)
        }
    }
}

private struct FixedProcessGroupProbeFixture: ManagedProcessGroupProbeSeam {
    let result: ManagedProcessGroupProbeResult
    func probe(processGroupIdentifier _: Int32) -> ManagedProcessGroupProbeResult { result }
}

private struct DarwinSignalDeliveryFixture: ManagedSignalDeliverySeam {
    func deliver(signal: Int32, to identity: ManagedProcessIdentity) -> ManagedSignalDeliveryResult {
        errno = 0
        if Darwin.kill(-identity.processGroupIdentifier, signal) == 0 { return .delivered }
        switch errno {
        case ESRCH: return .processGroupAbsentESRCH
        case EPERM: return .permissionDenied
        default: return .failed(errno: errno)
        }
    }
}

private struct FixedSignalDeliveryFixture: ManagedSignalDeliverySeam {
    let result: ManagedSignalDeliveryResult
    func deliver(signal _: Int32, to _: ManagedProcessIdentity) -> ManagedSignalDeliveryResult { result }
}

private struct DiskTerminationWorkflowFixture: ManagedTerminationWorkflowSeam, Sendable {
    let directory: URL
    private var recordURL: URL { directory.appendingPathComponent("signal-outbox.json") }
    private var attemptsURL: URL { directory.appendingPathComponent("signal-attempts.log") }

    func persistCause(
        _ record: ManagedTerminationWorkflowRecord
    ) throws -> ManagedTerminationWorkflowRecord {
        if let existing = try recover(runID: record.runID) { return existing }
        try replace(record)
        return record
    }

    func persistOutboxPending(runID: UUID) throws {
        guard let record = try recover(runID: runID), record.state == .causePersisted else {
            throw SignalReconcileError.recoveryRequired
        }
        try replace(transition(record, to: .outboxPending))
    }

    func recover(runID: UUID) throws -> ManagedTerminationWorkflowRecord? {
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return nil }
        let record = try JSONDecoder().decode(
            ManagedTerminationWorkflowRecord.self,
            from: Data(contentsOf: recordURL)
        )
        return record.runID == runID ? record : nil
    }

    func persistGroupGoneObservation(runID: UUID) throws {
        guard let record = try recover(runID: runID) else { throw SignalReconcileError.recoveryRequired }
        try replace(transition(record, to: .processGroupGoneObserved))
    }

    func persistSpawnAbortObservation(runID: UUID) throws {
        guard let record = try recover(runID: runID), record.state == .outboxPending else {
            throw SignalReconcileError.recoveryRequired
        }
        try replace(transition(record, to: .spawnAbortObserved))
    }

    func acknowledge(runID: UUID) throws {
        guard let record = try recover(runID: runID),
              record.state == .processGroupGoneObserved || record.state == .spawnAbortObserved
        else {
            throw SignalReconcileError.recoveryRequired
        }
        try replace(transition(record, to: .acknowledged))
    }

    func recordSignalResult(_ result: Int32) throws {
        if !FileManager.default.fileExists(atPath: attemptsURL.path) {
            _ = FileManager.default.createFile(atPath: attemptsURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: attemptsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(result)\n".utf8))
        try handle.synchronize()
        try handle.close()
    }

    func signalAttempts() throws -> [Int32] {
        guard FileManager.default.fileExists(atPath: attemptsURL.path) else { return [] }
        return String(decoding: try Data(contentsOf: attemptsURL), as: UTF8.self)
            .split(separator: "\n").compactMap { Int32($0) }
    }

    private func transition(
        _ record: ManagedTerminationWorkflowRecord,
        to state: ManagedTerminationWorkflowState
    ) -> ManagedTerminationWorkflowRecord {
        ManagedTerminationWorkflowRecord(
            runID: record.runID,
            cause: record.cause,
            acceptedAt: record.acceptedAt,
            processPhase: record.processPhase,
            signal: record.signal,
            state: state
        )
    }

    private func replace(_ record: ManagedTerminationWorkflowRecord) throws {
        let temporary = directory.appendingPathComponent("signal-outbox.tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        _ = FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.write(contentsOf: encoder.encode(record))
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporary.path, recordURL.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try fsyncDirectory(directory)
    }
}

private struct TerminationWorkflowReconcilerFixture {
    let workflow: DiskTerminationWorkflowFixture
    let processGroupProbe: any ManagedProcessGroupProbeSeam
    let signalDelivery: any ManagedSignalDeliverySeam
    let reapAttempts: Int
    let reapPollMicroseconds: useconds_t

    init(
        workflow: DiskTerminationWorkflowFixture,
        processGroupProbe: any ManagedProcessGroupProbeSeam = DarwinProcessGroupProbeFixture(),
        signalDelivery: any ManagedSignalDeliverySeam = DarwinSignalDeliveryFixture(),
        reapAttempts: Int = 50,
        reapPollMicroseconds: useconds_t = 10_000
    ) {
        self.workflow = workflow
        self.processGroupProbe = processGroupProbe
        self.signalDelivery = signalDelivery
        self.reapAttempts = reapAttempts
        self.reapPollMicroseconds = reapPollMicroseconds
    }

    func reconcile(runID: UUID, crash: SignalReconcileCrash?) throws {
        guard var record = try workflow.recover(runID: runID) else {
            throw SignalReconcileError.recoveryRequired
        }
        if record.state == .acknowledged { return }
        if record.state == .processGroupGoneObserved || record.state == .spawnAbortObserved {
            if crash == .afterObservationBeforeAck { throw SignalReconcileError.injectedCrash }
            try workflow.acknowledge(runID: runID)
            return
        }
        if record.state == .causePersisted {
            if crash == .afterCauseBeforeOutbox { throw SignalReconcileError.injectedCrash }
            try workflow.persistOutboxPending(runID: runID)
            record = try workflow.recover(runID: runID)!
        }
        if crash == .afterOutboxBeforeSignal { throw SignalReconcileError.injectedCrash }

        guard let identity = record.identity else {
            try workflow.persistSpawnAbortObservation(runID: runID)
            if crash == .afterObservationBeforeAck { throw SignalReconcileError.injectedCrash }
            try workflow.acknowledge(runID: runID)
            return
        }

        let liveStart = processStartIdentity(
            pid: identity.processIdentifier,
            expectedProcessGroup: identity.processGroupIdentifier
        )
        if let liveStart, liveStart != identity.processStartIdentity {
            throw SignalReconcileError.recoveryRequired
        }
        guard liveStart != nil else {
            // PGIDだけでは所有processを証明できない。存在するgroupへは絶対にsignalしない。
            var reapedStatus: Int32 = 0
            let reaped = waitpid(identity.processIdentifier, &reapedStatus, WNOHANG)
            if reaped == identity.processIdentifier,
               processGroupProbe.probe(processGroupIdentifier: identity.processGroupIdentifier) == .absentESRCH {
                if crash == .afterTerminationActionBeforeObservation {
                    throw SignalReconcileError.injectedCrash
                }
                try workflow.persistGroupGoneObservation(runID: runID)
                if crash == .afterObservationBeforeAck { throw SignalReconcileError.injectedCrash }
                try workflow.acknowledge(runID: runID)
                return
            }
            switch processGroupProbe.probe(processGroupIdentifier: identity.processGroupIdentifier) {
            case .absentESRCH:
                try workflow.persistGroupGoneObservation(runID: runID)
                if crash == .afterObservationBeforeAck { throw SignalReconcileError.injectedCrash }
                try workflow.acknowledge(runID: runID)
                return
            case .exists, .permissionDenied, .failed:
                throw SignalReconcileError.recoveryRequired
            }
        }

        var status: Int32 = 0
        switch record.cause {
        case .cancellation, .timeout:
            switch signalDelivery.deliver(signal: record.signal, to: identity) {
            case .delivered:
                try workflow.recordSignalResult(0)
            case .processGroupAbsentESRCH:
                try workflow.recordSignalResult(-ESRCH)
            case .permissionDenied:
                try workflow.recordSignalResult(-EPERM)
                throw SignalReconcileError.recoveryRequired
            case let .failed(errorNumber):
                try workflow.recordSignalResult(-errorNumber)
                throw SignalReconcileError.recoveryRequired
            }
            if crash == .afterTerminationActionBeforeObservation { throw SignalReconcileError.injectedCrash }
        case .naturalExit:
            break
        }
        var didReap = false
        for _ in 0..<reapAttempts {
            let result = waitpid(identity.processIdentifier, &status, WNOHANG)
            if result == identity.processIdentifier || (result == -1 && errno == ECHILD) {
                didReap = true
                break
            }
            usleep(reapPollMicroseconds)
        }
        guard didReap else { throw SignalReconcileError.recoveryRequired }
        if crash == .afterTerminationActionBeforeObservation { throw SignalReconcileError.injectedCrash }
        for _ in 0..<reapAttempts {
            if processGroupProbe.probe(processGroupIdentifier: identity.processGroupIdentifier) == .absentESRCH {
                break
            }
            usleep(reapPollMicroseconds)
        }
        guard processGroupProbe.probe(processGroupIdentifier: identity.processGroupIdentifier) == .absentESRCH else {
            throw SignalReconcileError.recoveryRequired
        }
        try workflow.persistGroupGoneObservation(runID: runID)
        if crash == .afterObservationBeforeAck { throw SignalReconcileError.injectedCrash }
        try workflow.acknowledge(runID: runID)
    }
}

private struct SupervisorEndpointFixture: Codable, Equatable {
    let supervisorNonce: String
    let bootSessionIdentity: String
    let processStartIdentity: String
}

private enum AdapterRecoveryFixtureError: Error, Equatable {
    case recoveryRequired
}

private struct DurableAdapterRecoveryFixture: ManagedAdapterRecoverySeam {
    let recordURL: URL
    let sessionNonce: String

    func reconnect(runID: UUID) async throws -> ManagedAdapterReconnectResult {
        guard let recordData = try? Data(contentsOf: recordURL),
              let record = try? JSONDecoder().decode(ManagedAdapterRecoveryRecord.self, from: recordData),
              record.runID == runID,
              let endpointData = try? Data(contentsOf: URL(fileURLWithPath: record.supervisorEndpoint)),
              let endpoint = try? JSONDecoder().decode(SupervisorEndpointFixture.self, from: endpointData),
              endpoint.supervisorNonce == record.processIdentity.supervisorNonce,
              endpoint.bootSessionIdentity == record.processIdentity.bootSessionIdentity,
              endpoint.processStartIdentity == record.processIdentity.processStartIdentity
        else {
            throw AdapterRecoveryFixtureError.recoveryRequired
        }
        return ManagedAdapterReconnectResult(record: record, transportSessionNonce: sessionNonce)
    }
}

private struct UnixSocketAdapterRecoveryFixture: ManagedAdapterRecoverySeam {
    let recordURL: URL
    let authenticationKeyURL: URL
    let sessionNonce: String

    func reconnect(runID: UUID) async throws -> ManagedAdapterReconnectResult {
        guard let data = try? Data(contentsOf: recordURL),
              let record = try? JSONDecoder().decode(ManagedAdapterRecoveryRecord.self, from: data),
              record.runID == runID,
              let materialData = try? Data(contentsOf: authenticationKeyURL),
              let authenticationMaterial = try? JSONDecoder().decode(
                  ManagedSupervisorAuthenticationMaterial.self,
                  from: materialData
              ),
              authenticationMaterial.runID == runID,
              authenticationMaterial.supervisorNonce == record.processIdentity.supervisorNonce
        else { throw AdapterRecoveryFixtureError.recoveryRequired }
        let request = ManagedSupervisorHandshakeRequest(
            runID: runID,
            transportSessionNonce: sessionNonce,
            clientChallenge: UUID().uuidString.lowercased(),
            adapterProcessIdentifier: getpid(),
            credentialExpiresAtUnixMilliseconds: Int64(Date().addingTimeInterval(30).timeIntervalSince1970 * 1_000)
        )
        guard let response = try? unixSocketRoundTrip(
            path: record.supervisorEndpoint,
            request: request,
            authenticationKey: authenticationMaterial.secret
        ),
            response.supervisorNonce == record.processIdentity.supervisorNonce,
            response.bootSessionIdentity == record.processIdentity.bootSessionIdentity,
            response.processIdentifier == record.processIdentity.processIdentifier,
            response.processStartIdentity == record.processIdentity.processStartIdentity,
            response.processGroupIdentifier == record.processIdentity.processGroupIdentifier
        else { throw AdapterRecoveryFixtureError.recoveryRequired }
        return ManagedAdapterReconnectResult(record: record, transportSessionNonce: sessionNonce)
    }
}

private final class UnixSupervisorSocketFixture: @unchecked Sendable {
    private let socketURL: URL
    private let listener: Int32
    private let serverTask: Task<Void, Error>
    private let sessionRecorder: SocketSessionRecorder

    init(
        socketURL: URL,
        runID: UUID,
        identity: ManagedProcessIdentity,
        authenticationMaterial: ManagedSupervisorAuthenticationMaterial,
        responseBootIdentity: String,
        expectedConnections: Int
    ) throws {
        self.socketURL = socketURL
        try? FileManager.default.removeItem(at: socketURL)
        let listenerFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        listener = listenerFD
        let recorder = SocketSessionRecorder()
        sessionRecorder = recorder
        guard listenerFD >= 0 else { throw AdapterRecoveryFixtureError.recoveryRequired }
        guard withUnixSocketAddress(path: socketURL.path, { address, length in
            Darwin.bind(listenerFD, address, length)
        }) == 0, Darwin.listen(listenerFD, 8) == 0 else {
            Darwin.close(listenerFD)
            throw AdapterRecoveryFixtureError.recoveryRequired
        }

        serverTask = Task.detached {
            defer {
                Darwin.close(listenerFD)
                try? FileManager.default.removeItem(at: socketURL)
            }
            for _ in 0..<expectedConnections {
                let client = Darwin.accept(listenerFD, nil, nil)
                guard client >= 0 else { throw AdapterRecoveryFixtureError.recoveryRequired }
                defer { Darwin.close(client) }
                let requestData = try readSocketToEOF(client)
                let request = try JSONDecoder().decode(ManagedSupervisorHandshakeRequest.self, from: requestData)
                await recorder.append(request.transportSessionNonce)
                guard peerCredentialsMatch(
                          client,
                          material: authenticationMaterial,
                          claimedProcessIdentifier: request.adapterProcessIdentifier
                      ),
                      authenticationMaterial.runID == runID,
                      authenticationMaterial.supervisorNonce == identity.supervisorNonce,
                      request.runID == runID,
                      request.credentialExpiresAtUnixMilliseconds >= Int64(Date().timeIntervalSince1970 * 1_000),
                      let liveStart = processStartIdentity(
                          pid: identity.processIdentifier,
                          expectedProcessGroup: identity.processGroupIdentifier
                      ),
                      liveStart == identity.processStartIdentity
                else { throw AdapterRecoveryFixtureError.recoveryRequired }
                let supervisorChallenge = UUID().uuidString.lowercased()
                let challenge = ManagedSupervisorChallenge(
                    supervisorChallenge: supervisorChallenge,
                    supervisorProof: handshakeProof(
                        label: "supervisor",
                        request: request,
                        supervisorChallenge: supervisorChallenge,
                        key: authenticationMaterial.secret
                    )
                )
                try writeJSONLine(client, challenge)
                let clientResponse = try JSONDecoder().decode(
                    ManagedSupervisorChallengeResponse.self,
                    from: readSocketToEOF(client)
                )
                guard clientResponse.clientProof == handshakeProof(
                    label: "client",
                    request: request,
                    supervisorChallenge: supervisorChallenge,
                    key: authenticationMaterial.secret
                ) else { throw AdapterRecoveryFixtureError.recoveryRequired }
                let response = ManagedSupervisorHandshakeResponse(
                    supervisorNonce: identity.supervisorNonce,
                    bootSessionIdentity: responseBootIdentity,
                    processIdentifier: identity.processIdentifier,
                    processStartIdentity: liveStart,
                    processGroupIdentifier: identity.processGroupIdentifier
                )
                try writeJSONLine(client, response)
            }
        }
    }

    func waitUntilFinished() async throws {
        try await serverTask.value
    }

    func receivedSessionNonces() async -> [String] { await sessionRecorder.values() }
}

private actor SocketSessionRecorder {
    private var nonces: [String] = []
    func append(_ nonce: String) { nonces.append(nonce) }
    func values() -> [String] { nonces }
}

private func unixSocketRoundTrip(
    path: String,
    request: ManagedSupervisorHandshakeRequest,
    authenticationKey: Data
) throws -> ManagedSupervisorHandshakeResponse {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw AdapterRecoveryFixtureError.recoveryRequired }
    defer { Darwin.close(descriptor) }
    guard withUnixSocketAddress(path: path, { address, length in
        Darwin.connect(descriptor, address, length)
    }) == 0 else { throw AdapterRecoveryFixtureError.recoveryRequired }
    try writeJSONLine(descriptor, request)
    let challenge = try JSONDecoder().decode(
        ManagedSupervisorChallenge.self,
        from: readSocketToEOF(descriptor)
    )
    guard challenge.supervisorProof == handshakeProof(
        label: "supervisor",
        request: request,
        supervisorChallenge: challenge.supervisorChallenge,
        key: authenticationKey
    ) else { throw AdapterRecoveryFixtureError.recoveryRequired }
    try writeJSONLine(
        descriptor,
        ManagedSupervisorChallengeResponse(clientProof: handshakeProof(
            label: "client",
            request: request,
            supervisorChallenge: challenge.supervisorChallenge,
            key: authenticationKey
        ))
    )
    return try JSONDecoder().decode(ManagedSupervisorHandshakeResponse.self, from: readSocketToEOF(descriptor))
}

private func writeJSONLine<T: Encodable>(_ descriptor: Int32, _ value: T) throws {
    var data = try JSONEncoder().encode(value)
    data.append(0x0a)
    try writeAll(descriptor, data: data)
}

private func handshakeProof(
    label: String,
    request: ManagedSupervisorHandshakeRequest,
    supervisorChallenge: String,
    key: Data
) -> String {
    let message = Data(
        "\(label)\u{0}\(request.runID.uuidString.lowercased())\u{0}\(request.transportSessionNonce)\u{0}\(request.clientChallenge)\u{0}\(request.adapterProcessIdentifier)\u{0}\(request.credentialExpiresAtUnixMilliseconds)\u{0}\(supervisorChallenge)".utf8
    )
    return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))).base64EncodedString()
}

private func peerCredentialsMatch(
    _ descriptor: Int32,
    material: ManagedSupervisorAuthenticationMaterial,
    claimedProcessIdentifier: Int32
) -> Bool {
    var peerPID: pid_t = 0
    var peerPIDLength = socklen_t(MemoryLayout<pid_t>.size)
    let pidResult = withUnsafeMutablePointer(to: &peerPID) {
        Darwin.getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, $0, &peerPIDLength)
    }
    var effectiveUID: uid_t = 0
    var effectiveGID: gid_t = 0
    let credentialResult = getpeereid(descriptor, &effectiveUID, &effectiveGID)
    return pidResult == 0 && credentialResult == 0
        && peerPID == claimedProcessIdentifier
        && effectiveUID == material.allowedEffectiveUserIdentifier
        && effectiveGID == material.allowedEffectiveGroupIdentifier
}

private func withUnixSocketAddress<T>(
    path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
) -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    precondition(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.copyBytes(from: bytes)
    }
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private func readSocketToEOF(_ descriptor: Int32) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count == 0 { break }
        guard count > 0 else { throw AdapterRecoveryFixtureError.recoveryRequired }
        data.append(contentsOf: buffer.prefix(Int(count)))
        if data.last == 0x0a { break }
    }
    if data.last == 0x0a { data.removeLast() }
    return data
}

private func writeAll(_ descriptor: Int32, data: Data) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
            guard written > 0 else { throw AdapterRecoveryFixtureError.recoveryRequired }
            offset += written
        }
    }
}

private func processStartIdentity(pid: pid_t, expectedProcessGroup: pid_t) -> String? {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    let returned = withUnsafeMutablePointer(to: &info) { pointer in
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(size))
    }
    guard returned == size, getpgid(pid) == expectedProcessGroup else { return nil }
    return "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
}

private enum DiskPublicationFailure: String, Error, CaseIterable, Equatable {
    case writeStdout
    case fsyncStdout
    case writeStderr
    case fsyncStderr
    case writeDiagnostic
    case fsyncDiagnostic
    case writeMetadata
    case fsyncMetadata
    case writeIndex
    case fsyncIndex
    case fsyncStagingDirectory
    case rename
    case fsyncPublicDirectory
}

private enum DiskReplayError: Error, Equatable {
    case bindingMismatch
}

private actor DiskAtomicPublisherFixture: ManagedSpoolFinalizationSeam {
    let publicRootURL: URL
    let publicRunURL: URL
    private let stagingRootURL: URL
    private let stagingRunURL: URL
    private let runID: UUID
    private let requestDigest: String
    private let stdoutURL: URL
    private let stderrURL: URL
    private let diagnosticURL: URL
    private let failure: DiskPublicationFailure?

    init(
        root: URL,
        runID: UUID,
        requestDigest: String,
        stdoutURL: URL,
        stderrURL: URL,
        diagnosticURL: URL,
        failure: DiskPublicationFailure?
    ) {
        publicRootURL = root.appendingPathComponent("published", isDirectory: true)
        stagingRootURL = root.appendingPathComponent("staging", isDirectory: true)
        let name = runID.uuidString.lowercased()
        publicRunURL = publicRootURL.appendingPathComponent(name, isDirectory: true)
        stagingRunURL = stagingRootURL.appendingPathComponent(name, isDirectory: true)
        self.runID = runID
        self.requestDigest = requestDigest
        self.stdoutURL = stdoutURL
        self.stderrURL = stderrURL
        self.diagnosticURL = diagnosticURL
        self.failure = failure
    }

    func fsyncAndInspect(stdoutURL: URL, stderrURL: URL) throws -> ManagedSpoolInspection {
        ManagedSpoolInspection(
            stdout: try inspectSpool(stdoutURL, handle: "stdout"),
            stderr: try inspectSpool(stderrURL, handle: "stderr")
        )
    }

    func publishAtomically(
        inspection: ManagedSpoolInspection,
        diagnostics: ManagedArtifactIdentity,
        finalizedAt: Date
    ) throws -> ManagedFinalizationBundle {
        if FileManager.default.fileExists(atPath: publicRunURL.path) {
            return try loadPublished(
                inspection: inspection,
                diagnostics: diagnostics,
                finalizedAt: finalizedAt
            )
        }
        try FileManager.default.createDirectory(at: publicRootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagingRootURL, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: stagingRunURL.path) {
            try FileManager.default.removeItem(at: stagingRunURL)
        }
        try FileManager.default.createDirectory(at: stagingRunURL, withIntermediateDirectories: true)
        do {
            try stage(try Data(contentsOf: stdoutURL), name: "stdout.artifact", write: .writeStdout, sync: .fsyncStdout)
            try stage(try Data(contentsOf: stderrURL), name: "stderr.artifact", write: .writeStderr, sync: .fsyncStderr)
            let diagnosticBytes = try Data(contentsOf: diagnosticURL)
            guard UInt64(diagnosticBytes.count) == diagnostics.sizeBytes,
                  digest(diagnosticBytes) == diagnostics.sha256
            else { throw DiskReplayError.bindingMismatch }
            try stage(
                diagnosticBytes,
                name: "diagnostic.artifact",
                write: .writeDiagnostic,
                sync: .fsyncDiagnostic
            )
            let metadata = PublicationMetadataFixture(
                schema: "aishell.managed-finalization.v1",
                binding: ManagedFinalizationReplayBinding(
                    runID: runID,
                    requestDigest: requestDigest,
                    stdout: inspection.stdout,
                    stderr: inspection.stderr,
                    diagnostics: diagnostics,
                    finalizedAt: finalizedAt
                )
            )
            try stage(try encoded(metadata), name: "metadata.json", write: .writeMetadata, sync: .fsyncMetadata)
            let index = PublicationIndexFixture(
                schema: "aishell.managed-run-index.v1",
                runID: runID,
                requestDigest: requestDigest,
                stdoutSHA256: inspection.stdout.sha256,
                stderrSHA256: inspection.stderr.sha256,
                diagnosticSHA256: diagnostics.sha256,
                finalizedAt: finalizedAt
            )
            try stage(try encoded(index), name: "registry-index.json", write: .writeIndex, sync: .fsyncIndex)
            if failure == .fsyncStagingDirectory { throw DiskPublicationFailure.fsyncStagingDirectory }
            try fsyncDirectory(stagingRunURL)
            if failure == .rename { throw DiskPublicationFailure.rename }
            try FileManager.default.moveItem(at: stagingRunURL, to: publicRunURL)
            if failure == .fsyncPublicDirectory {
                try FileManager.default.moveItem(at: publicRunURL, to: stagingRunURL)
                try fsyncDirectory(publicRootURL)
                throw DiskPublicationFailure.fsyncPublicDirectory
            }
            try fsyncDirectory(publicRootURL)
        } catch {
            if FileManager.default.fileExists(atPath: publicRunURL.path) {
                try? FileManager.default.removeItem(at: publicRunURL)
                try? fsyncDirectory(publicRootURL)
            }
            throw error
        }
        return ManagedFinalizationBundle(
            stdout: inspection.stdout,
            stderr: inspection.stderr,
            diagnostics: diagnostics,
            runIndexDigest: digest(Data("\(inspection.stdout.sha256):\(inspection.stderr.sha256)".utf8)),
            finalizedAt: finalizedAt
        )
    }

    private func stage(_ data: Data, name: String, write: DiskPublicationFailure, sync: DiskPublicationFailure) throws {
        if failure == write { throw write }
        let url = stagingRunURL.appendingPathComponent(name)
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: data)
        if failure == sync {
            try handle.close()
            throw sync
        }
        try handle.synchronize()
        try handle.close()
    }

    private func loadPublished(
        inspection: ManagedSpoolInspection,
        diagnostics: ManagedArtifactIdentity,
        finalizedAt: Date
    ) throws -> ManagedFinalizationBundle {
        let metadata = try JSONDecoder().decode(
            PublicationMetadataFixture.self,
            from: Data(contentsOf: publicRunURL.appendingPathComponent("metadata.json"))
        )
        let candidate = ManagedFinalizationReplayBinding(
            runID: runID,
            requestDigest: requestDigest,
            stdout: inspection.stdout,
            stderr: inspection.stderr,
            diagnostics: diagnostics,
            finalizedAt: finalizedAt
        )
        guard metadata.schema == "aishell.managed-finalization.v1", metadata.binding == candidate else {
            throw DiskReplayError.bindingMismatch
        }
        let index = try JSONDecoder().decode(
            PublicationIndexFixture.self,
            from: Data(contentsOf: publicRunURL.appendingPathComponent("registry-index.json"))
        )
        let expectedIndex = PublicationIndexFixture(
            schema: "aishell.managed-run-index.v1",
            runID: runID,
            requestDigest: requestDigest,
            stdoutSHA256: candidate.stdout.sha256,
            stderrSHA256: candidate.stderr.sha256,
            diagnosticSHA256: candidate.diagnostics.sha256,
            finalizedAt: candidate.finalizedAt
        )
        let publishedStdout = try Data(contentsOf: publicRunURL.appendingPathComponent("stdout.artifact"))
        let publishedStderr = try Data(contentsOf: publicRunURL.appendingPathComponent("stderr.artifact"))
        guard let publishedDiagnostic = try? Data(
            contentsOf: publicRunURL.appendingPathComponent("diagnostic.artifact")
        ) else { throw DiskReplayError.bindingMismatch }
        guard index == expectedIndex,
              UInt64(publishedStdout.count) == candidate.stdout.sizeBytes,
              digest(publishedStdout) == candidate.stdout.sha256,
              UInt64(publishedStderr.count) == candidate.stderr.sizeBytes,
              digest(publishedStderr) == candidate.stderr.sha256,
              UInt64(publishedDiagnostic.count) == candidate.diagnostics.sizeBytes,
              digest(publishedDiagnostic) == candidate.diagnostics.sha256
        else { throw DiskReplayError.bindingMismatch }
        return ManagedFinalizationBundle(
            stdout: metadata.binding.stdout,
            stderr: metadata.binding.stderr,
            diagnostics: metadata.binding.diagnostics,
            runIndexDigest: digest(Data("\(metadata.binding.stdout.sha256):\(metadata.binding.stderr.sha256)".utf8)),
            finalizedAt: metadata.binding.finalizedAt
        )
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

private struct PublicationMetadataFixture: Codable {
    let schema: String
    let binding: ManagedFinalizationReplayBinding
}

private struct PublicationIndexFixture: Codable, Equatable {
    let schema: String
    let runID: UUID
    let requestDigest: String
    let stdoutSHA256: String
    let stderrSHA256: String
    let diagnosticSHA256: String
    let finalizedAt: Date
}

private func inspectSpool(_ url: URL, handle: String) throws -> ManagedArtifactIdentity {
    let file = try FileHandle(forUpdating: url)
    try file.synchronize()
    try file.seek(toOffset: 0)
    let data = try file.readToEnd() ?? Data()
    try file.close()
    return ManagedArtifactIdentity(
        handle: handle,
        sizeBytes: UInt64(data.count),
        lineCount: UInt64(data.filter { $0 == 0x0a }.count),
        sha256: digest(data)
    )
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func fsyncDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY)
    guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
}

private func createExclusiveAuthenticationMaterial(
    _ material: ManagedSupervisorAuthenticationMaterial,
    at url: URL
) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(material)
    let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteFileExists) }
    var shouldRemove = true
    defer {
        Darwin.close(descriptor)
        if shouldRemove { try? FileManager.default.removeItem(at: url) }
    }
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
            guard written > 0 else { throw CocoaError(.fileWriteUnknown) }
            offset += written
        }
    }
    guard Darwin.fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
          status.st_uid == geteuid(),
          status.st_mode & mode_t(0o777) == mode_t(0o600)
    else { throw CocoaError(.fileWriteNoPermission) }
    try fsyncDirectory(url.deletingLastPathComponent())
    shouldRemove = false
}
