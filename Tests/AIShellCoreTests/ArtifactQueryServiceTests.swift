import Foundation
import XCTest
@testable import AIShellCore

final class ArtifactQueryServiceTests: XCTestCase {
    func testLiteralPagesConcatenateToImmutableStreamAndCursorsAdvance() async throws {
        let service = ArtifactQueryService()
        let source = ArtifactQueryService.Artifact(id: "a", kind: "stdout", data: Data("hit one\nhit two\nhit three".utf8))
        var page = try await service.start(.init(pattern: .literal("hit", mode: .sensitive), pageByteLimit: 40), sources: [source])
        let handle = page.streamHandle
        var gathered = page.items
        while page.hasMore {
            let cursor = try XCTUnwrap(page.nextCursor)
            page = try await service.next(streamHandle: handle, cursor: cursor, pageByteLimit: 40)
            gathered += page.items
        }
        let stream = try await service.stream(handle: handle)
        XCTAssertEqual(gathered, stream.items)
        XCTAssertEqual(gathered.count, 3)
    }

    func testOversizeItemIsConsumedAndReturnsDescriptor() async throws {
        let service = ArtifactQueryService()
        let source = ArtifactQueryService.Artifact(id: "a", kind: "diagnostic", data: Data(("needle " + String(repeating: "x", count: 100)) .utf8))
        let page = try await service.start(.init(pattern: .literal("needle", mode: .sensitive), pageByteLimit: 16), sources: [source])
        XCTAssertFalse(page.hasMore)
        guard case let .oversizeDescriptor(value) = try XCTUnwrap(page.items.first) else { return XCTFail("descriptorが必要") }
        XCTAssertEqual(value.offset, 0)
        XCTAssertGreaterThan(value.fullByteCount, 16)
        XCTAssertEqual(value.artifactRange, "a:0:\(value.fullByteCount)")
    }

    func testOversizeDescriptorRangesTheEntireUTF8PrefixedLineNotMatchOffset() async throws {
        let service = ArtifactQueryService()
        let line = "é needle " + String(repeating: "x", count: 100)
        let source = ArtifactQueryService.Artifact(id: "a", kind: "diagnostic", data: Data(line.utf8))
        let page = try await service.start(.init(pattern: .literal("needle", mode: .sensitive), pageByteLimit: 16), sources: [source])
        guard case let .oversizeDescriptor(value) = try XCTUnwrap(page.items.first) else { return XCTFail("descriptorが必要") }
        XCTAssertEqual(value.offset, 0)
        XCTAssertEqual(value.fullByteCount, Data(line.utf8).count)
        XCTAssertEqual(value.artifactRange, "a:0:\(Data(line.utf8).count)")
    }

    func testBinaryAllowsOnlySensitiveLiteralAtRawOffsets() async throws {
        let service = ArtifactQueryService()
        let binary = ArtifactQueryService.Artifact(id: "bin", kind: "stdout", data: Data([0xff, 0x61, 0x62, 0x00, 0x61, 0x62]))
        let page = try await service.start(.init(pattern: .literal("ab", mode: .sensitive)), sources: [binary])
        XCTAssertEqual(page.items, [.match(sourceID: "bin", kind: "stdout", offset: 1, line: 0, text: ""), .match(sourceID: "bin", kind: "stdout", offset: 4, line: 0, text: "")])
        await XCTAssertThrowsErrorAsync(try await service.start(.init(pattern: .literal("ab", mode: .insensitive)), sources: [binary])) { XCTAssertEqual($0 as? ArtifactQueryService.Error, .binaryCaseModeUnsupported) }
        await XCTAssertThrowsErrorAsync(try await service.start(.init(pattern: .regex("ab")), sources: [binary])) { XCTAssertEqual($0 as? ArtifactQueryService.Error, .binaryRegexUnsupported) }
    }

    func testRejectsTamperedAndOtherStreamCursor() async throws {
        let service = ArtifactQueryService()
        let source = ArtifactQueryService.Artifact(id: "a", kind: "stdout", data: Data("x\nx".utf8))
        let first = try await service.start(.init(pattern: .literal("x", mode: .sensitive), pageByteLimit: 8), sources: [source])
        let other = try await service.start(.init(pattern: .literal("x", mode: .sensitive), pageByteLimit: 8), sources: [source])
        let cursor = try XCTUnwrap(first.nextCursor)
        await XCTAssertThrowsErrorAsync(try await service.next(streamHandle: other.streamHandle, cursor: cursor)) { XCTAssertEqual($0 as? ArtifactQueryService.Error, .invalidCursor) }
        await XCTAssertThrowsErrorAsync(try await service.next(streamHandle: first.streamHandle, cursor: cursor + "x")) { XCTAssertEqual($0 as? ArtifactQueryService.Error, .invalidCursor) }
    }

