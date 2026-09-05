import CryptoKit
import Darwin
import Foundation

public enum GitContextError: Error, Equatable, LocalizedError, Sendable {
    case notGitRepository
    case repositoryOutsideAllowedRoot(String)
    case unresolvedBase(String)
    case invalidComparisonMode(String)
    case unbornHeadWithExplicitBase
    case pathEncodingUnsupported
    case contentChanged
    case invalidContinuation
    case cursorExpired
    case gitFailed(exitCode: Int32, arguments: [String], stderr: String)
    case artifactPublicationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notGitRepository: "NOT_GIT_REPOSITORY"
        case let .repositoryOutsideAllowedRoot(path): "REPOSITORY_OUTSIDE_WORKSPACE: \(path)"
        case let .unresolvedBase(ref): "UNRESOLVED_BASE: \(ref)"
        case let .invalidComparisonMode(reason): "INVALID_COMPARISON_MODE: \(reason)"
        case .unbornHeadWithExplicitBase: "UNBORN_HEAD_WITH_EXPLICIT_BASE"
        case .pathEncodingUnsupported: "PATH_ENCODING_UNSUPPORTED"
        case .contentChanged: "CONTENT_CHANGED"
        case .invalidContinuation: "INVALID_CONTINUATION"
        case .cursorExpired: "CURSOR_EXPIRED"
        case let .gitFailed(exitCode, arguments, stderr):
            "GIT_FAILED(\(exitCode)): git \(arguments.joined(separator: " ")): \(stderr)"
        case let .artifactPublicationFailed(reason): "ARTIFACT_PUBLICATION_FAILED: \(reason)"
        }
    }
}

public enum GitComparisonMode: String, Codable, Equatable, Sendable {
    case worktree, branch
}

public struct GitDiffContextRequest: Codable, Equatable, Sendable {
    public let mode: GitComparisonMode
    public let baseRef: String?
    public let byteBudget: Int
    public let includePatch: Bool
    public let continuation: String?

    public init(
        mode: GitComparisonMode? = nil,
        baseRef: String? = nil,
        byteBudget: Int = 65_536,
        includePatch: Bool = true,
        continuation: String? = nil
    ) {
        self.mode = mode ?? (baseRef == nil ? .worktree : .branch)
        self.baseRef = baseRef
        self.byteBudget = min(max(1, byteBudget), 1_048_576)
        self.includePatch = includePatch
        self.continuation = continuation
    }
}

public enum GitDiffLayer: String, Codable, CaseIterable, Equatable, Sendable {
    case baseToHead = "base_to_head"
    case staged
    case unstaged
    case untracked
}

public enum GitDiffChangeKind: String, Codable, Equatable, Sendable {
    case added, modified, deleted, renamed, copied
    case typeChanged = "type_changed"
    case unmerged
}

public enum GitObjectIDSource: String, Codable, Equatable, Sendable {
    case tree, index, worktreeRaw = "worktree_raw", untrackedRaw = "untracked_raw", gitlink, none
}

public struct GitUnmergedStageEntry: Codable, Equatable, Sendable {
    public let mode: String
    public let objectID: String
    public let path: String
    public let stage: Int
}

public struct GitDiffChange: Codable, Equatable, Sendable {
    public let layer: GitDiffLayer
    public let kind: GitDiffChangeKind
    public let path: String
    public let previousPath: String?
    public let objectFormat: String
    public let oldObjectID: String?
    public let newObjectID: String?
    public let oldObjectIDSource: GitObjectIDSource
    public let newObjectIDSource: GitObjectIDSource
    public let contentSHA256: String?
    public let isBinary: Bool
    public let modeBefore: String?
    public let modeAfter: String?
    public let similarityPercent: Int?
    public let stageEntries: [GitUnmergedStageEntry]?
}

public struct GitDiffPatch: Codable, Equatable, Sendable {
    public let layer: GitDiffLayer
    public let path: String?
    public let offset: Int
    public let totalBytes: Int
    public let encoding: String
    public let text: String?
    public let base64: String?
}

public struct GitWorkspaceBindingEntry: Codable, Equatable, Sendable {
    public let hashState: String
    public let identity: String
    public let kind: String
    public let modifiedAtNanoseconds: String?
    public let path: String
    public let sha256: String?
    public let sizeBytes: Int64

    public init(hashState: String, identity: String, kind: String, modifiedAtNanoseconds: String?, path: String, sha256: String?, sizeBytes: Int64) {
        self.hashState = hashState
        self.identity = identity
        self.kind = kind
        self.modifiedAtNanoseconds = modifiedAtNanoseconds
        self.path = path
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }
}

public struct GitWorkspaceComparisonBinding: Codable, Equatable, Sendable {
    public let entries: [GitWorkspaceBindingEntry]
    public let eventHighWater: String?
    public let generation: String
    public let rootIdentity: String
    public let schema: String
    public let workspaceCursor: String

    public init(entries: [GitWorkspaceBindingEntry], eventHighWater: String?, generation: String, rootIdentity: String, workspaceCursor: String) {
        self.entries = entries.sorted { Data($0.path.utf8).lexicographicallyPrecedes(Data($1.path.utf8)) }
        self.eventHighWater = eventHighWater
        self.generation = generation
        self.rootIdentity = rootIdentity
        self.schema = "aishell.git-workspace-binding.v1"
        self.workspaceCursor = workspaceCursor
    }

    /// continuationの同一性はworkspace内容で判定する。
    /// cursorとgenerationはsnapshot取得ごとに進む観測位置であり、内容が同じpage間のbindingには含めない。
    fileprivate func hasSameContent(as other: Self) -> Bool {
        schema == other.schema
            && rootIdentity == other.rootIdentity
            && entries == other.entries
    }
}

public struct GitEvidenceContentDigest: Codable, Equatable, Sendable {
    public let kind: String
    public let path: String
    public let sha256: String
}

public struct GitDiffArtifactDescriptor: Codable, Equatable, Sendable {
    public let handle: String
    public let sha256: String
    public let sizeBytes: Int
    public let expiresAt: Date
}

public struct GitDiffContextResult: Codable, Equatable, Sendable {
    public let schema: String
    public let comparisonMode: GitComparisonMode
    public let repositoryRoot: String
    public let repositoryIdentity: String
    public let objectFormat: String
    public let headSHA: String?
    public let headBranch: String?
    public let baseRef: String?
    public let baseSHA: String?
    public let indexTreeSHA: String?
    public let indexState: String
    public let dirtyState: String
    public let workspaceCursor: String
    public let gitStateDigest: String
    public let layerCounts: [String: Int]
    public let changes: [GitDiffChange]
    public let patches: [GitDiffPatch]
    public let byteBudget: Int
    public let returnedBytes: Int
    public let omittedBytes: Int
    public let hasMore: Bool
    public let continuation: String?
    public let artifact: GitDiffArtifactDescriptor
    public let worktreeEvidenceDigest: String
}

enum GitRawContentHookPhase: Sendable {
    case beforeRootOpen
    case rootOpenCompleted
    case rootAnchored
    case workersCompleted
    case parentOpened
    case contentRead
}

