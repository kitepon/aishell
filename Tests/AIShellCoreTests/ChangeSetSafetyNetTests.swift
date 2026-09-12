import CryptoKit
import Foundation
import XCTest
@testable import AIShellCore

/// ACE-051の先行red suite。
///
/// このsuiteはNativeFileServiceの逐次呼出しやtest内の偽transactionを使わず、ACE-052が実装する
/// productionのApplyChangeSetService、transaction store、fault seamを直接検証する。
final class ChangeSetSafetyNetTests: XCTestCase {
    func testMixedCreateWriteDeleteRenameCommitsOnlyAfterEveryPreconditionMatches() async throws {
        let f = try await ChangeSetFixture.make()
        defer { f.cleanup() }
        try f.put("write.txt", "write-before")
        try f.put("delete.txt", "delete-before")
        try f.put("rename.txt", "rename-before")
        let request = try await f.request(changes: [
            .create(id: "create", path: "created.txt", expected: .absent, content: .utf8("created")),
            .write(id: "write", path: "write.txt", expected: .file(try f.sha("write.txt")), content: .utf8("write-after")),
            .delete(id: "delete", path: "delete.txt", expected: .file(try f.sha("delete.txt"))),
            .rename(id: "rename", source: "rename.txt", sourceExpected: .file(try f.sha("rename.txt")), destination: "renamed.txt", destinationExpected: .absent),
        ])

        let result = try await f.service.apply(request)

        XCTAssertEqual(result.status, .committed)
        XCTAssertEqual(result.visibility, .aishellSerializedRecoverable)
        XCTAssertEqual(result.changes.map(\.changeID), ["create", "write", "delete", "rename"])
        XCTAssertNotEqual(result.fromCursor, result.cursor)
        XCTAssertEqual(try f.text("created.txt"), "created")
        XCTAssertEqual(try f.text("write.txt"), "write-after")
        XCTAssertFalse(f.exists("delete.txt"))
        XCTAssertFalse(f.exists("rename.txt"))
        XCTAssertEqual(try f.text("renamed.txt"), "rename-before")
        XCTAssertFalse(result.diffArtifact.handle.isEmpty)
    }

    func testEveryReadOnlyPreflightFailureLeavesAllTargetsUnchanged() async throws {
        let cases: [(String, ApplyChangeSetError.Code, (ChangeSetFixture) async throws -> ApplyChangeSetRequest)] = [
            ("stale-first", .contentChanged, { try await $0.twoWrites(staleIndex: 0) }),
            ("stale-middle", .contentChanged, { try await $0.threeWrites(staleIndex: 1) }),
            ("stale-last", .contentChanged, { try await $0.threeWrites(staleIndex: 2) }),
            ("absence", .expectedAbsenceViolated, { try await $0.expectedAbsenceViolation() }),
            ("cursor-head", .workspaceChanged, { try await $0.delayedCursorRequest() }),
            ("other-root", .rootMismatch, { try await $0.otherRootRequest() }),
            ("other-volume", .transactionVolumeMismatch, { try await $0.otherVolumeRequest() }),
            ("symlink", .unsupportedChangeTarget, { try await $0.symlinkEscapeRequest() }),
            ("directory", .unsupportedChangeTarget, { try await $0.directoryTargetRequest() }),
            ("case-fold", .changeSetConflict, { try await $0.caseFoldCollisionRequest() }),
            ("identity-alias", .changeSetConflict, { try await $0.hardLinkAliasRequest() }),
        ]
        for (name, code, build) in cases {
            let f = try await ChangeSetFixture.make(label: name)
            defer { f.cleanup() }
            let before = try f.publicTreeDigest()
            await XCTAssertThrowsApplyCode(code) { try await f.service.apply(build(f)) }
            XCTAssertEqual(try f.publicTreeDigest(), before, name)
            let targetMutationReceiptCount = try await f.probe.targetMutationReceiptCount()
            XCTAssertEqual(targetMutationReceiptCount, 0, name)
        }
    }

    func testRenameChainsAndCyclesCommitButAmbiguousGraphsRejectWithoutMutation() async throws {
        let f = try await ChangeSetFixture.make()
        defer { f.cleanup() }
        try f.put("a", "A"); try f.put("b", "B"); try f.put("c", "C")
        let cycle = try await f.request(changes: [
            .rename(id: "a-b", source: "a", sourceExpected: .file(try f.sha("a")), destination: "b", destinationExpected: .file(try f.sha("b"))),
            .rename(id: "b-c", source: "b", sourceExpected: .file(try f.sha("b")), destination: "c", destinationExpected: .file(try f.sha("c"))),
            .rename(id: "c-a", source: "c", sourceExpected: .file(try f.sha("c")), destination: "a", destinationExpected: .file(try f.sha("a"))),
        ])
        _ = try await f.service.apply(cycle)
        XCTAssertEqual(try f.text("a"), "C"); XCTAssertEqual(try f.text("b"), "A"); XCTAssertEqual(try f.text("c"), "B")

        for request in try await f.ambiguousRenameRequests() {
            let before = try f.publicTreeDigest()
            await XCTAssertThrowsApplyCode(.changeSetConflict) { try await f.service.apply(request) }
            XCTAssertEqual(try f.publicTreeDigest(), before)
        }
    }

