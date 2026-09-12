import Foundation
import XCTest
@testable import AIShellMCP

private final class Recorder<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    func append(_ element: Element) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(element)
    }

    var values: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class MCPServerStartupOutcomeTests: XCTestCase {
    private func runStartup(
        toolProfile: String? = nil,
        capabilitySet: String? = nil
    ) async -> (outcome: MCPServerOutcome, diagnostics: [String], responses: [JSONValue]) {
        let diagnostics = Recorder<String>()
        let responses = Recorder<JSONValue>()
        let writer = MCPResponseWriter { data in
            var line = data
            if line.last == 0x0A { line.removeLast() }
            if let decoded = try? JSONDecoder.aishell.decode(JSONValue.self, from: line) {
                responses.append(decoded)
            }
        }
        let server = MCPServer(toolProfile: toolProfile, capabilitySet: capabilitySet)
        let outcome = await server.run(writer: writer, diagnostics: { diagnostics.append($0) })
        return (outcome, diagnostics.values, responses.values)
    }

    func testInvalidCapabilitySetIsReportedOnDiagnosticsSinkWithNonZeroExit() async {
        let (outcome, diagnostics, responses) = await runStartup(capabilitySet: "future")

        XCTAssertEqual(outcome, .startupFailure(MCPStartupError.invalidCapabilitySet("future").localizedDescription))
        XCTAssertEqual(outcome.exitCode, 78)
        XCTAssertNotEqual(outcome.exitCode, 0)

        // hostの接続失敗表示に載るのはstderr側なので、型付きメッセージがそこに出ることを固定する。
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertTrue(diagnostics[0].contains("INVALID_CAPABILITY_SET"))
        XCTAssertTrue(diagnostics[0].contains("future"))

        // stdoutのJSON-RPC errorは互換のため従来どおり出し続ける。
        XCTAssertEqual(responses.count, 1)
        let error = responses[0].objectValue?["error"]?.objectValue
        XCTAssertEqual(error?["code"]?.intValue, -32000)
        XCTAssertTrue(error?["message"]?.stringValue?.contains("INVALID_CAPABILITY_SET") == true)
    }

    func testInvalidToolProfileIsReportedOnDiagnosticsSinkWithNonZeroExit() async {
        let (outcome, diagnostics, responses) = await runStartup(toolProfile: "future")

        XCTAssertEqual(outcome, .startupFailure(MCPStartupError.invalidToolProfile("future").localizedDescription))
        XCTAssertEqual(outcome.exitCode, 78)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertTrue(diagnostics[0].contains("INVALID_TOOL_PROFILE"))
        XCTAssertEqual(responses.count, 1)
        let error = responses[0].objectValue?["error"]?.objectValue
        XCTAssertTrue(error?["message"]?.stringValue?.contains("INVALID_TOOL_PROFILE") == true)
    }

    func testFactoryProfileRejectingCapabilitySetIsReportedOnDiagnosticsSink() async {
        let (outcome, diagnostics, _) = await runStartup(toolProfile: "factory", capabilitySet: "expanded-v1")

        XCTAssertEqual(outcome.exitCode, 78)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertTrue(diagnostics[0].contains("FACTORY_PROFILE_CAPABILITY_SET_UNSUPPORTED"))
    }

    func testDiagnosticsLineIsPrefixedWithProcessNameAndTerminated() {
        // 実際のstderrには書かずに、既定sinkが組み立てる文面だけを確認する。
        let rendered = MCPServer.diagnosticsLine("INVALID_CAPABILITY_SET: future")
        XCTAssertEqual(rendered, "aishell-mcp: INVALID_CAPABILITY_SET: future\n")
    }

    func testCompletedOutcomeKeepsZeroExitCode() {
        XCTAssertEqual(MCPServerOutcome.completed.exitCode, 0)
        XCTAssertNotEqual(MCPServerOutcome.completed.exitCode, MCPServerOutcome.startupFailure("x").exitCode)
    }
}
