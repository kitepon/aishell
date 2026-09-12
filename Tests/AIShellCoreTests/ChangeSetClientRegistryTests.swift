import CryptoKit
import Foundation
import XCTest
@testable import AIShellCore

final class ChangeSetClientRegistryTests: XCTestCase {
    func testTerminalIntentCanConvergeAfterRetentionExpiresAndReplaysExactly() async throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        let registry = try fixture.open()
        _ = try await registry.allocate(
            controlRequestID: fixture.uuid(60), proofIDDigest: fixture.digest(60),
            proofExpiresAt: fixture.clock.now().addingTimeInterval(300),
            expectedRegistryGeneration: 0)
        let allocated = await registry.snapshot()
        let client = try XCTUnwrap(allocated.slots.first {
            $0.allocationState == .active
        })
        let requestDigest = fixture.digest(61)
        let admitted = try await registry.admit(clientID: client.clientID,
            epoch: client.currentEpoch, sequence: 1, requestDigest: requestDigest,
            transactionID: "expired-intent", expectedRegistryGeneration: 1)
        let expiry = fixture.clock.now().addingTimeInterval(10)
        fixture.clock.advance(11)

        let terminal = try await registry.reconcileTerminalIntent(
            clientID: client.clientID, epoch: client.currentEpoch, sequence: 1,
            state: .committed, terminalResponseDigest: fixture.digest(62),
            artifact: .init(handle: "expired-artifact", expiresAt: expiry),
            retentionExpiresAt: expiry, expectedRegistryGeneration: admitted)
        let replayed = try await registry.reconcileTerminalIntent(
            clientID: client.clientID, epoch: client.currentEpoch, sequence: 1,
            state: .committed, terminalResponseDigest: fixture.digest(62),
            artifact: .init(handle: "expired-artifact", expiresAt: expiry),
            retentionExpiresAt: expiry, expectedRegistryGeneration: terminal)
        XCTAssertEqual(replayed, terminal)
        await XCTAssertRegistryError(.clientExpired) {
            _ = try await registry.lookup(clientID: client.clientID, epoch: client.currentEpoch,
                sequence: 1, requestDigest: requestDigest)
        }
    }

    func testBootstrapPreallocatesFixedOwnerOnlyBanksAndSurvivesRestart() async throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }

        let registry = try fixture.open()
        let initial = await registry.snapshot()
        let pristineImportReceipt = await registry.legacyImportReceipt()
        XCTAssertEqual(initial.generation, 0)
        XCTAssertNil(pristineImportReceipt)
        XCTAssertEqual(initial.slots.count, 64)
        XCTAssertEqual(Set(initial.slots.map(\.clientID)).count, 64)
        XCTAssertTrue(initial.slots.allSatisfy { $0.allocationState == .free && $0.currentEpoch == 0 })
        XCTAssertEqual(try fixture.permissions(of: fixture.directory), 0o700)
        XCTAssertEqual(try fixture.fileSize("registry-a.bank"), ChangeSetClientRegistry.bankByteCount)
        XCTAssertEqual(try fixture.fileSize("registry-b.bank"), ChangeSetClientRegistry.bankByteCount)
        XCTAssertEqual(try fixture.permissions(of: fixture.directory.appendingPathComponent("registry-a.bank")), 0o600)
        XCTAssertEqual(ChangeSetClientRegistry.replayCapacity, 256)
        XCTAssertEqual(ChangeSetClientRegistry.controlReceiptCapacity, 128)

        let receipt = try await registry.allocate(
            controlRequestID: fixture.uuid(1),
            proofIDDigest: fixture.digest(1),
            proofExpiresAt: fixture.clock.now().addingTimeInterval(300),
            expectedRegistryGeneration: initial.generation
        )
        XCTAssertEqual(receipt.registryGeneration, 1)
        XCTAssertEqual(receipt.slotIndex, 0)
        XCTAssertEqual(receipt.clientID, initial.slots[0].clientID)
        XCTAssertEqual(try fixture.fileSize("registry-b.bank"), ChangeSetClientRegistry.bankByteCount)

        let restarted = try fixture.open()
        let restartedSnapshot = await restarted.snapshot()
        XCTAssertEqual(restartedSnapshot.generation, 1)
        XCTAssertEqual(restartedSnapshot.slots.filter { $0.allocationState == .active }.count, 1)
        let replayedReceipt = try await restarted.allocate(
            controlRequestID: fixture.uuid(1),
            proofIDDigest: fixture.digest(1),
            proofExpiresAt: fixture.clock.now().addingTimeInterval(300),
            expectedRegistryGeneration: initial.generation
        )
        XCTAssertEqual(replayedReceipt.clientID, receipt.clientID)
        XCTAssertEqual(replayedReceipt.slotIndex, receipt.slotIndex)
        XCTAssertEqual(replayedReceipt.registryGeneration, receipt.registryGeneration)
    }

    func testHighestValidBankRecoversOneCorruptionAndBothCorruptFailClosed() async throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        let registry = try fixture.open()
        _ = try await registry.allocate(
            controlRequestID: fixture.uuid(2),
            proofIDDigest: fixture.digest(2),
            proofExpiresAt: fixture.clock.now().addingTimeInterval(300),
            expectedRegistryGeneration: 0
        )

        try fixture.corrupt("registry-b.bank")
        let recovered = try fixture.open()
        let recoveredSnapshot = await recovered.snapshot()
        XCTAssertEqual(recoveredSnapshot.generation, 0)
        XCTAssertTrue(recoveredSnapshot.slots.allSatisfy { $0.allocationState == .free })

        try fixture.corrupt("registry-a.bank")
        XCTAssertThrowsError(try fixture.open()) { error in
            XCTAssertEqual((error as? ChangeSetClientRegistryError)?.code, .storeCorrupt)
        }
    }

    func testGenerationCASProofConsumptionAndControlReplay() async throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        let registry = try fixture.open()
        let requestID = fixture.uuid(3)
        let proof = fixture.digest(3)
        let expiry = fixture.clock.now().addingTimeInterval(300)

        let first = try await registry.allocate(controlRequestID: requestID, proofIDDigest: proof, proofExpiresAt: expiry, expectedRegistryGeneration: 0)
        let replay = try await registry.allocate(controlRequestID: requestID, proofIDDigest: proof, proofExpiresAt: expiry, expectedRegistryGeneration: 0)
        XCTAssertEqual(replay, first)

        await XCTAssertRegistryError(.ownerProofConsumed) {
            try await registry.allocate(
                controlRequestID: fixture.uuid(4),
                proofIDDigest: proof,
                proofExpiresAt: expiry,
                expectedRegistryGeneration: first.registryGeneration
            )
        }
        await XCTAssertRegistryError(.generationChanged) {
            try await registry.allocate(
                controlRequestID: fixture.uuid(5),
                proofIDDigest: fixture.digest(5),
                proofExpiresAt: expiry,
                expectedRegistryGeneration: 0
            )
        }
    }

    func testCompactReplayLookupRetentionAndFailClosedSequenceRules() async throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        let registry = try fixture.open()
        _ = try await registry.allocate(
            controlRequestID: fixture.uuid(6),
            proofIDDigest: fixture.digest(6),
            proofExpiresAt: fixture.clock.now().addingTimeInterval(300),
            expectedRegistryGeneration: 0
        )
        let allocatedSnapshot = await registry.snapshot()
        let client = try XCTUnwrap(allocatedSnapshot.slots.first { $0.allocationState == .active })
        let requestDigest = fixture.digest(20)

        let initialLookup = try await registry.lookup(clientID: client.clientID, epoch: client.currentEpoch, sequence: 1, requestDigest: requestDigest)
        XCTAssertEqual(initialLookup, .new(nextSequence: 1))
        let admittedGeneration = try await registry.admit(
            clientID: client.clientID,
            epoch: client.currentEpoch,
            sequence: 1,
            requestDigest: requestDigest,
            transactionID: "tx-1",
            expectedRegistryGeneration: 1
        )
        guard case let .pending(pending) = try await registry.lookup(clientID: client.clientID, epoch: client.currentEpoch, sequence: 1, requestDigest: requestDigest) else {
            return XCTFail("admitted request must be pending")
        }
        XCTAssertEqual(pending.transactionID, "tx-1")
        XCTAssertNil(pending.terminalResponseDigest)
        await XCTAssertRegistryError(.previousPending) {
            try await registry.lookup(clientID: client.clientID, epoch: client.currentEpoch, sequence: 2, requestDigest: fixture.digest(21))
        }
        await XCTAssertRegistryError(.sequenceConflict) {
            try await registry.lookup(clientID: client.clientID, epoch: client.currentEpoch, sequence: 1, requestDigest: fixture.digest(22))
        }
        await XCTAssertRegistryError(.sequenceGap) {
            try await registry.lookup(clientID: client.clientID, epoch: client.currentEpoch, sequence: 3, requestDigest: fixture.digest(23))
        }

        let invalidRetentionExpiry = fixture.clock.now().addingTimeInterval(60)
        await XCTAssertRegistryError(.invalidEnvelope) {
            try await registry.markTerminal(
                clientID: client.clientID,
                epoch: client.currentEpoch,
                sequence: 1,
                state: .committed,
                terminalResponseDigest: fixture.digest(24),
                artifact: ChangeSetReplayArtifact(handle: "expires-too-early", expiresAt: invalidRetentionExpiry.addingTimeInterval(-1)),
                retentionExpiresAt: invalidRetentionExpiry,
                expectedRegistryGeneration: admittedGeneration
            )
        }
        let terminalGeneration = try await registry.markTerminal(
            clientID: client.clientID,
            epoch: client.currentEpoch,
            sequence: 1,
            state: .committed,
            terminalResponseDigest: fixture.digest(24),
            artifact: ChangeSetReplayArtifact(handle: "artifact-1", expiresAt: fixture.clock.now().addingTimeInterval(60)),
            retentionExpiresAt: fixture.clock.now().addingTimeInterval(60),
            expectedRegistryGeneration: admittedGeneration
        )
        XCTAssertEqual(terminalGeneration, admittedGeneration + 1)
        guard case let .replay(replayed) = try await registry.lookup(clientID: client.clientID, epoch: client.currentEpoch, sequence: 1, requestDigest: requestDigest) else {
            return XCTFail("terminal request must replay")
        }
        XCTAssertEqual(replayed.terminalResponseDigest, fixture.digest(24))
        XCTAssertNil(Mirror(reflecting: replayed).children.first { $0.label == "fullResult" })

        fixture.clock.advance(61)
        await XCTAssertRegistryError(.clientExpired) {
            try await registry.lookup(clientID: client.clientID, epoch: client.currentEpoch, sequence: 1, requestDigest: requestDigest)
        }
        let expiredTombstones = await registry.replayReferences()
        XCTAssertEqual(expiredTombstones.count, 1)
        XCTAssertEqual(expiredTombstones[0].transactionID, "tx-1")
        XCTAssertEqual(expiredTombstones[0].state, .committed)
        XCTAssertNotNil(expiredTombstones[0].retentionExpiresAt)
        XCTAssertLessThanOrEqual(try XCTUnwrap(expiredTombstones[0].retentionExpiresAt), fixture.clock.now())
    }

    func testEpochRotationAndRetirePreserveStableSlotIdentity() async throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        let registry = try fixture.open()
        _ = try await registry.allocate(
            controlRequestID: fixture.uuid(7),
            proofIDDigest: fixture.digest(7),
            proofExpiresAt: fixture.clock.now().addingTimeInterval(300),
            expectedRegistryGeneration: 0
        )
        let initialSnapshot = await registry.snapshot()
        let first = try XCTUnwrap(initialSnapshot.slots.first { $0.allocationState == .active })
        let rotate = try await registry.rotateEpoch(
            controlRequestID: fixture.uuid(8),
            proofIDDigest: fixture.digest(8),
            proofExpiresAt: fixture.clock.now().addingTimeInterval(300),
            clientID: first.clientID,
            expectedEpoch: first.currentEpoch,
            nextEpoch: first.currentEpoch + 1,
            expectedRegistryGeneration: 1
        )
        await XCTAssertRegistryError(.clientExpired) {
            try await registry.lookup(clientID: first.clientID, epoch: first.currentEpoch, sequence: 1, requestDigest: fixture.digest(30))
        }
        _ = try await registry.retire(
            controlRequestID: fixture.uuid(9),
            proofIDDigest: fixture.digest(9),
            proofExpiresAt: fixture.clock.now().addingTimeInterval(300),
            clientID: first.clientID,
            expectedEpoch: first.currentEpoch + 1,
            expectedRegistryGeneration: rotate.registryGeneration
        )
        let retiredSnapshot = await registry.snapshot()
        let retired = try XCTUnwrap(retiredSnapshot.slots.first { $0.clientID == first.clientID })
        XCTAssertEqual(retired.allocationState, .free)
        XCTAssertEqual(retired.currentEpoch, first.currentEpoch + 1)

        let beforeReallocate = await registry.snapshot()
        let allocated = try await registry.allocate(
            controlRequestID: fixture.uuid(10),
            proofIDDigest: fixture.digest(10),
            proofExpiresAt: fixture.clock.now().addingTimeInterval(300),
            expectedRegistryGeneration: beforeReallocate.generation
        )
        let reusedSnapshot = await registry.snapshot()
        let reused = try XCTUnwrap(reusedSnapshot.slots.first { $0.allocationState == .active })
        XCTAssertEqual(reused.clientID, first.clientID)
        XCTAssertEqual(reused.currentEpoch, first.currentEpoch + 2)
        XCTAssertEqual(allocated.currentEpoch, reused.currentEpoch)
    }

    func testReplayReferencesAreCompactBoundedAndDeterministicallyOrdered() async throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        let registry = try fixture.open()

        let firstReceipt = try await registry.allocate(
            controlRequestID: fixture.uuid(40),
            proofIDDigest: fixture.digest(40),
            proofExpiresAt: fixture.clock.now().addingTimeInterval(300),
            expectedRegistryGeneration: 0
        )
        let secondReceipt = try await registry.allocate(
            controlRequestID: fixture.uuid(41),
            proofIDDigest: fixture.digest(41),
            proofExpiresAt: fixture.clock.now().addingTimeInterval(300),
            expectedRegistryGeneration: firstReceipt.registryGeneration
        )
        let snapshot = await registry.snapshot()
        let first = snapshot.slots[try XCTUnwrap(firstReceipt.slotIndex)]
        let second = snapshot.slots[try XCTUnwrap(secondReceipt.slotIndex)]

        let firstGeneration = try await registry.admit(
            clientID: first.clientID,
            epoch: first.currentEpoch,
            sequence: 1,
            requestDigest: fixture.digest(42),
            transactionID: "tx-first",
            expectedRegistryGeneration: secondReceipt.registryGeneration
        )
        let secondGeneration = try await registry.admit(
            clientID: second.clientID,
            epoch: second.currentEpoch,
            sequence: 1,
            requestDigest: fixture.digest(43),
            transactionID: "tx-second",
            expectedRegistryGeneration: firstGeneration
        )
        let terminalRetentionExpiry = fixture.clock.now().addingTimeInterval(120)
        _ = try await registry.markTerminal(
            clientID: first.clientID,
            epoch: first.currentEpoch,
            sequence: 1,
            state: .committed,
            terminalResponseDigest: fixture.digest(44),
            artifact: ChangeSetReplayArtifact(handle: "artifact-first", expiresAt: terminalRetentionExpiry),
            retentionExpiresAt: terminalRetentionExpiry,
            expectedRegistryGeneration: secondGeneration
        )

        let references = await registry.replayReferences()
        XCTAssertEqual(references.count, 2)
        XCTAssertEqual(references.map(\.slotIndex), [0, 1])
        XCTAssertEqual(references.map(\.sequence), [1, 1])
        XCTAssertEqual(references[0].clientID, first.clientID)
        XCTAssertEqual(references[0].requestDigest, fixture.digest(42))
        XCTAssertEqual(references[0].transactionID, "tx-first")
        XCTAssertEqual(references[0].state, .committed)
        XCTAssertEqual(references[0].terminalResponseDigest, fixture.digest(44))
        XCTAssertEqual(references[0].artifactHandle, "artifact-first")
        XCTAssertNotNil(references[0].artifactExpiresAt)
        XCTAssertEqual(references[0].retentionExpiresAt, terminalRetentionExpiry)
        XCTAssertEqual(references[1].clientID, second.clientID)
        XCTAssertEqual(references[1].state, .pending)
        XCTAssertNil(references[1].terminalResponseDigest)
        XCTAssertNil(references[1].retentionExpiresAt)
        XCTAssertNil(Mirror(reflecting: references[0]).children.first { $0.label == "fullResult" })
        XCTAssertLessThanOrEqual(references.count, ChangeSetClientRegistry.slotCount * ChangeSetClientRegistry.replayCapacity)
    }

    func testLegacyCutoverIsLosslessRestartableAndExactlyReplayable() async throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        let registry = try fixture.open()
        let pristine = await registry.snapshot()
        let legacy = fixture.legacySnapshot(from: pristine)

        let imported = try await registry.initializeFromLegacy(legacySnapshot: legacy)
        let importedProvenance = await registry.legacyImportReceipt()
        XCTAssertEqual(imported.registryGeneration, legacy.registryGeneration)
        XCTAssertEqual(imported.snapshotDigest.count, 64)
        XCTAssertEqual(importedProvenance, imported)
        let importedSnapshot = await registry.snapshot()
        XCTAssertEqual(importedSnapshot.generation, legacy.registryGeneration)
        XCTAssertEqual(importedSnapshot.controlReceiptCount, 1)
        XCTAssertEqual(importedSnapshot.slots[0].clientID, legacy.slots[0].clientID)
        XCTAssertEqual(importedSnapshot.slots[0].slotGeneration, legacy.slots[0].slotGeneration)
        XCTAssertEqual(importedSnapshot.slots[0].highWater, 2)

        let references = await registry.replayReferences()
        XCTAssertEqual(references.map(\.sequence), [1, 2])
        XCTAssertEqual(references.map(\.transactionID), ["legacy-tx-1", "legacy-tx-2"])
        XCTAssertEqual(references[0].terminalResponseDigest, fixture.digest(61))
        XCTAssertEqual(references[0].artifactHandle, "legacy-artifact")
        XCTAssertEqual(references[1].state, .recoveryRequired)

        let postImportAllocation = try await registry.allocate(
            controlRequestID: fixture.uuid(64),
            proofIDDigest: fixture.digest(64),
            proofExpiresAt: fixture.clock.now().addingTimeInterval(300),
            expectedRegistryGeneration: legacy.registryGeneration
        )
        XCTAssertEqual(postImportAllocation.registryGeneration, legacy.registryGeneration + 1)
        XCTAssertEqual(postImportAllocation.slotIndex, 1)
        let provenanceAfterAllocate = await registry.legacyImportReceipt()
        XCTAssertEqual(provenanceAfterAllocate, imported)

        let allocatedClientID = try XCTUnwrap(postImportAllocation.clientID)
        let allocatedEpoch = try XCTUnwrap(postImportAllocation.currentEpoch)
        let rotated = try await registry.rotateEpoch(
            controlRequestID: fixture.uuid(65),
            proofIDDigest: fixture.digest(65),
            proofExpiresAt: fixture.clock.now().addingTimeInterval(300),
            clientID: allocatedClientID,
            expectedEpoch: allocatedEpoch,
            nextEpoch: allocatedEpoch + 1,
            expectedRegistryGeneration: postImportAllocation.registryGeneration
        )
        let provenanceAfterRotate = await registry.legacyImportReceipt()
        XCTAssertEqual(provenanceAfterRotate, imported)
        let retired = try await registry.retire(
            controlRequestID: fixture.uuid(66),
            proofIDDigest: fixture.digest(66),
            proofExpiresAt: fixture.clock.now().addingTimeInterval(300),
            clientID: allocatedClientID,
            expectedEpoch: allocatedEpoch + 1,
            expectedRegistryGeneration: rotated.registryGeneration
        )
        let provenanceAfterRetire = await registry.legacyImportReceipt()
        XCTAssertEqual(provenanceAfterRetire, imported)

        let restarted = try fixture.open()
        let restartedSnapshot = await restarted.snapshot()
        XCTAssertEqual(restartedSnapshot.generation, retired.registryGeneration)
        XCTAssertEqual(restartedSnapshot.slots[1].allocationState, .free)
        let restartedProvenance = await restarted.legacyImportReceipt()
        XCTAssertEqual(restartedProvenance, imported)
        let replayed = try await restarted.initializeFromLegacy(legacySnapshot: legacy)
        XCTAssertEqual(replayed, imported)
        XCTAssertEqual(replayed.registryGeneration, legacy.registryGeneration)
        let restartedReferences = await restarted.replayReferences()
        XCTAssertEqual(restartedReferences, references)
        await XCTAssertRegistryError(.ownerProofConsumed) {
            try await restarted.allocate(
                controlRequestID: fixture.uuid(62),
                proofIDDigest: fixture.digest(60),
                proofExpiresAt: fixture.clock.now().addingTimeInterval(300),
                expectedRegistryGeneration: retired.registryGeneration
            )
        }
    }

    func testLegacyCutoverRejectsDifferentRetryAndNonPristineStore() async throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        let registry = try fixture.open()
        let pristine = await registry.snapshot()
        let legacy = fixture.legacySnapshot(from: pristine)
        _ = try await registry.initializeFromLegacy(legacySnapshot: legacy)

        var changedSlots = legacy.slots
        let first = changedSlots[0]
        changedSlots[0] = ChangeSetLegacyClientSlot(
            number: first.number,
            clientID: first.clientID,
            slotGeneration: first.slotGeneration + 1,
            allocationState: first.allocationState,
            currentEpoch: first.currentEpoch,
            highWater: first.highWater,
            replay: first.replay
        )
        let changed = ChangeSetLegacyRegistrySnapshot(
            rootIdentityDigest: legacy.rootIdentityDigest,
            registryGeneration: legacy.registryGeneration,
            slots: changedSlots,
            controlReceipts: legacy.controlReceipts
        )
        await XCTAssertRegistryError(.legacyImportConflict) {
            try await registry.initializeFromLegacy(legacySnapshot: changed)
        }

        let other = try RegistryFixture()
        defer { other.cleanup() }
        let nonPristine = try other.open()
        _ = try await nonPristine.allocate(
            controlRequestID: other.uuid(70),
            proofIDDigest: other.digest(70),
            proofExpiresAt: other.clock.now().addingTimeInterval(300),
            expectedRegistryGeneration: 0
        )
        await XCTAssertRegistryError(.legacyImportNotPristine) {
            try await nonPristine.initializeFromLegacy(
                expectedPristineGeneration: 1,
                legacySnapshot: other.legacySnapshot(from: await nonPristine.snapshot(), generation: 8)
            )
        }
    }

    func testLegacyCutoverRejectsMissingReplayAndDuplicateClientWithoutMutation() async throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        let registry = try fixture.open()
        let pristine = await registry.snapshot()
        let valid = fixture.legacySnapshot(from: pristine)

        var missingReplaySlots = valid.slots
        let first = missingReplaySlots[0]
        missingReplaySlots[0] = ChangeSetLegacyClientSlot(
            number: first.number,
            clientID: first.clientID,
            slotGeneration: first.slotGeneration,
            allocationState: first.allocationState,
            currentEpoch: first.currentEpoch,
            highWater: first.highWater,
            replay: Array(repeating: nil, count: ChangeSetClientRegistry.replayCapacity)
        )
        let missingReplay = ChangeSetLegacyRegistrySnapshot(
            rootIdentityDigest: valid.rootIdentityDigest,
            registryGeneration: valid.registryGeneration,
            slots: missingReplaySlots,
            controlReceipts: valid.controlReceipts
        )
        await XCTAssertRegistryError(.storeCorrupt) {
            try await registry.initializeFromLegacy(legacySnapshot: missingReplay)
        }
        let afterMissingReplay = await registry.snapshot()
        XCTAssertEqual(afterMissingReplay.generation, 0)

        var duplicateSlots = valid.slots
        let second = duplicateSlots[1]
        duplicateSlots[1] = ChangeSetLegacyClientSlot(
            number: second.number,
            clientID: duplicateSlots[0].clientID,
            slotGeneration: second.slotGeneration,
            allocationState: second.allocationState,
            currentEpoch: second.currentEpoch,
            highWater: second.highWater,
            replay: second.replay
        )
        let duplicate = ChangeSetLegacyRegistrySnapshot(
            rootIdentityDigest: valid.rootIdentityDigest,
            registryGeneration: valid.registryGeneration,
            slots: duplicateSlots,
            controlReceipts: valid.controlReceipts
        )
        await XCTAssertRegistryError(.storeCorrupt) {
            try await registry.initializeFromLegacy(legacySnapshot: duplicate)
        }
        let afterDuplicate = await registry.snapshot()
        XCTAssertEqual(afterDuplicate.generation, 0)
    }

    func testLegacyCutoverRejectsInvalidTerminalNonterminalAndRetentionShapes() async throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        let registry = try fixture.open()
        let pristine = await registry.snapshot()
        let valid = fixture.legacySnapshot(from: pristine)

        func replacingFirstReplay(_ envelope: ChangeSetReplayEnvelope) -> ChangeSetLegacyRegistrySnapshot {
            var slots = valid.slots
            let first = slots[0]
            var replay = first.replay
            replay[0] = envelope
            slots[0] = ChangeSetLegacyClientSlot(
                number: first.number,
                clientID: first.clientID,
                slotGeneration: first.slotGeneration,
                allocationState: first.allocationState,
                currentEpoch: first.currentEpoch,
                highWater: first.highWater,
                replay: replay
            )
            return ChangeSetLegacyRegistrySnapshot(
                rootIdentityDigest: valid.rootIdentityDigest,
                registryGeneration: valid.registryGeneration,
                slots: slots,
                controlReceipts: valid.controlReceipts
            )
        }

        let terminalWithoutRetention = replacingFirstReplay(ChangeSetReplayEnvelope(
            sequence: 1,
            requestDigest: fixture.digest(51),
            transactionID: "legacy-tx-1",
            state: .committed,
            terminalResponseDigest: fixture.digest(61)
        ))
        await XCTAssertRegistryError(.storeCorrupt) {
            try await registry.initializeFromLegacy(legacySnapshot: terminalWithoutRetention)
        }

        let nonterminalWithTerminalMaterial = replacingFirstReplay(ChangeSetReplayEnvelope(
            sequence: 1,
            requestDigest: fixture.digest(51),
            transactionID: "legacy-tx-1",
            state: .pending,
            artifact: ChangeSetReplayArtifact(handle: "must-not-exist", expiresAt: fixture.clock.now().addingTimeInterval(600)),
            retentionExpiresAt: fixture.clock.now().addingTimeInterval(600)
        ))
        await XCTAssertRegistryError(.storeCorrupt) {
            try await registry.initializeFromLegacy(legacySnapshot: nonterminalWithTerminalMaterial)
        }

        let retentionExpiry = fixture.clock.now().addingTimeInterval(600)
        let artifactExpiresTooEarly = replacingFirstReplay(ChangeSetReplayEnvelope(
            sequence: 1,
            requestDigest: fixture.digest(51),
            transactionID: "legacy-tx-1",
            state: .committed,
            terminalResponseDigest: fixture.digest(61),
            artifact: ChangeSetReplayArtifact(handle: "expires-too-early", expiresAt: retentionExpiry.addingTimeInterval(-1)),
            retentionExpiresAt: retentionExpiry
        ))
        await XCTAssertRegistryError(.storeCorrupt) {
            try await registry.initializeFromLegacy(legacySnapshot: artifactExpiresTooEarly)
        }
        let afterInvalidImports = await registry.snapshot()
        XCTAssertEqual(afterInvalidImports.generation, 0)
        XCTAssertTrue(afterInvalidImports.slots.allSatisfy { $0.allocationState == .free })
    }

    func testExpiredControlReceiptRingReportsZeroAndAcceptsNewReceipt() async throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        let registry = try fixture.open()
        let pristine = await registry.snapshot()
        let base = fixture.legacySnapshot(from: pristine)
        let referenceDate = fixture.clock.now()
        let expiredAt = fixture.clock.now().addingTimeInterval(-1)
        let expiredReceipts: [ChangeSetClientControlReceipt?] = (0..<ChangeSetClientRegistry.controlReceiptCapacity).map { index in
            ChangeSetClientControlReceipt(
                controlRequestID: fixture.uuid(100 + index),
                proofIDDigest: fixture.digest(100 + index),
                action: .allocate,
                resultDigest: fixture.digest(101 + index),
                registryGeneration: base.registryGeneration,
                clientID: base.slots[0].clientID,
                slotIndex: 0,
                slotGeneration: base.slots[0].slotGeneration,
                currentEpoch: base.slots[0].currentEpoch,
                expiresAt: index == 0 ? referenceDate : expiredAt
            )
        }
        let legacy = ChangeSetLegacyRegistrySnapshot(
            rootIdentityDigest: base.rootIdentityDigest,
            registryGeneration: base.registryGeneration,
            slots: base.slots,
            controlReceipts: expiredReceipts
        )
        _ = try await registry.initializeFromLegacy(legacySnapshot: legacy)
        let imported = await registry.snapshot()
        let importedUnexpiredCount = await registry.unexpiredControlReceiptCount(at: referenceDate)
        XCTAssertEqual(imported.controlReceiptCount, ChangeSetClientRegistry.controlReceiptCapacity)
        XCTAssertEqual(importedUnexpiredCount, 0)

        _ = try await registry.allocate(
            controlRequestID: fixture.uuid(240),
            proofIDDigest: fixture.digest(240),
            proofExpiresAt: fixture.clock.now().addingTimeInterval(300),
            expectedRegistryGeneration: base.registryGeneration
        )
        let afterAppend = await registry.snapshot()
        let afterAppendUnexpiredCount = await registry.unexpiredControlReceiptCount(at: fixture.clock.now())
        XCTAssertEqual(afterAppend.controlReceiptCount, ChangeSetClientRegistry.controlReceiptCapacity)
        XCTAssertEqual(afterAppendUnexpiredCount, 1)
    }
}

