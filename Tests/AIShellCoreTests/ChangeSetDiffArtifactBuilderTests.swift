import CryptoKit
import XCTest
@testable import AIShellCore

final class ChangeSetDiffArtifactBuilderTests: XCTestCase {
    private typealias Builder = ChangeSetDiffArtifactBuilder

    func testBuildBindsManifestRequestCursorAndOrdersByCanonicalPathBytes() throws {
        let changes = [
            Builder.Change(changeID: "delete-z", kind: .delete,
                before: .init(path: "z.txt", identity: "1:3", mode: 0o644, bytes: Data("gone\n".utf8)), after: nil),
            Builder.Change(changeID: "create-a", kind: .create, before: nil,
                after: .init(path: "a.txt", identity: "1:4", mode: 0o600, bytes: Data("new\n".utf8))),
            Builder.Change(changeID: "rename-m", kind: .rename,
                before: .init(path: "old.txt", identity: "1:1", mode: 0o644, bytes: Data("same\n".utf8)),
                after: .init(path: "m.txt", identity: "1:1", mode: 0o644, bytes: Data("same\n".utf8))),
            Builder.Change(changeID: "write-b", kind: .write,
                before: .init(path: "b.txt", identity: "1:2", mode: 0o644, bytes: Data("old\n".utf8)),
                after: .init(path: "b.txt", identity: "1:2", mode: 0o644, bytes: Data("new\n".utf8))),
        ]

        let first = try Builder.build(binding: binding(), changes: changes, previewBudget: .max)
        let second = try Builder.build(binding: binding(), changes: changes.reversed(), previewBudget: .max)

        XCTAssertEqual(first.artifact, second.artifact)
        XCTAssertEqual(first.sha256, sha256(first.artifact))
        XCTAssertEqual(first.header.binding.manifestDigest, String(repeating: "b", count: 64))
        XCTAssertEqual(first.header.binding.requestDigest, String(repeating: "a", count: 64))
        XCTAssertEqual(first.header.changes.map(\.changeID), ["create-a", "write-b", "rename-m", "delete-z"])

        let decoded = try Builder.decode(first.artifact)
        XCTAssertEqual(decoded.header, first.header)
        XCTAssertEqual(decoded.sections.map(\.header.kind), [.create, .write, .rename, .delete])
        for section in decoded.sections {
            XCTAssertFalse(section.bytes.isEmpty, "renameと空fileもsectionを失ってはならない")
        }
    }

    func testTextUnifiedDiffRoundTripsRawUTF8CRLFAndMissingFinalNewline() throws {
        let before = Data("先頭\r\n二行目".utf8)
        let after = Data("先頭\n末尾\r\n".utf8)
        let output = try Builder.build(
            binding: binding(),
            changes: [.init(changeID: "text", kind: .write,
                before: .init(path: "日本語.txt", mode: 0o640, bytes: before),
                after: .init(path: "日本語.txt", mode: 0o640, bytes: after))],
            previewBudget: .max
        )

        let section = try XCTUnwrap(Builder.decode(output.artifact).sections.first)
        XCTAssertEqual(section.header.representation, .rawUnifiedDiff)
        XCTAssertTrue(section.bytes.starts(with: Data("--- path-base64:".utf8)))
        let reconstructed = try section.reconstructText()
        XCTAssertEqual(reconstructed.before, before)
        XCTAssertEqual(reconstructed.after, after)
        XCTAssertEqual(section.header.before?.lineCount, 2)
        XCTAssertEqual(section.header.before?.endsWithNewline, false)
        XCTAssertEqual(section.header.after?.endsWithNewline, true)
    }

    func testNonUTF8AndNULAreBinaryMetadataWithoutByteStringification() throws {
        let fixtures = [Data([0xFF, 0xFE, 0x41]), Data([0x41, 0x00, 0x42])]
        for (index, bytes) in fixtures.enumerated() {
            let output = try Builder.build(
                binding: binding(transaction: "binary-\(index)"),
                changes: [.init(changeID: "binary", kind: .write,
                    before: .init(path: "blob.bin", mode: 0o600, bytes: Data([1, 2, 3])),
                    after: .init(path: "blob.bin", mode: 0o600, bytes: bytes))],
                previewBudget: .max
            )
            let section = try XCTUnwrap(Builder.decode(output.artifact).sections.first)
            XCTAssertEqual(section.header.representation, .binaryMetadata)
            XCTAssertEqual(section.header.after?.sizeBytes, bytes.count)
            XCTAssertEqual(section.header.after?.sha256, sha256(bytes))
            XCTAssertNil(section.header.after?.lineCount)
            XCTAssertFalse(section.bytes.contains(bytes), "binary bytesをtext artifactへ埋め込んではならない")
            XCTAssertThrowsError(try section.reconstructText()) { error in
                XCTAssertEqual(error as? Builder.Error, .wrongRepresentation)
            }
        }
    }

