import Foundation
import XCTest
@testable import AIShellCore

final class ChangeSetTransactionStoreTests: XCTestCase {
    func testTransactionSnapshotsAreEncryptedOwnerOnlyAndRestartReadable() async throws {
        let fixture = try Fixture()
        let store = try fixture.makeStore()
        let preparing = fixture.snapshot(state: .preparing, payload: Data("secret-payload".utf8))

        try await store.persistTransition(preparing)

        let transactionDirectory = fixture.transactionDirectory
        let encrypted = try Data(contentsOf: transactionDirectory.appendingPathComponent("snapshot.enc"))
        XCTAssertFalse(String(data: encrypted, encoding: .utf8)?.contains("secret-payload") == true)
        XCTAssertEqual(try permissions(fixture.storeDirectory), 0o700)
        XCTAssertEqual(try permissions(transactionDirectory), 0o700)
        XCTAssertEqual(try permissions(transactionDirectory.appendingPathComponent("snapshot.enc")), 0o600)

        let restarted = try fixture.makeStore()
        let loaded = try await restarted.load(fixture.transactionID)
        let active = try await restarted.listActive()
        XCTAssertEqual(loaded, preparing)
        XCTAssertEqual(active, [preparing])
    }

    func testIncompleteJournalTailIsDiscardedAndNextTransitionRemainsValid() async throws {
        let fixture = try Fixture()
        let store = try fixture.makeStore()
        let preparing = fixture.snapshot(state: .preparing)
        try await store.persistTransition(preparing)
        try Data("{\"torn\":".utf8).append(to: fixture.journalURL)

        let restarted = try fixture.makeStore()
        let loadedPreparing = try await restarted.load(fixture.transactionID)
        XCTAssertEqual(loadedPreparing, preparing)
        let preparedRequest = fixture.snapshot(state: .prepared)
        try await restarted.persistTransition(preparedRequest, expectedState: .preparing)

        let restartedAgain = try fixture.makeStore()
        let loadedPrepared = try await restartedAgain.load(fixture.transactionID)
        XCTAssertEqual(loadedPrepared?.state, .prepared)
        XCTAssertEqual(loadedPrepared?.revision, 1)
    }

    func testWALAheadOfPreviousSnapshotIsReconciledAfterRestart() async throws {
        let fixture = try Fixture()
        let store = try fixture.makeStore()
        try await store.persistTransition(fixture.snapshot(state: .preparing))
        let snapshotURL = fixture.transactionDirectory.appendingPathComponent("snapshot.enc")
        let previousSnapshot = try Data(contentsOf: snapshotURL)
        let preparedRequest = fixture.snapshot(state: .prepared)
        try await store.persistTransition(preparedRequest, expectedState: .preparing)

        // WAL fsync後・snapshot atomic replace前のcrashを、直前世代snapshotへ戻して再現する。
        try previousSnapshot.write(to: snapshotURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)

        let restarted = try fixture.makeStore()
        let reconciled = try await restarted.load(fixture.transactionID)
        XCTAssertEqual(reconciled?.state, .prepared)
        XCTAssertEqual(reconciled?.revision, 1)
        let restartedAgain = try fixture.makeStore()
        let durable = try await restartedAgain.load(fixture.transactionID)
        XCTAssertEqual(durable, reconciled)
    }

