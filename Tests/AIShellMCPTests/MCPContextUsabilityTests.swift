import AIShellCore
import CryptoKit
import Foundation
import XCTest
@testable import AIShellMCP

final class MCPContextUsabilityTests: XCTestCase {
    func testSelectedSnapshotFairReadAndSearchExposeUsableCode() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let large = String(repeating: "before\nneedle\nafter\n", count: 20)
        let small = "opening\nspecial\nclosing\n"
        try large.write(to: root.appendingPathComponent("A.swift"), atomically: false, encoding: .utf8)
        try small.write(to: root.appendingPathComponent("B.swift"), atomically: false, encoding: .utf8)
        let sha = SHA256.hash(data: Data(small.utf8)).map { String(format: "%02x", $0) }.joined()
        let store = RuntimeStore(baseDirectory: base.appendingPathComponent("state"))
        await store.setWorkingDirectoryForTesting(root)
        let server = MCPServer(runtimeStore: store, capabilitySet: "expanded-v1")
        func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> [String: JSONValue] {
            let response = await server.callTool(id: .number(1), params: .object([
                "name": .string(name), "arguments": .object(arguments)
            ]))
            XCTAssertNil(response.error)
            return try XCTUnwrap(response.result?.objectValue)
        }
        let snapshot = try await call("workspace_snapshot", [
            "path": .string(root.path), "context_paths": .array([.string("B.swift")]),
            "context_budget": .number(100), "project_profile": .object(["mode": .string("none")])
        ])
        XCTAssertNotEqual(snapshot["isError"], .bool(true))
        let snapshotText = snapshot["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
        XCTAssertTrue(snapshotText.contains("special"))
        XCTAssertFalse(snapshotText.contains("needle"))

        let targets: JSONValue = .array([
            .string("A.swift"), .object(["path": .string("B.swift"), "start_line": .number(2),
                                        "end_line": .number(3), "expected_sha256": .string(sha)])
        ])
        let read = try await call("read_context", ["targets": targets, "byte_budget": .number(80)])
        XCTAssertNotEqual(read["isError"], .bool(true))
        let body = try XCTUnwrap(read["structuredContent"]?.objectValue)
        XCTAssertEqual(body["chunks"]?.arrayValue?.count, 2)
        XCTAssertLessThanOrEqual(body["returnedBytes"]?.intValue ?? Int.max, 80)
        let text = read["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("special\nclosing"))
        XCTAssertFalse(text.contains("opening"))
        let continuation = try XCTUnwrap(body["continuation"])
        try "changed\n".write(to: root.appendingPathComponent("B.swift"), atomically: false, encoding: .utf8)
        let stale = try await call("read_context", ["targets": targets, "byte_budget": .number(80), "continuation": continuation])
        XCTAssertEqual(stale["structuredContent"]?.objectValue?["error"]?.objectValue?["code"], .string("CONTENT_CHANGED"))
        try small.write(to: root.appendingPathComponent("B.swift"), atomically: false, encoding: .utf8)

        let search = try await call("search_context", ["path": .string(root.path), "max_results": .number(2),
            "byte_budget": .number(14000), "queries": .array([
                .object(["id": .string("many"), "kind": .string("fixed"), "pattern": .string("needle"),
                         "before_lines": .number(1), "after_lines": .number(1)]),
                .object(["id": .string("rare"), "kind": .string("fixed"), "pattern": .string("special"),
                         "before_lines": .number(1), "after_lines": .number(1)])
            ])])
        XCTAssertNotEqual(search["isError"], .bool(true))
        let searchBody = try XCTUnwrap(search["structuredContent"]?.objectValue)
        let queries = Set(searchBody["matches"]?.arrayValue?.flatMap { $0.objectValue?["queryIds"]?.arrayValue?.compactMap(\.stringValue) ?? [] } ?? [])
        XCTAssertEqual(queries, ["many", "rare"])
        XCTAssertLessThanOrEqual(searchBody["returnedBytes"]?.intValue ?? Int.max, 14000)
        let searchText = search["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
        XCTAssertTrue(searchText.contains("before\nneedle\nafter"))
        XCTAssertTrue(searchText.contains("opening\nspecial\nclosing"))
        XCTAssertNil(searchBody["contextBlocks"]?.arrayValue?.first?.objectValue?["text"])
        XCTAssertNotNil(searchBody["continuation"])
    }
}
