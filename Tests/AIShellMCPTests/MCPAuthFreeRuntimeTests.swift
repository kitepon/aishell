import Foundation
import XCTest
@testable import AIShellCore
@testable import AIShellMCP

final class MCPAuthFreeRuntimeTests: XCTestCase {
    func testExpandedFullCatalogRetainsAllPreviousTools() throws {
        let tools = try ToolCatalog.listedTools(profile: "full", capabilitySet: "expanded-v1")
        XCTAssertEqual(tools.count, 29)
        let expected: Set<String> = [
            "run_check", "run_observe", "artifact_read", "workspace_snapshot", "workspace_wait",
            "read_context", "search_context", "change_impact", "apply_change_set", "runtime_status", "runtime_open_manager",
            "files_list", "files_search", "files_read_text", "files_stat", "files_tree", "files_create_directory",
            "files_create_text", "files_write_text", "files_replace_text", "files_copy", "files_move", "files_rename", "files_trash",
            "apps_list_running", "apps_list_installed", "apps_open", "apps_activate", "process_run"
        ]
        XCTAssertEqual(Set(tools.map(\.name)), expected)
    }

    func testManagerCompatibilityEntrypointReportsRemovalWithoutOpeningUI() async throws {
        let server = MCPServer(capabilitySet: "expanded-v1")
        let response = await server.callTool(id: .number(1), params: .object([
            "name": .string("runtime_open_manager"), "arguments": .object([:])
        ]))
        XCTAssertEqual(response.result?.objectValue?["isError"], .bool(true))
        XCTAssertEqual(response.result?.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"], .string("MANAGER_REMOVED"))
    }

    func testLegacyPauseIsNotAnOperationGate() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("{\"isPaused\":true}".utf8).write(to: base.appendingPathComponent("runtime.json"))
        let server = MCPServer(runtimeStore: RuntimeStore(baseDirectory: base), capabilitySet: "expanded-v1")
        let response = await server.callTool(id: .number(1), params: .object([
            "name": .string("runtime_status"), "arguments": .object([:])
        ]))
        let result = response.result?.objectValue?["structuredContent"]?.objectValue
        XCTAssertEqual(result?["isPaused"], .bool(false))
        XCTAssertEqual(result?["managerTool"], .null)
    }
}