public actor GitContextProvider {
    fileprivate struct CommandResult: Sendable {
        let arguments: [String]
        let stdout: Data
        let stderr: Data
    }

    fileprivate struct Inventory: Equatable, Sendable {
        let headSHA: String?
        let indexTreeSHA: String?
        let indexState: String
        let raw: [GitDiffLayer: Data]
        let untrackedPaths: [String]
        let stages: [GitUnmergedStageEntry]
        let digest: String
    }

    fileprivate struct PageItem: Sendable {
        enum Value: Sendable { case change(GitDiffChange), patch(GitDiffPatch) }
        let bytes: Data
        let value: Value
    }

    private struct RetainedSnapshot: Sendable {
        let expiresAt: Date
        let requestDigest: String
        let repositoryIdentity: String
        let baseSHA: String?
        let scope: String?
        let inventory: Inventory
        let binding: GitWorkspaceComparisonBinding
        let evidenceDigest: String
        let items: [PageItem]
        let template: GitDiffContextResult
    }

    private let resolver: PathResolver
    private let evidenceStore: EvidenceStore
    private let gitURL: URL
    private let retentionSeconds: TimeInterval
    private let inheritedEnvironment: [String: String]
    private let rawContentOpenHookForTests: (@Sendable (URL, GitRawContentHookPhase) throws -> Void)?
    private let tokenKey: SymmetricKey
    private var retained: [String: RetainedSnapshot] = [:]
    private var anchoredDirectoryDescriptors: [String: Int32] = [:]

    public init(
        resolver: PathResolver,
        evidenceStore: EvidenceStore,
        gitURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        retentionSeconds: TimeInterval = EvidenceStore.defaultRetentionSeconds,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.resolver = resolver
        self.evidenceStore = evidenceStore
        self.gitURL = gitURL
        self.retentionSeconds = max(1, retentionSeconds)
        self.inheritedEnvironment = environment
        self.rawContentOpenHookForTests = nil
        self.tokenKey = SymmetricKey(size: .bits256)
    }

    init(
        resolver: PathResolver,
        evidenceStore: EvidenceStore,
        gitURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        retentionSeconds: TimeInterval = EvidenceStore.defaultRetentionSeconds,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        rawContentOpenHookForTests: @escaping @Sendable (URL, GitRawContentHookPhase) throws -> Void
    ) {
        self.resolver = resolver
        self.evidenceStore = evidenceStore
        self.gitURL = gitURL
        self.retentionSeconds = max(1, retentionSeconds)
        self.inheritedEnvironment = environment
        self.rawContentOpenHookForTests = rawContentOpenHookForTests
        self.tokenKey = SymmetricKey(size: .bits256)
    }

    public func context(
        path: String? = nil,
        request: GitDiffContextRequest = GitDiffContextRequest(),
        comparisonBinding: GitWorkspaceComparisonBinding,
        comparisonBindingVerifier: (@Sendable () async throws -> GitWorkspaceComparisonBinding)? = nil
    ) async throws -> GitDiffContextResult {
        if let token = request.continuation {
            guard request.baseRef == nil, request.includePatch else {
                throw GitContextError.invalidContinuation
            }
            return try await continueContext(token: token, budget: request.byteBudget, currentBinding: comparisonBinding)
        }
        if request.mode == .branch, request.baseRef == nil {
            throw GitContextError.invalidComparisonMode("branch mode requires base_ref")
        }
        let directory = try resolver.resolveExisting(path)
        let repositoryRoot = try repositoryRoot(from: directory)
        let repositoryIdentity = try fileIdentity(repositoryRoot)
        let scope = try literalScope(directory: directory, repositoryRoot: repositoryRoot)
        try rawContentOpenHookForTests?(repositoryRoot, .beforeRootOpen)
        let repositoryDescriptor: Int32
        do {
            repositoryDescriptor = try openDirectoryWithoutFollowing(repositoryRoot)
        } catch {
            try rawContentOpenHookForTests?(repositoryRoot, .rootOpenCompleted)
            throw error
        }
        try rawContentOpenHookForTests?(repositoryRoot, .rootOpenCompleted)
        defer { close(repositoryDescriptor) }
        guard try fileIdentity(repositoryDescriptor) == repositoryIdentity else { throw GitContextError.contentChanged }
        anchoredDirectoryDescriptors[repositoryRoot.path] = repositoryDescriptor
        defer { anchoredDirectoryDescriptors[repositoryRoot.path] = nil }
        try rawContentOpenHookForTests?(repositoryRoot, .rootAnchored)
        let objectFormat = try text(try run(["rev-parse", "--show-object-format"], cwd: repositoryRoot).stdout)
        let headSHA = try optionalCommit("HEAD", cwd: repositoryRoot)
        let headBranch = try optionalBranch(cwd: repositoryRoot)
        if headSHA == nil, request.baseRef != nil { throw GitContextError.unbornHeadWithExplicitBase }
        let baseSHA: String?
        if let baseRef = request.baseRef {
            baseSHA = try resolveCommit(baseRef, cwd: repositoryRoot)
        } else {
            baseSHA = headSHA
        }
        let pre = try inventory(root: repositoryRoot, head: headSHA, base: baseSHA, scope: scope)
        let collected = try collect(
            root: repositoryRoot, objectFormat: objectFormat, head: headSHA, base: baseSHA,
            repositoryIdentity: repositoryIdentity, repositoryDescriptor: repositoryDescriptor,
            scope: scope, inventory: pre, includePatch: request.includePatch
        )
        let post = try inventory(root: repositoryRoot, head: headSHA, base: baseSHA, scope: scope)
        guard pre == post else { throw GitContextError.contentChanged }
        try rawContentOpenHookForTests?(repositoryRoot, .workersCompleted)
        let postBinding = try await comparisonBindingVerifier?() ?? comparisonBinding
        guard comparisonBinding == postBinding else { throw GitContextError.contentChanged }

        let bindingData = try canonicalData(postBinding)
        let evidenceDigests = collected.evidenceDigests.sorted(by: bytePathOrder)
        let artifactData = try frameArtifact(records: collected.records, binding: postBinding, evidenceDigests: evidenceDigests, stages: collected.stages)
        let metadata: ArtifactMetadata
        do {
            metadata = try await evidenceStore.store(data: artifactData, kind: "git-diff-evidence.v1", producer: "GitContextProvider", retentionSeconds: retentionSeconds)
        } catch {
            throw GitContextError.artifactPublicationFailed(error.localizedDescription)
        }
        let evidenceArrayData = try canonicalData(evidenceDigests)
        let stagesData = try canonicalData(collected.stages)
        let evidenceDigest = try sha256(canonicalObjectData([
            "artifactSHA256": metadata.sha256,
            "bindingDigest": sha256(bindingData),
            "evidenceContentDigest": sha256(evidenceArrayData),
            "schema": "aishell.git-worktree-evidence.v1",
            "unmergedStagesDigest": sha256(stagesData)
        ]))
        let items = try pageItems(changes: collected.changes, patches: collected.patches)
        let descriptor = GitDiffArtifactDescriptor(handle: metadata.handle, sha256: metadata.sha256, sizeBytes: metadata.sizeBytes, expiresAt: metadata.expiresAt)
        let stateDigest = sha256(Data("\(pre.digest)\u{0}\(sha256(bindingData))".utf8))
        let template = GitDiffContextResult(
            schema: "aishell.git-diff-context.v1", comparisonMode: request.mode,
            repositoryRoot: repositoryRoot.path,
            repositoryIdentity: repositoryIdentity, objectFormat: objectFormat,
            headSHA: headSHA, headBranch: headBranch, baseRef: request.baseRef, baseSHA: baseSHA,
            indexTreeSHA: pre.indexTreeSHA, indexState: pre.indexState,
            dirtyState: isDirty(pre) ? "dirty" : "clean",
            workspaceCursor: postBinding.workspaceCursor, gitStateDigest: stateDigest,
            layerCounts: Dictionary(grouping: collected.changes, by: { $0.layer.rawValue }).mapValues(\.count),
            changes: [], patches: [], byteBudget: request.byteBudget,
            returnedBytes: 0, omittedBytes: 0, hasMore: !items.isEmpty,
            continuation: nil, artifact: descriptor, worktreeEvidenceDigest: evidenceDigest
        )
        let snapshotID = UUID().uuidString.lowercased()
        retained[snapshotID] = RetainedSnapshot(
            expiresAt: metadata.expiresAt, requestDigest: try requestDigest(request, scope: scope),
            repositoryIdentity: repositoryIdentity, baseSHA: baseSHA, scope: scope, inventory: post,
            binding: postBinding, evidenceDigest: evidenceDigest, items: items, template: template
        )
        return page(snapshotID: snapshotID, offset: 0, budget: request.byteBudget)
    }

    public func context(
        path: String? = nil,
        request: GitDiffContextRequest = GitDiffContextRequest(),
        comparisonBindingProvider: @escaping @Sendable () async throws -> GitWorkspaceComparisonBinding
    ) async throws -> GitDiffContextResult {
        let preBinding = try await comparisonBindingProvider()
        return try await context(
            path: path,
            request: request,
            comparisonBinding: preBinding,
            comparisonBindingVerifier: comparisonBindingProvider
        )
    }

    private func continueContext(token: String, budget: Int, currentBinding: GitWorkspaceComparisonBinding) async throws -> GitDiffContextResult {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "gitctx1", let offset = Int(parts[2]), offset >= 0 else {
            throw GitContextError.invalidContinuation
        }
        let unsigned = parts.prefix(3).joined(separator: ".")
        let expected = hmac(Data(unsigned.utf8))
        guard constantTimeEqual(expected, String(parts[3])) else { throw GitContextError.invalidContinuation }
        let id = String(parts[1])
        guard let snapshot = retained[id] else { throw GitContextError.cursorExpired }
        guard Date() <= snapshot.expiresAt else { retained[id] = nil; throw GitContextError.cursorExpired }
        guard snapshot.binding.hasSameContent(as: currentBinding) else {
            throw GitContextError.contentChanged
        }
        let root = URL(fileURLWithPath: snapshot.template.repositoryRoot, isDirectory: true)
        let rootDescriptor = try openDirectoryWithoutFollowing(root)
        defer { close(rootDescriptor) }
        guard try fileIdentity(rootDescriptor) == snapshot.repositoryIdentity else {
            throw GitContextError.contentChanged
        }
        anchoredDirectoryDescriptors[root.path] = rootDescriptor
        defer { anchoredDirectoryDescriptors[root.path] = nil }
        let current = try inventory(root: root, head: snapshot.inventory.headSHA, base: snapshot.baseSHA, scope: snapshot.scope)
        guard current == snapshot.inventory else { throw GitContextError.contentChanged }
        return page(snapshotID: id, offset: offset, budget: min(max(1, budget), 1_048_576))
    }

    private func page(snapshotID: String, offset: Int, budget: Int) -> GitDiffContextResult {
        guard let snapshot = retained[snapshotID] else { preconditionFailure("retained snapshot missing") }
        var changes: [GitDiffChange] = []
        var patches: [GitDiffPatch] = []
        var used = 0
        var next = offset
        while next < snapshot.items.count, used + snapshot.items[next].bytes.count <= budget {
            let item = snapshot.items[next]
            used += item.bytes.count
            switch item.value { case let .change(value): changes.append(value); case let .patch(value): patches.append(value) }
            next += 1
        }
        let omitted = snapshot.items.dropFirst(next).reduce(0) { $0 + $1.bytes.count }
        let continuation = next < snapshot.items.count ? token(snapshotID: snapshotID, offset: next) : nil
        let t = snapshot.template
        return GitDiffContextResult(
            schema: t.schema, comparisonMode: t.comparisonMode,
            repositoryRoot: t.repositoryRoot, repositoryIdentity: t.repositoryIdentity,
            objectFormat: t.objectFormat, headSHA: t.headSHA, headBranch: t.headBranch,
            baseRef: t.baseRef, baseSHA: t.baseSHA,
            indexTreeSHA: t.indexTreeSHA, indexState: t.indexState, dirtyState: t.dirtyState,
            workspaceCursor: t.workspaceCursor,
            gitStateDigest: t.gitStateDigest, layerCounts: t.layerCounts, changes: changes, patches: patches,
            byteBudget: budget, returnedBytes: used, omittedBytes: omitted,
            hasMore: continuation != nil, continuation: continuation,
            artifact: t.artifact, worktreeEvidenceDigest: t.worktreeEvidenceDigest
        )
    }
}

