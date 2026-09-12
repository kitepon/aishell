import CryptoKit
import Foundation

public enum ProjectProfileProjectionMode: String, Codable, Sendable {
    case auto, all, none
}

public struct ProjectProfileProjectionRequest: Codable, Sendable {
    public let mode: ProjectProfileProjectionMode
    public let projectIDs: [String]
    public let byteBudget: Int
    public let profileLimit: Int
    public let continuation: String?

    public init(
        mode: ProjectProfileProjectionMode = .auto,
        projectIDs: [String] = [],
        byteBudget: Int = 65_536,
        profileLimit: Int = 100,
        continuation: String? = nil
    ) {
        self.mode = mode
        self.projectIDs = projectIDs
        self.byteBudget = min(max(1_024, byteBudget), 262_144)
        self.profileLimit = min(max(1, profileLimit), 1_000)
        self.continuation = continuation
    }
}

public struct ProjectProfileOversizeDescriptor: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let projection: String
    public let projectId: String
    public let requiredBytes: Int
    public let sha256: String
    public let artifact: ArtifactMetadata
}

public enum ProjectProfileProjectionItem: Codable, Equatable, Sendable {
    case profile(ProjectProfile)
    case oversized(ProjectProfileOversizeDescriptor)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let descriptor = try? container.decode(ProjectProfileOversizeDescriptor.self),
           descriptor.projection == "artifact_only" {
            self = .oversized(descriptor)
        } else {
            self = .profile(try container.decode(ProjectProfile.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .profile(profile): try container.encode(profile)
        case let .oversized(descriptor): try container.encode(descriptor)
        }
    }
}

public struct ProjectProfileSummary: Codable, Equatable, Sendable {
    public let totalProfiles: Int
    public let returnedProfiles: Int
    public let omittedProfiles: Int
    public let returnedBytes: Int
    public let omittedBytes: Int
    public let statusCounts: [String: Int]
    public let profileDigest: String
}

public struct WorkspaceSnapshotV2Result: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let root: String
    public let cursor: String
    public let isFull: Bool
    public let freshness: String
    public let checkpointState: String?
    public let entries: [WorkspaceEntry]
    public let changes: [WorkspaceChange]
    public let omittedEntries: Int
    public let manifests: [String]
    public let guidanceFiles: [String]
    public let testCandidates: [String]
    public let gitStatusState: String
    public let gitStatus: [String]
    public let context: [ContextChunk]
    public let gitDiff: GitDiffContextResult?
    public let projectProfiles: [ProjectProfileProjectionItem]?
    public let projectProfileSummary: ProjectProfileSummary?
    public let projectProfileHasMore: Bool?
    public let projectProfileContinuation: String?
}

