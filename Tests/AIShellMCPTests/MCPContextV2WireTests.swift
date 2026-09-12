import AIShellCore
import Foundation
import XCTest
@testable import AIShellMCP

final class MCPContextV2WireTests: XCTestCase {
    func testWorkspaceBranchComparisonRoundTripsIdentityDirtyStateAndBudgetedDiff() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("aishell-mcp-branch-\(UUID().uuidString)", isDirectory: true)
        let root = temporary.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.git(["init", "-b", "main"], root)
        try Self.git(["config", "user.email", "fixture@example.invalid"], root)
        try Self.git(["config", "user.name", "Fixture"], root)
        try Data("one\n".utf8).write(to: root.appendingPathComponent("File.txt"))
        try Self.git(["add", "File.txt"], root)
        try Self.git(["commit", "-m", "base"], root)
        let base = try Self.git(["rev-parse", "HEAD"], root)
        try Data("two\n".utf8).write(to: root.appendingPathComponent("File.txt"))
        try Self.git(["commit", "-am", "head"], root)
        try Data("dirty\n".utf8).write(to: root.appendingPathComponent("File.txt"))
        let store = RuntimeStore(baseDirectory: temporary.appendingPathComponent("state"))
        await store.setWorkingDirectoryForTesting(root)
        let server = MCPServer(runtimeStore: store)

