import AIShellCore
import Foundation
import XCTest
@testable import AIShellMCP

final class MCPReservedPathWireTests: XCTestCase {
    func testExplicitReservedPathsUseSuccessfulJSONRPCErrorEnvelope() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("aishell-mcp-reserved-wire-\(UUID().uuidString)", isDirectory: true)
        let root = temporary.appendingPathComponent("workspace", isDirectory: true)
        let reserved = root.appendingPathComponent(".aishell-transactions", isDirectory: true)
        let reservedFile = reserved.appendingPathComponent("secret.txt")
        let state = temporary.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: reserved, withIntermediateDirectories: true)
        try Data("reserved wire fixture\n".utf8).write(to: reservedFile)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let runtimeStore = RuntimeStore(baseDirectory: state)
        await runtimeStore.setWorkingDirectoryForTesting(root)
        let server = MCPServer(runtimeStore: runtimeStore, toolProfile: "full")
        let fixtures: [(name: String, arguments: [String: JSONValue])] = [
            ("files_read_text", ["path": .string(reservedFile.path)]),
            ("read_context", ["targets": .array([.string(reservedFile.path)])]),
            ("search_context", [
                "query": .string("fixture"),
                "path": .string(reserved.path)
            ]),
            ("workspace_snapshot", ["path": .string(reserved.path)])
        ]

        for (offset, fixture) in fixtures.enumerated() {
            let response = await server.callTool(
                id: .number(Double(offset + 1)),
                params: .object([
                    "name": .string(fixture.name),
                    "arguments": .object(fixture.arguments)
                ])
            )

            XCTAssertNil(response.error, "\(fixture.name) must remain a JSON-RPC success response")
            let result = try XCTUnwrap(response.result?.objectValue, fixture.name)
            XCTAssertEqual(result["isError"], .bool(true), fixture.name)
            let structured = try XCTUnwrap(result["structuredContent"]?.objectValue, fixture.name)
            XCTAssertEqual(structured["schemaVersion"], .string("aishell.error.v1"), fixture.name)
            XCTAssertEqual(
                structured["error"]?.objectValue?["code"],
                .string("RESERVED_PATH"),
                fixture.name
            )
        }
    }
}