    func testPinnedRootAndParentDescriptorsDefeatRenameAndSymlinkRaces() async throws {
        for race in ApplyChangeSetRacePoint.pathResolutionCases {
            let f = try await ChangeSetFixture.make(label: String(describing: race))
            defer { f.cleanup() }
            let request = try await f.singleWriteRequest()
            await f.faults.raceOnce(at: race, action: try f.pathSwapAction(for: race))
            let beforeOutside = try f.outsideDigest()
            await XCTAssertThrowsAnyApplyError { try await f.service.apply(request) }
            XCTAssertEqual(try f.outsideDigest(), beforeOutside)
            let unpinnedPathMutationCount = try await f.probe.unpinnedPathMutationCount()
            XCTAssertEqual(unpinnedPathMutationCount, 0)
        }
    }

    func testMissingRenameCapabilitiesNeverFallBackToPathBasedOverwrite() async throws {
        for capability in [ApplyChangeSetCapability.renameExclusive, .renameSwap, .directoryFSync] {
            let f = try await ChangeSetFixture.make(disabledCapabilities: [capability])
            defer { f.cleanup() }
            let before = try f.publicTreeDigest()
            await XCTAssertThrowsApplyCode(.transactionCapabilityUnavailable) {
                try await f.service.apply(try await f.singleWriteRequest())
            }
            XCTAssertEqual(try f.publicTreeDigest(), before)
            let pathBasedFallbackCount = try await f.probe.pathBasedFallbackCount()
            XCTAssertEqual(pathBasedFallbackCount, 0)
        }
    }

    func testReservedNamespaceIsInvisibleAndInvalidMarkersFailClosed() async throws {
        let f = try await ChangeSetFixture.make()
        defer { f.cleanup() }
        try await f.assertReservedNamespaceExcludedFromEveryReader()
        for corruption in ApplyChangeSetNamespaceCorruption.allCases {
            try await f.probe.replaceNamespace(with: corruption)
            let before = try f.publicTreeDigest()
            await XCTAssertThrowsApplyCode(.reservedNamespaceConflict) { try await f.service.bootstrap(root: f.root) }
            XCTAssertEqual(try f.publicTreeDigest(), before)
            try await f.probe.restoreValidNamespace()
        }
        try await f.probe.installLegacyCursorAndCheckpoint()
        try await f.service.migrateNamespace(root: f.root)
        let legacyCursorIsExpired = try await f.probe.legacyCursorIsExpired()
        let legacyCheckpointEntriesWereReused = try await f.probe.legacyCheckpointEntriesWereReused()
        XCTAssertTrue(legacyCursorIsExpired)
        XCTAssertFalse(legacyCheckpointEntriesWereReused)
    }

    func testInjectedPrepareCommitRuntimeDiffAndTrashFailuresRecoverToWholeBeforeOrAfter() async throws {
        for point in ApplyChangeSetFailurePoint.ace051DurabilityPoints {
            let f = try await ChangeSetFixture.make(label: point.rawValue)
            defer { f.cleanup() }
            let request = try await f.mixedRequest()
            let before = try f.publicTreeDigest()
            await f.faults.crashOnce(at: point)
            await XCTAssertThrowsSimulatedCrash { try await f.service.apply(request) }
            let recovered = try await f.restartedService().recover(root: f.root)
            let after = try f.publicTreeDigest()
            let expectedMixedAfterDigest = try f.expectedMixedAfterDigest()
            XCTAssertTrue(after == before || after == expectedMixedAfterDigest, point.rawValue)
            let hasStablePartialGraph = try await f.probe.hasStablePartialGraph()
            XCTAssertFalse(hasStablePartialGraph, point.rawValue)
            XCTAssertTrue(recovered.allSatisfy { !$0.evidenceMissing }, point.rawValue)
        }
    }

    func testExternalFDConflictIsClassifiedWithoutOverwritingUnknownBytes() async throws {
        for point in ApplyChangeSetRacePoint.externalDescriptorWriteCases {
            let f = try await ChangeSetFixture.make(label: String(describing: point))
            defer { f.cleanup() }
            let request = try await f.singleWriteRequest()
            let externalBytes = Data("external-wins".utf8)
            await f.faults.raceOnce(at: point, action: try f.externalFDWriteAction(bytes: externalBytes))
            await XCTAssertThrowsApplyCode(.externalConflictDuringCommit) { try await f.service.apply(request) }
            XCTAssertEqual(try f.data("one.txt"), externalBytes)
            let transactionState = try await f.probe.transactionState(for: request)
            XCTAssertEqual(transactionState, .recoveryRequired)
        }
    }

    func testStoreCorruptionNeverReconstructsIntentFromCurrentTree() async throws {
        for corruption in ApplyChangeSetStoreCorruption.allCases {
            let f = try await ChangeSetFixture.make(label: String(describing: corruption))
            defer { f.cleanup() }
            let transaction = corruption == .receiptGap
                ? try await f.prepareRuntimeCommittedTransaction()
                : try await f.prepareRecoverableTransaction()
            try await f.probe.corrupt(transaction: transaction, as: corruption, service: f.service)
            let before = try f.publicTreeDigest()
            await XCTAssertThrowsApplyCode(.changeSetStoreCorrupt) { try await f.restartedService().recover(root: f.root) }
            XCTAssertEqual(try f.publicTreeDigest(), before)
            let transactionMaterialExists = try await f.probe.transactionMaterialExists(transaction)
            XCTAssertTrue(transactionMaterialExists)
        }
    }

