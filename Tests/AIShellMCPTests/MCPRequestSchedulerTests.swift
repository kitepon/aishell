import Foundation
import XCTest
@testable import AIShellMCP

final class MCPRequestSchedulerTests: XCTestCase {
    func testCancellationInterruptsActiveRequestAndContinuesQueuedRequest() async throws {
        let output = OutputRecorder()
        let writer = MCPResponseWriter { data in await output.append(data) }
        let scheduler = MCPRequestScheduler(writer: writer) { request in
            if request.id == .number(1) {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return nil
                }
            }
            return .success(id: request.id ?? .null, result: .object(["ok": .bool(true)]))
        }

        await scheduler.submit(request(id: 1))
        await scheduler.submit(request(id: 2))
        await scheduler.submit(cancellation(id: 1))
        await scheduler.waitUntilIdle()

        let lines = try parsedLines(await output.data())
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0]["id"] as? Double, 1)
        XCTAssertEqual((lines[0]["error"] as? [String: Any])?["code"] as? Double, -32800)
        XCTAssertEqual(lines[1]["id"] as? Double, 2)
        XCTAssertNotNil(lines[1]["result"])
    }

    func testQueuedCancellationPreventsHandlerExecution() async throws {
        let output = OutputRecorder()
        let calls = CallRecorder()
        let writer = MCPResponseWriter { data in await output.append(data) }
        let scheduler = MCPRequestScheduler(writer: writer) { request in
            await calls.record(request.id)
            if request.id == .number(1) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            return .success(id: request.id ?? .null, result: .object([:]))
        }

        await scheduler.submit(request(id: 1))
        await scheduler.submit(request(id: 2))
        await scheduler.submit(cancellation(id: 2))
        await scheduler.waitUntilIdle()

        let calledIDs = await calls.ids()
        XCTAssertEqual(calledIDs, [.number(1)])
        let lines = try parsedLines(await output.data())
        XCTAssertEqual(Set(lines.compactMap { $0["id"] as? Double }), Set([1.0, 2.0]))
    }

    func testSingleWriterEmitsCompleteJSONLines() async throws {
        let output = OutputRecorder()
        let writer = MCPResponseWriter { data in await output.append(data) }
        let scheduler = MCPRequestScheduler(writer: writer) { request in
            .success(id: request.id ?? .null, result: .object([
                "payload": .string(String(repeating: "x", count: 1_024))
            ]))
        }
        for id in 1...40 {
            await scheduler.submit(request(id: id))
        }
        await scheduler.waitUntilIdle()

        let data = await output.data()
        let rawLines = data.split(separator: 0x0A)
        XCTAssertEqual(rawLines.count, 40)
        for line in rawLines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line)))
        }
    }

    func testRequestCancellationDoesNotCancelDetachedManagedJob() async throws {
        let output = OutputRecorder()
        let managed = ManagedJobProbe()
        let writer = MCPResponseWriter { data in await output.append(data) }
        let scheduler = MCPRequestScheduler(writer: writer) { request in
            Task.detached {
                try? await Task.sleep(for: .milliseconds(30))
                await managed.finish()
            }
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return nil
            }
            return .success(id: request.id ?? .null, result: .object([:]))
        }

        await scheduler.submit(request(id: 7))
        await scheduler.submit(cancellation(id: 7))
        await scheduler.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(50))

        let managedFinished = await managed.isFinished()
        XCTAssertTrue(managedFinished)
        let outputData = await output.data()
        let line = try XCTUnwrap(try parsedLines(outputData).first)
        XCTAssertEqual((line["error"] as? [String: Any])?["code"] as? Double, -32800)
    }

    private func request(id: Int) -> JSONRPCRequest {
        JSONRPCRequest(jsonrpc: "2.0", id: .number(Double(id)), method: "test", params: nil)
    }

    private func cancellation(id: Int) -> JSONRPCRequest {
        JSONRPCRequest(
            jsonrpc: "2.0",
            id: nil,
            method: "notifications/cancelled",
            params: .object(["requestId": .number(Double(id))])
        )
    }

    private func parsedLines(_ data: Data) throws -> [[String: Any]] {
        try data.split(separator: 0x0A).map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        }
    }
}

private actor OutputRecorder {
    private var chunks: [Data] = []

    func append(_ data: Data) { chunks.append(data) }
    func data() -> Data { chunks.reduce(into: Data()) { $0.append($1) } }
}

private actor CallRecorder {
    private var values: [JSONValue?] = []
    func record(_ id: JSONValue?) { values.append(id) }
    func ids() -> [JSONValue?] { values }
}

private actor ManagedJobProbe {
    private var finished = false
    func finish() { finished = true }
    func isFinished() -> Bool { finished }
}
