import CryptoKit
import Darwin
import Foundation

public enum SearchContextQueryKind: String, Codable, Sendable {
    case fixed
    case regex
    case glob
}

public enum SearchContextCaseMode: String, Codable, Sendable {
    case sensitive
    case insensitive
    case smart
}

public enum SearchContextRanking: String, Codable, Sendable {
    case changed
    case tests
}

public struct SearchContextQueryV2: Codable, Equatable, Sendable {
    public let id: String
    public let kind: SearchContextQueryKind
    public let pattern: String
    public let caseMode: SearchContextCaseMode
    public let beforeLines: Int
    public let afterLines: Int
    public let includeGlobs: [String]
    public let excludeGlobs: [String]

    public init(
        id: String,
        kind: SearchContextQueryKind,
        pattern: String,
        caseMode: SearchContextCaseMode = .sensitive,
        beforeLines: Int = 0,
        afterLines: Int = 0,
        includeGlobs: [String] = [],
        excludeGlobs: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.pattern = pattern
        self.caseMode = caseMode
        self.beforeLines = beforeLines
        self.afterLines = afterLines
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, pattern
        case caseMode = "case"
        case beforeLines = "before_lines"
        case afterLines = "after_lines"
        case includeGlobs = "include_globs"
        case excludeGlobs = "exclude_globs"
    }
}

public struct SearchContextRequestV2: Codable, Equatable, Sendable {
    public let path: String?
    public let queries: [SearchContextQueryV2]
    public let ranking: [SearchContextRanking]
    public let changedSinceCursor: String?
    public let maxResults: Int
    public let byteBudget: Int

    public init(
        path: String? = nil,
        queries: [SearchContextQueryV2],
        ranking: [SearchContextRanking] = [.tests],
        changedSinceCursor: String? = nil,
        maxResults: Int = 50,
        byteBudget: Int = 65_536
    ) {
        self.path = path
        self.queries = queries
        self.ranking = ranking
        self.changedSinceCursor = changedSinceCursor
        self.maxResults = maxResults
        self.byteBudget = byteBudget
    }

    enum CodingKeys: String, CodingKey {
        case path, queries, ranking
        case changedSinceCursor = "changed_since_cursor"
        case maxResults = "max_results"
        case byteBudget = "byte_budget"
    }
}

public struct SearchContextIndexedFile: Codable, Equatable, Sendable {
    public let path: String
    public let fileIdentity: String
    public let contentSHA256: String

    public init(path: String, fileIdentity: String, contentSHA256: String) {
        self.path = path
        self.fileIdentity = fileIdentity
        self.contentSHA256 = contentSHA256
    }
}

public struct SearchContextEnvironment: Sendable {
    public let effectiveRootIdentity: String
    public let effectiveRootPolicyDigest: String
    public let workspaceCursor: String
    public let observedFrom: String
    public let observedThrough: String
    public let observationViewID: String
    public let changedPaths: Set<String>
    public let testPaths: Set<String>
    public let testClassification: String
    public let projectProfileDigest: String?
    public let indexedFiles: [SearchContextIndexedFile]?
    public let isFresh: Bool

    public init(
        effectiveRootIdentity: String,
        effectiveRootPolicyDigest: String,
        workspaceCursor: String,
        observedFrom: String,
        observedThrough: String,
        observationViewID: String,
        changedPaths: Set<String> = [],
        testPaths: Set<String> = [],
        testClassification: String = "unavailable",
        projectProfileDigest: String? = nil,
        indexedFiles: [SearchContextIndexedFile]? = nil,
        isFresh: Bool = true
    ) {
        self.effectiveRootIdentity = effectiveRootIdentity
        self.effectiveRootPolicyDigest = effectiveRootPolicyDigest
        self.workspaceCursor = workspaceCursor
        self.observedFrom = observedFrom
        self.observedThrough = observedThrough
        self.observationViewID = observationViewID
        self.changedPaths = changedPaths
        self.testPaths = testPaths
        self.testClassification = testClassification
        self.projectProfileDigest = projectProfileDigest
        self.indexedFiles = indexedFiles
        self.isFresh = isFresh
    }
}

public struct SearchContextByteRange: Codable, Equatable, Sendable {
    public let start: Int
    public let end: Int
}

public struct SearchContextQueryRange: Codable, Equatable, Sendable {
    public let queryID: String
    public let range: SearchContextByteRange?
    public let selectedCaseMode: SearchContextCaseMode

    enum CodingKeys: String, CodingKey {
        case queryID = "query_id"
        case range
        case selectedCaseMode = "selected_case"
    }
}

public struct SearchContextMatchV2: Codable, Equatable, Sendable {
    public let kind: String
    public let canonicalIdentity: String
    public let path: String
    public let pathDigest: String
    public let byteRange: SearchContextByteRange?
    public let line: Int?
    public let columnBytes: Int?
    public let text: String?
    public let queryIDs: [String]
    public let queryRanges: [SearchContextQueryRange]
    public let contextBlockID: String?

    enum CodingKeys: String, CodingKey {
        case kind, canonicalIdentity, path, pathDigest, byteRange, line, columnBytes, text
        case queryIDs = "queryIds"
        case queryRanges, contextBlockID
    }
}

public struct SearchContextBlock: Codable, Equatable, Sendable {
    public let kind: String
    public let id: String
    public let path: String
    public let byteRange: SearchContextByteRange
    public let startLine: Int
    public let endLine: Int
    public let text: String
}