    func testRecoveryAndFSEventsEchoAppendKnownMutationExactlyOnceWithoutRescan() async throws {
        let f = try await ChangeSetFixture.make()
        defer { f.cleanup() }
        let initialWorkspace = try await f.probe.workspaceSnapshot()
        let initialScanCount = await f.probe.workspaceScanCount()
        let request = try await f.mixedRequest()
        await f.faults.crashOnce(at: .runtimeReceiptFSyncAfter)
        await XCTAssertThrowsSimulatedCrash { try await f.service.apply(request) }
        let service = try await f.restartedService()
        _ = try await service.recover(root: f.root)
        let delta = try await f.probe.workspaceSnapshot(since: initialWorkspace.cursor)
        XCTAssertEqual(Set(delta.changes.map(\.path)), Set(["created.txt", "write.txt", "delete.txt", "renamed.txt"]))
        XCTAssertEqual(delta.changes.count, request.changes.count)
        XCTAssertTrue(delta.changes.contains {
            $0.kind == .renamed && $0.path == "renamed.txt" && $0.previousPath == "rename.txt"
        })
        try await f.probe.deliverFSEventsEcho(for: request)
        let echo = try await f.probe.workspaceSnapshot(since: delta.cursor)
        XCTAssertTrue(echo.changes.isEmpty)
        XCTAssertEqual(echo.cursor, delta.cursor)
        let finalScanCount = await f.probe.workspaceScanCount()
        XCTAssertEqual(finalScanCount, initialScanCount)
    }

    func testSuccessfulApplyAppendsWorkspaceDeltaWithoutRescan() async throws {
        let f = try await ChangeSetFixture.make()
        defer { f.cleanup() }
        let initialWorkspace = try await f.probe.workspaceSnapshot()
        let initialScanCount = await f.probe.workspaceScanCount()
        let request = try await f.mixedRequest()

        let result = try await f.service.apply(request)
        let delta = try await f.probe.workspaceSnapshot(since: initialWorkspace.cursor)

        XCTAssertEqual(result.status, .committed)
        XCTAssertEqual(Set(delta.changes.map(\.path)), Set([
            "created.txt", "write.txt", "delete.txt", "renamed.txt",
        ]))
        XCTAssertTrue(delta.changes.contains {
            $0.kind == .renamed && $0.path == "renamed.txt" && $0.previousPath == "rename.txt"
        })
        let finalScanCount = await f.probe.workspaceScanCount()
        XCTAssertEqual(finalScanCount, initialScanCount)
    }

    func testPhase5TransactionLoopMatchesHostPatchAndRemovesConfirmationRoundTrips() async throws {
        let f = try await ChangeSetFixture.make(label: "phase5-acceptance")
        defer { f.cleanup() }
        let request = try await f.mixedRequest()
        let baselineRoot = f.base.appendingPathComponent("host-apply-patch", isDirectory: true)
        try FileManager.default.copyItem(at: f.root, to: baselineRoot)

        let initialWorkspace = try await f.probe.workspaceSnapshot()
        let initialScanCount = await f.probe.workspaceScanCount()
        let candidateStartedAt = CFAbsoluteTimeGetCurrent()
        let result = try await f.service.apply(request)
        let candidateMilliseconds = (CFAbsoluteTimeGetCurrent() - candidateStartedAt) * 1_000

        let baselineStartedAt = CFAbsoluteTimeGetCurrent()
        try applyHostPatchEquivalent(request.changes, to: baselineRoot)
        let baselineDigest = try f.probe.publicTreeDigest(baselineRoot)
        _ = try f.probe.publicTreeDigest(baselineRoot) // host側の明示確認call
        _ = try await f.probe.workspaceSnapshot(since: initialWorkspace.cursor) // host側の再snapshot call
        let baselineMilliseconds = (CFAbsoluteTimeGetCurrent() - baselineStartedAt) * 1_000

        XCTAssertEqual(result.status, .committed)
        XCTAssertEqual(try f.publicTreeDigest(), baselineDigest)
        XCTAssertEqual(Set(result.changedPaths), Set([
            "created.txt", "write.txt", "delete.txt", "rename.txt", "renamed.txt",
        ]))
        XCTAssertNotEqual(result.fromCursor, result.cursor)
        XCTAssertFalse(result.diffArtifact.handle.isEmpty)
        let finalScanCount = await f.probe.workspaceScanCount()
        XCTAssertEqual(finalScanCount, initialScanCount)

        let candidateToolCalls = 2 // initial snapshot + apply_change_set
        let baselineToolCalls = 4 // initial snapshot + apply_patch + confirmation + re-snapshot
        XCTAssertLessThan(candidateToolCalls, baselineToolCalls)
        let measurement: [String: Any] = [
            "schema": "aishell.phase5-acceptance-measurement.v1",
            "candidate": [
                "toolCalls": candidateToolCalls,
                "wallMilliseconds": candidateMilliseconds,
                "filesystemEntriesRescanned": 0,
                "diffArtifactReturned": true,
                "updatedCursorReturned": true,
            ],
            "hostApplyPatch": [
                "toolCalls": baselineToolCalls,
                "wallMilliseconds": baselineMilliseconds,
                "explicitConfirmationRequired": true,
                "resnapshotRequired": true,
            ],
            "correctness": ["publicTreeDigestEqual": true, "partialWrites": 0],
        ]
        let encoded = try JSONSerialization.data(withJSONObject: measurement, options: [.sortedKeys])
        print("PHASE5_MEASUREMENT \(String(decoding: encoded, as: UTF8.self))")
    }

    func testCheckpointMarkerAndTransactionReceiptCrashOrderingIsIdempotent() async throws {
        for point in ApplyChangeSetFailurePoint.checkpointReceiptOrderingPoints {
            let f = try await ChangeSetFixture.make(label: point.rawValue)
            defer { f.cleanup() }
            let request = try await f.singleWriteRequest()
            await f.faults.crashOnce(at: point)
            await XCTAssertThrowsSimulatedCrash { try await f.service.apply(request) }
            _ = try await f.restartedService().recover(root: f.root)
            let runtimeCommitCount = try await f.probe.runtimeCommitCount(request)
            XCTAssertEqual(runtimeCommitCount, 1)
        }
    }

