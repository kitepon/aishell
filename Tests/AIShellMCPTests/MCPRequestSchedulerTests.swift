import Foundation
import XCTest
@testable import AIShellMCP

final class MCPRequestSchedulerTests: XCTestCase, @unchecked Sendable {
    func testSlowOperationDoesNotBlockPingAndCancellationIsDelivered() async throws {
        let output = Output()
        let writer = MCPResponseWriter { output.append($0) }
        let scheduler = MCPRequestScheduler(writer: writer) { request in
            if request.method == "slow" {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return .failure(id: request.id!, code: -32800, message: "中止") }
            }
            return .success(id: request.id!, result: .object([:]))
        }
        await scheduler.submit(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "slow", params: nil))
        await scheduler.submit(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "ping", params: nil))
        for _ in 0..<100 {
            if !output.data().isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let first = try JSONDecoder.aishell.decode(JSONValue.self, from: output.data())
        XCTAssertEqual(first.objectValue?["id"], .number(2))
        await scheduler.submit(JSONRPCRequest(jsonrpc: "2.0", id: nil, method: "notifications/cancelled",
            params: .object(["requestId": .number(1)])))
        try await scheduler.waitUntilIdle()
        let lines = output.data().split(separator: 0x0A)
        XCTAssertEqual(lines.count, 2)
        let cancelled = try JSONDecoder.aishell.decode(JSONValue.self, from: Data(lines[1]))
        XCTAssertEqual(cancelled.objectValue?["error"]?.objectValue?["code"], .number(-32800))
    }

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ data: Data) { lock.withLock { bytes.append(data) } }
        func data() -> Data { lock.withLock { bytes } }
    }
}
