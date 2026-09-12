import CryptoKit
import XCTest
@testable import AIShellCore

final class ChangeSetCutoverCoordinatorTests: XCTestCase {
    func testStoredDateComparisonRejectsChangedExpiryAndMissingDates() {
        let expiry = Date(timeIntervalSinceReferenceDate: 810_000_000.1234568)
        XCTAssertFalse(ChangeSetCutoverCoordinator.sameStoredDate(expiry, expiry.addingTimeInterval(0.001)))
        XCTAssertFalse(ChangeSetCutoverCoordinator.sameStoredDate(expiry, nil))
        XCTAssertFalse(ChangeSetCutoverCoordinator.sameStoredDate(nil, expiry))
        XCTAssertTrue(ChangeSetCutoverCoordinator.sameStoredDate(nil, nil))
    }

    func testFractionalExpirySurvivesTransactionStoreEncodingAndRestart() async throws {
        let expiry = Date(timeIntervalSinceReferenceDate: 810_000_000.1234568)
        let fixture = try await CutoverFixture.makeLiveTerminal(retentionExpiresAt: expiry)
        defer { fixture.cleanup() }
        let compatibility = CutoverCompatibilityFixture()
        let coordinator = try fixture.coordinator(compatibility: compatibility)
        XCTAssertValidated(try await coordinator.run(fixture.source), sourceDigest: fixture.source.sourceDigest)
        let reopened = try fixture.coordinator(compatibility: compatibility)
        XCTAssertValidated(try await reopened.validateForPublication(), sourceDigest: fixture.source.sourceDigest)
    }

    func testEveryDurablePhaseCrashResumesExactSnapshotAndPublishesOnlyAfterCompleteMarker() async throws {
        let fixture = try await CutoverFixture.makeLiveTerminal()
        defer { fixture.cleanup() }
        let compatibility = CutoverCompatibilityFixture()
        let phases: [(ChangeSetCutoverCrashPoint, ChangeSetCutoverPhase?)] = [
            (.prepared, .prepared),
            (.compatibilityPrepared, .prepared),
            (.registryImported, .compatibilityPrepared),
            (.transactionsImported, .registryImported),
            (.crossValidated, .transactionsImported),
            (.completeMarker, nil),
        ]

        for (point, expectedPhase) in phases {
            let coordinator = try fixture.coordinator(compatibility: compatibility, crashAfter: point)
            do {
                _ = try await coordinator.run(fixture.source)
                XCTFail("expected simulated crash at \(point)")
            } catch let crash as ChangeSetCutoverSimulatedCrash {
                XCTAssertEqual(crash.point, point)
            }
            let observer = try fixture.coordinator(compatibility: compatibility)
            let status = try await observer.status()
            if let expectedPhase {
                XCTAssertEqual(status, .inProgress(phase: expectedPhase, sourceDigest: fixture.source.sourceDigest))
                XCTAssertFalse(status.permitsDedicatedStorePublication)
            } else {
                XCTAssertEqual(status, .complete(sourceDigest: fixture.source.sourceDigest))
                XCTAssertFalse(status.permitsDedicatedStorePublication)
            }
        }

        let restarted = try fixture.coordinator(compatibility: compatibility)
        let restartedResult = try await restarted.run(fixture.source)
        XCTAssertValidated(restartedResult, sourceDigest: fixture.source.sourceDigest)
        let counts = await compatibility.counts()
        XCTAssertEqual(counts.prepared, 1)
        XCTAssertEqual(counts.validated, 3)
        let receipts = try await fixture.transactionStore.runtimeReceipts()
        XCTAssertEqual(receipts, fixture.source.runtimeReceipts)
    }

    func testCompleteFastPathRemovesProgressLeftByMarkerCrash() async throws {
        let fixture = try await CutoverFixture.makeLiveTerminal()
        defer { fixture.cleanup() }
        let compatibility = CutoverCompatibilityFixture()
        let crashing = try fixture.coordinator(compatibility: compatibility, crashAfter: .completeMarker)
        await XCTAssertCutoverCrash(.completeMarker) { try await crashing.run(fixture.source) }
        let progress = fixture.coordinatorDirectory.appendingPathComponent("progress.enc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: progress.path))

        let restarted = try fixture.coordinator(compatibility: compatibility)
        XCTAssertValidated(try await restarted.run(fixture.source), sourceDigest: fixture.source.sourceDigest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: progress.path))
    }

    func testCompletionClampsWallClockRollbackToPreparedAt() async throws {
        let fixture = try await CutoverFixture.makeLiveTerminal()
        defer { fixture.cleanup() }
        let source = ChangeSetCutoverLegacySnapshot(
            sourceDigest: fixture.source.sourceDigest,
            preparedAt: fixture.clock.addingTimeInterval(100),
            cursorBinding: fixture.source.cursorBinding,
            registry: fixture.source.registry,
            transactions: fixture.source.transactions,
            runtimeReceipts: fixture.source.runtimeReceipts
        )
        let compatibility = CutoverCompatibilityFixture()
        let coordinator = try fixture.coordinator(compatibility: compatibility)

        XCTAssertValidated(try await coordinator.run(source), sourceDigest: source.sourceDigest)
        XCTAssertValidated(try await coordinator.validateForPublication(), sourceDigest: source.sourceDigest)
    }

