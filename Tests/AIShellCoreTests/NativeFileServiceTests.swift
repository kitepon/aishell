import XCTest
@testable import AIShellCore

final class NativeFileServiceTests: XCTestCase {
    func testDirectFileOperationsPreserveRequestedContent() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let files = NativeFileService(workingDirectory: fixture.base)
        _ = try files.createDirectory(path: "notes/inbox")
        _ = try files.createTextFile(path: "notes/inbox/hello.txt", content: "")
        _ = try files.writeText(path: "notes/inbox/hello.txt", content: "日本語\r\n$HOME; * \t\n")
        XCTAssertEqual(try files.readText(path: "notes/inbox/hello.txt"), "日本語\r\n$HOME; * \t\n")
        let before = try files.stat(path: "notes/inbox/hello.txt", includeHash: true)
        XCTAssertEqual(before.sha256?.count, 64)
        _ = try files.writeText(path: "notes/inbox/hello.txt", content: "one one", expectedSHA256: before.sha256)
        XCTAssertThrowsError(try files.writeText(path: "notes/inbox/hello.txt", content: "stale", expectedSHA256: before.sha256))
        XCTAssertThrowsError(try files.replaceText(path: "notes/inbox/hello.txt", oldText: "one", newText: "two"))
        _ = try files.replaceText(path: "notes/inbox/hello.txt", oldText: "one", newText: "two", replaceAll: true)
        XCTAssertEqual(try files.readText(path: "notes/inbox/hello.txt"), "two two")
        _ = try files.copy(source: "notes/inbox/hello.txt", destination: "notes/copy.txt")
        _ = try files.rename(path: "notes/copy.txt", newName: "renamed.txt")
        _ = try files.move(source: "notes/renamed.txt", destination: "moved.txt")
        XCTAssertEqual(try files.readText(path: "moved.txt"), "two two")
        XCTAssertThrowsError(try files.createTextFile(path: "moved.txt", content: "overwrite"))
        XCTAssertThrowsError(try files.copy(source: "moved.txt", destination: "moved.txt"))
        _ = try files.createTextFile(path: ".hidden", content: "visible")
        XCTAssertEqual(Set(try files.list().map(\.name)), [".hidden", "moved.txt", "notes"])
        XCTAssertEqual(try files.search(query: "hello").entries.map(\.name), ["hello.txt"])
        XCTAssertEqual(try files.tree(path: "notes", maxDepth: 1).entries.map(\.entry.name), ["inbox"])
        XCTAssertTrue(try files.tree(limit: 1).hasMore)
        XCTAssertFalse(try files.search(query: "hello", limit: 1).hasMore)
        XCTAssertThrowsError(try files.tree(limit: 0))
        XCTAssertThrowsError(try files.tree(path: "moved.txt"))
    }

    func testReadIsCompleteAndInvalidTextIsExplicit() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let files = NativeFileService(workingDirectory: fixture.base)
        let content = String(repeating: "あ", count: 400_000)
        _ = try files.writeText(path: "large.txt", content: content)
        XCTAssertEqual(try files.readText(path: "large.txt"), content)
        try Data([0xFF]).write(to: fixture.base.appendingPathComponent("binary"))
        XCTAssertThrowsError(try files.readText(path: "binary")) {
            XCTAssertEqual($0 as? AIShellError, .notTextFile("binary"))
        }
    }

    func testRenameAndTrashOperateOnSymlinkItself() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let files = NativeFileService(workingDirectory: fixture.base)
        _ = try files.createTextFile(path: "target", content: "keep")
        try FileManager.default.createSymbolicLink(atPath: fixture.base.appendingPathComponent("link").path,
            withDestinationPath: "target")
        _ = try files.rename(path: "link", newName: "renamed-link")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.base.appendingPathComponent("renamed-link").path), "target")
        XCTAssertEqual(try files.readText(path: "target"), "keep")
        let trashed = try files.trash(path: "renamed-link")
        defer { try? FileManager.default.removeItem(atPath: trashed) }
        XCTAssertEqual(try files.readText(path: "target"), "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.appendingPathComponent("renamed-link").path))
    }

    func testAbsoluteAndFormerlyReservedPathsNeedNoStateOrRegistration() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let files = NativeFileService()
        let target = fixture.base.appendingPathComponent(".aishell-transaction-test.txt")
        _ = try files.writeText(path: target.path, content: "direct")
        XCTAssertEqual(try files.readText(path: target.path), "direct")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.base.path), [target.lastPathComponent])
        XCTAssertThrowsError(try files.writeText(path: target.path + "\0ignored", content: "bad"))
    }
}
