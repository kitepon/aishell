import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import AIShellCore

final class LegacyControlCompatStoreTests: XCTestCase {
    func testRecordPersistsExactReplayAndConsumesProofAcrossRestart() async throws {
        let fixture = try Fixture()
        let store = try fixture.store()
        try await store.importLegacy(fixture.emptySnapshot())

        let recorded = try await store.record(
            controlRequestID: fixture.requestID,
            requestDigest: fixture.requestDigest,
            proofID: fixture.proofID,
            result: fixture.result,
            expiresAt: fixture.now.addingTimeInterval(60),
            now: fixture.now)
        XCTAssertEqual(recorded, fixture.result)

        let restarted = try fixture.store()
        let replay = try await restarted.record(
            controlRequestID: fixture.requestID,
            requestDigest: fixture.requestDigest,
            proofID: fixture.proofID,
            result: fixture.result,
            expiresAt: fixture.now.addingTimeInterval(120),
            now: fixture.now)
        XCTAssertEqual(replay, fixture.result)
        let proofConsumedAfterRestart = await restarted.consumedOwnerProof(fixture.proofID)
        XCTAssertTrue(proofConsumedAfterRestart)

        await XCTAssertCompatError(.requestConflict) {
            _ = try await restarted.record(
                controlRequestID: fixture.requestID,
                requestDigest: fixture.digest("different-request"),
                proofID: "other-proof",
                result: fixture.result,
                expiresAt: fixture.now.addingTimeInterval(60),
                now: fixture.now)
        }
        await XCTAssertCompatError(.proofConsumed) {
            _ = try await restarted.record(
                controlRequestID: "control-request-2",
                requestDigest: fixture.digest("request-2"),
                proofID: fixture.proofID,
                result: ApplyChangeSetControlResult(
                    controlRequestID: "control-request-2", client: nil, transactionResult: nil),
                expiresAt: fixture.now.addingTimeInterval(60),
                now: fixture.now)
        }
    }

    func testRecordCrashAfterRenameIsExactlyRestartable() async throws {
        let fixture = try Fixture()
        let initial = try fixture.store()
        try await initial.importLegacy(fixture.emptySnapshot())

        let crashing = try fixture.store(failurePoint: .afterRename)
        await XCTAssertCompatError(.storeCorrupt) {
            _ = try await crashing.record(
                controlRequestID: fixture.requestID,
                requestDigest: fixture.requestDigest,
                proofID: fixture.proofID,
                result: fixture.result,
                expiresAt: fixture.now.addingTimeInterval(60),
                now: fixture.now)
        }

        let restarted = try fixture.store()
        let replay = try await restarted.lookup(
            controlRequestID: fixture.requestID,
            requestDigest: fixture.requestDigest,
            now: fixture.now)
        XCTAssertEqual(replay, .replay(fixture.result))
        let proofConsumedAfterCrash = await restarted.consumedOwnerProof(fixture.proofID)
        XCTAssertTrue(proofConsumedAfterCrash)
    }

    func testLegacyReceiptExactReplaySurvivesRestartAndDigestConflictFailsClosed() async throws {
        let fixture = try Fixture()
        let snapshot = fixture.snapshot(expiresAt: fixture.now.addingTimeInterval(60))
        let store = try fixture.store()
        try await store.importLegacy(snapshot)

        let firstReplay = try await store.lookup(
            controlRequestID: fixture.requestID, requestDigest: fixture.requestDigest, now: fixture.now)
        XCTAssertEqual(firstReplay, .replay(fixture.result))
        let restarted = try fixture.store()
        let restartedReplay = try await restarted.lookup(
            controlRequestID: fixture.requestID, requestDigest: fixture.requestDigest, now: fixture.now)
        XCTAssertEqual(restartedReplay, .replay(fixture.result))
        await XCTAssertCompatError(.requestConflict) {
            _ = try await restarted.lookup(
                controlRequestID: fixture.requestID, requestDigest: fixture.digest("different"), now: fixture.now)
        }
        let proofConsumed = await restarted.consumedOwnerProof(fixture.proofID)
        XCTAssertTrue(proofConsumed)
    }

