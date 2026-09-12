import XCTest
@testable import AIShellCore

final class EvidenceStoreTests: XCTestCase {
    func testFindCompleteArtifactReusesVerifiedStableHandle() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let store = EvidenceStore(baseDirectory: fixture.base.appendingPathComponent("evidence"))
        let metadata = try await store.store(data: Data("durable".utf8), kind: "apply-change-set-diff", producer: "ApplyChangeSetService", retentionSeconds: 60)
        let found = try await store.findCompleteArtifact(kind: metadata.kind, producer: metadata.producer, sha256: metadata.sha256)
        XCTAssertEqual(found?.handle, metadata.handle)
        XCTAssertEqual(found?.sha256, metadata.sha256)
        XCTAssertEqual(found?.sizeBytes, metadata.sizeBytes)
        let missing = try await store.findCompleteArtifact(kind: metadata.kind, producer: metadata.producer, sha256: String(repeating: "0", count: 64))
        XCTAssertNil(missing)
    }

    func testStoresLosslessArtifactAndReadsBoundedSlices() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let store = EvidenceStore(baseDirectory: fixture.base.appendingPathComponent("evidence"))
        let text = "alpha\nbeta needle\ngamma\ndelta\n"

        let metadata = try await store.store(
            text: text,
            kind: "stderr",
            producer: "test",
            retentionSeconds: 60
        )

        XCTAssertEqual(metadata.sizeBytes, text.utf8.count)
        XCTAssertEqual(metadata.lineCount, 4)
        XCTAssertFalse(metadata.sha256.isEmpty)

        let range = try await store.read(
            handle: metadata.handle,
            mode: .range(offset: 0, length: 5),
            byteBudget: 5
        )
        XCTAssertEqual(range.text, "alpha")
        XCTAssertEqual(range.returnedBytes, 5)
        XCTAssertGreaterThan(range.omittedBytes, 0)

        let tail = try await store.read(
            handle: metadata.handle,
            mode: .tail(lines: 2),
            byteBudget: 1_024
        )
        XCTAssertEqual(tail.text, "gamma\ndelta\n")

        let around = try await store.read(
            handle: metadata.handle,
            mode: .around(pattern: "needle", contextLines: 1),
            byteBudget: 1_024
        )
        XCTAssertTrue(around.text?.contains("beta needle") == true)
        XCTAssertEqual(around.matchLine, 2)
    }

    func testExpiredHandleFailsExplicitlyWithoutDeletingMetadataEarly() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000) }
        let clock = Clock()
        let store = EvidenceStore(
            baseDirectory: fixture.base.appendingPathComponent("evidence"),
            clock: { clock.now }
        )
        let metadata = try await store.store(
            text: "complete log",
            kind: "stdout",
            producer: "test",
            retentionSeconds: 10
        )
        clock.now = Date(timeIntervalSince1970: 1_011)
        let verified = try await store.verifyCompleteArtifact(
            handle: metadata.handle,
            kind: metadata.kind,
            producer: metadata.producer,
            sha256: metadata.sha256
        )
        XCTAssertEqual(verified.handle, metadata.handle)
        let finalized = try await store.finalizeArtifact(handle: metadata.handle, expiresAt: metadata.expiresAt)
        XCTAssertEqual(finalized.expiresAt, metadata.expiresAt)
        _ = try await store.garbageCollectExpired()

        do {
            _ = try await store.read(handle: metadata.handle, mode: .tail(lines: 10), byteBudget: 1_024)
            XCTFail("期限切れhandleを読み取ってしまいました。")
        } catch {
            guard case AIShellError.handleExpired(let handle) = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
            XCTAssertEqual(handle, metadata.handle)
        }
    }

    func testBinaryRangeIsReturnedLosslesslyAsBase64() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let store = EvidenceStore(baseDirectory: fixture.base.appendingPathComponent("evidence"))
        let bytes = Data([0x00, 0xff, 0x41, 0x0a])
        let metadata = try await store.store(data: bytes, kind: "binary", producer: "test")

        let slice = try await store.read(
            handle: metadata.handle,
            mode: .range(offset: 0, length: bytes.count),
            byteBudget: bytes.count
        )

        XCTAssertEqual(slice.encoding, "base64")
        XCTAssertNil(slice.text)
        XCTAssertEqual(Data(base64Encoded: slice.base64 ?? ""), bytes)
    }
}