private extension GitContextProvider {
    struct ArtifactRecord: Sendable {
        let kind: UInt8
        let argumentsDigest: String?
        let layer: String?
        let path: String?
        let recordKind: String
        let stream: String
        let body: Data
    }

    struct Collection: Sendable {
        let changes: [GitDiffChange]
        let patches: [GitDiffPatch]
        let records: [ArtifactRecord]
        let evidenceDigests: [GitEvidenceContentDigest]
        let stages: [GitUnmergedStageEntry]
    }

    func repositoryRoot(from directory: URL) throws -> URL {
        do {
            let result = try run(["rev-parse", "--show-toplevel"], cwd: directory)
            let discovered = URL(fileURLWithPath: try text(result.stdout), isDirectory: true).standardizedFileURL
            return try canonicalExistingURL(discovered)
        } catch let GitContextError.gitFailed(_, _, stderr)
            where stderr.lowercased().contains("not a git repository") {
            throw GitContextError.notGitRepository
        }
    }

    func literalScope(directory: URL, repositoryRoot: URL) throws -> String? {
        let canonicalDirectory = try canonicalExistingURL(directory)
        guard canonicalDirectory != repositoryRoot else { return nil }
        guard contains(canonicalDirectory, in: repositoryRoot) else {
            throw GitContextError.repositoryOutsideAllowedRoot(repositoryRoot.path)
        }
        let relative = String(canonicalDirectory.path.dropFirst(repositoryRoot.path.count + 1))
        guard String(data: Data(relative.utf8), encoding: .utf8) != nil else { throw GitContextError.pathEncodingUnsupported }
        return relative
    }

