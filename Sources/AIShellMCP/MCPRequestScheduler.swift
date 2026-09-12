import Foundation

actor MCPResponseWriter {
    typealias Sink = @Sendable (Data) async -> Void

    private let sink: Sink
    /// 直前のsink呼び出し。
    ///
    /// `sink`はnonisolatedなasync closureなので、`await sink(...)`でこのactorは解放される。
    /// laneを分けてhandlerが並列に走るようになると、そこへ別のwriteが再入し、2本の応答が
    /// 同時に同じ出力先へ書き込みうる。1行がPIPE_BUFを超えると混線してJSON-linesが壊れる
    /// ため、sinkの呼び出しだけは1本の鎖へ直列化する。
    private var tail: Task<Void, Never>?

    init(sink: @escaping Sink = { data in
        FileHandle.standardOutput.write(data)
    }) {
        self.sink = sink
    }

    func write(_ response: JSONRPCResponse) async throws {
        var data = try JSONEncoder.aishell.encode(response)
        data.append(0x0A)
        // encodeはactor内で完了しているため、鎖へ繋ぐ順序がそのまま出力順になる。
        let previous = tail
        let sink = self.sink
        let task = Task {
            await previous?.value
            await sink(data)
        }
        tail = task
        await task.value
    }
}

/// requestの実行lane。
///
/// `run_check`のような長時間実行が、復旧用controlや読み取りをhead-of-line blockingしない
/// ように分ける。Claude Code 2.1.219でsubagentのnested spawnが既定depth 3になり、1 session
/// あたりの同時agent数が増えて、その全部が同じstdio processへ集中するようになった。
enum MCPRequestLane: Sendable {
    /// 復旧用control。実行系がどれだけ詰まっていても待たせない。
    case recovery
    /// 副作用のない読み取り。互いに並列に走る。
    case readOnly
    /// 副作用があるか長時間実行しうる。1度に1件だけ走らせる。
    case execution

    private static let recoveryTools: Set<String> = [
        "runtime_status", "runtime_open_manager"
    ]
    private static let readOnlyTools: Set<String> = [
        "read_context", "search_context", "artifact_read", "workspace_snapshot"
    ]

    /// 分類できないmethodとtoolはexecutionに落とす。並列化は個別に安全性を確認したものだけへ
    /// 与え、未知のものは従来どおり直列のままにする。
    static func lane(for request: JSONRPCRequest) -> MCPRequestLane {
        switch request.method {
        case "initialize", "ping", "tools/list":
            // 不変stateだけを読む純粋な応答で、実行系に待たされる理由がない。とくにpingは
            // liveness確認なので、詰まっている時こそ答える必要がある。
            return .recovery
        case "tools/call":
            guard let name = request.params?.objectValue?["name"]?.stringValue else {
                return .execution
            }
            if recoveryTools.contains(name) { return .recovery }
            if readOnlyTools.contains(name) { return .readOnly }
            return .execution
        default:
            return .execution
        }
    }
}

actor MCPRequestScheduler {
    typealias Handler = @Sendable (JSONRPCRequest) async -> JSONRPCResponse?

    private struct Pending: Sendable {
        let request: JSONRPCRequest
        let key: String?
    }

    private struct Active {
        let id: JSONValue?
        let key: String?
        let lane: MCPRequestLane
        var cancelled: Bool
        var task: Task<Void, Never>?
    }

    private let handler: Handler
    private let writer: MCPResponseWriter
    /// executionだけがqueueを持つ。recoveryとreadOnlyはsubmitでそのまま起動する。
    private var executionQueue: [Pending] = []
    private var executionIsBusy = false
    private var active: [UInt64: Active] = [:]
    /// request id由来のkeyから実行中tokenへの索引。重複検出とcancelがlaneをまたいで効く。
    private var activeKeys: [String: UInt64] = [:]
    private var nextToken: UInt64 = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(writer: MCPResponseWriter, handler: @escaping Handler) {
        self.writer = writer
        self.handler = handler
    }

    func submit(_ request: JSONRPCRequest) async {
        if request.method == "notifications/cancelled", request.id == nil {
            if let requestID = request.params?.objectValue?["requestId"] {
                await cancel(requestID: requestID)
            }
            return
        }

        let key = request.id.flatMap(Self.requestKey)
        if let key, activeKeys[key] != nil || executionQueue.contains(where: { $0.key == key }) {
            try? await writer.write(.failure(
                id: request.id ?? .null,
                code: -32600,
                message: "同じrequest idが処理中です。"
            ))
            return
        }

        let pending = Pending(request: request, key: key)
        let lane = MCPRequestLane.lane(for: request)
        switch lane {
        case .recovery, .readOnly:
            start(pending, lane: lane)
        case .execution:
            executionQueue.append(pending)
            startNextExecutionIfNeeded()
        }
    }

    func waitUntilIdle() async {
        guard !active.isEmpty || !executionQueue.isEmpty else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    private func cancel(requestID: JSONValue) async {
        guard let key = Self.requestKey(requestID) else { return }
        if let token = activeKeys[key] {
            active[token]?.cancelled = true
            active[token]?.task?.cancel()
            return
        }
        if let index = executionQueue.firstIndex(where: { $0.key == key }) {
            let pending = executionQueue.remove(at: index)
            if let id = pending.request.id {
                try? await writer.write(Self.cancelledResponse(id: id))
            }
            resumeIdleWaitersIfNeeded()
        }
    }

    private func startNextExecutionIfNeeded() {
        guard !executionIsBusy, !executionQueue.isEmpty else { return }
        start(executionQueue.removeFirst(), lane: .execution)
    }

    /// 起動の登録はawaitを挟まずに完了させる。以降のsubmitやcancelが、起動済みrequestを
    /// 必ず`active`側で見つけられるようにするため。
    private func start(_ pending: Pending, lane: MCPRequestLane) {
        let token = nextToken
        nextToken += 1
        if lane == .execution { executionIsBusy = true }
        if let key = pending.key { activeKeys[key] = token }
        active[token] = Active(
            id: pending.request.id, key: pending.key, lane: lane, cancelled: false, task: nil
        )
        let handler = self.handler
        let task = Task { [weak self] in
            let response = await handler(pending.request)
            let taskWasCancelled = Task.isCancelled
            await self?.complete(token: token, response: response, taskWasCancelled: taskWasCancelled)
        }
        active[token]?.task = task
    }

    private func complete(token: UInt64, response: JSONRPCResponse?, taskWasCancelled: Bool) async {
        guard let entry = active[token] else { return }
        // 応答を書き終えるまでkeyを解放しない。同じrequest idの再送は重複として弾く。
        if (entry.cancelled || taskWasCancelled), let id = entry.id {
            try? await writer.write(Self.cancelledResponse(id: id))
        } else if let response {
            try? await writer.write(response)
        }
        active[token] = nil
        if let key = entry.key { activeKeys[key] = nil }
        if entry.lane == .execution { executionIsBusy = false }
        startNextExecutionIfNeeded()
        resumeIdleWaitersIfNeeded()
    }

    private func resumeIdleWaitersIfNeeded() {
        guard active.isEmpty, executionQueue.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    private static func cancelledResponse(id: JSONValue) -> JSONRPCResponse {
        .failure(id: id, code: -32800, message: "Request cancelled")
    }

    private static func requestKey(_ id: JSONValue) -> String? {
        switch id {
        case .string, .number, .null:
            return (try? JSONEncoder.aishell.encode(id))?.base64EncodedString()
        default:
            return nil
        }
    }
}