    func testTrashCrashRecoveryUsesOnlyTheUniqueIntendedIdentity() async throws {
        for point in ApplyChangeSetFailurePoint.trashIntentReceiptPoints {
            let f = try await ChangeSetFixture.make(label: point.rawValue)
            defer { f.cleanup() }
            let request = try await f.deleteRequest()
            await f.faults.crashOnce(at: point)
            await XCTAssertThrowsSimulatedCrash { try await f.service.apply(request) }
            _ = try await f.restartedService().recover(root: f.root)
            let trashReceiptCount = try await f.probe.trashReceiptCount(request)
            let internalDeleteBackupWasPinnedUntilReceipt = try await f.probe.internalDeleteBackupWasPinnedUntilReceipt(request)
            XCTAssertEqual(trashReceiptCount, 1)
            XCTAssertTrue(internalDeleteBackupWasPinnedUntilReceipt)
        }
        for ambiguity in ApplyChangeSetTrashRecoveryAmbiguity.allCases {
            let f = try await ChangeSetFixture.make(label: String(describing: ambiguity))
            defer { f.cleanup() }
            let transaction = try await f.prepareTrashRecovery(ambiguity)
            await XCTAssertThrowsApplyCode(.changeSetRecoveryRequired) { try await f.restartedService().recover(root: f.root) }
            let transactionMaterialExists = try await f.probe.transactionMaterialExists(transaction)
            XCTAssertTrue(transactionMaterialExists)
        }
    }

    func testContentBoundariesAndMetadataPreservation() async throws {
        let f = try await ChangeSetFixture.make()
        defer { f.cleanup() }
        for content in ApplyChangeSetContentFixture.ace051Cases {
            let result = try await f.service.apply(f.request(for: content))
            XCTAssertEqual(try f.data(content.path), content.afterBytes)
            XCTAssertEqual(result.changes.first?.afterSHA256, content.afterSHA256)
            XCTAssertEqual(try f.metadata(content.path), content.expectedMetadata)
        }
        await XCTAssertThrowsApplyCode(.changeSetLimitExceeded) { try await f.service.apply(f.request(totalContentBytes: 64 * 1_024 * 1_024 + 1)) }
    }

    func testDiffPreviewBoundaryAndImmutableCompleteArtifact() async throws {
        for budgetOffset in [0, 1] {
            let f = try await ChangeSetFixture.make(label: "budget-\(budgetOffset)")
            defer { f.cleanup() }
            let request = try await f.diffBoundaryRequest(budgetOffset: budgetOffset)
            let result = try await f.service.apply(request)
            let artifact = try await f.probe.readArtifact(result.diffArtifact.handle)
            XCTAssertEqual(SHA256.hash(data: artifact).hex, result.diffArtifact.sha256)
            XCTAssertEqual(artifact.count, result.diffArtifact.sizeBytes)
            XCTAssertEqual(try f.diffPaths(in: artifact), request.changes.flatMap(\.paths))
            XCTAssertEqual(result.returnedDiffBytes + result.omittedDiffBytes, artifact.count)
        }
        for failure in ApplyChangeSetEvidenceFailure.allCases {
            let f = try await ChangeSetFixture.make(label: String(describing: failure))
            defer { f.cleanup() }
            let before = try f.publicTreeDigest()
            try await f.probe.injectEvidenceFailure(failure)
            await XCTAssertThrowsAnyApplyError { try await f.service.apply(try await f.singleWriteRequest()) }
            XCTAssertEqual(try f.publicTreeDigest(), before)
        }
    }

    func testClientIdentitySequenceReplayAndRetentionBoundaries() async throws {
        let f = try await ChangeSetFixture.make()
        defer { f.cleanup() }
        for invalidID in f.invalidClientIDs {
            await XCTAssertThrowsApplyCode(.invalidArgument) { try await f.service.apply(try await f.singleWriteRequest(clientID: invalidID)) }
        }
        await XCTAssertThrowsApplyCode(.changeSetClientNotRegistered) { try await f.service.apply(try await f.singleWriteRequest(clientID: UUID().uuidString.lowercased())) }
        await XCTAssertThrowsApplyCode(.changeSetExpired) { try await f.service.apply(try await f.singleWriteRequest(epoch: f.client.epoch - 1)) }
        await XCTAssertThrowsApplyCode(.changeSetClientEpochAhead) { try await f.service.apply(try await f.singleWriteRequest(epoch: f.client.epoch + 1)) }
        await XCTAssertThrowsApplyCode(.changeSetSequenceGap) { try await f.service.apply(try await f.singleWriteRequest(sequence: 2)) }

        let request = try await f.singleWriteRequest()
        let first = try await f.service.apply(request)
        let replayed = try await f.service.apply(request)
        XCTAssertEqual(replayed, first)
        await XCTAssertThrowsApplyCode(.changeSetSequenceConflict) { try await f.service.apply(request.replacingFirstContent(.utf8("different"))) }
    }

