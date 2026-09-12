import CryptoKit
import Foundation

/// ADR 0018 が定める `run_check` の immutable invocation plan。
///
/// この型は request の解釈だけを所有する。process admission、cache lookup、focused
/// selection の再照合は consumer 側が plan digest を受け取ってから行うため、ここで
/// invocation や dispatch を都合よく書き換えることはない。
public struct RunCheckInvocationPlan: Equatable, Sendable {
    public static let schema = "aishell.run-check-invocation-plan.v1"

    public enum Invocation: Equatable, Sendable {
        case direct(Direct)
        case profileCheck(ProfileCheck)
        case focusedSet(FocusedSet)
    }

    public struct Direct: Equatable, Sendable {
        public let executable: String
        public let arguments: [String]
        /// v1の`working_directory`省略を空文字や既定cwdへ捏造しない。
        public let workingDirectory: String?
        public let effectiveEnvironment: [String: String]
        public let diagnosticFormat: DiagnosticFormat?

        public init(
            executable: String,
            arguments: [String],
            workingDirectory: String?,
            effectiveEnvironment: [String: String],
            diagnosticFormat: DiagnosticFormat? = nil
        ) {
            self.executable = executable
            self.arguments = arguments
            self.workingDirectory = workingDirectory
            self.effectiveEnvironment = effectiveEnvironment
            self.diagnosticFormat = diagnosticFormat
        }
    }

    public struct ProfileCheck: Equatable, Sendable {
        public let projectID: String
        public let profileDigest: String
        public let checkID: String

        public init(projectID: String, profileDigest: String, checkID: String) {
            self.projectID = projectID
            self.profileDigest = profileDigest
            self.checkID = checkID
        }
    }

    public struct FocusedSet: Equatable, Sendable {
        public let setID: String
        public let orderedCheckIDs: [String]

        public init(setID: String, orderedCheckIDs: [String]) {
            self.setID = setID
            self.orderedCheckIDs = orderedCheckIDs
        }
    }

    public enum Dispatch: Equatable, Sendable {
        case sync
        case start(clientRunKey: String)
    }

    public enum CachePolicy: String, CaseIterable, Sendable {
        case off
        case prefer
        case only
        case refresh
    }

    /// Process の具体的な起動は consumer が所有するが、timeout と retention は plan identity
    /// に含める。これにより同じ選択でも lifecycle が異なる request を同一 plan にしない。
    public struct ExecutionPolicy: Equatable, Sendable {
        public let timeoutMilliseconds: UInt64
        public let retentionSeconds: UInt64

        public init(timeoutMilliseconds: UInt64 = 120_000, retentionSeconds: UInt64 = 86_400) {
            self.timeoutMilliseconds = timeoutMilliseconds
            self.retentionSeconds = retentionSeconds
        }
    }

    public struct LegacyDirectRequest: Equatable, Sendable {
        public let executable: String
        public let arguments: [String]
        public let workingDirectory: String?
        public let effectiveEnvironment: [String: String]
        public let executionPolicy: ExecutionPolicy

        public init(
            executable: String,
            arguments: [String],
            workingDirectory: String?,
            effectiveEnvironment: [String: String],
            executionPolicy: ExecutionPolicy = .init()
        ) {
            self.executable = executable
            self.arguments = arguments
            self.workingDirectory = workingDirectory
            self.effectiveEnvironment = effectiveEnvironment
            self.executionPolicy = executionPolicy
        }
    }

    public struct V2Request: Equatable, Sendable {
        public let invocation: Invocation
        public let dispatch: Dispatch
        public let cachePolicy: CachePolicy
        public let executionPolicy: ExecutionPolicy
        public let selectionDigest: String

        public init(
            invocation: Invocation,
            dispatch: Dispatch,
            cachePolicy: CachePolicy,
            executionPolicy: ExecutionPolicy = .init(),
            selectionDigest: String
        ) {
            self.invocation = invocation
            self.dispatch = dispatch
            self.cachePolicy = cachePolicy
            self.executionPolicy = executionPolicy
            self.selectionDigest = selectionDigest
        }
    }