    func canonicalExistingURL(_ url: URL) throws -> URL {
        guard let pointer = realpath(url.path, nil) else { throw AIShellError.invalidPath(url.path) }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    }

    func contains(_ target: URL, in root: URL) -> Bool {
        let lhs = target.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let rhs = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return lhs.count >= rhs.count && Array(lhs.prefix(rhs.count)) == rhs
    }

    func optionalCommit(_ ref: String, cwd: URL) throws -> String? {
        do { return try resolveCommit(ref, cwd: cwd) }
        catch let error as GitContextError {
            if case let .unresolvedBase(missing) = error, missing == ref { return nil }
            throw error
        }
    }

    func optionalBranch(cwd: URL) throws -> String? {
        do {
            return try text(run(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: cwd).stdout)
        } catch let GitContextError.gitFailed(exitCode, _, _) where exitCode == 1 {
            return nil
        }
    }

    func isDirty(_ inventory: Inventory) -> Bool {
        inventory.indexState != "clean"
            || !(inventory.raw[.staged] ?? Data()).isEmpty
            || !(inventory.raw[.unstaged] ?? Data()).isEmpty
            || !inventory.untrackedPaths.isEmpty
    }

    func resolveCommit(_ ref: String, cwd: URL) throws -> String {
        do {
            return try text(try run(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(ref)^{commit}"], cwd: cwd).stdout)
        } catch let GitContextError.gitFailed(exitCode, _, stderr) where exitCode == 1 && stderr.isEmpty {
            throw GitContextError.unresolvedBase(ref)
        }
    }

    func inventory(root: URL, head: String?, base: String?, scope: String?) throws -> Inventory {
        var raw: [GitDiffLayer: Data] = [:]
        raw[.baseToHead] = try rawLayer(.baseToHead, root: root, head: head, base: base, scope: scope).stdout
        raw[.staged] = try rawLayer(.staged, root: root, head: head, base: base, scope: scope).stdout
        raw[.unstaged] = try rawLayer(.unstaged, root: root, head: head, base: base, scope: scope).stdout
        let untracked = try untrackedPaths(root: root, scope: scope)
        let stages = try unmergedStages(root: root, scope: scope)
        let indexState = stages.isEmpty ? "clean" : "unmerged"
        let indexTree: String?
        if stages.isEmpty {
            indexTree = try text(run(["write-tree"], cwd: root).stdout)
        } else { indexTree = nil }
        let currentHead = try optionalCommit("HEAD", cwd: root)
        var layers: [[String: Any]] = []
        for layer in [GitDiffLayer.baseToHead, .staged, .unstaged] {
            layers.append(["layer": layer.rawValue, "rawSHA256": sha256(raw[layer] ?? Data())])
        }
        let pathBytes = untracked.reduce(into: Data()) { data, path in data.append(Data(path.utf8)); data.append(0) }
        let stagesDigest = sha256(try canonicalData(stages))
        let digest = try sha256(canonicalAny([
            "layers": layers, "schema": "aishell.git-raw-inventory.v1",
            "unmergedStagesSHA256": stagesDigest, "untrackedPathsSHA256": sha256(pathBytes)
        ]))
        return Inventory(
            headSHA: currentHead, indexTreeSHA: indexTree, indexState: indexState,
            raw: raw, untrackedPaths: untracked, stages: stages, digest: digest
        )
    }

    func rawLayer(_ layer: GitDiffLayer, root: URL, head: String?, base: String?, scope: String?) throws -> CommandResult {
        let common = ["diff", "--raw", "-z", "--full-index", "--no-ext-diff", "--no-textconv", "--submodule=short", "--find-renames=50%", "--find-copies=50%", "--find-copies-harder"]
        var arguments = common
        switch layer {
        case .baseToHead:
            guard let head, let base else { return CommandResult(arguments: arguments, stdout: Data(), stderr: Data()) }
            arguments += [base, head]
        case .staged:
            arguments.insert("--cached", at: 1)
            arguments.append(try head ?? emptyTreeSHA(root: root))
        case .unstaged: break
        case .untracked: return CommandResult(arguments: arguments, stdout: Data(), stderr: Data())
        }
        arguments += ["--"]
        arguments.append(scope ?? ".")
        arguments.append(ReservedNamespacePolicy.gitExclusionPathspec)
        return try run(arguments, cwd: root)
    }

    func patchLayer(_ layer: GitDiffLayer, root: URL, head: String?, base: String?, scope: String?) throws -> CommandResult {
        var arguments = ["diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", "--submodule=short", "--find-renames=50%", "--find-copies=50%", "--find-copies-harder"]
        switch layer {
        case .baseToHead:
            guard let head, let base else { return CommandResult(arguments: arguments, stdout: Data(), stderr: Data()) }
            arguments += [base, head]
        case .staged:
            arguments.insert("--cached", at: 1)
            arguments.append(try head ?? emptyTreeSHA(root: root))
        case .unstaged: break
        case .untracked: return CommandResult(arguments: arguments, stdout: Data(), stderr: Data())
        }
        arguments += ["--"]
        arguments.append(scope ?? ".")
        arguments.append(ReservedNamespacePolicy.gitExclusionPathspec)
        return try run(arguments, cwd: root)
    }

    func collect(
        root: URL, objectFormat: String, head: String?, base: String?, repositoryIdentity: String,
        repositoryDescriptor: Int32, scope: String?,
        inventory: Inventory, includePatch: Bool
    ) throws -> Collection {
        let stages = try unmergedStages(root: root, scope: scope)
        let stagesByPath = Dictionary(grouping: stages, by: \.path)
        var changes: [GitDiffChange] = []
        var patches: [GitDiffPatch] = []
        var records: [ArtifactRecord] = []
        var digests: [GitEvidenceContentDigest] = []

        for layer in [GitDiffLayer.baseToHead, .staged, .unstaged] {
            let rawCommand = try rawLayer(layer, root: root, head: head, base: base, scope: scope)
            let patchCommand = includePatch ? try patchLayer(layer, root: root, head: head, base: base, scope: scope) : CommandResult(arguments: [], stdout: Data(), stderr: Data())
            records.append(try record(kind: 1, command: rawCommand, layer: layer, recordKind: "raw_stdout", stream: "stdout", body: rawCommand.stdout))
            records.append(ArtifactRecord(kind: 2, argumentsDigest: includePatch ? try argumentsDigest(patchCommand.arguments) : nil, layer: layer.rawValue, path: nil, recordKind: "patch_stdout", stream: "stdout", body: patchCommand.stdout))
            records.append(try record(kind: 3, command: rawCommand, layer: layer, recordKind: "worker_stderr", stream: "stderr", body: rawCommand.stderr + patchCommand.stderr))
            changes += try parseRaw(
                rawCommand.stdout, layer: layer, objectFormat: objectFormat, root: root,
                repositoryIdentity: repositoryIdentity, repositoryDescriptor: repositoryDescriptor,
                stagesByPath: stagesByPath, digests: &digests
            )
            if includePatch, !patchCommand.stdout.isEmpty {
                patches += patchChunks(patchCommand.stdout, layer: layer, path: nil)
            }
        }
        let untrackedCommand = try untrackedCommand(root: root, scope: scope)
        var untrackedPreview = Data()
        for path in inventory.untrackedPaths {
            let content = try rawContent(
                relativePath: path, repositoryRoot: root, expectedRootIdentity: repositoryIdentity,
                repositoryDescriptor: repositoryDescriptor
            )
            let digest = sha256(content.bytes)
            let oid = try hashObject(content.bytes, root: root)
            digests.append(GitEvidenceContentDigest(kind: content.kind, path: path, sha256: digest))
            changes.append(GitDiffChange(
                layer: .untracked, kind: .added, path: path, previousPath: nil, objectFormat: objectFormat,
                oldObjectID: nil, newObjectID: oid, oldObjectIDSource: .none, newObjectIDSource: .untrackedRaw,
                contentSHA256: digest, isBinary: content.bytes.contains(0), modeBefore: nil,
                modeAfter: content.mode, similarityPercent: nil, stageEntries: nil
            ))
            let body = try canonicalAny(["path": path, "sha256": digest])
            records.append(ArtifactRecord(kind: 4, argumentsDigest: nil, layer: "untracked", path: path, recordKind: "untracked_content_digest", stream: "none", body: body))
            if content.kind == "symlink" {
                records.append(ArtifactRecord(kind: 5, argumentsDigest: nil, layer: nil, path: path, recordKind: "symlink_target_digest", stream: "none", body: body))
            }
            if includePatch {
                untrackedPreview.append(Data("untracked \(path)\n".utf8))
                untrackedPreview.append(content.bytes)
                if content.bytes.last != 0x0A { untrackedPreview.append(0x0A) }
            }
        }
        records.append(try record(kind: 1, command: untrackedCommand, layer: .untracked, recordKind: "raw_stdout", stream: "stdout", body: untrackedCommand.stdout))
        records.append(ArtifactRecord(kind: 2, argumentsDigest: nil, layer: GitDiffLayer.untracked.rawValue, path: nil, recordKind: "patch_stdout", stream: "stdout", body: untrackedPreview))
        records.append(try record(kind: 3, command: untrackedCommand, layer: .untracked, recordKind: "worker_stderr", stream: "stderr", body: untrackedCommand.stderr))
        if includePatch, !untrackedPreview.isEmpty { patches += patchChunks(untrackedPreview, layer: .untracked, path: nil) }
        changes.sort(by: changeOrder)
        digests = Dictionary(grouping: digests, by: \.path).compactMap { $0.value.first }.sorted(by: bytePathOrder)
        return Collection(changes: changes, patches: patches, records: records, evidenceDigests: digests, stages: stages)
    }

    func parseRaw(
        _ data: Data, layer: GitDiffLayer, objectFormat: String, root: URL, repositoryIdentity: String,
        repositoryDescriptor: Int32,
        stagesByPath: [String: [GitUnmergedStageEntry]], digests: inout [GitEvidenceContentDigest]
    ) throws -> [GitDiffChange] {
        guard !data.isEmpty else { return [] }
        let fields = data.split(separator: 0, omittingEmptySubsequences: true)
        var index = 0
        var result: [GitDiffChange] = []
        while index < fields.count {
            guard let headerText = String(data: fields[index], encoding: .utf8), headerText.first == ":" else {
                throw GitContextError.pathEncodingUnsupported
            }
            let header: [Substring]
            let firstPath: String
            if let tab = headerText.firstIndex(of: "\t") {
                header = headerText[..<tab].dropFirst().split(separator: " ")
                firstPath = String(headerText[headerText.index(after: tab)...])
            } else {
                header = headerText.dropFirst().split(separator: " ")
                index += 1
                guard index < fields.count, let path = String(data: fields[index], encoding: .utf8) else {
                    throw GitContextError.pathEncodingUnsupported
                }
                firstPath = path
            }
            guard header.count >= 5 else { throw GitContextError.gitFailed(exitCode: -1, arguments: ["diff", "--raw"], stderr: "invalid raw record") }
            let status = String(header[4])
            let letter = status.first ?? "M"
            var previousPath: String?
            var path = firstPath
            if letter == "R" || letter == "C" {
                index += 1
                guard index < fields.count, let second = String(data: fields[index], encoding: .utf8) else { throw GitContextError.pathEncodingUnsupported }
                previousPath = firstPath
                path = second
            }
            let modeBefore = String(header[0]) == "000000" ? nil : String(header[0])
            let modeAfter = String(header[1]) == "000000" ? nil : String(header[1])
            var oldOID = zeroToNil(String(header[2]))
            var newOID = zeroToNil(String(header[3]))
            let kind: GitDiffChangeKind
            switch letter {
            case "A": kind = .added
            case "D": kind = .deleted
            case "R": kind = .renamed
            case "C": kind = .copied
            case "T": kind = .typeChanged
            case "U": kind = .unmerged
            default: kind = .modified
            }
            var oldSource = source(layer: layer, endpoint: .old, mode: modeBefore, oid: oldOID)
            var newSource = source(layer: layer, endpoint: .new, mode: modeAfter, oid: newOID)
            var contentDigest: String?
            var binary = false
            if layer == .unstaged, kind != .deleted, kind != .unmerged, modeAfter != "160000" {
                let content = try rawContent(
                    relativePath: path, repositoryRoot: root, expectedRootIdentity: repositoryIdentity,
                    repositoryDescriptor: repositoryDescriptor
                )
                newOID = try hashObject(content.bytes, root: root)
                newSource = modeAfter == "160000" ? .gitlink : .worktreeRaw
                contentDigest = sha256(content.bytes)
                binary = content.bytes.contains(0)
                digests.append(GitEvidenceContentDigest(kind: content.kind, path: path, sha256: contentDigest!))
            } else if kind != .unmerged, modeAfter != "160000" {
                let inspectOID = newOID ?? oldOID
                if let inspectOID {
                    let blob = try run(["cat-file", "blob", inspectOID], cwd: root).stdout
                    binary = blob.contains(0)
                }
            }
            if kind == .unmerged { oldOID = nil; newOID = nil; oldSource = .none; newSource = .none }
            result.append(GitDiffChange(
                layer: layer, kind: kind, path: path, previousPath: previousPath, objectFormat: objectFormat,
                oldObjectID: oldOID, newObjectID: newOID, oldObjectIDSource: oldSource, newObjectIDSource: newSource,
                contentSHA256: contentDigest, isBinary: binary, modeBefore: modeBefore, modeAfter: modeAfter,
                similarityPercent: (letter == "R" || letter == "C") ? Int(status.dropFirst()) : nil,
                stageEntries: kind == .unmerged ? stagesByPath[path] : nil
            ))
            index += 1
        }
        return result
    }

    enum Endpoint { case old, new }

    func source(layer: GitDiffLayer, endpoint: Endpoint, mode: String?, oid: String?) -> GitObjectIDSource {
        guard oid != nil else { return .none }
        if mode == "160000" { return .gitlink }
        switch (layer, endpoint) {
        case (.baseToHead, _): return .tree
        case (.staged, .old): return .tree
        case (.staged, .new): return .index
        case (.unstaged, .old): return .index
        case (.unstaged, .new): return .worktreeRaw
        case (.untracked, .new): return .untrackedRaw
        default: return .none
        }
    }

    func untrackedPaths(root: URL, scope: String?) throws -> [String] {
        let data = try untrackedCommand(root: root, scope: scope).stdout
        return try data.split(separator: 0).compactMap {
            guard let path = String(data: $0, encoding: .utf8) else { throw GitContextError.pathEncodingUnsupported }
            return ReservedNamespacePolicy.contains(relativePath: path) ? nil : path
        }.sorted(by: utf8Order)
    }

    func untrackedCommand(root: URL, scope: String?) throws -> CommandResult {
        var args = ["ls-files", "--others", "--exclude-standard", "-z"]
        args += ["--"]
        args.append(scope ?? ".")
        args.append(ReservedNamespacePolicy.gitExclusionPathspec)
        return try run(args, cwd: root)
    }

    func unmergedStages(root: URL, scope: String?) throws -> [GitUnmergedStageEntry] {
        var args = ["ls-files", "--unmerged", "-z"]
        args += ["--"]
        args.append(scope ?? ".")
        args.append(ReservedNamespacePolicy.gitExclusionPathspec)
        return try run(args, cwd: root).stdout.split(separator: 0).compactMap { field in
            guard let value = String(data: field, encoding: .utf8), let tab = value.firstIndex(of: "\t") else { throw GitContextError.pathEncodingUnsupported }
            let metadata = value[..<tab].split(separator: " ")
            guard metadata.count == 3, let stage = Int(metadata[2]) else { throw GitContextError.gitFailed(exitCode: -1, arguments: args, stderr: "invalid unmerged record") }
            let path = String(value[value.index(after: tab)...])
            guard !ReservedNamespacePolicy.contains(relativePath: path) else { return nil }
            return GitUnmergedStageEntry(mode: String(metadata[0]), objectID: String(metadata[1]), path: path, stage: stage)
        }.sorted { $0.path == $1.path ? $0.stage < $1.stage : utf8Order($0.path, $1.path) }
    }

    func rawContent(
        relativePath: String,
        repositoryRoot: URL,
        expectedRootIdentity: String,
        repositoryDescriptor: Int32
    ) throws -> (bytes: Data, kind: String, mode: String) {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AIShellError.invalidPath(relativePath)
        }
        guard !ReservedNamespacePolicy.contains(relativePath: relativePath) else {
            throw AIShellError.reservedPath(relativePath)
        }
        var descriptors: [Int32] = []
        defer { for descriptor in descriptors.reversed() { close(descriptor) } }
        let rootDescriptor = fcntl(repositoryDescriptor, F_DUPFD_CLOEXEC, 0)
        guard rootDescriptor >= 0 else { throw AIShellError.invalidPath(repositoryRoot.path) }
        descriptors.append(rootDescriptor)
        guard try fileIdentity(rootDescriptor) == expectedRootIdentity else {
            throw GitContextError.contentChanged
        }
        var parentDescriptor = rootDescriptor
        for component in components.dropLast() {
            let descriptor = component.withCString {
                openat(parentDescriptor, $0, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { throw AIShellError.invalidPath(relativePath) }
            descriptors.append(descriptor)
            parentDescriptor = descriptor
        }
        let targetURL = repositoryRoot.appendingPathComponent(relativePath)
        try rawContentOpenHookForTests?(targetURL, .parentOpened)
        let name = components.last!
        var entryInfo = stat()
        let statResult = name.withCString { fstatat(parentDescriptor, $0, &entryInfo, AT_SYMLINK_NOFOLLOW) }
        guard statResult == 0 else { throw AIShellError.itemNotFound(relativePath) }
        if (entryInfo.st_mode & S_IFMT) == S_IFLNK {
            var capacity = max(256, Int(entryInfo.st_size) + 1)
            while true {
                var bytes = [UInt8](repeating: 0, count: capacity)
                let count = name.withCString { readlinkat(parentDescriptor, $0, &bytes, capacity) }
                guard count >= 0 else { throw AIShellError.invalidPath(relativePath) }
                if count < capacity {
                    try rawContentOpenHookForTests?(targetURL, .contentRead)
                    return (Data(bytes.prefix(count)), "symlink", "120000")
                }
                capacity *= 2
            }
        }
        let fileDescriptor = name.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fileDescriptor >= 0 else { throw AIShellError.invalidPath(relativePath) }
        descriptors.append(fileDescriptor)
        var openedInfo = stat()
        guard fstat(fileDescriptor, &openedInfo) == 0, (openedInfo.st_mode & S_IFMT) == S_IFREG else {
            throw AIShellError.invalidPath(relativePath)
        }
        let bytes = try readAll(from: fileDescriptor, path: relativePath)
        try rawContentOpenHookForTests?(targetURL, .contentRead)
        let executable = (openedInfo.st_mode & S_IXUSR) != 0
        return (bytes, "regular", executable ? "100755" : "100644")
    }

    func openDirectoryWithoutFollowing(_ directory: URL) throws -> Int32 {
        let descriptor = open(directory.path, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw AIShellError.invalidPath("\(directory.path) [errno=\(errno)]")
        }
        return descriptor
    }

    func fileIdentity(_ descriptor: Int32) throws -> String {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw AIShellError.invalidPath("fd:\(descriptor)") }
        return "\(UInt64(info.st_dev)):\(UInt64(info.st_ino))"
    }

    func readAll(from descriptor: Int32, path: String) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw AIShellError.invalidPath(path)
            }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    func hashObject(_ data: Data, root: URL) throws -> String {
        try text(run(["hash-object", "--no-filters", "--stdin"], cwd: root, stdin: data).stdout)
    }

    func emptyTreeSHA(root: URL) throws -> String {
        try text(run(["hash-object", "-t", "tree", "--stdin"], cwd: root, stdin: Data()).stdout)
    }

    func run(_ arguments: [String], cwd: URL, stdin: Data? = nil) throws -> CommandResult {
        let actualArguments = ["--no-optional-locks"] + (try filterOverrides(cwd: cwd)) + arguments
        return try launch(actualArguments, cwd: cwd, stdin: stdin)
    }

    func filterOverrides(cwd: URL) throws -> [String] {
        let configuration: Data
        do {
            configuration = try launch(
                ["config", "--null", "--name-only", "--get-regexp", "^filter\\..*\\.(clean|process|required)$"],
                cwd: cwd
            ).stdout
        } catch let GitContextError.gitFailed(exitCode, _, stderr) where exitCode == 1 && stderr.isEmpty {
            return []
        }
        var drivers = Set<String>()
        for field in configuration.split(separator: 0) {
            guard let key = String(data: field, encoding: .utf8), key.hasPrefix("filter.") else { continue }
            for suffix in [".clean", ".process", ".required"] where key.hasSuffix(suffix) {
                let start = key.index(key.startIndex, offsetBy: "filter.".count)
                let end = key.index(key.endIndex, offsetBy: -suffix.count)
                if start < end { drivers.insert(String(key[start..<end])) }
            }
        }
        return drivers.sorted().flatMap { driver in
            ["-c", "filter.\(driver).clean=", "-c", "filter.\(driver).process=", "-c", "filter.\(driver).required=false"]
        }
    }

    func launch(_ arguments: [String], cwd: URL, stdin: Data? = nil) throws -> CommandResult {
        if let descriptor = anchoredDirectoryDescriptors[cwd.path] {
            return try spawnAnchored(arguments, directoryDescriptor: descriptor, stdin: stdin)
        }
        let process = Process()
        process.executableURL = gitURL
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = workerEnvironment()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let stdin {
            let pipe = Pipe()
            process.standardInput = pipe
            do { try process.run() }
            catch { throw GitContextError.gitFailed(exitCode: -1, arguments: arguments, stderr: error.localizedDescription) }
            pipe.fileHandleForWriting.write(stdin)
            try pipe.fileHandleForWriting.close()
        } else {
            do { try process.run() }
            catch { throw GitContextError.gitFailed(exitCode: -1, arguments: arguments, stderr: error.localizedDescription) }
        }
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let stdout = stdoutHandle.readDataToEndOfFile()
        let stderr = stderrHandle.readDataToEndOfFile()
        do {
            try stdoutHandle.close()
            try stderrHandle.close()
        } catch {
            throw GitContextError.gitFailed(exitCode: -1, arguments: arguments, stderr: error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitContextError.gitFailed(
                exitCode: process.terminationStatus,
                arguments: arguments,
                stderr: String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return CommandResult(arguments: arguments, stdout: stdout, stderr: stderr)
    }

    func spawnAnchored(_ arguments: [String], directoryDescriptor: Int32, stdin: Data?) throws -> CommandResult {
        guard let stdoutFile = tmpfile(), let stderrFile = tmpfile(), let stdinFile = tmpfile() else {
            throw GitContextError.gitFailed(exitCode: -1, arguments: arguments, stderr: "temporary stdio file creation failed")
        }
        defer { fclose(stdoutFile); fclose(stderrFile); fclose(stdinFile) }
        let stdoutDescriptor = fileno(stdoutFile)
        let stderrDescriptor = fileno(stderrFile)
        let stdinDescriptor = fileno(stdinFile)
        if let stdin {
            let writeResult = stdin.withUnsafeBytes { bytes in
                Darwin.write(stdinDescriptor, bytes.baseAddress, bytes.count)
            }
            guard writeResult == stdin.count, lseek(stdinDescriptor, 0, SEEK_SET) == 0 else {
                throw GitContextError.gitFailed(exitCode: -1, arguments: arguments, stderr: "stdin staging failed")
            }
        }
        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw GitContextError.gitFailed(exitCode: -1, arguments: arguments, stderr: "spawn actions init failed")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_addfchdir_np(&actions, directoryDescriptor) == 0,
              posix_spawn_file_actions_adddup2(&actions, stdinDescriptor, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stdoutDescriptor, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stderrDescriptor, STDERR_FILENO) == 0 else {
            throw GitContextError.gitFailed(exitCode: -1, arguments: arguments, stderr: "spawn actions configuration failed")
        }
        let argv = [gitURL.path] + arguments
        let environment = workerEnvironment().map { "\($0.key)=\($0.value)" }.sorted()
        let invocation = try Self.invokeSpawn(
            executable: gitURL.path, arguments: argv, environment: environment, actions: actions
        )
        let processIdentifier = invocation.processIdentifier
        let spawnResult = invocation.result
        guard spawnResult == 0 else {
            throw GitContextError.gitFailed(exitCode: Int32(spawnResult), arguments: arguments, stderr: String(cString: strerror(spawnResult)))
        }
        var status: Int32 = 0
        while waitpid(processIdentifier, &status, 0) < 0 {
            if errno == EINTR { continue }
            throw GitContextError.gitFailed(exitCode: -1, arguments: arguments, stderr: "waitpid failed: \(errno)")
        }
        guard lseek(stdoutDescriptor, 0, SEEK_SET) == 0, lseek(stderrDescriptor, 0, SEEK_SET) == 0 else {
            throw GitContextError.gitFailed(exitCode: -1, arguments: arguments, stderr: "stdio rewind failed")
        }
        let stdout = try readAll(from: stdoutDescriptor, path: "git stdout")
        let stderr = try readAll(from: stderrDescriptor, path: "git stderr")
        let exitCode: Int32
        let terminationBits = status & 0x7F
        if terminationBits == 0 { exitCode = (status >> 8) & 0xFF }
        else if terminationBits != 0x7F { exitCode = 128 + terminationBits }
        else { exitCode = -1 }
        guard exitCode == 0 else {
            throw GitContextError.gitFailed(
                exitCode: exitCode, arguments: arguments,
                stderr: String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return CommandResult(arguments: arguments, stdout: stdout, stderr: stderr)
    }

    func workerEnvironment() -> [String: String] {
        let allowedEnvironmentKeys = ["HOME", "LOGNAME", "PATH", "TMPDIR", "USER"]
        var environment = Dictionary(uniqueKeysWithValues: allowedEnvironmentKeys.compactMap { key in
            inheritedEnvironment[key].map { (key, $0) }
        })
        environment["LC_ALL"] = "C"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_LITERAL_PATHSPECS"] = "1"
        return environment
    }

    nonisolated static func invokeSpawn(
        executable: String,
        arguments: [String],
        environment: [String],
        actions: posix_spawn_file_actions_t?
    ) throws -> (result: Int32, processIdentifier: pid_t) {
        var localActions = actions
        var processIdentifier: pid_t = 0
        let result = try withCStringArray(arguments) { argvPointer in
            try withCStringArray(environment) { environmentPointer in
                posix_spawn(&processIdentifier, executable, &localActions, nil, argvPointer, environmentPointer)
            }
        }
        return (result, processIdentifier)
    }

    nonisolated static func withCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) throws -> Result {
        let allocated = strings.map { strdup($0) }
        defer { for pointer in allocated { free(pointer) } }
        var pointers: [UnsafeMutablePointer<CChar>?] = allocated + [nil]
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw GitContextError.gitFailed(exitCode: -1, arguments: [], stderr: "argv allocation failed")
            }
            return try body(baseAddress)
        }
    }

    func text(_ data: Data) throws -> String {
        guard let result = String(data: data, encoding: .utf8) else { throw GitContextError.pathEncodingUnsupported }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func fileIdentity(_ url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw AIShellError.invalidPath(url.path) }
        return "\(UInt64(info.st_dev)):\(UInt64(info.st_ino))"
    }

    func zeroToNil(_ value: String) -> String? {
        value.allSatisfy { $0 == "0" } ? nil : value
    }

    func record(kind: UInt8, command: CommandResult, layer: GitDiffLayer, recordKind: String, stream: String, body: Data) throws -> ArtifactRecord {
        ArtifactRecord(kind: kind, argumentsDigest: try argumentsDigest(command.arguments), layer: layer.rawValue, path: nil, recordKind: recordKind, stream: stream, body: body)
    }

    func argumentsDigest(_ arguments: [String]) throws -> String {
        try sha256(canonicalAny(["arguments": arguments, "executable": gitURL.path]))
    }

    func frameArtifact(
        records baseRecords: [ArtifactRecord], binding: GitWorkspaceComparisonBinding,
        evidenceDigests: [GitEvidenceContentDigest], stages: [GitUnmergedStageEntry]
    ) throws -> Data {
        let commandRecords = baseRecords.filter { $0.kind <= 3 }
        var digestRecords = baseRecords.filter { $0.kind == 4 || $0.kind == 5 }
        let existingDigestPaths = Set(digestRecords.compactMap(\.path))
        for digest in evidenceDigests where digest.kind == "symlink" && !existingDigestPaths.contains(digest.path) {
            digestRecords.append(ArtifactRecord(
                kind: 5, argumentsDigest: nil, layer: nil,
                path: digest.path, recordKind: "symlink_target_digest",
                stream: "none", body: try canonicalAny(["path": digest.path, "sha256": digest.sha256])
            ))
        }
        digestRecords.sort {
            if $0.path != $1.path { return utf8Order($0.path ?? "", $1.path ?? "") }
            return $0.kind < $1.kind
        }
        var records = commandRecords + digestRecords
        let bindingBody = try canonicalAny([
            "comparisonBinding": try jsonObject(binding),
            "evidenceContentDigests": try jsonObject(evidenceDigests),
            "schema": "aishell.git-workspace-evidence.v1"
        ])
        records.append(ArtifactRecord(kind: 6, argumentsDigest: nil, layer: nil, path: nil, recordKind: "workspace_binding", stream: "none", body: bindingBody))
        records.append(ArtifactRecord(kind: 7, argumentsDigest: nil, layer: nil, path: nil, recordKind: "unmerged_stages", stream: "none", body: try canonicalData(stages)))
        var result = Data("AISHELL-GIT-DIFF".utf8)
        result.append(0)
        result.append(1)
        for record in records {
            let header = try canonicalAny([
                "argumentsDigest": record.argumentsDigest as Any,
                "layer": record.layer as Any,
                "path": record.path as Any,
                "recordKind": record.recordKind,
                "stream": record.stream
            ])
            result.append(record.kind)
            appendUInt32(UInt32(header.count), to: &result)
            result.append(header)
            appendUInt64(UInt64(record.body.count), to: &result)
            result.append(record.body)
        }
        return result
    }

    func pageItems(changes: [GitDiffChange], patches: [GitDiffPatch]) throws -> [PageItem] {
        var result: [PageItem] = []
        for change in changes {
            let item = try canonicalAny(["change": try jsonObject(change)]) + Data([0x0A])
            result.append(PageItem(bytes: item, value: .change(change)))
        }
        for patch in patches {
            let item = try canonicalAny(["patch": try jsonObject(patch)]) + Data([0x0A])
            result.append(PageItem(bytes: item, value: .patch(patch)))
        }
        return result
    }

    func patchChunks(_ data: Data, layer: GitDiffLayer, path: String?) -> [GitDiffPatch] {
        let chunkLimit = 8 * 1_024
        let isUTF8 = String(data: data, encoding: .utf8) != nil
        var chunks: [GitDiffPatch] = []
        var offset = 0
        while offset < data.count {
            var end = min(data.count, offset + chunkLimit)
            if isUTF8 {
                while end > offset, String(data: data[offset..<end], encoding: .utf8) == nil { end -= 1 }
            }
            if end == offset { end = min(data.count, offset + chunkLimit) }
            let bytes = Data(data[offset..<end])
            let text = isUTF8 ? String(data: bytes, encoding: .utf8) : nil
            chunks.append(GitDiffPatch(
                layer: layer, path: path, offset: offset, totalBytes: data.count,
                encoding: text == nil ? "base64" : "utf-8", text: text,
                base64: text == nil ? bytes.base64EncodedString() : nil
            ))
            offset = end
        }
        return chunks
    }

    func requestDigest(_ request: GitDiffContextRequest, scope: String?) throws -> String {
        try sha256(canonicalAny([
            "baseRef": request.baseRef as Any,
            "includePatch": request.includePatch,
            "mode": request.mode.rawValue,
            "scope": scope as Any
        ]))
    }

    func token(snapshotID: String, offset: Int) -> String {
        let unsigned = "gitctx1.\(snapshotID).\(offset)"
        return "\(unsigned).\(hmac(Data(unsigned.utf8)))"
    }

    func hmac(_ data: Data) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: tokenKey)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    func changeOrder(_ lhs: GitDiffChange, _ rhs: GitDiffChange) -> Bool {
        let ranks: [GitDiffLayer: Int] = [.baseToHead: 0, .staged: 1, .unstaged: 2, .untracked: 3]
        if ranks[lhs.layer] != ranks[rhs.layer] { return ranks[lhs.layer, default: 9] < ranks[rhs.layer, default: 9] }
        if lhs.path != rhs.path { return utf8Order(lhs.path, rhs.path) }
        if lhs.previousPath != rhs.previousPath { return utf8Order(lhs.previousPath ?? "", rhs.previousPath ?? "") }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }

    func bytePathOrder(_ lhs: GitEvidenceContentDigest, _ rhs: GitEvidenceContentDigest) -> Bool { utf8Order(lhs.path, rhs.path) }
    func utf8Order(_ lhs: String, _ rhs: String) -> Bool { Data(lhs.utf8).lexicographicallyPrecedes(Data(rhs.utf8)) }

    func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func canonicalData<T: Encodable>(_ value: T) throws -> Data { try canonicalAny(jsonObject(value)) }

    func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
    }

    func canonicalObjectData(_ values: [String: String]) throws -> Data { try canonicalAny(values) }

    func canonicalAny(_ value: Any) throws -> Data {
        if let optional = value as? OptionalProtocol, optional.isNil { return Data("null".utf8) }
        switch value {
        case is NSNull: return Data("null".utf8)
        case let string as String:
            return try JSONSerialization.data(withJSONObject: [string]).dropFirst().dropLast()
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return Data(number.boolValue ? "true".utf8 : "false".utf8) }
            return Data(number.stringValue.utf8)
        case let array as [Any]:
            var data = Data([0x5B])
            for (index, item) in array.enumerated() { if index > 0 { data.append(0x2C) }; data.append(try canonicalAny(item)) }
            data.append(0x5D)
            return data
        case let dictionary as [String: Any]:
            var data = Data([0x7B])
            for (index, key) in dictionary.keys.sorted().enumerated() {
                if index > 0 { data.append(0x2C) }
                data.append(try canonicalAny(key)); data.append(0x3A); data.append(try canonicalAny(dictionary[key] ?? NSNull()))
            }
            data.append(0x7D)
            return data
        default: return try canonicalAny(try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: value)))
        }
    }

    func appendUInt32(_ value: UInt32, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    func appendUInt64(_ value: UInt64, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }
}

private protocol OptionalProtocol { var isNil: Bool { get } }
extension Optional: OptionalProtocol { fileprivate var isNil: Bool { self == nil } }