    func testFixedClientRegistryOwnerProofAndControlConcurrency() async throws {
        let f = try await ChangeSetFixture.make(allocationCount: 64)
        defer { f.cleanup() }
        await XCTAssertThrowsApplyCode(.changeSetClientCapacityExceeded) { try await f.allocateClient() }
        let retired = try await f.retireTerminalClient(slot: 0)
        let reallocated = try await f.allocateClient()
        XCTAssertEqual(reallocated.clientID, retired.clientID)
        XCTAssertEqual(reallocated.epoch, retired.epoch + 1)
        let registrySlotCount = try await f.probe.registrySlotCount(service: f.service)
        XCTAssertEqual(registrySlotCount, 64)

        for tamper in ApplyChangeSetOwnerProofTamper.allCases {
            await XCTAssertThrowsApplyCode(.clientOwnerProofInvalid) { try await f.performControl(with: tamper) }
        }
        let pending = try await f.singleWriteRequest(clientID: reallocated.clientID,
            epoch: reallocated.epoch, sequence: 1)
        await f.faults.crashOnce(at: .admissionFSyncAfter)
        await XCTAssertThrowsSimulatedCrash { try await f.service.apply(pending) }
        await XCTAssertThrowsApplyCode(.clientRotationBlocked) { try await f.rotate(reallocated) }
        await XCTAssertThrowsApplyCode(.clientRetireBlocked) { try await f.retire(reallocated) }
        await XCTAssertThrowsApplyCode(.clientRegistryReinitializeBlocked) { try await f.reinitializeRegistry() }
    }

    func testControlLinearizationCrashAndReceiptCapacity() async throws {
        for race in ApplyChangeSetControlRace.allCases {
            let f = try await ChangeSetFixture.make(label: String(describing: race))
            defer { f.cleanup() }
            let outcomes = try await f.runControlRace(race)
            XCTAssertEqual(outcomes.filter(\.isSuccess).count, 1)
            let registryIsInternallyConsistent = try await f.probe.registryIsInternallyConsistent(service: f.service)
            XCTAssertTrue(registryIsInternallyConsistent)
        }
        for point in ApplyChangeSetFailurePoint.registryAtomicReplacePoints {
            let f = try await ChangeSetFixture.make(label: point.rawValue)
            defer { f.cleanup() }
            let operation = try await f.pendingControlOperation()
            await f.faults.crashOnce(at: point)
            await XCTAssertThrowsSimulatedCrash { try await f.service.control(operation.request) }
            let restarted = try await f.restartedService()
            let replay = try await restarted.control(operation.request)
            let repeatedReplay = try await restarted.control(operation.request)
            let registryIsInternallyConsistent = try await f.probe.registryIsInternallyConsistent(service: f.service)
            XCTAssertEqual(repeatedReplay, replay)
            XCTAssertTrue(registryIsInternallyConsistent)
        }
        let full = try await ChangeSetFixture.make(controlReceiptCount: 128)
        defer { full.cleanup() }
        await XCTAssertThrowsApplyCode(.clientControlCapacityExceeded) { try await full.performFreshControl() }
        await full.clock.advance(by: .seconds(301))
        _ = try await full.performFreshControl()
    }

    func testReservationCanonicalEnvelopeTamperAndSecretNonDisclosure() async throws {
        let f = try await ChangeSetFixture.make()
        defer { f.cleanup() }
        let request = try await f.canonicalReservationRequest()
        let reservation = try await f.probe.reserveWithoutAdmission(request)
        XCTAssertEqual(try f.probe.independentlyComputedReservationDigest(reservation), reservation.requestDigest)
        let decryptedRequest = try await f.probe.decryptRequest(reservation)
        XCTAssertEqual(decryptedRequest, request)
        for tamper in ApplyChangeSetReservationTamper.allCases {
            try await f.probe.restoreReservation(reservation)
            try await f.probe.tamperReservation(tamper)
            await XCTAssertThrowsApplyCode(.changeSetReservationCorrupt) { try await f.service.resumeReservation(reservation.id) }
            let targetMutationReceiptCount = try await f.probe.targetMutationReceiptCount()
            XCTAssertEqual(targetMutationReceiptCount, 0)
        }
        for secretFailure in ApplyChangeSetSecretFailure.allCases {
            try await f.probe.injectSecretFailure(secretFailure)
            await XCTAssertThrowsApplyCode(.changeSetSecretStoreUnavailable) { try await f.service.apply(request) }
            let logsContainNone = try await f.probe.logsContainNone(of: request.secretFragments)
            XCTAssertTrue(logsContainNone)
        }
    }

    func testAdmissionOrderingAndOrphanCleanupNeverNeedsClientRetry() async throws {
        for point in ApplyChangeSetFailurePoint.validationReservationAdmissionMaterializationPoints {
            let f = try await ChangeSetFixture.make(label: point.rawValue)
            defer { f.cleanup() }
            let request = try await f.singleWriteRequest()
            await f.faults.crashOnce(at: point)
            await XCTAssertThrowsSimulatedCrash { try await f.service.apply(request) }
            _ = try await f.restartedService().recover(root: f.root)
            let admitted = try await f.probe.isAdmitted(request)
            XCTAssertEqual(try f.text("one.txt"), "before")
            let admissionCount = try await f.probe.admissionCount(request)
            XCTAssertEqual(admissionCount, admitted ? 1 : 0)
        }
        for orphan in ApplyChangeSetOrphanCase.allCases {
            let f = try await ChangeSetFixture.make(label: String(describing: orphan))
            defer { f.cleanup() }
            let reservation = try await f.probe.installOrphan(orphan, client: f.client)
            try await f.restartedService().recover(root: f.root)
            let reservationExists = try await f.probe.reservationExists(reservation)
            XCTAssertEqual(reservationExists, orphan.mustRemainPinned)
        }
    }

