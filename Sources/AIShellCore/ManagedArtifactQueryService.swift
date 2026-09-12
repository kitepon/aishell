import CryptoKit
import Foundation

public enum ManagedArtifactQuerySource: Sendable, Equatable {
    case artifact(handle: String)
    case run(id: UUID, channels: Set<String>)
}

public enum ManagedArtifactQueryError: Error, Equatable, Sendable {
    case invalidProjectPath
    case invalidSource
    case invalidChannel(String)
}

public struct ManagedArtifactQueryItem: Codable, Equatable, Sendable {
    public let kind: String
    public let sourceID: String
    public let sourceKind: String?
    public let offset: Int
    public let line: Int?
    public let text: String?
    public let fullByteCount: Int?
    public let contentSHA256: String?
    public let artifactRange: String?
}

public struct ManagedArtifactQueryPage: Codable, Equatable, Sendable {
    public let schema: String
    public let action: String
    public let projectID: String?
    public let streamHandle: String
    public let items: [ManagedArtifactQueryItem]
    public let nextCursor: String?
    public let hasMore: Bool
}

public struct ManagedArtifactComparison: Codable, Equatable, Sendable {
    public let channel: String
    public let baselineHandle: String
    public let candidateHandle: String
    public let baselineSHA256: String
    public let baselineSizeBytes: Int
    public let candidateSHA256: String
    public let candidateSizeBytes: Int
    public let artifactsEqual: Bool
    public let bindingEqual: Bool
    public let missingOnBaseline: [String]
    public let missingOnCandidate: [String]
    public let changedBindings: [String]
}

public struct ManagedArtifactCompareResult: Codable, Equatable, Sendable {
    public let schema: String
    public let action: String
    public let projectID: String
    public let baselineRunID: UUID
    public let candidateRunID: UUID
    public let comparisons: [ManagedArtifactComparison]
}

/// terminal run indexだけをquery engineへ接続するproduction seam。
/// live spoolやlegacy unbound artifactを横断queryへ暗黙昇格しない。
public actor ManagedArtifactQueryService {
    private let store: ManagedRunArtifactStore
    private let engine: ArtifactQueryService
    private var streamProjects: [String: String] = [:]

    public init(store: ManagedRunArtifactStore, engine: ArtifactQueryService = ArtifactQueryService()) {
        self.store = store
        self.engine = engine
    }

    public func search(
        projectPath: String,
        sources: [ManagedArtifactQuerySource],
        pattern: ArtifactQueryService.Pattern,
        pageByteLimit: Int = ArtifactQueryService.maximumPageBytes
    ) async throws -> ManagedArtifactQueryPage {
        guard (1 ... 64).contains(sources.count) else { throw ManagedArtifactQueryError.invalidSource }
        let projectID = try Self.projectID(path: projectPath)
        var artifacts: [ArtifactQueryService.Artifact] = []
        for source in sources {
            switch source {
            case let .artifact(handle):
                artifacts.append(try await store.queryArtifact(handle: handle, projectID: projectID))
            case let .run(id, channels):
                try Self.validate(channels: channels)
                artifacts.append(contentsOf: try await store.queryArtifacts(
                    runID: id, channels: channels, projectID: projectID
                ))
            }
        }
        let page = try await engine.start(.init(pattern: pattern, pageByteLimit: pageByteLimit), sources: artifacts)
        streamProjects[page.streamHandle] = projectID
        return Self.page(page, projectID: projectID)
    }

    public func next(
        streamHandle: String,
        cursor: String,
        pageByteLimit: Int = ArtifactQueryService.maximumPageBytes
    ) async throws -> ManagedArtifactQueryPage {
        let page = try await engine.next(
                streamHandle: streamHandle, cursor: cursor, pageByteLimit: pageByteLimit
            )
        return Self.page(page, projectID: streamProjects[streamHandle])
    }

    public func compare(
        projectPath: String,
        baselineRunID: UUID,
        candidateRunID: UUID,
        channels: Set<String>
    ) async throws -> ManagedArtifactCompareResult {
        try Self.validate(channels: channels)
        let projectID = try Self.projectID(path: projectPath)
        let baseline = try await store.queryArtifacts(
            runID: baselineRunID, channels: channels, projectID: projectID
        )
        let candidate = try await store.queryArtifacts(
            runID: candidateRunID, channels: channels, projectID: projectID
        )
        let byKind = Dictionary(uniqueKeysWithValues: candidate.map { ($0.kind, $0) })
        var comparisons: [ManagedArtifactComparison] = []
        for left in baseline {
            guard let right = byKind[left.kind] else { throw ManagedArtifactQueryError.invalidSource }
            let result = await engine.compareHistory(baseline: left, candidate: right)
            let bindingEqual: Bool
            let missingLeft: [String]
            let missingRight: [String]
            let changed: [String]
            switch result.binding {
            case .equal:
                bindingEqual = true; missingLeft = []; missingRight = []; changed = []
            case let .different(left, right, differences):
                bindingEqual = false; missingLeft = left; missingRight = right; changed = differences
            }
            comparisons.append(ManagedArtifactComparison(
                channel: left.kind,
                baselineHandle: left.id,
                candidateHandle: right.id,
                baselineSHA256: result.baseline.sha256,
                baselineSizeBytes: result.baseline.sizeBytes,
                candidateSHA256: result.candidate.sha256,
                candidateSizeBytes: result.candidate.sizeBytes,
                artifactsEqual: result.artifactsEqual,
                bindingEqual: bindingEqual,
                missingOnBaseline: missingLeft,
                missingOnCandidate: missingRight,
                changedBindings: changed
            ))
        }
        return ManagedArtifactCompareResult(
            schema: "aishell.artifact-read.v2",
            action: "compare",
            projectID: projectID,
            baselineRunID: baselineRunID,
            candidateRunID: candidateRunID,
            comparisons: comparisons
        )
    }

    public nonisolated static func projectID(path: String) throws -> String {
        let url = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard url.path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw ManagedArtifactQueryError.invalidProjectPath }
        return SHA256.hash(data: Data(url.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func validate(channels: Set<String>) throws {
        guard !channels.isEmpty else { throw ManagedArtifactQueryError.invalidSource }
        for channel in channels where !["stdout", "stderr", "diagnostics"].contains(channel) {
            throw ManagedArtifactQueryError.invalidChannel(channel)
        }
    }

    private nonisolated static func page(
        _ page: ArtifactQueryService.Page,
        projectID: String?
    ) -> ManagedArtifactQueryPage {
        ManagedArtifactQueryPage(
            schema: "aishell.artifact-read.v2",
            action: "search",
            projectID: projectID,
            streamHandle: page.streamHandle,
            items: page.items.map {
                switch $0 {
                case let .match(sourceID, kind, offset, line, text):
                    return .init(
                        kind: "match", sourceID: sourceID, sourceKind: kind,
                        offset: offset, line: line, text: text,
                        fullByteCount: nil, contentSHA256: nil, artifactRange: nil
                    )
                case let .oversizeDescriptor(value):
                    return .init(
                        kind: "oversize_descriptor", sourceID: value.sourceID,
                        sourceKind: nil, offset: value.offset, line: nil, text: nil,
                        fullByteCount: value.fullByteCount,
                        contentSHA256: value.contentSHA256,
                        artifactRange: value.artifactRange
                    )
                }
            },
            nextCursor: page.nextCursor,
            hasMore: page.hasMore
        )
    }
}