    /// public `run_check` schemaのdirect/profile preparation用入力。selection digestは
    /// Coreがcanonical invocation materialから生成するため、callerはplaceholderを渡さない。
    public struct PreparedRequest: Equatable, Sendable {
        public let invocation: Invocation
        public let dispatch: Dispatch
        public let cachePolicy: CachePolicy
        public let executionPolicy: ExecutionPolicy

        public init(
            invocation: Invocation,
            dispatch: Dispatch,
            cachePolicy: CachePolicy,
            executionPolicy: ExecutionPolicy = .init()
        ) {
            self.invocation = invocation
            self.dispatch = dispatch
            self.cachePolicy = cachePolicy
            self.executionPolicy = executionPolicy
        }
    }

    /// MCP adapter が v1 flat fields と v2 object を同時に受けたことを、曖昧な優先順なしに
    /// compiler へ伝えるための closed input。
    public enum Request: Equatable, Sendable {
        case legacyDirect(LegacyDirectRequest)
        case v2(V2Request)
        case mixed(legacy: LegacyDirectRequest, v2: V2Request)
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case invocationInvalid
        case cacheNotAllowed

        public var code: String {
            switch self {
            case .invocationInvalid: "RUN_CHECK_INVOCATION_INVALID"
            case .cacheNotAllowed: "RUN_CHECK_CACHE_NOT_ALLOWED"
            }
        }
    }

    public let invocation: Invocation
    public let dispatch: Dispatch
    public let cachePolicy: CachePolicy
    public let executionPolicy: ExecutionPolicy
    public let selectionDigest: String
    public let requestDigest: String

    /// Canonical bytes は secret を含み得るため、外部 response へ出してはいけない。
    /// consumer は `digest` だけを activity / managed-run receipt に出す。
    var canonicalBytes: Data {
        Self.encodePlan(
            invocation: invocation,
            dispatch: dispatch,
            cachePolicy: cachePolicy,
            executionPolicy: executionPolicy,
            selectionDigest: selectionDigest,
            requestDigest: requestDigest
        )
    }

    public var digest: String { Self.sha256(canonicalBytes) }

    public static func compile(_ request: Request) throws -> RunCheckInvocationPlan {
        switch request {
        case let .legacyDirect(legacy):
            let invocation = Invocation.direct(.init(
                executable: legacy.executable,
                arguments: legacy.arguments,
                workingDirectory: legacy.workingDirectory,
                effectiveEnvironment: legacy.effectiveEnvironment
            ))
            let selectionDigest = sha256(encodeInvocation(invocation))
            let requestDigest = sha256(encodeLegacy(legacy))
            return try make(
                invocation: invocation,
                dispatch: .sync,
                cachePolicy: .off,
                executionPolicy: legacy.executionPolicy,
                selectionDigest: selectionDigest,
                requestDigest: requestDigest
            )
        case let .v2(v2):
            // direct/profile selection は caller が選んだ hash ではなく、閉じた invocation
            // material から Core 自身が導出する。focused だけは immutable set receipt
            // から導出済みの digest を admission 時に再照合するため入力として運ぶ。
            let selectionDigest = canonicalSelectionDigest(for: v2.invocation) ?? v2.selectionDigest
            return try make(
                invocation: v2.invocation,
                dispatch: v2.dispatch,
                cachePolicy: v2.cachePolicy,
                executionPolicy: v2.executionPolicy,
                selectionDigest: selectionDigest,
                requestDigest: sha256(encodeV2(v2, effectiveSelectionDigest: selectionDigest))
            )
        case .mixed:
            throw Error.invocationInvalid
        }
    }

    /// selectionをcaller supplied fieldとして持たないdirect/profileの公開prepare入口。
    /// focused setは保存receipt由来selectionをexactに照合するため、この型では受けない。
    public static func prepare(_ request: PreparedRequest) throws -> RunCheckInvocationPlan {
        guard let selectionDigest = canonicalSelectionDigest(for: request.invocation) else {
            throw Error.invocationInvalid
        }
        return try make(
            invocation: request.invocation,
            dispatch: request.dispatch,
            cachePolicy: request.cachePolicy,
            executionPolicy: request.executionPolicy,
            selectionDigest: selectionDigest,
            requestDigest: sha256(encodePrepared(request, selectionDigest: selectionDigest))
        )
    }

