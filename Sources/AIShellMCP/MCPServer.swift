import AIShellCore
import Foundation

private struct ManagedChangeSetInput {
    let root: URL
    let workspaceCursor: String
    let changes: [ApplyChangeSetChange]
    let diffByteBudget: Int
    let retentionSeconds: Int
}

typealias MCPDiagnosticsSink = @Sendable (String) -> Void

/// `run()`の終了理由。processのexit codeはここだけから決まる。
enum MCPServerOutcome: Equatable, Sendable {
    case completed
    case startupFailure(String)

    /// 起動時設定の誤りは`EX_CONFIG`(sysexits.h)で返し、正常終了と区別できるようにする。
    var exitCode: Int32 {
        switch self {
        case .completed:
            return 0
        case .startupFailure:
            return 78
        }
    }
}

/// stored propertyはすべて`let`かつSendableで、可変stateは`MCPServiceRegistry`と
/// 各serviceのactorが所有する。したがってhandlerを並列に走らせても同期は不要であり、
/// `Sendable`適合はcompilerが検証する（`@unchecked`ではない）。
final class MCPServer: Sendable {
    private let store: RuntimeStore
    private let toolProfile: String
    private let capabilitySet: String?
    private let files: NativeFileService
    private let processes: NativeProcessService
    private let development: DevelopmentRuntimeService
    private let services: MCPServiceRegistry

    init(
        runtimeStore: RuntimeStore = RuntimeStore(),
        toolProfile: String? = nil,
        capabilitySet: String? = ProcessInfo.processInfo.environment["AISHELL_CAPABILITY_SET"],
        developmentRuntime: DevelopmentRuntimeService? = nil,
        managedRunService: ManagedRunService? = nil
    ) {
        store = runtimeStore
        self.toolProfile = toolProfile
            ?? ProcessInfo.processInfo.environment["AISHELL_TOOL_PROFILE"]
            ?? "development"
        self.capabilitySet = capabilitySet
        files = NativeFileService(store: runtimeStore)
        processes = NativeProcessService(store: runtimeStore)
        let development = developmentRuntime ?? DevelopmentRuntimeService(runtimeStore: runtimeStore)
        self.development = development
        services = MCPServiceRegistry(
            store: runtimeStore,
            workspaceRuntime: development.workspaceRuntime,
            managedRunService: managedRunService
        )
    }

    @discardableResult
    func run(
        writer: MCPResponseWriter = MCPResponseWriter(),
        diagnostics: @escaping MCPDiagnosticsSink = MCPServer.standardErrorDiagnostics
    ) async -> MCPServerOutcome {
        do {
            try validateStartup()
        } catch {
            let message = error.localizedDescription
            // 起動時検証の失敗はinitializeへの応答にならないため、stdoutのJSON-RPC errorだけでは
            // hostに「応答せず終了した」としか見えない。型付きメッセージをstderrにも出し、
            // 非0 exitで終了することでhost側の接続失敗表示に載せる。
            diagnostics(message)
            try? await writer.write(.failure(id: .null, code: -32000, message: message))
            return .startupFailure(message)
        }
        let scheduler = MCPRequestScheduler(writer: writer) { [self] request in
            await handle(request)
        }
        while let line = readLine() {
            guard let data = line.data(using: .utf8) else { continue }

            do {
                let request = try JSONDecoder.aishell.decode(JSONRPCRequest.self, from: data)
                await scheduler.submit(request)
            } catch {
                let response = JSONRPCResponse.failure(
                    id: .null,
                    code: -32700,
                    message: "JSON-RPCを解析できません: \(error.localizedDescription)"
                )
                try? await writer.write(response)
            }
        }
        await scheduler.waitUntilIdle()
        return .completed
    }

    static func diagnosticsLine(_ message: String) -> String {
        "aishell-mcp: \(message)\n"
    }

    static let standardErrorDiagnostics: MCPDiagnosticsSink = { message in
        FileHandle.standardError.write(Data(MCPServer.diagnosticsLine(message).utf8))
    }

    private func handle(_ request: JSONRPCRequest) async -> JSONRPCResponse? {
        guard request.jsonrpc == "2.0" else {
            return request.id.map {
                .failure(id: $0, code: -32600, message: "jsonrpcは2.0である必要があります。")
            }
        }

        guard let id = request.id else {
            return nil
        }

        switch request.method {
        case "initialize":
            return .success(id: id, result: .object([
                "protocolVersion": .string("2025-11-25"),
                "capabilities": .object([
                    "tools": .object(["listChanged": .bool(false)])
                ]),
                "serverInfo": .object([
                    "name": .string("aishell-macos"),
                    "version": .string(AIShellProduct.version)
                ]),
                "instructions": .string("macOSの生きたfilesystem・process・artifact状態を直接所有します。AIはtaskに応じてtool利用を自分で判断します。依頼成果が一覧の1 toolへ直接一致する時はshell/native代替より先にそのtoolを使い、workspace accessが不要ならtoolを呼びません。tinyなsingle-file taskはhost native toolを使います。反復またはmulti-file観測はworkspace_snapshotから開始し埋込contextを先に使います。SHA付きmulti-file編集はsnapshotのopaque cursorをそのままapply_change_setへ渡します。client IDやsequenceの管理は不要です。32KiB超の出力が見込まれる検査だけrun_checkを使い、artifact_readは主要診断が不足する時だけ使います。search_context/read_contextはsnapshot不足時のdrilldownです。 Choose tools autonomously. When the requested outcome directly matches one listed tool, call that tool before shell or native alternatives. Call no tool when the answer needs no workspace access. Snapshot multi-file state, observe existing runs, wait on workspace cursors without polling, and apply SHA-guarded edits atomically.")
            ]))

        case "ping":
            return .success(id: id, result: .object([:]))

        case "tools/list":
            do {
                return .success(id: id, result: .object([
                    "tools": try .from(ToolCatalog.listedTools(
                        profile: toolProfile, capabilitySet: capabilitySet
                    ))
                ]))
            } catch {
                return .failure(id: id, code: -32603, message: error.localizedDescription)
            }

        case "tools/call":
            return await callTool(id: id, params: request.params)

        default:
            return .failure(id: id, code: -32601, message: "未対応のmethodです: \(request.method)")
        }
    }