    func testRegexCaseFoldAndHistoryMissingBindingAreNotEqual() async throws {
        let service = ArtifactQueryService()
        let source = ArtifactQueryService.Artifact(id: "a", kind: "stdout", data: Data("Alpha\nbeta".utf8))
        let page = try await service.start(.init(pattern: .regex("alpha", flags: "i")), sources: [source])
        XCTAssertEqual(page.items.count, 1)
        let comparison = await service.compareHistory(.init(request: "r", toolchain: "t", input: "i"), .init(request: "r", toolchain: nil, input: "i"))
        XCTAssertEqual(comparison, .different(missingOnLeft: [], missingOnRight: ["toolchain"], changed: []))
    }

    func testTextLiteralAndRegexReturnEveryUTF8MatchOffsetInRequestSourceOrder() async throws {
        let service = ArtifactQueryService()
        let first = ArtifactQueryService.Artifact(id: "z", kind: "stdout", data: Data("é xx é xx".utf8))
        let second = ArtifactQueryService.Artifact(id: "a", kind: "stdout", data: Data("xx".utf8))
        let literal = try await service.start(.init(pattern: .literal("xx", mode: .sensitive)), sources: [first, second])
        XCTAssertEqual(literal.items, [
            .match(sourceID: "z", kind: "stdout", offset: 3, line: 1, text: "é xx é xx"),
            .match(sourceID: "z", kind: "stdout", offset: 9, line: 1, text: "é xx é xx"),
            .match(sourceID: "a", kind: "stdout", offset: 0, line: 1, text: "xx")
        ])
        let regex = try await service.start(.init(pattern: .regex("x+")), sources: [first])
        XCTAssertEqual(regex.items, [
            .match(sourceID: "z", kind: "stdout", offset: 3, line: 1, text: "é xx é xx"),
            .match(sourceID: "z", kind: "stdout", offset: 9, line: 1, text: "é xx é xx")
        ])
    }

    func testRegexRejectsUnknownAndDuplicateFlags() async throws {
        let service = ArtifactQueryService()
        let source = ArtifactQueryService.Artifact(id: "a", kind: "stdout", data: Data("x".utf8))
        await XCTAssertThrowsErrorAsync(try await service.start(.init(pattern: .regex("x", flags: "m")), sources: [source])) {
            XCTAssertEqual($0 as? ArtifactQueryService.Error, .unsupportedRegexFlag("m"))
        }
        await XCTAssertThrowsErrorAsync(try await service.start(.init(pattern: .regex("x", flags: "ii")), sources: [source])) {
            XCTAssertEqual($0 as? ArtifactQueryService.Error, .duplicateRegexFlag("i"))
        }
    }

    func testHistoryResultIncludesArtifactIdentityAndBindingComparison() async throws {
        let service = ArtifactQueryService()
        let binding = ArtifactQueryService.HistoryBinding(request: "r", toolchain: "t", input: "i")
        let baseline = ArtifactQueryService.Artifact(id: "base", kind: "stdout", data: Data("same".utf8), historyBinding: binding)
        let same = ArtifactQueryService.Artifact(id: "candidate", kind: "stdout", data: Data("same".utf8), historyBinding: binding)
        let equal = await service.compareHistory(baseline: baseline, candidate: same)
        XCTAssertTrue(equal.artifactsEqual)
        XCTAssertEqual(equal.baseline, .init(sha256: baseline.sha256, sizeBytes: 4))
        XCTAssertEqual(equal.candidate, .init(sha256: same.sha256, sizeBytes: 4))
        XCTAssertEqual(equal.binding, .equal)

        let changed = ArtifactQueryService.Artifact(id: "changed", kind: "stdout", data: Data("different".utf8), historyBinding: .init(request: "r2", toolchain: nil, input: "i"))
        let different = await service.compareHistory(baseline: baseline, candidate: changed)
        XCTAssertFalse(different.artifactsEqual)
        XCTAssertEqual(different.candidate.sizeBytes, 9)
        XCTAssertEqual(different.binding, .different(missingOnLeft: [], missingOnRight: ["toolchain"], changed: ["request"]))
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ verify: (Swift.Error) -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("エラーが必要", file: file, line: line) }
    catch { verify(error) }
}
