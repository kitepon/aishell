import Foundation

actor MCPResponseWriter {
    typealias Sink = @Sendable (Data) throws -> Void
    private let sink: Sink

    init(sink: @escaping Sink = { try FileHandle.standardOutput.write(contentsOf: $0) }) {
        self.sink = sink
    }

    func write(_ response: JSONRPCResponse) throws {
        var data = try JSONEncoder.aishell.encode(response)
        data.append(0x0A)
        try sink(data)
    }
}

/// 実行中の要求だけを保持する。完了した要求の再送・復旧管理は行わない。
actor MCPRequestScheduler {
    typealias Handler = @Sendable (JSONRPCRequest) async -> JSONRPCResponse?
    private enum RequestID: Hashable { case string(String), number(Double), null }
    private let handler: Handler
    private let writer: MCPResponseWriter
    private var active: [RequestID: Task<Void, Never>] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var writeError: Error?

    init(writer: MCPResponseWriter, handler: @escaping Handler) {
        self.writer = writer
        self.handler = handler
    }

    func submit(_ request: JSONRPCRequest) async {
        if request.method == "notifications/cancelled", request.id == nil {
            if let id = request.params?.objectValue?["requestId"], let key = key(id) { active[key]?.cancel() }
            return
        }
        guard let id = request.id else { return }
        guard let key = key(id) else {
            await write(.failure(id: .null, code: -32600, message: "request idの形式が不正です。"))
            return
        }
        if active[key] != nil {
            await write(.failure(id: id, code: -32600, message: "同じrequest idが処理中です。"))
            return
        }
        active[key] = Task {
            if let response = await handler(request) { await write(response) }
            finish(key)
        }
    }

    func waitUntilIdle() async throws {
        if !active.isEmpty { await withCheckedContinuation { waiters.append($0) } }
        if let writeError { throw writeError }
    }

    private func write(_ response: JSONRPCResponse) async {
        do { try await writer.write(response) }
        catch { writeError = error }
    }

    private func finish(_ key: RequestID) {
        active[key] = nil
        if active.isEmpty {
            let completed = waiters
            waiters.removeAll()
            completed.forEach { $0.resume() }
        }
    }

    private func key(_ id: JSONValue) -> RequestID? {
        switch id {
        case let .string(value): .string(value)
        case let .number(value): .number(value)
        case .null: .null
        default: nil
        }
    }
}
