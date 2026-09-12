import CryptoKit
import Foundation

public struct SemanticSearchContextQuery: Codable, Equatable, Sendable {
    public let id: String
    public let pattern: String
    public let operation: SourceKitLSPOperation
    public let path: String?
    public let line: Int?
    public let character: Int?

    public init(
        id: String,
        pattern: String,
        operation: SourceKitLSPOperation,
        path: String? = nil,
        line: Int? = nil,
        character: Int? = nil
    ) {
        self.id = id
        self.pattern = pattern
        self.operation = operation
        self.path = path
        self.line = line
        self.character = character
    }
}

public struct SemanticSearchContextRequest: Codable, Equatable, Sendable {
    public let path: String?
    public let queries: [SemanticSearchContextQuery]
    public let provider: String
    public let cursor: String
    public let maxResults: Int
    public let byteBudget: Int

    public init(
        path: String? = nil,
        queries: [SemanticSearchContextQuery],
        provider: String,
        cursor: String,
        maxResults: Int = 50,
        byteBudget: Int = 65_536
    ) {
        self.path = path
        self.queries = queries
        self.provider = provider
        self.cursor = cursor
        self.maxResults = maxResults
        self.byteBudget = byteBudget
    }
}

/// SourceKit-LSPの結果だけを公開search_context v2へ投影する。
/// symbol位置の特定はprovider requestを作るためのanchor解決であり、検索結果のlexical代替には使わない。
public actor SemanticSearchContextService {
    private let runtimeStore: RuntimeStore
    private let workspaceRuntime: WorkspaceStateRuntime
    private let evidenceStore: EvidenceStore
    private let sourceKit: SourceKitLSPService

    public init(
        runtimeStore: RuntimeStore,
        workspaceRuntime: WorkspaceStateRuntime,
        evidenceStore: EvidenceStore,
        sourceKit: SourceKitLSPService? = nil
    ) {
        self.runtimeStore = runtimeStore
        self.workspaceRuntime = workspaceRuntime
        self.evidenceStore = evidenceStore
        self.sourceKit = sourceKit ?? SourceKitLSPService(
            runtimeStore: runtimeStore,
            workspaceRuntime: workspaceRuntime
        )
    }

    public func search(_ request: SemanticSearchContextRequest) async throws -> SearchContextResultV2 {
        guard request.provider == "sourcekit-lsp" else {
            throw SearchContextServiceError.workerUnavailable("semantic provider is not registered: \(request.provider)")
        }
        guard (1...32).contains(request.queries.count),
              Set(request.queries.map(\.id)).count == request.queries.count,
              request.queries.allSatisfy({ !$0.id.isEmpty && !$0.pattern.isEmpty }) else {
            throw SearchContextServiceError.invalidArgument("semantic queries must contain 1...32 unique non-empty entries")
        }
        guard (1...500).contains(request.maxResults), (1_024...1_048_576).contains(request.byteBudget) else {
            throw SearchContextServiceError.invalidArgument("semantic limits are outside the supported range")
        }

        let resolver = await runtimeStore.pathResolver()
        let root = try resolver.resolveExisting(request.path)
        let environment = try await workspaceRuntime.searchContextObservation(
            path: root.path,
            fromCursor: request.cursor
        )

        var providerResults: [(query: SemanticSearchContextQuery, result: SourceKitLSPResult)] = []
        if environment.changedPaths.isEmpty {
            for query in request.queries {
                guard let anchor = try resolveAnchor(query, root: root, indexedFiles: environment.indexedFiles ?? []) else {
                    providerResults.append((query, .init(
                        status: .unavailable,
                        operation: query.operation,
                        observedCursor: environment.workspaceCursor,
                        locations: [],
                        reason: "semantic_symbol_anchor_not_found"
                    )))
                    continue
                }
                providerResults.append((query, try await sourceKit.query(.init(
                    root: root,
                    workspaceCursor: request.cursor,
                    path: anchor.path,
                    contentSHA256: anchor.sha256,
                    operation: query.operation,
                    symbol: normalizedSymbol(query.pattern),
                    line: anchor.line,
                    character: anchor.character
                ))))
            }
        } else {
            providerResults = request.queries.map { query in
                (query, .init(
                    status: .stale,
                    operation: query.operation,
                    observedCursor: environment.workspaceCursor,
                    locations: [],
                    reason: "workspace_changed_since_semantic_cursor"
                ))
            }
        }

        let status = combinedStatus(providerResults.map(\.result.status))
        let allLocations = providerResults.flatMap { item in
            item.result.locations.map { (queryID: item.query.id, location: $0) }
        }
        let limited = Array(allLocations.prefix(request.maxResults))
        let matches = limited.map { item -> SearchContextMatchV2 in
            let identityMaterial = "sourcekit-lsp\u{0}\(item.location.path)\u{0}\(item.location.line)\u{0}\(item.location.character)\u{0}\(item.location.contentSHA256)"
            return SearchContextMatchV2(
                kind: "semantic",
                canonicalIdentity: Self.sha256(Data(identityMaterial.utf8)),
                path: item.location.path,
                pathDigest: Self.sha256(Data(item.location.path.utf8)),
                byteRange: nil,
                line: item.location.line,
                columnBytes: item.location.character,
                text: nil,
                queryIDs: [item.queryID],
                queryRanges: [],
                contextBlockID: nil
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let evidenceData = try encoder.encode(providerResults.map { SemanticEvidence(query: $0.query, result: $0.result) })
        let evidence = try await evidenceStore.store(
            data: evidenceData,
            kind: "search-context-semantic-evidence.v1",
            producer: "SemanticSearchContextService"
        )
        let returnedBytes = try encoder.encode(matches).count
        let omitted = max(0, allLocations.count - matches.count)
        let providerDigest = Self.sha256(evidenceData)
        let freshness = SearchContextFreshness(
            effectiveRootIdentity: environment.effectiveRootIdentity,
            effectiveRootPolicyDigest: environment.effectiveRootPolicyDigest,
            searchScope: root.path,
            workspaceCursor: environment.workspaceCursor,
            observedFrom: environment.observedFrom,
            observedThrough: environment.observedThrough,
            state: status.rawValue,
            providerEvidenceDigest: providerDigest
        )
        let ranking = SearchContextRankingEvidence(
            applied: [],
            workspaceCursor: environment.workspaceCursor,
            observationViewID: environment.observationViewID,
            fromCursor: environment.observedFrom,
            throughCursor: environment.observedThrough,
            changedSetDigest: Self.sha256(Data(environment.changedPaths.sorted().joined(separator: "\u{0}").utf8)),
            projectProfileDigest: environment.projectProfileDigest,
            testClassification: environment.testClassification
        )
        return SearchContextResultV2(
            schema: "aishell.search-context.v2",
            provider: request.provider,
            scanMode: "semantic_provider",
            matches: matches,
            contextBlocks: [],
            oversizedDescriptors: [],
            returnedMatches: matches.count,
            omittedMatches: omitted,
            returnedBytes: returnedBytes,
            omittedBytes: 0,
            hasMore: omitted > 0,
            continuation: nil,
            evidence: evidence,
            freshness: freshness,
            rankingEvidence: ranking
        )
    }

    private struct Anchor {
        let path: String
        let sha256: String
        let line: Int
        let character: Int
    }

    private struct SemanticEvidence: Codable {
        let query: SemanticSearchContextQuery
        let result: SourceKitLSPResult
    }

    private func resolveAnchor(
        _ query: SemanticSearchContextQuery,
        root: URL,
        indexedFiles: [SearchContextIndexedFile]
    ) throws -> Anchor? {
        let symbol = normalizedSymbol(query.pattern)
        let candidates = query.path.map { requested in
            indexedFiles.filter { $0.path == requested }
        } ?? indexedFiles.filter { $0.path.hasSuffix(".swift") }
        for indexed in candidates.sorted(by: { $0.path < $1.path }) {
            let url = root.appendingPathComponent(indexed.path)
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard Self.sha256(data) == indexed.contentSHA256,
                  let text = String(data: data, encoding: .utf8),
                  let range = text.range(of: symbol) else { continue }
            let prefix = text[..<range.lowerBound]
            let line = prefix.reduce(into: 0) { if $1 == "\n" { $0 += 1 } }
            let lineStart = prefix.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            let character = text[lineStart..<range.lowerBound].utf16.count
            return Anchor(
                path: indexed.path,
                sha256: indexed.contentSHA256,
                line: query.line ?? line,
                character: query.character ?? character
            )
        }
        return nil
    }

    private func normalizedSymbol(_ pattern: String) -> String {
        pattern.split(separator: ":", maxSplits: 1).last.map(String.init) ?? pattern
    }

    private func combinedStatus(_ statuses: [SourceKitLSPStatus]) -> SourceKitLSPStatus {
        if statuses.contains(.stale) { return .stale }
        if statuses.contains(.indexing) { return .indexing }
        if statuses.contains(.unavailable) { return .unavailable }
        return .fresh
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
