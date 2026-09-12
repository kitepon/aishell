import XCTest
@testable import AIShellCore

final class NativeFileServiceTests: XCTestCase {
    func testNativeFileWorkflowUsesWorkingDirectory() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.base.appendingPathComponent("runtime", isDirectory: true)
        let allowed = fixture.base.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)

        let store = RuntimeStore(baseDirectory: runtime)
        await store.setWorkingDirectoryForTesting(allowed)
        let service = NativeFileService(store: store)

        let folder = try await service.createDirectory(path: "notes/inbox")
        XCTAssertTrue(folder.isDirectory)

        let created = try await service.createTextFile(
            path: "notes/inbox/hello.txt",
            content: "hello macOS"
        )
        XCTAssertEqual(created.name, "hello.txt")
        let text = try await service.readText(path: "notes/inbox/hello.txt")
        XCTAssertEqual(text, "hello macOS")

        let copy = try await service.copy(
            source: "notes/inbox/hello.txt",
            destination: "notes/inbox/copy.txt"
        )
        XCTAssertEqual(copy.name, "copy.txt")

        let renamed = try await service.rename(path: "notes/inbox/copy.txt", newName: "renamed.txt")
        XCTAssertEqual(renamed.name, "renamed.txt")

        let moved = try await service.move(
            source: "notes/inbox/renamed.txt",
            destination: "notes/renamed.txt"
        )
        XCTAssertEqual(moved.path, allowed.appendingPathComponent("notes/renamed.txt").path)

        let searchResults = try await service.search(query: "hello")
        XCTAssertEqual(searchResults.map(\.name), ["hello.txt"])

        let list = try await service.list(path: "notes")
        XCTAssertEqual(Set(list.map(\.name)), ["inbox", "renamed.txt"])

        let activities = try await store.loadRecentActivities(limit: 20)
        XCTAssertGreaterThanOrEqual(activities.count, 8)
        XCTAssertTrue(activities.allSatisfy(\.success))
    }

    func testPausedRuntimeRejectsOperations() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.base.appendingPathComponent("runtime", isDirectory: true)
        let allowed = fixture.base.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)

        let store = RuntimeStore(baseDirectory: runtime)
        await store.setWorkingDirectoryForTesting(allowed)
        try await store.setPaused(true)
        let service = NativeFileService(store: store)

        do {
            _ = try await service.list()
            XCTFail("停止中の操作が成功してしまいました。")
        } catch {
            XCTAssertEqual(error as? AIShellError, .paused)
        }
    }

    func testAbsolutePathWorksWithoutConfiguration() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.base.appendingPathComponent("runtime", isDirectory: true)
        let first = fixture.base.appendingPathComponent("first", isDirectory: true)
        let second = fixture.base.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let store = RuntimeStore(baseDirectory: runtime)
        let service = NativeFileService(store: store)

        let created = try await service.createTextFile(
            path: second.appendingPathComponent("second.txt").path,
            content: "second root"
        )
        XCTAssertEqual(created.path, second.appendingPathComponent("second.txt").path)
        let content = try await service.readText(path: created.path)
        XCTAssertEqual(content, "second root")
    }

    func testCreateDoesNotOverwriteExistingFile() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.base.appendingPathComponent("runtime", isDirectory: true)
        let allowed = fixture.base.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)

        let store = RuntimeStore(baseDirectory: runtime)
        await store.setWorkingDirectoryForTesting(allowed)
        let service = NativeFileService(store: store)
        _ = try await service.createTextFile(path: "stable.txt", content: "first")

        do {
            _ = try await service.createTextFile(path: "stable.txt", content: "second")
            XCTFail("既存ファイルを上書きしてしまいました。")
        } catch {
            guard case AIShellError.itemAlreadyExists = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }

        XCTAssertEqual(
            try String(contentsOf: allowed.appendingPathComponent("stable.txt"), encoding: .utf8),
            "first"
        )
    }

    func testStatWriteReplaceAndTreeSupportDevelopmentEdits() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.base.appendingPathComponent("runtime", isDirectory: true)
        let allowed = fixture.base.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)

        let store = RuntimeStore(baseDirectory: runtime)
        await store.setWorkingDirectoryForTesting(allowed)
        let service = NativeFileService(store: store)
        _ = try await service.createDirectory(path: "Sources/Feature")
        _ = try await service.createTextFile(
            path: "Sources/Feature/value.swift",
            content: "let value = 1\nlet other = 2\n"
        )

        let initial = try await service.stat(path: "Sources/Feature/value.swift")
        XCTAssertEqual(initial.sha256?.count, 64)

        do {
            _ = try await service.writeText(
                path: "Sources/Feature/value.swift",
                content: "blind overwrite"
            )
            XCTFail("hashなしで既存ファイルを更新してしまいました。")
        } catch {
            guard case AIShellError.invalidArgument = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }

        let written = try await service.writeText(
            path: "Sources/Feature/value.swift",
            content: "let value = 3\nlet other = 2\n",
            expectedSHA256: initial.sha256
        )
        XCTAssertNotEqual(written.sha256, initial.sha256)

        do {
            _ = try await service.writeText(
                path: "Sources/Feature/value.swift",
                content: "stale overwrite",
                expectedSHA256: initial.sha256
            )
            XCTFail("古いhashで更新してしまいました。")
        } catch {
            guard case AIShellError.contentChanged = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }

        _ = try await service.replaceText(
            path: "Sources/Feature/value.swift",
            oldText: "let other = 2",
            newText: "let other = 4"
        )
        let updated = try await service.readText(path: "Sources/Feature/value.swift")
        XCTAssertEqual(updated, "let value = 3\nlet other = 4\n")

        let tree = try await service.tree(path: "Sources", maxDepth: 3)
        XCTAssertEqual(tree.map(\.entry.name), ["Feature", "value.swift"])
        XCTAssertEqual(tree.map(\.depth), [1, 2])
    }
}
