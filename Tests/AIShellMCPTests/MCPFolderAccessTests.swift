import Foundation
import XCTest
@testable import AIShellCore
@testable import AIShellMCP

final class MCPFolderAccessTests: XCTestCase {
    func testFreshAndLegacyConfigurationsOperateWithoutFolderRegistration() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("aishell-folder-access-\(UUID().uuidString)", isDirectory: true)
        let state = temporary.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = RuntimeStore(baseDirectory: state)
        let server = MCPServer(runtimeStore: store, capabilitySet: "expanded-v1")

        for index in 0..<2 {
            if index == 1 {
                try Data("{\"allowedRootPaths\":[\"/missing/old-root\"],\"isPaused\":false}".utf8)
                    .write(to: store.configurationURL)
            }
            let folder = temporary.appendingPathComponent("project-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("確認用の文字列".utf8).write(to: folder.appendingPathComponent("sample.txt"))
            let snapshot = await server.callTool(id: .number(1), params: .object([
                "name": .string("workspace_snapshot"),
                "arguments": .object(["path": .string(folder.path), "context_budget": .number(0)])
            ]))
            let result = try XCTUnwrap(snapshot.result?.objectValue)
            XCTAssertEqual(result["isError"], .bool(false), "\(result)")
            XCTAssertEqual(result["structuredContent"]?.objectValue?["root"],
                           .string(folder.resolvingSymlinksInPath().path))

            let search = await server.callTool(id: .number(2), params: .object([
                "name": .string("search_context"),
                "arguments": .object([
                    "path": .string(folder.path),
                    "queries": .array([.object([
                        "id": .string("sample"), "kind": .string("fixed"),
                        "pattern": .string("確認用")
                    ])])
                ])
            ]))
            let searchResult = try XCTUnwrap(search.result?.objectValue)
            XCTAssertEqual(searchResult["isError"], .bool(false), "\(searchResult)")
            XCTAssertEqual(searchResult["structuredContent"]?.objectValue?["matches"]?.arrayValue?.count, 1)
        }

        let status = await server.callTool(id: .number(3), params: .object([
            "name": .string("runtime_status"), "arguments": .object([:])
        ]))
        let structured = try XCTUnwrap(status.result?.objectValue?["structuredContent"]?.objectValue)
        XCTAssertEqual(Set(structured.keys), ["relativePathBase", "isPaused", "updatedAt", "managerTool", "nextAction"])
        XCTAssertEqual(structured["isPaused"], .bool(false))
        let schema = try XCTUnwrap(ToolCatalog.listedTools(profile: nil)
            .first { $0.name == "runtime_status" }?.outputSchema?.objectValue)
        let success = try XCTUnwrap(schema["oneOf"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(Set(success["required"]?.arrayValue?.compactMap(\.stringValue) ?? []), Set(structured.keys))
    }
}