    /// caller supplied selection hashを信頼してはならない invocation のcanonical selection
    /// digest。focused set は保存済みreceiptと照合して初めて確定するため `nil` を返す。
    public static func canonicalSelectionDigest(for invocation: Invocation) -> String? {
        switch invocation {
        case .direct, .profileCheck:
            return sha256(encodeInvocation(invocation))
        case .focusedSet:
            return nil
        }
    }

    private static func make(
        invocation: Invocation,
        dispatch: Dispatch,
        cachePolicy: CachePolicy,
        executionPolicy: ExecutionPolicy,
        selectionDigest: String,
        requestDigest: String
    ) throws -> RunCheckInvocationPlan {
        guard isValid(invocation), isValid(dispatch), executionPolicy.timeoutMilliseconds > 0,
              executionPolicy.retentionSeconds > 0, isSHA256(selectionDigest), isSHA256(requestDigest) else {
            throw Error.invocationInvalid
        }
        if case .direct = invocation, cachePolicy != .off {
            throw Error.cacheNotAllowed
        }
        return .init(
            invocation: invocation,
            dispatch: dispatch,
            cachePolicy: cachePolicy,
            executionPolicy: executionPolicy,
            selectionDigest: selectionDigest,
            requestDigest: requestDigest
        )
    }

    private static func isValid(_ invocation: Invocation) -> Bool {
        switch invocation {
        case let .direct(direct):
            return !direct.executable.isEmpty && direct.workingDirectory != ""
                && direct.effectiveEnvironment.allSatisfy { !$0.key.isEmpty }
        case let .profileCheck(profile):
            return !profile.projectID.isEmpty && !profile.checkID.isEmpty && isSHA256(profile.profileDigest)
        case let .focusedSet(set):
            return !set.setID.isEmpty && !set.orderedCheckIDs.isEmpty
                && set.orderedCheckIDs.allSatisfy { !$0.isEmpty }
                && Set(set.orderedCheckIDs).count == set.orderedCheckIDs.count
        }
    }

