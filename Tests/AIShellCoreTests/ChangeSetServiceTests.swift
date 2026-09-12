import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import AIShellCore

final class ChangeSetServiceTests: XCTestCase {
    func testAdmissionIntentCrashReconcilesBeforePublicationValidation() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "admission-intent")
        await fixture.faults.crashOnce(at: .dedicatedAdmissionIntentAfter)
        do {
            _ = try await fixture.service.apply(request)
            XCTFail("admission intent直後のcrashが発生しませんでした")
        } catch let crash as ApplyChangeSetSimulatedCrash {
            XCTAssertEqual(crash.point, .dedicatedAdmissionIntentAfter)
        }

        let restarted = try fixture.freshService()
        let recovered = try await restarted.apply(request)
        XCTAssertEqual(recovered.status, .abortedBeforeSideEffect)
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("one.txt"),
            encoding: .utf8), "before")
    }

    func testAdmissionRegistryCrashReplaysIntentAndClearsItExactly() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "admission-registry")
        await fixture.faults.crashOnce(at: .dedicatedAdmissionRegistryAfter)
        do {
            _ = try await fixture.service.apply(request)
            XCTFail("admission registry反映直後のcrashが発生しませんでした")
        } catch let crash as ApplyChangeSetSimulatedCrash {
            XCTAssertEqual(crash.point, .dedicatedAdmissionRegistryAfter)
        }

        let restarted = try fixture.freshService()
        let firstReplay = try await restarted.apply(request)
        let secondRestart = try fixture.freshService()
        let secondReplay = try await secondRestart.apply(request)
        XCTAssertEqual(firstReplay, secondReplay)
        XCTAssertEqual(firstReplay.status, .abortedBeforeSideEffect)
    }

    func testTerminalIntentCrashReconcilesBeforePublicationValidation() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "terminal-intent")
        await fixture.faults.crashOnce(at: .dedicatedTerminalIntentAfter)
        do {
            _ = try await fixture.service.apply(request)
            XCTFail("terminal intent直後のcrashが発生しませんでした")
        } catch let crash as ApplyChangeSetSimulatedCrash {
            XCTAssertEqual(crash.point, .dedicatedTerminalIntentAfter)
        }

        let restarted = try fixture.freshService()
        let replay = try await restarted.apply(request)
        XCTAssertEqual(replay.status, .committed)
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("one.txt"),
            encoding: .utf8), "terminal-intent")
    }

    func testTerminalTransactionCrashReconcilesBeforePublicationValidation() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "terminal-transaction")
        await fixture.faults.crashOnce(at: .dedicatedTerminalTransactionAfter)
        do {
            _ = try await fixture.service.apply(request)
            XCTFail("terminal transaction反映直後のcrashが発生しませんでした")
        } catch let crash as ApplyChangeSetSimulatedCrash {
            XCTAssertEqual(crash.point, .dedicatedTerminalTransactionAfter)
        }

        let restarted = try fixture.freshService()
        let replay = try await restarted.apply(request)
        XCTAssertEqual(replay.status, .committed)
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("one.txt"),
            encoding: .utf8), "terminal-transaction")
    }

    func testExpiredTerminalIntentStillConvergesBeforePublicationValidation() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "expired-terminal-intent")
        await fixture.faults.crashOnce(at: .dedicatedTerminalIntentAfter)
        do {
            _ = try await fixture.service.apply(request)
            XCTFail("terminal intent直後のcrashが発生しませんでした")
        } catch is ApplyChangeSetSimulatedCrash {}
        await fixture.clock.advance(by: .seconds(request.retentionSeconds + 1))

        let restarted = try fixture.freshService()
        _ = try await restarted.currentCursor(root: fixture.root)
        do {
            _ = try await restarted.apply(request)
            XCTFail("期限切れreplayが成功しました")
        } catch let error as ApplyChangeSetError {
            XCTAssertEqual(error.code, .changeSetExpired)
        }
    }

    func testTerminalRegistryCrashReplaysIntentAndClearsItExactly() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "terminal-registry")
        await fixture.faults.crashOnce(at: .dedicatedTerminalRegistryAfter)
        do {
            _ = try await fixture.service.apply(request)
            XCTFail("registry反映直後のcrashが発生しませんでした")
        } catch let crash as ApplyChangeSetSimulatedCrash {
            XCTAssertEqual(crash.point, .dedicatedTerminalRegistryAfter)
        }

        let restarted = try fixture.freshService()
        let firstReplay = try await restarted.apply(request)
        let secondRestart = try fixture.freshService()
        let secondReplay = try await secondRestart.apply(request)
        XCTAssertEqual(firstReplay, secondReplay)
        XCTAssertEqual(firstReplay.status, .committed)
    }

    func testCompletedCutoverPersistsCoreOnlyStateAndFreshServiceReplays() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "core-only")
        let first = try await fixture.service.apply(request)

        let durable = try fixture.probe.durableStateSchemaAndKeys()
        XCTAssertEqual(durable.schema, "aishell.apply-change-set-core-state.v1")
        XCTAssertTrue(durable.keys.isDisjoint(with: [
            "slots", "transactions", "runtimeEvents", "runtimeCommitted",
            "controlReceipts",
        ]))

        let restarted = try fixture.freshService()
        let replay = try await restarted.apply(request)
        XCTAssertEqual(replay, first)
        let restartedDurable = try fixture.probe.durableStateSchemaAndKeys()
        XCTAssertEqual(restartedDurable.schema, "aishell.apply-change-set-core-state.v1")
    }

    func testLegacyCommittedRuntimeReceiptCutsOverAndReplaysWithCanonicalDigest() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "legacy-committed")
        let first = try await fixture.service.apply(request)
        try await fixture.probe.installLegacyCommittedCutoverFixture(for: request)

        let restarted = try fixture.freshService()
        let replay = try await restarted.apply(request)
        XCTAssertEqual(replay, first)
        XCTAssertEqual(try fixture.probe.durableStateSchemaAndKeys().schema,
            "aishell.apply-change-set-core-state.v1")
    }

    func testCoreOnlyModeIgnoresAndDurablyRetiresLegacyJournalResidue() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "journal-retirement")
        _ = try await fixture.service.apply(request)
        try fixture.probe.installCorruptLegacyJournalResidue()

        let restarted = try fixture.freshService()
        _ = try await restarted.currentCursor(root: fixture.root)
        XCTAssertFalse(fixture.probe.legacyJournalResidueExists())
    }

    func testLegacyRolledBackCutoverResumesCleanupAfterCrashBeforePublishingStores() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "legacy-rollback")
        await fixture.faults.crashOnce(at: .stageFSyncAfter)
        do { _ = try await fixture.service.apply(request); XCTFail("prepared crashが発生しませんでした") }
        catch is ApplyChangeSetSimulatedCrash {}
        try await fixture.probe.installLegacyRolledBackCutoverFixture(for: request)

        let cutoverFault = ApplyChangeSetFailureInjector()
        await cutoverFault.crashOnce(at: .evidenceMetadataReplacementRenameAfter)
        let interrupted = try fixture.freshService(failureInjector: cutoverFault)
        do { _ = try await interrupted.apply(request); XCTFail("legacy recovery crashが発生しませんでした") }
        catch let crash as ApplyChangeSetSimulatedCrash {
            XCTAssertEqual(crash.point, .evidenceMetadataReplacementRenameAfter)
        }

        let restarted = try fixture.freshService()
        let replay = try await restarted.apply(request)
        XCTAssertEqual(replay.status, .abortedBeforeSideEffect)
        XCTAssertEqual(try fixture.probe.durableStateSchemaAndKeys().schema,
            "aishell.apply-change-set-core-state.v1")
    }

    func testAtomicMixedCommitAndReplay() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        try Data("before".utf8).write(to: fixture.root.appendingPathComponent("one"))
        let request = ApplyChangeSetRequest(
            clientID: fixture.client.clientID,
            clientEpoch: fixture.client.epoch,
            requestSequence: 1,
            cursor: try await fixture.service.currentCursor(root: fixture.root),
            changes: [
                .write(id: "write", path: "one", expected: .file(Self.sha(Data("before".utf8))), content: .utf8("after")),
                .create(id: "create", path: "two", expected: .absent, content: .utf8("created")),
            ],
            diffByteBudget: 65_536,
            retentionSeconds: 3_600
        )

        let first = try await fixture.service.apply(request)
        let replay = try await fixture.service.apply(request)

        XCTAssertEqual(first, replay)
        XCTAssertEqual(first.status, .committed)
        XCTAssertEqual(first.transactionID, request.transactionIdentity)
        XCTAssertEqual(first.clientID, request.clientID)
        XCTAssertEqual(first.clientEpoch, request.clientEpoch)
        XCTAssertEqual(first.root, fixture.root.path)
        XCTAssertEqual(first.summary?.writeCount, 1)
        XCTAssertEqual(first.summary?.createCount, 1)
        XCTAssertEqual(first.changes.map(\.kind), ["write", "create"])
        // A committed transaction implies every listed change was applied, so each change reports the
        // resulting state (path, digest, content) rather than a redundant per-change verdict string.
        XCTAssertEqual(first.status, .committed)
        XCTAssertTrue(first.changes.allSatisfy { $0.afterSHA256 != nil })
        XCTAssertNotNil(first.changes[0].beforeIdentity)
        XCTAssertNotNil(first.changes[0].afterIdentity)
        XCTAssertNotNil(first.diffPreview)
        XCTAssertEqual(first.hasMore, false)
        XCTAssertNotNil(first.diffArtifact.expiresAt)
        let artifactSlice = try await fixture.evidence.read(
            handle: first.diffArtifact.handle,
            mode: .range(offset: 0, length: first.diffArtifact.sizeBytes),
            byteBudget: first.diffArtifact.sizeBytes
        )
        let artifactBytes = artifactSlice.base64.flatMap { Data(base64Encoded: $0) }
            ?? artifactSlice.text.map { Data($0.utf8) }
        let completeArtifactBytes = try XCTUnwrap(artifactBytes)
        let decodedArtifact = try ChangeSetDiffArtifactBuilder.decode(completeArtifactBytes)
        let durableManifestDigest = try await fixture.probe.manifestDigest(for: request)
        XCTAssertEqual(decodedArtifact.header.binding.manifestDigest, durableManifestDigest)
        let artifactKinds: [ChangeSetDiffArtifactBuilder.Kind] = decodedArtifact.header.changes.map { $0.kind }
        XCTAssertEqual(artifactKinds, [.write, .create])
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("one"), encoding: .utf8), "after")
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("two"), encoding: .utf8), "created")
    }

    func testDurableStateMachineReachesFinalizedInMonotonicOrder() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "state-after")

        _ = try await fixture.service.apply(request)

        let terminalState = try await fixture.probe.transactionState(for: request)
        XCTAssertEqual(terminalState, .finalized)
        let states = try await fixture.probe.transactionJournalStates(for: request).reduce(into: [ApplyChangeSetTransactionState]()) {
            if $0.last != $1 { $0.append($1) }
        }
        XCTAssertEqual(states, [.preparing, .prepared, .commitDecided, .filesystemCommitted, .runtimeCommitted, .trashCommitted, .finalized])
    }

    func testPreparedCrashRollsBackAndTerminatesWithoutRecommit() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "must-not-commit")
        await fixture.faults.crashOnce(at: .stageFSyncAfter)
        do { _ = try await fixture.service.apply(request); XCTFail("prepared crashが発生しませんでした") }
        catch is ApplyChangeSetSimulatedCrash {}

        let restarted = try await fixture.probe.restartedService(
            failureInjector: ApplyChangeSetFailureInjector(), clock: fixture.clock, autoRecover: false
        )
        _ = try await restarted.recover(root: fixture.root)

        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("one.txt"), encoding: .utf8), "before")
        let terminalState = try await fixture.probe.transactionState(for: request)
        XCTAssertEqual(terminalState, .abortedBeforeSideEffect)
        let states = try await fixture.probe.transactionJournalStates(for: request).reduce(into: [ApplyChangeSetTransactionState]()) {
            if $0.last != $1 { $0.append($1) }
        }
        XCTAssertEqual(states, [.preparing, .prepared, .rollbackDecided, .rolledBack, .abortedBeforeSideEffect])
    }

    func testConcurrentQuotaSnapshotPersistenceDoesNotDeadlockOrLoseNewerMutation() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "concurrent-persistence")
        await fixture.faults.crashOnce(at: .reservationFSyncAfter)
        do { _ = try await fixture.service.apply(request); XCTFail("reservation crashが発生しませんでした") }
        catch is ApplyChangeSetSimulatedCrash {}

        let keys = ["concurrency-a", "concurrency-b"]
        let completed = expectation(description: "quota snapshot writer completes")
        Task {
            await fixture.probe.exerciseConcurrentPersistence(keys: keys)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 5)

        _ = try await fixture.probe.restartedService(
            failureInjector: ApplyChangeSetFailureInjector(), clock: fixture.clock, autoRecover: false
        )
        let persistedBoth = await fixture.probe.hasConcurrentPersistenceKeys(keys)
        XCTAssertTrue(persistedBoth)
    }

    func testConcurrentApplyCallsSerializeToOneAdmissionAndTerminalReplay() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "serialized-apply")
        let entered = expectation(description: "first apply entered commit")
        let release = DispatchSemaphore(value: 0)
        await fixture.faults.raceOnce(at: .afterParentPin, action: .init {
            entered.fulfill(); release.wait()
        })
        let first = Task { try await fixture.service.apply(request) }
        await fulfillment(of: [entered], timeout: 3)
        let second = Task { try await fixture.service.apply(request) }
        try await Task.sleep(for: .milliseconds(50))
        release.signal()
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult, secondResult)
        let admissionCount = try await fixture.probe.admissionCount(request)
        XCTAssertEqual(admissionCount, 1)
    }

    func testConcurrentApplyAndControlDoNotConsumeUnplannedQuotaSnapshotSlot() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "serialized-control")
        let entered = expectation(description: "apply entered commit")
        let release = DispatchSemaphore(value: 0)
        await fixture.faults.raceOnce(at: .afterParentPin, action: .init {
            entered.fulfill(); release.wait()
        })
        let apply = Task { try await fixture.service.apply(request) }
        await fulfillment(of: [entered], timeout: 3)
        let control = Task { try await fixture.probe.allocateClient(service: fixture.service) }
        try await Task.sleep(for: .milliseconds(50))
        release.signal()
        let result = try await apply.value
        let replay = try await fixture.service.apply(request)
        XCTAssertEqual(result, replay)
        let allocated = try await control.value
        XCTAssertFalse(allocated.clientID.isEmpty)
    }

    func testConcurrentApplyAndRecoverDoNotRunRecoveryTwice() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "serialized-recovery")
        let entered = expectation(description: "apply entered commit")
        let release = DispatchSemaphore(value: 0)
        await fixture.faults.raceOnce(at: .afterParentPin, action: .init {
            entered.fulfill(); release.wait()
        })
        let apply = Task { try await fixture.service.apply(request) }
        await fulfillment(of: [entered], timeout: 3)
        let recover = Task { try await fixture.service.recover(root: fixture.root) }
        try await Task.sleep(for: .milliseconds(50))
        release.signal()
        let result = try await apply.value
        let recovered = try await recover.value
        XCTAssertEqual(result.status, .committed)
        XCTAssertTrue(recovered.isEmpty)
        let runtimeCommitCount = try await fixture.probe.runtimeCommitCount(request)
        XCTAssertEqual(runtimeCommitCount, 1)
    }

    func testCancelledOperationGateWaiterDoesNotBlockFollowingWaiter() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "cancelled-waiter")
        let entered = expectation(description: "apply entered commit")
        let release = DispatchSemaphore(value: 0)
        await fixture.faults.raceOnce(at: .afterParentPin, action: .init {
            entered.fulfill(); release.wait()
        })
        let apply = Task { try await fixture.service.apply(request) }
        await fulfillment(of: [entered], timeout: 3)
        let cancelled = Task { try await fixture.service.currentCursor(root: fixture.root) }
        try await Task.sleep(for: .milliseconds(20))
        cancelled.cancel()
        let followingFirst = Task { try await fixture.probe.allocateClient(service: fixture.service) }
        try await Task.sleep(for: .milliseconds(20))
        let followingSecond = Task { try await fixture.probe.allocateClient(service: fixture.service) }
        try await Task.sleep(for: .milliseconds(30))
        release.signal()
        _ = try await apply.value
        do { _ = try await cancelled.value; XCTFail("cancelled waiterが成功しました") }
        catch is CancellationError { }
        let firstClient = try await followingFirst.value
        let secondClient = try await followingSecond.value
        XCTAssertLessThan(firstClient.slot, secondClient.slot)
    }

    func testTrashCommittedRequiresEveryDeleteReceipt() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        try Data("A".utf8).write(to: fixture.root.appendingPathComponent("delete-a"))
        try Data("B".utf8).write(to: fixture.root.appendingPathComponent("delete-b"))
        let request = ApplyChangeSetRequest(
            clientID: fixture.client.clientID, clientEpoch: fixture.client.epoch, requestSequence: 1,
            cursor: try await fixture.service.currentCursor(root: fixture.root),
            changes: [
                .delete(id: "a", path: "delete-a", expected: .file(Self.sha(Data("A".utf8)))),
                .delete(id: "b", path: "delete-b", expected: .file(Self.sha(Data("B".utf8)))),
            ], diffByteBudget: 65_536, retentionSeconds: 3_600
        )
        await fixture.faults.crashOnce(at: .trashReceiptFSyncAfter)
        do { _ = try await fixture.service.apply(request); XCTFail("trash receipt crashが発生しませんでした") }
        catch is ApplyChangeSetSimulatedCrash {}

        let interruptedState = try await fixture.probe.transactionState(for: request)
        let interruptedReceipts = try await fixture.probe.trashReceiptCount(for: request)
        XCTAssertEqual(interruptedState, .runtimeCommitted)
        XCTAssertEqual(interruptedReceipts, 1)
        let restarted = try await fixture.probe.restartedService(
            failureInjector: ApplyChangeSetFailureInjector(), clock: fixture.clock, autoRecover: false
        )
        _ = try await restarted.recover(root: fixture.root)
        let terminalState = try await fixture.probe.transactionState(for: request)
        let terminalReceipts = try await fixture.probe.trashReceiptCount(for: request)
        XCTAssertEqual(terminalState, .finalized)
        XCTAssertEqual(terminalReceipts, 2)
    }

    func testStalePreconditionLeavesWholeGraphUntouched() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        try Data("A".utf8).write(to: fixture.root.appendingPathComponent("a"))
        try Data("B".utf8).write(to: fixture.root.appendingPathComponent("b"))
        let request = ApplyChangeSetRequest(
            clientID: fixture.client.clientID,
            clientEpoch: fixture.client.epoch,
            requestSequence: 1,
            cursor: try await fixture.service.currentCursor(root: fixture.root),
            changes: [
                .write(id: "a", path: "a", expected: .file(Self.sha(Data("A".utf8))), content: .utf8("AA")),
                .write(id: "b", path: "b", expected: .file(Self.sha(Data("stale".utf8))), content: .utf8("BB")),
            ],
            diffByteBudget: 65_536,
            retentionSeconds: 3_600
        )

        do {
            _ = try await fixture.service.apply(request)
            XCTFail("stale preconditionを受理しました")
        } catch let error as ApplyChangeSetError {
            XCTAssertEqual(error.code, .contentChanged)
        }
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("a"), encoding: .utf8), "A")
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("b"), encoding: .utf8), "B")
    }

    func testAdmittedCrashRecoversWithoutClientRetry() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        try Data("before".utf8).write(to: fixture.root.appendingPathComponent("one"))
        let request = ApplyChangeSetRequest(
            clientID: fixture.client.clientID,
            clientEpoch: fixture.client.epoch,
            requestSequence: 1,
            cursor: try await fixture.service.currentCursor(root: fixture.root),
            changes: [.write(id: "one", path: "one", expected: .file(Self.sha(Data("before".utf8))), content: .utf8("after"))],
            diffByteBudget: 65_536,
            retentionSeconds: 3_600
        )
        await fixture.faults.crashOnce(at: .admissionFSyncAfter)
        do {
            _ = try await fixture.service.apply(request)
            XCTFail("注入crashが発生しませんでした")
        } catch is ApplyChangeSetSimulatedCrash {}

        let restarted = try fixture.freshService()
        _ = try await restarted.recover(root: fixture.root)
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("one"), encoding: .utf8), "before")
        let replay = try await restarted.apply(request)
        XCTAssertEqual(replay.status, .abortedBeforeSideEffect)
    }

    func testReservationCrashRetryReusesDurableReservationAndRejectsDifferentDigest() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "after-reservation-crash")
        await fixture.faults.crashOnce(at: .reservationFSyncAfter)
        do { _ = try await fixture.service.apply(request); XCTFail("reservation crashが発生しませんでした") }
        catch is ApplyChangeSetSimulatedCrash {}

        do { _ = try await fixture.service.apply(request.replacingFirstContent(.utf8("different"))); XCTFail("異digest reservation retryを受理しました") }
        catch let error as ApplyChangeSetError { XCTAssertEqual(error.code, .changeSetSequenceConflict) }
        let result = try await fixture.service.apply(request)
        XCTAssertEqual(result.status, .committed)
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("one.txt"), encoding: .utf8), "after-reservation-crash")
    }

    func testDiffPreviewNeverReturnsPartialJSONItemAtTinyBudget() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        var request = try await fixture.singleWriteRequest(after: "preview-after")
        request.diffByteBudget = 1
        let result = try await fixture.service.apply(request)
        XCTAssertEqual(result.diffPreview, "")
        XCTAssertEqual(result.returnedDiffBytes, 0)
        XCTAssertEqual(result.hasMore, true)
        XCTAssertGreaterThan(result.omittedDiffBytes, 0)
    }

    func testAdmissionCrashThenExternalWriteFailsClosedWithoutOverwrite() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "caller-after")
        await fixture.faults.crashOnce(at: .admissionFSyncAfter)
        do { _ = try await fixture.service.apply(request); XCTFail("admission crashが発生しませんでした") }
        catch is ApplyChangeSetSimulatedCrash {}

        let external = Data("external-after-admission".utf8)
        let target = fixture.root.appendingPathComponent("one.txt")
        try external.write(to: target)
        let restarted = try fixture.freshService()
        do { _ = try await restarted.recover(root: fixture.root); XCTFail("admission後の外部変更を上書きしました") }
        catch let error as ApplyChangeSetError {
            XCTAssertEqual(error.code, .externalConflictDuringCommit)
            XCTAssertEqual(error.context?.transactionID, request.transactionIdentity)
            XCTAssertEqual(error.context?.clientID, request.clientID)
            XCTAssertEqual(error.context?.recoveryState, "recovery_required")
            XCTAssertEqual(error.context?.nextAction, "resolve_external_conflict_then_retry_apply_change_set")
        }
        XCTAssertEqual(try Data(contentsOf: target), external)
    }

    func testPinnedNestedParentReplacementIsDetectedBeforeMutation() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let parent = fixture.root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let target = parent.appendingPathComponent("file.txt")
        try Data("before".utf8).write(to: target)
        let request = ApplyChangeSetRequest(
            clientID: fixture.client.clientID,
            clientEpoch: fixture.client.epoch,
            requestSequence: 1,
            cursor: try await fixture.service.currentCursor(root: fixture.root),
            changes: [.write(id: "nested", path: "nested/file.txt", expected: .file(Self.sha(Data("before".utf8))), content: .utf8("after"))],
            diffByteBudget: 65_536,
            retentionSeconds: 3_600
        )
        let parked = fixture.root.appendingPathComponent("nested-parked", isDirectory: true)
        await fixture.faults.raceOnce(at: .afterParentPin, action: .init {
            try FileManager.default.moveItem(at: parent, to: parked)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            try Data("replacement".utf8).write(to: parent.appendingPathComponent("file.txt"))
        })
        do { _ = try await fixture.service.apply(request); XCTFail("parent replacementを受理しました") }
        catch let error as ApplyChangeSetError { XCTAssertEqual(error.code, .changeSetRecoveryRequired) }
        XCTAssertEqual(try String(contentsOf: parked.appendingPathComponent("file.txt"), encoding: .utf8), "before")
        XCTAssertEqual(try String(contentsOf: parent.appendingPathComponent("file.txt"), encoding: .utf8), "replacement")
    }

    func testCommitDecidedTransactionCannotBeOwnerAborted() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "after")
        await fixture.faults.crashOnce(at: .commitDecisionFSyncAfter)
        do { _ = try await fixture.service.apply(request); XCTFail("commit decision crashが発生しませんでした") }
        catch is ApplyChangeSetSimulatedCrash {}

        let restarted = try fixture.freshService()
        do {
            _ = try await fixture.probe.ownerAbort(ApplyChangeSetTransactionID(request.transactionIdentity), service: restarted)
            XCTFail("commit_decided transactionをabortしました")
        } catch let error as ApplyChangeSetError {
            XCTAssertEqual(error.code, .changeSetRecoveryRequired)
        }
    }

    func testOwnerAbortTerminalIntentCrashReconcilesBeforePublicationValidation() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "owner-abort-intent")
        await fixture.faults.crashOnce(at: .materializationBefore)
        do { _ = try await fixture.service.apply(request); XCTFail("prepared crashが発生しませんでした") }
        catch is ApplyChangeSetSimulatedCrash {}

        await fixture.faults.crashOnce(at: .dedicatedTerminalIntentAfter)
        do {
            _ = try await fixture.probe.ownerAbort(
                ApplyChangeSetTransactionID(request.transactionIdentity), service: fixture.service)
            XCTFail("owner abort intent直後のcrashが発生しませんでした")
        } catch let crash as ApplyChangeSetSimulatedCrash {
            XCTAssertEqual(crash.point, .dedicatedTerminalIntentAfter)
        }

        let restarted = try fixture.freshService()
        let replay = try await fixture.probe.ownerAbort(
            ApplyChangeSetTransactionID(request.transactionIdentity), service: restarted)
        XCTAssertEqual(replay.status, .abortedBeforeSideEffect)
    }

    func testManifestTamperAfterCommitDecisionFailsAuthenticatedRecovery() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "manifest-after")
        await fixture.faults.crashOnce(at: .commitDecisionFSyncAfter)
        do { _ = try await fixture.service.apply(request); XCTFail("commit decision crashが発生しませんでした") }
        catch is ApplyChangeSetSimulatedCrash {}
        let manifest = fixture.root.appendingPathComponent(".aishell-transactions/\(request.transactionIdentity)/manifest.json")
        var bytes = try Data(contentsOf: manifest); bytes.append(0x20); try bytes.write(to: manifest)
        let restarted = try fixture.freshService()
        do { _ = try await restarted.recover(root: fixture.root); XCTFail("改ざんmanifestを受理しました") }
        catch let error as ApplyChangeSetError { XCTAssertEqual(error.code, .changeSetStoreCorrupt) }
    }

    func testReservationBlocksAreReleasedAsArtifactMaterialIsWritten() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: String(repeating: "x", count: 8_192))
        await fixture.faults.crashOnce(at: .reservationFSyncAfter)
        do { _ = try await fixture.service.apply(request); XCTFail("reservation crashが発生しませんでした") }
        catch is ApplyChangeSetSimulatedCrash {}
        func remainingExtentBytes() throws -> Int {
            let urls = (FileManager.default.enumerator(at: fixture.base, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL]) ?? []
            return try urls.filter { $0.pathExtension == "extent" }
                .reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        }
        let before = try remainingExtentBytes()
        await fixture.faults.crashOnce(at: .diffArtifactFSyncAfter)
        do { _ = try await fixture.service.apply(request); XCTFail("artifact crashが発生しませんでした") }
        catch is ApplyChangeSetSimulatedCrash {}
        let after = try remainingExtentBytes()
        XCTAssertLessThan(after, before, "予約blockを保持したまま別artifactを追加書込みしています")
    }

    func testQuotaMaterialRenameCrashReconcilesPlannedFinalBeforeRollback() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "rename-receipt-crash")
        await fixture.faults.crashOnce(at: .quotaMaterialRenameAfter)
        do {
            _ = try await fixture.service.apply(request)
            XCTFail("quota material rename後のcrashが発生しませんでした")
        } catch let crash as ApplyChangeSetSimulatedCrash {
            XCTAssertEqual(crash.point, .quotaMaterialRenameAfter)
        }

        let unlinkFault = ApplyChangeSetFailureInjector()
        await unlinkFault.crashOnce(at: .evidenceUnlinkIntentAfter)
        let firstRestart = try fixture.freshService(failureInjector: unlinkFault)
        do { _ = try await firstRestart.apply(request); XCTFail("evidence unlink intent後crashが発生しませんでした") }
        catch let crash as ApplyChangeSetSimulatedCrash { XCTAssertEqual(crash.point, .evidenceUnlinkIntentAfter) }
        let restarted = try fixture.freshService()
        let terminal = try await restarted.apply(request)
        XCTAssertEqual(terminal.status, .abortedBeforeSideEffect)
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("one.txt"), encoding: .utf8), "before")
        _ = try await restarted.recover(root: fixture.root)
        _ = try await restarted.recover(root: fixture.root)
        let evidenceDirectory = fixture.base.appendingPathComponent("state/evidence", isDirectory: true)
        let evidenceFiles = try FileManager.default.contentsOfDirectory(at: evidenceDirectory, includingPropertiesForKeys: nil)
        let orphanData = evidenceFiles.filter { $0.pathExtension == "data" }.filter {
            !FileManager.default.fileExists(atPath: $0.deletingPathExtension().appendingPathExtension("json").path)
        }
        XCTAssertTrue(orphanData.isEmpty, "quota-owned unreferenced evidence dataが残存しています")
    }

    func testPreparedQuotaWithoutStateBindingIsAbandonedAfterExpiredLease() async throws {
        let expiredOwner = ChangeSetQuotaLedger.OwnerBinding(
            bootID: "test-expired-boot", processStartIdentity: "test-expired-process",
            instanceNonce: "test-expired-instance", leaseExpiresAt: Date(timeIntervalSinceNow: -1_200)
        )
        let fixture = try await Fixture.make(quotaOwner: expiredOwner)
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "orphan-quota-retry")
        await fixture.faults.crashOnce(at: .quotaPreparedBeforeBinding)
        do { _ = try await fixture.service.apply(request); XCTFail("quota prepare後のcrashが発生しませんでした") }
        catch let crash as ApplyChangeSetSimulatedCrash { XCTAssertEqual(crash.point, .quotaPreparedBeforeBinding) }

        let restarted = try fixture.freshService()
        let result = try await restarted.apply(request)
        XCTAssertEqual(result.status, .committed)
        let reservationDirectory = fixture.base.appendingPathComponent("state/reservations", isDirectory: true)
        let ledgers = try FileManager.default.contentsOfDirectory(at: reservationDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("quota-") && $0.pathExtension == "json" }
        XCTAssertEqual(ledgers.count, 1, "expired pre-binding quota ledgerが残存しています")
    }

    func testQuotaPrepareFailureBeforeLedgerLeavesNoLeaseDescriptorOrFile() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "prepare-before-ledger")
        await fixture.faults.crashOnce(at: .quotaPrepareBeforeLedger)
        do { _ = try await fixture.service.apply(request); XCTFail("ledger作成前faultが発生しませんでした") }
        catch let crash as ApplyChangeSetSimulatedCrash { XCTAssertEqual(crash.point, .quotaPrepareBeforeLedger) }
        let directory = fixture.base.appendingPathComponent("state/reservations", isDirectory: true)
        let leftovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter {
            $0.lastPathComponent.hasPrefix(".aishell-quota-") || $0.lastPathComponent.hasPrefix("quota-")
        }
        XCTAssertTrue(leftovers.isEmpty)
        let result = try await fixture.service.apply(request)
        XCTAssertEqual(result.status, .committed)
    }

    func testQuotaPrepareFailureAfterLedgerKeepsManifestForScannerConvergence() async throws {
        let expiredOwner = ChangeSetQuotaLedger.OwnerBinding(
            bootID: "prepare-after-boot", processStartIdentity: "prepare-after-process",
            instanceNonce: "prepare-after-instance", leaseExpiresAt: Date(timeIntervalSinceNow: -1_200))
        let fixture = try await Fixture.make(quotaOwner: expiredOwner)
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "prepare-after-ledger")
        await fixture.faults.crashOnce(at: .quotaPrepareAfterLedger)
        do { _ = try await fixture.service.apply(request); XCTFail("ledger作成後faultが発生しませんでした") }
        catch let crash as ApplyChangeSetSimulatedCrash { XCTAssertEqual(crash.point, .quotaPrepareAfterLedger) }
        let directory = fixture.base.appendingPathComponent("state/reservations", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let oldLedger = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("quota-") && $0.pathExtension == "json" })
        XCTAssertNotNil(files.first { $0.lastPathComponent.hasPrefix(".aishell-quota-") && $0.pathExtension == "lease" })
        let result = try await fixture.freshService().apply(request)
        XCTAssertEqual(result.status, .committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldLedger.path))
    }

    func testExpiredScannerReconcilesCanonicalRenameBeforeReceiptAndRemovesOrphan() async throws {
        let expiredOwner = ChangeSetQuotaLedger.OwnerBinding(
            bootID: "canonical-rename-boot", processStartIdentity: "canonical-rename-process",
            instanceNonce: "canonical-rename-instance", leaseExpiresAt: Date(timeIntervalSinceNow: -1_200))
        let fixture = try await Fixture.make(quotaOwner: expiredOwner)
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "canonical-rename-orphan")
        await fixture.faults.crashOnce(at: .quotaCanonicalRenameAfter)
        do { _ = try await fixture.service.apply(request); XCTFail("canonical rename後crashが発生しませんでした") }
        catch let crash as ApplyChangeSetSimulatedCrash { XCTAssertEqual(crash.point, .quotaCanonicalRenameAfter) }
        let reservationDirectory = fixture.base.appendingPathComponent("state/reservations", isDirectory: true)
        let oldLedger = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: reservationDirectory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("quota-") && $0.pathExtension == "json" })
        let result = try await fixture.freshService().apply(request)
        XCTAssertEqual(result.status, .committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldLedger.path))
    }

    func testPreparedQuotaAbandonmentIntentCrashResumesCleanup() async throws {
        let expiredOwner = ChangeSetQuotaLedger.OwnerBinding(
            bootID: "test-abandon-crash-boot", processStartIdentity: "test-abandon-crash-process",
            instanceNonce: "test-abandon-crash-instance", leaseExpiresAt: Date(timeIntervalSinceNow: -1_200)
        )
        let fixture = try await Fixture.make(quotaOwner: expiredOwner)
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "abandon-intent-retry")
        await fixture.faults.crashOnce(at: .quotaPreparedBeforeBinding)
        do { _ = try await fixture.service.apply(request); XCTFail("quota prepare後のcrashが発生しませんでした") }
        catch is ApplyChangeSetSimulatedCrash {}
        let reservationDirectory = fixture.base.appendingPathComponent("state/reservations", isDirectory: true)
        let oldLedger = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: reservationDirectory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("quota-") && $0.pathExtension == "json" })

        let scanFaults = ApplyChangeSetFailureInjector()
        await scanFaults.crashOnce(at: .quotaAbandonmentIntentAfter)
        let interrupted = try await fixture.probe.restartedService(
            failureInjector: scanFaults, clock: fixture.clock, autoRecover: false
        )
        do { _ = try await interrupted.apply(request); XCTFail("abandonment intent後のcrashが発生しませんでした") }
        catch let crash as ApplyChangeSetSimulatedCrash { XCTAssertEqual(crash.point, .quotaAbandonmentIntentAfter) }

        let restarted = try fixture.freshService()
        let result = try await restarted.apply(request)
        XCTAssertEqual(result.status, .committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldLedger.path), "abandonment intent ledgerが再開後も残存しています")
    }

    func testExpiredLeaseCleansMaterializedCanonicalUnadmittedReservation() async throws {
        let expiredOwner = ChangeSetQuotaLedger.OwnerBinding(
            bootID: "test-expired-bound-boot", processStartIdentity: "test-expired-bound-process",
            instanceNonce: "test-expired-bound-instance", leaseExpiresAt: Date(timeIntervalSinceNow: -1_200)
        )
        let fixture = try await Fixture.make(quotaOwner: expiredOwner)
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "bound-quota-retry")
        await fixture.faults.crashOnce(at: .reservationFSyncAfter)
        do { _ = try await fixture.service.apply(request); XCTFail("reservation receipt後のcrashが発生しませんでした") }
        catch is ApplyChangeSetSimulatedCrash {}
        let reservationDirectory = fixture.base.appendingPathComponent("state/reservations", isDirectory: true)
        let oldLedger = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: reservationDirectory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("quota-") && $0.pathExtension == "json" })

        let restarted = try fixture.freshService()
        let result = try await restarted.apply(request)
        XCTAssertEqual(result.status, .committed)
        XCTAssertEqual(result.requestSequence, request.requestSequence)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldLedger.path), "expired unadmitted canonical ledgerが残存しています")
    }

    func testExpiredLeaseResumesStateGenerationReleaseAfterDetachCrash() async throws {
        let expiredOwner = ChangeSetQuotaLedger.OwnerBinding(
            bootID: "test-detach-boot", processStartIdentity: "test-detach-process",
            instanceNonce: "test-detach-instance", leaseExpiresAt: Date(timeIntervalSinceNow: -1_200)
        )
        let fixture = try await Fixture.make(quotaOwner: expiredOwner)
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "detach-crash-retry")
        await fixture.faults.crashOnce(at: .reservationFSyncAfter)
        do { _ = try await fixture.service.apply(request); XCTFail("reservation crashが発生しませんでした") }
        catch is ApplyChangeSetSimulatedCrash {}
        let reservationDirectory = fixture.base.appendingPathComponent("state/reservations", isDirectory: true)
        let oldLedger = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: reservationDirectory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("quota-") && $0.pathExtension == "json" })

        let detachFault = ApplyChangeSetFailureInjector()
        await detachFault.crashOnce(at: .quotaStateDetachAfter)
        let firstRestart = try fixture.freshService(failureInjector: detachFault)
        do { _ = try await firstRestart.apply(request); XCTFail("detach後crashが発生しませんでした") }
        catch let crash as ApplyChangeSetSimulatedCrash { XCTAssertEqual(crash.point, .quotaStateDetachAfter) }

        let secondRestart = try fixture.freshService()
        let result = try await secondRestart.apply(request)
        XCTAssertEqual(result.status, .committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldLedger.path))
    }

    func testCommittedEvidenceMetadataReplacementRenameCrashReplaysFixedExpiry() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "metadata-replacement")
        await fixture.faults.crashOnce(at: .evidenceMetadataReplacementRenameAfter)
        do { _ = try await fixture.service.apply(request); XCTFail("metadata replacement crashが発生しませんでした") }
        catch let crash as ApplyChangeSetSimulatedCrash {
            XCTAssertEqual(crash.point, .evidenceMetadataReplacementRenameAfter)
        }

        let restarted = try fixture.freshService()
        let replay = try await restarted.apply(request)
        XCTAssertEqual(replay.status, .committed)
        let artifact = try await fixture.evidence.read(handle: replay.diffArtifact.handle)
        XCTAssertEqual(artifact.expiresAt, replay.diffArtifact.expiresAt)
        let secondReplay = try await restarted.apply(request)
        XCTAssertEqual(secondReplay.diffArtifact.expiresAt, replay.diffArtifact.expiresAt)
    }

    func testEvidenceMetadataReplacementIntentCrashReconcilesBeforeReloadingMetadata() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "metadata-intent-replacement")
        await fixture.faults.crashOnce(at: .evidenceMetadataReplacementIntentAfter)
        do { _ = try await fixture.service.apply(request); XCTFail("metadata replacement intent後crashが発生しませんでした") }
        catch let crash as ApplyChangeSetSimulatedCrash { XCTAssertEqual(crash.point, .evidenceMetadataReplacementIntentAfter) }
        let restarted = try fixture.freshService()
        let replay = try await restarted.apply(request)
        XCTAssertEqual(replay.status, .committed)
        let artifact = try await fixture.evidence.read(handle: replay.diffArtifact.handle)
        XCTAssertEqual(artifact.expiresAt, replay.diffArtifact.expiresAt)
    }

    func testAbortedEvidenceMetadataReplacementRenameCrashReplaysFixedExpiry() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "aborted-metadata-replacement")
        await fixture.faults.mutateOnce(.expectedContentChanged, at: .beforeFirstTargetReceipt)
        await fixture.faults.crashOnce(at: .evidenceMetadataReplacementRenameAfter)
        do { _ = try await fixture.service.apply(request); XCTFail("aborted metadata replacement crashが発生しませんでした") }
        catch let crash as ApplyChangeSetSimulatedCrash {
            XCTAssertEqual(crash.point, .evidenceMetadataReplacementRenameAfter)
        }

        let restarted = try fixture.freshService()
        let replay = try await restarted.apply(request)
        XCTAssertEqual(replay.status, .abortedBeforeSideEffect)
        let artifact = try await fixture.evidence.read(handle: replay.diffArtifact.handle)
        XCTAssertEqual(artifact.expiresAt, replay.diffArtifact.expiresAt)
        let secondReplay = try await restarted.apply(request)
        XCTAssertEqual(secondReplay.diffArtifact.expiresAt, replay.diffArtifact.expiresAt)
    }

    func testRenameCycleRollsForwardAfterCommitDecisionCrash() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        for (path, value) in [("a", "A"), ("b", "B"), ("c", "C")] { try Data(value.utf8).write(to: fixture.root.appendingPathComponent(path)) }
        let request = ApplyChangeSetRequest(clientID: fixture.client.clientID, clientEpoch: fixture.client.epoch, requestSequence: 1,
            cursor: try await fixture.service.currentCursor(root: fixture.root), changes: [
                .rename(id: "a-b", source: "a", sourceExpected: .file(Self.sha(Data("A".utf8))), destination: "b", destinationExpected: .file(Self.sha(Data("B".utf8)))),
                .rename(id: "b-c", source: "b", sourceExpected: .file(Self.sha(Data("B".utf8))), destination: "c", destinationExpected: .file(Self.sha(Data("C".utf8)))),
                .rename(id: "c-a", source: "c", sourceExpected: .file(Self.sha(Data("C".utf8))), destination: "a", destinationExpected: .file(Self.sha(Data("A".utf8)))),
            ], diffByteBudget: 65_536, retentionSeconds: 3_600)
        await fixture.faults.crashOnce(at: .commitDecisionFSyncAfter)
        do { _ = try await fixture.service.apply(request); XCTFail("commit decision crashが発生しませんでした") }
        catch is ApplyChangeSetSimulatedCrash {}
        let restarted = try fixture.freshService()
        _ = try await restarted.recover(root: fixture.root)
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("a"), encoding: .utf8), "C")
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("b"), encoding: .utf8), "A")
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("c"), encoding: .utf8), "B")
    }

    func testSameContentRenameCycleRecoveryUsesStageIdentityInsteadOfSHAAlone() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let bytes = Data("identical".utf8)
        let a = fixture.root.appendingPathComponent("a")
        let b = fixture.root.appendingPathComponent("b")
        try bytes.write(to: a)
        try bytes.write(to: b)
        XCTAssertEqual(chmod(a.path, 0o600), 0)
        XCTAssertEqual(chmod(b.path, 0o640), 0)
        let request = ApplyChangeSetRequest(
            clientID: fixture.client.clientID,
            clientEpoch: fixture.client.epoch,
            requestSequence: 1,
            cursor: try await fixture.service.currentCursor(root: fixture.root),
            changes: [
                .rename(id: "a-b", source: "a", sourceExpected: .file(Self.sha(bytes)), destination: "b", destinationExpected: .file(Self.sha(bytes))),
                .rename(id: "b-a", source: "b", sourceExpected: .file(Self.sha(bytes)), destination: "a", destinationExpected: .file(Self.sha(bytes))),
            ],
            diffByteBudget: 65_536,
            retentionSeconds: 3_600
        )
        await fixture.faults.crashOnce(at: .commitDecisionFSyncAfter)
        do { _ = try await fixture.service.apply(request); XCTFail("commit decision crashが発生しませんでした") }
        catch is ApplyChangeSetSimulatedCrash {}

        let restarted = try fixture.freshService()
        _ = try await restarted.recover(root: fixture.root)
        let aMode = (try FileManager.default.attributesOfItem(atPath: a.path)[.posixPermissions] as? NSNumber)?.intValue
        let bMode = (try FileManager.default.attributesOfItem(atPath: b.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(aMode, 0o640, "同一SHAでもb由来stageをaへ配置する必要があります")
        XCTAssertEqual(bMode, 0o600, "同一SHAでもa由来stageをbへ配置する必要があります")
    }

    func testFirstTargetReceiptCrashRecoversFromDiskBackedStageAndBackup() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "receipt-after")
        await fixture.faults.crashOnce(at: .firstTargetReceiptAfter)
        do { _ = try await fixture.service.apply(request); XCTFail("target receipt crashが発生しませんでした") }
        catch is ApplyChangeSetSimulatedCrash {}

        let restarted = try fixture.freshService()
        do { _ = try await restarted.currentCursor(root: fixture.root); XCTFail("unfinished transaction中にcursorを公開しました") }
        catch let error as ApplyChangeSetError { XCTAssertEqual(error.code, .changeSetRecoveryRequired) }
        do { _ = try await restarted.apply(request.replacingFirstContent(.utf8("different"))); XCTFail("異digest retryを合流しました") }
        catch let error as ApplyChangeSetError { XCTAssertEqual(error.code, .changeSetSequenceConflict) }
        let joined = try await restarted.apply(request)
        XCTAssertEqual(joined.status, .committed)
        _ = try await restarted.recover(root: fixture.root)
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("one.txt"), encoding: .utf8), "receipt-after")
        let replay = try await restarted.apply(request)
        XCTAssertEqual(replay.status, .committed)
        XCTAssertEqual(replay.requestSequence, request.requestSequence)
        let artifactFiles = try FileManager.default.contentsOfDirectory(at: fixture.base.appendingPathComponent("evidence"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "data" }
        XCTAssertEqual(artifactFiles.count, 1, "commit_decided recoveryでdiff artifactを再生成しました")
    }

    func testRecoveryStageOwnershipIsReleasedBeforeRenameCrashAndSecondRecoveryCompletes() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "recovery-stage-transfer")
        await fixture.faults.crashOnce(at: .commitDecisionFSyncAfter)
        do { _ = try await fixture.service.apply(request); XCTFail("commit decision crashが発生しませんでした") }
        catch is ApplyChangeSetSimulatedCrash {}

        let recoveryFault = ApplyChangeSetFailureInjector()
        await recoveryFault.crashOnce(at: .recoveryStageRenameAfter)
        let firstRestart = try fixture.freshService(failureInjector: recoveryFault)
        do { _ = try await firstRestart.recover(root: fixture.root); XCTFail("stage rename後crashが発生しませんでした") }
        catch let crash as ApplyChangeSetSimulatedCrash { XCTAssertEqual(crash.point, .recoveryStageRenameAfter) }

        let secondRestart = try fixture.freshService()
        _ = try await secondRestart.recover(root: fixture.root)
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("one.txt"), encoding: .utf8), "recovery-stage-transfer")
        let replay = try await secondRestart.apply(request)
        XCTAssertEqual(replay.status, .committed)
    }

    func testRuntimeReceiptCrashFreshRecoveryPersistsSameTerminalReplay() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "runtime-after")
        await fixture.faults.crashOnce(at: .runtimeReceiptFSyncAfter)
        do { _ = try await fixture.service.apply(request); XCTFail("runtime receipt crashが発生しませんでした") }
        catch is ApplyChangeSetSimulatedCrash {}
        await fixture.clock.advance(by: .seconds(10))

        let restarted = try fixture.freshService()
        let recovery = try await restarted.recover(root: fixture.root)
        XCTAssertEqual(recovery.count, 1)
        let replay = try await restarted.apply(request)
        XCTAssertEqual(replay.status, .committed)
        XCTAssertEqual(replay.fromCursor, request.cursor)
        XCTAssertEqual(replay.cursor.sequence, request.cursor.sequence + 1)
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("one.txt"), encoding: .utf8), "runtime-after")
    }

    func testRuntimeCursorCrashFreshRecoveryCreatesReceiptWithoutSecondAdvance() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "runtime-cursor-after")
        await fixture.faults.crashOnce(at: .runtimeCursorFSyncAfter)
        do { _ = try await fixture.service.apply(request); XCTFail("runtime cursor crashが発生しませんでした") }
        catch let crash as ApplyChangeSetSimulatedCrash {
            XCTAssertEqual(crash.point, .runtimeCursorFSyncAfter)
        }

        let restarted = try fixture.freshService()
        _ = try await restarted.recover(root: fixture.root)
        let replay = try await restarted.apply(request)
        XCTAssertEqual(replay.status, .committed)
        XCTAssertEqual(replay.cursor.sequence, request.cursor.sequence + 1)
        let currentCursor = try await restarted.currentCursor(root: fixture.root)
        XCTAssertEqual(currentCursor, replay.cursor)
    }

    func testExternalUnknownBytesRemainUntouchedAcrossFreshRecovery() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "caller-after")
        let external = Data("external-unknown".utf8)
        let target = fixture.root.appendingPathComponent("one.txt")
        await fixture.faults.raceOnce(at: .externalBeforeReceipt, action: .init { try external.write(to: target) })
        do { _ = try await fixture.service.apply(request); XCTFail("external conflictを検出しませんでした") }
        catch let error as ApplyChangeSetError { XCTAssertEqual(error.code, .externalConflictDuringCommit) }

        let restarted = try fixture.freshService()
        do { _ = try await restarted.recover(root: fixture.root); XCTFail("unknown bytesを自動回復しました") }
        catch let error as ApplyChangeSetError { XCTAssertEqual(error.code, .externalConflictDuringCommit) }
        XCTAssertEqual(try Data(contentsOf: target), external)
    }

    func testDurableStateIsPlainJSONAndFreshServiceReplays() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "very-secret-after-bytes")
        let first = try await fixture.service.apply(request)
        let bytes = try Data(contentsOf: fixture.base.appendingPathComponent("state/apply-change-set-state.enc.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(object["schema"] as? String, "aishell.apply-change-set-core-state.v1")
        XCTAssertNil(object["ciphertext"])

        let restarted = try fixture.freshService()
        let replay = try await restarted.apply(request)
        XCTAssertEqual(replay, first)
    }

    func testReservationStoresReadableRequestAndKeepsIndependentQuota() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let request = try await fixture.singleWriteRequest(after: "reservation-secret-bytes")
        let reservation = try await fixture.probe.reserveWithoutAdmission(request)
        let record = fixture.base.appendingPathComponent("state/reservations/\(reservation.id).enc.json")
        let diskBytes = try Data(contentsOf: record)
        XCTAssertNotNil(String(data: diskBytes, encoding: .utf8)?.range(of: "reservation-secret-bytes"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: diskBytes) as? [String: Any])
        XCTAssertNil(object["ciphertext"])
        XCTAssertNotNil(object["request"])
        let decrypted = try await fixture.probe.decryptRequest(reservation)
        XCTAssertEqual(decrypted, request)
        let quota = fixture.base.appendingPathComponent("state/reservations/quota-\(reservation.id).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: quota.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.appendingPathComponent("state/reservations/\(reservation.id).quota").path))
    }

    func testMissingStateSnapshotWithExistingNamespaceFailsClosed() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.base.appendingPathComponent("state/apply-change-set-state.enc.json"))
        XCTAssertThrowsError(try fixture.freshService()) { error in
            XCTAssertEqual((error as? ApplyChangeSetError)?.code, .changeSetStoreCorrupt)
        }
    }

    func testWritePreservesModeAndExtendedAttributes() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let target = fixture.root.appendingPathComponent("one.txt")
        chmod(target.path, 0o600)
        let name = "dev.kitepon.aishell.test"
        let attribute = Data("metadata".utf8)
        let setResult = attribute.withUnsafeBytes { setxattr(target.path, name, $0.baseAddress, $0.count, 0, 0) }
        XCTAssertEqual(setResult, 0)
        _ = try await fixture.service.apply(try await fixture.singleWriteRequest(after: "metadata-after"))
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let length = getxattr(target.path, name, nil, 0, 0, 0)
        XCTAssertEqual(length, attribute.count)
        var restored = Data(count: max(0, length))
        let read = restored.withUnsafeMutableBytes { getxattr(target.path, name, $0.baseAddress, $0.count, 0, 0) }
        XCTAssertEqual(read, attribute.count)
        XCTAssertEqual(restored, attribute)
    }

    private static func sha(_ data: Data) -> String {
        // 公開requestのtest helper。production canonical digestとは独立に入力SHAだけを計算する。
        importSHA256(data)
    }
}