private final class RegistryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

private struct RegistryFixture {
    let directory: URL
    let key = Data(repeating: 0x5a, count: 32)
    let clock = RegistryClock()

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChangeSetClientRegistryTests-\(UUID().uuidString)", isDirectory: true)
    }

    func open() throws -> ChangeSetClientRegistry {
        try ChangeSetClientRegistry(directory: directory, rootIdentityDigest: digest(250), hmacKey: key, now: clock.now)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func uuid(_ value: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", value) }
    func digest(_ value: Int) -> String { String(repeating: String(format: "%02x", value & 0xff), count: 32) }
    func fileSize(_ name: String) throws -> Int { (try Data(contentsOf: directory.appendingPathComponent(name))).count }

    func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func corrupt(_ name: String) throws {
        let url = directory.appendingPathComponent(name)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 140)
        try handle.write(contentsOf: Data([0xff]))
        try handle.synchronize()
        try handle.close()
    }

    func legacySnapshot(from pristine: ChangeSetClientRegistrySnapshot, generation: UInt64 = 7) -> ChangeSetLegacyRegistrySnapshot {
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
        var replay = Array<ChangeSetReplayEnvelope?>(repeating: nil, count: ChangeSetClientRegistry.replayCapacity)
        replay[0] = ChangeSetReplayEnvelope(
            sequence: 1,
            requestDigest: digest(51),
            transactionID: "legacy-tx-1",
            state: .committed,
            terminalResponseDigest: digest(61),
            artifact: ChangeSetReplayArtifact(handle: "legacy-artifact", expiresAt: clock.now().addingTimeInterval(600)),
            retentionExpiresAt: clock.now().addingTimeInterval(600)
        )
        replay[1] = ChangeSetReplayEnvelope(
            sequence: 2,
            requestDigest: digest(52),
            transactionID: "legacy-tx-2",
            state: .recoveryRequired
        )
        slots[0] = ChangeSetLegacyClientSlot(
            number: 0,
            clientID: slots[0].clientID,
            slotGeneration: 9,
            allocationState: .active,
            currentEpoch: 3,
            highWater: 2,
            replay: replay
        )
        var receipts = Array<ChangeSetClientControlReceipt?>(repeating: nil, count: ChangeSetClientRegistry.controlReceiptCapacity)
        receipts[0] = ChangeSetClientControlReceipt(
            controlRequestID: uuid(60),
            proofIDDigest: digest(60),
            action: .allocate,
            resultDigest: digest(63),
            registryGeneration: generation,
            clientID: slots[0].clientID,
            slotIndex: 0,
            slotGeneration: 9,
            currentEpoch: 3,
            expiresAt: clock.now().addingTimeInterval(300)
        )
        return ChangeSetLegacyRegistrySnapshot(
            rootIdentityDigest: digest(250),
            registryGeneration: generation,
            slots: slots,
            controlReceipts: receipts
        )
    }
}

private func XCTAssertRegistryError<T>(
    _ code: ChangeSetClientRegistryError.Code,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> T
) async {
    do {
        _ = try await body()
        XCTFail("expected \(code.rawValue)", file: file, line: line)
    } catch let error as ChangeSetClientRegistryError {
        XCTAssertEqual(error.code, code, file: file, line: line)
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}