    func testCompleteJournalCorruptionFailsClosedWithoutDeletingMaterial() async throws {
        let fixture = try Fixture()
        let store = try fixture.makeStore()
        try await store.persistTransition(fixture.snapshot(state: .preparing))
        try Data("{\"complete\":\"but-invalid\"}\n".utf8).append(to: fixture.journalURL)

        let restarted = try fixture.makeStore()
        await XCTAssertThrowsStoreError(.corrupt("journal decode failed at 1")) {
            _ = try await restarted.listActive()
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.transactionDirectory.path))
    }

    func testStaleAndBackwardTransitionsAreRejected() async throws {
        let fixture = try Fixture()
        let store = try fixture.makeStore()
        try await store.persistTransition(fixture.snapshot(state: .preparing))
        try await store.persistTransition(fixture.snapshot(state: .prepared), expectedState: .preparing)
        try await store.persistTransition(fixture.snapshot(state: .prepared), expectedState: .prepared)

        await XCTAssertThrowsStoreError(.staleTransition(expected: .preparing, actual: .prepared)) {
            try await store.persistTransition(fixture.snapshot(state: .commitDecided), expectedState: .preparing)
        }
        await XCTAssertThrowsStoreError(.invalidTransition(from: .prepared, to: .preparing)) {
            try await store.persistTransition(fixture.snapshot(state: .preparing), expectedState: .prepared)
        }
    }

    func testRuntimeReceiptsStayBoundedAndTerminalCleanupRemovesAllReferences() async throws {
        let fixture = try Fixture(maxRuntimeReceipts: 2, terminalRetention: 10)
        let store = try fixture.makeStore()
        for index in 0..<3 {
            let id = ApplyChangeSetTransactionID("transaction-\(index)")
            try await store.persistTransition(fixture.snapshot(id: id, state: .preparing))
            try await store.appendRuntimeReceipt(.init(
                transactionID: id,
                cursor: .init(root: fixture.root.path, generation: "g", sequence: UInt64(index + 1)),
                paths: ["file-\(index)"], digest: "digest-\(index)",
                recordedAt: Date(timeIntervalSince1970: Double(index)), terminalAt: Date(timeIntervalSince1970: Double(index))
            ))
        }
        let receiptIDs = try await store.runtimeReceipts().map(\.transactionID.rawValue)
        XCTAssertEqual(receiptIDs, ["transaction-1", "transaction-2"])

        let terminal = fixture.snapshot(id: fixture.transactionID, state: .abortedBeforeSideEffect, terminalAt: Date(timeIntervalSince1970: 100))
        try await store.persistTransition(fixture.snapshot(state: .preparing))
        try await store.persistTransition(terminal, expectedState: .preparing)
        let removed = try await store.cleanup(now: Date(timeIntervalSince1970: 111))
        XCTAssertTrue(removed.contains(fixture.transactionID))
        let cleaned = try await store.load(fixture.transactionID)
        XCTAssertNil(cleaned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.transactionDirectory.path))
    }

    func testUnknownOrphanDirectoryFailsClosed() async throws {
        let fixture = try Fixture()
        let orphan = fixture.storeDirectory.appendingPathComponent("transactions/orphan", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.storeDirectory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: orphan.deletingLastPathComponent().path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: orphan.path)
        let store = try fixture.makeStore()
        await XCTAssertThrowsStoreError(.orphan("orphan")) { _ = try await store.listActive() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testBoundedReferencesExposeTerminalRetentionAndDigestsAcrossRestartAndCleanup() async throws {
        let fixture = try Fixture(terminalRetention: 10)
        let store = try fixture.makeStore()
        let activeID = ApplyChangeSetTransactionID("active-transaction")
        let terminalID = ApplyChangeSetTransactionID("terminal-transaction")
        try await store.persistTransition(fixture.snapshot(id: activeID, state: .preparing, payload: Data(repeating: 0xAA, count: 4_096)))
        try await store.persistTransition(fixture.snapshot(id: terminalID, state: .preparing))
        try await store.persistTransition(
            fixture.snapshot(id: terminalID, state: .abortedBeforeSideEffect, terminalAt: Date(timeIntervalSince1970: 100)),
            expectedState: .preparing
        )
        try await store.appendRuntimeReceipt(.init(
            transactionID: terminalID,
            cursor: .init(root: fixture.root.path, generation: "g", sequence: 9),
            paths: ["terminal.txt"], digest: "runtime-digest",
            recordedAt: Date(timeIntervalSince1970: 100), terminalAt: Date(timeIntervalSince1970: 100)
        ))

        let references = try await store.listReferences(now: Date(timeIntervalSince1970: 111))
        XCTAssertEqual(references.map(\.transactionID.rawValue), ["active-transaction", "terminal-transaction"])
        XCTAssertEqual(references[0].state, .preparing)
        XCTAssertNil(references[0].terminalAt)
        XCTAssertFalse(references[0].cleanupCandidate)
        XCTAssertEqual(references[1].state, .abortedBeforeSideEffect)
        XCTAssertEqual(references[1].retentionExpiresAt, Date(timeIntervalSince1970: 110))
        XCTAssertTrue(references[1].cleanupCandidate)
        XCTAssertEqual(references[1].artifactDigests, ["artifact-digest"])
        XCTAssertEqual(references[1].runtimeReceiptDigest, "runtime-digest")
        XCTAssertEqual(references[1].referenceDigest.count, 64)

        let restarted = try fixture.makeStore()
        let terminal = try await restarted.listTerminalReferences(now: Date(timeIntervalSince1970: 111))
        XCTAssertEqual(terminal, [references[1]])
        _ = try await restarted.cleanup(now: Date(timeIntervalSince1970: 111))
        let afterCleanup = try await restarted.listReferences(now: Date(timeIntervalSince1970: 111))
        XCTAssertEqual(afterCleanup.map(\.transactionID.rawValue), ["active-transaction"])
    }

    func testSameStateSnapshotUpdatesUseRevisionCASAndReplayOnlyExactContent() async throws {
        let fixture = try Fixture()
        let store = try fixture.makeStore()
        try await store.persistTransition(fixture.snapshot(state: .preparing, payload: Data("v0".utf8)))
        let snapshotURL = fixture.transactionDirectory.appendingPathComponent("snapshot.enc")
        let revisionZeroBytes = try Data(contentsOf: snapshotURL)
        let references = [ChangeSetTransactionStore.Reference(kind: "artifact", identifier: "v1", digest: "digest-v1")]

        let revisionOne = try await store.updateSnapshot(
            transactionID: fixture.transactionID, expectedState: .preparing, expectedRevision: 0,
            payload: Data("v1".utf8), references: references, manifestDigest: "manifest-v1"
        )
        XCTAssertEqual(revisionOne, 1)
        let replayRevision = try await store.updateSnapshot(
            transactionID: fixture.transactionID, expectedState: .preparing, expectedRevision: 0,
            payload: Data("v1".utf8), references: references, manifestDigest: "manifest-v1"
        )
        XCTAssertEqual(replayRevision, 1)

        await XCTAssertThrowsStoreError(.snapshotUpdateConflict(expectedRevision: 0)) {
            try await store.updateSnapshot(
                transactionID: fixture.transactionID, expectedState: .preparing, expectedRevision: 0,
                payload: Data("different".utf8), references: references, manifestDigest: "manifest-v1"
            )
        }
        await XCTAssertThrowsStoreError(.staleRevision(expected: 9, actual: 1)) {
            try await store.updateSnapshot(
                transactionID: fixture.transactionID, expectedState: .preparing, expectedRevision: 9,
                payload: Data("v10".utf8), references: references, manifestDigest: "manifest-v10"
            )
        }

        // same-state WAL fsync後・snapshot replace前のcrashも、WALのrevision 1へ回復する。
        try revisionZeroBytes.write(to: snapshotURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
        let restarted = try fixture.makeStore()
        let loaded = try await restarted.load(fixture.transactionID)
        XCTAssertEqual(loaded?.state, .preparing)
        XCTAssertEqual(loaded?.revision, 1)
        XCTAssertEqual(loaded?.payload, Data("v1".utf8))
        XCTAssertEqual(loaded?.references, references)
    }

    func testLegacyImportPreservesArbitraryStatesAndIsExactlyIdempotent() async throws {
        let fixture = try Fixture()
        let store = try fixture.makeStore()
        let snapshots = [
            fixture.snapshot(id: .init("a-prepared"), state: .prepared, payload: Data("prepared".utf8), revision: 4),
            fixture.snapshot(id: .init("b-decided"), state: .commitDecided, payload: Data("decided".utf8), revision: 7),
            fixture.snapshot(id: .init("c-recovery"), state: .recoveryRequired, payload: Data("recovery".utf8), revision: 8),
            fixture.snapshot(id: .init("d-terminal"), state: .committed, payload: Data("terminal".utf8), terminalAt: Date(timeIntervalSince1970: 100), revision: 12),
        ]
        let importedReceipts = [ChangeSetTransactionStore.RuntimeReceipt(
            transactionID: .init("d-terminal"),
            cursor: .init(root: fixture.root.path, generation: "legacy", sequence: 42),
            paths: ["legacy.txt"], digest: "legacy-runtime-digest",
            recordedAt: Date(timeIntervalSince1970: 100), terminalAt: Date(timeIntervalSince1970: 100)
        )]

        try await store.importLegacy(snapshots, receipts: importedReceipts, provenance: "legacy-store-digest")
        let loaded = try await store.listReferences(now: Date(timeIntervalSince1970: 101))
        XCTAssertEqual(loaded.map(\.transactionID.rawValue), ["a-prepared", "b-decided", "c-recovery", "d-terminal"])
        XCTAssertEqual(loaded.map(\.revision), [4, 7, 8, 12])
        XCTAssertEqual(loaded.last?.runtimeReceiptDigest, "legacy-runtime-digest")

        // 完了後も同じimportはno-op、異なるpayloadは明示conflict。
        try await store.importLegacy(snapshots, receipts: importedReceipts, provenance: "legacy-store-digest")
        var changed = snapshots
        changed[0] = fixture.snapshot(id: .init("a-prepared"), state: .prepared, payload: Data("changed".utf8), revision: 4)
        await XCTAssertThrowsStoreError(.migrationConflict) {
            try await store.importLegacy(changed, receipts: importedReceipts, provenance: "legacy-store-digest")
        }
    }

    func testLegacyImportCrashBlocksPartialVisibilityAndExactRetryResumes() async throws {
        let fixture = try Fixture()
        let snapshots = [
            fixture.snapshot(id: .init("legacy-1"), state: .prepared, revision: 2),
            fixture.snapshot(id: .init("legacy-2"), state: .recoveryRequired, revision: 5),
        ]
        let crashing = try fixture.makeStore(crashAfterImportedTransactions: 1)
        await XCTAssertThrowsStoreError(.simulatedMigrationCrash(1)) {
            try await crashing.importLegacy(snapshots, receipts: [], provenance: "legacy-crash")
        }
        await XCTAssertThrowsStoreError(.migrationInProgress("legacy import must be resumed with the exact request")) {
            _ = try await crashing.listReferences()
        }
        await XCTAssertThrowsStoreError(.migrationInProgress("legacy import must be resumed with the exact request")) {
            _ = try await crashing.legacyImportReceipt()
        }

        let restarted = try fixture.makeStore()
        try await restarted.importLegacy(snapshots, receipts: [], provenance: "legacy-crash")
        let loaded = try await restarted.listReferences()
        XCTAssertEqual(loaded.map(\.transactionID.rawValue), ["legacy-1", "legacy-2"])
        XCTAssertEqual(loaded.map(\.revision), [2, 5])
    }

    func testLegacyImportReceiptSurvivesEvolutionCleanupAndRestart() async throws {
        let fixture = try Fixture(terminalRetention: 1)
        let emptyStore = try fixture.makeStore()
        let emptyReceipt = try await emptyStore.legacyImportReceipt()
        XCTAssertNil(emptyReceipt)
        let snapshots = [
            fixture.snapshot(id: .init("evolving"), state: .prepared, payload: Data("v1".utf8), revision: 2),
            fixture.snapshot(
                id: .init("cleanup"), state: .committed, terminalAt: Date(timeIntervalSince1970: 100),
                retentionExpiresAt: Date(timeIntervalSince1970: 101), revision: 6
            ),
        ]
        try await emptyStore.importLegacy(snapshots, receipts: [], provenance: "legacy-provenance")
        let loadedReceipt = try await emptyStore.legacyImportReceipt()
        let originalReceipt = try XCTUnwrap(loadedReceipt)
        XCTAssertEqual(originalReceipt.provenance, "legacy-provenance")
        XCTAssertEqual(originalReceipt.requestDigest.count, 64)

        _ = try await emptyStore.updateSnapshot(
            transactionID: .init("evolving"), expectedState: .prepared, expectedRevision: 2,
            payload: Data("v2".utf8), references: snapshots[0].references, manifestDigest: snapshots[0].manifestDigest
        )
        let removed = try await emptyStore.cleanup(now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(removed.map(\.rawValue), ["cleanup"])
        // frozen import requestの再提示は、現在の合法evolution/cleanupを巻き戻さずreceipt replayになる。
        try await emptyStore.importLegacy(snapshots, receipts: [], provenance: "legacy-provenance")
        let evolved = try await emptyStore.load(.init("evolving"))
        XCTAssertEqual(evolved?.payload, Data("v2".utf8))
        let cleaned = try await emptyStore.load(.init("cleanup"))
        XCTAssertNil(cleaned)
        let receiptAfterEvolution = try await emptyStore.legacyImportReceipt()
        XCTAssertEqual(receiptAfterEvolution, originalReceipt)

        let restarted = try fixture.makeStore()
        let restartedReceipt = try await restarted.legacyImportReceipt()
        XCTAssertEqual(restartedReceipt, originalReceipt)
    }

    func testLegacyImportRejectsNonemptyStore() async throws {
        let fixture = try Fixture()
        let store = try fixture.makeStore()
        try await store.persistTransition(fixture.snapshot(state: .preparing))
        await XCTAssertThrowsStoreError(.migrationConflict) {
            try await store.importLegacy(
                [fixture.snapshot(id: .init("legacy"), state: .prepared)],
                receipts: [], provenance: "legacy-nonempty"
            )
        }
    }

    func testRecoveryRequiredCanRollForwardOrRollbackAcrossCrashBoundaries() async throws {
        let rollforwardFixture = try Fixture()
        let rollforward = try rollforwardFixture.makeStore()
        try await rollforward.persistTransition(rollforwardFixture.snapshot(state: .preparing))
        try await rollforward.persistTransition(rollforwardFixture.snapshot(state: .recoveryRequired), expectedState: .preparing)
        let recoverySnapshotURL = rollforwardFixture.transactionDirectory.appendingPathComponent("snapshot.enc")
        let recoveryBytes = try Data(contentsOf: recoverySnapshotURL)
        try await rollforward.persistTransition(rollforwardFixture.snapshot(state: .filesystemCommitted), expectedState: .recoveryRequired)
        try recoveryBytes.write(to: recoverySnapshotURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recoverySnapshotURL.path)
        let rollforwardRestarted = try rollforwardFixture.makeStore()
        let recoveredForward = try await rollforwardRestarted.load(rollforwardFixture.transactionID)
        XCTAssertEqual(recoveredForward?.state, .filesystemCommitted)
        XCTAssertEqual(recoveredForward?.revision, 2)

        let rollbackFixture = try Fixture()
        let rollback = try rollbackFixture.makeStore()
        try await rollback.persistTransition(rollbackFixture.snapshot(state: .preparing))
        try await rollback.persistTransition(rollbackFixture.snapshot(state: .recoveryRequired), expectedState: .preparing)
        try await rollback.persistTransition(rollbackFixture.snapshot(state: .rollbackDecided), expectedState: .recoveryRequired)
        let rollbackDecidedURL = rollbackFixture.transactionDirectory.appendingPathComponent("snapshot.enc")
        let rollbackDecidedBytes = try Data(contentsOf: rollbackDecidedURL)
        try await rollback.persistTransition(
            rollbackFixture.snapshot(
                state: .rolledBack,
                terminalAt: Date(timeIntervalSince1970: 100),
                retentionExpiresAt: Date(timeIntervalSince1970: 101)
            ),
            expectedState: .rollbackDecided
        )
        try rollbackDecidedBytes.write(to: rollbackDecidedURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rollbackDecidedURL.path)
        let rollbackRestarted = try rollbackFixture.makeStore()
        let activeAfterRollback = try await rollbackRestarted.listActive()
        XCTAssertEqual(activeAfterRollback.map(\.state), [.rolledBack])
        let prematureCleanup = try await rollbackRestarted.cleanup(now: Date(timeIntervalSince1970: 500))
        XCTAssertTrue(prematureCleanup.isEmpty)
        let retainedRollback = try await rollbackRestarted.load(rollbackFixture.transactionID)
        XCTAssertEqual(retainedRollback?.state, .rolledBack)
        try await rollbackRestarted.persistTransition(
            rollbackFixture.snapshot(
                state: .abortedBeforeSideEffect,
                terminalAt: Date(timeIntervalSince1970: 100),
                retentionExpiresAt: Date(timeIntervalSince1970: 500)
            ),
            expectedState: .rolledBack
        )
        let recoveredRollback = try await rollbackRestarted.load(rollbackFixture.transactionID)
        XCTAssertEqual(recoveredRollback?.state, .abortedBeforeSideEffect)
        XCTAssertEqual(recoveredRollback?.revision, 4)
    }

    func testExactTransactionRetentionSurvivesLegacyImportRestartAndCleanup() async throws {
        let fixture = try Fixture(terminalRetention: 10)
        let terminal = fixture.snapshot(
            id: .init("long-retention"), state: .committed, payload: Data("retained-evidence".utf8),
            terminalAt: Date(timeIntervalSince1970: 100),
            retentionExpiresAt: Date(timeIntervalSince1970: 500), revision: 9
        )
        let store = try fixture.makeStore()
        try await store.importLegacy([terminal], receipts: [], provenance: "retention-migration")
        _ = try await store.updateSnapshot(
            transactionID: .init("long-retention"), expectedState: .committed, expectedRevision: 9,
            payload: Data("updated-retained-evidence".utf8), references: terminal.references,
            manifestDigest: terminal.manifestDigest
        )
        let earlyCleanup = try await store.cleanup(now: Date(timeIntervalSince1970: 111))
        XCTAssertTrue(earlyCleanup.isEmpty)

        let restarted = try fixture.makeStore()
        let references = try await restarted.listTerminalReferences(now: Date(timeIntervalSince1970: 499))
        XCTAssertEqual(references.first?.retentionExpiresAt, Date(timeIntervalSince1970: 500))
        XCTAssertFalse(references.first?.cleanupCandidate ?? true)
        let retained = try await restarted.load(.init("long-retention"))
        XCTAssertEqual(retained?.payload, Data("updated-retained-evidence".utf8))
        XCTAssertEqual(retained?.retentionExpiresAt, Date(timeIntervalSince1970: 500))

        let removed = try await restarted.cleanup(now: Date(timeIntervalSince1970: 500))
        XCTAssertEqual(removed.map(\.rawValue), ["long-retention"])
        let cleaned = try await restarted.load(.init("long-retention"))
        XCTAssertNil(cleaned)
    }
}

private struct Fixture {
    let root: URL
    let storeDirectory: URL
    let transactionID = ApplyChangeSetTransactionID("transaction-main")
    let key = Data(repeating: 0xA5, count: 32)
    let maxRuntimeReceipts: Int
    let terminalRetention: TimeInterval

    init(maxRuntimeReceipts: Int = 16, terminalRetention: TimeInterval = 60) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("change-set-store-tests-\(UUID().uuidString)", isDirectory: true)
        storeDirectory = root.appendingPathComponent("store", isDirectory: true)
        self.maxRuntimeReceipts = maxRuntimeReceipts
        self.terminalRetention = terminalRetention
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeStore(crashAfterImportedTransactions: Int? = nil) throws -> ChangeSetTransactionStore {
        try ChangeSetTransactionStore(
            directory: storeDirectory, encryptionKey: key,
            maxRuntimeReceipts: maxRuntimeReceipts, terminalRetention: terminalRetention,
            migrationCrashAfterImportedTransactions: crashAfterImportedTransactions
        )
    }

    func snapshot(
        id: ApplyChangeSetTransactionID? = nil,
        state: ApplyChangeSetTransactionState,
        payload: Data = Data("payload".utf8),
        terminalAt: Date? = nil,
        retentionExpiresAt: Date? = nil,
        revision: UInt64 = 0
    ) -> ChangeSetTransactionStore.Snapshot {
        .init(
            transactionID: id ?? transactionID, state: state, manifestDigest: "manifest-digest",
            references: [.init(kind: "artifact", identifier: "artifact-1", digest: "artifact-digest")],
            payload: payload, terminalAt: terminalAt,
            retentionExpiresAt: retentionExpiresAt, revision: revision
        )
    }

    var transactionDirectory: URL {
        storeDirectory.appendingPathComponent("transactions", isDirectory: true)
            .appendingPathComponent(ChangeSetTransactionStore.directoryName(for: transactionID.rawValue), isDirectory: true)
    }

    var journalURL: URL { transactionDirectory.appendingPathComponent("journal.wal") }
}

private func permissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
        try handle.synchronize()
    }
}

private func XCTAssertThrowsStoreError<T>(
    _ expected: ChangeSetTransactionStore.StoreError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as ChangeSetTransactionStore.StoreError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}