public struct SearchContextOversizedDescriptor: Codable, Equatable, Sendable {
    public let kind: String
    public let reason: String
    public let canonicalIdentity: String
    public let pathDigest: String
    public let byteRange: SearchContextByteRange?
    public let requiredBytes: Int
    public let artifactHandle: String
    public let artifactSHA256: String
    public let artifactSizeBytes: Int
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case kind, reason, canonicalIdentity, pathDigest, byteRange, requiredBytes
        case artifactHandle = "artifact_handle"
        case artifactSHA256 = "artifact_sha256"
        case artifactSizeBytes = "artifact_size_bytes"
        case expiresAt = "expires_at"
    }
}

public struct SearchContextFreshness: Codable, Equatable, Sendable {
    public let effectiveRootIdentity: String
    public let effectiveRootPolicyDigest: String
    public let searchScope: String
    public let workspaceCursor: String
    public let observedFrom: String
    public let observedThrough: String
    public let state: String
    public let providerEvidenceDigest: String
}

public struct SearchContextRankingEvidence: Codable, Equatable, Sendable {
    public let applied: [SearchContextRanking]
    public let workspaceCursor: String
    public let observationViewID: String
    public let fromCursor: String
    public let throughCursor: String
    public let changedSetDigest: String
    public let projectProfileDigest: String?
    public let testClassification: String
}

public struct SearchContextResultV2: Codable, Equatable, Sendable {
    public let schema: String
    public let provider: String
    public let scanMode: String
    public let matches: [SearchContextMatchV2]
    public let contextBlocks: [SearchContextBlock]
    public let oversizedDescriptors: [SearchContextOversizedDescriptor]
    public let returnedMatches: Int
    public let omittedMatches: Int
    public let returnedBytes: Int
    public let omittedBytes: Int
    public let hasMore: Bool
    public let continuation: String?
    public let evidence: ArtifactMetadata
    public let freshness: SearchContextFreshness
    public let rankingEvidence: SearchContextRankingEvidence
}

public enum SearchContextServiceError: Error, Equatable, Sendable {
    case invalidArgument(String)
    case invalidRegex(queryID: String, message: String)
    case invalidGlob(queryID: String, message: String)
    case rescanRequired(String)
    case cursorExpired(reason: String)
    case contentChanged(String)
    case workerUnavailable(String)
    case workerTimeout
    case outputLimitExceeded
    case workerFailed(Int32, String)
    case workerOutputInvalid(String)
    case notTextFile(String)
    case artifactStoreFailed(String)
    case resultEncodingFailed(String)
}

