import AIShellCore
import Foundation

/// MCP wire DTO を、実行や service 呼出しを伴わない closed な意味 request へ変換する。
enum MCPRunCheckAdapter {
    enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
    }

    enum RunCheckRequest: Equatable, Sendable {
        case legacy(LegacyRunCheckRequest)
        case v2(V2RunCheckRequest)
    }

    /// v1は既存MCP runtimeへ渡す秒単位のDoubleをそのまま保つ。planning用の整数policyへ
    /// 早期に丸めると、既存のfractional timeout/retention互換を失う。
    struct LegacyRunCheckRequest: Equatable, Sendable {
        let executable: String
        let arguments: [String]
        let workingDirectory: String?
        let environment: [String: String]
        let timeoutSeconds: Double
        let retentionSeconds: Double
    }

    struct V2RunCheckRequest: Equatable, Sendable {
        let invocation: RunCheckInvocationPlan.Invocation
        let dispatch: RunCheckInvocationPlan.Dispatch
        let cachePolicy: RunCheckInvocationPlan.CachePolicy
        let executionPolicy: RunCheckInvocationPlan.ExecutionPolicy
        let selection: Selection

        /// `prepare` は Core の canonical selection API が digest を生成するまで保持する。
        enum Selection: Equatable, Sendable {
            case prepare
            case prepareFocusedSet(focusedSetDigest: String)
            case focusedSet(focusedSetDigest: String, selectionDigest: String)
        }

    }

    enum ChangeImpactRequest: Sendable {
        case analyze(AIShellCore.ChangeImpactRequest)
        case recommend(AIShellCore.ChangeImpactRecommendationRequest)
        case continuation(ChangeImpactContinuation)
    }

    /// continuation は operation を wire に持たないため、ここでは勝手に analyze/recommend を選ばない。
    struct ChangeImpactContinuation: Equatable, Sendable {
        let token: String
        let byteBudget: Int?

    }

    static func runCheck(arguments: [String: JSONValue]) throws -> RunCheckRequest {
        let dto: MCPRunCheckRequestDTO
        do {
            dto = try JSONDecoder.aishell.decode(
                MCPRunCheckRequestDTO.self,
                from: JSONEncoder.aishell.encode(JSONValue.object(arguments))
            )
        } catch {
            throw Error.invalidArguments
        }
        switch dto {
        case let .legacy(legacy):
            let timeout = legacy.timeoutSeconds ?? 120
            let retention = legacy.retentionSeconds ?? 86_400
            guard timeout.isFinite, retention.isFinite, retention <= 604_800 else { throw Error.invalidArguments }
            return .legacy(.init(
                executable: legacy.executable,
                arguments: legacy.arguments,
                workingDirectory: legacy.workingDirectory,
                environment: legacy.environment,
                timeoutSeconds: timeout,
                retentionSeconds: retention
            ))
        case let .v2(v2):
            let invocation: RunCheckInvocationPlan.Invocation
            switch v2.invocation {
            case let .direct(executable, arguments, directory, environment, diagnosticAdapter):
                invocation = .direct(.init(
                    executable: executable,
                    arguments: arguments,
                    workingDirectory: directory,
                    effectiveEnvironment: environment,
                    diagnosticFormat: diagnosticAdapter.flatMap(DiagnosticFormat.init(rawValue:))
                ))
            case let .profileCheck(projectID, profileDigest, checkID):
                invocation = .profileCheck(.init(projectID: projectID, profileDigest: profileDigest, checkID: checkID))
            case let .focusedSet(id, ids):
                invocation = .focusedSet(.init(setID: id, orderedCheckIDs: ids))
            }
            let dispatch: RunCheckInvocationPlan.Dispatch = switch v2.dispatch {
            case .sync: .sync
            case let .start(key): .start(clientRunKey: key)
            }
            guard let cache = RunCheckInvocationPlan.CachePolicy(rawValue: v2.cache) else { throw Error.invalidArguments }
            let selection: V2RunCheckRequest.Selection = switch v2.selection {
            case .preparedByCore: .prepare
            case let .prepareFocusedSet(set): .prepareFocusedSet(focusedSetDigest: set)
            case let .focusedSet(set, digest): .focusedSet(focusedSetDigest: set, selectionDigest: digest)
            }
            if case .direct = invocation, cache != .off { throw Error.invalidArguments }
            return .v2(.init(
                invocation: invocation, dispatch: dispatch, cachePolicy: cache,
                executionPolicy: .init(timeoutMilliseconds: UInt64(v2.timeoutMilliseconds), retentionSeconds: UInt64(v2.retentionSeconds)),
                selection: selection
            ))
        }
    }

    static func changeImpact(arguments: [String: JSONValue]) throws -> ChangeImpactRequest {
        if arguments["continuation"] != nil {
            try exactKeys(arguments, allowed: ["continuation", "byte_budget"])
            guard let token = string(arguments["continuation"], maximum: 16_384),
                  let budget = optionalInt(arguments["byte_budget"], range: 1...1_048_576) else { throw Error.invalidArguments }
            return .continuation(.init(token: token, byteBudget: budget))
        }
        guard let operation = arguments["operation"]?.stringValue,
              operation == "analyze" || operation == "recommend" else { throw Error.invalidArguments }
        let allowed = operation == "analyze"
            ? Set(["operation", "root", "workspace_cursor", "changed_paths", "changed_symbols", "required_providers", "byte_budget"])
            : Set(["operation", "root", "workspace_cursor", "changed_paths", "changed_symbols", "required_providers", "byte_budget", "project_id", "profile_digest"])
        try exactKeys(arguments, allowed: allowed)
        guard
              let cursor = string(arguments["workspace_cursor"], maximum: 4_096),
              let paths = changedPaths(arguments["changed_paths"]),
              let symbols = changedSymbols(arguments["changed_symbols"]),
              !paths.isEmpty || !symbols.isEmpty,
              let providers = stringArray(arguments["required_providers"], maximum: 64), Set(providers).count == providers.count,
              let budget = optionalInt(arguments["byte_budget"], range: 1...1_048_576),
              let root = optionalString(arguments["root"], maximum: 4_096)
        else { throw Error.invalidArguments }
        let impact = AIShellCore.ChangeImpactRequest(
            operation: .analyze, root: root, workspaceCursor: cursor, changedPaths: paths,
            changedSymbols: symbols, requiredProviders: providers, byteBudget: budget
        )
        if operation == "analyze" { return .analyze(impact) }
        guard let projectID = string(arguments["project_id"], maximum: 4_096),
              let profileDigest = arguments["profile_digest"]?.stringValue, sha256(profileDigest) else { throw Error.invalidArguments }
        return .recommend(.init(impactRequest: impact, projectID: projectID, profileDigest: profileDigest, byteBudget: budget))
    }

    private static func changedPaths(_ value: JSONValue?) -> [AIShellCore.ChangeImpactChangedPath]? {
        guard let value else { return [] }
        guard let array = value.arrayValue, array.count <= 4_096 else { return nil }
        var seen = Set<String>()
        var result: [AIShellCore.ChangeImpactChangedPath] = []
        for item in array {
            guard let object = item.objectValue else { return nil }
            guard (try? exactKeys(object, allowed: ["path", "content_sha256", "expected_absent"])) != nil else { return nil }
            guard let path = string(object["path"], maximum: 4_096), seen.insert(path).inserted else { return nil }
            let digest = object["content_sha256"]?.stringValue
            let absent = object["expected_absent"]?.boolValue ?? false
            guard absent != (digest != nil), digest.map(sha256) ?? true else { return nil }
            result.append(.init(path: path, contentSHA256: digest, expectedAbsent: absent))
        }
        return result
    }

    private static func changedSymbols(_ value: JSONValue?) -> [AIShellCore.ChangeImpactChangedSymbol]? {
        guard let value else { return [] }
        guard let array = value.arrayValue, array.count <= 4_096 else { return nil }
        var seen = Set<String>()
        var result: [AIShellCore.ChangeImpactChangedSymbol] = []
        for item in array {
            guard let object = item.objectValue else { return nil }
            guard (try? exactKeys(object, allowed: ["path", "content_sha256", "name", "start_offset", "end_offset", "stable_id"])) != nil,
                  let path = string(object["path"], maximum: 4_096),
                  let digest = object["content_sha256"]?.stringValue, sha256(digest),
                  let name = string(object["name"], maximum: 1_024),
                  let start = object["start_offset"]?.intValue, let end = object["end_offset"]?.intValue,
                  start >= 0, end > start,
                  let stableID = optionalString(object["stable_id"], maximum: 4_096)
            else { return nil }
            let key = [path, digest, name, String(start), String(end), stableID ?? ""].joined(separator: "\u{0}")
            guard seen.insert(key).inserted else { return nil }
            result.append(.init(path: path, contentSHA256: digest, name: name, startOffset: start, endOffset: end, stableID: stableID))
        }
        return result
    }

    private static func exactKeys(_ object: [String: JSONValue], allowed: Set<String>) throws {
        guard Set(object.keys).isSubset(of: allowed) else { throw Error.invalidArguments }
    }
    private static func string(_ value: JSONValue?, maximum: Int) -> String? {
        guard let value = value?.stringValue, !value.isEmpty, value.utf8.count <= maximum else { return nil }; return value
    }
    private static func optionalString(_ value: JSONValue?, maximum: Int) -> String?? {
        guard let value else { return .some(nil) }
        return string(value, maximum: maximum)
    }
    private static func stringArray(_ value: JSONValue?, maximum: Int) -> [String]? {
        guard let value else { return [] }
        guard let values = value.arrayValue, values.count <= maximum else { return nil }
        let strings = values.compactMap { string($0, maximum: 4_096) }
        return strings.count == values.count ? strings : nil
    }
    private static func optionalInt(_ value: JSONValue?, range: ClosedRange<Int>) -> Int?? {
        guard let value else { return .some(nil) }
        guard let integer = value.intValue, range.contains(integer) else { return nil }; return .some(integer)
    }
    private static func sha256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