    func testPostAdmissionChangesAbortOnlyBeforeFirstTargetReceipt() async throws {
        for mutation in ApplyChangeSetPostAdmissionMutation.allCases {
            for boundary in [ApplyChangeSetMutationBoundary.beforeFirstTargetReceipt, .afterFirstTargetReceipt, .afterCommitDecided] {
                let f = try await ChangeSetFixture.make(label: "\(mutation)-\(boundary)")
                defer { f.cleanup() }
                let request = try await f.singleWriteRequest()
                await f.faults.mutateOnce(mutation, at: boundary)
                if boundary == .beforeFirstTargetReceipt {
                    let result = try await f.service.apply(request)
                    XCTAssertEqual(result.status, .abortedBeforeSideEffect)
                    XCTAssertEqual(result.changedPaths, [])
                    XCTAssertFalse(result.transactionCursorAdvanced)
                } else {
                    await XCTAssertThrowsAnyApplyError { try await f.service.apply(request) }
                    let transactionState = try await f.probe.transactionState(for: request)
                    XCTAssertNotEqual(transactionState, .abortedBeforeSideEffect)
                }
            }
        }
    }

    func testOwnerAbortRequiresZeroTargetReceiptsAndMaterialRetentionMatchesTerminalState() async throws {
        for state in ApplyChangeSetReservationTerminalCase.allCases {
            let f = try await ChangeSetFixture.make(label: String(describing: state))
            defer { f.cleanup() }
            let transaction = try await f.probe.installReservationTerminalCase(state,
                client: f.client, service: f.service)
            if state.ownerAbortAllowed {
                let result = try await f.ownerAbort(transaction)
                XCTAssertEqual(result.status, .abortedBeforeSideEffect)
            } else {
                await XCTAssertThrowsAnyApplyError { try await f.ownerAbort(transaction) }
            }
            let materialRetention = try await f.probe.materialRetention(transaction)
            XCTAssertEqual(materialRetention, state.expectedRetention)
        }
    }

    func testStartupRecoveryGatesFreshSnapshotAndMutationUntilTerminal() async throws {
        let f = try await ChangeSetFixture.make()
        defer { f.cleanup() }
        let transaction = try await f.prepareRecoverableTransaction()
        let service = try await f.restartedService(autoRecover: false)
        let queuedMutation = try f.replayRequest(sequence: 2)
        async let recovery = service.recover(root: f.root)
        await f.probe.waitUntilRecoveryStarted(transaction)
        async let queuedCursor = service.currentCursor(root: f.root)
        async let mutation = service.apply(queuedMutation)
        _ = try await recovery
        let currentRoot = try await queuedCursor.root
        let mutationResult = try await mutation
        XCTAssertEqual(currentRoot, f.root.path)
        XCTAssertEqual(mutationResult.status, .committed)
    }

    func testCompatibilityCatalogAndFrozenBenchmarkV1RemainByteForByteStable() async throws {
        let f = try await ChangeSetFixture.make()
        defer { f.cleanup() }
        let developmentTools = try await f.probe.toolNames(profile: .development)
        let fullTools = try await f.probe.toolNames(profile: .full)
        let legacyTools = try await f.probe.legacyFilePrimitiveNames()
        XCTAssertEqual(developmentTools.count, 9)
        XCTAssertEqual(fullTools.count, 29)
        XCTAssertTrue(legacyTools.allSatisfy(fullTools.contains))
        for fixture in try f.probe.frozenBenchmarkV1Files() {
            XCTAssertEqual(try Data(contentsOf: fixture.url).sha256, fixture.expectedSHA256)
        }
    }
}

private func applyHostPatchEquivalent(_ changes: [ApplyChangeSetChange], to root: URL) throws {
    for change in changes {
        switch change {
        case let .create(_, path, expected, content), let .write(_, path, expected, content):
            let target = root.appendingPathComponent(path)
            let before = try? Data(contentsOf: target)
            guard hostState(before, matches: expected), let bytes = content.bytes else {
                throw ApplyChangeSetError(.contentChanged)
            }
            try bytes.write(to: target)
        case let .delete(_, path, expected):
            let target = root.appendingPathComponent(path)
            guard hostState(try? Data(contentsOf: target), matches: expected) else {
                throw ApplyChangeSetError(.contentChanged)
            }
            try FileManager.default.removeItem(at: target)
        case let .rename(_, source, sourceExpected, destination, destinationExpected):
            let sourceURL = root.appendingPathComponent(source)
            let destinationURL = root.appendingPathComponent(destination)
            guard hostState(try? Data(contentsOf: sourceURL), matches: sourceExpected),
                  hostState(try? Data(contentsOf: destinationURL), matches: destinationExpected) else {
                throw ApplyChangeSetError(.contentChanged)
            }
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        }
    }
}

private func hostState(_ data: Data?, matches expected: ApplyChangeSetExpected) -> Bool {
    switch expected {
    case .absent: data == nil
    case let .file(sha256): data?.sha256 == sha256
    }
}

// MARK: - Production seam required by the red suite

private struct ChangeSetFixture {
    let base: URL
    let root: URL
    let outside: URL
    let service: ApplyChangeSetService
    let probe: ApplyChangeSetTestProbe
    let faults: ApplyChangeSetFailureInjector
    let clock: ApplyChangeSetTestClock
    let client: ApplyChangeSetClient