public actor SearchContextService {
    private struct Candidate: Sendable {
        var canonicalIdentity: String
        let identityDescriptor: Data
        let path: String
        let pathDigest: String
        let fileURL: URL
        let fileIdentity: String
        let contentSHA256: String
        let byteRange: SearchContextByteRange?
        let line: Int?
        let columnBytes: Int?
        let text: String?
        var queryRanges: [SearchContextQueryRange]
        var queryIndices: [Int]
        var beforeLines: Int
        var afterLines: Int
        var contextBlockID: String?
    }

    private struct Bundle: Sendable {
        let match: SearchContextMatchV2
        let block: SearchContextBlock?
        let data: Data
    }

    private struct FileEvidence: Sendable {
        let url: URL
        let identity: String
        let sha256: String
    }

    private struct Snapshot: Sendable {
        let id: String
        let requestDigest: String
        let bundles: [Bundle]
        let evidence: ArtifactMetadata
        let files: [FileEvidence]
        let freshness: SearchContextFreshness
        let rankingEvidence: SearchContextRankingEvidence
        let byteBudget: Int
        let maxResults: Int
        let expiresAt: Date
    }

    private struct TokenPayload: Codable {
        let snapshotID: String
        let offset: Int
    }

    private struct WorkerResult: Sendable {
        let data: Data
        let arguments: [String]
        let exitStatus: Int32
        let stdoutDigest: String
        let stderrDigest: String
    }

    private let resolver: PathResolver
    private let evidenceStore: EvidenceStore
    private let executable: URL
    private let retentionSeconds: TimeInterval
    private let clock: @Sendable () -> Date
    private let tokenKey: SymmetricKey
    private var snapshots: [String: Snapshot] = [:]

    public init(
        resolver: PathResolver,
        evidenceStore: EvidenceStore,
        rgExecutable: URL? = nil,
        retentionSeconds: TimeInterval = EvidenceStore.defaultRetentionSeconds,
        clock: @escaping @Sendable () -> Date = Date.init,
        tokenSecret: Data? = nil
    ) throws {
        self.resolver = resolver
        self.evidenceStore = evidenceStore
        executable = try rgExecutable ?? Self.findRGExecutable()
        self.retentionSeconds = max(1, retentionSeconds)
        self.clock = clock
        tokenKey = SymmetricKey(data: tokenSecret ?? Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
    }

    public func search(
        _ request: SearchContextRequestV2,
        environment: SearchContextEnvironment
    ) async throws -> SearchContextResultV2 {
        try validate(request, environment: environment)
        guard environment.isFresh else {
            throw SearchContextServiceError.rescanRequired("workspace observation is not fresh")
        }
        let scope = try resolver.resolveExisting(request.path)
        let scopeValues = try scope.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        let scopeIsDirectory = scopeValues.isDirectory == true
        guard scopeIsDirectory || scopeValues.isRegularFile == true else {
            throw SearchContextServiceError.invalidArgument("search path must be a directory or regular file")
        }
        let root = try effectiveRoot(containing: scope)
        let initialScopeEvidence = try fileIdentity(scope)
        var workerEvidence: [[String: Any]] = []
        var candidates: [Candidate] = []

        for (queryIndex, query) in request.queries.enumerated() {
            let selectedCase = selectedCaseMode(for: query)
            let includeMatchers = try query.includeGlobs.map { try GlobMatcher(pattern: $0) }
            let excludeMatchers = try query.excludeGlobs.map { try GlobMatcher(pattern: $0) }
            switch query.kind {
            case .fixed, .regex:
                let worker = try runRG(
                    query: query,
                    selectedCase: selectedCase,
                    scope: scope,
                    scopeIsDirectory: scopeIsDirectory
                )
                workerEvidence.append([
                    "query_id": query.id,
                    "argv": worker.arguments,
                    "exit_status": Int(worker.exitStatus),
                    "stdout_sha256": worker.stdoutDigest,
                    "stderr_sha256": worker.stderrDigest
                ])
                let parsed = try parseRG(
                    worker.data,
                    query: query,
                    queryIndex: queryIndex,
                    selectedCase: selectedCase,
                    root: root,
                    includeMatchers: includeMatchers,
                    excludeMatchers: excludeMatchers,
                    rootIdentity: environment.effectiveRootIdentity
                )
                candidates.append(contentsOf: parsed)
            case .glob:
                guard let indexedFiles = environment.indexedFiles else {
                    throw SearchContextServiceError.rescanRequired("glob search requires an attested workspace index")
                }
                let matcher: GlobMatcher
                do { matcher = try GlobMatcher(pattern: query.pattern) }
                catch { throw SearchContextServiceError.invalidGlob(queryID: query.id, message: String(describing: error)) }
                for indexed in indexedFiles where matcher.matches(indexed.path) {
                    guard !ReservedNamespacePolicy.contains(relativePath: indexed.path) else { continue }
                    let url = root.appendingPathComponent(indexed.path).standardizedFileURL
                    guard isContained(url, in: scope) else { continue }
                    let inspection = try inspectRegularFile(url)
                    guard inspection.identity == indexed.fileIdentity,
                          inspection.sha256 == indexed.contentSHA256 else {
                        throw SearchContextServiceError.contentChanged(indexed.path)
                    }
                    let identity = try canonicalIdentity(
                        kind: "glob", path: indexed.path, fileIdentity: indexed.fileIdentity,
                        contentSHA: nil, range: nil, rootIdentity: environment.effectiveRootIdentity
                    )
                    candidates.append(Candidate(
                        canonicalIdentity: identity.digest,
                        identityDescriptor: identity.descriptor,
                        path: indexed.path,
                        pathDigest: Self.sha256(Data(indexed.path.utf8)),
                        fileURL: url,
                        fileIdentity: indexed.fileIdentity,
                        contentSHA256: indexed.contentSHA256,
                        byteRange: nil,
                        line: nil,
                        columnBytes: nil,
                        text: nil,
                        queryRanges: [.init(queryID: query.id, range: nil, selectedCaseMode: .sensitive)],
                        queryIndices: [queryIndex],
                        beforeLines: 0,
                        afterLines: 0,
                        contextBlockID: nil
                    ))
                }
            }
        }

        var deduplicated = deduplicate(candidates)
        try attachContextBlocks(to: &deduplicated)
        deduplicated.sort { lhs, rhs in
            compare(lhs, rhs, ranking: request.ranking, environment: environment)
        }
        // 明示rankingの優先度を保ち、同じ優先度ではqueryとファイルを交互に返す。
        let ranked = Dictionary(grouping: deduplicated) { candidate in
            request.ranking.map { criterion in
                switch criterion {
                case .changed: return environment.changedPaths.contains(candidate.path) ? "0" : "1"
                case .tests: return environment.testPaths.contains(candidate.path) ? "0" : "1"
                }
            }.joined()
        }
        deduplicated = ranked.keys.sorted().flatMap { rank in
            let groups = Dictionary(grouping: ranked[rank]!) { candidate in
                "\(candidate.queryIndices.min() ?? 0)\u{0}\(candidate.path)"
            }
            let keys = groups.keys.sorted {
                let left = groups[$0]!.first!.queryIndices.min() ?? 0
                let right = groups[$1]!.first!.queryIndices.min() ?? 0
                return left == right ? Self.utf8Less($0, $1) : left < right
            }
            var ordered: [Candidate] = []
            for offset in 0..<(groups.values.map(\.count).max() ?? 0) {
                for key in keys {
                    if let values = groups[key], offset < values.count { ordered.append(values[offset]) }
                }
            }
            return ordered
        }
        for candidate in deduplicated {
            let current = try inspectRegularFile(candidate.fileURL)
            guard current.identity == candidate.fileIdentity,
                  current.sha256 == candidate.contentSHA256 else {
                throw SearchContextServiceError.contentChanged(candidate.path)
            }
        }
        let blocksByID = try makeContextBlocks(for: deduplicated)
        var emittedBlocks = Set<String>()
        var bundles: [Bundle] = []
        for candidate in deduplicated {
            let match = publicMatch(candidate)
            let block = candidate.contextBlockID.flatMap { id -> SearchContextBlock? in
                guard emittedBlocks.insert(id).inserted else { return nil }
                return blocksByID[id]
            }
            bundles.append(Bundle(match: match, block: block, data: try canonicalBundle(match: match, block: block)))
        }

        let workerEvidenceData = try Self.canonicalJSON(workerEvidence)
        let providerDigest = Self.sha256(workerEvidenceData)
        let freshness = SearchContextFreshness(
            effectiveRootIdentity: environment.effectiveRootIdentity,
            effectiveRootPolicyDigest: environment.effectiveRootPolicyDigest,
            searchScope: scope.path,
            workspaceCursor: environment.workspaceCursor,
            observedFrom: environment.observedFrom,
            observedThrough: environment.observedThrough,
            state: "fresh",
            providerEvidenceDigest: providerDigest
        )
        let rankingEvidence = SearchContextRankingEvidence(
            applied: request.ranking,
            workspaceCursor: environment.workspaceCursor,
            observationViewID: environment.observationViewID,
            fromCursor: environment.observedFrom,
            throughCursor: environment.observedThrough,
            changedSetDigest: Self.digestStrings(environment.changedPaths),
            projectProfileDigest: environment.projectProfileDigest,
            testClassification: environment.testClassification
        )
        let requestData = try Self.canonicalEncodable(request)
        let requestDigest = Self.sha256(requestData)
        let candidateEvidence = try candidates.map {
            try Self.jsonObject(Self.canonicalEncodable(publicMatch($0)))
        }
        let identityEvidence = try deduplicated.map {
            try Self.jsonObject($0.identityDescriptor)
        }
        let completeStream = bundles.reduce(into: Data()) { $0.append($1.data) }
        let evidenceObject: [String: Any] = [
            "schema": "aishell.search-context-evidence.v2",
            "request": try Self.jsonObject(requestData),
            "request_digest": requestDigest,
            "root_binding": [
                "effective_root_identity": environment.effectiveRootIdentity,
                "policy_digest": environment.effectiveRootPolicyDigest,
                "scope_identity": initialScopeEvidence
            ],
            "worker_evidence": workerEvidence,
            "candidates_before_dedup": candidateEvidence,
            "identity_descriptors": identityEvidence,
            "ordered_stream_base64": completeStream.base64EncodedString(),
            "stream_sha256": Self.sha256(completeStream)
        ]
        let evidenceData = try Self.canonicalJSON(evidenceObject)
        let evidence: ArtifactMetadata
        do {
            evidence = try await evidenceStore.store(
                data: evidenceData,
                kind: "search-context-evidence.v2",
                producer: "SearchContextService",
                retentionSeconds: retentionSeconds
            )
        } catch {
            throw SearchContextServiceError.artifactStoreFailed(String(describing: error))
        }
        let snapshotID = UUID().uuidString.lowercased()
        let files = Dictionary(grouping: deduplicated, by: \.path).compactMap { _, values -> FileEvidence? in
            guard let first = values.first else { return nil }
            return FileEvidence(url: first.fileURL, identity: first.fileIdentity, sha256: first.contentSHA256)
        }
        let snapshot = Snapshot(
            id: snapshotID,
            requestDigest: requestDigest,
            bundles: bundles,
            evidence: evidence,
            files: files,
            freshness: freshness,
            rankingEvidence: rankingEvidence,
            byteBudget: request.byteBudget,
            maxResults: request.maxResults,
            expiresAt: evidence.expiresAt
        )
        snapshots[snapshotID] = snapshot
        discardExpiredSnapshots()
        return try await page(snapshot: snapshot, offset: 0)
    }

    public func continueSearch(_ continuation: String) async throws -> SearchContextResultV2 {
        discardExpiredSnapshots()
        let payload = try decodeToken(continuation)
        guard let snapshot = snapshots[payload.snapshotID] else {
            throw SearchContextServiceError.cursorExpired(reason: "artifact_expired")
        }
        guard clock() <= snapshot.expiresAt else {
            snapshots.removeValue(forKey: snapshot.id)
            throw SearchContextServiceError.cursorExpired(reason: "artifact_expired")
        }
        guard payload.offset >= 0, payload.offset < snapshot.bundles.count else {
            throw SearchContextServiceError.cursorExpired(reason: "integrity_mismatch")
        }
        for file in snapshot.files {
            let current = try inspectRegularFile(file.url)
            guard current.identity == file.identity, current.sha256 == file.sha256 else {
                throw SearchContextServiceError.contentChanged(file.url.path)
            }
        }
        return try await page(snapshot: snapshot, offset: payload.offset)
    }

    private func validate(_ request: SearchContextRequestV2, environment: SearchContextEnvironment) throws {
        guard (1...32).contains(request.queries.count) else {
            throw SearchContextServiceError.invalidArgument("queries must contain 1...32 entries")
        }
        guard Set(request.queries.map(\.id)).count == request.queries.count,
              request.queries.allSatisfy({ !$0.id.isEmpty && !$0.pattern.isEmpty }) else {
            throw SearchContextServiceError.invalidArgument("query id must be unique and id/pattern must not be empty")
        }
        guard (1...500).contains(request.maxResults) else {
            throw SearchContextServiceError.invalidArgument("max_results must be 1...500")
        }
        guard (1_024...1_048_576).contains(request.byteBudget) else {
            throw SearchContextServiceError.invalidArgument("byte_budget must be 1024...1048576")
        }
        guard Set(request.ranking).count == request.ranking.count else {
            throw SearchContextServiceError.invalidArgument("ranking entries must be unique")
        }
        if request.ranking.contains(.changed) {
            guard let changedSinceCursor = request.changedSinceCursor else {
                throw SearchContextServiceError.invalidArgument("changed_since_cursor is required for changed ranking")
            }
            guard changedSinceCursor == environment.observedFrom else {
                throw SearchContextServiceError.cursorExpired(reason: "request_mismatch")
            }
        }
        for query in request.queries {
            guard (0...20).contains(query.beforeLines), (0...20).contains(query.afterLines) else {
                throw SearchContextServiceError.invalidArgument("context line count must be 0...20")
            }
            if query.kind == .glob,
               (query.caseMode != .sensitive || query.beforeLines != 0 || query.afterLines != 0
                || !query.includeGlobs.isEmpty || !query.excludeGlobs.isEmpty) {
                throw SearchContextServiceError.invalidArgument("glob query does not accept case/context/include/exclude options")
            }
            do {
                _ = try query.includeGlobs.map { try GlobMatcher(pattern: $0) }
                _ = try query.excludeGlobs.map { try GlobMatcher(pattern: $0) }
            } catch {
                throw SearchContextServiceError.invalidGlob(queryID: query.id, message: String(describing: error))
            }
        }
    }

    private func runRG(
        query: SearchContextQueryV2,
        selectedCase: SearchContextCaseMode,
        scope: URL,
        scopeIsDirectory: Bool
    ) throws -> WorkerResult {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("AIShellSearch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let stdoutURL = scratch.appendingPathComponent("stdout")
        let stderrURL = scratch.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdout.close(); try? stderr.close() }
        var arguments = ["--json", "--line-number", "--column", "--color", "never", "--no-heading"]
        if query.kind == .fixed { arguments.append("--fixed-strings") }
        switch selectedCase {
        case .sensitive: arguments.append("--case-sensitive")
        case .insensitive: arguments.append("--ignore-case")
        case .smart: break
        }
        arguments += ["--glob", "!.git/**", "--glob", "!.build/**", "--glob", "!node_modules/**"]
        arguments += ReservedNamespacePolicy.rgGlobArguments
        arguments += ["--", query.pattern, scope.path]
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = scopeIsDirectory ? scope : scope.deletingLastPathComponent()
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() }
        catch { throw SearchContextServiceError.workerUnavailable(executable.path) }
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                let grace = Date().addingTimeInterval(1)
                while process.isRunning, Date() < grace { usleep(20_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw SearchContextServiceError.workerTimeout
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: stdoutURL.path)[.size]) as? NSNumber)?.intValue ?? 0
            if size > 64 * 1_024 * 1_024 {
                process.terminate()
                let grace = Date().addingTimeInterval(1)
                while process.isRunning, Date() < grace { usleep(20_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw SearchContextServiceError.outputLimitExceeded
            }
            usleep(20_000)
        }
        process.waitUntilExit()
        try stdout.synchronize(); try stderr.synchronize()
        let output = try Data(contentsOf: stdoutURL, options: .mappedIfSafe)
        let errorData = try Data(contentsOf: stderrURL, options: .mappedIfSafe)
        let errorText = String(decoding: errorData, as: UTF8.self)
        if process.terminationStatus != 0 && process.terminationStatus != 1 {
            if query.kind == .regex {
                throw SearchContextServiceError.invalidRegex(queryID: query.id, message: errorText)
            }
            throw SearchContextServiceError.workerFailed(process.terminationStatus, errorText)
        }
        return WorkerResult(
            data: output,
            arguments: arguments,
            exitStatus: process.terminationStatus,
            stdoutDigest: Self.sha256(output),
            stderrDigest: Self.sha256(errorData)
        )
    }

    private func parseRG(
        _ output: Data,
        query: SearchContextQueryV2,
        queryIndex: Int,
        selectedCase: SearchContextCaseMode,
        root: URL,
        includeMatchers: [GlobMatcher],
        excludeMatchers: [GlobMatcher],
        rootIdentity: String
    ) throws -> [Candidate] {
        var result: [Candidate] = []
        for lineData in output.split(separator: 0x0A) {
            let object: [String: Any]
            do {
                guard let decoded = try JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any] else {
                    throw SearchContextServiceError.workerOutputInvalid(query.id)
                }
                object = decoded
            } catch let error as SearchContextServiceError { throw error }
            catch { throw SearchContextServiceError.workerOutputInvalid(query.id) }
            guard object["type"] as? String == "match" else { continue }
            guard let data = object["data"] as? [String: Any],
                  let pathObject = data["path"] as? [String: Any],
                  let pathText = pathObject["text"] as? String,
                  let linesObject = data["lines"] as? [String: Any],
                  let lineText = linesObject["text"] as? String,
                  let lineNumber = data["line_number"] as? Int,
                  let absoluteOffset = data["absolute_offset"] as? Int,
                  let submatches = data["submatches"] as? [[String: Any]] else {
                throw SearchContextServiceError.workerOutputInvalid(query.id)
            }
            let url = URL(fileURLWithPath: pathText).standardizedFileURL
            guard isContained(url, in: root) else { throw SearchContextServiceError.workerOutputInvalid(query.id) }
            let relative = String(url.path.dropFirst(root.path.count + (url.path == root.path ? 0 : 1)))
            guard !ReservedNamespacePolicy.contains(relativePath: relative) else { continue }
            guard (includeMatchers.isEmpty || includeMatchers.contains(where: { $0.matches(relative) })),
                  !excludeMatchers.contains(where: { $0.matches(relative) }) else { continue }
            let file = try inspectRegularFile(url)
            guard String(data: file.data, encoding: .utf8) != nil else {
                throw SearchContextServiceError.notTextFile(relative)
            }
            for submatch in submatches {
                guard let start = submatch["start"] as? Int,
                      let end = submatch["end"] as? Int,
                      start < end else { throw SearchContextServiceError.workerOutputInvalid(query.id) }
                let range = SearchContextByteRange(start: absoluteOffset + start, end: absoluteOffset + end)
                guard range.end <= file.data.count else { throw SearchContextServiceError.workerOutputInvalid(query.id) }
                let identity = try canonicalIdentity(
                    kind: "text", path: relative, fileIdentity: file.identity,
                    contentSHA: file.sha256, range: range, rootIdentity: rootIdentity
                )
                result.append(Candidate(
                    canonicalIdentity: identity.digest,
                    identityDescriptor: identity.descriptor,
                    path: relative,
                    pathDigest: Self.sha256(Data(relative.utf8)),
                    fileURL: url,
                    fileIdentity: file.identity,
                    contentSHA256: file.sha256,
                    byteRange: range,
                    line: lineNumber,
                    columnBytes: start,
                    text: lineText.trimmingCharacters(in: .newlines),
                    queryRanges: [.init(queryID: query.id, range: range, selectedCaseMode: selectedCase)],
                    queryIndices: [queryIndex],
                    beforeLines: query.beforeLines,
                    afterLines: query.afterLines,
                    contextBlockID: nil
                ))
            }
        }
        return result
    }

    private func deduplicate(_ candidates: [Candidate]) -> [Candidate] {
        var byIdentity: [String: Candidate] = [:]
        for candidate in candidates {
            if var existing = byIdentity[candidate.canonicalIdentity] {
                existing.queryRanges.append(contentsOf: candidate.queryRanges)
                existing.queryRanges = Dictionary(grouping: existing.queryRanges, by: \.queryID)
                    .values.compactMap(\.first).sorted { Self.utf8Less($0.queryID, $1.queryID) }
                existing.queryIndices.append(contentsOf: candidate.queryIndices)
                existing.queryIndices = Array(Set(existing.queryIndices)).sorted()
                existing.beforeLines = max(existing.beforeLines, candidate.beforeLines)
                existing.afterLines = max(existing.afterLines, candidate.afterLines)
                byIdentity[candidate.canonicalIdentity] = existing
            } else {
                byIdentity[candidate.canonicalIdentity] = candidate
            }
        }
        return Array(byIdentity.values)
    }

    private func attachContextBlocks(to candidates: inout [Candidate]) throws {
        let grouped = Dictionary(grouping: candidates.indices.filter { candidates[$0].byteRange != nil }) {
            candidates[$0].path
        }
        for (_, indices) in grouped {
            guard let firstIndex = indices.first else { continue }
            let data = try Data(contentsOf: candidates[firstIndex].fileURL, options: .mappedIfSafe)
            guard String(data: data, encoding: .utf8) != nil else {
                throw SearchContextServiceError.notTextFile(candidates[firstIndex].path)
            }
            let starts = lineStarts(data)
            var windows: [(index: Int, start: Int, end: Int)] = []
            for index in indices {
                guard let line = candidates[index].line else { continue }
                let startLine = max(1, line - candidates[index].beforeLines)
                let endLine = min(starts.count, line + candidates[index].afterLines)
                let start = starts[startLine - 1]
                let end = endLine < starts.count ? starts[endLine] : data.count
                windows.append((index, start, end))
            }
            windows.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
            var groups: [[(index: Int, start: Int, end: Int)]] = []
            for window in windows {
                if let last = groups.indices.last,
                   window.start <= (groups[last].map(\.end).max() ?? -1) {
                    groups[last].append(window)
                } else { groups.append([window]) }
            }
            for group in groups {
                let start = group.map(\.start).min() ?? 0
                let end = group.map(\.end).max() ?? start
                let id = Self.sha256(Data("\(candidates[firstIndex].fileIdentity):\(start):\(end)".utf8))
                for window in group { candidates[window.index].contextBlockID = id }
            }
        }
    }

    private func makeContextBlocks(for candidates: [Candidate]) throws -> [String: SearchContextBlock] {
        var result: [String: SearchContextBlock] = [:]
        for candidate in candidates {
            guard let id = candidate.contextBlockID, result[id] == nil,
                  let line = candidate.line else { continue }
            let data = try Data(contentsOf: candidate.fileURL, options: .mappedIfSafe)
            let starts = lineStarts(data)
            let related = candidates.filter { $0.contextBlockID == id }
            let startLine = related.compactMap(\.line).enumerated().map { offset, value in
                max(1, value - related[offset].beforeLines)
            }.min() ?? line
            let endLine = related.compactMap(\.line).enumerated().map { offset, value in
                min(starts.count, value + related[offset].afterLines)
            }.max() ?? line
            let start = starts[startLine - 1]
            let end = endLine < starts.count ? starts[endLine] : data.count
            guard let text = String(data: data[start..<end], encoding: .utf8) else {
                throw SearchContextServiceError.notTextFile(candidate.path)
            }
            result[id] = SearchContextBlock(
                kind: "contextBlock", id: id, path: candidate.path,
                byteRange: .init(start: start, end: end),
                startLine: startLine, endLine: endLine,
                text: text
            )
        }
        return result
    }

    private func compare(
        _ lhs: Candidate,
        _ rhs: Candidate,
        ranking: [SearchContextRanking],
        environment: SearchContextEnvironment
    ) -> Bool {
        for criterion in ranking {
            let left: Bool
            let right: Bool
            switch criterion {
            case .changed:
                left = environment.changedPaths.contains(lhs.path)
                right = environment.changedPaths.contains(rhs.path)
            case .tests:
                left = environment.testPaths.contains(lhs.path)
                right = environment.testPaths.contains(rhs.path)
            }
            if left != right { return left && !right }
        }
        let leftQuery = lhs.queryIndices.min() ?? Int.max
        let rightQuery = rhs.queryIndices.min() ?? Int.max
        if leftQuery != rightQuery { return leftQuery < rightQuery }
        if lhs.path != rhs.path { return Self.utf8Less(lhs.path, rhs.path) }
        let leftRange = lhs.byteRange ?? .init(start: 0, end: 0)
        let rightRange = rhs.byteRange ?? .init(start: 0, end: 0)
        if leftRange.start != rightRange.start { return leftRange.start < rightRange.start }
        return leftRange.end < rightRange.end
    }

    private func page(snapshot: Snapshot, offset: Int) async throws -> SearchContextResultV2 {
        var matches: [SearchContextMatchV2] = []
        var blocks: [SearchContextBlock] = []
        var oversized: [SearchContextOversizedDescriptor] = []
        var returnedBytes = 0
        var index = offset
        while index < snapshot.bundles.count, matches.count + oversized.count < snapshot.maxResults {
            let bundle = snapshot.bundles[index]
            if returnedBytes + bundle.data.count <= snapshot.byteBudget {
                if let block = bundle.block { blocks.append(block) }
                matches.append(bundle.match)
                returnedBytes += bundle.data.count
                index += 1
                continue
            }
            if returnedBytes > 0 { break }
            let artifact: ArtifactMetadata
            do {
                artifact = try await evidenceStore.store(
                    data: bundle.data,
                    kind: "search-context-oversized.v2",
                    producer: "SearchContextService",
                    retentionSeconds: retentionSeconds
                )
            } catch {
                throw SearchContextServiceError.artifactStoreFailed(String(describing: error))
            }
            let descriptor = SearchContextOversizedDescriptor(
                kind: "oversized",
                reason: bundle.data.count > 1_048_576 ? "maximum_budget_exceeded" : "request_budget_exceeded",
                canonicalIdentity: bundle.match.canonicalIdentity,
                pathDigest: bundle.match.pathDigest,
                byteRange: bundle.match.byteRange,
                requiredBytes: bundle.data.count,
                artifactHandle: artifact.handle,
                artifactSHA256: artifact.sha256,
                artifactSizeBytes: artifact.sizeBytes,
                expiresAt: artifact.expiresAt
            )
            let descriptorData = try Self.canonicalRecord(descriptor)
            guard descriptorData.count <= 512, descriptorData.count <= snapshot.byteBudget else {
                throw SearchContextServiceError.resultEncodingFailed("oversized descriptor does not fit its bounded record")
            }
            oversized.append(descriptor)
            returnedBytes += descriptorData.count
            index += 1
        }
        let remaining = snapshot.bundles[index...]
        let omittedBytes = remaining.reduce(0) { $0 + $1.data.count }
        let hasMore = index < snapshot.bundles.count
        return SearchContextResultV2(
            schema: "aishell.search-context.v2",
            provider: "rg-json-v1",
            scanMode: "live_rg",
            matches: matches,
            contextBlocks: blocks,
            oversizedDescriptors: oversized,
            returnedMatches: matches.count + oversized.count,
            omittedMatches: snapshot.bundles.count - index,
            returnedBytes: returnedBytes,
            omittedBytes: omittedBytes,
            hasMore: hasMore,
            continuation: hasMore ? try encodeToken(.init(snapshotID: snapshot.id, offset: index)) : nil,
            evidence: snapshot.evidence,
            freshness: snapshot.freshness,
            rankingEvidence: snapshot.rankingEvidence
        )
    }

    private func publicMatch(_ candidate: Candidate) -> SearchContextMatchV2 {
        SearchContextMatchV2(
            kind: "match",
            canonicalIdentity: candidate.canonicalIdentity,
            path: candidate.path,
            pathDigest: candidate.pathDigest,
            byteRange: candidate.byteRange,
            line: candidate.line,
            columnBytes: candidate.columnBytes,
            text: candidate.text,
            queryIDs: candidate.queryRanges.map(\.queryID).sorted(by: Self.utf8Less),
            queryRanges: candidate.queryRanges.sorted { Self.utf8Less($0.queryID, $1.queryID) },
            contextBlockID: candidate.contextBlockID
        )
    }

    private func canonicalBundle(match: SearchContextMatchV2, block: SearchContextBlock?) throws -> Data {
        var data = Data()
        if let block { data.append(try Self.canonicalRecord(block)) }
        data.append(try Self.canonicalRecord(match))
        return data
    }

    private func canonicalIdentity(
        kind: String,
        path: String,
        fileIdentity: String,
        contentSHA: String?,
        range: SearchContextByteRange?,
        rootIdentity: String
    ) throws -> (digest: String, descriptor: Data) {
        var descriptor: [String: Any] = [
            "schema": "aishell.search-match-identity.v1",
            "kind": kind,
            "path": path,
            "file_identity": fileIdentity,
            "root_identity": rootIdentity
        ]
        if let contentSHA, let range {
            descriptor["content_sha256"] = contentSHA
            descriptor["byte_start"] = range.start
            descriptor["byte_end"] = range.end
        }
        let data = try Self.canonicalJSON(descriptor)
        return (Self.sha256(data), data)
    }

    private func encodeToken(_ payload: TokenPayload) throws -> String {
        let data = try Self.canonicalEncodable(payload)
        let body = data.base64EncodedString()
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: tokenKey)
        return "search2.\(body).\(Data(mac).base64EncodedString())"
    }

    private func decodeToken(_ token: String) throws -> TokenPayload {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "search2",
              let data = Data(base64Encoded: String(parts[1])),
              let supplied = Data(base64Encoded: String(parts[2])) else {
            throw SearchContextServiceError.cursorExpired(reason: "malformed")
        }
        let expected = Data(HMAC<SHA256>.authenticationCode(for: data, using: tokenKey))
        guard expected == supplied else {
            throw SearchContextServiceError.cursorExpired(reason: "integrity_mismatch")
        }
        do { return try JSONDecoder().decode(TokenPayload.self, from: data) }
        catch { throw SearchContextServiceError.cursorExpired(reason: "malformed") }
    }

    private func discardExpiredSnapshots() {
        let now = clock()
        snapshots = snapshots.filter { now <= $0.value.expiresAt }
    }

    private func effectiveRoot(containing scope: URL) throws -> URL {
        let values = try scope.resourceValues(forKeys: [.isDirectoryKey])
        return values.isDirectory == true ? scope : scope.deletingLastPathComponent()
    }

    private func selectedCaseMode(for query: SearchContextQueryV2) -> SearchContextCaseMode {
        guard query.caseMode == .smart else { return query.caseMode }
        return query.pattern.unicodeScalars.contains(where: CharacterSet.uppercaseLetters.contains)
            ? .sensitive : .insensitive
    }

    private func inspectRegularFile(_ url: URL) throws -> (identity: String, sha256: String, data: Data) {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SearchContextServiceError.rescanRequired("index candidate is not a regular file: \(url.path)")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return (try fileIdentity(url), Self.sha256(data), data)
    }

    private func fileIdentity(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return "\(device):\(inode)"
    }

    private func isContained(_ target: URL, in root: URL) -> Bool {
        let targetComponents = target.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        return targetComponents.count >= rootComponents.count
            && Array(targetComponents.prefix(rootComponents.count)) == rootComponents
    }

    private func lineStarts(_ data: Data) -> [Int] {
        var starts = [0]
        for (index, byte) in data.enumerated() where byte == 0x0A && index + 1 < data.count {
            starts.append(index + 1)
        }
        return starts
    }

    private static func canonicalRecord<T: Encodable>(_ value: T) throws -> Data {
        var data = try canonicalEncodable(value)
        data.append(0x0A)
        return data
    }

    private static func canonicalEncodable<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do { return try encoder.encode(value) }
        catch { throw SearchContextServiceError.resultEncodingFailed(String(describing: error)) }
    }

    private static func canonicalJSON(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw SearchContextServiceError.resultEncodingFailed("non-JSON value")
        }
        do { return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) }
        catch { throw SearchContextServiceError.resultEncodingFailed(String(describing: error)) }
    }

    private static func jsonObject(_ data: Data) throws -> Any {
        do { return try JSONSerialization.jsonObject(with: data) }
        catch { throw SearchContextServiceError.resultEncodingFailed(String(describing: error)) }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func digestStrings(_ strings: Set<String>) -> String {
        let joined = strings.sorted(by: utf8Less).joined(separator: "\n")
        return sha256(Data(joined.utf8))
    }

    private static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func findRGExecutable() throws -> URL {
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] + pathEntries {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("rg")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw SearchContextServiceError.workerUnavailable("rg")
    }
}