    private static func isValid(_ dispatch: Dispatch) -> Bool {
        switch dispatch {
        case .sync: true
        case let .start(clientRunKey): (1 ... 128).contains(clientRunKey.utf8.count)
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func encodeLegacy(_ request: LegacyDirectRequest) -> Data {
        encode([
            ("request_version", Data("v1".utf8)),
            ("invocation", encodeInvocation(.direct(.init(
                executable: request.executable,
                arguments: request.arguments,
                workingDirectory: request.workingDirectory,
                effectiveEnvironment: request.effectiveEnvironment
            )))),
            ("execution_policy", encodeExecutionPolicy(request.executionPolicy)),
        ])
    }

    private static func encodeV2(_ request: V2Request, effectiveSelectionDigest: String) -> Data {
        encode([
            ("request_version", Data("v2".utf8)),
            ("invocation", encodeInvocation(request.invocation)),
            ("dispatch", encodeDispatch(request.dispatch)),
            ("cache", Data(request.cachePolicy.rawValue.utf8)),
            ("execution_policy", encodeExecutionPolicy(request.executionPolicy)),
            ("selection_digest", Data(effectiveSelectionDigest.utf8)),
        ])
    }

    private static func encodePrepared(_ request: PreparedRequest, selectionDigest: String) -> Data {
        encode([
            // preparedはv2 wireのdirect/profile正規入口。effective canonical materialを
            // 既存v2互換経路と一致させ、入口だけで別plan identityを作らない。
            ("request_version", Data("v2".utf8)),
            ("invocation", encodeInvocation(request.invocation)),
            ("dispatch", encodeDispatch(request.dispatch)),
            ("cache", Data(request.cachePolicy.rawValue.utf8)),
            ("execution_policy", encodeExecutionPolicy(request.executionPolicy)),
            ("selection_digest", Data(selectionDigest.utf8)),
        ])
    }

    private static func encodePlan(
        invocation: Invocation,
        dispatch: Dispatch,
        cachePolicy: CachePolicy,
        executionPolicy: ExecutionPolicy,
        selectionDigest: String,
        requestDigest: String
    ) -> Data {
        encode([
            ("schema", Data(schema.utf8)),
            ("invocation", encodeInvocation(invocation)),
            ("dispatch", encodeDispatch(dispatch)),
            ("cache", Data(cachePolicy.rawValue.utf8)),
            ("execution_policy", encodeExecutionPolicy(executionPolicy)),
            ("selection_digest", Data(selectionDigest.utf8)),
            ("request_digest", Data(requestDigest.utf8)),
        ])
    }

    private static func encodeInvocation(_ invocation: Invocation) -> Data {
        switch invocation {
        case let .direct(direct):
            encode([
                ("kind", Data("direct".utf8)),
                ("executable", Data(direct.executable.utf8)),
                ("arguments", encodeArray(direct.arguments)),
                ("working_directory", encodeOptional(direct.workingDirectory)),
                ("environment", encodeMap(direct.effectiveEnvironment)),
                ("diagnostic_format", encodeOptional(direct.diagnosticFormat?.rawValue)),
            ])
        case let .profileCheck(profile):
            encode([
                ("kind", Data("profile_check".utf8)),
                ("project_id", Data(profile.projectID.utf8)),
                ("profile_digest", Data(profile.profileDigest.utf8)),
                ("check_id", Data(profile.checkID.utf8)),
            ])
        case let .focusedSet(set):
            encode([
                ("kind", Data("focused_set".utf8)),
                ("set_id", Data(set.setID.utf8)),
                ("ordered_check_ids", encodeArray(set.orderedCheckIDs)),
            ])
        }
    }

    private static func encodeDispatch(_ dispatch: Dispatch) -> Data {
        switch dispatch {
        case .sync: encode([("mode", "sync")])
        case let .start(clientRunKey): encode([("mode", "start"), ("client_run_key", clientRunKey)])
        }
    }

    private static func encodeExecutionPolicy(_ policy: ExecutionPolicy) -> Data {
        encode([
            ("timeout_milliseconds", String(policy.timeoutMilliseconds)),
            ("retention_seconds", String(policy.retentionSeconds)),
        ])
    }

    private static func encodeArray(_ values: [String]) -> Data {
        var data = Data()
        append("array", to: &data)
        append(String(values.count), to: &data)
        for value in values { append(value, to: &data) }
        return data
    }

    /// absent、空文字、実値を別々のlength-prefixed objectへ固定する。
    private static func encodeOptional(_ value: String?) -> Data {
        switch value {
        case .none:
            encode([("present", "false")])
        case let .some(value):
            encode([("present", "true"), ("value", value)])
        }
    }

    private static func encodeMap(_ values: [String: String]) -> Data {
        var data = Data()
        append("map", to: &data)
        let keys = values.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        append(String(keys.count), to: &data)
        for key in keys {
            append(key, to: &data)
            append(values[key]!, to: &data)
        }
        return data
    }

    private static func encode(_ fields: [(String, String)]) -> Data {
        encode(fields.map { ($0.0, Data($0.1.utf8)) })
    }

    private static func encode(_ fields: [(String, Data)]) -> Data {
        var data = Data()
        let ordered = fields.sorted { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }
        append("object", to: &data)
        append(String(ordered.count), to: &data)
        for (key, value) in ordered {
            append(key, to: &data)
            append(value, to: &data)
        }
        return data
    }

    private static func append(_ value: String, to data: inout Data) {
        append(Data(value.utf8), to: &data)
    }

    private static func append(_ value: Data, to data: inout Data) {
        data.append(Data(String(value.count).utf8))
        data.append(0x3A)
        data.append(value)
    }
}
