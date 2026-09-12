import Foundation

struct JSONRPCRequest: Decodable, Sendable {
    let jsonrpc: String
    let id: JSONValue?
    let method: String
    let params: JSONValue?
}

struct JSONRPCResponse: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: JSONValue
    let result: JSONValue?
    let error: JSONRPCError?

    static func success(id: JSONValue, result: JSONValue) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: result, error: nil)
    }

    static func failure(id: JSONValue, code: Int, message: String) -> JSONRPCResponse {
        JSONRPCResponse(
            id: id,
            result: nil,
            error: JSONRPCError(code: code, message: message)
        )
    }
}

struct JSONRPCError: Encodable, Sendable {
    let code: Int
    let message: String
}

struct MCPTool: Encodable, Sendable {
    let name: String
    let title: String
    let description: String
    let inputSchema: JSONValue
    let outputSchema: JSONValue?
    let annotations: MCPToolAnnotations
}

struct MCPToolAnnotations: Encodable, Sendable {
    let readOnlyHint: Bool
    let destructiveHint: Bool
    let idempotentHint: Bool
    let openWorldHint: Bool
}

/// Wire decodeだけを所有するclosed DTO。Core planへの変換時、`.preparedByCore`は
/// canonical selection APIで生成し、`.focusedSet`はFocusedCheckServiceで再照合する。
enum MCPRunCheckRequestDTO: Decodable, Equatable, Sendable {
    struct Legacy: Equatable, Sendable {
        let executable: String
        let arguments: [String]
        let workingDirectory: String?
        let environment: [String: String]
        let timeoutSeconds: Double?
        let retentionSeconds: Double?
    }
    enum Invocation: Equatable, Sendable {
        case direct(
            executable: String,
            arguments: [String],
            workingDirectory: String?,
            environment: [String: String],
            diagnosticAdapter: String?
        )
        case profileCheck(projectID: String, profileDigest: String, checkID: String)
        case focusedSet(id: String, orderedCheckIDs: [String])
    }
    enum Dispatch: Equatable, Sendable { case sync; case start(clientRunKey: String) }
    enum Selection: Equatable, Sendable {
        case preparedByCore
        case prepareFocusedSet(focusedSetDigest: String)
        case focusedSet(focusedSetDigest: String, selectionDigest: String)
    }
    struct V2: Equatable, Sendable {
        let invocation: Invocation
        let dispatch: Dispatch
        let cache: String
        let timeoutMilliseconds: Int
        let retentionSeconds: Int
        let selection: Selection
    }

    case legacy(Legacy)
    case v2(V2)

    init(from decoder: Decoder) throws {
        let object = try decoder.singleValueContainer().decode([String: JSONValue].self)
        if object["schema"] == nil {
            try Self.exactKeys(object, allowed: ["executable", "arguments", "working_directory", "environment", "timeout_seconds", "retention_seconds"])
            guard let executable = object["executable"]?.stringValue, !executable.isEmpty else { throw Self.invalid(decoder) }
            self = .legacy(.init(
                executable: executable,
                arguments: try Self.strings(object["arguments"]),
                workingDirectory: try Self.optionalString(object["working_directory"]),
                environment: try Self.map(object["environment"]),
                timeoutSeconds: try Self.optionalNumber(object["timeout_seconds"], minimum: 0.1, maximum: 3_600),
                retentionSeconds: try Self.optionalNumber(object["retention_seconds"], minimum: 1, maximum: nil)
            ))
            return
        }
        try Self.exactKeys(object, allowed: ["schema", "invocation", "dispatch", "cache", "execution_policy", "selection"])
        guard object["schema"]?.stringValue == "aishell.run-check.v2",
              let invocationObject = object["invocation"]?.objectValue,
              let dispatchObject = object["dispatch"]?.objectValue,
              let cache = object["cache"]?.stringValue,
              ["off", "prefer", "only", "refresh"].contains(cache),
              let policy = object["execution_policy"]?.objectValue,
              let selectionObject = object["selection"]?.objectValue else { throw Self.invalid(decoder) }
        try Self.exactKeys(policy, allowed: ["timeout_ms", "retention_seconds"])
        guard let timeout = policy["timeout_ms"]?.intValue, (1...3_600_000).contains(timeout),
              let retention = policy["retention_seconds"]?.intValue, (1...604_800).contains(retention) else { throw Self.invalid(decoder) }
        let invocation = try Self.invocation(invocationObject, decoder: decoder)
        let dispatch = try Self.dispatch(dispatchObject, decoder: decoder)
        let selection = try Self.selection(selectionObject, decoder: decoder)
        if case let .direct(_, _, _, _, diagnosticAdapter) = invocation,
           diagnosticAdapter != nil,
           case .start = dispatch {
            throw Self.invalid(decoder)
        }
        switch (invocation, selection) {
        case (.focusedSet, .focusedSet), (.focusedSet, .prepareFocusedSet),
             (.direct, .preparedByCore), (.profileCheck, .preparedByCore): break
        default: throw Self.invalid(decoder)
        }
        self = .v2(.init(
            invocation: invocation, dispatch: dispatch, cache: cache,
            timeoutMilliseconds: timeout, retentionSeconds: retention, selection: selection
        ))
    }

    private static func invocation(_ object: [String: JSONValue], decoder: Decoder) throws -> Invocation {
        switch object["mode"]?.stringValue {
        case "direct":
            try exactKeys(object, allowed: ["mode", "executable", "arguments", "working_directory", "environment", "diagnostic_adapter"])
            guard let executable = boundedNonEmptyString(object["executable"], maximum: 4_096) else { throw invalid(decoder) }
            let diagnosticAdapter = try optionalString(object["diagnostic_adapter"], maximum: 32)
            guard diagnosticAdapter == nil || ["xcresult", "sarif", "cargo_json", "bazel_bep"].contains(diagnosticAdapter!) else {
                throw invalid(decoder)
            }
            let workingDirectory = try optionalString(object["working_directory"], maximum: 4_096)
            guard diagnosticAdapter == nil || workingDirectory != nil else { throw invalid(decoder) }
            return .direct(
                executable: executable,
                arguments: try strings(object["arguments"], maximumItems: 4_096, maximumLength: 4_096, allowEmpty: false),
                workingDirectory: workingDirectory,
                environment: try map(object["environment"]),
                diagnosticAdapter: diagnosticAdapter
            )
        case "profile_check":
            try exactKeys(object, allowed: ["mode", "project_id", "profile_digest", "check_id"])
            guard let project = boundedNonEmptyString(object["project_id"], maximum: 4_096),
                  let digest = object["profile_digest"]?.stringValue, isDigest(digest),
                  let check = boundedNonEmptyString(object["check_id"], maximum: 4_096) else { throw invalid(decoder) }
            return .profileCheck(projectID: project, profileDigest: digest, checkID: check)
        case "focused_set":
            try exactKeys(object, allowed: ["mode", "focused_set_id", "ordered_check_ids"])
            guard let id = boundedNonEmptyString(object["focused_set_id"], maximum: 4_096) else { throw invalid(decoder) }
            let ids = try strings(object["ordered_check_ids"], maximumItems: 4_096, maximumLength: 4_096, allowEmpty: false)
            guard !ids.isEmpty, Set(ids).count == ids.count else { throw invalid(decoder) }
            return .focusedSet(id: id, orderedCheckIDs: ids)
        default: throw invalid(decoder)
        }
    }

    private static func dispatch(_ object: [String: JSONValue], decoder: Decoder) throws -> Dispatch {
        switch object["mode"]?.stringValue {
        case "sync": try exactKeys(object, allowed: ["mode"]); return .sync
        case "start":
            try exactKeys(object, allowed: ["mode", "client_run_key"])
            guard let key = object["client_run_key"]?.stringValue, !key.isEmpty, key.utf8.count <= 128 else { throw invalid(decoder) }
            return .start(clientRunKey: key)
        default: throw invalid(decoder)
        }
    }

    private static func selection(_ object: [String: JSONValue], decoder: Decoder) throws -> Selection {
        switch object["binding"]?.stringValue {
        case "prepare": try exactKeys(object, allowed: ["binding"]); return .preparedByCore
        case "prepare_focused_set":
            try exactKeys(object, allowed: ["binding", "focused_set_digest"])
            guard let set = object["focused_set_digest"]?.stringValue, isDigest(set) else { throw invalid(decoder) }
            return .prepareFocusedSet(focusedSetDigest: set)
        case "verify_focused_set":
            try exactKeys(object, allowed: ["binding", "focused_set_digest", "selection_digest"])
            guard let set = object["focused_set_digest"]?.stringValue, isDigest(set),
                  let selection = object["selection_digest"]?.stringValue, isDigest(selection) else { throw invalid(decoder) }
            return .focusedSet(focusedSetDigest: set, selectionDigest: selection)
        default: throw invalid(decoder)
        }
    }