public actor ContextCompilerService {
    private let runtimeStore: RuntimeStore
    private let workspaceRuntime: WorkspaceStateRuntime?
    private let evidenceStore: EvidenceStore
    private let projectProfiles: ProjectProfileService
    private var providerBinding: String?
    private var gitProvider: GitContextProvider?
    private var searchProvider: SearchContextService?
    private struct ProfileProjectionSnapshot: Sendable {
        let workspace: WorkspaceSnapshot
        let profiles: [ProjectProfile]
        let records: [Data]
        let statusCounts: [String: Int]
        let profileDigest: String
        let expiresAt: Date
        let byteBudget: Int
        let profileLimit: Int
    }
    private var profileProjectionSnapshots: [String: ProfileProjectionSnapshot] = [:]
    private let profileTokenKey = SymmetricKey(size: .bits256)

    public init(
        runtimeStore: RuntimeStore = RuntimeStore(),
        workspaceRuntime: WorkspaceStateRuntime? = nil,
        evidenceStore: EvidenceStore? = nil,
        projectProfileService: ProjectProfileService? = nil
    ) {
        self.runtimeStore = runtimeStore
        self.workspaceRuntime = workspaceRuntime
        self.evidenceStore = evidenceStore ?? EvidenceStore(
            baseDirectory: runtimeStore.baseDirectory.appendingPathComponent("evidence", isDirectory: true)
        )
        projectProfiles = projectProfileService ?? ProjectProfileService(
            runtimeStore: runtimeStore,
            workspaceRuntime: workspaceRuntime,
            evidenceStore: self.evidenceStore
        )
    }

    public func workspaceSnapshot(
        path: String? = nil,
        sinceCursor: String? = nil,
        entryLimit: Int = 500,
        contextBudget: Int = 16_384,
        gitDiffRequest: GitDiffContextRequest? = nil,
        projectProfileRequest: ProjectProfileProjectionRequest? = nil
    ) async throws -> WorkspaceSnapshotV2Result {
        guard let workspaceRuntime else {
            throw AIShellError.invalidArgument("workspace runtimeが必要です。")
        }
        if let continuation = projectProfileRequest?.continuation {
            guard gitDiffRequest == nil else {
                throw AIShellError.invalidArgument("project_profile continuationとgit_diffは同時指定できません。")
            }
            return try await continueProfileProjection(
                continuation,
                path: path,
                byteBudget: projectProfileRequest?.byteBudget ?? 65_536,
                profileLimit: projectProfileRequest?.profileLimit ?? 100
            )
        }
        let snapshot = try await workspaceRuntime.snapshot(
            path: path,
            sinceCursor: sinceCursor,
            entryLimit: entryLimit,
            contextBudget: contextBudget
        )
        let gitDiff: GitDiffContextResult?
        if let gitDiffRequest {
            let provider = try await activeGitProvider()
            let initialBinding = try Self.gitComparisonBinding(snapshot: snapshot)
            gitDiff = try await provider.context(
                path: path,
                request: gitDiffRequest,
                comparisonBinding: initialBinding,
                comparisonBindingVerifier: {
                    try Self.gitComparisonBinding(snapshot: snapshot)
                }
            )
        } else {
            gitDiff = nil
        }

        let selectedProfiles: [ProjectProfileProjectionItem]?
        let profileSummary: ProjectProfileSummary?
        let profileHasMore: Bool?
        let profileContinuation: String?
        if let request = projectProfileRequest, request.mode != .none {
            let catalog = try await projectProfiles.catalog(rootPath: snapshot.root, observedCursor: snapshot.cursor)
            let requested = Set(request.projectIDs)
            if !requested.isEmpty {
                let known = Set(catalog.profiles.map(\.projectId))
                let missing = requested.subtracting(known).sorted()
                guard missing.isEmpty else {
                    throw AIShellError.invalidArgument("PROJECT_NOT_FOUND: \(missing.joined(separator: ", "))")
                }
            }
            let projected: [ProjectProfile]
            if !requested.isEmpty {
                projected = catalog.profiles.filter { requested.contains($0.projectId) }
            } else {
                switch request.mode {
                case .all:
                    projected = catalog.profiles
                case .auto:
                    projected = Self.autoProfiles(
                        catalog.profiles,
                        ownerRoot: catalog.root,
                        requestPath: snapshot.root
                    )
                case .none:
                    projected = []
                }
            }
            let projection = try await makeProfileProjection(
                workspace: snapshot,
                all: projected,
                projected: projected,
                request: request
            )
            selectedProfiles = projection.items
            profileSummary = projection.summary
            profileHasMore = projection.hasMore
            profileContinuation = projection.continuation
        } else {
            selectedProfiles = nil
            profileSummary = nil
            profileHasMore = nil
            profileContinuation = nil
        }

        return Self.workspaceResult(
            snapshot: snapshot,
            gitDiff: gitDiff,
            projectProfiles: selectedProfiles,
            projectProfileSummary: profileSummary,
            projectProfileHasMore: profileHasMore,
            projectProfileContinuation: profileContinuation
        )
    }

    private static func workspaceResult(
        snapshot: WorkspaceSnapshot,
        gitDiff: GitDiffContextResult?,
        projectProfiles: [ProjectProfileProjectionItem]?,
        projectProfileSummary: ProjectProfileSummary?,
        projectProfileHasMore: Bool?,
        projectProfileContinuation: String?
    ) -> WorkspaceSnapshotV2Result {
        WorkspaceSnapshotV2Result(
            schemaVersion: "aishell.workspace-snapshot.v2",
            root: snapshot.root,
            cursor: snapshot.cursor,
            isFull: snapshot.isFull,
            freshness: snapshot.freshness,
            checkpointState: snapshot.checkpointState,
            entries: snapshot.entries,
            changes: snapshot.changes,
            omittedEntries: snapshot.omittedEntries,
            manifests: snapshot.manifests,
            guidanceFiles: snapshot.guidanceFiles,
            testCandidates: snapshot.testCandidates,
            gitStatusState: snapshot.gitStatusState,
            gitStatus: snapshot.gitStatus,
            context: snapshot.context,
            gitDiff: gitDiff,
            projectProfiles: projectProfiles,
            projectProfileSummary: projectProfileSummary,
            projectProfileHasMore: projectProfileHasMore,
            projectProfileContinuation: projectProfileContinuation
        )
    }

    public func searchContextV2(
        request: SearchContextRequestV2? = nil,
        continuation: String? = nil
    ) async throws -> SearchContextResultV2 {
        let provider = try await activeSearchProvider()
        if let continuation {
            guard request == nil else {
                throw SearchContextServiceError.invalidArgument("continuationと初回requestは同時指定できません。")
            }
            return try await provider.continueSearch(continuation)
        }
        guard let request else {
            throw SearchContextServiceError.invalidArgument("初回search requestが必要です。")
        }
        guard let workspaceRuntime else {
            throw SearchContextServiceError.rescanRequired("workspace runtime is unavailable")
        }
        let fromCursor: String
        if let cursor = request.changedSinceCursor {
            fromCursor = cursor
        } else {
            guard !request.ranking.contains(.changed) else {
                throw SearchContextServiceError.invalidArgument("changed順位にはchanged_since_cursorが必要です。")
            }
            fromCursor = try await workspaceRuntime.currentSearchCursor(path: request.path)
        }
        let includeIndexedFiles = request.queries.contains { $0.kind == .glob }
        let initial = try await workspaceRuntime.searchContextObservation(
            path: request.path,
            fromCursor: fromCursor,
            includeIndexedFiles: false
        )
        let catalog = try await projectProfiles.catalog(
            rootPath: request.path,
            observedCursor: initial.workspaceCursor
        )
        let testPaths = Set(catalog.profiles.flatMap { profile in
            profile.targets.filter { $0.kind == "test" }.flatMap(\.sourceRoots)
        })
        let profileDigest = Self.digestStrings(catalog.profiles.map(\.profileDigest))
        let environment = try await workspaceRuntime.searchContextObservation(
            path: request.path,
            fromCursor: fromCursor,
            testPaths: testPaths,
            testClassification: catalog.profiles.contains(where: { $0.status != .complete }) ? "partial" : "complete",
            projectProfileDigest: profileDigest,
            includeIndexedFiles: includeIndexedFiles
        )
        return try await provider.search(request, environment: environment)
    }

    public func readContext(
        targets: [String],
        byteBudget: Int = 65_536,
        continuation: String? = nil
    ) async throws -> ReadContextResult {
        guard !targets.isEmpty else {
            throw AIShellError.invalidArgument("targetsは1件以上必要です。")
        }
        let resolver = try await activeResolver()
        let budget = min(max(1, byteBudget), 1_048_576)
        let signature = Self.signature(for: targets)
        let start = try parseContinuation(continuation, signature: signature)
        var chunks: [ContextChunk] = []
        var returned = 0
        var omitted = 0
        var next: String?

        for index in start.index..<targets.count {
            let url = try resolver.resolveExisting(targets[index])
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true else {
                throw AIShellError.invalidPath(url.path)
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard String(data: data, encoding: .utf8) != nil else {
                throw AIShellError.notTextFile(url.path)
            }
            let contentSHA = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if index == start.index,
               start.offset > 0,
               let expectedSHA = start.expectedSHA,
               expectedSHA != contentSHA {
                throw AIShellError.contentChanged(url.path)
            }
            let offset = index == start.index ? min(start.offset, data.count) : 0
            let remainingBudget = budget - returned
            guard remainingBudget > 0 else {
                omitted += data.count - offset
                next = continuationToken(signature: signature, index: index, offset: offset, sha256: contentSHA)
                for remaining in targets.dropFirst(index + 1) {
                    if let remainingURL = try? resolver.resolveExisting(remaining),
                       let size = try? remainingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        omitted += size
                    }
                }
                break
            }
            if !chunks.isEmpty, data.count - offset > remainingBudget {
                omitted += data.count - offset
                next = continuationToken(signature: signature, index: index, offset: offset, sha256: contentSHA)
                for remaining in targets.dropFirst(index + 1) {
                    if let remainingURL = try? resolver.resolveExisting(remaining),
                       let size = try? remainingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        omitted += size
                    }
                }
                break
            }
            let maximumCount = min(remainingBudget, data.count - offset)
            let selected = try Self.validUTF8Prefix(data: data, offset: offset, maximumCount: maximumCount)
            let count = selected.count
            let relative = displayPath(url: url, resolver: resolver)
            chunks.append(ContextChunk(
                path: relative,
                text: String(data: selected, encoding: .utf8) ?? "",
                sha256: contentSHA,
                sizeBytes: data.count,
                returnedBytes: selected.count,
                omittedBytes: data.count - offset - selected.count
            ))
            returned += selected.count
            omitted += data.count - offset - selected.count
            if offset + count < data.count {
                next = continuationToken(
                    signature: signature,
                    index: index,
                    offset: offset + count,
                    sha256: contentSHA
                )
                for remaining in targets[(index + 1)...] {
                    if let remainingURL = try? resolver.resolveExisting(remaining),
                       let size = try? remainingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        omitted += size
                    }
                }
                break
            }
            if returned == budget, index + 1 < targets.count {
                next = continuationToken(signature: signature, index: index + 1, offset: 0, sha256: nil)
                for remaining in targets[(index + 1)...] {
                    if let remainingURL = try? resolver.resolveExisting(remaining),
                       let size = try? remainingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        omitted += size
                    }
                }
                break
            }
        }

        return ReadContextResult(
            schemaVersion: "aishell.read-context.v1",
            chunks: chunks,
            returnedBytes: returned,
            omittedBytes: omitted,
            continuation: next
        )
    }

    public func searchContext(
        query: String,
        path: String? = nil,
        maxResults: Int = 50,
        byteBudget: Int = 65_536,
        continuation: String? = nil
    ) async throws -> SearchContextResult {
        guard !query.isEmpty else { throw AIShellError.invalidArgument("queryは空にできません。") }
        let resolver = try await activeResolver()
        let scope = try resolver.resolveExisting(path)
        let scopeValues = try scope.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        let scopeIsDirectory = scopeValues.isDirectory == true
        guard scopeIsDirectory || scopeValues.isRegularFile == true else {
            throw AIShellError.invalidPath(scope.path)
        }
        let resultRoot = scopeIsDirectory ? scope : scope.deletingLastPathComponent()
        let executable = try rgExecutable()
        let output = try runRG(
            executable: executable,
            query: query,
            scope: scope,
            workingDirectory: resultRoot
        )
        let changed = Set(await workspaceRuntime?.recentChangedPaths() ?? [])
        var matches = parseRG(output: output, root: resultRoot, changedPaths: changed)
        matches.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.path != $1.path { return $0.path < $1.path }
            return $0.line < $1.line
        }
        let resultDigest = Self.searchResultDigest(matches)
        let searchSignature = Self.signature(for: [query, scope.path])
        let startIndex = try parseSearchContinuation(
            continuation,
            signature: searchSignature,
            resultDigest: resultDigest
        )
        guard startIndex <= matches.count else { throw AIShellError.cursorExpired(continuation ?? "") }

        let resultLimit = min(max(1, maxResults), 500)
        let budget = min(max(1, byteBudget), 1_048_576)
        var visible: [SearchContextMatch] = []
        var used = 0
        for match in matches.dropFirst(startIndex).prefix(resultLimit) {
            let bytes = match.path.utf8.count + match.text.utf8.count + 16
            if used + bytes > budget { break }
            visible.append(match)
            used += bytes
        }
        if visible.isEmpty, startIndex < matches.count {
            throw AIShellError.invalidArgument("byte_budgetが先頭matchより小さすぎます。")
        }
        let nextIndex = startIndex + visible.count
        let remainingBytes = matches.dropFirst(nextIndex).reduce(0) {
            $0 + $1.path.utf8.count + $1.text.utf8.count + 16
        }
        return SearchContextResult(
            schemaVersion: "aishell.search-context.v1",
            query: query,
            worker: "rg --json",
            matches: visible,
            omittedMatches: matches.count - nextIndex,
            returnedBytes: used,
            omittedBytes: remainingBytes,
            continuation: nextIndex < matches.count
                ? searchContinuationToken(
                    signature: searchSignature,
                    index: nextIndex,
                    resultDigest: resultDigest
                ) : nil,
            freshness: "filesystem-current"
        )
    }

    private func activeGitProvider() async throws -> GitContextProvider {
        try await refreshProvidersIfNeeded()
        guard let gitProvider else { throw AIShellError.workerUnavailable("git") }
        return gitProvider
    }

    private func activeSearchProvider() async throws -> SearchContextService {
        try await refreshProvidersIfNeeded()
        guard let searchProvider else { throw AIShellError.workerUnavailable("rg") }
        return searchProvider
    }

    private func refreshProvidersIfNeeded() async throws {
        let resolver = await runtimeStore.pathResolver()
        let binding = Self.digestStrings([resolver.rootURL.path, "unrestricted-v1"])
        guard providerBinding != binding else { return }
        gitProvider = GitContextProvider(resolver: resolver, evidenceStore: evidenceStore)
        searchProvider = try SearchContextService(resolver: resolver, evidenceStore: evidenceStore)
        providerBinding = binding
    }

    private func makeProfileProjection(
        workspace: WorkspaceSnapshot,
        all: [ProjectProfile],
        projected: [ProjectProfile],
        request: ProjectProfileProjectionRequest
    ) async throws -> (
        items: [ProjectProfileProjectionItem], summary: ProjectProfileSummary,
        hasMore: Bool, continuation: String?
    ) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let records = try projected.map { profile -> Data in
            var data = try encoder.encode(profile)
            data.append(0x0A)
            return data
        }
        let id = UUID().uuidString.lowercased()
        let counts = Dictionary(grouping: all, by: { $0.status.rawValue }).mapValues(\.count)
        let profileDigest = Self.digestStrings(all.map(\.profileDigest))
        profileProjectionSnapshots[id] = ProfileProjectionSnapshot(
            workspace: workspace,
            profiles: projected,
            records: records,
            statusCounts: counts,
            profileDigest: profileDigest,
            expiresAt: Date().addingTimeInterval(EvidenceStore.defaultRetentionSeconds),
            byteBudget: request.byteBudget,
            profileLimit: request.profileLimit
        )
        return try await profileProjectionPage(
            id: id,
            offset: 0,
            byteBudget: request.byteBudget,
            profileLimit: request.profileLimit
        )
    }

    private func continueProfileProjection(
        _ token: String,
        path: String?,
        byteBudget: Int,
        profileLimit: Int
    ) async throws -> WorkspaceSnapshotV2Result {
        let parsed = try parseProfileToken(token)
        guard let retained = profileProjectionSnapshots[parsed.id] else {
            throw AIShellError.cursorExpired(token)
        }
        guard Date() <= retained.expiresAt else {
            profileProjectionSnapshots[parsed.id] = nil
            throw AIShellError.cursorExpired(token)
        }
        guard byteBudget == retained.byteBudget, profileLimit == retained.profileLimit else {
            throw AIShellError.cursorExpired(token)
        }
        guard path == nil || URL(fileURLWithPath: path!).standardizedFileURL.path == retained.workspace.root else {
            throw AIShellError.cursorExpired(token)
        }
        guard let workspaceRuntime else { throw AIShellError.rescanRequired("workspace runtime is unavailable") }
        let observation = try await workspaceRuntime.searchContextObservation(
            path: retained.workspace.root,
            fromCursor: retained.workspace.cursor
        )
        guard observation.observedThrough == retained.workspace.cursor else {
            throw AIShellError.contentChanged(retained.workspace.root)
        }
        let page = try await profileProjectionPage(
            id: parsed.id,
            offset: parsed.offset,
            byteBudget: byteBudget,
            profileLimit: profileLimit
        )
        return Self.workspaceResult(
            snapshot: retained.workspace,
            gitDiff: nil,
            projectProfiles: page.items,
            projectProfileSummary: page.summary,
            projectProfileHasMore: page.hasMore,
            projectProfileContinuation: page.continuation
        )
    }

    private func profileProjectionPage(
        id: String,
        offset: Int,
        byteBudget: Int,
        profileLimit: Int
    ) async throws -> (
        items: [ProjectProfileProjectionItem], summary: ProjectProfileSummary,
        hasMore: Bool, continuation: String?
    ) {
        guard let retained = profileProjectionSnapshots[id], offset <= retained.records.count else {
            throw AIShellError.cursorExpired(id)
        }
        let budget = min(max(1_024, byteBudget), 262_144)
        let limit = min(max(1, profileLimit), 1_000)
        var items: [ProjectProfileProjectionItem] = []
        var returnedBytes = 0
        var cursor = offset
        while cursor < retained.records.count, items.count < limit {
            let record = retained.records[cursor]
            if returnedBytes + record.count <= budget {
                items.append(.profile(retained.profiles[cursor]))
                returnedBytes += record.count
                cursor += 1
                continue
            }
            if items.isEmpty {
                let raw = Data(record.dropLast())
                let metadata = try await evidenceStore.store(
                    data: raw,
                    kind: "project-profile-oversize.v1",
                    producer: "ContextCompilerService",
                    retentionSeconds: EvidenceStore.defaultRetentionSeconds
                )
                let descriptor = ProjectProfileOversizeDescriptor(
                    schemaVersion: "aishell.project-profile-oversize.v1",
                    projection: "artifact_only",
                    projectId: retained.profiles[cursor].projectId,
                    requiredBytes: record.count,
                    sha256: metadata.sha256,
                    artifact: metadata
                )
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let descriptorBytes = try encoder.encode(descriptor).count + 1
                guard descriptorBytes <= budget else {
                    throw AIShellError.invalidArgument("PROFILE_DESCRIPTOR_OVERFLOW")
                }
                items.append(.oversized(descriptor))
                returnedBytes += descriptorBytes
                cursor += 1
            }
            break
        }
        let omittedBytes = retained.records.dropFirst(cursor).reduce(0) { $0 + $1.count }
        let summary = ProjectProfileSummary(
            totalProfiles: retained.records.count,
            returnedProfiles: items.count,
            omittedProfiles: retained.records.count - cursor,
            returnedBytes: returnedBytes,
            omittedBytes: omittedBytes,
            statusCounts: retained.statusCounts,
            profileDigest: retained.profileDigest
        )
        let hasMore = cursor < retained.records.count
        return (
            items,
            summary,
            hasMore,
            hasMore ? profileToken(id: id, offset: cursor) : nil
        )
    }

    private func profileToken(id: String, offset: Int) -> String {
        let unsigned = "profile1.\(id).\(offset)"
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(unsigned.utf8), using: profileTokenKey
        ).map { String(format: "%02x", $0) }.joined()
        return "\(unsigned).\(signature)"
    }

    private func parseProfileToken(_ token: String) throws -> (id: String, offset: Int) {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "profile1", let offset = Int(parts[2]), offset >= 0 else {
            throw AIShellError.cursorExpired(token)
        }
        let unsigned = parts.prefix(3).joined(separator: ".")
        let expected = HMAC<SHA256>.authenticationCode(
            for: Data(unsigned.utf8), using: profileTokenKey
        ).map { String(format: "%02x", $0) }.joined()
        guard expected == parts[3] else { throw AIShellError.cursorExpired(token) }
        return (String(parts[1]), offset)
    }

    private static func digestStrings(_ values: [String]) -> String {
        SHA256.hash(data: Data(values.sorted().joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func autoProfiles(
        _ profiles: [ProjectProfile],
        ownerRoot: String,
        requestPath: String
    ) -> [ProjectProfile] {
        let requested = URL(fileURLWithPath: requestPath).standardizedFileURL.path
        let candidates = profiles.compactMap { profile -> (ProjectProfile, String, Int)? in
            let absolute = URL(fileURLWithPath: ownerRoot, isDirectory: true)
                .appendingPathComponent(profile.projectRoot, isDirectory: true)
                .standardizedFileURL.path
            guard requested == absolute || requested.hasPrefix(absolute + "/") else { return nil }
            return (profile, absolute, URL(fileURLWithPath: absolute).pathComponents.count)
        }
        guard let depth = candidates.map({ $0.2 }).max() else { return [] }
        var selected = Set(candidates.filter { $0.2 == depth }.map { $0.0.projectId })
        var changed = true
        while changed {
            changed = false
            for profile in profiles where selected.contains(profile.projectId) {
                for member in profile.memberProjectIds where selected.insert(member).inserted {
                    changed = true
                }
            }
        }
        return profiles.filter { selected.contains($0.projectId) }
    }

    private static func gitComparisonBinding(snapshot: WorkspaceSnapshot) throws -> GitWorkspaceComparisonBinding {
        let root = URL(fileURLWithPath: snapshot.root, isDirectory: true).standardizedFileURL
        let rootIdentity = try fileIdentity(root)
        var bindings: [GitWorkspaceBindingEntry] = []
        for entry in snapshot.entries.sorted(by: { $0.path < $1.path }) {
            let url = root.appendingPathComponent(entry.path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                bindings.append(.init(
                    hashState: "missing", identity: "missing", kind: "missing",
                    modifiedAtNanoseconds: nil, path: entry.path, sha256: nil, sizeBytes: 0
                ))
                continue
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let identity = try fileIdentity(url)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date).map {
                String(Int64($0.timeIntervalSince1970 * 1_000_000_000))
            }
            let sha: String?
            if isDirectory.boolValue {
                sha = nil
            } else {
                sha = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
                    .map { String(format: "%02x", $0) }.joined()
            }
            bindings.append(.init(
                hashState: sha == nil ? "identity_only" : "hashed",
                identity: identity,
                kind: isDirectory.boolValue ? "directory" : "regular",
                modifiedAtNanoseconds: modified,
                path: entry.path,
                sha256: sha,
                sizeBytes: size
            ))
        }
        let parts = snapshot.cursor.split(separator: ":", omittingEmptySubsequences: false)
        let generation = parts.count == 5 ? String(parts[3]) : "unknown"
        return GitWorkspaceComparisonBinding(
            entries: bindings,
            eventHighWater: nil,
            generation: generation,
            rootIdentity: rootIdentity,
            workspaceCursor: snapshot.cursor
        )
    }

    private static func fileIdentity(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return "\(device):\(inode)"
    }

    private func activeResolver() async throws -> PathResolver {
        return await runtimeStore.pathResolver()
    }

    private func parseContinuation(
        _ continuation: String?,
        signature: String
    ) throws -> (index: Int, offset: Int, expectedSHA: String?) {
        guard let continuation else { return (0, 0, nil) }
        let parts = continuation.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 5,
              parts[0] == "read2",
              parts[1] == Substring(signature),
              let index = Int(parts[2]), index >= 0,
              let offset = Int(parts[3]), offset >= 0,
              parts[4].isEmpty || parts[4].count == 64 else {
            throw AIShellError.cursorExpired(continuation)
        }
        return (index, offset, parts[4].isEmpty ? nil : String(parts[4]))
    }

    private func continuationToken(
        signature: String,
        index: Int,
        offset: Int,
        sha256: String?
    ) -> String {
        "read2:\(signature):\(index):\(offset):\(sha256 ?? "")"
    }

    private func displayPath(url: URL, resolver: PathResolver) -> String {
        for root in [resolver.rootURL] where url.path.hasPrefix(root.path + "/") {
            return String(url.path.dropFirst(root.path.count + 1))
        }
        return url.path
    }

    private func rgExecutable() throws -> URL {
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] + pathEntries
        for directory in candidates {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("rg")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw AIShellError.workerUnavailable("rg")
    }

    private func runRG(executable: URL, query: String, scope: URL, workingDirectory: URL) throws -> Data {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIShellRG-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let outputURL = scratch.appendingPathComponent("stdout")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--json", "--line-number", "--color", "never", "--fixed-strings",
            "--glob", "!.git/**", "--glob", "!.build/**", "--glob", "!node_modules/**",
            "--glob", "!.aishell-transactions/**",
            query, scope.path
        ]
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        let outputLimit = 64 * 1_024 * 1_024
        var limitFailure: String?
        while process.isRunning {
            if Date() >= deadline {
                limitFailure = "rg exceeded 30 second timeout"
                break
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > outputLimit {
                limitFailure = "rg output exceeded 64 MiB limit"
                break
            }
            usleep(20_000)
        }
        if let limitFailure {
            process.terminate()
            let graceDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < graceDeadline { usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try output.close()
            throw AIShellError.processLaunchFailed(limitFailure)
        }
        process.waitUntilExit()
        try output.close()
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            throw AIShellError.processLaunchFailed("rg exit \(process.terminationStatus)")
        }
        let finalSize = (try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard finalSize <= outputLimit else {
            throw AIShellError.processLaunchFailed("rg output exceeded 64 MiB limit")
        }
        return try Data(contentsOf: outputURL, options: .mappedIfSafe)
    }

    private func parseRG(output: Data, root: URL, changedPaths: Set<String>) -> [SearchContextMatch] {
        String(decoding: output, as: UTF8.self).split(whereSeparator: { $0.isNewline }).compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "match",
                  let data = object["data"] as? [String: Any],
                  let pathObject = data["path"] as? [String: Any],
                  let path = pathObject["text"] as? String,
                  let linesObject = data["lines"] as? [String: Any],
                  let text = linesObject["text"] as? String,
                  let lineNumber = data["line_number"] as? Int else { return nil }
            let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
            let relative = absolute.hasPrefix(root.path + "/")
                ? String(absolute.dropFirst(root.path.count + 1)) : path
            let score = changedPaths.contains(absolute) ? 100 : 10
            return SearchContextMatch(
                path: relative,
                line: lineNumber,
                text: text.trimmingCharacters(in: .newlines),
                score: score
            )
        }
    }

    private static func signature(for targets: [String]) -> String {
        let digest = SHA256.hash(data: Data(targets.joined(separator: "\u{0}").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func parseSearchContinuation(
        _ continuation: String?,
        signature: String,
        resultDigest: String
    ) throws -> Int {
        guard let continuation else { return 0 }
        let parts = continuation.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0] == "search1",
              parts[1] == Substring(signature),
              let index = Int(parts[2]), index >= 0 else {
            throw AIShellError.cursorExpired(continuation)
        }
        guard parts[3] == Substring(resultDigest) else {
            throw AIShellError.contentChanged("search result")
        }
        return index
    }

    private func searchContinuationToken(signature: String, index: Int, resultDigest: String) -> String {
        "search1:\(signature):\(index):\(resultDigest)"
    }

    private static func searchResultDigest(_ matches: [SearchContextMatch]) -> String {
        let value = matches.map { "\($0.path):\($0.line):\($0.text):\($0.score)" }.joined(separator: "\u{0}")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func validUTF8Prefix(data: Data, offset: Int, maximumCount: Int) throws -> Data {
        guard maximumCount > 0 else { return Data() }
        for count in stride(from: maximumCount, through: 1, by: -1) {
            let selected = data.subdata(in: offset..<(offset + count))
            if String(data: selected, encoding: .utf8) != nil { return selected }
        }
        throw AIShellError.invalidArgument("byte_budgetがUTF-8文字境界まで小さすぎます。")
    }
}
