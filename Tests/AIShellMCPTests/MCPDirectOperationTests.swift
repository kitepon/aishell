import AIShellCore
import Foundation
import XCTest
@testable import AIShellMCP

final class MCPDirectOperationTests: XCTestCase, @unchecked Sendable {
    func testCatalogContainsOnlyDirectOperations() async throws {
        let expected: Set<String> = [
            "files_list", "files_search", "files_read_text", "files_stat", "files_tree",
            "files_create_directory", "files_create_text", "files_write_text", "files_replace_text",
            "files_copy", "files_move", "files_rename", "files_trash",
            "apps_list_running", "apps_list_installed", "apps_open", "apps_activate", "process_run"
        ]
        XCTAssertEqual(Set(ToolCatalog.tools.map(\.name)), expected)
        XCTAssertTrue(ToolCatalog.tools.allSatisfy { $0.outputSchema?.objectValue?["type"] == .string("object") })
        let response = await MCPServer().handle(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "initialize", params: nil))
        XCTAssertEqual(response?.result?.objectValue?["serverInfo"]?.objectValue?["version"], .string(AIShellProduct.version))
        let removed = await MCPServer().callTool(id: .number(2), params: params("runtime_open_manager"))
        XCTAssertEqual(removed.error?.code, -32602)
    }

    func testWritesNeedNoSetupKeyOrPriorHashAndKeepUsageLog() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let oldState = fixture.base.appendingPathComponent("log/runtime.json")
        try Data("{\"isPaused\":true}".utf8).write(to: oldState)
        let oldRecord = fixture.base.appendingPathComponent("log/apply-change-set")
        try Data("旧編集記録は読まない".utf8).write(to: oldRecord)
        for content in ["", "日本語\r\n$HOME; *", "更新"] {
            let write = await fixture.server.callTool(id: .number(1), params: params("files_write_text", [
                "path": .string("exact.txt"), "content": .string(content)
            ]))
            XCTAssertEqual(write.result?.objectValue?["isError"], .bool(false))
            XCTAssertEqual(try String(contentsOf: fixture.base.appendingPathComponent("exact.txt"), encoding: .utf8), content)
        }
        let read = await fixture.server.callTool(id: .number(2), params: params("files_read_text", ["path": .string("exact.txt")]))
        XCTAssertEqual(structured(read)?["text"], .string("更新"))
        let records = try fixture.records()
        XCTAssertEqual(records.count, 4)
        XCTAssertTrue(records.allSatisfy(\.success))
        XCTAssertEqual(try String(contentsOf: oldState, encoding: .utf8), "{\"isPaused\":true}")
        XCTAssertEqual(try String(contentsOf: oldRecord, encoding: .utf8), "旧編集記録は読まない")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: oldState.deletingLastPathComponent().path)),
                       ["runtime.json", "apply-change-set", "activity.jsonl"])
    }

    func testWrongTypesAndUnknownArgumentsFailWithoutMutation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let cases: [(String, [String: JSONValue])] = [
            ("files_write_text", ["path": .string("bad"), "content": .bool(true)]),
            ("files_list", ["path": .null]),
            ("files_stat", ["path": .string("."), "include_hash": .string("false")]),
            ("files_tree", ["limit": .number(1.5)]),
            ("files_tree", ["limit": .number(0)]),
            ("files_list", ["unknown": .bool(true)]),
            ("process_run", ["executable": .string("/usr/bin/true"), "arguments": .array([.number(1)])]),
            ("process_run", ["executable": .string("/usr/bin/true"), "environment": .object(["BAD": .bool(true)])])
        ]
        for (name, arguments) in cases {
            let response = await fixture.server.callTool(id: .number(1), params: params(name, arguments))
            XCTAssertEqual(response.result?.objectValue?["isError"], .bool(true))
            XCTAssertEqual(structured(response)?["error"]?.objectValue?["code"], .string("INVALID_ARGUMENT"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.appendingPathComponent("bad").path))
        XCTAssertEqual(try fixture.records().count, cases.count)
        XCTAssertTrue(try fixture.records().allSatisfy { !$0.success })
    }

    func testOSFailureAndNonzeroExitRemainVisible() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let missing = await fixture.server.callTool(id: .number(1), params: params("files_read_text", ["path": .string("missing")]))
        XCTAssertEqual(missing.result?.objectValue?["isError"], .bool(true))
        XCTAssertEqual(structured(missing)?["error"]?.objectValue?["code"], .string("ITEM_NOT_FOUND"))
        let nonzero = await fixture.server.callTool(id: .number(2), params: params("process_run", ["executable": .string("/usr/bin/false")]))
        XCTAssertEqual(nonzero.result?.objectValue?["isError"], .bool(true))
        XCTAssertEqual(structured(nonzero)?["exitCode"], .number(1))
        XCTAssertTrue(try fixture.records().allSatisfy { !$0.success })
    }

    func testLogFailureDoesNotHideCompletedWrite() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let occupied = fixture.base.appendingPathComponent("not-a-directory")
        try Data().write(to: occupied)
        let server = MCPServer(workingDirectory: fixture.base, usageLog: UsageLog(directory: occupied))
        let response = await server.callTool(id: .number(1), params: params("files_write_text", ["path": .string("written"), "content": .string("actual")]))
        XCTAssertEqual(response.result?.objectValue?["isError"], .bool(true))
        XCTAssertEqual(structured(response)?["name"], .string("written"))
        XCTAssertNotNil(structured(response)?["logging_error"])
        XCTAssertEqual(try String(contentsOf: fixture.base.appendingPathComponent("written"), encoding: .utf8), "actual")
    }

    private func params(_ name: String, _ arguments: [String: JSONValue] = [:]) -> JSONValue {
        .object(["name": .string(name), "arguments": .object(arguments)])
    }

    private func structured(_ response: JSONRPCResponse) -> [String: JSONValue]? {
        response.result?.objectValue?["structuredContent"]?.objectValue
    }

    private struct Fixture {
        let base: URL
        let server: MCPServer

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("AIShellWire-\(UUID().uuidString)", isDirectory: true)
            let logs = base.appendingPathComponent("log", isDirectory: true)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            server = MCPServer(workingDirectory: base, usageLog: UsageLog(directory: logs))
        }

        func records() throws -> [OperationRecord] {
            let text = try String(contentsOf: base.appendingPathComponent("log/activity.jsonl"), encoding: .utf8)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try text.split(separator: "\n").map { try decoder.decode(OperationRecord.self, from: Data($0.utf8)) }
        }

        func cleanup() { try? FileManager.default.removeItem(at: base) }
    }
}