    func testImportIsBoundToAuthenticatedSourceDigestAndExactRetryOnly() async throws {
        let fixture = try Fixture()
        let store = try fixture.store()
        let snapshot = fixture.snapshot(expiresAt: fixture.now.addingTimeInterval(60))
        try await store.importLegacy(snapshot)
        try await store.importLegacy(snapshot)

        let changed = LegacyControlCompatSnapshot(
            sourceDigest: fixture.digest("other-source"), receipts: snapshot.receipts,
            consumedOwnerProofIDs: snapshot.consumedOwnerProofIDs)
        await XCTAssertCompatError(.importConflict) { try await store.importLegacy(changed) }

        let bank = fixture.bank("a")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: bank)) as? [String: Any])
        object["sourceDigest"] = fixture.digest("substituted-source")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: bank)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bank.path)
        XCTAssertThrowsError(try fixture.store()) { error in
            XCTAssertEqual((error as? LegacyControlCompatStoreError)?.code, .storeCorrupt)
        }
    }

    func testExpiryCleanupRemovesPayloadButNeverReleasesProofConsumption() async throws {
        let fixture = try Fixture(receiptCapacity: 2)
        let store = try fixture.store()
        try await store.importLegacy(fixture.snapshot(expiresAt: fixture.now.addingTimeInterval(-1)))

        let expired = try await store.lookup(
            controlRequestID: fixture.requestID, requestDigest: fixture.requestDigest, now: fixture.now)
        XCTAssertEqual(expired, .expired)
        let countBeforeCleanup = await store.unexpiredReceiptCount(now: fixture.now)
        let capacityBeforeCleanup = await store.remainingReceiptCapacity(now: fixture.now)
        let removed = try await store.cleanupExpired(now: fixture.now)
        let missing = try await store.lookup(
            controlRequestID: fixture.requestID, requestDigest: fixture.requestDigest, now: fixture.now)
        let proofConsumed = await store.consumedOwnerProof(fixture.proofID)
        XCTAssertEqual(countBeforeCleanup, 0)
        XCTAssertEqual(capacityBeforeCleanup, 2)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(missing, .missing)
        XCTAssertTrue(proofConsumed)

        let restarted = try fixture.store()
        let restartedProofConsumed = await restarted.consumedOwnerProof(fixture.proofID)
        let restartedCount = await restarted.unexpiredReceiptCount(now: fixture.now)
        XCTAssertTrue(restartedProofConsumed)
        XCTAssertEqual(restartedCount, 0)
    }

    func testUnexpiredCapacityCountsLegacyReceiptsWithoutOffByOne() async throws {
        let fixture = try Fixture(receiptCapacity: 1)
        let store = try fixture.store()
        try await store.importLegacy(fixture.snapshot(expiresAt: fixture.now.addingTimeInterval(60)))
        let count = await store.unexpiredReceiptCount(now: fixture.now)
        let remaining = await store.remainingReceiptCapacity(now: fixture.now)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(remaining, 0)
        await XCTAssertCompatError(.capacityExceeded) {
            try await store.requireReceiptCapacity(additionalCount: 1, now: fixture.now)
        }
        try await store.requireReceiptCapacity(additionalCount: 0, now: fixture.now)
    }

    func testCrashBeforeAndAfterRenameAreExactlyRestartable() async throws {
        let before = try Fixture()
        let snapshot = before.snapshot(expiresAt: before.now.addingTimeInterval(60))
        let beforeCrash = try before.store(failurePoint: .beforeRename)
        await XCTAssertCompatError(.storeCorrupt) { try await beforeCrash.importLegacy(snapshot) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: before.bank("a").path))
        let beforeRestart = try before.store()
        try await beforeRestart.importLegacy(snapshot)
        let restartedDigest = await beforeRestart.sourceDigest()
        XCTAssertEqual(restartedDigest, snapshot.sourceDigest)

        let after = try Fixture()
        let afterSnapshot = after.snapshot(expiresAt: after.now.addingTimeInterval(60))
        let afterCrash = try after.store(failurePoint: .afterRename)
        await XCTAssertCompatError(.storeCorrupt) { try await afterCrash.importLegacy(afterSnapshot) }
        let afterRestart = try after.store()
        try await afterRestart.importLegacy(afterSnapshot)
        let replay = try await afterRestart.lookup(
            controlRequestID: after.requestID, requestDigest: after.requestDigest, now: after.now)
        XCTAssertEqual(replay, .replay(after.result))
    }

    func testPartialNewestBankFallsBackToPreviousAuthenticatedGeneration() async throws {
        let fixture = try Fixture()
        let store = try fixture.store()
        try await store.importLegacy(fixture.snapshot(expiresAt: fixture.now.addingTimeInterval(-1)))
        let removed = try await store.cleanupExpired(now: fixture.now)
        XCTAssertEqual(removed, 1)
        try Data("partial".utf8).write(to: fixture.bank("b"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.bank("b").path)

        let restarted = try fixture.store()
        let proofConsumed = await restarted.consumedOwnerProof(fixture.proofID)
        let count = await restarted.unexpiredReceiptCount(now: fixture.now)
        let lookup = try await restarted.lookup(
            controlRequestID: fixture.requestID, requestDigest: fixture.requestDigest, now: fixture.now)
        XCTAssertTrue(proofConsumed)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(lookup, .expired)
    }

    func testCiphertextTamperAndBothInvalidBanksFailClosed() async throws {
        let fixture = try Fixture()
        let store = try fixture.store()
        try await store.importLegacy(fixture.snapshot(expiresAt: fixture.now.addingTimeInterval(-1)))
        _ = try await store.cleanupExpired(now: fixture.now)
        try fixture.flipByte(in: fixture.bank("a"))
        try fixture.flipByte(in: fixture.bank("b"))
        XCTAssertThrowsError(try fixture.store()) { error in
            XCTAssertEqual((error as? LegacyControlCompatStoreError)?.code, .storeCorrupt)
        }
    }

    func testAuthenticatedBanksWithDifferentSourceDigestFailClosed() async throws {
        let target = try Fixture()
        let targetStore = try target.store()
        try await targetStore.importLegacy(target.snapshot(expiresAt: target.now.addingTimeInterval(-1)))

        let donor = try Fixture(keyData: target.keyData, sourceDigest: target.digest("other-source"))
        let donorStore = try donor.store()
        try await donorStore.importLegacy(donor.snapshot(expiresAt: donor.now.addingTimeInterval(-1)))
        _ = try await donorStore.cleanupExpired(now: donor.now)
        try donor.copyBank("b", to: target.bank("b"))

        XCTAssertThrowsError(try target.store()) { error in
            XCTAssertEqual((error as? LegacyControlCompatStoreError)?.code, .storeCorrupt)
        }
    }

    func testAuthenticatedBanksRejectProofShrinkAndReceiptMutation() async throws {
        let proofTarget = try Fixture()
        let proofTargetStore = try proofTarget.store()
        let proofSnapshot = proofTarget.snapshot(
            expiresAt: proofTarget.now.addingTimeInterval(-1), proofIDs: [proofTarget.proofID, "proof-2"])
        try await proofTargetStore.importLegacy(proofSnapshot)

        let proofDonor = try Fixture(keyData: proofTarget.keyData, sourceDigest: proofTarget.sourceDigest)
        let proofDonorStore = try proofDonor.store()
        try await proofDonorStore.importLegacy(
            proofDonor.snapshot(expiresAt: proofDonor.now.addingTimeInterval(-1), proofIDs: [proofDonor.proofID]))
        _ = try await proofDonorStore.cleanupExpired(now: proofDonor.now)
        try proofDonor.copyBank("b", to: proofTarget.bank("b"))
        XCTAssertThrowsError(try proofTarget.store()) { error in
            XCTAssertEqual((error as? LegacyControlCompatStoreError)?.code, .storeCorrupt)
        }

        let receiptTarget = try Fixture()
        let receiptTargetStore = try receiptTarget.store()
        try await receiptTargetStore.importLegacy(
            receiptTarget.snapshot(expiresAt: receiptTarget.now.addingTimeInterval(60)))
        let receiptDonor = try Fixture(keyData: receiptTarget.keyData, sourceDigest: receiptTarget.sourceDigest)
        let receiptDonorStore = try receiptDonor.store()
        try await receiptDonorStore.importLegacy(
            receiptDonor.snapshot(expiresAt: receiptDonor.now.addingTimeInterval(120)))
        try receiptDonor.copyBank("a", to: receiptTarget.bank("b"))
        XCTAssertThrowsError(try receiptTarget.store()) { error in
            XCTAssertEqual((error as? LegacyControlCompatStoreError)?.code, .storeCorrupt)
        }
    }

    func testAuthenticatedGenerationGapFailsClosed() async throws {
        let target = try Fixture()
        let targetStore = try target.store()
        try await targetStore.importLegacy(target.snapshot(expiresAt: target.now.addingTimeInterval(300)))

        let donor = try Fixture(keyData: target.keyData, sourceDigest: target.sourceDigest)
        let donorStore = try donor.store()
        let receipts = donor.twoReceiptSnapshot(
            firstExpiry: donor.now.addingTimeInterval(10), secondExpiry: donor.now.addingTimeInterval(20))
        try await donorStore.importLegacy(receipts)
        _ = try await donorStore.cleanupExpired(now: donor.now.addingTimeInterval(15))
        _ = try await donorStore.cleanupExpired(now: donor.now.addingTimeInterval(25))
        try donor.copyBank("a", to: target.bank("b"))

        XCTAssertThrowsError(try target.store()) { error in
            XCTAssertEqual((error as? LegacyControlCompatStoreError)?.code, .storeCorrupt)
        }
    }

    func testSymlinkOversizeAndTruncatedBanksFailClosed() async throws {
        let symlinkFixture = try Fixture()
        try FileManager.default.createDirectory(
            at: symlinkFixture.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let outside = symlinkFixture.directory.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString)")
        try Data("not-a-bank".utf8).write(to: outside)
        XCTAssertEqual(symlink(outside.path, symlinkFixture.bank("a").path), 0)
        XCTAssertThrowsError(try symlinkFixture.store()) { error in
            XCTAssertEqual((error as? LegacyControlCompatStoreError)?.code, .storeCorrupt)
        }

        let oversizeFixture = try Fixture()
        try FileManager.default.createDirectory(
            at: oversizeFixture.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let oversized = oversizeFixture.bank("a")
        let descriptor = open(oversized.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(ftruncate(descriptor, off_t(LegacyControlCompatStore.maximumBankByteCount + 1)), 0)
        XCTAssertEqual(close(descriptor), 0)
        XCTAssertThrowsError(try oversizeFixture.store()) { error in
            XCTAssertEqual((error as? LegacyControlCompatStoreError)?.code, .storeCorrupt)
        }

        let truncatedFixture = try Fixture()
        let truncatedStore = try truncatedFixture.store()
        try await truncatedStore.importLegacy(
            truncatedFixture.snapshot(expiresAt: truncatedFixture.now.addingTimeInterval(60)))
        let bytes = try Data(contentsOf: truncatedFixture.bank("a"))
        try bytes.prefix(bytes.count / 2).write(to: truncatedFixture.bank("a"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: truncatedFixture.bank("a").path)
        XCTAssertThrowsError(try truncatedFixture.store()) { error in
            XCTAssertEqual((error as? LegacyControlCompatStoreError)?.code, .storeCorrupt)
        }
    }

    func testPathSwapAfterOpenReadsPinnedDescriptorNotReplacementPath() async throws {
        let target = try Fixture()
        let targetStore = try target.store()
        try await targetStore.importLegacy(target.snapshot(expiresAt: target.now.addingTimeInterval(60)))

        let donor = try Fixture(keyData: target.keyData, sourceDigest: target.digest("replacement-source"))
        let donorStore = try donor.store()
        try await donorStore.importLegacy(donor.snapshot(expiresAt: donor.now.addingTimeInterval(60)))
        let replacement = target.directory.appendingPathComponent("replacement.enc")
        try Data(contentsOf: donor.bank("a")).write(to: replacement)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: replacement.path)
        let pinnedOriginal = target.directory.appendingPathComponent("pinned-original.enc")

        let swapped = try target.store(loadHook: { openedURL in
            guard openedURL.lastPathComponent == "legacy-control-compat-a.enc" else { return }
            guard link(openedURL.path, pinnedOriginal.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard rename(replacement.path, openedURL.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        })
        let loadedDigest = await swapped.sourceDigest()
        XCTAssertEqual(loadedDigest, target.sourceDigest)
        XCTAssertNotEqual(loadedDigest, donor.sourceDigest)
    }
}

private struct Fixture {
    let directory: URL
    let keyData: Data
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let requestID = "control-request-1"
    let proofID = "owner-proof-1"
    let requestDigest: String
    let sourceDigest: String
    let result: ApplyChangeSetControlResult
    let receiptCapacity: Int

    init(
        receiptCapacity: Int = 128,
        keyData: Data = Data(SHA256.hash(data: Data("legacy-control-test-key".utf8))),
        sourceDigest: String? = nil
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-control-compat-\(UUID().uuidString)", isDirectory: true)
        self.receiptCapacity = receiptCapacity
        self.keyData = keyData
        requestDigest = Self.digest("request")
        self.sourceDigest = sourceDigest ?? Self.digest("source")
        result = ApplyChangeSetControlResult(
            controlRequestID: requestID,
            client: ApplyChangeSetClient(clientID: "legacy-client", epoch: 7, slot: 3),
            transactionResult: nil)
    }

    func store(
        failurePoint: LegacyControlCompatStore.FailurePoint? = nil,
        loadHook: (@Sendable (URL) throws -> Void)? = nil
    ) throws -> LegacyControlCompatStore {
        try LegacyControlCompatStore(
            directory: directory, keyData: keyData,
            receiptCapacity: receiptCapacity, failurePoint: failurePoint, loadHook: loadHook)
    }

    func snapshot(expiresAt: Date, proofIDs: Set<String>? = nil) -> LegacyControlCompatSnapshot {
        LegacyControlCompatSnapshot(
            sourceDigest: sourceDigest,
            receipts: [requestID: LegacyControlCompatReceipt(
                expiresAt: expiresAt, requestDigest: requestDigest, result: result)],
            consumedOwnerProofIDs: proofIDs ?? [proofID])
    }

    func emptySnapshot() -> LegacyControlCompatSnapshot {
        LegacyControlCompatSnapshot(
            sourceDigest: sourceDigest,
            receipts: [:],
            consumedOwnerProofIDs: [])
    }

    func twoReceiptSnapshot(firstExpiry: Date, secondExpiry: Date) -> LegacyControlCompatSnapshot {
        let secondID = "control-request-2"
        let secondResult = ApplyChangeSetControlResult(
            controlRequestID: secondID,
            client: ApplyChangeSetClient(clientID: "legacy-client-2", epoch: 8, slot: 4),
            transactionResult: nil)
        return LegacyControlCompatSnapshot(
            sourceDigest: sourceDigest,
            receipts: [
                requestID: LegacyControlCompatReceipt(
                    expiresAt: firstExpiry, requestDigest: requestDigest, result: result),
                secondID: LegacyControlCompatReceipt(
                    expiresAt: secondExpiry, requestDigest: digest("request-2"), result: secondResult)
            ],
            consumedOwnerProofIDs: [proofID, "proof-2"])
    }

    func bank(_ name: String) -> URL {
        directory.appendingPathComponent("legacy-control-compat-\(name).enc")
    }

    func digest(_ value: String) -> String { Self.digest(value) }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func flipByte(in url: URL) throws {
        var bytes = try Data(contentsOf: url)
        bytes[bytes.index(before: bytes.endIndex)] ^= 0xff
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func copyBank(_ name: String, to destination: URL) throws {
        let data = try Data(contentsOf: bank(name))
        try data.write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}

private func XCTAssertCompatError(
    _ code: LegacyControlCompatStoreError.Code,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("expected LegacyControlCompatStoreError", file: file, line: line)
    } catch let error as LegacyControlCompatStoreError {
        XCTAssertEqual(error.code, code, file: file, line: line)
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}