private struct GlobMatcher: Sendable {
    private let expression: NSRegularExpression

    init(pattern: String) throws {
        guard !pattern.isEmpty, !pattern.hasPrefix("/"), !pattern.contains("\0") else {
            throw SearchContextServiceError.invalidArgument("invalid anchored glob")
        }
        let segments = pattern.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SearchContextServiceError.invalidArgument("glob contains an empty/dot segment")
        }
        var regex = "^"
        var separatorAlreadyProvided = false
        for (index, segment) in segments.enumerated() {
            if segment == "**" {
                if index == 0 {
                    regex += index == segments.count - 1 ? ".*" : "(?:[^/]+/)*"
                } else {
                    regex += index == segments.count - 1 ? "/.*" : "/(?:[^/]+/)*"
                }
                separatorAlreadyProvided = index != segments.count - 1
                continue
            }
            if index > 0, !separatorAlreadyProvided { regex += "/" }
            regex += try Self.compileSegment(segment)
            separatorAlreadyProvided = false
        }
        regex += "$"
        expression = try NSRegularExpression(pattern: regex)
    }

    func matches(_ path: String) -> Bool {
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return expression.firstMatch(in: path, range: range)?.range == range
    }

    private static func compileSegment(_ segment: String) throws -> String {
        let scalars = Array(segment.unicodeScalars)
        var result = ""
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case "*":
                if index + 1 < scalars.count, scalars[index + 1] == "*" {
                    throw SearchContextServiceError.invalidArgument("** must be a complete segment")
                }
                result += "[^/]*"
            case "?": result += "[^/]"
            case "[":
                guard let close = scalars[(index + 1)...].firstIndex(of: "]"), close > index + 1 else {
                    throw SearchContextServiceError.invalidArgument("unclosed or empty character class")
                }
                var body = String(String.UnicodeScalarView(scalars[(index + 1)..<close]))
                if body.first == "!" { body.removeFirst(); body = "^" + body }
                guard !body.isEmpty else { throw SearchContextServiceError.invalidArgument("empty character class") }
                result += "[\(body)]"
                index = close
            case "\\":
                guard index + 1 < scalars.count else { throw SearchContextServiceError.invalidArgument("trailing glob escape") }
                let escaped = scalars[index + 1]
                guard "*?[]!-\\".unicodeScalars.contains(escaped) else {
                    throw SearchContextServiceError.invalidArgument("unsupported glob escape")
                }
                result += NSRegularExpression.escapedPattern(for: String(escaped))
                index += 1
            default:
                result += NSRegularExpression.escapedPattern(for: String(scalar))
            }
            index += 1
        }
        return result
    }
}