    func testResumeRejectsSameSourceDigestWithChangedLegacyPayload() async throws {
        let fixture = try await CutoverFixture.makeLiveTerminal()
        defer { fixture.cleanup() }
        let compatibility = CutoverCompatibilityFixture()
        let coordinator = try fixture.coordinator(compatibility: compatibility, crashAfter: .prepared)
        await XCTAssertCutoverCrash(.prepared) { try await coordinator.run(fixture.source) }

        var changedTransactions = fixture.source.transactions
        let original = changedTransactions[0]
        changedTransactions[0] = .init(
            transactionID: original.transactionID,
            state: original.state,
            manifestDigest: CutoverFixture.digest(99),
            references: original.references,
            payload: original.payload,
            terminalAt: original.terminalAt,
            retentionExpiresAt: original.retentionExpiresAt,
            revision: original.revision
        )
        let changed = ChangeSetCutoverLegacySnapshot(
            sourceDigest: fixture.source.sourceDigest,
            preparedAt: fixture.source.preparedAt,
            cursorBinding: fixture.source.cursorBinding,
            registry: fixture.source.registry,
            transactions: changedTransactions,
            runtimeReceipts: fixture.source.runtimeReceipts
        )
        let restarted = try fixture.coordinator(compatibility: compatibility)
        await XCTAssertCutoverError(.sourceConflict) { try await restarted.run(changed) }
        let status = try await restarted.status()
        XCTAssertFalse(status.permitsDedicatedStorePublication)
    }

    func testUppercaseSourceDigestUsesOneCanonicalProvenanceAcrossRestart() async throws {
        let fixture = try await CutoverFixture.makeLiveTerminal()
        defer { fixture.cleanup() }
        let compatibility = CutoverCompatibilityFixture()
        let source = ChangeSetCutoverLegacySnapshot(
            sourceDigest: fixture.source.sourceDigest.uppercased(),
            preparedAt: fixture.source.preparedAt,
            cursorBinding: fixture.source.cursorBinding,
            registry: fixture.source.registry,
            transactions: fixture.source.transactions,
            runtimeReceipts: fixture.source.runtimeReceipts
        )

        let result = try await fixture.coordinator(compatibility: compatibility).run(source)
        XCTAssertValidated(result, sourceDigest: fixture.source.sourceDigest)
        let receipt = try await fixture.transactionStore.legacyImportReceipt()
        XCTAssertEqual(receipt?.provenance, fixture.source.sourceDigest)
        let restarted = try fixture.coordinator(compatibility: compatibility)
        XCTAssertValidated(
            try await restarted.validateForPublication(),
            sourceDigest: fixture.source.sourceDigest
        )
    }