private struct Fixture {
    let base: URL
    let root: URL
    let service: ApplyChangeSetService
    let faults: ApplyChangeSetFailureInjector
    let client: ApplyChangeSetClient
    let runtime: RuntimeStore
    let evidence: EvidenceStore
    let workspace: WorkspaceStateRuntime
    let clock: ApplyChangeSetTestClock
    let probe: ApplyChangeSetTestProbe

    static func make(quotaOwner: ChangeSetQuotaLedger.OwnerBinding? = nil) async throws -> Self {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("change-set-focused-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runtime = RuntimeStore(baseDirectory: base.appendingPathComponent("runtime", isDirectory: true))
        await runtime.setWorkingDirectoryForTesting(root)
        let clock = ApplyChangeSetTestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let probe = try ApplyChangeSetTestProbe(baseDirectory: base, disabledCapabilities: [], clock: clock)
        let faults = ApplyChangeSetFailureInjector()
        let service = try ApplyChangeSetService(
            runtimeStore: runtime,
            stateDirectory: base.appendingPathComponent("state", isDirectory: true),
            evidenceStore: probe.evidenceStore,
            stateStore: probe.stateStore,
            workspaceRuntime: probe.workspaceRuntime,
            failureInjector: faults,
            clock: clock,
            quotaOwner: quotaOwner
        )
        try await service.bootstrap(root: root)
        let client = try await probe.allocateClients(count: 1, service: service)[0]
        return .init(base: base, root: root, service: service, faults: faults, client: client, runtime: runtime, evidence: probe.evidenceStore, workspace: probe.workspaceRuntime, clock: clock, probe: probe)
    }

    func freshService(failureInjector: ApplyChangeSetFailureInjector = ApplyChangeSetFailureInjector()) throws -> ApplyChangeSetService {
        let secrets = try ApplyChangeSetStateStore(baseDirectory: base, stateDirectory: base.appendingPathComponent("state", isDirectory: true), root: root)
        return try ApplyChangeSetService(runtimeStore: runtime, stateDirectory: base.appendingPathComponent("state", isDirectory: true), evidenceStore: evidence, stateStore: secrets, workspaceRuntime: workspace, failureInjector: failureInjector, clock: clock)
    }
    func singleWriteRequest(after: String) async throws -> ApplyChangeSetRequest {
        let before = try Data(contentsOf: root.appendingPathComponent("one.txt"))
        return .init(clientID: client.clientID, clientEpoch: client.epoch, requestSequence: 1,
                     cursor: try await service.currentCursor(root: root),
                     changes: [.write(id: "one", path: "one.txt", expected: .file(importSHA256(before)), content: .utf8(after))],
                     diffByteBudget: 65_536, retentionSeconds: 3_600)
    }

    func cleanup() {

        try? FileManager.default.removeItem(at: base)
    }
}

private func importSHA256(_ data: Data) -> String {
    // CryptoKitをtest surfaceへ限定する。
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