    private static func exactKeys(_ object: [String: JSONValue], allowed: Set<String>) throws {
        guard Set(object.keys).isSubset(of: allowed) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unknown run_check field"))
        }
    }
    private static func strings(
        _ value: JSONValue?,
        maximumItems: Int? = nil,
        maximumLength: Int? = nil,
        allowEmpty: Bool = true
    ) throws -> [String] {
        guard let value else { return [] }
        guard let values = value.arrayValue else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "string array required")) }
        let strings = values.compactMap(\.stringValue)
        guard strings.count == values.count,
              maximumItems.map({ strings.count <= $0 }) ?? true,
              strings.allSatisfy({ string in
                  (allowEmpty || !string.isEmpty)
                      && (maximumLength.map { string.count <= $0 } ?? true)
              }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bounded string array required"))
        }
        return strings
    }
    private static func map(_ value: JSONValue?) throws -> [String: String] {
        guard let value else { return [:] }
        guard let values = value.objectValue else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "string map required")) }
        let strings = values.compactMapValues(\.stringValue)
        guard strings.count == values.count else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "string map required")) }
        return strings
    }
    private static func optionalString(_ value: JSONValue?, maximum: Int? = nil) throws -> String? {
        guard let value else { return nil }
        guard let string = value.stringValue, !string.isEmpty,
              maximum.map({ string.count <= $0 }) ?? true else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bounded non-empty string required"))
        }
        return string
    }
    private static func optionalNumber(_ value: JSONValue?, minimum: Double, maximum: Double?) throws -> Double? {
        guard let value else { return nil }
        guard let number = value.doubleValue, number >= minimum, maximum.map({ number <= $0 }) ?? true else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bounded number required"))
        }
        return number
    }
    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
        }
    }
    private static func boundedNonEmptyString(_ value: JSONValue?, maximum: Int) -> String? {
        guard let string = value?.stringValue, !string.isEmpty, string.count <= maximum else { return nil }
        return string
    }
    private static func invalid(_ decoder: Decoder) -> DecodingError {
        .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid closed run_check request"))
    }
}

enum ToolCatalog {
    static let developmentToolNames: Set<String> = [
        "run_check", "artifact_read", "workspace_snapshot", "read_context", "search_context"
    ]
    static let implementedExpandedToolNames: Set<String> = [
        "change_impact", "run_observe", "apply_change_set", "workspace_wait"
    ]
    static let expandedDevelopmentToolOrder = [
        "run_check", "run_observe", "artifact_read", "workspace_snapshot", "workspace_wait",
        "read_context", "search_context", "change_impact", "apply_change_set"
    ]
    static let controlToolOrder = ["runtime_status", "runtime_open_manager"]
    static let controlToolNames: Set<String> = [
        "runtime_status", "runtime_open_manager"
    ]
    static let defaultToolNames = developmentToolNames.union(controlToolNames)

    static let factoryTool = tool(
        "factory_diagnostics", "工場向けnative診断",
        "工場reporter向けに、AIShell runtimeと管理appのread-only診断をpathや操作履歴を含めず返します。",
        properties: [:], required: [], readOnly: true, idempotent: true,
        outputSchema: factoryDiagnosticsOutputSchema
    )

    static func listedTools(profile: String?, capabilitySet: String? = nil) throws -> [MCPTool] {
        switch profile {
        case nil, "development", "factory", "full", "legacy": break
        case let value?: throw MCPStartupError.invalidToolProfile(value)
        }
        let expanded: Bool
        switch capabilitySet {
        case nil: expanded = false
        case "expanded-v1": expanded = true
        case let value?: throw MCPStartupError.invalidCapabilitySet(value)
        }
        if profile == "factory" {
            guard capabilitySet == nil else {
                throw MCPStartupError.factoryProfileDoesNotAcceptCapabilitySet(capabilitySet!)
            }
            return [factoryTool]
        }
        let catalog = expanded ? expandedTools : tools
        if expanded {
            let byName = Dictionary(uniqueKeysWithValues: catalog.map { ($0.name, $0) })
            let highDensity = expandedDevelopmentToolOrder + controlToolOrder
            if profile == "full" || profile == "legacy" {
                let fullOnly = tools.map(\.name).filter {
                    !developmentToolNames.contains($0) && !controlToolNames.contains($0)
                        && !implementedExpandedToolNames.contains($0)
                }
                return (highDensity + fullOnly).compactMap { byName[$0] }
            }
            return highDensity.compactMap { byName[$0].map(compactTool) }
        }
        switch profile {
        case "full", "legacy":
            return catalog.filter { !implementedExpandedToolNames.contains($0.name) }
        default:
            return catalog.filter { defaultToolNames.contains($0.name) }.map(compactTool)
        }
    }

    private static func compactTool(_ tool: MCPTool) -> MCPTool {
        let descriptions = [
            "run_check": "大量診断を完全保持するrepository test/compiler/lintはshellでなくこれを使う。 Use this instead of shell for repository tests, compilers, or linters whose complete noisy diagnostics must be retained.",
            "run_observe": "既存AIShell runの待機・増分診断・取消は新規実行やworkspace待機でなくこれを使う。 Use this to wait for, read incremental diagnostics from, or cancel an existing AIShell run; do not start a new run or wait on a workspace cursor.",
            "artifact_read": "保持済みrun log/artifactの検索・比較・budget読取はsource file読取でなくこれを使う。 Use this to search, compare, or budget-read retained run logs and artifacts, not source files.",
            "workspace_snapshot": "現在のworkspace、Git/branch差分、project commandの統合要約は個別検索でなくこれを使う。 Use this for one integrated summary of the current workspace, Git/branch differences, and project commands.",
            "workspace_wait": "workspace cursor以後のfile変更待機はpollingやrun待機でなくこれを使う。 Use this to wait for file changes after a workspace cursor without polling; it does not observe a managed run.",
            "read_context": "複数file/symbol rangeを一つの共有budgetとexpected SHAで読む時に使う。 Use this to read multiple files or symbol ranges under one shared byte budget with expected SHA guards.",
            "search_context": "複数regex/固定文字列queryを変更file/test優先で一括検索する時に使う。 Use this to batch regex and fixed-string searches while prioritizing changed files and tests.",
            "change_impact": "変更が影響するsymbol、dependency、testと根拠の解析は検索やsnapshotでなくこれを使う。 Use this to explain affected symbols, dependencies, tests, and evidence rather than merely searching or snapshotting.",
            "apply_change_set": "expected SHA付きmulti-file編集をatomic適用し結果diffを得る時に使う。 Use this to atomically apply expected-SHA-guarded edits across multiple files and return the resulting diff."
        ]
        return MCPTool(
            name: tool.name,
            title: tool.title,
            description: descriptions[tool.name] ?? tool.description,
            inputSchema: removingDescriptions(tool.inputSchema),
            outputSchema: tool.outputSchema,
            annotations: tool.annotations
        )
    }

    private static func removingDescriptions(_ value: JSONValue) -> JSONValue {
        switch value {
        case let .object(object):
            return .object(object.filter { $0.key != "description" }.mapValues(removingDescriptions))
        case let .array(array):
            return .array(array.map(removingDescriptions))
        default:
            return value
        }
    }