    func callTool(id: JSONValue, params: JSONValue?) async -> JSONRPCResponse {
        guard let params = params?.objectValue,
              let name = params["name"]?.stringValue else {
            return .failure(id: id, code: -32602, message: "tools/callにはnameが必要です。")
        }
        let listedTools: [MCPTool]
        do {
            listedTools = try ToolCatalog.listedTools(profile: toolProfile, capabilitySet: capabilitySet)
        } catch {
            return .failure(id: id, code: -32000, message: error.localizedDescription)
        }
        guard listedTools.contains(where: { $0.name == name }) else {
            return .failure(id: id, code: -32602, message: "未定義のtoolです: \(name)")
        }
        let arguments: [String: JSONValue]
        if let value = params["arguments"] {
            guard let object = value.objectValue else {
                return .failure(id: id, code: -32602, message: "tools/callのargumentsはobjectである必要があります。")
            }
            arguments = object
        } else {
            arguments = [:]
        }

        do {
            let result = try await invoke(name: name, arguments: arguments)
            let text = try resultText(name: name, result: result)
            let structured = structuredProjection(name: name, result: result)
            return .success(id: id, result: .object([
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string(text)
                ])]),
                "structuredContent": structured,
                "isError": .bool(false)
            ]))
        } catch {
            let stableError = stableError(error)
            return .success(id: id, result: .object([
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string("\(stableError.code): \(stableError.message)")
                ])]),
                "structuredContent": structuredFailure(
                    name: name,
                    error: error,
                    stable: stableError
                ),
                "isError": .bool(true)
            ]))
        }
    }

    func validateStartup() throws {
        _ = try ToolCatalog.listedTools(profile: toolProfile, capabilitySet: capabilitySet)
    }

    /// 起動時検証と同じ判定をその場で行う。判定材料は`let`だけなので、結果をflagとして
    /// 保持せずに済み、handlerが並列に走っても読み取りが競合しない。
    private var isToolCatalogValid: Bool {
        (try? ToolCatalog.listedTools(profile: toolProfile, capabilitySet: capabilitySet)) != nil
    }

    private func invoke(name: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        switch name {
        case "factory_diagnostics":
            try validateKeys(arguments, allowed: [])
            return try await .from(FactoryDiagnosticsService(store: store).diagnose(
                managerApplicationURL: nil,
                mcpReady: isToolCatalogValid
            ))
        case "run_check":
            switch try MCPRunCheckAdapter.runCheck(arguments: arguments) {
            case .legacy(let legacy):
                return try await .from(development.runCheck(
                    executable: legacy.executable,
                    arguments: legacy.arguments,
                    workingDirectory: legacy.workingDirectory,
                    environment: legacy.environment,
                    timeoutSeconds: legacy.timeoutSeconds,
                    retentionSeconds: legacy.retentionSeconds
                ))
            case .v2(let request):
                switch request.selection {
                case .prepare:
                    let plan = try RunCheckInvocationPlan.prepare(.init(
                        invocation: request.invocation,
                        dispatch: request.dispatch,
                        cachePolicy: request.cachePolicy,
                        executionPolicy: request.executionPolicy
                    ))
                    if case let .start(clientRunKey) = plan.dispatch {
                        guard case let .direct(direct) = plan.invocation else {
                            throw RunCheckPipelineError.dispatchNotReady(processesStarted: 0)
                        }
                        return try await .from(services.managedRunService().start(
                            clientRunKey: clientRunKey,
                            requestDigest: plan.requestDigest,
                            planDigest: plan.digest,
                            executable: direct.executable,
                            arguments: direct.arguments,
                            workingDirectory: direct.workingDirectory,
                            environment: direct.effectiveEnvironment,
                            timeoutSeconds: Double(plan.executionPolicy.timeoutMilliseconds) / 1_000,
                            retentionSeconds: TimeInterval(plan.executionPolicy.retentionSeconds)
                        ))
                    }
                    return try await .from(development.runCheck(plan: plan))
                case .prepareFocusedSet(let setDigest):
                    return try await .from(development.runFocusedCheck(
                        invocation: request.invocation,
                        dispatch: request.dispatch,
                        cachePolicy: request.cachePolicy,
                        executionPolicy: request.executionPolicy,
                        focusedSetDigest: setDigest
                    ))
                case .focusedSet(let setDigest, let selectionDigest):
                    return try await .from(development.runFocusedCheck(
                        invocation: request.invocation,
                        dispatch: request.dispatch,
                        cachePolicy: request.cachePolicy,
                        executionPolicy: request.executionPolicy,
                        focusedSetDigest: setDigest,
                        expectedSelectionDigest: selectionDigest
                    ))
                }
            }
        case "run_observe":
            let action = try requiredString("action", in: arguments)
            switch action {
            case "status":
                try validateKeys(arguments, allowed: ["action", "run_handle"])
                return try await .from(services.managedRunService().status(
                    runHandle: requiredString("run_handle", in: arguments)
                ))
            case "read":
                try validateKeys(arguments, allowed: ["action", "run_handle", "cursor", "byte_budget"])
                return try await .from(services.managedRunService().read(
                    runHandle: requiredString("run_handle", in: arguments),
                    cursor: try strictOptionalString("cursor", in: arguments),
                    byteBudget: try boundedInt(
                        "byte_budget", in: arguments, default: 65_536,
                        minimum: 1, maximum: 1_048_576
                    )
                ))
            case "wait":
                try validateKeys(arguments, allowed: [
                    "action", "run_handle", "after_state_revision", "cursor", "timeout_ms"
                ])
                return try await .from(services.managedRunService().wait(
                    runHandle: requiredString("run_handle", in: arguments),
                    afterStateRevision: UInt64(try boundedInt(
                        "after_state_revision", in: arguments, default: 0,
                        minimum: 0, maximum: Int.max
                    )),
                    cursor: try strictOptionalString("cursor", in: arguments),
                    timeoutMilliseconds: try boundedInt(
                        "timeout_ms", in: arguments, default: 30_000,
                        minimum: 1, maximum: 300_000
                    )
                ))
            case "cancel":
                try validateKeys(arguments, allowed: ["action", "run_handle"])
                return try await .from(services.managedRunService().cancel(
                    runHandle: requiredString("run_handle", in: arguments)
                ))
            default:
                throw AIShellError.invalidArgument(
                    "run_observe actionはstatus、read、wait、cancelのいずれかです。"
                )
            }
        case "change_impact":
            switch try MCPRunCheckAdapter.changeImpact(arguments: arguments) {
            case .analyze(let request):
                return try await .from(development.analyzeChangeImpact(request))
            case .recommend(let request):
                return try await .from(development.recommendChangeImpact(request))
            case .continuation(let continuation):
                switch try await development.continueChangeImpact(
                    continuation: continuation.token,
                    byteBudget: continuation.byteBudget
                ) {
                case .analyze(let result): return try .from(result)
                case .recommend(let result): return try .from(result)
                }
            }
        case "artifact_read":
            if capabilitySet == "expanded-v1", let action = try strictOptionalString("action", in: arguments) {
                switch action {
                case "search":
                    try validateKeys(arguments, allowed: [
                        "action", "project_path", "sources", "pattern_kind", "pattern",
                        "case", "regex_flags", "page_byte_limit"
                    ])
                    guard let values = arguments["sources"]?.arrayValue,
                          (1 ... 64).contains(values.count) else {
                        throw AIShellError.invalidArgument("sourcesは1〜64件の配列である必要があります。")
                    }
                    let sources = try values.map { value -> ManagedArtifactQuerySource in
                        guard let source = value.objectValue else {
                            throw AIShellError.invalidArgument("sourceはobjectである必要があります。")
                        }
                        switch try requiredString("type", in: source) {
                        case "artifact":
                            try validateKeys(source, allowed: ["type", "handle"])
                            return .artifact(handle: try requiredString("handle", in: source))
                        case "run":
                            try validateKeys(source, allowed: ["type", "run_id", "channels"])
                            guard let runID = UUID(uuidString: try requiredString("run_id", in: source)) else {
                                throw AIShellError.invalidArgument("run_idはUUIDである必要があります。")
                            }
                            return .run(id: runID, channels: Set(try stringArray("channels", in: source)))
                        default:
                            throw AIShellError.invalidArgument("source.typeはartifactまたはrunです。")
                        }
                    }
                    let patternText = try requiredString("pattern", in: arguments)
                    let caseMode = try strictOptionalString("case", in: arguments) ?? "sensitive"
                    let pattern: ArtifactQueryService.Pattern
                    switch try strictOptionalString("pattern_kind", in: arguments) ?? "literal" {
                    case "literal":
                        guard caseMode == "sensitive" || caseMode == "insensitive" else {
                            throw AIShellError.invalidArgument("caseはsensitiveまたはinsensitiveです。")
                        }
                        pattern = .literal(
                            patternText,
                            mode: caseMode == "insensitive" ? .insensitive : .sensitive
                        )
                    case "regex":
                        var flags = try strictOptionalString("regex_flags", in: arguments) ?? ""
                        if caseMode == "insensitive", !flags.contains("i") { flags.append("i") }
                        guard caseMode == "sensitive" || caseMode == "insensitive" else {
                            throw AIShellError.invalidArgument("caseはsensitiveまたはinsensitiveです。")
                        }
                        pattern = .regex(patternText, flags: flags)
                    default:
                        throw AIShellError.invalidArgument("pattern_kindはliteralまたはregexです。")
                    }
                    return try await .from(services.managedRunService().searchArtifacts(
                        projectPath: requiredString("project_path", in: arguments),
                        sources: sources,
                        pattern: pattern,
                        pageByteLimit: try boundedInt(
                            "page_byte_limit", in: arguments, default: 65_536,
                            minimum: 1, maximum: 1_048_576
                        )
                    ))
                case "next":
                    try validateKeys(arguments, allowed: [
                        "action", "stream_handle", "cursor", "page_byte_limit"
                    ])
                    return try await .from(services.managedRunService().continueArtifactSearch(
                        streamHandle: requiredString("stream_handle", in: arguments),
                        cursor: requiredString("cursor", in: arguments),
                        pageByteLimit: try boundedInt(
                            "page_byte_limit", in: arguments, default: 65_536,
                            minimum: 1, maximum: 1_048_576
                        )
                    ))
                case "compare":
                    try validateKeys(arguments, allowed: [
                        "action", "project_path", "baseline_run_id", "candidate_run_id", "channels"
                    ])
                    guard let baseline = UUID(uuidString: try requiredString("baseline_run_id", in: arguments)),
                          let candidate = UUID(uuidString: try requiredString("candidate_run_id", in: arguments)) else {
                        throw AIShellError.invalidArgument("baseline_run_idとcandidate_run_idはUUIDである必要があります。")
                    }
                    return try await .from(services.managedRunService().compareArtifacts(
                        projectPath: requiredString("project_path", in: arguments),
                        baselineRunID: baseline,
                        candidateRunID: candidate,
                        channels: Set(try stringArray("channels", in: arguments))
                    ))
                default:
                    throw AIShellError.invalidArgument("artifact_read actionはsearch、next、compareのいずれかです。")
                }
            }
            try validateKeys(arguments, allowed: [
                "handle", "mode", "offset", "length", "tail_lines", "pattern",
                "context_lines", "byte_budget"
            ])
            let modeName = try strictOptionalString("mode", in: arguments) ?? "range"
            let mode: ArtifactReadMode
            switch modeName {
            case "range":
                mode = .range(
                    offset: try boundedInt("offset", in: arguments, default: 0, minimum: 0, maximum: Int.max),
                    length: try boundedInt("length", in: arguments, default: 65_536, minimum: 0, maximum: 1_048_576)
                )
            case "tail":
                mode = .tail(lines: try boundedInt("tail_lines", in: arguments, default: 100, minimum: 1, maximum: 1_000_000))
            case "around":
                mode = .around(
                    pattern: try requiredString("pattern", in: arguments),
                    contextLines: try boundedInt("context_lines", in: arguments, default: 2, minimum: 0, maximum: 10_000)
                )
            default:
                throw AIShellError.invalidArgument("modeはrange、tail、aroundのいずれかです。")
            }
            return try await .from(development.readArtifact(
                handle: requiredString("handle", in: arguments),
                mode: mode,
                byteBudget: try boundedInt("byte_budget", in: arguments, default: 65_536, minimum: 1, maximum: 1_048_576)
            ))
        case "workspace_snapshot":
            try validateKeys(arguments, allowed: [
                "path", "since_cursor", "entry_limit", "context_budget", "git_diff", "project_profile"
            ])
            let path = try strictOptionalString("path", in: arguments)
            let sinceCursor = try strictOptionalString("since_cursor", in: arguments)
            let entryLimit = try boundedInt("entry_limit", in: arguments, default: 500, minimum: 1, maximum: 5_000)
            let contextBudget = try boundedInt("context_budget", in: arguments, default: 16_384, minimum: 0, maximum: 65_536)
            if arguments["git_diff"] != nil || arguments["project_profile"] != nil {
                return try await .from(development.workspaceSnapshotV2(
                    path: path,
                    sinceCursor: sinceCursor,
                    entryLimit: entryLimit,
                    contextBudget: contextBudget,
                    gitDiffRequest: try gitDiffRequest(arguments["git_diff"]),
                    projectProfileRequest: try projectProfileRequest(arguments["project_profile"])
                ))
            }
            return try await .from(development.workspaceSnapshot(
                path: path,
                sinceCursor: sinceCursor,
                entryLimit: entryLimit,
                contextBudget: contextBudget
            ))
        case "workspace_wait":
            try validateKeys(arguments, allowed: ["path", "from_cursor", "timeout_ms"])
            return try await .from(development.workspaceRuntime.workspaceWait(
                path: try strictOptionalString("path", in: arguments),
                fromCursor: try requiredString("from_cursor", in: arguments),
                timeoutSeconds: Double(try boundedInt(
                    "timeout_ms", in: arguments, default: 30_000,
                    minimum: 0, maximum: 300_000
                )) / 1_000
            ))
        case "read_context":
            try validateKeys(arguments, allowed: ["targets", "byte_budget", "continuation"])
            return try await .from(development.readContext(
                targets: try stringArray("targets", in: arguments),
                byteBudget: try boundedInt("byte_budget", in: arguments, default: 65_536, minimum: 1, maximum: 1_048_576),
                continuation: try strictOptionalString("continuation", in: arguments)
            ))
        case "search_context":
            try validateKeys(arguments, allowed: [
                "action", "query", "queries", "path", "ranking", "changed_since_cursor",
                "provider", "cursor", "max_results", "byte_budget", "continuation"
            ])
            if arguments["query"] != nil {
                guard arguments["queries"] == nil, arguments["action"] == nil else {
                    throw AIShellError.invalidArgument("queryとv2 requestは同時指定できません。")
                }
                return try await .from(development.searchContext(
                    query: try requiredString("query", in: arguments),
                    path: try strictOptionalString("path", in: arguments),
                    maxResults: try boundedInt("max_results", in: arguments, default: 50, minimum: 1, maximum: 500),
                    byteBudget: try boundedInt("byte_budget", in: arguments, default: 65_536, minimum: 1, maximum: 1_048_576),
                    continuation: try strictOptionalString("continuation", in: arguments)
                ))
            }
            if let continuation = try strictOptionalString("continuation", in: arguments) {
                guard arguments.count == 1 else {
                    throw AIShellError.invalidArgument("continuationと初回fieldは同時指定できません。")
                }
                return try await .from(development.searchContextV2(continuation: continuation))
            }
            let action = try strictOptionalString("action", in: arguments) ?? "search"
            if action == "semantic" {
                return try await .from(development.semanticSearchContext(
                    request: try semanticSearchContextRequest(arguments)
                ))
            }
            guard action == "search" else {
                throw AIShellError.invalidArgument("actionはsearchまたはsemanticです。")
            }
            return try await .from(development.searchContextV2(
                request: try searchContextRequest(arguments)
            ))
        case "apply_change_set":
            try validateKeys(arguments, allowed: [
                "path", "workspace_cursor", "changes",
                "diff_byte_budget", "retention_seconds"
            ])
            let request = try managedChangeSetInput(arguments)
            let service = try await changeSetService(rootPath: request.root.path)
            let result = try await service.applyManaged(
                root: request.root,
                workspaceCursor: request.workspaceCursor,
                changes: request.changes,
                diffByteBudget: request.diffByteBudget,
                retentionSeconds: request.retentionSeconds
            )
            return applyChangeSetJSON(result)
        case "runtime_status":
            return try await runtimeStatus()
        case "runtime_open_manager":
            throw AIShellError.managerRemoved
        case "files_list":
            return try await .from(files.list(path: optionalString("path", in: arguments)))
        case "files_search":
            return try await .from(files.search(
                query: try requiredString("query", in: arguments),
                path: optionalString("path", in: arguments),
                limit: arguments["limit"]?.intValue ?? 100
            ))
        case "files_read_text":
            return .object([
                "text": .string(try await files.readText(path: requiredString("path", in: arguments)))
            ])
        case "files_stat":
            return try await .from(files.stat(
                path: requiredString("path", in: arguments),
                includeHash: arguments["include_hash"]?.boolValue ?? true
            ))
        case "files_tree":
            return try await .from(files.tree(
                path: optionalString("path", in: arguments),
                maxDepth: arguments["max_depth"]?.intValue ?? 4,
                limit: arguments["limit"]?.intValue ?? 500
            ))
        case "files_create_directory":
            return try await .from(files.createDirectory(path: requiredString("path", in: arguments)))
        case "files_create_text":
            return try await .from(files.createTextFile(
                path: requiredString("path", in: arguments),
                content: requiredString("content", in: arguments)
            ))
        case "files_write_text":
            return try await .from(files.writeText(
                path: requiredString("path", in: arguments),
                content: requiredStringAllowingEmpty("content", in: arguments),
                expectedSHA256: optionalString("expected_sha256", in: arguments)
            ))
        case "files_replace_text":
            return try await .from(files.replaceText(
                path: requiredString("path", in: arguments),
                oldText: requiredString("old_text", in: arguments),
                newText: requiredStringAllowingEmpty("new_text", in: arguments),
                replaceAll: arguments["replace_all"]?.boolValue ?? false
            ))
        case "files_copy":
            return try await .from(files.copy(
                source: requiredString("source", in: arguments),
                destination: requiredString("destination", in: arguments)
            ))
        case "files_move":
            return try await .from(files.move(
                source: requiredString("source", in: arguments),
                destination: requiredString("destination", in: arguments)
            ))
        case "files_rename":
            return try await .from(files.rename(
                path: requiredString("path", in: arguments),
                newName: requiredString("new_name", in: arguments)
            ))
        case "files_trash":
            return .object([
                "trashed_path": .string(try await files.trash(path: requiredString("path", in: arguments)))
            ])
        case "apps_list_running":
            return try await .from(NativeApplicationService(store: store).listRunningApplications())
        case "apps_list_installed":
            return try await .from(NativeApplicationService(store: store).listInstalledApplications())
        case "apps_open":
            return try await .from(NativeApplicationService(store: store).openApplication(
                bundleIdentifier: requiredString("bundle_identifier", in: arguments)
            ))
        case "apps_activate":
            return try await .from(NativeApplicationService(store: store).activateApplication(
                bundleIdentifier: requiredString("bundle_identifier", in: arguments)
            ))
        case "process_run":
            return try await .from(processes.run(
                executable: requiredString("executable", in: arguments),
                arguments: try stringArray("arguments", in: arguments),
                workingDirectory: optionalString("working_directory", in: arguments),
                environment: try stringMap("environment", in: arguments),
                timeoutSeconds: arguments["timeout_seconds"]?.doubleValue ?? 120
            ))
        default:
            throw AIShellError.invalidArgument("未定義のtoolです: \(name)")
        }
    }

    private func runtimeStatus() async throws -> JSONValue {
        let configuration = try await store.loadConfiguration()
        let resolver = await store.pathResolver()
        let nextAction = "利用可能です。管理UIと認証は不要です。相対パスはrelativePathBaseを基準にします。"
        return .object([
            "relativePathBase": .string(resolver.rootURL.path),
            "isPaused": .bool(configuration.isPaused),
            "updatedAt": .string(ISO8601DateFormatter().string(from: configuration.updatedAt)),
            "managerTool": .null,
            "nextAction": .string(nextAction)
        ])
    }

    private func requiredString(_ key: String, in arguments: [String: JSONValue]) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw AIShellError.invalidArgument("\(key)には空でない文字列が必要です。")
        }
        return value
    }

    private func requiredStringAllowingEmpty(
        _ key: String,
        in arguments: [String: JSONValue]
    ) throws -> String {
        guard let value = arguments[key]?.stringValue else {
            throw AIShellError.invalidArgument("\(key)には文字列が必要です。")
        }
        return value
    }

    private func optionalString(_ key: String, in arguments: [String: JSONValue]) -> String? {
        arguments[key]?.stringValue
    }

    private func strictOptionalString(_ key: String, in arguments: [String: JSONValue]) throws -> String? {
        guard let value = arguments[key] else { return nil }
        guard let string = value.stringValue else {
            throw AIShellError.invalidArgument("\(key)には文字列が必要です。")
        }
        return string
    }

    private func boundedInt(
        _ key: String,
        in arguments: [String: JSONValue],
        default defaultValue: Int,
        minimum: Int,
        maximum: Int
    ) throws -> Int {
        guard let value = arguments[key] else { return defaultValue }
        guard let integer = value.intValue, (minimum...maximum).contains(integer) else {
            throw AIShellError.invalidArgument("\(key)は\(minimum)〜\(maximum)の整数である必要があります。")
        }
        return integer
    }

    private func optionalBoundedInt(
        _ key: String,
        in arguments: [String: JSONValue],
        minimum: Int,
        maximum: Int
    ) throws -> Int? {
        guard arguments[key] != nil else { return nil }
        return try boundedInt(key, in: arguments, default: minimum, minimum: minimum, maximum: maximum)
    }

    private func boundedDouble(
        _ key: String,
        in arguments: [String: JSONValue],
        default defaultValue: Double,
        minimum: Double,
        maximum: Double
    ) throws -> Double {
        guard let value = arguments[key] else { return defaultValue }
        guard let number = value.doubleValue, number.isFinite, (minimum...maximum).contains(number) else {
            throw AIShellError.invalidArgument("\(key)は\(minimum)〜\(maximum)の数値である必要があります。")
        }
        return number
    }

    private func stringArray(_ key: String, in arguments: [String: JSONValue]) throws -> [String] {
        guard let value = arguments[key] else { return [] }
        guard let array = value.arrayValue else {
            throw AIShellError.invalidArgument("\(key)には文字列配列が必要です。")
        }
        return try array.map { item in
            guard let string = item.stringValue else {
                throw AIShellError.invalidArgument("\(key)には文字列配列が必要です。")
            }
            return string
        }
    }

    private func stringMap(_ key: String, in arguments: [String: JSONValue]) throws -> [String: String] {
        guard let value = arguments[key] else { return [:] }
        guard let object = value.objectValue else {
            throw AIShellError.invalidArgument("\(key)には文字列値のobjectが必要です。")
        }
        return try object.mapValues { item in
            guard let string = item.stringValue else {
                throw AIShellError.invalidArgument("\(key)の値は文字列である必要があります。")
            }
            return string
        }
    }

    private func gitDiffRequest(_ value: JSONValue?) throws -> GitDiffContextRequest? {
        guard let value else { return nil }
        guard let object = value.objectValue else {
            throw AIShellError.invalidArgument("git_diffはobjectである必要があります。")
        }
        try validateKeys(object, allowed: ["mode", "base_ref", "byte_budget", "include_patch", "continuation"])
        let continuation = try strictOptionalString("continuation", in: object)
        if continuation != nil, Set(object.keys).subtracting(["continuation", "byte_budget"]).isEmpty == false {
            throw AIShellError.invalidArgument("git_diff continuationと初回fieldは同時指定できません。")
        }
        return GitDiffContextRequest(
            mode: try strictOptionalString("mode", in: object).map {
                guard let mode = GitComparisonMode(rawValue: $0) else {
                    throw AIShellError.invalidArgument("git_diff modeはworktreeまたはbranchです。")
                }
                return mode
            },
            baseRef: try strictOptionalString("base_ref", in: object),
            byteBudget: try boundedInt("byte_budget", in: object, default: 65_536, minimum: 1, maximum: 1_048_576),
            includePatch: try strictOptionalBool("include_patch", in: object) ?? true,
            continuation: continuation
        )
    }

    private func projectProfileRequest(_ value: JSONValue?) throws -> ProjectProfileProjectionRequest? {
        guard let value else { return nil }
        guard let object = value.objectValue else {
            throw AIShellError.invalidArgument("project_profileはobjectである必要があります。")
        }
        try validateKeys(object, allowed: ["mode", "project_ids", "byte_budget", "profile_limit", "continuation"])
        let continuation = try strictOptionalString("continuation", in: object)
        if continuation != nil, Set(object.keys).subtracting(["continuation", "byte_budget", "profile_limit"]).isEmpty == false {
            throw AIShellError.invalidArgument("project_profile continuationと初回fieldは同時指定できません。")
        }
        let modeName = try strictOptionalString("mode", in: object) ?? "auto"
        guard let mode = ProjectProfileProjectionMode(rawValue: modeName) else {
            throw AIShellError.invalidArgument("project_profile.modeはauto、all、noneのいずれかです。")
        }
        return ProjectProfileProjectionRequest(
            mode: mode,
            projectIDs: try stringArray("project_ids", in: object),
            byteBudget: try boundedInt("byte_budget", in: object, default: 65_536, minimum: 1_024, maximum: 262_144),
            profileLimit: try boundedInt("profile_limit", in: object, default: 100, minimum: 1, maximum: 1_000),
            continuation: continuation
        )
    }

    private func searchContextRequest(_ arguments: [String: JSONValue]) throws -> SearchContextRequestV2 {
        guard let queryValues = arguments["queries"]?.arrayValue, !queryValues.isEmpty else {
            throw AIShellError.invalidArgument("queriesは1件以上必要です。")
        }
        let queries = try queryValues.map { value -> SearchContextQueryV2 in
            guard let object = value.objectValue else {
                throw AIShellError.invalidArgument("queriesの各要素はobjectである必要があります。")
            }
            try validateKeys(object, allowed: [
                "id", "kind", "pattern", "case", "before_lines", "after_lines", "include_globs", "exclude_globs"
            ])
            guard let kind = SearchContextQueryKind(rawValue: try requiredString("kind", in: object)) else {
                throw AIShellError.invalidArgument("query.kindはfixed、regex、globのいずれかです。")
            }
            guard let caseMode = SearchContextCaseMode(rawValue: try strictOptionalString("case", in: object) ?? "sensitive") else {
                throw AIShellError.invalidArgument("query.caseはsensitive、insensitive、smartのいずれかです。")
            }
            return SearchContextQueryV2(
                id: try requiredString("id", in: object),
                kind: kind,
                pattern: try requiredString("pattern", in: object),
                caseMode: caseMode,
                beforeLines: try boundedInt("before_lines", in: object, default: 0, minimum: 0, maximum: 20),
                afterLines: try boundedInt("after_lines", in: object, default: 0, minimum: 0, maximum: 20),
                includeGlobs: try stringArray("include_globs", in: object),
                excludeGlobs: try stringArray("exclude_globs", in: object)
            )
        }
        let changedSinceCursor = try strictOptionalString("changed_since_cursor", in: arguments)
        let rankings: [SearchContextRanking]
        if let values = arguments["ranking"]?.arrayValue {
            rankings = try values.map { value in
                guard let raw = value.stringValue, let ranking = SearchContextRanking(rawValue: raw) else {
                    throw AIShellError.invalidArgument("rankingはchanged、testsの配列です。")
                }
                return ranking
            }
        } else {
            rankings = changedSinceCursor == nil ? [.tests] : [.changed, .tests]
        }
        return SearchContextRequestV2(
            path: try strictOptionalString("path", in: arguments),
            queries: queries,
            ranking: rankings,
            changedSinceCursor: changedSinceCursor,
            maxResults: try boundedInt("max_results", in: arguments, default: 50, minimum: 1, maximum: 500),
            byteBudget: try boundedInt("byte_budget", in: arguments, default: 65_536, minimum: 1_024, maximum: 1_048_576)
        )
    }

    private func semanticSearchContextRequest(
        _ arguments: [String: JSONValue]
    ) throws -> SemanticSearchContextRequest {
        guard let queryValues = arguments["queries"]?.arrayValue, !queryValues.isEmpty else {
            throw AIShellError.invalidArgument("semantic queriesは1件以上必要です。")
        }
        let queries = try queryValues.map { value -> SemanticSearchContextQuery in
            guard let object = value.objectValue else {
                throw AIShellError.invalidArgument("semantic queriesの各要素はobjectである必要があります。")
            }
            try validateKeys(object, allowed: ["id", "kind", "pattern", "operation", "path", "line", "character"])
            guard try requiredString("kind", in: object) == "semantic" else {
                throw AIShellError.invalidArgument("semantic query.kindはsemanticです。")
            }
            guard let operation = SourceKitLSPOperation(rawValue: try requiredString("operation", in: object)),
                  operation != .diagnostics else {
                throw AIShellError.invalidArgument("semantic operationはdefinition、references、workspace_symbolsです。")
            }
            return SemanticSearchContextQuery(
                id: try requiredString("id", in: object),
                pattern: try requiredString("pattern", in: object),
                operation: operation,
                path: try strictOptionalString("path", in: object),
                line: try optionalBoundedInt("line", in: object, minimum: 0, maximum: 10_000_000),
                character: try optionalBoundedInt("character", in: object, minimum: 0, maximum: 10_000_000)
            )
        }
        return SemanticSearchContextRequest(
            path: try strictOptionalString("path", in: arguments),
            queries: queries,
            provider: try requiredString("provider", in: arguments),
            cursor: try requiredString("cursor", in: arguments),
            maxResults: try boundedInt("max_results", in: arguments, default: 50, minimum: 1, maximum: 500),
            byteBudget: try boundedInt("byte_budget", in: arguments, default: 65_536, minimum: 1_024, maximum: 1_048_576)
        )
    }

    private func managedChangeSetInput(_ arguments: [String: JSONValue]) throws -> ManagedChangeSetInput {
        guard let values = arguments["changes"]?.arrayValue, (1...128).contains(values.count) else {
            throw AIShellError.invalidArgument("changesは1〜128件の配列である必要があります。")
        }
        var identifiers = Set<String>()
        let changes = try values.map { value -> ApplyChangeSetChange in
            guard let change = value.objectValue else {
                throw AIShellError.invalidArgument("changesの各要素はobjectである必要があります。")
            }
            try validateKeys(change, allowed: [
                "change_id", "operation", "path", "source", "destination", "expected",
                "source_expected", "destination_expected", "content"
            ])
            let identifier = try requiredString("change_id", in: change)
            guard identifiers.insert(identifier).inserted else {
                throw AIShellError.invalidArgument("change_idはrequest内で一意である必要があります。")
            }
            switch try requiredString("operation", in: change) {
            case "create":
                try requireExactKeys(change, required: ["change_id", "operation", "path", "expected", "content"])
                return .create(
                    id: identifier,
                    path: try requiredString("path", in: change),
                    expected: try expectedState("expected", in: change),
                    content: try changeSetContent("content", in: change)
                )
            case "write":
                try requireExactKeys(change, required: ["change_id", "operation", "path", "expected", "content"])
                return .write(
                    id: identifier,
                    path: try requiredString("path", in: change),
                    expected: try expectedState("expected", in: change),
                    content: try changeSetContent("content", in: change)
                )
            case "delete":
                try requireExactKeys(change, required: ["change_id", "operation", "path", "expected"])
                return .delete(
                    id: identifier,
                    path: try requiredString("path", in: change),
                    expected: try expectedState("expected", in: change)
                )
            case "rename":
                try requireExactKeys(change, required: [
                    "change_id", "operation", "source", "source_expected", "destination", "destination_expected"
                ])
                return .rename(
                    id: identifier,
                    source: try requiredString("source", in: change),
                    sourceExpected: try expectedState("source_expected", in: change),
                    destination: try requiredString("destination", in: change),
                    destinationExpected: try expectedState("destination_expected", in: change)
                )
            default:
                throw AIShellError.invalidArgument("operationはcreate、write、delete、renameのいずれかです。")
            }
        }
        return ManagedChangeSetInput(
            root: URL(fileURLWithPath: try requiredString("path", in: arguments), isDirectory: true),
            workspaceCursor: try requiredString("workspace_cursor", in: arguments),
            changes: changes,
            diffByteBudget: try boundedInt(
                "diff_byte_budget", in: arguments, default: 65_536, minimum: 1, maximum: 1_048_576
            ),
            retentionSeconds: try boundedInt(
                "retention_seconds", in: arguments, default: 86_400, minimum: 1, maximum: 604_800
            )
        )
    }

    private func requiredObject(_ key: String, in object: [String: JSONValue]) throws -> [String: JSONValue] {
        guard let value = object[key]?.objectValue else {
            throw AIShellError.invalidArgument("\(key)にはobjectが必要です。")
        }
        return value
    }

    private func requireExactKeys(_ object: [String: JSONValue], required: Set<String>) throws {
        guard Set(object.keys) == required else {
            throw AIShellError.invalidArgument("operation固有fieldが不足または余分です。")
        }
    }

    private func expectedState(_ key: String, in object: [String: JSONValue]) throws -> ApplyChangeSetExpected {
        let expected = try requiredObject(key, in: object)
        try validateKeys(expected, allowed: ["state", "sha256"])
        switch try requiredString("state", in: expected) {
        case "absent":
            guard Set(expected.keys) == ["state"] else {
                throw AIShellError.invalidArgument("state=absentへsha256は指定できません。")
            }
            return .absent
        case "file":
            guard Set(expected.keys) == ["state", "sha256"] else {
                throw AIShellError.invalidArgument("state=fileにはsha256が必要です。")
            }
            let sha256 = try requiredString("sha256", in: expected)
            guard sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw AIShellError.invalidArgument("sha256は64桁のlowercase hexadecimalである必要があります。")
            }
            return .file(sha256)
        default:
            throw AIShellError.invalidArgument("expected.stateはabsentまたはfileである必要があります。")
        }
    }

    private func changeSetContent(_ key: String, in object: [String: JSONValue]) throws -> ApplyChangeSetContent {
        let content = try requiredObject(key, in: object)
        guard Set(content.keys) == ["encoding", "data"] else {
            throw AIShellError.invalidArgument("contentにはencodingとdataだけが必要です。")
        }
        let data = try requiredStringAllowingEmpty("data", in: content)
        switch try requiredString("encoding", in: content) {
        case "utf8": return .utf8(data)
        case "base64":
            guard Data(base64Encoded: data) != nil else {
                throw AIShellError.invalidArgument("content.dataは有効なbase64である必要があります。")
            }
            return .base64(data)
        default:
            throw AIShellError.invalidArgument("content.encodingはutf8またはbase64である必要があります。")
        }
    }

    private func changeSetService(rootPath: String) async throws -> ApplyChangeSetService {
        let resolver = await store.pathResolver()
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        _ = try resolver.resolveExisting(root.path)
        return try await services.changeSetService(root: root)
    }

    func applyChangeSetJSON(_ result: ApplyChangeSetResult) -> JSONValue {
        let status: String
        switch result.status {
        case .committed: status = "committed"
        case .abortedBeforeSideEffect: status = "aborted_before_side_effect"
        case .recoveryRequired: status = "recovery_required"
        }
        let changes = result.changes.map { change -> JSONValue in
            .object([
                "change_id": jsonString(change.changeID),
                "kind": jsonString(change.kind),
                "before_path": jsonString(change.beforePath),
                "after_path": jsonString(change.afterPath),
                "before_identity": jsonString(change.beforeIdentity),
                "after_identity": jsonString(change.afterIdentity),
                "before_sha256": jsonString(change.beforeSHA256),
                "after_sha256": jsonString(change.afterSHA256),
                "before_size_bytes": jsonInt(change.beforeSizeBytes),
                "after_size_bytes": jsonInt(change.afterSizeBytes),
                "before_metadata": change.beforeMetadata.map { .object(["mode": .number(Double($0.mode))]) } ?? .null,
                "after_metadata": change.afterMetadata.map { .object(["mode": .number(Double($0.mode))]) } ?? .null,
                "trash_path": jsonString(change.trashPath),
                "after_content": jsonString(change.afterContent)
            ])
        }
        let summary = result.summary.map { value in
            JSONValue.object([
                "create_count": .number(Double(value.createCount)),
                "write_count": .number(Double(value.writeCount)),
                "delete_count": .number(Double(value.deleteCount)),
                "rename_count": .number(Double(value.renameCount)),
                "before_bytes": .number(Double(value.beforeBytes)),
                "after_bytes": .number(Double(value.afterBytes))
            ])
        } ?? .null
        let expiresAt = result.diffArtifact.expiresAt.map {
            JSONValue.string(ISO8601DateFormatter().string(from: $0))
        } ?? .null
        return .object([
            "schemaVersion": .string("aishell.apply-change-set.v1"),
            "transaction_id": jsonString(result.transactionID),
            "client_id": jsonString(result.clientID),
            "client_epoch": jsonInt(result.clientEpoch),
            "request_sequence": .number(Double(result.requestSequence)),
            "status": .string(status),
            "visibility": .string("aishell_serialized_recoverable"),
            "root": jsonString(result.root),
            "from_cursor": changeSetCursorJSON(result.fromCursor),
            "cursor": changeSetCursorJSON(result.cursor),
            "changes": .array(changes),
            "changed_paths": .array(result.changedPaths.map(JSONValue.string)),
            "transaction_cursor_advanced": .bool(result.transactionCursorAdvanced),
            "summary": summary,
            "diff_preview": jsonString(result.diffPreview),
            "returned_diff_bytes": .number(Double(result.returnedDiffBytes)),
            "omitted_diff_bytes": .number(Double(result.omittedDiffBytes)),
            "has_more": result.hasMore.map(JSONValue.bool) ?? .null,
            "diff_artifact": .object([
                "handle": .string(result.diffArtifact.handle),
                "sha256": .string(result.diffArtifact.sha256),
                "size_bytes": .number(Double(result.diffArtifact.sizeBytes)),
                "expires_at": expiresAt
            ])
        ])
    }

    func applyChangeSetJSON(_ result: ManagedApplyChangeSetResult) -> JSONValue {
        guard case var .object(object) = applyChangeSetJSON(result.transaction) else {
            preconditionFailure("apply_change_set projection must be an object")
        }
        object["workspace_from_cursor"] = .string(result.workspaceFromCursor)
        object["workspace_cursor"] = .string(result.workspaceCursor)
        return .object(object)
    }

    private func changeSetCursorJSON(_ cursor: ApplyChangeSetCursor) -> JSONValue {
        .object([
            "root": .string(cursor.root),
            "generation": .string(cursor.generation),
            "sequence": .number(Double(cursor.sequence))
        ])
    }

    private func jsonString(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
    private func jsonInt(_ value: Int?) -> JSONValue { value.map { .number(Double($0)) } ?? .null }

    private func strictOptionalBool(_ key: String, in arguments: [String: JSONValue]) throws -> Bool? {
        guard let value = arguments[key] else { return nil }
        guard let result = value.boolValue else {
            throw AIShellError.invalidArgument("\(key)にはbooleanが必要です。")
        }
        return result
    }

    private func validateKeys(_ arguments: [String: JSONValue], allowed: Set<String>) throws {
        let unexpected = Set(arguments.keys).subtracting(allowed).sorted()
        guard unexpected.isEmpty else {
            throw AIShellError.invalidArgument("未定義の引数です: \(unexpected.joined(separator: ", "))")
        }
    }

    func stableError(_ error: Error) -> (code: String, message: String) {
        if let error = error as? MCPRunCheckAdapter.Error {
            return ("INVALID_ARGUMENT", String(describing: error))
        }
        if let error = error as? RunCheckInvocationPlan.Error {
            return (error.code, String(describing: error))
        }
        if let error = error as? RunCheckPipelineError {
            return (error.code, String(describing: error))
        }
        if let error = error as? ChangeImpactError {
            let code: String = switch error {
            case .invalidOperation: "CHANGE_IMPACT_INVALID_OPERATION"
            case .notReady: "CHANGE_IMPACT_NOT_READY"
            case .invalidRequest: "INVALID_ARGUMENT"
            case .requestTooLarge: "REQUEST_TOO_LARGE"
            case .contentChanged: "CONTENT_CHANGED"
            case .requiredProviderNotFresh: "CHANGE_IMPACT_PROVIDER_NOT_FRESH"
            case .providerFailure: "CHANGE_IMPACT_PROVIDER_FAILED"
            case .resultItemTooLarge: "RESULT_ITEM_TOO_LARGE"
            case .byteBudgetTooSmall: "BYTE_BUDGET_TOO_SMALL"
            case .invalidContinuation: "INVALID_CONTINUATION"
            case .invalidContinuationRequest: "INVALID_CONTINUATION_REQUEST"
            case .continuationExpired: "CONTINUATION_EXPIRED"
            case .evidenceIDCollision: "EVIDENCE_ID_COLLISION"
            case .recommendationJoinFailed: "RECOMMENDATION_JOIN_FAILED"
            }
            return (code, String(describing: error))
        }
        if let error = error as? ApplyChangeSetError {
            let code: String
            switch error.code {
            case .invalidArgument: code = "INVALID_ARGUMENT"
            case .contentChanged: code = "STALE_CONTENT"
            case .expectedAbsenceViolated: code = "EXPECTED_ABSENCE_VIOLATED"
            case .workspaceChanged: code = "WORKSPACE_CHANGED"
            case .rootMismatch: code = "ROOT_MISMATCH"
            case .transactionVolumeMismatch: code = "TRANSACTION_VOLUME_MISMATCH"
            case .unsupportedChangeTarget: code = "UNSUPPORTED_CHANGE_TARGET"
            case .changeSetConflict: code = "CHANGE_SET_CONFLICT"
            case .transactionCapabilityUnavailable: code = "TRANSACTION_CAPABILITY_UNAVAILABLE"
            case .reservedNamespaceConflict: code = "RESERVED_NAMESPACE_CONFLICT"
            case .externalConflictDuringCommit: code = "EXTERNAL_CONFLICT_DURING_COMMIT"
            case .changeSetStoreCorrupt: code = "CHANGE_SET_STORE_CORRUPT"
            case .changeSetRecoveryRequired: code = "CHANGE_SET_RECOVERY_REQUIRED"
            case .changeSetLimitExceeded: code = "CHANGE_SET_LIMIT_EXCEEDED"
            case .changeSetClientNotRegistered: code = "CHANGE_SET_CLIENT_NOT_REGISTERED"
            case .changeSetExpired: code = "CHANGE_SET_EXPIRED"
            case .changeSetClientEpochAhead: code = "CHANGE_SET_CLIENT_EPOCH_AHEAD"
            case .changeSetSequenceGap: code = "CHANGE_SET_SEQUENCE_GAP"
            case .changeSetSequenceConflict: code = "CHANGE_SET_SEQUENCE_CONFLICT"
            case .changeSetPreviousPending: code = "CHANGE_SET_PREVIOUS_PENDING"
            case .changeSetClientCapacityExceeded: code = "CHANGE_SET_CLIENT_CAPACITY_EXCEEDED"
            case .clientRotationBlocked: code = "CLIENT_ROTATION_BLOCKED"
            case .clientRetireBlocked: code = "CLIENT_RETIRE_BLOCKED"
            case .clientRegistryReinitializeBlocked: code = "CLIENT_REGISTRY_REINITIALIZE_BLOCKED"
            case .clientControlCapacityExceeded: code = "CLIENT_CONTROL_CAPACITY_EXCEEDED"
            case .changeSetReservationCorrupt: code = "CHANGE_SET_RESERVATION_CORRUPT"
            case .changeSetSecretStoreUnavailable: code = "CHANGE_SET_SECRET_STORE_UNAVAILABLE"
            case .clientEpochChanged: code = "CLIENT_EPOCH_CHANGED"
            case .clientControlExpired: code = "CLIENT_CONTROL_EXPIRED"
            case .clientEpochExhausted: code = "CLIENT_EPOCH_EXHAUSTED"
            }
            return (code, error.message.isEmpty ? code : error.message)
        }
        if let error = error as? SearchContextServiceError {
            switch error {
            case .invalidArgument: return ("INVALID_ARGUMENT", String(describing: error))
            case .invalidRegex: return ("INVALID_REGEX", String(describing: error))
            case .invalidGlob: return ("INVALID_GLOB", String(describing: error))
            case .rescanRequired: return ("RESCAN_REQUIRED", String(describing: error))
            case .cursorExpired: return ("CURSOR_EXPIRED", String(describing: error))
            case .contentChanged: return ("CONTENT_CHANGED", String(describing: error))
            case .workerUnavailable: return ("WORKER_UNAVAILABLE", String(describing: error))
            case .workerTimeout: return ("WORKER_TIMEOUT", String(describing: error))
            case .outputLimitExceeded: return ("OUTPUT_LIMIT_EXCEEDED", String(describing: error))
            case .workerFailed: return ("WORKER_FAILED", String(describing: error))
            case .workerOutputInvalid: return ("WORKER_OUTPUT_INVALID", String(describing: error))
            case .notTextFile: return ("NOT_TEXT_FILE", String(describing: error))
            case .artifactStoreFailed: return ("ARTIFACT_STORE_FAILED", String(describing: error))
            case .resultEncodingFailed: return ("RESULT_ENCODING_FAILED", String(describing: error))
            }
        }
        if let error = error as? ManagedArtifactQueryError {
            switch error {
            case .invalidProjectPath: return ("INVALID_PROJECT_PATH", String(describing: error))
            case .invalidSource: return ("INVALID_ARGUMENT", String(describing: error))
            case .invalidChannel: return ("INVALID_ARGUMENT", String(describing: error))
            }
        }
        if let error = error as? ManagedRunArtifactStoreError {
            switch error {
            case .bindingMismatch: return ("ARTIFACT_BINDING_MISMATCH", String(describing: error))
            case .runNotFinalized: return ("RUN_NOT_FINALIZED", String(describing: error))
            case .artifactNotFound: return ("ARTIFACT_NOT_FOUND", String(describing: error))
            case .runExpired: return ("RUN_EXPIRED", String(describing: error))
            case .scopeMismatch: return ("ARTIFACT_SCOPE_MISMATCH", String(describing: error))
            case .legacyArtifactUnbound: return ("ARTIFACT_SCOPE_MISMATCH", String(describing: error))
            case .storeCorrupt: return ("EVIDENCE_CORRUPT", String(describing: error))
            }
        }
        if let error = error as? ArtifactQueryService.Error {
            return (error.localizedDescription.components(separatedBy: ":").first ?? "ARTIFACT_QUERY_FAILED", error.localizedDescription)
        }
        if let error = error as? DiagnosticAdapterError {
            return ("DIAGNOSTIC_PARSE_FAILED", error.localizedDescription)
        }
        if let error = error as? GitContextError {
            switch error {
            case .notGitRepository: return ("NOT_GIT_REPOSITORY", error.localizedDescription)
            case .repositoryOutsideAllowedRoot: return ("REPOSITORY_OUTSIDE_WORKSPACE", error.localizedDescription)
            case .unresolvedBase: return ("UNRESOLVED_BASE", error.localizedDescription)
            case .invalidComparisonMode: return ("INVALID_COMPARISON_MODE", error.localizedDescription)
            case .unbornHeadWithExplicitBase: return ("UNBORN_HEAD_WITH_EXPLICIT_BASE", error.localizedDescription)
            case .pathEncodingUnsupported: return ("PATH_ENCODING_UNSUPPORTED", error.localizedDescription)
            case .contentChanged: return ("CONTENT_CHANGED", error.localizedDescription)
            case .invalidContinuation: return ("INVALID_CONTINUATION", error.localizedDescription)
            case .cursorExpired: return ("CURSOR_EXPIRED", error.localizedDescription)
            case .gitFailed: return ("GIT_FAILED", error.localizedDescription)
            case .artifactPublicationFailed: return ("ARTIFACT_PUBLICATION_FAILED", error.localizedDescription)
            }
        }
        guard let error = error as? AIShellError else {
            return ("INTERNAL_ERROR", error.localizedDescription)
        }
        switch error {
        case .managerRemoved: return ("MANAGER_REMOVED", error.localizedDescription)
        case .paused: return ("RUNTIME_PAUSED", error.localizedDescription)
        case .outsideWorkspace: return ("OUTSIDE_WORKSPACE", error.localizedDescription)
        case .reservedPath: return ("RESERVED_PATH", error.localizedDescription)
        case .invalidPath: return ("INVALID_PATH", error.localizedDescription)
        case .itemAlreadyExists: return ("ITEM_ALREADY_EXISTS", error.localizedDescription)
        case .itemNotFound: return ("ITEM_NOT_FOUND", error.localizedDescription)
        case .notTextFile: return ("NOT_TEXT_FILE", error.localizedDescription)
        case .textFileTooLarge: return ("TEXT_TOO_LARGE", error.localizedDescription)
        case .applicationNotFound: return ("APPLICATION_NOT_FOUND", error.localizedDescription)
        case .applicationActivationFailed: return ("APPLICATION_ACTIVATION_FAILED", error.localizedDescription)
        case .contentChanged: return ("CONTENT_CHANGED", error.localizedDescription)
        case .executableNotAllowed: return ("EXECUTABLE_NOT_ALLOWED", error.localizedDescription)
        case .processLaunchFailed: return ("PROCESS_LAUNCH_FAILED", error.localizedDescription)
        case .handleNotFound: return ("ARTIFACT_NOT_FOUND", error.localizedDescription)
        case .handleExpired: return ("HANDLE_EXPIRED", error.localizedDescription)
        case .evidenceQuotaExceeded: return ("EVIDENCE_QUOTA_EXCEEDED", error.localizedDescription)
        case .checkpointCorrupt: return ("CHECKPOINT_CORRUPT", error.localizedDescription)
        case .checkpointUnsupported: return ("CHECKPOINT_UNSUPPORTED", error.localizedDescription)
        case .checkpointMigrationFailed: return ("CHECKPOINT_MIGRATION_FAILED", error.localizedDescription)
        case .checkpointQuotaExceeded: return ("CHECKPOINT_QUOTA_EXCEEDED", error.localizedDescription)
        case .checkpointWriteFailed: return ("CHECKPOINT_WRITE_FAILED", error.localizedDescription)
        case .cursorExpired: return ("CURSOR_EXPIRED", error.localizedDescription)
        case .rescanRequired: return ("RESCAN_REQUIRED", error.localizedDescription)
        case .workerUnavailable: return ("WORKER_UNAVAILABLE", error.localizedDescription)
        case .invalidArgument: return ("INVALID_ARGUMENT", error.localizedDescription)
        }
    }

    func structuredError(_ error: Error, stable: (code: String, message: String)) -> JSONValue {
        var object: [String: JSONValue] = [
            "code": .string(stable.code),
            "message": .string(stable.message)
        ]
        if let changeSet = error as? ApplyChangeSetError,
           changeSet.code == .changeSetSecretStoreUnavailable, changeSet.context == nil {
            // 鍵の取得はservice生成と編集開始より前。過去取引の状態は推定しない。
            object["request_status"] = .string("aborted_before_side_effect")
            object["changed_paths"] = .array([])
            object["next_action"] = .string("check_local_state_key_then_retry")
        }
        if let context = (error as? ApplyChangeSetError)?.context {
            object["transaction_id"] = .string(context.transactionID)
            object["client_id"] = .string(context.clientID)
            object["client_epoch"] = .number(Double(context.clientEpoch))
            object["request_sequence"] = .number(Double(context.requestSequence))
            object["changed_paths"] = .array(context.changedPaths.map(JSONValue.string))
            object["rollback_state"] = .string(context.rollbackState)
            object["recovery_state"] = .string(context.recoveryState)
            object["evidence_handle"] = jsonString(context.evidenceHandle)
            object["next_action"] = .string(context.nextAction)
        }
        return .object(object)
    }

    private func structuredFailure(
        name: String,
        error: Error,
        stable: (code: String, message: String)
    ) -> JSONValue {
        guard name == "run_check", let pipeline = error as? RunCheckPipelineError else {
            return .object([
                "schemaVersion": .string("aishell.error.v1"),
                "error": structuredError(error, stable: stable)
            ])
        }
        let evidence: [CheckFreshnessCache.LookupEvidence]
        if case .cacheMiss(_, let values) = pipeline { evidence = values } else { evidence = [] }
        return .object([
            "schemaVersion": .string("aishell.run-check.v2"),
            "error": .object([
                "code": .string(stable.code),
                "message": .string(stable.message),
                "processesStarted": .number(Double(pipeline.processesStarted)),
                "lookupEvidence": .array(evidence.map { value in
                    .object([
                        "stepID": .string(value.stepID),
                        "status": .string(value.status.rawValue),
                        "ineligibilityReason": value.ineligibilityReason
                            .map { .string($0.rawValue) } ?? .null
                    ])
                })
            ])
        ])
    }

    private func resultText(name: String, result: JSONValue) throws -> String {
        if name == "run_check", let summary = result.objectValue?["summary"]?.stringValue {
            return summary
        }
        if name == "run_check", let object = result.objectValue,
           let state = object["cacheState"]?.stringValue,
           let processes = object["processesStarted"]?.intValue {
            let steps = object["steps"]?.arrayValue ?? []
            let passed = steps.filter { $0.objectValue?["terminalState"]?.stringValue == "passed" }.count
            let failed = steps.count - passed
            return "run_check: cache=\(state) processes=\(processes) steps=\(steps.count) passed=\(passed) failed=\(failed) complete_diagnostics_retained=true; artifact_read is unnecessary unless the user asks to display log contents"
        }
        if name == "change_impact", let object = result.objectValue {
            let operation = object["operation"]?.stringValue ?? "unknown"
            let hasMore = object["hasMore"]?.boolValue ?? false
            return "change_impact: operation=\(operation) has_more=\(hasMore)"
        }
        if name == "artifact_read", let object = result.objectValue {
            if let text = object["text"]?.stringValue { return text }
            if let base64 = object["base64"]?.stringValue { return "base64:\(base64)" }
        }
        if name == "workspace_snapshot", let object = result.objectValue {
            let mode = object["isFull"]?.boolValue == true ? "full" : "delta"
            let entries = object["entries"]?.arrayValue?.count ?? 0
            let changes = object["changes"]?.arrayValue?.count ?? 0
            let omitted = object["omittedEntries"]?.intValue ?? 0
            let cursor = object["cursor"]?.stringValue ?? ""
            let header = "snapshot \(mode): entries=\(entries) changes=\(changes) omitted=\(omitted) cursor=\(cursor)"
            let context = object["context"]?.arrayValue?.compactMap { value -> String? in
                guard let chunk = value.objectValue,
                      let path = chunk["path"]?.stringValue,
                      let text = chunk["text"]?.stringValue else { return nil }
                return "// --- \(path) ---\n\(text)"
            }.joined(separator: "\n") ?? ""
            return context.isEmpty ? header : "\(header)\n\(context)"
        }
        if name == "read_context", let chunks = result.objectValue?["chunks"]?.arrayValue {
            return chunks.compactMap { value in
                guard let object = value.objectValue,
                      let path = object["path"]?.stringValue,
                      let text = object["text"]?.stringValue else { return nil }
                return "// --- \(path) ---\n\(text)"
            }.joined(separator: "\n")
        }
        if name == "search_context", let matches = result.objectValue?["matches"]?.arrayValue {
            return matches.compactMap { value in
                guard let object = value.objectValue,
                      let path = object["path"]?.stringValue,
                      let line = object["line"]?.intValue,
                      let text = object["text"]?.stringValue else { return nil }
                return "\(path):\(line): \(text)"
            }.joined(separator: "\n")
        }
        if name == "apply_change_set", let object = result.objectValue {
            let status = object["status"]?.stringValue ?? "unknown"
            let changed = object["changed_paths"]?.arrayValue?.count ?? 0
            let transaction = object["transaction_id"]?.stringValue ?? "unassigned"
            let artifact = object["diff_artifact"]?.objectValue?["handle"]?.stringValue ?? "none"
            return "change set \(status): transaction=\(transaction) changed=\(changed) diff=\(artifact)"
        }
        let data = try JSONEncoder.aishell.encode(result)
        return String(decoding: data, as: UTF8.self)
    }

    func structuredProjection(name: String, result: JSONValue) -> JSONValue {
        guard var object = result.objectValue else { return result }
        if name == "artifact_read" {
            object.removeValue(forKey: "text")
            object.removeValue(forKey: "base64")
        } else if name == "workspace_snapshot", let context = object["context"]?.arrayValue {
            object["context"] = .array(context.map { value in
                guard var chunk = value.objectValue else { return value }
                chunk.removeValue(forKey: "text")
                return .object(chunk)
            })
        } else if name == "read_context", let chunks = object["chunks"]?.arrayValue {
            object["chunks"] = .array(chunks.map { value in
                guard var chunk = value.objectValue else { return value }
                chunk.removeValue(forKey: "text")
                return .object(chunk)
            })
        } else if name == "search_context", let matches = object["matches"]?.arrayValue {
            object["matches"] = .array(matches.map { value in
                guard var match = value.objectValue else { return value }
                match.removeValue(forKey: "text")
                return .object(match)
            })
            if let blocks = object["contextBlocks"]?.arrayValue {
                object["contextBlocks"] = .array(blocks.map { value in
                    guard var block = value.objectValue else { return value }
                    block.removeValue(forKey: "text")
                    return .object(block)
                })
            }
        }
        return .object(object)
    }

}