    func testPreviewContainsOnlyWholeArtifactRecordsAtNMinusOneNAndTinyBudgets() throws {
        let changes = [
            Builder.Change(changeID: "a", kind: .create, before: nil,
                after: .init(path: "a", bytes: Data("a\n".utf8))),
            Builder.Change(changeID: "b", kind: .create, before: nil,
                after: .init(path: "b", bytes: Data("b\n".utf8))),
        ]
        let full = try Builder.build(binding: binding(), changes: changes, previewBudget: .max)
        XCTAssertEqual(full.preview.bytes, full.artifact)
        XCTAssertFalse(full.preview.hasMore)

        let exact = try Builder.build(binding: binding(), changes: changes, previewBudget: full.artifact.count)
        let short = try Builder.build(binding: binding(), changes: changes, previewBudget: full.artifact.count - 1)
        let tiny = try Builder.build(binding: binding(), changes: changes, previewBudget: 1)
        XCTAssertEqual(exact.preview.bytes, full.artifact)
        XCTAssertLessThan(short.preview.returnedBytes, short.artifact.count - 1,
            "record途中のbyte prefixを返してはならない")
        XCTAssertTrue(short.preview.hasMore)
        XCTAssertEqual(short.preview.returnedBytes + short.preview.omittedBytes, short.artifact.count)
        XCTAssertEqual(tiny.preview.bytes, Data())
        XCTAssertEqual(tiny.preview.omittedBytes, tiny.artifact.count)
    }

    func testLargeRawTextArtifactIsCompleteAndTamperIsDetected() throws {
        var large = Data(repeating: 0x78, count: 1_100_000)
        large.append(0x0A)
        let output = try Builder.build(
            binding: binding(),
            changes: [.init(changeID: "large", kind: .create, before: nil,
                after: .init(path: "large.txt", bytes: large))],
            previewBudget: 32
        )
        XCTAssertGreaterThan(output.artifact.count, large.count)
        XCTAssertEqual(try Builder.decode(output.artifact).sections.first?.reconstructText().after, large)
        XCTAssertTrue(output.preview.hasMore)

        var tampered = output.artifact
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        XCTAssertThrowsError(try Builder.decode(tampered)) { error in
            guard case Builder.Error.corruptArtifact = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testInvalidChangeShapeAndNonCanonicalDigestFailClosed() throws {
        XCTAssertThrowsError(try Builder.build(
            binding: binding(),
            changes: [.init(changeID: "bad", kind: .delete, before: nil, after: nil)],
            previewBudget: 10
        ))
        var bad = binding()
        bad = .init(transactionID: bad.transactionID, requestDigest: "A" + String(repeating: "a", count: 63),
            manifestDigest: bad.manifestDigest, root: bad.root, fromCursor: bad.fromCursor, toCursor: bad.toCursor,
            clientID: bad.clientID, clientEpoch: bad.clientEpoch, requestSequence: bad.requestSequence)
        XCTAssertThrowsError(try Builder.build(binding: bad,
            changes: [.init(changeID: "ok", kind: .create, before: nil, after: .init(path: "x", bytes: Data()))],
            previewBudget: 10))
        let duplicate = Builder.Change(changeID: "same", kind: .create, before: nil,
            after: .init(path: "x", bytes: Data()))
        XCTAssertThrowsError(try Builder.build(binding: binding(), changes: [duplicate, duplicate], previewBudget: 10))
    }

    private func binding(transaction: String = "transaction-1") -> Builder.Binding {
        .init(
            transactionID: transaction,
            requestDigest: String(repeating: "a", count: 64),
            manifestDigest: String(repeating: "b", count: 64),
            root: "/tmp/workspace",
            fromCursor: .init(root: "/tmp/workspace", generation: "generation-1", sequence: 40),
            toCursor: .init(root: "/tmp/workspace", generation: "generation-1", sequence: 41),
            clientID: "00000000-0000-4000-8000-000000000001",
            clientEpoch: 2,
            requestSequence: 9
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