    func testPreparedManifestStaysCompactAtMaximumLegalReferenceCount() async throws {
        let fixture = try await CutoverFixture.makeLiveTerminal()
        defer { fixture.cleanup() }
        let compatibility = CutoverCompatibilityFixture()
        let original = fixture.source.transactions[0]
        var references = original.references
        for index in references.count..<4_096 {
            references.append(.init(
                kind: "metadata",
                identifier: "reference-\(index)",
                digest: CutoverFixture.digest(index + 100)
            ))
        }
        let expanded = ChangeSetTransactionStore.Snapshot(
            transactionID: original.transactionID,
            state: original.state,
            manifestDigest: original.manifestDigest,
            references: references,
            payload: original.payload,
            terminalAt: original.terminalAt,
            retentionExpiresAt: original.retentionExpiresAt,
            revision: original.revision
        )
        let source = ChangeSetCutoverLegacySnapshot(
            sourceDigest: fixture.source.sourceDigest,
            preparedAt: fixture.source.preparedAt,
            cursorBinding: fixture.source.cursorBinding,
            registry: fixture.source.registry,
            transactions: [expanded],
            runtimeReceipts: fixture.source.runtimeReceipts
        )
        let coordinator = try fixture.coordinator(compatibility: compatibility, crashAfter: .prepared)
        await XCTAssertCutoverCrash(.prepared) { try await coordinator.run(source) }

        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.coordinatorDirectory
            .appendingPathComponent("validation-manifest.enc").path)
        let bytes = try XCTUnwrap(attributes[.size] as? NSNumber).intValue
        XCTAssertLessThan(bytes, 4_096)
    }

    func testCrossValidationRejectsLiveReplayWithoutTransactionAndLeavesPublicationBlocked() async throws {
        let fixture = try await CutoverFixture.makeLiveTerminal(includeTransaction: false)
        defer { fixture.cleanup() }
        let compatibility = CutoverCompatibilityFixture()
        let coordinator = try fixture.coordinator(compatibility: compatibility)

        await XCTAssertCutoverError(.crossValidationFailed) { try await coordinator.run(fixture.source) }
        let status = try await coordinator.status()
        XCTAssertEqual(status, .inProgress(phase: .transactionsImported, sourceDigest: fixture.source.sourceDigest))
        XCTAssertFalse(status.permitsDedicatedStorePublication)
    }

    func testExpiredTerminalTombstoneMayOutliveItsTransaction() async throws {
        let fixture = try await CutoverFixture.makeExpiredTombstone()
        defer { fixture.cleanup() }
        let compatibility = CutoverCompatibilityFixture()
        let coordinator = try fixture.coordinator(compatibility: compatibility)

        let result = try await coordinator.run(fixture.source)
        XCTAssertValidated(result, sourceDigest: fixture.source.sourceDigest)
        let status = try await coordinator.status()
        XCTAssertFalse(status.permitsDedicatedStorePublication)
    }

    func testAuthenticatedCompleteMarkerTamperFailsClosed() async throws {
        let fixture = try await CutoverFixture.makeLiveTerminal()
        defer { fixture.cleanup() }
        let compatibility = CutoverCompatibilityFixture()
        let coordinator = try fixture.coordinator(compatibility: compatibility)
        _ = try await coordinator.run(fixture.source)

        let marker = fixture.coordinatorDirectory.appendingPathComponent("complete.enc")
        var bytes = try Data(contentsOf: marker)
        bytes[bytes.index(before: bytes.endIndex)] ^= 0x01
        try bytes.write(to: marker, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)

        let restarted = try fixture.coordinator(compatibility: compatibility)
        await XCTAssertCutoverError(.stateCorrupt) { try await restarted.status() }
    }

    func testAuthenticatedValidationManifestTamperFailsClosed() async throws {
        let fixture = try await CutoverFixture.makeLiveTerminal()
        defer { fixture.cleanup() }
        let compatibility = CutoverCompatibilityFixture()
        let coordinator = try fixture.coordinator(compatibility: compatibility)
        _ = try await coordinator.run(fixture.source)

        let manifest = fixture.coordinatorDirectory.appendingPathComponent("validation-manifest.enc")
        var bytes = try Data(contentsOf: manifest)
        bytes[bytes.startIndex] ^= 0x01
        try bytes.write(to: manifest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)

        let restarted = try fixture.coordinator(compatibility: compatibility)
        await XCTAssertCutoverError(.stateCorrupt) { try await restarted.status() }
        await XCTAssertCutoverError(.stateCorrupt) {
            try await restarted.validateForPublication(at: fixture.clock)
        }
    }

    func testCompleteMarkerFastPathAllowsAuthenticatedTransactionEvolution() async throws {
        let fixture = try await CutoverFixture.makeLiveTerminal()
        defer { fixture.cleanup() }
        let compatibility = CutoverCompatibilityFixture()
        let coordinator = try fixture.coordinator(compatibility: compatibility)
        XCTAssertValidated(try await coordinator.run(fixture.source), sourceDigest: fixture.source.sourceDigest)

        let expected = fixture.source.transactions[0]
        _ = try await fixture.transactionStore.updateSnapshot(
            transactionID: expected.transactionID,
            expectedState: expected.state,
            expectedRevision: expected.revision,
            payload: Data("drifted-after-completion".utf8),
            references: expected.references,
            manifestDigest: expected.manifestDigest,
            terminalAt: expected.terminalAt,
            retentionExpiresAt: expected.retentionExpiresAt
        )

        let restarted = try fixture.coordinator(compatibility: compatibility)
        XCTAssertValidated(try await restarted.validateForPublication(at: fixture.clock),
            sourceDigest: fixture.source.sourceDigest)
        XCTAssertValidated(try await restarted.run(fixture.source),
            sourceDigest: fixture.source.sourceDigest)
        let markerOnlyStatus = try await restarted.status()
        XCTAssertEqual(markerOnlyStatus, .complete(sourceDigest: fixture.source.sourceDigest))
        XCTAssertFalse(markerOnlyStatus.permitsDedicatedStorePublication)
    }

    func testPublicationValidatorRejectsRegistryResponseDigestDrift() async throws {
        let fixture = try await CutoverFixture.makeLiveTerminal()
        defer { fixture.cleanup() }
        let compatibility = CutoverCompatibilityFixture()
        let coordinator = try fixture.coordinator(compatibility: compatibility)
        _ = try await coordinator.run(fixture.source)

        let replayReferences = await fixture.registry.replayReferences()
        let replay = try XCTUnwrap(replayReferences.first)
        let registrySnapshot = await fixture.registry.snapshot()
        _ = try await fixture.registry.markTerminal(
            clientID: replay.clientID,
            epoch: replay.epoch,
            sequence: replay.sequence,
            state: replay.state,
            terminalResponseDigest: CutoverFixture.digest(88),
            artifact: replay.artifactHandle.map {
                ChangeSetReplayArtifact(handle: $0, expiresAt: replay.artifactExpiresAt!)
            },
            retentionExpiresAt: replay.retentionExpiresAt!,
            expectedRegistryGeneration: registrySnapshot.generation
        )

        let restarted = try fixture.coordinator(compatibility: compatibility)
        await XCTAssertCutoverError(.crossValidationFailed) {
            try await restarted.validateForPublication(at: fixture.clock)
        }
    }

    func testPostCutoverNewAdmittedTransactionPassesButEitherOneSidedReferenceFails() async throws {
        let validFixture = try await CutoverFixture.makeLiveTerminal()
        defer { validFixture.cleanup() }
        let validCompatibility = CutoverCompatibilityFixture()
        let validCoordinator = try validFixture.coordinator(compatibility: validCompatibility)
        _ = try await validCoordinator.run(validFixture.source)
        try await validFixture.installNewPendingTransaction(includeRegistry: true, includeTransaction: true)
        XCTAssertValidated(
            try await validCoordinator.validateForPublication(at: validFixture.clock),
            sourceDigest: validFixture.source.sourceDigest
        )

        let registryOnly = try await CutoverFixture.makeLiveTerminal()
        defer { registryOnly.cleanup() }
        let registryCompatibility = CutoverCompatibilityFixture()
        let registryCoordinator = try registryOnly.coordinator(compatibility: registryCompatibility)
        _ = try await registryCoordinator.run(registryOnly.source)
        try await registryOnly.installNewPendingTransaction(includeRegistry: true, includeTransaction: false)
        await XCTAssertCutoverError(.crossValidationFailed) {
            try await registryCoordinator.validateForPublication(at: registryOnly.clock)
        }

        let transactionOnly = try await CutoverFixture.makeLiveTerminal()
        defer { transactionOnly.cleanup() }
        let transactionCompatibility = CutoverCompatibilityFixture()
        let transactionCoordinator = try transactionOnly.coordinator(compatibility: transactionCompatibility)
        _ = try await transactionCoordinator.run(transactionOnly.source)
        try await transactionOnly.installNewPendingTransaction(includeRegistry: false, includeTransaction: true)
        await XCTAssertCutoverError(.crossValidationFailed) {
            try await transactionCoordinator.validateForPublication(at: transactionOnly.clock)
        }
    }

    func testPostCutoverRotateAndRetireIntentionallyInvalidateTerminalReplay() async throws {
        let fixture = try await CutoverFixture.makeLiveTerminal()
        defer { fixture.cleanup() }
        let compatibility = CutoverCompatibilityFixture()
        let coordinator = try fixture.coordinator(compatibility: compatibility)
        _ = try await coordinator.run(fixture.source)
        let replayReferences = await fixture.registry.replayReferences()
        let replay = try XCTUnwrap(replayReferences.first)

        var generation = await fixture.registry.snapshot().generation
        _ = try await fixture.registry.rotateEpoch(
            controlRequestID: UUID().uuidString.lowercased(),
            proofIDDigest: CutoverFixture.digest(70),
            proofExpiresAt: Date(timeIntervalSince1970: 1_200),
            clientID: replay.clientID,
            expectedEpoch: replay.epoch,
            nextEpoch: replay.epoch + 1,
            expectedRegistryGeneration: generation
        )
        XCTAssertValidated(try await coordinator.validateForPublication(at: fixture.clock),
            sourceDigest: fixture.source.sourceDigest)

        generation = await fixture.registry.snapshot().generation
        _ = try await fixture.registry.retire(
            controlRequestID: UUID().uuidString.lowercased(),
            proofIDDigest: CutoverFixture.digest(71),
            proofExpiresAt: Date(timeIntervalSince1970: 1_200),
            clientID: replay.clientID,
            expectedEpoch: replay.epoch + 1,
            expectedRegistryGeneration: generation
        )
        XCTAssertValidated(try await coordinator.validateForPublication(at: fixture.clock),
            sourceDigest: fixture.source.sourceDigest)
    }

    func testRuntimeReceiptSemanticConstraintsRejectMissingAbortedAndCursorMismatch() async throws {
        let missing = try await CutoverFixture.makeLiveTerminal()
        defer { missing.cleanup() }
        let missingSource = ChangeSetCutoverLegacySnapshot(
            sourceDigest: missing.source.sourceDigest,
            preparedAt: missing.source.preparedAt,
            cursorBinding: missing.source.cursorBinding,
            registry: missing.source.registry,
            transactions: missing.source.transactions,
            runtimeReceipts: []
        )
        await XCTAssertCutoverError(.crossValidationFailed) {
            try await missing.coordinator(compatibility: CutoverCompatibilityFixture()).run(missingSource)
        }

        let aborted = try await CutoverFixture.makeFinalAbortedTerminal()
        defer { aborted.cleanup() }
        let invalidReceipt = ChangeSetTransactionStore.RuntimeReceipt(
            transactionID: aborted.source.transactions[0].transactionID,
            cursor: .init(root: aborted.root.path, generation: "legacy-generation", sequence: 42),
            paths: ["changed.txt"],
            digest: CutoverFixture.runtimeDigest(root: aborted.root.path,
                generation: "legacy-generation", sequence: 42, paths: ["changed.txt"]),
            recordedAt: Date(timeIntervalSince1970: 850),
            terminalAt: Date(timeIntervalSince1970: 800)
        )
        let abortedSource = ChangeSetCutoverLegacySnapshot(
            sourceDigest: aborted.source.sourceDigest,
            preparedAt: aborted.source.preparedAt,
            cursorBinding: aborted.source.cursorBinding,
            registry: aborted.source.registry,
            transactions: aborted.source.transactions,
            runtimeReceipts: [invalidReceipt]
        )
        await XCTAssertCutoverError(.crossValidationFailed) {
            try await aborted.coordinator(compatibility: CutoverCompatibilityFixture()).run(abortedSource)
        }

        let cursor = try await CutoverFixture.makeLiveTerminal()
        defer { cursor.cleanup() }
        let wrongCursor = ChangeSetTransactionStore.RuntimeReceipt(
            transactionID: cursor.source.transactions[0].transactionID,
            cursor: .init(root: cursor.root.path, generation: "wrong-generation", sequence: 42),
            paths: ["changed.txt"],
            digest: CutoverFixture.runtimeDigest(root: cursor.root.path,
                generation: "wrong-generation", sequence: 42, paths: ["changed.txt"]),
            recordedAt: Date(timeIntervalSince1970: 850),
            terminalAt: Date(timeIntervalSince1970: 800)
        )
        let cursorSource = ChangeSetCutoverLegacySnapshot(
            sourceDigest: cursor.source.sourceDigest,
            preparedAt: cursor.source.preparedAt,
            cursorBinding: cursor.source.cursorBinding,
            registry: cursor.source.registry,
            transactions: cursor.source.transactions,
            runtimeReceipts: [wrongCursor]
        )
        await XCTAssertCutoverError(.crossValidationFailed) {
            try await cursor.coordinator(compatibility: CutoverCompatibilityFixture()).run(cursorSource)
        }
    }

    func testFilesystemCommittedWithDurableReceiptIsRecoverableBeforeTransactionSync() async throws {
        let fixture = try await CutoverFixture.makeLiveTerminal()
        defer { fixture.cleanup() }
        let compatibility = CutoverCompatibilityFixture()
        let coordinator = try fixture.coordinator(compatibility: compatibility)
        _ = try await coordinator.run(fixture.source)
        try await fixture.installFilesystemCommittedWithReceipt()

        XCTAssertValidated(
            try await coordinator.validateForPublication(at: fixture.clock),
            sourceDigest: fixture.source.sourceDigest
        )
    }

    func testRecordReadRejectsOversizeAndSymlinkAndKeepsOpenedFileAcrossPathSwap() async throws {
        let oversize = try await CutoverFixture.makeLiveTerminal()
        defer { oversize.cleanup() }
        let oversizeCompatibility = CutoverCompatibilityFixture()
        _ = try await oversize.coordinator(compatibility: oversizeCompatibility).run(oversize.source)
        let oversizeManifest = oversize.coordinatorDirectory.appendingPathComponent("validation-manifest.enc")
        let oversizeHandle = try FileHandle(forWritingTo: oversizeManifest)
        try oversizeHandle.truncate(atOffset: UInt64(16 * 1_024 * 1_024 + 1))
        try oversizeHandle.close()
        await XCTAssertCutoverError(.stateCorrupt) {
            try await oversize.coordinator(compatibility: oversizeCompatibility).status()
        }

        let symlink = try await CutoverFixture.makeLiveTerminal()
        defer { symlink.cleanup() }
        let symlinkCompatibility = CutoverCompatibilityFixture()
        _ = try await symlink.coordinator(compatibility: symlinkCompatibility).run(symlink.source)
        let symlinkManifest = symlink.coordinatorDirectory.appendingPathComponent("validation-manifest.enc")
        try FileManager.default.removeItem(at: symlinkManifest)
        try FileManager.default.createSymbolicLink(atPath: symlinkManifest.path,
            withDestinationPath: symlink.coordinatorDirectory.appendingPathComponent("complete.enc").path)
        await XCTAssertCutoverError(.stateCorrupt) {
            try await symlink.coordinator(compatibility: symlinkCompatibility).status()
        }

        let swapped = try await CutoverFixture.makeLiveTerminal()
        defer { swapped.cleanup() }
        let swappedCompatibility = CutoverCompatibilityFixture()
        _ = try await swapped.coordinator(compatibility: swappedCompatibility).run(swapped.source)
        let hook = CutoverPathSwapHook(target: swapped.coordinatorDirectory
            .appendingPathComponent("validation-manifest.enc"))
        let observing = try swapped.coordinator(compatibility: swappedCompatibility,
            recordOpenedHook: hook.handle)
        let observedStatus = try await observing.status()
        XCTAssertEqual(observedStatus, .complete(sourceDigest: swapped.source.sourceDigest))
        let reopened = try swapped.coordinator(compatibility: swappedCompatibility)
        await XCTAssertCutoverError(.stateCorrupt) { try await reopened.status() }
    }

    func testManifestAuthoringRejectsReferenceCountAboveExplicitBound() async throws {
        let fixture = try await CutoverFixture.makeLiveTerminal()
        defer { fixture.cleanup() }
        let original = fixture.source.transactions[0]
        let excessiveReferences = (0...4_096).map {
            ChangeSetTransactionStore.Reference(
                kind: "artifact",
                identifier: "bounded-\($0)",
                digest: CutoverFixture.digest($0)
            )
        }
        let excessive = ChangeSetTransactionStore.Snapshot(
            transactionID: original.transactionID,
            state: original.state,
            manifestDigest: original.manifestDigest,
            references: excessiveReferences,
            payload: original.payload,
            terminalAt: original.terminalAt,
            retentionExpiresAt: original.retentionExpiresAt,
            revision: original.revision
        )
        let source = ChangeSetCutoverLegacySnapshot(
            sourceDigest: fixture.source.sourceDigest,
            preparedAt: fixture.source.preparedAt,
            cursorBinding: fixture.source.cursorBinding,
            registry: fixture.source.registry,
            transactions: [excessive],
            runtimeReceipts: fixture.source.runtimeReceipts
        )
        await XCTAssertCutoverError(.invalidSource) {
            try await fixture.coordinator(compatibility: CutoverCompatibilityFixture()).run(source)
        }
    }

    func testLegacyRolledBackRecoveryFailsClosedUntilServiceExportsFinalAbortedState() async throws {
        let fixture = try await CutoverFixture.makeRolledBackLegacyTerminal()
        defer { fixture.cleanup() }
        let compatibility = CutoverCompatibilityFixture()
        let coordinator = try fixture.coordinator(compatibility: compatibility)

        await XCTAssertCutoverError(.invalidSource) { try await coordinator.run(fixture.source) }

        let finalFixture = try await CutoverFixture.makeFinalAbortedTerminal()
        defer { finalFixture.cleanup() }
        let finalCompatibility = CutoverCompatibilityFixture()
        let finalCoordinator = try finalFixture.coordinator(compatibility: finalCompatibility)
        let result = try await finalCoordinator.run(finalFixture.source)
        XCTAssertValidated(result, sourceDigest: finalFixture.source.sourceDigest)
    }
}