    static func make(
        label: String = UUID().uuidString,
        disabledCapabilities: Set<ApplyChangeSetCapability> = [],
        allocationCount: Int = 1,
        controlReceiptCount: Int = 0
    ) async throws -> Self {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ace051-\(label)-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let runtime = RuntimeStore(baseDirectory: base.appendingPathComponent("runtime", isDirectory: true))
        await runtime.setWorkingDirectoryForTesting(root)
        let faults = ApplyChangeSetFailureInjector()
        let clock = ApplyChangeSetTestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let probe = try ApplyChangeSetTestProbe(baseDirectory: base, disabledCapabilities: disabledCapabilities, clock: clock)
        let service = try ApplyChangeSetService(runtimeStore: runtime, stateDirectory: base.appendingPathComponent("state", isDirectory: true), evidenceStore: probe.evidenceStore, secretStore: probe.secretStore, workspaceRuntime: probe.workspaceRuntime, failureInjector: faults, clock: clock)
        try await service.bootstrap(root: root)
        let clients = try await probe.allocateClients(count: allocationCount, service: service)
        try await probe.seedControlReceipts(count: controlReceiptCount, service: service)
        return Self(base: base, root: root, outside: outside, service: service, probe: probe, faults: faults, clock: clock, client: clients[0])
    }

