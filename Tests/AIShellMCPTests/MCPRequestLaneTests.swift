import Foundation
import XCTest
@testable import AIShellMCP

/// laneが分かれていることを、実行系を止めたまま他laneが応答できるかで確認する。
final class MCPRequestLaneTests: XCTestCase {
    func testLaneClassificationFollowsCatalog() {
        XCTAssertEqual(MCPRequestLane.lane(for: toolCall(id: 1, name: "runtime_status")), .recovery)
        XCTAssertEqual(MCPRequestLane.lane(for: toolCall(id: 1, name: "runtime_open_manager")), .recovery)
        XCTAssertEqual(MCPRequestLane.lane(for: toolCall(id: 1, name: "read_context")), .readOnly)
        XCTAssertEqual(MCPRequestLane.lane(for: toolCall(id: 1, name: "search_context")), .readOnly)
        XCTAssertEqual(MCPRequestLane.lane(for: toolCall(id: 1, name: "artifact_read")), .readOnly)
        XCTAssertEqual(MCPRequestLane.lane(for: toolCall(id: 1, name: "workspace_snapshot")), .readOnly)
        XCTAssertEqual(MCPRequestLane.lane(for: toolCall(id: 1, name: "run_check")), .execution)
        XCTAssertEqual(MCPRequestLane.lane(for: toolCall(id: 1, name: "run_observe")), .execution)
        XCTAssertEqual(MCPRequestLane.lane(for: toolCall(id: 1, name: "apply_change_set")), .execution)
        XCTAssertEqual(MCPRequestLane.lane(for: toolCall(id: 1, name: "workspace_wait")), .execution)
        XCTAssertEqual(MCPRequestLane.lane(for: toolCall(id: 1, name: "change_impact")), .execution)
        // 表に無いtoolは直列のまま据え置く。
        XCTAssertEqual(MCPRequestLane.lane(for: toolCall(id: 1, name: "files_write_text")), .execution)
        XCTAssertEqual(MCPRequestLane.lane(for: toolCall(id: 1, name: "process_run")), .execution)
        // 不変stateだけを読むprotocol methodは待たせない。
        XCTAssertEqual(MCPRequestLane.lane(for: method("ping", id: 1)), .recovery)
        XCTAssertEqual(MCPRequestLane.lane(for: method("initialize", id: 1)), .recovery)
        XCTAssertEqual(MCPRequestLane.lane(for: method("tools/list", id: 1)), .recovery)
        XCTAssertEqual(MCPRequestLane.lane(for: method("notifications/initialized", id: nil)), .execution)
    }

    func testLongRunningExecutionDoesNotBlockRecoveryAndReadOnly() async throws {
        let output = OutputRecorder()
        let gate = Gate()
        let writer = MCPResponseWriter { data in await output.append(data) }
        let scheduler = MCPRequestScheduler(writer: writer) { request in
            if Self.toolName(request) == "run_check" { await gate.wait() }
            return .success(id: request.id ?? .null, result: .object(["ok": .bool(true)]))
        }

        await scheduler.submit(toolCall(id: 1, name: "run_check"))
        await scheduler.submit(toolCall(id: 2, name: "runtime_status"))
        await scheduler.submit(toolCall(id: 3, name: "read_context"))

        // run_checkを解放しないまま、recoveryとread-onlyが応答し切ることを確認する。
        let answered = await waitUntil { await output.lineCount() >= 2 }
        XCTAssertTrue(answered, "run_check実行中にruntime_statusとread_contextが応答しなかった")
        let early = try parsedLines(await output.data())
        XCTAssertEqual(Set(early.compactMap { $0["id"] as? Double }), [2, 3])

        await gate.open()
        await scheduler.waitUntilIdle()
        let all = try parsedLines(await output.data())
        XCTAssertEqual(Set(all.compactMap { $0["id"] as? Double }), [1, 2, 3])
    }

    func testReadOnlyRequestsRunConcurrently() async throws {
        let output = OutputRecorder()
        let gate = Gate()
        let starts = CallRecorder()
        let writer = MCPResponseWriter { data in await output.append(data) }
        let scheduler = MCPRequestScheduler(writer: writer) { request in
            await starts.record(request.id)
            await gate.wait()
            return .success(id: request.id ?? .null, result: .object([:]))
        }

        await scheduler.submit(toolCall(id: 1, name: "read_context"))
        await scheduler.submit(toolCall(id: 2, name: "search_context"))

        // 直列なら1件目がgateで止まり、2件目のhandlerは呼ばれない。
        let bothStarted = await waitUntil { await starts.count() == 2 }
        XCTAssertTrue(bothStarted, "read-only laneが並列に走っていない")

        await gate.open()
        await scheduler.waitUntilIdle()
        let lineCount = await output.lineCount()
        XCTAssertEqual(lineCount, 2)
    }

    func testExecutionLaneStaysSerial() async throws {
        let output = OutputRecorder()
        let gate = Gate()
        let starts = CallRecorder()
        let writer = MCPResponseWriter { data in await output.append(data) }
        let scheduler = MCPRequestScheduler(writer: writer) { request in
            await starts.record(request.id)
            await gate.wait()
            return .success(id: request.id ?? .null, result: .object([:]))
        }

        await scheduler.submit(toolCall(id: 1, name: "run_check"))
        await scheduler.submit(toolCall(id: 2, name: "apply_change_set"))

        let leaked = await waitUntil(timeout: 0.3) { await starts.count() > 1 }
        XCTAssertFalse(leaked, "execution laneが同時に2件走った")

        await gate.open()
        await scheduler.waitUntilIdle()
        let startCount = await starts.count()
        let lineCount = await output.lineCount()
        XCTAssertEqual(startCount, 2)
        XCTAssertEqual(lineCount, 2)
    }