private actor CutoverCompatibilityFixture: ChangeSetCutoverCompatibilityPreparing {
    private var identity: (String, String)?
    private var prepareCount = 0
    private var validateCount = 0

    func prepareLegacyCompatibility(sourceDigest: String, payloadDigest: String) throws {
        if let identity, identity != (sourceDigest, payloadDigest) {
            throw ChangeSetCutoverError(.sourceConflict)
        }
        if identity == nil {
            identity = (sourceDigest, payloadDigest)
            prepareCount += 1
        }
    }

    func validateLegacyCompatibility(sourceDigest: String, payloadDigest: String) throws {
        guard let identity, identity == (sourceDigest, payloadDigest) else {
            throw ChangeSetCutoverError(.sourceConflict)
        }
        validateCount += 1
    }

    func counts() -> (prepared: Int, validated: Int) { (prepareCount, validateCount) }
}

private struct CutoverFixture {
    let root: URL
    let coordinatorDirectory: URL
    let key: Data
    let registry: ChangeSetClientRegistry
    let transactionStore: ChangeSetTransactionStore
    let source: ChangeSetCutoverLegacySnapshot
    let clock: Date

    static func makeLiveTerminal(includeTransaction: Bool = true,
        retentionExpiresAt: Date = Date(timeIntervalSince1970: 2_000)) async throws -> Self {
        try await make(
            replayState: .committed,
            transactionState: .committed,
            retentionExpiresAt: retentionExpiresAt,
            includeTransaction: includeTransaction,
            clock: Date(timeIntervalSince1970: 1_000)
        )
    }