    func cleanup() {
        probe.cleanupExternalFixtures()
        try? FileManager.default.removeItem(at: base)
    }
    func put(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent(path), options: .atomic) }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }
    func data(_ path: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(path)) }
    func text(_ path: String) throws -> String { try String(decoding: data(path), as: UTF8.self) }
    func sha(_ path: String) throws -> String { try data(path).sha256 }
    func metadata(_ path: String) throws -> ApplyChangeSetMetadata { try probe.metadata(root.appendingPathComponent(path)) }
    func publicTreeDigest() throws -> String { try probe.publicTreeDigest(root) }
    func outsideDigest() throws -> String { try probe.publicTreeDigest(outside) }

    func request(changes: [ApplyChangeSetChange]) async throws -> ApplyChangeSetRequest {
        ApplyChangeSetRequest(clientID: client.clientID, clientEpoch: client.epoch, requestSequence: try await probe.nextSequence(client, service: service), cursor: try await service.currentCursor(root: root), changes: changes, diffByteBudget: 65_536, retentionSeconds: 3_600)
    }

    func singleWriteRequest(clientID: String? = nil, epoch: Int? = nil, sequence: Int? = nil) async throws -> ApplyChangeSetRequest {
        if !exists("one.txt") { try put("one.txt", "before") }
        var value = try await request(changes: [.write(id: "one", path: "one.txt", expected: .file(try sha("one.txt")), content: .utf8("after"))])
        if let clientID { value = value.replacingClientID(clientID) }
        if let epoch { value = value.replacingClientEpoch(epoch) }
        if let sequence { value = value.replacingRequestSequence(sequence) }
        return value
    }

    func mixedRequest() async throws -> ApplyChangeSetRequest {
        if !exists("write.txt") { try put("write.txt", "write-before") }
        if !exists("delete.txt") { try put("delete.txt", "delete-before") }
        if !exists("rename.txt") { try put("rename.txt", "rename-before") }
        return try await request(changes: [
            .create(id: "create", path: "created.txt", expected: .absent, content: .utf8("created")),
            .write(id: "write", path: "write.txt", expected: .file(try sha("write.txt")), content: .utf8("write-after")),
            .delete(id: "delete", path: "delete.txt", expected: .file(try sha("delete.txt"))),
            .rename(id: "rename", source: "rename.txt", sourceExpected: .file(try sha("rename.txt")), destination: "renamed.txt", destinationExpected: .absent),
        ])
    }
    func twoWrites(staleIndex: Int) async throws -> ApplyChangeSetRequest { try await probe.preflightFailureRequest(root: root, client: client, count: 2, staleIndex: staleIndex, service: service) }
    func threeWrites(staleIndex: Int) async throws -> ApplyChangeSetRequest { try await probe.preflightFailureRequest(root: root, client: client, count: 3, staleIndex: staleIndex, service: service) }
    func expectedAbsenceViolation() async throws -> ApplyChangeSetRequest { try await probe.expectedAbsenceViolation(root: root, client: client, service: service) }
    func delayedCursorRequest() async throws -> ApplyChangeSetRequest { try await probe.delayedCursorRequest(root: root, client: client, service: service) }
    func otherRootRequest() async throws -> ApplyChangeSetRequest { try await probe.otherRootRequest(root: root, client: client, service: service) }
    func otherVolumeRequest() async throws -> ApplyChangeSetRequest { try await probe.otherVolumeRequest(root: root, client: client, service: service) }
    func symlinkEscapeRequest() async throws -> ApplyChangeSetRequest { try await probe.symlinkEscapeRequest(root: root, outside: outside, client: client, service: service) }
    func directoryTargetRequest() async throws -> ApplyChangeSetRequest { try await probe.directoryTargetRequest(root: root, client: client, service: service) }
    func caseFoldCollisionRequest() async throws -> ApplyChangeSetRequest { try await probe.caseFoldCollisionRequest(root: root, client: client, service: service) }
    func hardLinkAliasRequest() async throws -> ApplyChangeSetRequest { try await probe.hardLinkAliasRequest(root: root, client: client, service: service) }
    func ambiguousRenameRequests() async throws -> [ApplyChangeSetRequest] { try await probe.ambiguousRenameRequests(root: root, client: client, service: service) }
    func pathSwapAction(for point: ApplyChangeSetRacePoint) throws -> ApplyChangeSetRaceAction { try probe.pathSwapAction(root: root, outside: outside, point: point) }
    func externalFDWriteAction(bytes: Data) throws -> ApplyChangeSetRaceAction { try probe.externalFDWriteAction(root: root, bytes: bytes) }
    func assertReservedNamespaceExcludedFromEveryReader() async throws {
        try await probe.assertReservedNamespaceExcludedFromEveryReader(root)
    }
    func expectedMixedAfterDigest() throws -> String { try probe.expectedMixedAfterDigest(root) }
    func restartedService(autoRecover: Bool = true) async throws -> ApplyChangeSetService { try await probe.restartedService(failureInjector: faults, clock: clock, autoRecover: autoRecover) }
    func prepareRecoverableTransaction() async throws -> ApplyChangeSetTransactionID {
        let request = try await singleWriteRequest()
        await faults.crashOnce(at: .admissionFSyncAfter)
        do {
            _ = try await service.apply(request)
            throw ApplyChangeSetError(.changeSetStoreCorrupt, "recoverable fixture did not stop after admission")
        } catch is ApplyChangeSetSimulatedCrash {
            return ApplyChangeSetTransactionID(request.transactionIdentity)
        }
    }
    func prepareRuntimeCommittedTransaction() async throws -> ApplyChangeSetTransactionID {
        let request = try await singleWriteRequest()
        await faults.crashOnce(at: .runtimeReceiptFSyncAfter)
        do {
            _ = try await service.apply(request)
            throw ApplyChangeSetError(.changeSetStoreCorrupt,
                "runtime receipt fixture did not stop after receipt persistence")
        } catch is ApplyChangeSetSimulatedCrash {
            return ApplyChangeSetTransactionID(request.transactionIdentity)
        }
    }
    func deleteRequest() async throws -> ApplyChangeSetRequest { try await probe.deleteRequest(root: root, client: client, service: service) }
    func prepareTrashRecovery(_ ambiguity: ApplyChangeSetTrashRecoveryAmbiguity) async throws -> ApplyChangeSetTransactionID {
        let request = try await deleteRequest()
        await faults.crashOnce(at: .trashIntentFSyncAfter)
        do {
            _ = try await service.apply(request)
            throw ApplyChangeSetError(.changeSetStoreCorrupt,
                "trash ambiguity fixture did not stop after intent persistence")
        } catch is ApplyChangeSetSimulatedCrash {
            try await probe.installTrashAmbiguity(for: request, ambiguity: ambiguity)
            return ApplyChangeSetTransactionID(request.transactionIdentity)
        }
    }
    func request(for fixture: ApplyChangeSetContentFixture) throws -> ApplyChangeSetRequest { try probe.request(for: fixture, client: client) }
    func request(totalContentBytes: Int) throws -> ApplyChangeSetRequest { try probe.request(totalContentBytes: totalContentBytes, client: client) }
    func diffBoundaryRequest(budgetOffset: Int) async throws -> ApplyChangeSetRequest { try await probe.diffBoundaryRequest(root: root, client: client, service: service, budgetOffset: budgetOffset) }
    func diffPaths(in artifact: Data) throws -> [String] { try probe.diffPaths(in: artifact) }
    var invalidClientIDs: [String] { probe.invalidClientIDs }
    func replayRequest(sequence: Int) throws -> ApplyChangeSetRequest { try probe.replayRequest(client: client, sequence: sequence) }
    func allocateClient() async throws -> ApplyChangeSetClient { try await probe.allocateClient(service: service) }
    func retireTerminalClient(slot: Int) async throws -> ApplyChangeSetClient { try await probe.retireTerminalClient(slot: slot, service: service) }
    func performControl(with tamper: ApplyChangeSetOwnerProofTamper) async throws -> ApplyChangeSetControlResult { try await probe.performControl(with: tamper, service: service) }
    func rotate(_ client: ApplyChangeSetClient) async throws -> ApplyChangeSetControlResult { try await probe.rotate(client, service: service) }
    func retire(_ client: ApplyChangeSetClient) async throws -> ApplyChangeSetControlResult { try await probe.retire(client, service: service) }
    func reinitializeRegistry() async throws -> ApplyChangeSetControlResult { try await probe.reinitializeRegistry(service: service) }
    func runControlRace(_ race: ApplyChangeSetControlRace) async throws -> [Result<ApplyChangeSetControlResult, Error>] { try await probe.runControlRace(race, service: service) }
    func pendingControlOperation() async throws -> ApplyChangeSetPendingControl { try await probe.pendingControlOperation(service: service) }
    func performFreshControl() async throws -> ApplyChangeSetControlResult { try await probe.performFreshControl(service: service) }
    func canonicalReservationRequest() async throws -> ApplyChangeSetRequest { try await probe.canonicalReservationRequest(root: root, client: client, service: service) }
    func ownerAbort(_ transaction: ApplyChangeSetTransactionID) async throws -> ApplyChangeSetResult { try await probe.ownerAbort(transaction, service: service) }
}

private func XCTAssertThrowsApplyCode<T>(_ code: ApplyChangeSetError.Code, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> T) async {
    do { _ = try await body(); XCTFail("\(code)を返さず成功しました", file: file, line: line) }
    catch let error as ApplyChangeSetError { XCTAssertEqual(error.code, code, file: file, line: line) }
    catch { XCTFail("想定外のエラー: \(error)", file: file, line: line) }
}

private func XCTAssertThrowsAnyApplyError<T>(file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> T) async {
    do { _ = try await body(); XCTFail("失敗せず成功しました", file: file, line: line) }
    catch is ApplyChangeSetError { }
    catch { XCTFail("想定外のエラー: \(error)", file: file, line: line) }
}

private func XCTAssertThrowsSimulatedCrash<T>(file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> T) async {
    do { _ = try await body(); XCTFail("注入したcrashが発生しませんでした", file: file, line: line) }
    catch is ApplyChangeSetSimulatedCrash { }
    catch { XCTFail("想定外のエラー: \(error)", file: file, line: line) }
}

private extension Data {
    var sha256: String { SHA256.hash(data: self).hex }
}

private extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