        let response = await server.callTool(id: .number(1), params: .object([
            "name": .string("workspace_snapshot"),
            "arguments": .object([
                "path": .string(root.path),
                "context_budget": .number(0),
                "git_diff": .object([
                    "mode": .string("branch"), "base_ref": .string(base),
                    "byte_budget": .number(1_024), "include_patch": .bool(false)
                ])
            ])
        ]))
        let comparison = try XCTUnwrap(response.result?.objectValue?["structuredContent"]?
            .objectValue?["gitDiff"]?.objectValue)
        XCTAssertEqual(comparison["comparisonMode"], .string("branch"))
        XCTAssertEqual(comparison["headBranch"], .string("main"))
        XCTAssertEqual(comparison["dirtyState"], .string("dirty"))
        XCTAssertEqual(comparison["baseSHA"], .string(base))
        XCTAssertFalse(comparison["repositoryIdentity"]?.stringValue?.isEmpty ?? true)
        XCTAssertLessThanOrEqual(comparison["returnedBytes"]?.intValue ?? .max, 1_024)
    }

    func testWorkspaceWaitTimeoutRoundTripsThroughExpandedMCP() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("aishell-mcp-workspace-wait-\(UUID().uuidString)", isDirectory: true)
        let root = temporary.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = RuntimeStore(baseDirectory: temporary.appendingPathComponent("state"))
        await store.setWorkingDirectoryForTesting(root)
        let server = MCPServer(runtimeStore: store, capabilitySet: "expanded-v1")

        let snapshot = await server.callTool(id: .number(1), params: .object([
            "name": .string("workspace_snapshot"),
            "arguments": .object(["path": .string(root.path)])
        ]))
        let cursor = try XCTUnwrap(
            snapshot.result?.objectValue?["structuredContent"]?.objectValue?["cursor"]?.stringValue
        )
        let response = await server.callTool(id: .number(2), params: .object([
            "name": .string("workspace_wait"),
            "arguments": .object([
                "path": .string(root.path), "from_cursor": .string(cursor), "timeout_ms": .number(0)
            ])
        ]))
        let result = try XCTUnwrap(response.result?.objectValue)
        XCTAssertEqual(result["isError"], .bool(false))
        XCTAssertEqual(result["structuredContent"]?.objectValue?["schemaVersion"], .string("aishell.workspace-wait.v1"))
        XCTAssertEqual(result["structuredContent"]?.objectValue?["status"], .string("timed_out"))
        XCTAssertEqual(result["structuredContent"]?.objectValue?["observedFrom"], .string(cursor))
        XCTAssertEqual(result["structuredContent"]?.objectValue?["observedThrough"], .string(cursor))
    }

    func testProjectProfileContinuationRoundTripsThroughMCP() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("aishell-mcp-profile-page-\(UUID().uuidString)", isDirectory: true)
        let root = temporary.appendingPathComponent("workspace", isDirectory: true)
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("[package]\nname=\"root\"\nversion=\"0.1.0\"\n".utf8)
            .write(to: root.appendingPathComponent("Cargo.toml"))
        try Data("[package]\nname=\"nested\"\nversion=\"0.1.0\"\n".utf8)
            .write(to: nested.appendingPathComponent("Cargo.toml"))
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = RuntimeStore(baseDirectory: temporary.appendingPathComponent("state"))
        await store.setWorkingDirectoryForTesting(root)
        let server = MCPServer(runtimeStore: store)

        let first = await server.callTool(id: .number(1), params: .object([
            "name": .string("workspace_snapshot"),
            "arguments": .object([
                "path": .string(root.path),
                "project_profile": .object([
                    "mode": .string("all"),
                    "byte_budget": .number(262_144),
                    "profile_limit": .number(1)
                ])
            ])
        ]))
        let firstStructured = try XCTUnwrap(
            first.result?.objectValue?["structuredContent"]?.objectValue
        )
        let continuation = try XCTUnwrap(firstStructured["projectProfileContinuation"]?.stringValue)
        XCTAssertEqual(firstStructured["projectProfileHasMore"], .bool(true))

        let second = await server.callTool(id: .number(2), params: .object([
            "name": .string("workspace_snapshot"),
            "arguments": .object([
                "path": .string(root.path),
                "project_profile": .object([
                    "continuation": .string(continuation),
                    "byte_budget": .number(262_144),
                    "profile_limit": .number(1)
                ])
            ])
        ]))
        let secondStructured = try XCTUnwrap(
            second.result?.objectValue?["structuredContent"]?.objectValue
        )
        XCTAssertEqual(second.result?.objectValue?["isError"], .bool(false))
        XCTAssertEqual(secondStructured["projectProfileHasMore"], .bool(false))
        XCTAssertEqual(secondStructured["cursor"], firstStructured["cursor"])
    }

    func testWorkspaceV2ProjectionAndSearchV2DefaultsUseStableWireShapes() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("aishell-mcp-context-v2-\(UUID().uuidString)", isDirectory: true)
        let root = temporary.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("needle\n".utf8).write(to: root.appendingPathComponent("Source.swift"))
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = RuntimeStore(baseDirectory: temporary.appendingPathComponent("state"))
        await store.setWorkingDirectoryForTesting(root)
        let server = MCPServer(runtimeStore: store)

        let workspace = await server.callTool(id: .number(1), params: .object([
            "name": .string("workspace_snapshot"),
            "arguments": .object([
                "path": .string(root.path),
                "project_profile": .object(["mode": .string("none")])
            ])
        ]))
        let workspaceResult = try XCTUnwrap(workspace.result?.objectValue)
        XCTAssertEqual(workspaceResult["isError"], .bool(false))
        XCTAssertEqual(
            workspaceResult["structuredContent"]?.objectValue?["schemaVersion"],
            .string("aishell.workspace-snapshot.v2")
        )
        let cursor = try XCTUnwrap(
            workspaceResult["structuredContent"]?.objectValue?["cursor"]?.stringValue
        )
        let search = await server.callTool(id: .number(2), params: .object([
            "name": .string("search_context"),
            "arguments": .object([
                "action": .string("search"),
                "path": .string(root.path),
                "changed_since_cursor": .string(cursor),
                "queries": .array([.object([
                    "id": .string("q0"), "kind": .string("fixed"), "pattern": .string("needle")
                ])])
            ])
        ]))
        let searchResult = try XCTUnwrap(search.result?.objectValue)
        XCTAssertEqual(searchResult["isError"], .bool(false))
        XCTAssertEqual(
            searchResult["structuredContent"]?.objectValue?["schema"],
            .string("aishell.search-context.v2")
        )
        XCTAssertEqual(
            searchResult["structuredContent"]?.objectValue?["matches"]?.arrayValue?.count,
            1
        )
        XCTAssertEqual(
            searchResult["structuredContent"]?.objectValue?["rankingEvidence"]?.objectValue?["applied"],
            .array([.string("changed"), .string("tests")])
        )

        let defaultSearch = await server.callTool(id: .number(3), params: .object([
            "name": .string("search_context"),
            "arguments": .object([
                "action": .string("search"),
                "path": .string(root.path),
                "queries": .array([.object([
                    "id": .string("q0"), "kind": .string("fixed"), "pattern": .string("needle")
                ])])
            ])
        ]))
        let defaultResult = try XCTUnwrap(defaultSearch.result?.objectValue)
        XCTAssertEqual(defaultResult["isError"], .bool(false))
        XCTAssertEqual(
            defaultResult["structuredContent"]?.objectValue?["rankingEvidence"]?.objectValue?["applied"],
            .array([.string("tests")])
        )

        try Data("needle sibling\n".utf8).write(to: root.appendingPathComponent("Other.swift"))
        let fileSearch = await server.callTool(id: .number(4), params: .object([
            "name": .string("search_context"),
            "arguments": .object([
                "query": .string("needle"),
                "path": .string(root.appendingPathComponent("Source.swift").path),
                "byte_budget": .number(1_200)
            ])
        ]))
        let fileResult = try XCTUnwrap(fileSearch.result?.objectValue)
        XCTAssertEqual(fileResult["isError"], .bool(false))
        XCTAssertEqual(fileResult["structuredContent"]?.objectValue?["matches"]?.arrayValue?.count, 1)
        XCTAssertEqual(
            fileResult["structuredContent"]?.objectValue?["matches"]?.arrayValue?.first?
                .objectValue?["path"],
            .string("Source.swift")
        )

        let invalidSearch = await server.callTool(id: .number(5), params: .object([
            "name": .string("search_context"),
            "arguments": .object([
                "action": .string("search"),
                "path": .string(root.path),
                "ranking": .array([.string("changed")]),
                "queries": .array([.object([
                    "id": .string("q0"), "kind": .string("fixed"), "pattern": .string("needle")
                ])])
            ])
        ]))
        let invalidResult = try XCTUnwrap(invalidSearch.result?.objectValue)
        XCTAssertEqual(invalidResult["isError"], .bool(true))
        XCTAssertEqual(
            invalidResult["structuredContent"]?.objectValue?["error"]?.objectValue?["code"],
            .string("INVALID_ARGUMENT")
        )
    }

    func testSemanticSearchActionIsPublicAndReturnsTypedProviderState() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("aishell-mcp-semantic-\(UUID().uuidString)", isDirectory: true)
        let root = temporary.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("func target() {}\n".utf8).write(to: root.appendingPathComponent("src/a.swift"))
        try Data("func caller() { target() }\n".utf8).write(to: root.appendingPathComponent("src/b.swift"))
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = RuntimeStore(baseDirectory: temporary.appendingPathComponent("state"))
        await store.setWorkingDirectoryForTesting(root)
        let server = MCPServer(runtimeStore: store, capabilitySet: "expanded-v1")
        let snapshot = await server.callTool(id: .number(1), params: .object([
            "name": .string("workspace_snapshot"),
            "arguments": .object(["path": .string(root.path), "context_budget": .number(0)])
        ]))
        let cursor = try XCTUnwrap(
            snapshot.result?.objectValue?["structuredContent"]?.objectValue?["cursor"]?.stringValue
        )

        let response = await server.callTool(id: .number(2), params: .object([
            "name": .string("search_context"),
            "arguments": .object([
                "action": .string("semantic"), "path": .string(root.path),
                "provider": .string("sourcekit-lsp"), "cursor": .string(cursor),
                "queries": .array([.object([
                    "id": .string("refs"), "kind": .string("semantic"),
                    "pattern": .string("target"), "operation": .string("references")
                ])])
            ])
        ]))
        let result = try XCTUnwrap(response.result?.objectValue)
        XCTAssertEqual(result["isError"], .bool(false))
        let structured = try XCTUnwrap(result["structuredContent"]?.objectValue)
        XCTAssertEqual(structured["schema"], .string("aishell.search-context.v2"))
        XCTAssertEqual(structured["provider"], .string("sourcekit-lsp"))
        XCTAssertEqual(structured["scanMode"], .string("semantic_provider"))
        let state = try XCTUnwrap(structured["freshness"]?.objectValue?["state"]?.stringValue)
        XCTAssertTrue(["fresh", "indexing", "unavailable"].contains(state))
        if state == "fresh" {
            let paths = structured["matches"]?.arrayValue?.compactMap {
                $0.objectValue?["path"]?.stringValue
            } ?? []
            XCTAssertTrue(paths.contains("src/b.swift"), "fresh SourceKit result omitted the cross-file reference")
        }
    }

    func testToolSchemasAdvertiseNestedV2ContextWithoutRemovingV1Fields() throws {
        let tools = try ToolCatalog.listedTools(profile: nil)
        let workspace = try XCTUnwrap(tools.first { $0.name == "workspace_snapshot" })
        let workspaceProperties = try XCTUnwrap(workspace.inputSchema.objectValue?["properties"]?.objectValue)
        XCTAssertNotNil(workspaceProperties["git_diff"])
        XCTAssertNotNil(workspaceProperties["project_profile"])
        XCTAssertNotNil(workspaceProperties["since_cursor"])
        let comparisonMode = workspaceProperties["git_diff"]?.objectValue?["properties"]?
            .objectValue?["mode"]?.objectValue?["enum"]?.arrayValue
        XCTAssertEqual(comparisonMode, [.string("worktree"), .string("branch")])

        let search = try XCTUnwrap(tools.first { $0.name == "search_context" })
        let searchProperties = try XCTUnwrap(search.inputSchema.objectValue?["properties"]?.objectValue)
        XCTAssertNotNil(searchProperties["query"])
        XCTAssertNotNil(searchProperties["queries"])
        XCTAssertNotNil(searchProperties["changed_since_cursor"])
        XCTAssertNotNil(searchProperties["provider"])
        XCTAssertNotNil(searchProperties["cursor"])
        XCTAssertEqual(
            searchProperties["action"]?.objectValue?["enum"]?.arrayValue,
            [.string("search"), .string("semantic")]
        )
        let profileProperties = workspaceProperties["project_profile"]?.objectValue?["properties"]?.objectValue
        XCTAssertNotNil(profileProperties?["byte_budget"])
        XCTAssertNotNil(profileProperties?["profile_limit"])
        XCTAssertNotNil(profileProperties?["continuation"])
    }

    @discardableResult
    private static func git(_ arguments: [String], _ root: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        let output = Pipe(), error = Pipe()
        process.standardOutput = output; process.standardError = error
        try process.run(); process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "MCPContextV2WireTests", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: stderr, as: UTF8.self)])
        }
        return String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
