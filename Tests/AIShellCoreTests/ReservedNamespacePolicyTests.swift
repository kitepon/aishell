import XCTest
@testable import AIShellCore

final class ReservedNamespacePolicyTests: XCTestCase {
    func testResolverRejectsBothSymlinkDirectionsWithTypedReservedPath() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        let reserved = root.appendingPathComponent(ReservedNamespacePolicy.name, isDirectory: true)
        let publicDirectory = root.appendingPathComponent("public", isDirectory: true)
        try FileManager.default.createDirectory(at: reserved, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: publicDirectory, withIntermediateDirectories: true)
        try "secret".write(to: reserved.appendingPathComponent("secret.txt"), atomically: false, encoding: .utf8)
        try "public".write(to: publicDirectory.appendingPathComponent("value.txt"), atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("publicAlias"), withDestinationURL: reserved
        )
        try FileManager.default.createSymbolicLink(
            at: reserved.appendingPathComponent("outAlias"), withDestinationURL: publicDirectory
        )
        let resolver = PathResolver(baseDirectory: URL(fileURLWithPath: root.path))

        XCTAssertThrowsReservedPath {
            _ = try resolver.resolveExisting("publicAlias/secret.txt")
        }
        XCTAssertThrowsReservedPath {
            _ = try resolver.resolveExisting(".aishell-transactions/outAlias/value.txt")
        }
    }

    func testWorkingDirectoryCannotRepublishReservedNamespace() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        let nested = root.appendingPathComponent(".aishell-transactions/reopened", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        XCTAssertThrowsReservedPath {
            _ = try PathResolver(baseDirectory: nested).resolveExisting(nil)
        }
        XCTAssertThrowsReservedPath {
            _ = try PathResolver(baseDirectory: root).resolveExisting(nested.path)
        }
    }

    func testNativeFilesAndWorkspaceNeverPublishReservedNamespace() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        let reserved = root.appendingPathComponent(".aishell-transactions", isDirectory: true)
        try FileManager.default.createDirectory(at: reserved, withIntermediateDirectories: true)
        try "visible".write(to: root.appendingPathComponent("visible.txt"), atomically: false, encoding: .utf8)
        try "needle".write(to: reserved.appendingPathComponent("secret.txt"), atomically: false, encoding: .utf8)
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(root)

        let files = NativeFileService(store: store)
        let listed = try await files.list()
        let searched = try await files.search(query: "secret")
        XCTAssertFalse(listed.contains { $0.name == ReservedNamespacePolicy.name })
        XCTAssertTrue(searched.isEmpty)
        do {
            _ = try await files.readText(path: ".aishell-transactions/secret.txt")
            XCTFail("予約namespaceを直接readできました。")
        } catch {
            guard case AIShellError.reservedPath = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }

        let runtime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        let snapshot = try await runtime.snapshot()
        XCTAssertFalse(snapshot.entries.contains { ReservedNamespacePolicy.contains(relativePath: $0.path) })
        XCTAssertEqual(snapshot.cursor.split(separator: ":")[2], Substring(ReservedNamespacePolicy.exclusionDigest))
        await runtime.ingestObservedPaths([reserved.appendingPathComponent("echo").path])
        let unchanged = try await runtime.snapshot(sinceCursor: snapshot.cursor)
        XCTAssertEqual(unchanged.cursor, snapshot.cursor)
    }

    func testKnownMutationAppendsOnceWithoutRescanAndAbsorbsExactEcho() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(root)
        let runtime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        let initial = try await runtime.snapshot()
        let scanCount = await runtime.scanInvocationCountForTests()
        let file = root.appendingPathComponent("created.txt")
        try "created".write(to: file, atomically: false, encoding: .utf8)

        let committedCursor = try await runtime.appendKnownMutation(
            transactionID: "tx-1",
            changes: [.init(kind: .created, path: "created.txt")]
        )
        let repeatedCursor = try await runtime.appendKnownMutation(
            transactionID: "tx-1",
            changes: [.init(kind: .created, path: "created.txt")]
        )
        XCTAssertEqual(repeatedCursor, committedCursor)
        let delta = try await runtime.snapshot(sinceCursor: initial.cursor)
        XCTAssertEqual(delta.changes.map(\.path), ["created.txt"])
        XCTAssertEqual(delta.changes.map(\.kind), [.created])
        let countAfterDelta = await runtime.scanInvocationCountForTests()
        XCTAssertEqual(countAfterDelta, scanCount)

        await runtime.ingestObservedPaths([file.path])
        let echo = try await runtime.snapshot(sinceCursor: delta.cursor)
        XCTAssertTrue(echo.changes.isEmpty)
        XCTAssertEqual(echo.cursor, delta.cursor)
        let countAfterEcho = await runtime.scanInvocationCountForTests()
        XCTAssertEqual(countAfterEcho, scanCount)
    }
}

private func XCTAssertThrowsReservedPath(
    _ expression: () throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        try expression()
        XCTFail("RESERVED_PATHを返しませんでした。", file: file, line: line)
    } catch {
        guard case AIShellError.reservedPath = error else {
            return XCTFail("想定外のエラー: \(error)", file: file, line: line)
        }
    }
}