    static func makeExpiredTombstone() async throws -> Self {
        try await make(
            replayState: .committed,
            transactionState: .committed,
            retentionExpiresAt: Date(timeIntervalSince1970: 900),
            includeTransaction: false,
            clock: Date(timeIntervalSince1970: 1_000)
        )
    }

    static func makeRolledBackLegacyTerminal() async throws -> Self {
        try await make(
            replayState: .rolledBack,
            transactionState: .rolledBack,
            retentionExpiresAt: Date(timeIntervalSince1970: 2_000),
            includeTransaction: true,
            clock: Date(timeIntervalSince1970: 1_000)
        )
    }

    static func makeFinalAbortedTerminal() async throws -> Self {
        try await make(
            replayState: .abortedBeforeSideEffect,
            transactionState: .abortedBeforeSideEffect,
            retentionExpiresAt: Date(timeIntervalSince1970: 2_000),
            includeTransaction: true,
            clock: Date(timeIntervalSince1970: 1_000)
        )
    }

    private static func make(
        replayState: ChangeSetReplayState,
        transactionState: ApplyChangeSetTransactionState,
        retentionExpiresAt: Date,
        includeTransaction: Bool,
        clock: Date
    ) async throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChangeSetCutoverCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let key = Data(repeating: 0x6c, count: 32)
        let rootDigest = digest(1)
        let registry = try ChangeSetClientRegistry(
            directory: root.appendingPathComponent("registry", isDirectory: true),
            rootIdentityDigest: rootDigest,
            hmacKey: key,
            now: { clock }
        )
        let pristine = await registry.snapshot()
        let transactionID = "cutover-transaction"
        var slots = pristine.slots.map {
            ChangeSetLegacyClientSlot(
                number: $0.number,
                clientID: $0.clientID,
                slotGeneration: $0.slotGeneration,
                allocationState: $0.allocationState,
                currentEpoch: $0.currentEpoch,
                highWater: $0.highWater,
                replay: Array(repeating: nil, count: ChangeSetClientRegistry.replayCapacity)
            )
        }
        let first = slots[0]
        var replay = first.replay
        replay[0] = ChangeSetReplayEnvelope(
            sequence: 1,
            requestDigest: digest(2),
            transactionID: transactionID,
            state: replayState,
            terminalResponseDigest: digest(3),
            artifact: .init(handle: "artifact-handle", expiresAt: retentionExpiresAt),
            retentionExpiresAt: retentionExpiresAt
        )
        slots[0] = ChangeSetLegacyClientSlot(
            number: first.number,
            clientID: first.clientID,
            slotGeneration: 1,
            allocationState: .active,
            currentEpoch: 1,
            highWater: 1,
            replay: replay
        )
        let legacyRegistry = ChangeSetLegacyRegistrySnapshot(
            rootIdentityDigest: rootDigest,
            registryGeneration: 1,
            slots: slots,
            controlReceipts: Array(repeating: nil, count: ChangeSetClientRegistry.controlReceiptCapacity)
        )
        let transaction = ChangeSetTransactionStore.Snapshot(
            transactionID: .init(transactionID),
            state: transactionState,
            manifestDigest: digest(4),
            references: [
                .init(kind: "request", identifier: transactionID, digest: digest(2)),
                .init(kind: "reservation", identifier: "reservation-1", digest: digest(2)),
                .init(kind: "artifact", identifier: "artifact-handle", digest: digest(5)),
                .init(kind: "terminal_response", identifier: transactionID, digest: digest(3)),
            ],
            payload: Data("legacy-payload".utf8),
            terminalAt: Date(timeIntervalSince1970: 800),
            retentionExpiresAt: retentionExpiresAt,
            revision: 7
        )
        let receipt = ChangeSetTransactionStore.RuntimeReceipt(
            transactionID: .init(transactionID),
            cursor: .init(root: root.path, generation: "legacy-generation", sequence: 42),
            paths: ["changed.txt"],
            digest: runtimeDigest(root: root.path, generation: "legacy-generation",
                sequence: 42, paths: ["changed.txt"]),
            recordedAt: Date(timeIntervalSince1970: 850),
            terminalAt: Date(timeIntervalSince1970: 800)
        )
        let transactionStore = try ChangeSetTransactionStore(
            directory: root.appendingPathComponent("transaction-store", isDirectory: true),
            encryptionKey: key
        )
        let source = ChangeSetCutoverLegacySnapshot(
            sourceDigest: digest(7),
            preparedAt: clock,
            cursorBinding: .init(root: root.path, generation: "legacy-generation"),
            registry: legacyRegistry,
            transactions: includeTransaction ? [transaction] : [],
            runtimeReceipts: includeTransaction && (transactionState == .committed || transactionState == .finalized)
                ? [receipt] : []
        )
        return Self(
            root: root,
            coordinatorDirectory: root.appendingPathComponent("coordinator", isDirectory: true),
            key: key,
            registry: registry,
            transactionStore: transactionStore,
            source: source,
            clock: clock
        )
    }

    func coordinator(
        compatibility: CutoverCompatibilityFixture,
        crashAfter: ChangeSetCutoverCrashPoint? = nil,
        recordOpenedHook: (@Sendable (URL) -> Void)? = nil
    ) throws -> ChangeSetCutoverCoordinator {
        try ChangeSetCutoverCoordinator(
            directory: coordinatorDirectory,
            encryptionKey: key,
            registry: registry,
            transactionStore: transactionStore,
            compatibility: compatibility,
            now: { clock },
            crashAfter: crashAfter,
            recordOpenedHook: recordOpenedHook
        )
    }

    func installNewPendingTransaction(includeRegistry: Bool, includeTransaction: Bool) async throws {
        let transactionID = ApplyChangeSetTransactionID("post-cutover-pending")
        let requestDigest = Self.digest(44)
        if includeTransaction {
            try await transactionStore.persistTransition(.init(
                transactionID: transactionID,
                state: .preparing,
                manifestDigest: Self.digest(45),
                references: [
                    .init(kind: "request", identifier: transactionID.rawValue, digest: requestDigest),
                    .init(kind: "reservation", identifier: "post-reservation", digest: requestDigest),
                ],
                payload: Data("post-cutover-pending".utf8)
            ))
        }
        if includeRegistry {
            let replayReferences = await registry.replayReferences()
            let replay = try XCTUnwrap(replayReferences.first)
            let generation = await registry.snapshot().generation
            _ = try await registry.admit(
                clientID: replay.clientID,
                epoch: replay.epoch,
                sequence: replay.sequence + 1,
                requestDigest: requestDigest,
                transactionID: transactionID.rawValue,
                expectedRegistryGeneration: generation
            )
        }
    }

    func installFilesystemCommittedWithReceipt() async throws {
        try await installNewPendingTransaction(includeRegistry: true, includeTransaction: true)
        let transactionID = ApplyChangeSetTransactionID("post-cutover-pending")
        let loaded = try await transactionStore.load(transactionID)
        let initial = try XCTUnwrap(loaded)
        var previous = initial.state
        for state: ApplyChangeSetTransactionState in [.prepared, .commitDecided, .filesystemCommitted] {
            let next = ChangeSetTransactionStore.Snapshot(
                transactionID: initial.transactionID,
                state: state,
                manifestDigest: initial.manifestDigest,
                references: initial.references,
                payload: initial.payload,
                terminalAt: nil,
                retentionExpiresAt: nil,
                revision: initial.revision
            )
            try await transactionStore.persistTransition(next, expectedState: previous)
            previous = state
        }
        let cursor = ApplyChangeSetCursor(
            root: source.cursorBinding.root,
            generation: source.cursorBinding.generation,
            sequence: 43
        )
        let paths = ["post-cutover.txt"]
        try await transactionStore.appendRuntimeReceipt(.init(
            transactionID: transactionID,
            cursor: cursor,
            paths: paths,
            digest: Self.runtimeDigest(
                root: cursor.root,
                generation: cursor.generation,
                sequence: cursor.sequence,
                paths: paths
            ),
            recordedAt: clock,
            terminalAt: clock
        ))
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    static func digest(_ value: Int) -> String {
        String(repeating: String(format: "%02x", value & 0xff), count: 32)
    }

    static func runtimeDigest(root: String, generation: String, sequence: UInt64, paths: [String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try! encoder.encode([root, generation, String(sequence)] + paths)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class CutoverPathSwapHook: @unchecked Sendable {
    private let lock = NSLock()
    private let target: URL
    private var fired = false

    init(target: URL) { self.target = target }

    func handle(_ opened: URL) {
        lock.withLock {
            guard !fired, opened.path == target.path else { return }
            fired = true
            let moved = target.deletingLastPathComponent().appendingPathComponent("opened-manifest.enc")
            try? FileManager.default.moveItem(at: target, to: moved)
            try? Data("path-swapped".utf8).write(to: target)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
    }
}

private func XCTAssertCutoverCrash<T>(
    _ expected: ChangeSetCutoverCrashPoint,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        XCTFail("expected simulated crash", file: file, line: line)
    } catch let error as ChangeSetCutoverSimulatedCrash {
        XCTAssertEqual(error.point, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}

private func XCTAssertCutoverError<T>(
    _ expected: ChangeSetCutoverError.Code,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        XCTFail("expected cutover error", file: file, line: line)
    } catch let error as ChangeSetCutoverError {
        XCTAssertEqual(error.code, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}

private func XCTAssertValidated(
    _ status: ChangeSetCutoverStatus,
    sourceDigest: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case let .validated(actualSourceDigest, manifestDigest) = status else {
        XCTFail("expected validated publication status, got \(status)", file: file, line: line)
        return
    }
    XCTAssertEqual(actualSourceDigest, sourceDigest, file: file, line: line)
    XCTAssertEqual(manifestDigest.count, 64, file: file, line: line)
    XCTAssertTrue(status.permitsDedicatedStorePublication, file: file, line: line)
}