    func testDuplicateRequestIDIsRejectedAcrossLanes() async throws {
        let output = OutputRecorder()
        let gate = Gate()
        let writer = MCPResponseWriter { data in await output.append(data) }
        let scheduler = MCPRequestScheduler(writer: writer) { request in
            if Self.toolName(request) == "read_context" { await gate.wait() }
            return .success(id: request.id ?? .null, result: .object([:]))
        }

        await scheduler.submit(toolCall(id: 9, name: "read_context"))
        await scheduler.submit(toolCall(id: 9, name: "runtime_status"))

        let rejected = await waitUntil { await output.lineCount() >= 1 }
        XCTAssertTrue(rejected, "重複request idが弾かれなかった")
        let rejectionData = await output.data()
        let rejection = try XCTUnwrap(try parsedLines(rejectionData).first)
        XCTAssertEqual(rejection["id"] as? Double, 9)
        XCTAssertEqual((rejection["error"] as? [String: Any])?["code"] as? Double, -32600)

        await gate.open()
        await scheduler.waitUntilIdle()
    }

    func testCancellationInterruptsInFlightReadOnlyRequestOnly() async throws {
        let output = OutputRecorder()
        let gate = Gate()
        let writer = MCPResponseWriter { data in await output.append(data) }
        let scheduler = MCPRequestScheduler(writer: writer) { request in
            if request.id == .number(1) {
                do { try await Task.sleep(for: .seconds(10)) } catch { return nil }
            } else {
                await gate.wait()
            }
            return .success(id: request.id ?? .null, result: .object([:]))
        }

        await scheduler.submit(toolCall(id: 1, name: "read_context"))
        await scheduler.submit(toolCall(id: 2, name: "search_context"))
        await scheduler.submit(cancellation(id: 1))

        let cancelled = await waitUntil { await output.lineCount() >= 1 }
        XCTAssertTrue(cancelled, "read-only laneのcancelが効かなかった")
        let cancelledData = await output.data()
        let first = try XCTUnwrap(try parsedLines(cancelledData).first)
        XCTAssertEqual(first["id"] as? Double, 1)
        XCTAssertEqual((first["error"] as? [String: Any])?["code"] as? Double, -32800)

        // 並走していたもう1件はcancelの巻き添えにならない。
        await gate.open()
        await scheduler.waitUntilIdle()
        let lines = try parsedLines(await output.data())
        XCTAssertEqual(lines.count, 2)
        XCTAssertNotNil(lines[1]["result"])
    }

    func testWaitUntilIdleCoversEveryLane() async throws {
        let output = OutputRecorder()
        let writer = MCPResponseWriter { data in await output.append(data) }
        let scheduler = MCPRequestScheduler(writer: writer) { request in
            try? await Task.sleep(for: .milliseconds(30))
            return .success(id: request.id ?? .null, result: .object([:]))
        }

        await scheduler.submit(toolCall(id: 1, name: "run_check"))
        await scheduler.submit(toolCall(id: 2, name: "read_context"))
        await scheduler.submit(toolCall(id: 3, name: "runtime_status"))
        await scheduler.waitUntilIdle()

        let lineCount = await output.lineCount()
        XCTAssertEqual(lineCount, 3)
    }

    /// sink内部で分割書き込みが起きても行が混ざらないこと。laneを並列化すると
    /// 応答writeが再入しうるため、writer側の直列化が効いているかを見る。
    func testConcurrentResponsesRemainCompleteJSONLines() async throws {
        let output = OutputRecorder()
        let writer = MCPResponseWriter { data in
            let half = data.count / 2
            await output.append(Data(data.prefix(half)))
            try? await Task.sleep(for: .milliseconds(1))
            await output.append(Data(data.suffix(from: half)))
        }
        let scheduler = MCPRequestScheduler(writer: writer) { request in
            .success(id: request.id ?? .null, result: .object([
                "payload": .string(String(repeating: "x", count: 4_096))
            ]))
        }

        for id in 1...12 {
            await scheduler.submit(toolCall(id: id, name: "read_context"))
        }
        await scheduler.waitUntilIdle()

        let rawLines = await output.data().split(separator: 0x0A)
        XCTAssertEqual(rawLines.count, 12)
        for line in rawLines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line)))
        }
    }

    private static func toolName(_ request: JSONRPCRequest) -> String? {
        request.params?.objectValue?["name"]?.stringValue
    }

    private func toolCall(id: Int, name: String) -> JSONRPCRequest {
        JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(Double(id)),
            method: "tools/call",
            params: .object(["name": .string(name), "arguments": .object([:])])
        )
    }

    private func method(_ name: String, id: Int?) -> JSONRPCRequest {
        JSONRPCRequest(
            jsonrpc: "2.0",
            id: id.map { .number(Double($0)) },
            method: name,
            params: nil
        )
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

    /// 条件成立を待つ。成立しない場合はhangせずfalseを返し、失敗として報告できるようにする。
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await condition()
    }
}

private actor OutputRecorder {
    private var chunks: [Data] = []

    func append(_ data: Data) { chunks.append(data) }
    func data() -> Data { chunks.reduce(into: Data()) { $0.append($1) } }
    func lineCount() -> Int { data().split(separator: 0x0A).count }
}

private actor CallRecorder {
    private var values: [JSONValue?] = []
    func record(_ id: JSONValue?) { values.append(id) }
    func count() -> Int { values.count }
}

/// 開くまでhandlerを止めておく関門。実行系を止めたまま他laneを観測するために使う。
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }
}