    static let tools: [MCPTool] = [
        tool(
            "run_check", "検査を直接実行", "compilerやtest runnerをshellなしで直接起動し、短い成否・主要診断・完全stdout/stderrのartifact handleを返します。通常responseへ巨大logを展開しません。",
            properties: [
                "executable": string("実行ファイル名または絶対パス。PATHはAIShellが解決し、shellとenvは拒否します"),
                "arguments": stringArray("引数配列。shell展開は行いません"),
                "working_directory": string("作業ディレクトリ。省略時はMCP起動ディレクトリ"),
                "environment": stringMap("追加・上書きする環境変数"),
                "timeout_seconds": number("timeout秒。0.1〜3600、既定120", minimum: 0.1, maximum: 3600),
                "retention_seconds": number("完全logを保持する秒数。最小1、既定86400", minimum: 1)
            ],
            required: ["executable"], destructive: true, idempotent: false, openWorld: true,
            outputSchema: objectOutput(
                schemaVersion: "aishell.run-check.v1",
                required: ["schemaVersion", "requestID", "status", "summary", "exitCode", "stdoutArtifact", "stderrArtifact"],
                properties: [
                    "requestID": type("string"), "status": enumType(["passed", "failed", "timed_out"]),
                    "summary": type("string"), "exitCode": nullableType("integer"),
                    "stdoutArtifact": type("object"), "stderrArtifact": type("object")
                ]
            )
        ),
        tool(
            "artifact_read", "完全証拠を部分読取", "run_check等が保持したartifactをrange、tail、pattern周辺のいずれかでbudget内にlossless取得します。期限切れはHANDLE_EXPIREDで停止します。",
            properties: [
                "handle": string("art_で始まるartifact handle"),
                "mode": enumString(["range", "tail", "around"], "読取mode。既定range"),
                "offset": integer("range開始byte offset。既定0", minimum: 0),
                "length": integer("range長。既定65536", minimum: 0),
                "tail_lines": integer("tailの行数。既定100", minimum: 1),
                "pattern": string("aroundで探す文字列"),
                "context_lines": integer("aroundの前後行数。既定2", minimum: 0),
                "byte_budget": integer("返却上限byte。1〜1048576、既定65536", minimum: 1, maximum: 1_048_576)
            ],
            required: ["handle"], readOnly: true, idempotent: true,
            outputSchema: objectOutput(
                required: ["handle", "encoding", "offset", "returnedBytes", "totalBytes", "omittedBytes", "eof", "sha256", "expiresAt"],
                properties: [
                    "handle": type("string"), "encoding": enumType(["utf-8", "base64"]),
                    "offset": type("integer"), "returnedBytes": type("integer"),
                    "totalBytes": type("integer"), "omittedBytes": type("integer"),
                    "eof": type("boolean"), "sha256": type("string"), "expiresAt": type("string")
                ]
            )
        ),
        tool(
            "workspace_snapshot", "workspace現在状態のpreviewと差分", "初回は現在filesystemを確定してbounded previewを返し、以後はFSEventsで観測したpathだけをidentity/hash照合します。任意のgit_diffとproject_profileを同じ観測へ束ねられます。event gapや期限切れcursorは黙ってfull scanせず明示errorにします。",
            properties: [
                "path": string("snapshot root。省略時はMCP起動ディレクトリ"),
                "since_cursor": string("前回cursor。省略時は明示的なfull snapshot"),
                "entry_limit": integer("最大entry/change件数。1〜5000、既定500", minimum: 1, maximum: 5_000),
                "context_budget": integer("guidance・manifest・test・小規模workspace本文、またはdelta本文の共有byte上限。0〜65536、既定16384", minimum: 0, maximum: 65_536),
                "git_diff": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "mode": enumString(["worktree", "branch"], "worktreeはHEAD対index/worktree、branchはbase_ref対HEADも含める"),
                        "base_ref": string("比較元commit-ish。省略時HEAD"),
                        "byte_budget": integer("change/patch共有budget。1〜1048576", minimum: 1, maximum: 1_048_576),
                        "include_patch": boolean("patch previewを含める。既定true"),
                        "continuation": string("前pageのopaque continuation")
                    ]),
                    "additionalProperties": .bool(false)
                ]),
                "project_profile": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "mode": enumString(["auto", "all", "none"], "profile projection mode。既定auto"),
                        "project_ids": stringArray("返すstable project ID"),
                        "byte_budget": integer("profile record共有budget。1024〜262144", minimum: 1_024, maximum: 262_144),
                        "profile_limit": integer("1 pageの最大profile件数。1〜1000", minimum: 1, maximum: 1_000),
                        "continuation": string("前pageのopaque continuation")
                    ]),
                    "additionalProperties": .bool(false)
                ])
            ],
            required: [], readOnly: true, idempotent: true,
            outputSchema: objectOutputWithAlternate(
                primarySchemaKey: "schemaVersion",
                primarySchemaVersion: "aishell.workspace-snapshot.v1",
                alternateSchemaKey: "schemaVersion",
                alternateSchemaVersion: "aishell.workspace-snapshot.v2",
                required: ["schemaVersion", "root", "cursor", "isFull", "freshness", "entries", "changes", "omittedEntries", "guidanceFiles", "gitStatusState", "gitStatus", "context"],
                properties: [
                    "root": type("string"), "cursor": type("string"), "isFull": type("boolean"),
                    "freshness": enumType(["fresh"]), "entries": type("array"), "changes": type("array"),
                    "omittedEntries": type("integer"), "checkpointState": type("string"), "guidanceFiles": type("array"),
                    "gitStatusState": enumType(["clean", "dirty", "not_repository"]),
                    "gitStatus": type("array"), "context": type("array"),
                    "gitDiff": nullableType("object"),
                    "projectProfiles": nullableType("array"),
                    "projectProfileSummary": nullableType("object"),
                    "projectProfileHasMore": nullableType("boolean"),
                    "projectProfileContinuation": nullableType("string")
                ]
            )
        ),
        tool(
            "read_context", "複数fileを共有budgetで読取", "複数targetを一つのbyte budgetで読み、SHA、omitted bytes、明示continuationを返します。巨大fileや後続fileを暗黙切捨てしません。",
            properties: [
                "targets": stringArray("相対または絶対ファイルパスの配列"),
                "byte_budget": integer("全target共有の返却上限byte。1〜1048576、既定65536", minimum: 1, maximum: 1_048_576),
                "continuation": string("前回結果のcontinuation")
            ],
            required: ["targets"], readOnly: true, idempotent: true,
            outputSchema: objectOutput(
                schemaVersion: "aishell.read-context.v1",
                required: ["schemaVersion", "chunks", "returnedBytes", "omittedBytes"],
                properties: ["chunks": type("array"), "returnedBytes": type("integer"), "omittedBytes": type("integer")]
            )
        ),
        tool(
            "search_context", "複数queryの共有budget検索", "fixed、regex、globを一回の非破壊workspace観測へ束ねます。action=semanticではSourceKit-LSPのdefinition/references/workspace_symbolsをcursorへ束縛し、fresh/stale/indexing/unavailableを明示してlexical fallbackしません。v1 queryも互換受理します。",
            properties: [
                "query": string("固定文字列query"),
                "action": enumString(["search", "semantic"], "v2 action"),
                "queries": .object([
                    "type": .string("array"),
                    "minItems": .number(1),
                    "maxItems": .number(32),
                    "items": .object([
                        "type": .string("object"),
                        "required": .array([.string("id"), .string("kind"), .string("pattern")]),
                        "properties": .object([
                            "id": string("request内で一意のquery ID"),
                            "kind": enumString(["fixed", "regex", "glob", "semantic"], "query kind"),
                            "pattern": string("検索pattern"),
                            "operation": enumString(["definition", "references", "workspace_symbols"], "semantic operation"),
                            "path": string("semantic anchor document。省略時は現在indexからsymbol anchorを解決"),
                            "line": integer("semantic anchorの0-based line", minimum: 0),
                            "character": integer("semantic anchorの0-based UTF-16 character", minimum: 0),
                            "case": enumString(["sensitive", "insensitive", "smart"], "case mode"),
                            "before_lines": integer("前文脈行。0〜20", minimum: 0, maximum: 20),
                            "after_lines": integer("後文脈行。0〜20", minimum: 0, maximum: 20),
                            "include_globs": stringArray("include path glob"),
                            "exclude_globs": stringArray("exclude path glob")
                        ]),
                        "additionalProperties": .bool(false)
                    ])
                ]),
                "path": string("検索scope directoryまたは単一regular file。省略時はMCP起動ディレクトリ"),
                "provider": enumString(["sourcekit-lsp"], "semantic provider"),
                "cursor": string("semantic観測を束縛するworkspace cursor"),
                "ranking": .object([
                    "type": .string("array"),
                    "items": enumString(["changed", "tests"], "ranking criterion。省略時はtests、changed_since_cursor指定時はchangedとtests"),
                    "uniqueItems": .bool(true)
                ]),
                "changed_since_cursor": string("changed順位の下限workspace cursor。rankingにchangedを含める場合は必須"),
                "max_results": integer("最大match数。1〜500、既定50", minimum: 1, maximum: 500),
                "byte_budget": integer("返却上限byte。1〜1048576、既定65536", minimum: 1, maximum: 1_048_576),
                "continuation": string("前回結果のcontinuation。検索結果変更時はCONTENT_CHANGED")
            ],
            required: [], readOnly: true, idempotent: true,
            outputSchema: objectOutputWithAlternate(
                primarySchemaKey: "schemaVersion",
                primarySchemaVersion: "aishell.search-context.v1",
                alternateSchemaKey: "schema",
                alternateSchemaVersion: "aishell.search-context.v2",
                required: ["matches", "omittedMatches", "returnedBytes", "omittedBytes", "freshness"],
                properties: [
                    "query": type("string"), "worker": type("string"), "matches": type("array"),
                    "omittedMatches": type("integer"), "returnedBytes": type("integer"),
                    "omittedBytes": type("integer"),
                    "contextBlocks": type("array"), "oversizedDescriptors": type("array"),
                    "evidence": type("object"), "rankingEvidence": type("object"),
                    "freshness": .object(["oneOf": .array([
                        enumType(["filesystem-current"]), type("object")
                    ])])
                ]
            )
        ),
        changeImpactTool,
        runObserveTool,
        tool(
            "workspace_wait", "workspace変更を待機", "保持済みworkspace journalを消費せず、指定cursorより後の変更または期限まで待ちます。gap・期限切れcursorはfull scanへfallbackせず明示errorにし、request cancellationは待機だけを終了します。",
            properties: [
                "path": string("待機対象root。省略時はMCP起動ディレクトリ"),
                "from_cursor": string("workspace_snapshot等が返した開始cursor"),
                "timeout_ms": integer("待機上限milliseconds。0〜300000", minimum: 0, maximum: 300_000)
            ],
            required: ["from_cursor", "timeout_ms"], readOnly: true, idempotent: true,
            outputSchema: objectOutput(
                schemaVersion: "aishell.workspace-wait.v1",
                required: ["schemaVersion", "status", "observedFrom", "observedThrough", "observationViewID", "retentionFloorSequence", "headSequence", "changedPaths"],
                properties: [
                    "status": enumType(["changed", "timed_out"]),
                    "observedFrom": type("string"), "observedThrough": type("string"),
                    "observationViewID": type("string"),
                    "retentionFloorSequence": type("integer"), "headSequence": type("integer"),
                    "changedPaths": type("array")
                ]
            )
        ),
        tool(
            "apply_change_set", "複数fileを原子的に変更", "指定フォルダ内のcreate、write、delete、renameをexpected SHAとworkspace cursorで固定し、durable transactionとして適用します。途中失敗を部分成功へ丸めず、完全diff artifactと更新後cursorを返します。",
            properties: [
                "path": string("workspace_snapshotと同じ対象canonical root"),
                "workspace_cursor": string("workspace_snapshotが返したopaque cursor。cursor以後に変更があれば適用しない"),
                "changes": .object([
                    "type": .string("array"), "minItems": .number(1), "maxItems": .number(128),
                    "items": .object([
                        "oneOf": .array([
                            changeVariantSchema(operation: "create", content: true),
                            changeVariantSchema(operation: "write", content: true),
                            changeVariantSchema(operation: "delete", content: false),
                            renameVariantSchema
                        ])
                    ])
                ]),
                "diff_byte_budget": integer("通常resultへ含めるitem単位preview budget", minimum: 1, maximum: 1_048_576),
                "retention_seconds": integer("完全diff artifactの保持秒", minimum: 1, maximum: 604_800)
            ],
            required: ["path", "workspace_cursor", "changes"],
            destructive: true, idempotent: true,
            outputSchema: objectOutput(
                schemaVersion: "aishell.apply-change-set.v1",
                required: ["schemaVersion", "transaction_id", "client_id", "client_epoch", "request_sequence", "status", "visibility", "root", "from_cursor", "cursor", "workspace_from_cursor", "workspace_cursor", "changes", "changed_paths", "transaction_cursor_advanced", "summary", "diff_preview", "returned_diff_bytes", "omitted_diff_bytes", "has_more", "diff_artifact"],
                properties: [
                    "transaction_id": nullableType("string"), "client_id": nullableType("string"),
                    "client_epoch": nullableType("integer"), "request_sequence": type("integer"),
                    "status": enumType(["committed", "aborted_before_side_effect", "recovery_required"]),
                    "visibility": enumType(["aishell_serialized_recoverable"]), "root": nullableType("string"),
                    "from_cursor": type("object"), "cursor": type("object"), "changes": type("array"),
                    "workspace_from_cursor": type("string"), "workspace_cursor": type("string"),
                    "changed_paths": type("array"), "transaction_cursor_advanced": type("boolean"),
                    "summary": nullableType("object"), "diff_preview": nullableType("string"),
                    "returned_diff_bytes": type("integer"), "omitted_diff_bytes": type("integer"),
                    "has_more": nullableType("boolean"), "diff_artifact": type("object")
                ]
            )
        ),
        tool(
            "runtime_status", "実行状態", "停止状態、相対パスの基準、次に必要な操作を取得します。フォルダ登録は不要です。停止中でも利用できます。",
            properties: [:], required: [], readOnly: true, idempotent: true,
            outputSchema: objectOutput(
                required: ["relativePathBase", "isPaused", "updatedAt", "managerTool", "nextAction"],
                properties: [
                    "relativePathBase": nullableType("string"), "isPaused": type("boolean"),
                    "updatedAt": type("string"), "managerTool": type("string"), "nextAction": type("string")
                ]
            )
        ),
        tool(
            "runtime_open_manager", "管理画面を開く", "AIShellが停止中でも管理画面を開きます。停止と再開は画面上で行います。",
            properties: [:], required: [], idempotent: true,
            outputSchema: objectOutput(
                required: ["name", "processIdentifier", "isActive"],
                properties: [
                    "name": type("string"), "bundleIdentifier": nullableType("string"),
                    "processIdentifier": type("integer"), "isActive": type("boolean")
                ]
            )
        ),
        tool(
            "files_list", "フォルダ一覧", "指定フォルダの項目を一覧します。pathを省略するとMCP起動ディレクトリです。",
            properties: ["path": string("MCP起動ディレクトリからの相対パス、または絶対パス")],
            required: [], readOnly: true, idempotent: true
        ),
        tool(
            "files_search", "ファイル検索", "許可フォルダ内をファイル名で再帰検索します。",
            properties: [
                "query": string("検索文字列"),
                "path": string("検索開始パス。省略時は許可ルート"),
                "limit": integer("最大件数。1〜500")
            ],
            required: ["query"], readOnly: true, idempotent: true
        ),
        tool(
            "files_read_text", "テキスト読取", "1MB以下のUTF-8テキストを読み取ります。",
            properties: ["path": string("対象ファイルのパス")],
            required: ["path"], readOnly: true, idempotent: true
        ),
        tool(
            "files_stat", "ファイル情報", "ファイル情報、POSIX permission、必要ならSHA-256を取得します。",
            properties: [
                "path": string("対象パス"),
                "include_hash": boolean("ファイルのSHA-256を計算する。既定true")
            ],
            required: ["path"], readOnly: true, idempotent: true
        ),
        tool(
            "files_tree", "ディレクトリツリー", "許可フォルダ内を深さと件数を制限して再帰一覧します。",
            properties: [
                "path": string("開始パス。省略時は許可ルート"),
                "max_depth": integer("最大深さ。1〜20"),
                "limit": integer("最大件数。1〜2000")
            ],
            required: [], readOnly: true, idempotent: true
        ),
        tool(
            "files_create_directory", "フォルダ作成", "許可フォルダ内へ新しいフォルダを作成します。",
            properties: ["path": string("作成するフォルダのパス")],
            required: ["path"], idempotent: false
        ),
        tool(
            "files_create_text", "テキスト作成", "既存項目を上書きせず、新しいUTF-8テキストファイルを作成します。",
            properties: [
                "path": string("作成するファイルのパス"),
                "content": string("書き込む内容")
            ],
            required: ["path", "content"], idempotent: false
        ),
        tool(
            "files_write_text", "テキスト更新", "新規作成または既存テキストを原子的に更新します。既存ファイルにはfiles_statで得たexpected_sha256が必要です。",
            properties: [
                "path": string("対象ファイルのパス"),
                "content": string("更新後の全内容"),
                "expected_sha256": string("既存ファイルを読み取った時点のSHA-256")
            ],
            required: ["path", "content"], idempotent: false
        ),
        tool(
            "files_replace_text", "部分置換", "old_textを事前条件としてUTF-8テキストの一部を置換します。",
            properties: [
                "path": string("対象ファイルのパス"),
                "old_text": string("置換対象の正確な文字列"),
                "new_text": string("置換後の文字列"),
                "replace_all": boolean("一致箇所をすべて置換する。既定false")
            ],
            required: ["path", "old_text", "new_text"], idempotent: false
        ),
        tool(
            "files_copy", "ファイルコピー", "許可フォルダ内で項目をコピーします。既存項目は上書きしません。",
            properties: [
                "source": string("コピー元パス"),
                "destination": string("コピー先パス")
            ],
            required: ["source", "destination"], idempotent: false
        ),
        tool(
            "files_move", "ファイル移動", "許可フォルダ内で項目を移動します。既存項目は上書きしません。",
            properties: [
                "source": string("移動元パス"),
                "destination": string("移動先パス")
            ],
            required: ["source", "destination"], idempotent: false
        ),
        tool(
            "files_rename", "名前変更", "許可フォルダ内の項目名を変更します。",
            properties: [
                "path": string("対象パス"),
                "new_name": string("新しいファイル名。パスは含めません")
            ],
            required: ["path", "new_name"], idempotent: false
        ),
        tool(
            "files_trash", "Trashへ移動", "項目を完全削除せずmacOSのTrashへ移動します。",
            properties: ["path": string("対象パス")],
            required: ["path"], destructive: true, idempotent: false
        ),
        tool(
            "apps_list_running", "実行中アプリ", "実行中の通常アプリを一覧します。",
            properties: [:], required: [], readOnly: true, idempotent: true
        ),
        tool(
            "apps_list_installed", "インストール済みアプリ", "標準Applicationsフォルダにあるアプリを一覧します。",
            properties: [:], required: [], readOnly: true, idempotent: true
        ),
        tool(
            "apps_open", "アプリ起動", "bundle identifierを指定してアプリを起動します。",
            properties: ["bundle_identifier": string("例: com.apple.TextEdit")],
            required: ["bundle_identifier"], idempotent: true
        ),
        tool(
            "apps_activate", "アプリ前面化", "実行中アプリを前面化します。",
            properties: ["bundle_identifier": string("例: com.apple.TextEdit")],
            required: ["bundle_identifier"], idempotent: true
        ),
        tool(
            "process_run", "プログラム直接実行", "shellを介さず、PATH解決した実行ファイルへ引数配列を直接渡します。stdout、stderr、終了コードを返します。",
            properties: [
                "executable": string("実行ファイル名または絶対パス。PATHはAIShellが解決し、shellとenvは拒否します"),
                "arguments": stringArray("引数配列。shell展開は行いません"),
                "working_directory": string("作業ディレクトリ。省略時はMCP起動ディレクトリ"),
                "environment": stringMap("追加・上書きする環境変数"),
                "timeout_seconds": number("timeout秒。0.1〜3600、既定120")
            ],
            required: ["executable"], destructive: true, idempotent: false, openWorld: true
        )
    ]

    /// baselineのv1 schemaを一切変更せず、capability opt-in時だけv2 closed unionへ置換する。
    private static var expandedTools: [MCPTool] {
        tools.map { tool in
            if tool.name == "artifact_read" {
                return MCPTool(
                    name: tool.name,
                    title: tool.title,
                    description: "v1単一readを維持し、terminal managed runだけをproject/store binding照合後に横断search・compareします。live spoolへfallbackしません。",
                    inputSchema: artifactReadExpandedInputSchema(legacy: tool.inputSchema),
                    outputSchema: artifactReadExpandedOutputSchema(legacy: tool.outputSchema!),
                    annotations: tool.annotations
                )
            }
            guard tool.name == "run_check" else { return tool }
            return MCPTool(
                name: tool.name,
                title: tool.title,
                description: tool.description,
                inputSchema: runCheckExpandedInputSchema(legacy: tool.inputSchema),
                outputSchema: runCheckExpandedOutputSchema(legacy: tool.outputSchema!),
                annotations: tool.annotations
            )
        }
    }

    private static let artifactQuerySourceSchema: JSONValue = .object([
        "oneOf": .array([
            closedObject(required: ["type", "handle"], properties: [
                "type": constString("artifact"),
                "handle": boundedString(minLength: 1, maxLength: 16_384)
            ]),
            closedObject(required: ["type", "run_id", "channels"], properties: [
                "type": constString("run"),
                "run_id": boundedString(minLength: 1, maxLength: 64),
                "channels": .object([
                    "type": .string("array"), "minItems": .number(1), "maxItems": .number(3),
                    "uniqueItems": .bool(true),
                    "items": enumType(["stdout", "stderr", "diagnostics"])
                ])
            ])
        ])
    ])

    private static func artifactReadExpandedInputSchema(legacy: JSONValue) -> JSONValue {
        .object(["type": .string("object"), "oneOf": .array([
            legacy,
            closedObject(required: ["action", "project_path", "sources", "pattern"], properties: [
                "action": constString("search"),
                "project_path": boundedString(minLength: 1, maxLength: 4_096),
                "sources": .object([
                    "type": .string("array"), "minItems": .number(1), "maxItems": .number(64),
                    "items": artifactQuerySourceSchema
                ]),
                "pattern_kind": enumType(["literal", "regex"]),
                "pattern": boundedString(minLength: 1, maxLength: 65_536),
                "case": enumType(["sensitive", "insensitive"]),
                "regex_flags": boundedString(minLength: 0, maxLength: 8),
                "page_byte_limit": integer("result page上限", minimum: 1, maximum: 1_048_576)
            ]),
            closedObject(required: ["action", "stream_handle", "cursor"], properties: [
                "action": constString("next"),
                "stream_handle": boundedString(minLength: 1, maxLength: 16_384),
                "cursor": boundedString(minLength: 1, maxLength: 65_536),
                "page_byte_limit": integer("result page上限", minimum: 1, maximum: 1_048_576)
            ]),
            closedObject(required: ["action", "project_path", "baseline_run_id", "candidate_run_id", "channels"], properties: [
                "action": constString("compare"),
                "project_path": boundedString(minLength: 1, maxLength: 4_096),
                "baseline_run_id": boundedString(minLength: 1, maxLength: 64),
                "candidate_run_id": boundedString(minLength: 1, maxLength: 64),
                "channels": .object([
                    "type": .string("array"), "minItems": .number(1), "maxItems": .number(3),
                    "uniqueItems": .bool(true),
                    "items": enumType(["stdout", "stderr", "diagnostics"])
                ])
            ])
        ])])
    }

    private static let artifactSearchOutputSchema = closedObject(
        required: ["schema", "action", "projectID", "streamHandle", "items", "hasMore"],
        properties: [
            "schema": constString("aishell.artifact-read.v2"), "action": constString("search"),
            "projectID": sha256Schema, "streamHandle": type("string"), "items": type("array"),
            "nextCursor": type("string"), "hasMore": type("boolean")
        ]
    )

    private static let artifactCompareOutputSchema = closedObject(
        required: ["schema", "action", "projectID", "baselineRunID", "candidateRunID", "comparisons"],
        properties: [
            "schema": constString("aishell.artifact-read.v2"), "action": constString("compare"),
            "projectID": sha256Schema, "baselineRunID": type("string"),
            "candidateRunID": type("string"), "comparisons": type("array")
        ]
    )

    private static func artifactReadExpandedOutputSchema(legacy: JSONValue) -> JSONValue {
        let legacyVariants = legacy.objectValue?["oneOf"]?.arrayValue ?? []
        return .object([
            "type": .string("object"),
            "oneOf": .array(legacyVariants + [artifactSearchOutputSchema, artifactCompareOutputSchema])
        ])
    }

    private static let changeImpactTool = MCPTool(
        name: "change_impact",
        title: "変更影響候補を取得",
        description: "workspace cursorとcontent SHAへ束縛した参照・依存・関連test・build target候補、または明示実行用focused check候補を返します。解析や候補生成はtest/buildを起動しません。",
        inputSchema: changeImpactInputSchema,
        outputSchema: changeImpactOutputSchema,
        annotations: MCPToolAnnotations(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false
        )
    )

    private static let runObserveTool = MCPTool(
        name: "run_observe",
        title: "managed runを観測・取消",
        description: "認証付きrun_handleで、adapterから独立して継続するmanaged runの状態確認、stdout/stderr/diagnostic増分読取、revision/evidence待機、identity照合付き取消を行います。request cancellationはrunを停止しません。",
        inputSchema: .object(["type": .string("object"), "oneOf": .array([
            closedObject(required: ["action", "run_handle"], properties: [
                "action": constString("status"), "run_handle": boundedString(minLength: 1, maxLength: 16_384)
            ]),
            closedObject(required: ["action", "run_handle"], properties: [
                "action": constString("read"), "run_handle": boundedString(minLength: 1, maxLength: 16_384),
                "cursor": boundedString(minLength: 1, maxLength: 16_384),
                "byte_budget": integer("stdout/stderr/diagnostic共有budget", minimum: 1, maximum: 1_048_576)
            ]),
            closedObject(required: ["action", "run_handle", "after_state_revision", "timeout_ms"], properties: [
                "action": constString("wait"), "run_handle": boundedString(minLength: 1, maxLength: 16_384),
                "after_state_revision": integer("既知state revision", minimum: 0),
                "cursor": boundedString(minLength: 1, maxLength: 16_384),
                "timeout_ms": integer("待機上限milliseconds", minimum: 1, maximum: 300_000)
            ]),
            closedObject(required: ["action", "run_handle"], properties: [
                "action": constString("cancel"), "run_handle": boundedString(minLength: 1, maxLength: 16_384)
            ])
        ])]),
        outputSchema: .object([
            "type": .string("object"),
            "oneOf": .array([
                runObserveResultSchema("aishell.run-observe-status.v1", required: ["runHandle", "runID", "state", "stateRevision", "evidenceCursor"]),
                runObserveResultSchema("aishell.run-observe-read.v1", required: ["status", "chunks", "cursor", "hasMore", "omittedBytes"]),
                runObserveResultSchema("aishell.run-observe-wait.v1", required: ["outcome", "status"]),
                .object([
                    "type": .string("object"),
                    "required": .array([.string("schemaVersion"), .string("error")]),
                    "properties": .object([
                        "schemaVersion": .object(["const": .string("aishell.error.v1")]),
                        "error": type("object")
                    ]),
                    "additionalProperties": .bool(true)
                ])
            ])
        ]),
        annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false
        )
    )

    private static func runObserveResultSchema(_ schema: String, required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "required": .array((["schema"] + required).map(JSONValue.string)),
            "properties": .object(["schema": .object(["const": .string(schema)])]),
            "additionalProperties": .bool(true)
        ])
    }

    private static let sha256Schema: JSONValue = .object([
        "type": .string("string"), "pattern": .string("^[0-9a-f]{64}$")
    ])

    private static let executionPolicySchema: JSONValue = closedObject(
        required: ["timeout_ms", "retention_seconds"],
        properties: [
            "timeout_ms": integer("timeout milliseconds", minimum: 1, maximum: 3_600_000),
            "retention_seconds": integer("artifact retention seconds", minimum: 1, maximum: 604_800)
        ]
    )

    private static let dispatchSchema: JSONValue = .object(["oneOf": .array([
        closedObject(required: ["mode"], properties: ["mode": constString("sync")]),
        closedObject(required: ["mode", "client_run_key"], properties: [
            "mode": constString("start"),
            "client_run_key": boundedString(minLength: 1, maxLength: 128)
        ])
    ])])

    private static let directInvocationSchema: JSONValue = closedObject(
        required: ["mode", "executable"],
        properties: [
            "mode": constString("direct"),
            "executable": boundedString(minLength: 1, maxLength: 4_096),
            "arguments": boundedStringArray(minItems: 0, maxItems: 4_096),
            "working_directory": boundedString(minLength: 1, maxLength: 4_096),
            "environment": stringMap("effective environment override"),
            "diagnostic_adapter": enumType(["xcresult", "sarif", "cargo_json", "bazel_bep"])
        ]
    )

    private static let profileInvocationSchema: JSONValue = closedObject(
        required: ["mode", "project_id", "profile_digest", "check_id"],
        properties: [
            "mode": constString("profile_check"),
            "project_id": boundedString(minLength: 1, maxLength: 4_096),
            "profile_digest": sha256Schema,
            "check_id": boundedString(minLength: 1, maxLength: 4_096)
        ]
    )

    private static let focusedInvocationSchema: JSONValue = closedObject(
        required: ["mode", "focused_set_id", "ordered_check_ids"],
        properties: [
            "mode": constString("focused_set"),
            "focused_set_id": boundedString(minLength: 1, maxLength: 4_096),
            "ordered_check_ids": boundedStringArray(minItems: 1, maxItems: 4_096, uniqueItems: true)
        ]
    )

    /// `prepare`はadapterにCore canonical APIでselectionを生成させる型。caller提供hashを
    /// profile selectionとして盲信しない。focused setだけはservice発行digestを再照合する。
    private static let preparedSelectionSchema = closedObject(
        required: ["binding"], properties: ["binding": constString("prepare")]
    )
    private static let focusedSelectionSchema = JSONValue.object(["oneOf": .array([
        closedObject(
            required: ["binding", "focused_set_digest"],
            properties: [
                "binding": constString("prepare_focused_set"),
                "focused_set_digest": sha256Schema
            ]
        ),
        closedObject(
            required: ["binding", "focused_set_digest", "selection_digest"],
            properties: [
                "binding": constString("verify_focused_set"),
                "focused_set_digest": sha256Schema,
                "selection_digest": sha256Schema
            ]
        )
    ])])

    private static func runCheckV2Variant(
        invocation: JSONValue,
        selection: JSONValue,
        cache: JSONValue = enumType(["off", "prefer", "only", "refresh"])
    ) -> JSONValue {
        closedObject(
            required: ["schema", "invocation", "dispatch", "cache", "execution_policy", "selection"],
            properties: [
                "schema": constString("aishell.run-check.v2"),
                "invocation": invocation,
                "dispatch": dispatchSchema,
                "cache": cache,
                "execution_policy": executionPolicySchema,
                "selection": selection
            ]
        )
    }

    private static func runCheckExpandedInputSchema(legacy: JSONValue) -> JSONValue {
        .object([
        "type": .string("object"),
        "oneOf": .array([
            legacy,
            runCheckV2Variant(invocation: directInvocationSchema, selection: preparedSelectionSchema, cache: constString("off")),
            runCheckV2Variant(invocation: profileInvocationSchema, selection: preparedSelectionSchema),
            runCheckV2Variant(invocation: focusedInvocationSchema, selection: focusedSelectionSchema)
        ])
        ])
    }

    private static let artifactSchema = closedObject(
        required: ["handle", "kind", "sizeBytes", "lineCount", "sha256", "createdAt", "expiresAt", "producer"],
        properties: [
            "handle": type("string"), "kind": type("string"), "sizeBytes": type("integer"),
            "lineCount": type("integer"), "sha256": sha256Schema, "createdAt": type("string"),
            "expiresAt": type("string"), "producer": type("string")
        ]
    )

    private static let lookupEvidenceSchema = closedObject(
        required: ["stepID", "status", "ineligibilityReason"],
        properties: [
            "stepID": type("string"), "status": enumType(["hit", "miss", "expired", "incomplete", "ineligible"]),
            "ineligibilityReason": nullableEnumType(["binding_unavailable", "binding_incomplete", "unsupported"])
        ]
    )

    private static let pipelineStepSchema = closedObject(
        required: ["stepID", "terminalState", "sourceRunID", "stdoutArtifactSHA256", "stderrArtifactSHA256", "artifacts", "skippedBecauseDependencyFailed"],
        properties: [
            "stepID": type("string"),
            "terminalState": enumType(["passed", "failed", "timed_out", "cancelled", "signaled", "launch_failed", "artifact_failed"]),
            "sourceRunID": type("string"), "stdoutArtifactSHA256": sha256Schema, "stderrArtifactSHA256": sha256Schema,
            "artifacts": arrayOf(artifactSchema), "skippedBecauseDependencyFailed": type("boolean")
        ]
    )

    private static let runCheckV2SuccessSchema = closedObject(
        required: ["schemaVersion", "planDigest", "selectionDigest", "requestedCheckIDs", "plannedCheckIDs", "cacheState", "processesStarted", "publications", "steps", "lookupEvidence"],
        properties: [
            "schemaVersion": constString("aishell.run-check.v2"), "planDigest": sha256Schema,
            "selectionDigest": sha256Schema, "requestedCheckIDs": arrayOf(type("string")),
            "plannedCheckIDs": arrayOf(type("string")),
            "cacheState": enumType(["disabled", "hit", "miss_executed", "refresh_executed", "ineligible"]),
            "processesStarted": type("integer"), "publications": type("integer"),
            "steps": arrayOf(pipelineStepSchema), "lookupEvidence": arrayOf(lookupEvidenceSchema),
            "diagnostics": type("object")
        ]
    )

    private static let runCheckV2ErrorSchema = closedObject(
        required: ["schemaVersion", "error"],
        properties: [
            "schemaVersion": constString("aishell.run-check.v2"),
            "error": closedObject(required: ["code", "message", "processesStarted", "lookupEvidence"], properties: [
                "code": enumType(["RUN_CHECK_INVOCATION_INVALID", "RUN_CHECK_CACHE_NOT_ALLOWED", "RUN_CHECK_SELECTION_STALE", "RUN_CHECK_CACHE_MISS", "CACHE_CORRUPT", "CONTENT_CHANGED", "RUN_CHECK_CACHE_FAILED", "RUN_CHECK_START_NOT_READY", "RUN_KEY_CONFLICT"]),
                "message": type("string"), "processesStarted": type("integer"),
                "lookupEvidence": arrayOf(lookupEvidenceSchema)
            ])
        ]
    )

    private static let runCheckV2StartSchema = closedObject(
        required: [
            "schemaVersion", "dispatch", "planDigest", "runHandle", "runID", "state",
            "stateRevision", "evidenceCursor", "stdoutBytes", "stderrBytes", "diagnosticBytes",
            "executable", "arguments", "workingDirectory", "environmentDigest", "startedAt",
            "timeoutDeadline", "retentionSeconds"
        ],
        properties: [
            "schemaVersion": constString("aishell.run-check.v2"),
            "dispatch": constString("start"),
            "planDigest": sha256Schema,
            "runHandle": boundedString(minLength: 1, maxLength: 16_384),
            "runID": type("string"),
            "state": enumType(["starting", "running", "cancelling", "timing_out", "finalizing", "recovery_required", "passed", "failed", "timed_out", "cancelled", "interrupted"]),
            "stateRevision": integer("managed run state revision", minimum: 0),
            "evidenceCursor": boundedString(minLength: 1, maxLength: 16_384),
            "stdoutBytes": integer("persisted stdout bytes", minimum: 0),
            "stderrBytes": integer("persisted stderr bytes", minimum: 0),
            "diagnosticBytes": integer("persisted diagnostic bytes", minimum: 0),
            "executable": boundedString(minLength: 1, maxLength: 4_096),
            "arguments": arrayOf(type("string")),
            "workingDirectory": boundedString(minLength: 1, maxLength: 4_096),
            "environmentDigest": sha256Schema,
            "startedAt": type("string"),
            "timeoutDeadline": type("string"),
            "retentionSeconds": type("number"),
            "terminationCause": type("string"),
            "stdoutArtifact": type("object"),
            "stderrArtifact": type("object"),
            "diagnosticArtifact": type("object"),
            "expiresAt": type("string")
        ]
    )

    private static func runCheckExpandedOutputSchema(legacy: JSONValue) -> JSONValue {
        let legacyVariants = legacy.objectValue?["oneOf"]?.arrayValue ?? []
        return .object([
            "type": .string("object"),
            "oneOf": .array(legacyVariants + [runCheckV2SuccessSchema, runCheckV2StartSchema, runCheckV2ErrorSchema])
        ])
    }

    private static let changedPathSchema: JSONValue = .object(["oneOf": .array([
        closedObject(required: ["path", "content_sha256"], properties: [
            "path": boundedString(minLength: 1, maxLength: 4_096), "content_sha256": sha256Schema
        ]),
        closedObject(required: ["path", "expected_absent"], properties: [
            "path": boundedString(minLength: 1, maxLength: 4_096), "expected_absent": .object([
                "type": .string("boolean"), "const": .bool(true)
            ])
        ])
    ])])
    private static let changedSymbolSchema = closedObject(
        required: ["path", "content_sha256", "name", "start_offset", "end_offset"],
        properties: [
            "path": boundedString(minLength: 1, maxLength: 4_096), "content_sha256": sha256Schema,
            "name": boundedString(minLength: 1, maxLength: 1_024),
            "start_offset": integer("UTF-8 byte start", minimum: 0),
            "end_offset": integer("UTF-8 byte end", minimum: 0),
            "stable_id": boundedString(minLength: 1, maxLength: 4_096)
        ]
    )
    private static let changeImpactSharedProperties: [String: JSONValue] = [
        "root": boundedString(minLength: 1, maxLength: 4_096),
        "workspace_cursor": boundedString(minLength: 1, maxLength: 4_096),
        "changed_paths": arrayOf(changedPathSchema, minItems: 1, maxItems: 4_096),
        "changed_symbols": arrayOf(changedSymbolSchema, minItems: 1, maxItems: 4_096),
        "required_providers": boundedStringArray(minItems: 0, maxItems: 64, uniqueItems: true),
        "byte_budget": integer("primary response byte budget", minimum: 1, maximum: 1_048_576)
    ]

    private static func changeImpactInitialSchema(operation: String, recommending: Bool) -> JSONValue {
        var properties = changeImpactSharedProperties
        properties["operation"] = constString(operation)
        var required = ["operation", "workspace_cursor"]
        if recommending {
            properties["project_id"] = boundedString(minLength: 1, maxLength: 4_096)
            properties["profile_digest"] = sha256Schema
            required += ["project_id", "profile_digest"]
        }
        var value = closedObject(required: required, properties: properties).objectValue!
        value["anyOf"] = .array([
            .object(["required": .array([.string("changed_paths")])]),
            .object(["required": .array([.string("changed_symbols")])])
        ])
        return .object(value)
    }

    private static let changeImpactInputSchema: JSONValue = .object([
        "type": .string("object"),
        "oneOf": .array([
            changeImpactInitialSchema(operation: "analyze", recommending: false),
            changeImpactInitialSchema(operation: "recommend", recommending: true),
            closedObject(required: ["continuation"], properties: [
                "continuation": boundedString(minLength: 1, maxLength: 16_384),
                "byte_budget": integer("same or increased byte budget", minimum: 1, maximum: 1_048_576)
            ])
        ])
    ])

    private static let changeImpactFreshnessSchema = closedObject(
        required: ["rootIdentity", "workspaceGeneration", "inputCursor", "observedCursor", "bindingDigest", "bindingCount"],
        properties: [
            "rootIdentity": type("string"), "workspaceGeneration": type("string"),
            "inputCursor": type("string"), "observedCursor": type("string"),
            "bindingDigest": sha256Schema, "bindingCount": type("integer")
        ]
    )
    private static let changeImpactCountsSchema = closedObject(
        required: ["references", "dependencies", "relatedTests", "buildTargets"],
        properties: [
            "references": type("integer"), "dependencies": type("integer"),
            "relatedTests": type("integer"), "buildTargets": type("integer")
        ]
    )
    private static let changeImpactAnalyzeItemSchema: JSONValue = .object([
        "oneOf": .array([
            changeImpactItem(kind: "input_path", fields: ["changedPath": type("object")]),
            changeImpactItem(kind: "input_symbol", fields: ["changedSymbol": type("object")]),
            changeImpactItem(kind: "required_provider", fields: ["providerID": type("string")]),
            changeImpactItem(kind: "freshness_binding", fields: ["freshnessBinding": type("object")]),
            changeImpactItem(kind: "provider_report", fields: ["providerReport": type("object")]),
            changeImpactItem(kind: "coverage_gap", fields: ["coverageGap": type("object")]),
            changeImpactItem(kind: "candidate", fields: [
                "candidateID": sha256Schema, "category": enumType(["references", "dependencies", "related_tests", "build_targets"]),
                "subject": type("object")
            ]),
            changeImpactItem(kind: "evidence", fields: [
                "evidenceID": sha256Schema, "providerID": type("string"), "inputIdentity": type("string"),
                "subject": type("object"), "relation": enumType(["semantic_reference", "lexical_reference", "declared_dependency", "contains_source", "contains_test", "naming_heuristic"]),
                "locator": type("object"), "evidenceStrength": enumType(["heuristic", "lexical_match", "semantic_match", "declared_edge"]), "summary": type("string")
            ]),
            changeImpactItem(kind: "candidate_evidence", fields: ["candidateID": sha256Schema, "evidenceID": sha256Schema])
        ])
    ])

    private static func changeImpactItem(kind: String, fields: [String: JSONValue]) -> JSONValue {
        closedObject(required: ["kind", "itemID"] + fields.keys.sorted(), properties: [
            "kind": constString(kind), "itemID": type("string")
        ].merging(fields) { _, new in new })
    }

    private static let selectorSchema: JSONValue = .object(["oneOf": .array([
        closedObject(required: ["kind", "path"], properties: ["kind": constString("test_path"), "path": type("string")]),
        closedObject(required: ["kind", "id"], properties: ["kind": constString("profile_check"), "id": type("string")]),
        closedObject(required: ["kind", "ecosystemID", "profileIdentity", "manifestPath", "declaredID"], properties: [
            "kind": constString("target"), "ecosystemID": type("string"), "profileIdentity": type("string"),
            "manifestPath": type("string"), "declaredID": type("string")
        ])
    ])])
    private static let focusedStepSchema = closedObject(
        required: ["id", "descriptorDigest", "dependsOn", "ordinal"],
        properties: [
            "id": type("string"), "descriptorDigest": sha256Schema,
            "dependsOn": arrayOf(type("string")), "ordinal": nullableType("integer")
        ]
    )
    private static let recommendationItemSchema: JSONValue = .object(["oneOf": .array([
        changeImpactItem(kind: "focused_candidate", fields: [
            "focusedCheckID": type("string"), "profileCheckID": type("string"),
            "profileDigest": sha256Schema, "selector": selectorSchema
        ]),
        changeImpactItem(kind: "focused_step", fields: ["focusedCheckID": type("string"), "step": focusedStepSchema]),
        changeImpactItem(kind: "dependency_edge", fields: ["focusedCheckID": type("string"), "dependsOn": type("string")]),
        changeImpactItem(kind: "manifest_binding", fields: ["manifest": type("object")]),
        changeImpactItem(kind: "impact_evidence", fields: ["focusedCheckID": type("string"), "evidence": type("object")]),
        changeImpactItem(kind: "coverage_gap", fields: ["coverageGap": type("object")])
    ])])

    private static let analyzeOutputSchema = closedObject(
        required: ["schemaVersion", "operation", "coverage", "freshness", "counts", "items", "returnedBytes", "omittedBytes", "hasMore", "continuation", "artifact"],
        properties: [
            "schemaVersion": constString("aishell.change-impact.v2"), "operation": constString("analyze"),
            "coverage": enumType(["complete", "partial"]), "freshness": changeImpactFreshnessSchema,
            "counts": changeImpactCountsSchema, "items": arrayOf(changeImpactAnalyzeItemSchema, maxItems: 4_096),
            "returnedBytes": type("integer"), "omittedBytes": type("integer"), "hasMore": type("boolean"),
            "continuation": nullableType("string"), "artifact": artifactSchema
        ]
    )
    private static let recommendOutputSchema = closedObject(
        required: ["schema", "operation", "executionPolicy", "focusedSetID", "focusedSetDigest", "expiresAt", "freshness", "coverage", "candidateCount", "stepCount", "limitationCount", "items", "byteBudget", "hasMore", "continuation", "artifact"],
        properties: [
            "schema": constString("aishell.change-impact.v2"), "operation": constString("recommend"),
            "executionPolicy": constString("explicit_run_check_only"), "focusedSetID": type("string"),
            "focusedSetDigest": sha256Schema, "expiresAt": type("string"), "freshness": changeImpactFreshnessSchema,
            "coverage": enumType(["complete", "partial"]), "candidateCount": type("integer"),
            "stepCount": type("integer"), "limitationCount": type("integer"),
            "items": arrayOf(recommendationItemSchema, maxItems: 4_096), "byteBudget": type("integer"),
            "hasMore": type("boolean"), "continuation": nullableType("string"), "artifact": artifactSchema
        ]
    )
    private static let changeImpactErrorSchema = closedObject(
        required: ["schemaVersion", "error"], properties: [
            "schemaVersion": constString("aishell.error.v1"),
            "error": closedObject(required: ["code", "message"], properties: [
                "code": type("string"), "message": type("string"),
                "requiredMinimumBytes": type("integer"), "continuation": type("string"),
                "operation": enumType(["analyze", "recommend"]), "ownerTask": type("string"), "nextAction": type("string")
            ])
        ]
    )
    private static let changeImpactOutputSchema: JSONValue = .object([
        "type": .string("object"),
        "oneOf": .array([analyzeOutputSchema, recommendOutputSchema, changeImpactErrorSchema])
    ])

    private static func closedObject(required: [String], properties: [String: JSONValue]) -> JSONValue {
        .object([
            "type": .string("object"), "required": .array(required.map(JSONValue.string)),
            "properties": .object(properties), "additionalProperties": .bool(false)
        ])
    }

    private static func constString(_ value: String) -> JSONValue {
        .object(["type": .string("string"), "const": .string(value)])
    }

    private static func boundedString(minLength: Int? = nil, maxLength: Int? = nil) -> JSONValue {
        var value: [String: JSONValue] = ["type": .string("string")]
        if let minLength { value["minLength"] = .number(Double(minLength)) }
        if let maxLength { value["maxLength"] = .number(Double(maxLength)) }
        return .object(value)
    }

    private static func boundedStringArray(
        minItems: Int? = nil, maxItems: Int? = nil, uniqueItems: Bool = false
    ) -> JSONValue {
        arrayOf(boundedString(minLength: 1, maxLength: 4_096), minItems: minItems, maxItems: maxItems, uniqueItems: uniqueItems)
    }

    private static func arrayOf(
        _ item: JSONValue, minItems: Int? = nil, maxItems: Int? = nil, uniqueItems: Bool = false
    ) -> JSONValue {
        var value: [String: JSONValue] = ["type": .string("array"), "items": item]
        if let minItems { value["minItems"] = .number(Double(minItems)) }
        if let maxItems { value["maxItems"] = .number(Double(maxItems)) }
        if uniqueItems { value["uniqueItems"] = .bool(true) }
        return .object(value)
    }

    private static func nullableEnumType(_ values: [String]) -> JSONValue {
        .object(["oneOf": .array([enumType(values), .object(["type": .string("null")])])])
    }

    private static func tool(
        _ name: String,
        _ title: String,
        _ description: String,
        properties: [String: JSONValue],
        required: [String],
        readOnly: Bool = false,
        destructive: Bool = false,
        idempotent: Bool,
        openWorld: Bool = false,
        outputSchema: JSONValue? = nil
    ) -> MCPTool {
        MCPTool(
            name: name,
            title: title,
            description: description,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map(JSONValue.string)),
                "additionalProperties": .bool(false)
            ]),
            outputSchema: outputSchema,
            annotations: MCPToolAnnotations(
                readOnlyHint: readOnly,
                destructiveHint: destructive,
                idempotentHint: idempotent,
                openWorldHint: openWorld
            )
        )
    }

    private static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static let expectedStateSchema: JSONValue = .object([
        "type": .string("object"),
        "required": .array([.string("state")]),
        "properties": .object([
            "state": enumString(["absent", "file"], "期待する開始状態"),
            "sha256": string("state=fileで必須のlowercase SHA-256")
        ]),
        "additionalProperties": .bool(false)
    ])

    private static let contentSchema: JSONValue = .object([
        "type": .string("object"),
        "required": .array([.string("encoding"), .string("data")]),
        "properties": .object([
            "encoding": enumString(["utf8", "base64"], "content encoding"),
            "data": string("正規化しないcontent")
        ]),
        "additionalProperties": .bool(false)
    ])

    private static func changeVariantSchema(operation: String, content: Bool) -> JSONValue {
        var properties: [String: JSONValue] = [
            "change_id": string("request内で一意のID"),
            "operation": .object(["const": .string(operation)]),
            "path": string("対象のroot相対path"),
            "expected": expectedStateSchema
        ]
        var required = ["change_id", "operation", "path", "expected"]
        if content {
            properties["content"] = contentSchema
            required.append("content")
        }
        return .object([
            "type": .string("object"),
            "required": .array(required.map(JSONValue.string)),
            "properties": .object(properties),
            "additionalProperties": .bool(false)
        ])
    }

    private static let renameVariantSchema: JSONValue = .object([
        "type": .string("object"),
        "required": .array([
            .string("change_id"), .string("operation"), .string("source"),
            .string("source_expected"), .string("destination"), .string("destination_expected")
        ]),
        "properties": .object([
            "change_id": string("request内で一意のID"),
            "operation": .object(["const": .string("rename")]),
            "source": string("rename元のroot相対path"),
            "source_expected": expectedStateSchema,
            "destination": string("rename先のroot相対path"),
            "destination_expected": expectedStateSchema
        ]),
        "additionalProperties": .bool(false)
    ])

    private static func integer(
        _ description: String, minimum: Int? = nil, maximum: Int? = nil
    ) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("integer"), "description": .string(description)]
        if let minimum { schema["minimum"] = .number(Double(minimum)) }
        if let maximum { schema["maximum"] = .number(Double(maximum)) }
        return .object(schema)
    }

    private static func number(
        _ description: String, minimum: Double? = nil, maximum: Double? = nil
    ) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("number"), "description": .string(description)]
        if let minimum { schema["minimum"] = .number(minimum) }
        if let maximum { schema["maximum"] = .number(maximum) }
        return .object(schema)
    }

    private static func boolean(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    private static func stringArray(_ description: String) -> JSONValue {
        return .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object(["type": .string("string")])
        ])
    }

    private static func stringMap(_ description: String) -> JSONValue {
        .object([
            "type": .string("object"),
            "description": .string(description),
            "additionalProperties": .object(["type": .string("string")])
        ])
    }

    private static func enumString(_ values: [String], _ description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description),
            "enum": .array(values.map(JSONValue.string))
        ])
    }

    private static func type(_ name: String) -> JSONValue {
        .object(["type": .string(name)])
    }

    private static func nullableType(_ name: String) -> JSONValue {
        .object(["type": .array([.string(name), .string("null")])])
    }

    private static func nullableNonNegativeIntegerType() -> JSONValue {
        .object([
            "oneOf": .array([
                .object(["type": .string("integer"), "minimum": .number(0)]),
                .object(["type": .string("null")])
            ])
        ])
    }

    private static func enumType(_ values: [String]) -> JSONValue {
        .object(["type": .string("string"), "enum": .array(values.map(JSONValue.string))])
    }

    private static func objectOutput(
        schemaVersion: String? = nil,
        required: [String],
        properties: [String: JSONValue]
    ) -> JSONValue {
        var successProperties = properties
        if let schemaVersion {
            successProperties["schemaVersion"] = .object(["const": .string(schemaVersion)])
        }
        return .object([
            "type": .string("object"),
            "oneOf": .array([
                .object([
                    "type": .string("object"),
                    "required": .array(required.map(JSONValue.string)),
                    "properties": .object(successProperties),
                    "additionalProperties": .bool(true)
                ]),
                .object([
                    "type": .string("object"),
                    "required": .array([.string("schemaVersion"), .string("error")]),
                    "properties": .object([
                        "schemaVersion": .object(["const": .string("aishell.error.v1")]),
                        "error": .object([
                            "type": .string("object"),
                            "required": .array([.string("code"), .string("message")]),
                            "additionalProperties": .bool(true)
                        ])
                    ]),
                    "additionalProperties": .bool(true)
                ])
            ])
        ])
    }

    private static let factoryDiagnosticsOutputSchema: JSONValue = .object([
        "type": .string("object"),
        "oneOf": .array([
            .object([
                "type": .string("object"),
                "required": .array([
                    .string("schemaVersion"), .string("product"), .string("platform"), .string("runtime"),
                    .string("mcp"), .string("manager"), .string("privacy"), .string("ready"), .string("issues")
                ]),
                "properties": .object([
                    "schemaVersion": .object(["const": .string("aishell.native_factory_diagnostics.v1")]),
                    "product": .object([
                        "type": .string("object"), "required": .array([.string("identifier"), .string("version")]),
                        "properties": .object([
                            "identifier": .object(["const": .string("aishell")]), "version": type("string")
                        ]), "additionalProperties": .bool(false)
                    ]),
                    "platform": .object([
                        "type": .string("object"), "required": .array([
                            .string("operatingSystem"), .string("architecture"), .string("minimumOperatingSystem"), .string("supported")
                        ]), "properties": .object([
                            "operatingSystem": .object(["const": .string("macos")]), "architecture": type("string"),
                            "minimumOperatingSystem": .object(["const": .string("15.0")]), "supported": type("boolean")
                        ]), "additionalProperties": .bool(false)
                    ]),
                    "runtime": .object([
                        "type": .string("object"), "required": .array([
                            .string("schemaVersion"), .string("configurationState"), .string("migrationStatus"),
                            .string("operationReadiness"), .string("isPaused"), .string("configuredRootCount"),
                            .string("automaticGitWorktreeCount"), .string("effectiveRootCount")
                        ]), "properties": .object([
                            "schemaVersion": .object(["const": .string("aishell.runtime_configuration.v2")]),
                            "configurationState": enumType(["valid", "uninitialized", "invalid"]),
                            "migrationStatus": enumType(["compatible_on_read", "blocked"]),
                            "operationReadiness": enumType(["ready", "paused", "not_configured", "invalid_roots", "invalid_configuration"]),
                            "isPaused": nullableType("boolean"), "configuredRootCount": nullableNonNegativeIntegerType(),
                            "automaticGitWorktreeCount": nullableNonNegativeIntegerType(), "effectiveRootCount": nullableNonNegativeIntegerType()
                        ]), "additionalProperties": .bool(false)
                    ]),
                    "mcp": .object([
                        "type": .string("object"), "required": .array([.string("transport"), .string("protocolVersion"), .string("ready")]),
                        "properties": .object([
                            "transport": .object(["const": .string("stdio")]), "protocolVersion": type("string"), "ready": type("boolean")
                        ]), "additionalProperties": .bool(false)
                    ]),
                    "manager": .object([
                        "type": .string("object"), "required": .array([.string("applicationBundleState"), .string("ready")]),
                        "properties": .object([
                            "applicationBundleState": enumType(["available", "unavailable"]), "ready": type("boolean")
                        ]), "additionalProperties": .bool(false)
                    ]),
                    "privacy": .object([
                        "type": .string("object"), "required": .array([
                            .string("exposesAllowedRootPaths"), .string("exposesOperationHistory"),
                            .string("exposesFileContents"), .string("exposesProcessArguments")
                        ]), "properties": .object([
                            "exposesAllowedRootPaths": .object(["const": .bool(false)]),
                            "exposesOperationHistory": .object(["const": .bool(false)]),
                            "exposesFileContents": .object(["const": .bool(false)]),
                            "exposesProcessArguments": .object(["const": .bool(false)])
                        ]), "additionalProperties": .bool(false)
                    ]),
                    "ready": type("boolean"),
                    "issues": .object([
                        "type": .string("array"), "items": enumType([
                            "runtime.invalid_roots", "runtime.invalid_configuration", "platform.unsupported", "manager.application_bundle_unavailable"
                        ])
                    ])
                ]), "additionalProperties": .bool(false)
            ]),
            .object([
                "type": .string("object"), "required": .array([.string("schemaVersion"), .string("error")]),
                "properties": .object([
                    "schemaVersion": .object(["const": .string("aishell.error.v1")]),
                    "error": .object(["type": .string("object")])
                ]), "additionalProperties": .bool(true)
            ])
        ])
    ])

    private static func objectOutputWithAlternate(
        primarySchemaKey: String,
        primarySchemaVersion: String,
        alternateSchemaKey: String,
        alternateSchemaVersion: String,
        required: [String],
        properties: [String: JSONValue]
    ) -> JSONValue {
        func success(_ key: String, _ version: String) -> JSONValue {
            var successProperties = properties
            successProperties[key] = .object(["const": .string(version)])
            return .object([
                "type": .string("object"),
                "required": .array((required + [key]).map(JSONValue.string)),
                "properties": .object(successProperties),
                "additionalProperties": .bool(true)
            ])
        }
        return .object([
            "type": .string("object"),
            "oneOf": .array([
                success(primarySchemaKey, primarySchemaVersion),
                success(alternateSchemaKey, alternateSchemaVersion),
                .object([
                    "type": .string("object"),
                    "required": .array([.string("schemaVersion"), .string("error")]),
                    "properties": .object([
                        "schemaVersion": .object(["const": .string("aishell.error.v1")]),
                        "error": .object([
                            "type": .string("object"),
                            "required": .array([.string("code"), .string("message")]),
                            "additionalProperties": .bool(true)
                        ])
                    ]),
                    "additionalProperties": .bool(true)
                ])
            ])
        ])
    }
}

enum MCPStartupError: LocalizedError, Equatable {
    case invalidToolProfile(String)
    case invalidCapabilitySet(String)
    case factoryProfileDoesNotAcceptCapabilitySet(String)

    var errorDescription: String? {
        switch self {
        case let .invalidToolProfile(value):
            "INVALID_TOOL_PROFILE: AISHELL_TOOL_PROFILEはdevelopment、factory、full、legacyだけを受理します: \(value)"
        case let .invalidCapabilitySet(value):
            "INVALID_CAPABILITY_SET: AISHELL_CAPABILITY_SETは未指定またはexpanded-v1だけを受理します: \(value)"
        case let .factoryProfileDoesNotAcceptCapabilitySet(value):
            "FACTORY_PROFILE_CAPABILITY_SET_UNSUPPORTED: factory profileはAISHELL_CAPABILITY_SETを受理しません: \(value)"
        }
    }
}
