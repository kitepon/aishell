import CryptoKit
import Darwin
import Foundation

public enum ChangeImpactOperation: String, Codable, Equatable, Sendable {
    case analyze
    case recommend
}

public struct ChangeImpactChangedPath: Codable, Equatable, Sendable {
    public let path: String
    public let contentSHA256: String?
    public let expectedAbsent: Bool

    public init(path: String, contentSHA256: String? = nil, expectedAbsent: Bool = false) {
        self.path = path
        self.contentSHA256 = contentSHA256
        self.expectedAbsent = expectedAbsent
    }
}

public struct ChangeImpactChangedSymbol: Codable, Equatable, Sendable {
    public let path: String
    public let contentSHA256: String
    public let name: String
    public let startOffset: Int
    public let endOffset: Int
    public let stableID: String?

    public init(
        path: String,
        contentSHA256: String,
        name: String,
        startOffset: Int,
        endOffset: Int,
        stableID: String? = nil
    ) {
        self.path = path
        self.contentSHA256 = contentSHA256
        self.name = name
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.stableID = stableID
    }
}

public struct ChangeImpactRequest: Codable, Equatable, Sendable {
    public let operation: ChangeImpactOperation?
    public let root: String?
    public let workspaceCursor: String?
    public let changedPaths: [ChangeImpactChangedPath]
    public let changedSymbols: [ChangeImpactChangedSymbol]
    public let requiredProviders: [String]
    public let byteBudget: Int?
    public let continuation: String?

    public init(
        operation: ChangeImpactOperation? = .analyze,
        root: String? = nil,
        workspaceCursor: String? = nil,
        changedPaths: [ChangeImpactChangedPath] = [],
        changedSymbols: [ChangeImpactChangedSymbol] = [],
        requiredProviders: [String] = [],
        byteBudget: Int? = nil,
        continuation: String? = nil
    ) {
        self.operation = operation
        self.root = root
        self.workspaceCursor = workspaceCursor
        self.changedPaths = changedPaths
        self.changedSymbols = changedSymbols
        self.requiredProviders = requiredProviders
        self.byteBudget = byteBudget
        self.continuation = continuation
    }
}

public enum ChangeImpactCategory: String, Codable, CaseIterable, Equatable, Sendable {
    case references
    case dependencies
    case relatedTests = "related_tests"
    case buildTargets = "build_targets"
}

public enum ChangeImpactSubjectKind: String, Codable, CaseIterable, Equatable, Sendable {
    case path
    case symbol
    case resource
    case module
    case package
    case test
    case target
}

public struct ChangeImpactSubject: Codable, Equatable, Sendable {
    public let kind: ChangeImpactSubjectKind
    public let path: String?
    public let name: String?
    public let startOffset: Int?
    public let endOffset: Int?
    public let stableID: String?
    public let ecosystemID: String?
    public let profileIdentity: String?
    public let manifestPath: String?
    public let declaredID: String?

    public init(
        kind: ChangeImpactSubjectKind,
        path: String? = nil,
        name: String? = nil,
        startOffset: Int? = nil,
        endOffset: Int? = nil,
        stableID: String? = nil,
        ecosystemID: String? = nil,
        profileIdentity: String? = nil,
        manifestPath: String? = nil,
        declaredID: String? = nil
    ) {
        self.kind = kind
        self.path = path
        self.name = name
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.stableID = stableID
        self.ecosystemID = ecosystemID
        self.profileIdentity = profileIdentity
        self.manifestPath = manifestPath
        self.declaredID = declaredID
    }

    public static func path(_ path: String) -> Self { .init(kind: .path, path: path) }
    public static func test(path: String) -> Self { .init(kind: .test, path: path) }
    public static func target(
        ecosystemID: String,
        profileIdentity: String,
        manifestPath: String,
        declaredID: String
    ) -> Self {
        .init(
            kind: .target,
            ecosystemID: ecosystemID,
            profileIdentity: profileIdentity,
            manifestPath: manifestPath,
            declaredID: declaredID
        )
    }
}

public enum ChangeImpactProviderKind: String, Codable, Equatable, Sendable {
    case workspaceIndex = "workspace_index"
    case projectProfile = "project_profile"
    case lexicalSearch = "lexical_search"
    case sourceKit = "sourcekit"
    case depfile
    case buildGraph = "build_graph"
    case custom
}

public enum ChangeImpactProviderStatus: String, Codable, Equatable, Sendable {
    case fresh
    case stale
    case unavailable
    case unsupported
}

public struct ChangeImpactProviderDescriptor: Codable, Equatable, Sendable {
    public let providerID: String
    public let kind: ChangeImpactProviderKind
    public let version: String

    public init(providerID: String, kind: ChangeImpactProviderKind, version: String) {
        self.providerID = providerID
        self.kind = kind
        self.version = version
    }
}

public struct ChangeImpactProviderReport: Codable, Equatable, Sendable {
    public let descriptor: ChangeImpactProviderDescriptor
    public let status: ChangeImpactProviderStatus
    public let inputDigest: String
    public let observedAtCursor: String
    public let reasonCode: String?
    public let nextAction: String?

    public init(
        descriptor: ChangeImpactProviderDescriptor,
        status: ChangeImpactProviderStatus,
        inputDigest: String,
        observedAtCursor: String,
        reasonCode: String? = nil,
        nextAction: String? = nil
    ) {
        self.descriptor = descriptor
        self.status = status
        self.inputDigest = inputDigest
        self.observedAtCursor = observedAtCursor
        self.reasonCode = reasonCode
        self.nextAction = nextAction
    }
}

public enum ChangeImpactRelation: String, Codable, Equatable, Sendable {
    case semanticReference = "semantic_reference"
    case lexicalReference = "lexical_reference"
    case declaredDependency = "declared_dependency"
    case containsSource = "contains_source"
    case containsTest = "contains_test"
    case namingHeuristic = "naming_heuristic"
}

public enum ChangeImpactEvidenceStrength: String, Codable, Equatable, Sendable {
    case heuristic
    case lexicalMatch = "lexical_match"
    case semanticMatch = "semantic_match"
    case declaredEdge = "declared_edge"
}

public struct ChangeImpactEvidenceLocator: Codable, Equatable, Sendable {
    public let path: String
    public let contentSHA256: String
    public let startOffset: Int?
    public let endOffset: Int?
    public let edgeID: String?

    public init(
        path: String,
        contentSHA256: String,
        startOffset: Int? = nil,
        endOffset: Int? = nil,
        edgeID: String? = nil
    ) {
        self.path = path
        self.contentSHA256 = contentSHA256
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.edgeID = edgeID
    }
}

public struct ChangeImpactCandidateSeed: Codable, Equatable, Sendable {
    public let category: ChangeImpactCategory
    public let subject: ChangeImpactSubject

    public init(category: ChangeImpactCategory, subject: ChangeImpactSubject) {
        self.category = category
        self.subject = subject
    }
}

public struct ChangeImpactEvidenceSeed: Codable, Equatable, Sendable {
    public let inputIdentity: String
    public let candidate: ChangeImpactCandidateSeed
    public let relation: ChangeImpactRelation
    public let locator: ChangeImpactEvidenceLocator
    public let strength: ChangeImpactEvidenceStrength
    public let summary: String

    public init(
        inputIdentity: String,
        candidate: ChangeImpactCandidateSeed,
        relation: ChangeImpactRelation,
        locator: ChangeImpactEvidenceLocator,
        strength: ChangeImpactEvidenceStrength,
        summary: String
    ) {
        self.inputIdentity = inputIdentity
        self.candidate = candidate
        self.relation = relation
        self.locator = locator
        self.strength = strength
        self.summary = summary
    }
}

public struct ChangeImpactFreshnessBinding: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Equatable, Sendable {
        case input
        case analysis
    }

    public let role: Role
    public let path: String
    public let contentSHA256: String?
    public let expectedAbsent: Bool

    public init(role: Role, path: String, contentSHA256: String?, expectedAbsent: Bool = false) {
        self.role = role
        self.path = path
        self.contentSHA256 = contentSHA256
        self.expectedAbsent = expectedAbsent
    }
}

public struct ChangeImpactCoverageGap: Codable, Equatable, Sendable {
    public let category: ChangeImpactCategory
    public let reasonCode: String
    public let providerID: String?
    public let subject: ChangeImpactSubject?
    public let nextAction: String

    public init(
        category: ChangeImpactCategory,
        reasonCode: String,
        providerID: String? = nil,
        subject: ChangeImpactSubject? = nil,
        nextAction: String
    ) {
        self.category = category
        self.reasonCode = reasonCode
        self.providerID = providerID
        self.subject = subject
        self.nextAction = nextAction
    }
}

public struct ChangeImpactProviderInput: Sendable {
    public let root: URL
    public let workspaceCursor: String
    public let changedPaths: [ChangeImpactChangedPath]
    public let changedSymbols: [ChangeImpactChangedSymbol]

    public init(
        root: URL,
        workspaceCursor: String,
        changedPaths: [ChangeImpactChangedPath],
        changedSymbols: [ChangeImpactChangedSymbol]
    ) {
        self.root = root
        self.workspaceCursor = workspaceCursor
        self.changedPaths = changedPaths
        self.changedSymbols = changedSymbols
    }
}

public struct ChangeImpactProviderOutput: Sendable {
    public let report: ChangeImpactProviderReport
    public let evidence: [ChangeImpactEvidenceSeed]
    public let freshnessBindings: [ChangeImpactFreshnessBinding]
    public let coverageGaps: [ChangeImpactCoverageGap]

    public init(
        report: ChangeImpactProviderReport,
        evidence: [ChangeImpactEvidenceSeed] = [],
        freshnessBindings: [ChangeImpactFreshnessBinding] = [],
        coverageGaps: [ChangeImpactCoverageGap] = []
    ) {
        self.report = report
        self.evidence = evidence
        self.freshnessBindings = freshnessBindings
        self.coverageGaps = coverageGaps
    }
}

public protocol ChangeImpactProvider: Sendable {
    var descriptor: ChangeImpactProviderDescriptor { get }
    func analyze(_ input: ChangeImpactProviderInput) async throws -> ChangeImpactProviderOutput
}

/// Phase 3の直接OS provider。indexやLSPへfallbackせず、現在のfile bytesだけから
/// lexical referenceと配置規約上のtest/target候補を生成する。
public struct FileSystemChangeImpactProvider: ChangeImpactProvider {
    public let descriptor = ChangeImpactProviderDescriptor(
        providerID: "aishell.filesystem-impact",
        kind: .lexicalSearch,
        version: "1"
    )

    public init() {}

    public func analyze(_ input: ChangeImpactProviderInput) async throws -> ChangeImpactProviderOutput {
        let files = try regularFiles(in: input.root)
        var bindings: [ChangeImpactFreshnessBinding] = []
        var evidence: [ChangeImpactEvidenceSeed] = []
        let changedPaths = Set(input.changedPaths.map(\.path))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        for file in files {
            let relative = relativePath(file, root: input.root)
            guard !changedPaths.contains(relative),
                  let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                  data.count <= 4 * 1_024 * 1_024,
                  String(data: data, encoding: .utf8) != nil else { continue }
            let sha = sha256(data)
            for symbol in input.changedSymbols {
                for range in lexicalRanges(of: Data(symbol.name.utf8), in: data) {
                    let candidate = ChangeImpactCandidateSeed(category: .references, subject: .path(relative))
                    evidence.append(ChangeImpactEvidenceSeed(
                        inputIdentity: symbolIdentity(symbol),
                        candidate: candidate,
                        relation: .lexicalReference,
                        locator: .init(
                            path: relative,
                            contentSHA256: sha,
                            startOffset: range.lowerBound,
                            endOffset: range.upperBound
                        ),
                        strength: .lexicalMatch,
                        summary: "\(symbol.name)のUTF-8 token一致"
                    ))
                }
            }
            let isTest = relative.hasPrefix("Tests/") || relative.contains("/Tests/")
                || relative.lowercased().contains(".test.")
            if isTest {
                for changed in input.changedPaths {
                    let changedStem = URL(fileURLWithPath: changed.path).deletingPathExtension()
                        .lastPathComponent.lowercased()
                    guard testFileName(file, matchesChangedStem: changedStem) else { continue }
                    let candidate = ChangeImpactCandidateSeed(category: .relatedTests, subject: .test(path: relative))
                    evidence.append(ChangeImpactEvidenceSeed(
                        inputIdentity: pathIdentity(changed),
                        candidate: candidate,
                        relation: .namingHeuristic,
                        locator: .init(path: relative, contentSHA256: sha),
                        strength: .heuristic,
                        summary: "test file名tokenが変更file名と一致"
                    ))
                }
            }
            // 非一致を判定するために読んだfileもprovider inputである。候補を生成したfileだけへ
            // bindingを狭めると、解析中の編集で新しい一致が生じた時にfalse-freshになる。
            bindings.append(.init(role: .analysis, path: relative, contentSHA256: sha))
        }

        for changed in input.changedPaths {
            let components = changed.path.split(separator: "/").map(String.init)
            guard components.count >= 2,
                  components[0] == "Sources" || components[0] == "Tests" else { continue }
            let manifest = input.root.appendingPathComponent("Package.swift")
            guard let manifestData = try? Data(contentsOf: manifest), !manifestData.isEmpty else { continue }
            let manifestSHA = sha256(manifestData)
            let targetID = components[1]
            let candidate = ChangeImpactCandidateSeed(
                category: .buildTargets,
                subject: .target(
                    ecosystemID: "swift-package-manager",
                    profileIdentity: manifestSHA,
                    manifestPath: "Package.swift",
                    declaredID: targetID
                )
            )
            evidence.append(ChangeImpactEvidenceSeed(
                inputIdentity: pathIdentity(changed),
                candidate: candidate,
                relation: components[0] == "Tests" ? .containsTest : .containsSource,
                locator: .init(
                    path: "Package.swift",
                    contentSHA256: manifestSHA,
                    edgeID: "\(components[0]):\(targetID)"
                ),
                strength: .declaredEdge,
                summary: "SwiftPM標準配置\(components[0])/\(targetID)"
            ))
            bindings.append(.init(role: .analysis, path: "Package.swift", contentSHA256: manifestSHA))
        }

        let bindingData = try encoder.encode(bindings)
        let inputDigest = sha256(try encoder.encode(input.changedPaths))
            + sha256(try encoder.encode(input.changedSymbols))
            + sha256(bindingData)
        return ChangeImpactProviderOutput(
            report: .init(
                descriptor: descriptor,
                status: .fresh,
                inputDigest: sha256(Data(inputDigest.utf8)),
                observedAtCursor: input.workspaceCursor
            ),
            evidence: evidence,
            freshnessBindings: bindings
        )
    }

    private func regularFiles(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else { throw AIShellError.invalidPath(root.path) }
        var result: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let relative = relativePath(url, root: root)
            if ReservedNamespacePolicy.shouldExclude(relativePath: relative) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= 4 * 1_024 * 1_024 else { continue }
            result.append(url)
        }
        return result.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    private func lexicalRanges(of token: Data, in data: Data) -> [Range<Int>] {
        guard !token.isEmpty, token.count <= data.count else { return [] }
        var result: [Range<Int>] = []
        var searchStart = data.startIndex
        while searchStart < data.endIndex,
              let range = data.range(of: token, options: [], in: searchStart..<data.endIndex) {
            let left = range.lowerBound == data.startIndex ? nil : data[data.index(before: range.lowerBound)]
            let right = range.upperBound == data.endIndex ? nil : data[range.upperBound]
            if !isIdentifierByte(left), !isIdentifierByte(right) {
                result.append(range.lowerBound..<range.upperBound)
            }
            searchStart = range.upperBound
        }
        return result
    }

    private func testFileName(_ file: URL, matchesChangedStem changedStem: String) -> Bool {
        guard !changedStem.isEmpty else { return false }
        let name = file.deletingPathExtension().lastPathComponent.lowercased()
        let tokens = name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if tokens.contains(changedStem) { return true }
        return ["test", "tests", "spec", "specs"].contains { name == changedStem + $0 }
    }

    private func isIdentifierByte(_ byte: UInt8?) -> Bool {
        guard let byte else { return false }
        return (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A)
            || byte == 0x5F
            || byte >= 0x80
    }

    private func relativePath(_ url: URL, root: URL) -> String {
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        return canonicalURL.pathComponents.dropFirst(canonicalRoot.pathComponents.count).joined(separator: "/")
    }

    private func pathIdentity(_ value: ChangeImpactChangedPath) -> String {
        tuple(["input_path", value.path, value.expectedAbsent ? "1" : "0", value.contentSHA256 ?? ""])
    }

    private func symbolIdentity(_ value: ChangeImpactChangedSymbol) -> String {
        tuple([
            "input_symbol", value.path, String(value.startOffset), String(value.endOffset),
            value.name, value.stableID ?? "", value.contentSHA256
        ])
    }

    private func tuple(_ values: [String]) -> String {
        values.map { "\(Data($0.utf8).count):\($0)" }.joined()
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ChangeImpactItemKind: String, Codable, Equatable, Sendable {
    case inputPath = "input_path"
    case inputSymbol = "input_symbol"
    case requiredProvider = "required_provider"
    case freshnessBinding = "freshness_binding"
    case providerReport = "provider_report"
    case coverageGap = "coverage_gap"
    case candidate
    case evidence
    case candidateEvidence = "candidate_evidence"
}

public struct ChangeImpactItem: Codable, Equatable, Sendable {
    public let kind: ChangeImpactItemKind
    public let itemID: String
    public let changedPath: ChangeImpactChangedPath?
    public let changedSymbol: ChangeImpactChangedSymbol?
    public let providerID: String?
    public let freshnessBinding: ChangeImpactFreshnessBinding?
    public let providerReport: ChangeImpactProviderReport?
    public let coverageGap: ChangeImpactCoverageGap?
    public let candidateID: String?
    public let category: ChangeImpactCategory?
    public let subject: ChangeImpactSubject?
    public let evidenceID: String?
    public let inputIdentity: String?
    public let relation: ChangeImpactRelation?
    public let locator: ChangeImpactEvidenceLocator?
    public let evidenceStrength: ChangeImpactEvidenceStrength?
    public let summary: String?

    init(
        kind: ChangeImpactItemKind,
        itemID: String,
        changedPath: ChangeImpactChangedPath? = nil,
        changedSymbol: ChangeImpactChangedSymbol? = nil,
        providerID: String? = nil,
        freshnessBinding: ChangeImpactFreshnessBinding? = nil,
        providerReport: ChangeImpactProviderReport? = nil,
        coverageGap: ChangeImpactCoverageGap? = nil,
        candidateID: String? = nil,
        category: ChangeImpactCategory? = nil,
        subject: ChangeImpactSubject? = nil,
        evidenceID: String? = nil,
        inputIdentity: String? = nil,
        relation: ChangeImpactRelation? = nil,
        locator: ChangeImpactEvidenceLocator? = nil,
        evidenceStrength: ChangeImpactEvidenceStrength? = nil,
        summary: String? = nil
    ) {
        self.kind = kind
        self.itemID = itemID
        self.changedPath = changedPath
        self.changedSymbol = changedSymbol
        self.providerID = providerID
        self.freshnessBinding = freshnessBinding
        self.providerReport = providerReport
        self.coverageGap = coverageGap
        self.candidateID = candidateID
        self.category = category
        self.subject = subject
        self.evidenceID = evidenceID
        self.inputIdentity = inputIdentity
        self.relation = relation
        self.locator = locator
        self.evidenceStrength = evidenceStrength
        self.summary = summary
    }
}

public struct ChangeImpactFreshness: Codable, Equatable, Sendable {
    public let rootIdentity: String
    public let workspaceGeneration: String
    public let inputCursor: String
    public let observedCursor: String
    public let bindingDigest: String
    public let bindingCount: Int
}

public struct ChangeImpactCounts: Codable, Equatable, Sendable {
    public let references: Int
    public let dependencies: Int
    public let relatedTests: Int
    public let buildTargets: Int
}

public struct ChangeImpactResult: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let operation: ChangeImpactOperation
    public let coverage: String
    public let freshness: ChangeImpactFreshness
    public let counts: ChangeImpactCounts
    public let items: [ChangeImpactItem]
    public let returnedBytes: Int
    public let omittedBytes: Int
    public let hasMore: Bool
    public let continuation: String?
    public let artifact: ArtifactMetadata

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, operation, coverage, freshness, counts, items
        case returnedBytes, omittedBytes, hasMore, continuation, artifact
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(operation, forKey: .operation)
        try container.encode(coverage, forKey: .coverage)
        try container.encode(freshness, forKey: .freshness)
        try container.encode(counts, forKey: .counts)
        try container.encode(items, forKey: .items)
        try container.encode(returnedBytes, forKey: .returnedBytes)
        try container.encode(omittedBytes, forKey: .omittedBytes)
        try container.encode(hasMore, forKey: .hasMore)
        if let continuation {
            try container.encode(continuation, forKey: .continuation)
        } else {
            try container.encodeNil(forKey: .continuation)
        }
        try container.encode(artifact, forKey: .artifact)
    }
}

/// `recommend` 専用の入力。analyze の入力へ profile catalog を混ぜず、catalog の exact
/// identity を caller が明示的に束縛する。
public struct ChangeImpactRecommendationRequest: Sendable {
    public let impactRequest: ChangeImpactRequest?
    public let projectID: String?
    public let profileDigest: String?
    public let catalog: ProjectProfileCatalogResult?
    public let byteBudget: Int?
    public let continuation: String?

    public init(
        impactRequest: ChangeImpactRequest? = nil,
        projectID: String? = nil,
        profileDigest: String? = nil,
        catalog: ProjectProfileCatalogResult? = nil,
        byteBudget: Int? = nil,
        continuation: String? = nil
    ) {
        self.impactRequest = impactRequest; self.projectID = projectID
        self.profileDigest = profileDigest; self.catalog = catalog
        self.byteBudget = byteBudget; self.continuation = continuation
    }
}

public enum ChangeImpactRecommendationItemKind: String, Codable, Equatable, Sendable {
    case focusedCandidate = "focused_candidate"
    case focusedStep = "focused_step"
    case dependencyEdge = "dependency_edge"
    case manifestBinding = "manifest_binding"
    case impactEvidence = "impact_evidence"
    case coverageGap = "coverage_gap"
}

/// recommend stream の item。各 kind が必要とする identity/provenance は item 自身に残す。
public struct ChangeImpactRecommendationItem: Encodable, Equatable, Sendable {
    public let kind: ChangeImpactRecommendationItemKind
    public let itemID: String
    public let focusedCheckID: String?
    public let profileCheckID: String?
    public let profileDigest: String?
    public let selector: FocusedCheckService.Selector?
    public let step: FocusedCheckService.Step?
    public let dependsOn: String?
    public let manifest: ProjectProfileManifest?
    public let evidence: FocusedCheckService.Evidence?
    public let coverageGap: ChangeImpactCoverageGap?

    init(kind: ChangeImpactRecommendationItemKind, itemID: String, focusedCheckID: String? = nil,
         profileCheckID: String? = nil, profileDigest: String? = nil,
         selector: FocusedCheckService.Selector? = nil, step: FocusedCheckService.Step? = nil,
         dependsOn: String? = nil, manifest: ProjectProfileManifest? = nil,
         evidence: FocusedCheckService.Evidence? = nil, coverageGap: ChangeImpactCoverageGap? = nil) {
        self.kind = kind; self.itemID = itemID; self.focusedCheckID = focusedCheckID
        self.profileCheckID = profileCheckID; self.profileDigest = profileDigest; self.selector = selector
        self.step = step; self.dependsOn = dependsOn; self.manifest = manifest
        self.evidence = evidence; self.coverageGap = coverageGap
    }

    private enum CodingKeys: String, CodingKey { case kind, itemID, focusedCheckID, profileCheckID, profileDigest, selector, step, dependsOn, manifest, evidence, coverageGap }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind); try c.encode(itemID, forKey: .itemID)
        switch kind {
        case .focusedCandidate:
            try c.encode(focusedCheckID, forKey: .focusedCheckID); try c.encode(profileCheckID, forKey: .profileCheckID)
            try c.encode(profileDigest, forKey: .profileDigest); try c.encode(selector, forKey: .selector)
        case .focusedStep: try c.encode(focusedCheckID, forKey: .focusedCheckID); try c.encode(step, forKey: .step)
        case .dependencyEdge: try c.encode(focusedCheckID, forKey: .focusedCheckID); try c.encode(dependsOn, forKey: .dependsOn)
        case .manifestBinding: try c.encode(manifest, forKey: .manifest)
        case .impactEvidence: try c.encode(focusedCheckID, forKey: .focusedCheckID); try c.encode(evidence, forKey: .evidence)
        case .coverageGap: try c.encode(coverageGap, forKey: .coverageGap)
        }
    }
}

/// ADR 0020 raw recommend v2 の analyze と非共有な closed envelope。
public struct ChangeImpactRecommendationResult: Encodable, Equatable, Sendable {
    public let schema: String
    public let operation: ChangeImpactOperation
    public let executionPolicy: String
    public let focusedSetID: String
    public let focusedSetDigest: String
    public let expiresAt: Date
    public let freshness: ChangeImpactFreshness
    public let coverage: String
    public let candidateCount: Int
    public let stepCount: Int
    public let limitationCount: Int
    public let items: [ChangeImpactRecommendationItem]
    public let byteBudget: Int
    public let hasMore: Bool
    public let continuation: String?
    public let artifact: ArtifactMetadata

    private enum CodingKeys: String, CodingKey {
        case schema, operation, executionPolicy, focusedSetID, focusedSetDigest, expiresAt
        case freshness, coverage, candidateCount, stepCount, limitationCount, items
        case byteBudget, hasMore, continuation, artifact
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(operation, forKey: .operation)
        try container.encode(executionPolicy, forKey: .executionPolicy)
        try container.encode(focusedSetID, forKey: .focusedSetID)
        try container.encode(focusedSetDigest, forKey: .focusedSetDigest)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(freshness, forKey: .freshness)
        try container.encode(coverage, forKey: .coverage)
        try container.encode(candidateCount, forKey: .candidateCount)
        try container.encode(stepCount, forKey: .stepCount)
        try container.encode(limitationCount, forKey: .limitationCount)
        try container.encode(items, forKey: .items)
        try container.encode(byteBudget, forKey: .byteBudget)
        try container.encode(hasMore, forKey: .hasMore)
        if let continuation {
            try container.encode(continuation, forKey: .continuation)
        } else {
            try container.encodeNil(forKey: .continuation)
        }
        try container.encode(artifact, forKey: .artifact)
    }
}

/// opaque continuation を再開した結果。token の文字列表現ではなく、service が所有する
/// continuation registry の完全一致だけで operation を確定する。
public enum ChangeImpactContinuationResult: Sendable {
    case analyze(ChangeImpactResult)
    case recommend(ChangeImpactRecommendationResult)
}

public enum ChangeImpactError: Error, Equatable, Sendable {
    case invalidOperation
    case notReady(operation: ChangeImpactOperation, ownerTask: String)
    case invalidRequest(String)
    case requestTooLarge(String)
    case contentChanged(String)
    case requiredProviderNotFresh([String])
    case providerFailure(String)
    case resultItemTooLarge(Int)
    case byteBudgetTooSmall(requiredMinimumBytes: Int, continuation: String)
    case invalidContinuation
    case invalidContinuationRequest
    case continuationExpired
    case evidenceIDCollision(String)
    case recommendationJoinFailed(String)
}

public actor ChangeImpactService {
    public static let schemaVersion = "aishell.change-impact.v2"
    public static let defaultByteBudget = 65_536
    public static let maximumByteBudget = 1_048_576

    private struct AnalysisState: Sendable {
        let semanticDigest: String
        let operation: ChangeImpactOperation
        let root: URL
        let rootIdentity: String
        let generation: String
        let inputCursor: String
        let observedCursor: String
        let bindings: [ChangeImpactFreshnessBinding]
        let items: [ChangeImpactItem]
        let itemData: [Data]
        let stream: Data
        let artifact: ArtifactMetadata
        let coverage: String
        let counts: ChangeImpactCounts
        let expiresAt: Date
    }

    private struct ContinuationState: Sendable {
        let analysis: AnalysisState
        let offset: Int
        let previousBudget: Int
    }

    private struct RecommendationState: Sendable {
        let set: FocusedCheckService.FocusedSet
        let freshness: ChangeImpactFreshness
        let coverage: String
        let limitations: [String]
        let items: [ChangeImpactRecommendationItem]
        let itemData: [Data]
        let artifact: ArtifactMetadata
        let expiresAt: Date
    }

    private struct RecommendationContinuation: Sendable {
        let state: RecommendationState
        let offset: Int
        let previousBudget: Int
    }

    private struct EvidenceRecord {
        let providerID: String
        let candidateID: String
        let candidate: ChangeImpactCandidateSeed
        let evidenceID: String
        let seed: ChangeImpactEvidenceSeed
    }

    private let runtimeStore: RuntimeStore
    private let workspaceRuntime: WorkspaceStateRuntime
    private let evidenceStore: EvidenceStore
    private let providers: [any ChangeImpactProvider]
    private let clock: @Sendable () -> Date
    private let identifierHash: @Sendable (Data) -> String
    private let beforeFinalFreshnessCheck: (@Sendable () async throws -> Void)?
    private let focusedCheckService: FocusedCheckService
    private var continuations: [String: ContinuationState] = [:]
    private var recommendationContinuations: [String: RecommendationContinuation] = [:]

    public init(
        runtimeStore: RuntimeStore = RuntimeStore(),
        workspaceRuntime: WorkspaceStateRuntime? = nil,
        evidenceStore: EvidenceStore? = nil,
        providers: [any ChangeImpactProvider]? = nil,
        clock: @escaping @Sendable () -> Date = Date.init,
        identifierHash: @escaping @Sendable (Data) -> String = { data in
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        },
        focusedCheckService: FocusedCheckService = FocusedCheckService(),
        beforeFinalFreshnessCheck: (@Sendable () async throws -> Void)? = nil
    ) {
        self.runtimeStore = runtimeStore
        let resolvedWorkspaceRuntime = workspaceRuntime ?? WorkspaceStateRuntime(runtimeStore: runtimeStore)
        self.workspaceRuntime = resolvedWorkspaceRuntime
        self.evidenceStore = evidenceStore ?? EvidenceStore(
            baseDirectory: runtimeStore.baseDirectory.appendingPathComponent("evidence", isDirectory: true)
        )
        self.providers = providers ?? [
            FileSystemChangeImpactProvider(),
            StaticImportChangeImpactProvider(),
        ]
        self.clock = clock
        self.identifierHash = identifierHash
        self.focusedCheckService = focusedCheckService
        self.beforeFinalFreshnessCheck = beforeFinalFreshnessCheck
    }

    public func analyze(_ request: ChangeImpactRequest) async throws -> ChangeImpactResult {
        if let token = request.continuation {
            return try await continueAnalysis(request, token: token)
        }
        guard let operation = request.operation else { throw ChangeImpactError.invalidOperation }
        guard operation == .analyze else { throw ChangeImpactError.notReady(operation: operation, ownerTask: "ACE-033") }
        guard let workspaceCursor = request.workspaceCursor, !workspaceCursor.isEmpty else {
            throw ChangeImpactError.invalidRequest("workspace_cursor is required")
        }
        guard !request.changedPaths.isEmpty || !request.changedSymbols.isEmpty else {
            throw ChangeImpactError.invalidRequest("changed_paths or changed_symbols is required")
        }
        try validateRequestLimits(request)
        let budget = try validatedBudget(request.byteBudget ?? Self.defaultByteBudget)
        let resolver = try await activeResolver()
        let root = try resolveRoot(request.root, resolver: resolver)
        let normalizedPaths = try normalizeChangedPaths(request.changedPaths, root: root, resolver: resolver)
        let normalizedSymbols = try normalizeChangedSymbols(request.changedSymbols, root: root, resolver: resolver)
        let requiredProviders = sortedUnique(request.requiredProviders)
        let observed = try await validateCursor(root: root, cursor: workspaceCursor)
        let cursorParts = try parseCursor(observed.cursor)
        let rootIdentity = try fileIdentity(root)

        var inputBindings: [ChangeImpactFreshnessBinding] = []
        for changed in normalizedPaths {
            inputBindings.append(.init(
                role: .input,
                path: changed.path,
                contentSHA256: changed.contentSHA256,
                expectedAbsent: changed.expectedAbsent
            ))
        }
        for symbol in normalizedSymbols {
            inputBindings.append(.init(role: .input, path: symbol.path, contentSHA256: symbol.contentSHA256))
        }
        try validateCurrent(bindings: inputBindings, root: root)

        let providerInput = ChangeImpactProviderInput(
            root: root,
            workspaceCursor: observed.cursor,
            changedPaths: normalizedPaths,
            changedSymbols: normalizedSymbols
        )
        var outputs: [ChangeImpactProviderOutput] = []
        var seenProviderIDs: Set<String> = []
        for provider in providers.sorted(by: { utf8Less($0.descriptor.providerID, $1.descriptor.providerID) }) {
            guard seenProviderIDs.insert(provider.descriptor.providerID).inserted else {
                throw ChangeImpactError.invalidRequest("duplicate provider ID: \(provider.descriptor.providerID)")
            }
            do {
                let output = try await provider.analyze(providerInput)
                guard output.report.descriptor == provider.descriptor else {
                    throw ChangeImpactError.providerFailure("provider report descriptor mismatch: \(provider.descriptor.providerID)")
                }
                guard output.report.inputDigest.count == 64,
                      output.report.inputDigest.allSatisfy(\.isHexDigit) else {
                    throw ChangeImpactError.providerFailure("provider input digest is invalid: \(provider.descriptor.providerID)")
                }
                outputs.append(output)
            } catch {
                if let impactError = error as? ChangeImpactError { throw impactError }
                throw ChangeImpactError.providerFailure("\(provider.descriptor.providerID): \(error)")
            }
        }
        let reportsByID = Dictionary(uniqueKeysWithValues: outputs.map { ($0.report.descriptor.providerID, $0.report) })
        let missingRequired = requiredProviders.filter { reportsByID[$0]?.status != .fresh }
        if !missingRequired.isEmpty {
            throw ChangeImpactError.requiredProviderNotFresh(missingRequired)
        }

        var bindings = deduplicatedBindings(inputBindings + outputs.flatMap(\.freshnessBindings))
        if let beforeFinalFreshnessCheck { try await beforeFinalFreshnessCheck() }
        try validateCurrent(bindings: bindings, root: root)
        let finalObserved = try await validateCursor(root: root, cursor: observed.cursor)
        if finalObserved.cursor != observed.cursor {
            throw ChangeImpactError.contentChanged("workspace cursor advanced during analysis")
        }
        bindings = deduplicatedBindings(bindings)

        let built = try buildItems(
            changedPaths: normalizedPaths,
            changedSymbols: normalizedSymbols,
            requiredProviders: requiredProviders,
            bindings: bindings,
            outputs: outputs
        )
        let encoded = try encodeItems(built.items)
        let stream = encoded.reduce(into: Data()) { result, item in
            result.append(item)
            result.append(0x0A)
        }
        let artifact = try await evidenceStore.store(
            data: stream,
            kind: "change-impact-jsonl",
            producer: "change_impact"
        )
        let semanticDigest = try canonicalDigest(ChangeImpactRequest(
            operation: operation,
            root: root.path,
            workspaceCursor: workspaceCursor,
            changedPaths: normalizedPaths,
            changedSymbols: normalizedSymbols,
            requiredProviders: requiredProviders,
            byteBudget: nil,
            continuation: nil
        ))
        let analysis = AnalysisState(
            semanticDigest: semanticDigest,
            operation: operation,
            root: root,
            rootIdentity: rootIdentity,
            generation: cursorParts.generation,
            inputCursor: workspaceCursor,
            observedCursor: finalObserved.cursor,
            bindings: bindings,
            items: built.items,
            itemData: encoded,
            stream: stream,
            artifact: artifact,
            coverage: built.coverage,
            counts: built.counts,
            expiresAt: artifact.expiresAt
        )
        return try page(analysis: analysis, offset: 0, budget: budget)
    }

    /// analyze / recommend の continuation を同じ opaque entry point から再開する。
    /// token prefix は authority ではない。両 registry を完全照合し、存在しない又は
    /// 一意に定まらない token は消費せず fail closed する。
    public func continueImpact(continuation token: String, byteBudget: Int? = nil) async throws -> ChangeImpactContinuationResult {
        let analysisMatch = continuations[token] != nil
        let recommendationMatch = recommendationContinuations[token] != nil
        switch (analysisMatch, recommendationMatch) {
        case (true, false):
            return .analyze(try await continueAnalysis(
                ChangeImpactRequest(operation: nil, byteBudget: byteBudget, continuation: token),
                token: token
            ))
        case (false, true):
            return .recommend(try continueRecommendation(
                ChangeImpactRecommendationRequest(byteBudget: byteBudget, continuation: token),
                token: token
            ))
        case (false, false), (true, true):
            throw ChangeImpactError.invalidContinuation
        }
    }

    /// complete analyze evidence を全page回収してから、caller が指定した profile catalog とだけ exact join する。
    /// catalog の取得も check 実行も行わないため、この操作の process count は常に 0 である。
    public func recommend(_ request: ChangeImpactRecommendationRequest) async throws -> ChangeImpactRecommendationResult {
        if let token = request.continuation { return try continueRecommendation(request, token: token) }
        guard let projectID = request.projectID, !projectID.isEmpty,
              let profileDigest = request.profileDigest, validSHA256(profileDigest),
              let catalog = request.catalog, let impactRequest = request.impactRequest else {
            throw ChangeImpactError.recommendationJoinFailed("project_id、profile_digest、catalog、impact requestは必須です")
        }
        guard impactRequest.operation == .analyze, impactRequest.continuation == nil else {
            throw ChangeImpactError.recommendationJoinFailed("recommend inputは初回analyze requestだけを受け付けます")
        }
        let profileMatches = catalog.profiles.filter { $0.projectId == projectID && $0.profileDigest == profileDigest }
        guard profileMatches.count == 1 else { throw ChangeImpactError.recommendationJoinFailed("project/profile exact matchが一意ではありません") }
        let profile = profileMatches[0]
        guard profile.observedCursor == impactRequest.workspaceCursor else {
            throw ChangeImpactError.recommendationJoinFailed("profile cursorがimpact requestと一致しません")
        }
        let budget = try validatedBudget(request.byteBudget ?? impactRequest.byteBudget ?? Self.defaultByteBudget)
        var pageRequest = impactRequest
        pageRequest = ChangeImpactRequest(operation: .analyze, root: impactRequest.root, workspaceCursor: impactRequest.workspaceCursor,
                                          changedPaths: impactRequest.changedPaths, changedSymbols: impactRequest.changedSymbols,
                                          requiredProviders: impactRequest.requiredProviders, byteBudget: Self.maximumByteBudget)
        var analysis = try await analyze(pageRequest)
        var completeItems = analysis.items
        while let token = analysis.continuation {
            analysis = try await analyze(ChangeImpactRequest(operation: nil, byteBudget: Self.maximumByteBudget, continuation: token))
            completeItems.append(contentsOf: analysis.items)
        }
        guard !analysis.hasMore else { throw ChangeImpactError.recommendationJoinFailed("analyze streamを完全回収できません") }
        let state = try await recommendationState(profile: profile, catalog: catalog, analysis: analysis, completeItems: completeItems)
        return try recommendationPage(state: state, offset: 0, budget: budget)
    }

    private func continueRecommendation(_ request: ChangeImpactRecommendationRequest, token: String) throws -> ChangeImpactRecommendationResult {
        guard request.impactRequest == nil, request.projectID == nil, request.profileDigest == nil, request.catalog == nil else {
            throw ChangeImpactError.invalidContinuationRequest
        }
        guard let saved = recommendationContinuations.removeValue(forKey: token) else { throw ChangeImpactError.invalidContinuation }
        guard clock() <= saved.state.expiresAt else { throw ChangeImpactError.continuationExpired }
        let budget = try validatedBudget(request.byteBudget ?? saved.previousBudget)
        guard budget >= saved.previousBudget else { throw ChangeImpactError.invalidContinuationRequest }
        return try recommendationPage(state: saved.state, offset: saved.offset, budget: budget)
    }

    private func recommendationState(profile: ProjectProfile, catalog: ProjectProfileCatalogResult,
                                     analysis: ChangeImpactResult, completeItems: [ChangeImpactItem]) async throws -> RecommendationState {
        guard catalog.observedCursor == analysis.freshness.observedCursor else {
            throw ChangeImpactError.recommendationJoinFailed("catalog/profile freshnessがimpactと一致しません")
        }
        let manifests = profile.manifests.sorted { utf8Less($0.path, $1.path) }
        guard let primaryManifest = manifests.first(where: { $0.role == "primary" }), validSHA256(primaryManifest.sha256) else {
            throw ChangeImpactError.recommendationJoinFailed("primary manifest identity/SHAがありません")
        }
        let reports = Dictionary(uniqueKeysWithValues: completeItems.compactMap { item -> (String, ChangeImpactProviderReport)? in
            guard item.kind == .providerReport, let report = item.providerReport else { return nil }; return (report.descriptor.providerID, report)
        })
        let evidenceByID = Dictionary(uniqueKeysWithValues: completeItems.compactMap { item -> (String, ChangeImpactItem)? in
            guard item.kind == .evidence, let id = item.evidenceID else { return nil }; return (id, item)
        })
        var evidenceForCandidate: [String: [String]] = [:]
        for item in completeItems where item.kind == .candidateEvidence {
            if let candidate = item.candidateID, let evidence = item.evidenceID { evidenceForCandidate[candidate, default: []].append(evidence) }
        }
        var limitations: [String] = []
        var gaps = completeItems.compactMap { $0.kind == .coverageGap ? $0.coverageGap : nil }
        var candidates: [FocusedCheckService.Candidate] = []
        for item in completeItems where item.kind == .candidate {
            guard let candidateID = item.candidateID, let subject = item.subject else { continue }
            let evidenceIDs = (evidenceForCandidate[candidateID] ?? []).sorted(by: utf8Less)
            let evidence = try evidenceIDs.map { id -> FocusedCheckService.Evidence in
                guard let raw = evidenceByID[id], let providerID = raw.providerID, let report = reports[providerID] else {
                    throw ChangeImpactError.recommendationJoinFailed("impact evidence provenanceが欠損しています: \(id)")
                }
                return .init(id: id, provenance: .init(providerID: providerID, providerVersion: report.descriptor.version,
                    artifactDigest: analysis.artifact.sha256, freshness: analysis.freshness.bindingDigest))
            }
            guard !evidence.isEmpty else {
                gaps.append(.init(category: item.category ?? .relatedTests, reasonCode: "IMPACT_EVIDENCE_MISSING", subject: subject,
                                  nextAction: "complete impact evidenceを取得して再recommendしてください。")); continue
            }
            let selectors: [(FocusedCheckService.Selector, ProjectProfileCheck)]
            switch subject.kind {
            case .test:
                guard let path = subject.path, ownedTestPath(path, profile: profile, catalogRoot: catalog.root) else {
                    gaps.append(.init(category: .relatedTests, reasonCode: "TEST_PATH_NOT_OWNED_BY_PROFILE", subject: subject,
                                      nextAction: "test path ownershipをprofile targetへ明示してください。")); continue
                }
                selectors = profile.checks.filter { $0.kind == "test" }.map { (.testPath(path: path), $0) }
            case .target:
                guard let ecosystem = subject.ecosystemID, let identity = subject.profileIdentity,
                      let manifestPath = subject.manifestPath, let declaredID = subject.declaredID,
                      ecosystem == profile.ecosystem, manifestPath == primaryManifest.path,
                      identity == primaryManifest.sha256,
                      profile.targets.contains(where: { $0.targetId == declaredID }) else {
                    gaps.append(.init(category: .buildTargets, reasonCode: "TARGET_PROFILE_EXACT_JOIN_UNSUPPORTED", subject: subject,
                                      nextAction: "target ID、manifest identity、profile digestを一致させてください。")); continue
                }
                selectors = profile.checks.filter { $0.kind == "test" }.map { (.target(ecosystemID: ecosystem, profileIdentity: identity, manifestPath: manifestPath, declaredID: declaredID), $0) }
            default:
                limitations.append("unsupported mapping: \(candidateID)")
                gaps.append(.init(category: item.category ?? .references, reasonCode: "UNSUPPORTED_FOCUSED_MAPPING", subject: subject,
                                  nextAction: "profileにexact selector mappingを追加してください。")); continue
            }
            if selectors.isEmpty {
                gaps.append(.init(category: item.category ?? .relatedTests, reasonCode: "PROFILE_TEST_CHECK_UNAVAILABLE", subject: subject,
                                  nextAction: "profile catalogにtest check descriptorを追加してください。")); continue
            }
            for (selector, check) in selectors {
                guard check.provenance.contentSHA256 == primaryManifest.sha256 else {
                    throw ChangeImpactError.recommendationJoinFailed("profile check provenance SHAがmanifestと一致しません")
                }
                let descriptor = try canonicalJSON(check)
                let step = FocusedCheckService.Step(id: "step_\(check.checkId)", descriptorDigest: Self.sha256(descriptor), ordinal: 0)
                candidates.append(.init(profileCheckID: check.checkId, profileDigest: profile.profileDigest, selector: selector, steps: [step], evidence: evidence))
            }
        }
        let normalizedGaps = unique(gaps).sorted { gapSortKey($0) < gapSortKey($1) }
        limitations += normalizedGaps.map { "\($0.reasonCode):\($0.category.rawValue)" }
        guard !candidates.isEmpty else { throw ChangeImpactError.recommendationJoinFailed("exact join可能なfocused candidateがありません: \(limitations.joined(separator: ","))") }
        let set: FocusedCheckService.FocusedSet
        do {
            set = try await focusedCheckService.compile(.init(rootIdentity: analysis.freshness.rootIdentity, generation: analysis.freshness.workspaceGeneration,
                cursor: analysis.freshness.observedCursor, profileDigest: profile.profileDigest, manifestIdentity: primaryManifest.identity,
                impactArtifactDigest: analysis.artifact.sha256, coverage: analysis.coverage == "complete" && normalizedGaps.isEmpty ? ["complete"] : ["partial"],
                limitations: Array(Set(limitations)).sorted(by: utf8Less), candidates: candidates, expiresAt: analysis.artifact.expiresAt))
        } catch { throw ChangeImpactError.recommendationJoinFailed("focused set compile失敗: \(error)") }
        var items: [ChangeImpactRecommendationItem] = []
        for manifest in manifests { items.append(.init(kind: .manifestBinding, itemID: "manifest:\(manifest.path)", manifest: manifest)) }
        for candidate in set.candidates {
            items.append(.init(kind: .focusedCandidate, itemID: "candidate:\(candidate.focusedCheckID)", focusedCheckID: candidate.focusedCheckID,
                profileCheckID: candidate.source.profileCheckID, profileDigest: candidate.source.profileDigest, selector: candidate.source.selector))
            for step in candidate.source.steps { items.append(.init(kind: .focusedStep, itemID: "step:\(candidate.focusedCheckID):\(step.id)", focusedCheckID: candidate.focusedCheckID, step: step)) }
            for evidence in candidate.source.evidence { items.append(.init(kind: .impactEvidence, itemID: "evidence:\(candidate.focusedCheckID):\(evidence.id)", focusedCheckID: candidate.focusedCheckID, evidence: evidence)) }
        }
        for (index, gap) in normalizedGaps.enumerated() { items.append(.init(kind: .coverageGap, itemID: "gap:\(index):\(gap.reasonCode)", coverageGap: gap)) }
        items.sort { recommendationSortKey($0) < recommendationSortKey($1) }
        let data = try encodeRecommendationItems(items)
        let stream = data.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
        let artifact = try await evidenceStore.store(data: stream, kind: "change-impact-recommend-jsonl", producer: "change_impact")
        return RecommendationState(set: set, freshness: analysis.freshness, coverage: normalizedGaps.isEmpty && analysis.coverage == "complete" ? "complete" : "partial",
                                   limitations: Array(Set(limitations)).sorted(by: utf8Less), items: items, itemData: data, artifact: artifact, expiresAt: artifact.expiresAt)
    }

    private func recommendationPage(state: RecommendationState, offset: Int, budget: Int) throws -> ChangeImpactRecommendationResult {
        var result: [ChangeImpactRecommendationItem] = []; var used = 0; var index = offset
        while index < state.items.count {
            let bytes = state.itemData[index].count + 1
            if bytes > budget, result.isEmpty { throw ChangeImpactError.resultItemTooLarge(bytes) }
            guard used + bytes <= budget else { break }
            result.append(state.items[index]); used += bytes; index += 1
        }
        let more = index < state.items.count
        let token = more ? saveRecommendationContinuation(state: state, offset: index, budget: budget) : nil
        return .init(schema: Self.schemaVersion, operation: .recommend, executionPolicy: "explicit_run_check_only", focusedSetID: state.set.id,
                     focusedSetDigest: state.set.digest, expiresAt: state.set.expiresAt, freshness: state.freshness, coverage: state.coverage,
                     candidateCount: state.set.candidates.count, stepCount: state.set.candidates.reduce(0) { $0 + $1.source.steps.count },
                     limitationCount: state.limitations.count, items: result, byteBudget: budget, hasMore: more, continuation: token, artifact: state.artifact)
    }

    private func saveRecommendationContinuation(state: RecommendationState, offset: Int, budget: Int) -> String {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let token = "cir2:\(nonce):\(Self.sha256(Data("\(nonce):\(state.set.digest):\(offset):\(budget)".utf8)))"
        recommendationContinuations[token] = .init(state: state, offset: offset, previousBudget: budget); return token
    }

    private func ownedTestPath(_ path: String, profile: ProjectProfile, catalogRoot: String) -> Bool {
        guard let normalizedPath = rootRelative(path),
              let projectRoot = catalogRelative(profile.projectRoot, catalogRoot: catalogRoot) else { return false }
        guard projectRoot.isEmpty || normalizedPath == projectRoot || normalizedPath.hasPrefix(projectRoot + "/") else { return false }
        return profile.targets.contains { target in
            target.sourceRoots.contains { root in
                guard let normalizedRoot = rootRelative(root) else { return false }
                return normalizedPath == normalizedRoot || normalizedPath.hasPrefix(normalizedRoot + "/")
            }
        }
    }

    private func rootRelative(_ value: String) -> String? {
        guard !value.hasPrefix("/") else { return nil }
        let parts = value.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(".") && !parts.contains("..") else { return nil }
        return parts.joined(separator: "/")
    }

    private func catalogRelative(_ value: String, catalogRoot: String) -> String? {
        guard catalogRoot.hasPrefix("/"), let normalizedRoot = absoluteComponents(catalogRoot) else { return nil }
        if value.hasPrefix("/") {
            guard let candidate = absoluteComponents(value), candidate.starts(with: normalizedRoot) else { return nil }
            return candidate.dropFirst(normalizedRoot.count).joined(separator: "/")
        }
        return rootRelative(value)
    }

    private func absoluteComponents(_ value: String) -> [Substring]? {
        guard value.hasPrefix("/") else { return nil }
        let parts = value.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(".") && !parts.contains("..") else { return nil }
        return parts
    }

    private func encodeRecommendationItems(_ items: [ChangeImpactRecommendationItem]) throws -> [Data] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try items.map { try encoder.encode($0) }
    }

    private func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func validSHA256(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 64 && bytes.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    private func recommendationSortKey(_ item: ChangeImpactRecommendationItem) -> String {
        let ordinal: [ChangeImpactRecommendationItemKind: String] = [.focusedCandidate: "0", .focusedStep: "1", .dependencyEdge: "2", .manifestBinding: "3", .impactEvidence: "4", .coverageGap: "5"]
        return (ordinal[item.kind] ?? "9") + "\u{0}" + item.itemID
    }

    private func continueAnalysis(_ request: ChangeImpactRequest, token: String) async throws -> ChangeImpactResult {
        guard request.operation == nil,
              request.root == nil,
              request.workspaceCursor == nil,
              request.changedPaths.isEmpty,
              request.changedSymbols.isEmpty,
              request.requiredProviders.isEmpty else {
            throw ChangeImpactError.invalidContinuationRequest
        }
        guard let saved = continuations.removeValue(forKey: token) else {
            throw ChangeImpactError.invalidContinuation
        }
        guard clock() <= saved.analysis.expiresAt else { throw ChangeImpactError.continuationExpired }
        let budget = try validatedBudget(request.byteBudget ?? saved.previousBudget)
        guard budget >= saved.previousBudget else { throw ChangeImpactError.invalidContinuationRequest }
        guard try fileIdentity(saved.analysis.root) == saved.analysis.rootIdentity else {
            throw ChangeImpactError.contentChanged("workspace root identity changed")
        }
        try validateCurrent(bindings: saved.analysis.bindings, root: saved.analysis.root)
        let observed = try await validateCursor(root: saved.analysis.root, cursor: saved.analysis.observedCursor)
        guard observed.cursor == saved.analysis.observedCursor else {
            throw ChangeImpactError.contentChanged("workspace cursor advanced between pages")
        }
        return try page(analysis: saved.analysis, offset: saved.offset, budget: budget)
    }

    private func page(analysis: AnalysisState, offset: Int, budget: Int) throws -> ChangeImpactResult {
        var items: [ChangeImpactItem] = []
        var returned = 0
        var index = offset
        while index < analysis.items.count {
            let bytes = analysis.itemData[index].count + 1
            if bytes > budget, items.isEmpty {
                let token = saveContinuation(analysis: analysis, offset: index, budget: budget)
                throw ChangeImpactError.byteBudgetTooSmall(requiredMinimumBytes: bytes, continuation: token)
            }
            guard returned + bytes <= budget else { break }
            items.append(analysis.items[index])
            returned += bytes
            index += 1
            guard items.count < 4_096 else { break }
        }
        let hasMore = index < analysis.items.count
        let continuation = hasMore ? saveContinuation(analysis: analysis, offset: index, budget: budget) : nil
        let omitted = analysis.itemData[index...].reduce(0) { $0 + $1.count + 1 }
        return ChangeImpactResult(
            schemaVersion: Self.schemaVersion,
            operation: analysis.operation,
            coverage: analysis.coverage,
            freshness: ChangeImpactFreshness(
                rootIdentity: analysis.rootIdentity,
                workspaceGeneration: analysis.generation,
                inputCursor: analysis.inputCursor,
                observedCursor: analysis.observedCursor,
                bindingDigest: bindingDigest(analysis.bindings),
                bindingCount: analysis.bindings.count
            ),
            counts: analysis.counts,
            items: items,
            returnedBytes: returned,
            omittedBytes: omitted,
            hasMore: hasMore,
            continuation: continuation,
            artifact: analysis.artifact
        )
    }

    private func saveContinuation(analysis: AnalysisState, offset: Int, budget: Int) -> String {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let material = "\(nonce):\(analysis.semanticDigest):\(offset):\(budget)"
        let token = "ci2:\(nonce):\(Self.sha256(Data(material.utf8)))"
        continuations[token] = ContinuationState(analysis: analysis, offset: offset, previousBudget: budget)
        return token
    }

    private func buildItems(
        changedPaths: [ChangeImpactChangedPath],
        changedSymbols: [ChangeImpactChangedSymbol],
        requiredProviders: [String],
        bindings: [ChangeImpactFreshnessBinding],
        outputs: [ChangeImpactProviderOutput]
    ) throws -> (items: [ChangeImpactItem], coverage: String, counts: ChangeImpactCounts) {
        var items: [ChangeImpactItem] = []
        for changed in changedPaths {
            items.append(.init(kind: .inputPath, itemID: "input-path:\(inputPathIdentity(changed))", changedPath: changed))
        }
        for symbol in changedSymbols {
            items.append(.init(kind: .inputSymbol, itemID: "input-symbol:\(inputSymbolIdentity(symbol))", changedSymbol: symbol))
        }
        for providerID in requiredProviders {
            items.append(.init(kind: .requiredProvider, itemID: "required-provider:\(providerID)", providerID: providerID))
        }
        for binding in bindings {
            items.append(.init(
                kind: .freshnessBinding,
                itemID: "freshness:\(bindingIdentity(binding))",
                freshnessBinding: binding
            ))
        }
        let reports = outputs.map(\.report).sorted { reportSortKey($0) < reportSortKey($1) }
        for report in reports {
            items.append(.init(
                kind: .providerReport,
                itemID: "provider:\(report.descriptor.providerID)",
                providerReport: report
            ))
        }
        var gaps = outputs.flatMap(\.coverageGaps)
        if reports.isEmpty {
            for category in ChangeImpactCategory.allCases {
                gaps.append(ChangeImpactCoverageGap(
                    category: category,
                    reasonCode: "NO_PROVIDER_ATTEMPTED",
                    nextAction: "対応providerを有効にして再解析してください。"
                ))
            }
        }
        for report in reports where report.status != .fresh {
            for category in ChangeImpactCategory.allCases {
                gaps.append(ChangeImpactCoverageGap(
                    category: category,
                    reasonCode: report.reasonCode ?? "PROVIDER_NOT_FRESH",
                    providerID: report.descriptor.providerID,
                    nextAction: report.nextAction ?? "provider状態を解消して再解析してください。"
                ))
            }
        }
        gaps = unique(gaps).sorted { gapSortKey($0) < gapSortKey($1) }
        for (index, gap) in gaps.enumerated() {
            items.append(.init(kind: .coverageGap, itemID: "gap:\(index):\(gapSortKey(gap))", coverageGap: gap))
        }

        var candidates: [String: ChangeImpactCandidateSeed] = [:]
        var evidenceByID: [String: EvidenceRecord] = [:]
        for output in outputs where output.report.status == .fresh {
            let providerID = output.report.descriptor.providerID
            for seed in output.evidence {
                try validateEvidence(seed, rootBindings: bindings)
                let candidateIdentity = subjectIdentity(seed.candidate.subject)
                let candidateID = identifierHash(Data(tuple([
                    seed.candidate.category.rawValue, candidateIdentity
                ]).utf8))
                if let existing = candidates[candidateID], existing != seed.candidate {
                    throw ChangeImpactError.evidenceIDCollision(candidateID)
                }
                candidates[candidateID] = seed.candidate
                let canonical = tuple([
                    providerID,
                    seed.inputIdentity,
                    candidateIdentity,
                    seed.relation.rawValue,
                    locatorIdentity(seed.locator),
                    seed.strength.rawValue,
                    seed.summary
                ])
                let evidenceID = identifierHash(Data(canonical.utf8))
                let record = EvidenceRecord(
                    providerID: providerID,
                    candidateID: candidateID,
                    candidate: seed.candidate,
                    evidenceID: evidenceID,
                    seed: seed
                )
                if let existing = evidenceByID[evidenceID] {
                    let previous = try canonicalDigest(existing.seed)
                    let current = try canonicalDigest(seed)
                    if previous != current || existing.providerID != providerID {
                        throw ChangeImpactError.evidenceIDCollision(evidenceID)
                    }
                } else {
                    evidenceByID[evidenceID] = record
                }
            }
        }
        let sortedCandidates = candidates.map { (id: $0.key, seed: $0.value) }.sorted {
            candidateSortKey($0.seed, id: $0.id) < candidateSortKey($1.seed, id: $1.id)
        }
        for candidate in sortedCandidates {
            items.append(.init(
                kind: .candidate,
                itemID: "candidate:\(candidate.id)",
                candidateID: candidate.id,
                category: candidate.seed.category,
                subject: candidate.seed.subject
            ))
        }
        let sortedEvidence = evidenceByID.values.sorted { evidenceSortKey($0) < evidenceSortKey($1) }
        for record in sortedEvidence {
            items.append(.init(
                kind: .evidence,
                itemID: "evidence:\(record.evidenceID)",
                providerID: record.providerID,
                subject: record.candidate.subject,
                evidenceID: record.evidenceID,
                inputIdentity: record.seed.inputIdentity,
                relation: record.seed.relation,
                locator: record.seed.locator,
                evidenceStrength: record.seed.strength,
                summary: record.seed.summary
            ))
        }
        let edges = sortedEvidence.map { (candidateID: $0.candidateID, evidenceID: $0.evidenceID) }
            .sorted { tuple([$0.candidateID, $0.evidenceID]) < tuple([$1.candidateID, $1.evidenceID]) }
        for edge in edges {
            items.append(.init(
                kind: .candidateEvidence,
                itemID: "edge:\(edge.candidateID):\(edge.evidenceID)",
                candidateID: edge.candidateID,
                evidenceID: edge.evidenceID
            ))
        }
        guard items.count <= 4_096 else { throw ChangeImpactError.requestTooLarge("items exceed 4096") }
        let count = { (category: ChangeImpactCategory) in
            sortedCandidates.filter { $0.seed.category == category }.count
        }
        return (
            items,
            gaps.isEmpty ? "complete" : "partial",
            ChangeImpactCounts(
                references: count(.references),
                dependencies: count(.dependencies),
                relatedTests: count(.relatedTests),
                buildTargets: count(.buildTargets)
            )
        )
    }

    private func encodeItems(_ items: [ChangeImpactItem]) throws -> [Data] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try items.map { item in
            let data = try encoder.encode(item)
            guard data.count + 1 <= 16_384 else { throw ChangeImpactError.resultItemTooLarge(data.count + 1) }
            return data
        }
    }

    private func validateEvidence(
        _ seed: ChangeImpactEvidenceSeed,
        rootBindings: [ChangeImpactFreshnessBinding]
    ) throws {
        guard !seed.inputIdentity.isEmpty,
              !seed.summary.isEmpty,
              Data(seed.summary.utf8).count <= 4_096 else {
            throw ChangeImpactError.invalidRequest("invalid provider evidence")
        }
        guard rootBindings.contains(where: {
            $0.path == seed.locator.path && $0.contentSHA256 == seed.locator.contentSHA256
        }) else {
            throw ChangeImpactError.contentChanged("evidence locator is not freshness-bound: \(seed.locator.path)")
        }
    }

    private func normalizeChangedPaths(
        _ values: [ChangeImpactChangedPath],
        root: URL,
        resolver: PathResolver
    ) throws -> [ChangeImpactChangedPath] {
        var result: [String: ChangeImpactChangedPath] = [:]
        for value in values {
            guard value.expectedAbsent != (value.contentSHA256 != nil) else {
                throw ChangeImpactError.invalidRequest("each changed path requires exactly one of content_sha256 or expected_absent")
            }
            let path = try normalizePath(value.path, expectedAbsent: value.expectedAbsent, root: root, resolver: resolver)
            let sha = try value.contentSHA256.map(normalizedSHA)
            let normalized = ChangeImpactChangedPath(path: path, contentSHA256: sha, expectedAbsent: value.expectedAbsent)
            if let existing = result[path], existing != normalized {
                throw ChangeImpactError.invalidRequest("conflicting changed path: \(path)")
            }
            result[path] = normalized
        }
        return result.values.sorted { utf8Less($0.path, $1.path) }
    }

    private func normalizeChangedSymbols(
        _ values: [ChangeImpactChangedSymbol],
        root: URL,
        resolver: PathResolver
    ) throws -> [ChangeImpactChangedSymbol] {
        var result: [String: ChangeImpactChangedSymbol] = [:]
        for value in values {
            guard !value.name.isEmpty,
                  value.startOffset >= 0,
                  value.endOffset > value.startOffset else {
                throw ChangeImpactError.invalidRequest("invalid changed symbol range")
            }
            let path = try normalizePath(value.path, expectedAbsent: false, root: root, resolver: resolver)
            let normalized = ChangeImpactChangedSymbol(
                path: path,
                contentSHA256: try normalizedSHA(value.contentSHA256),
                name: value.name,
                startOffset: value.startOffset,
                endOffset: value.endOffset,
                stableID: value.stableID
            )
            let bytes = try Data(contentsOf: root.appendingPathComponent(path), options: .mappedIfSafe)
            guard normalized.endOffset <= bytes.count,
                  bytes[normalized.startOffset..<normalized.endOffset] == Data(normalized.name.utf8) else {
                throw ChangeImpactError.invalidRequest("changed symbol range does not identify name bytes: \(path)")
            }
            let key = inputSymbolIdentity(normalized)
            result[key] = normalized
        }
        return result.values.sorted { inputSymbolIdentity($0) < inputSymbolIdentity($1) }
    }

    private func normalizePath(
        _ path: String,
        expectedAbsent: Bool,
        root: URL,
        resolver: PathResolver
    ) throws -> String {
        guard !path.isEmpty, Data(path.utf8).count <= 4_096 else {
            throw ChangeImpactError.requestTooLarge("path exceeds limit")
        }
        let url = expectedAbsent ? try resolver.resolveDestination(path) : try resolver.resolveExisting(path)
        let rootComponents = root.pathComponents
        let components = url.pathComponents
        guard components.count > rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents else {
            throw AIShellError.outsideWorkspace(url.path)
        }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func validateCurrent(bindings: [ChangeImpactFreshnessBinding], root: URL) throws {
        for binding in bindings {
            let url = root.appendingPathComponent(binding.path)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if binding.expectedAbsent {
                guard !exists else { throw ChangeImpactError.contentChanged("expected absent: \(binding.path)") }
                continue
            }
            guard exists, !isDirectory.boolValue, let expected = binding.contentSHA256 else {
                throw ChangeImpactError.contentChanged("missing analysis input: \(binding.path)")
            }
            let current = try Self.fileSHA256(url)
            guard current == expected else { throw ChangeImpactError.contentChanged(binding.path) }
        }
    }

    private func validateCursor(root: URL, cursor: String) async throws -> WorkspaceSnapshot {
        do {
            return try await workspaceRuntime.snapshot(
                path: root.path,
                sinceCursor: cursor,
                entryLimit: 1,
                contextBudget: 0
            )
        } catch let error as AIShellError {
            switch error {
            case .cursorExpired: throw error
            case .rescanRequired: throw error
            default: throw error
            }
        }
    }

    private func activeResolver() async throws -> PathResolver {
        return await runtimeStore.pathResolver()
    }

    private func resolveRoot(_ path: String?, resolver: PathResolver) throws -> URL {
        let root = try resolver.resolveExisting(path)
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw AIShellError.invalidPath(root.path) }
        return root
    }

    private func validateRequestLimits(_ request: ChangeImpactRequest) throws {
        guard request.changedPaths.count <= 4_096,
              request.changedSymbols.count <= 4_096,
              request.requiredProviders.count <= 64 else {
            throw ChangeImpactError.requestTooLarge("request item count exceeds limit")
        }
        for symbol in request.changedSymbols {
            guard Data(symbol.name.utf8).count <= 1_024,
                  symbol.stableID.map({ Data($0.utf8).count <= 4_096 }) ?? true else {
                throw ChangeImpactError.requestTooLarge("symbol field exceeds limit")
            }
        }
        for provider in request.requiredProviders where provider.isEmpty || Data(provider.utf8).count > 256 {
            throw ChangeImpactError.requestTooLarge("provider ID exceeds limit")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(request).count <= 4_194_304 else {
            throw ChangeImpactError.requestTooLarge("canonical request exceeds 4194304 bytes")
        }
    }

    private func validatedBudget(_ value: Int) throws -> Int {
        guard (1...Self.maximumByteBudget).contains(value) else {
            throw ChangeImpactError.invalidRequest("byte_budget must be 1...1048576")
        }
        return value
    }

    private func parseCursor(_ cursor: String) throws -> (rootDigest: String, generation: String) {
        let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "ws2", UInt64(parts[4]) != nil else {
            throw AIShellError.cursorExpired(cursor)
        }
        return (String(parts[1]), String(parts[3]))
    }

    private func deduplicatedBindings(
        _ values: [ChangeImpactFreshnessBinding]
    ) -> [ChangeImpactFreshnessBinding] {
        var map: [String: ChangeImpactFreshnessBinding] = [:]
        for value in values { map[bindingIdentity(value)] = value }
        return map.values.sorted { bindingSortKey($0) < bindingSortKey($1) }
    }

    private func bindingDigest(_ bindings: [ChangeImpactFreshnessBinding]) -> String {
        Self.sha256(Data(bindings.map(bindingIdentity).joined(separator: "\n").utf8))
    }

    private func bindingIdentity(_ binding: ChangeImpactFreshnessBinding) -> String {
        tuple([
            binding.role.rawValue,
            binding.path,
            binding.contentSHA256 ?? "",
            binding.expectedAbsent ? "1" : "0"
        ])
    }

    private func bindingSortKey(_ binding: ChangeImpactFreshnessBinding) -> String {
        let role = binding.role == .input ? "0" : "1"
        return tuple([role, binding.path, binding.contentSHA256 ?? "", binding.expectedAbsent ? "1" : "0"])
    }

    private func inputPathIdentity(_ path: ChangeImpactChangedPath) -> String {
        tuple(["input_path", path.path, path.expectedAbsent ? "1" : "0", path.contentSHA256 ?? ""])
    }

    private func inputSymbolIdentity(_ symbol: ChangeImpactChangedSymbol) -> String {
        tuple([
            "input_symbol", symbol.path, String(symbol.startOffset), String(symbol.endOffset),
            symbol.name, symbol.stableID ?? "", symbol.contentSHA256
        ])
    }

    private func subjectIdentity(_ subject: ChangeImpactSubject) -> String {
        tuple([
            subject.kind.rawValue, subject.path ?? "", subject.name ?? "",
            subject.startOffset.map(String.init) ?? "", subject.endOffset.map(String.init) ?? "",
            subject.stableID ?? "", subject.ecosystemID ?? "", subject.profileIdentity ?? "",
            subject.manifestPath ?? "", subject.declaredID ?? ""
        ])
    }

    private func locatorIdentity(_ locator: ChangeImpactEvidenceLocator) -> String {
        tuple([
            locator.path, locator.contentSHA256, locator.startOffset.map(String.init) ?? "",
            locator.endOffset.map(String.init) ?? "", locator.edgeID ?? ""
        ])
    }

    private func candidateSortKey(_ seed: ChangeImpactCandidateSeed, id: String) -> String {
        tuple([
            String(categoryOrder(seed.category)),
            String(subjectOrder(seed.subject.kind)),
            subjectIdentity(seed.subject),
            id
        ])
    }

    private func evidenceSortKey(_ record: EvidenceRecord) -> String {
        let providerID = record.providerID
        let evidenceID = record.evidenceID
        let seed = record.seed
        return tuple([
            providerID, seed.inputIdentity, subjectIdentity(seed.candidate.subject),
            String(relationOrder(seed.relation)), locatorIdentity(seed.locator),
            String(strengthOrder(seed.strength)), seed.summary, evidenceID
        ])
    }

    private func reportSortKey(_ report: ChangeImpactProviderReport) -> String {
        tuple([
            report.descriptor.providerID,
            report.descriptor.kind.rawValue,
            report.descriptor.version,
            report.status.rawValue
        ])
    }

    private func gapSortKey(_ gap: ChangeImpactCoverageGap) -> String {
        tuple([
            String(categoryOrder(gap.category)), gap.reasonCode,
            gap.providerID ?? "", gap.subject.map(subjectIdentity) ?? ""
        ])
    }

    private func categoryOrder(_ value: ChangeImpactCategory) -> Int {
        ChangeImpactCategory.allCases.firstIndex(of: value) ?? Int.max
    }

    private func subjectOrder(_ value: ChangeImpactSubjectKind) -> Int {
        ChangeImpactSubjectKind.allCases.firstIndex(of: value) ?? Int.max
    }

    private func relationOrder(_ value: ChangeImpactRelation) -> Int {
        switch value {
        case .declaredDependency: 0
        case .containsSource: 1
        case .containsTest: 2
        case .semanticReference: 3
        case .lexicalReference: 4
        case .namingHeuristic: 5
        }
    }

    private func strengthOrder(_ value: ChangeImpactEvidenceStrength) -> Int {
        switch value {
        case .heuristic: 0
        case .lexicalMatch: 1
        case .semanticMatch: 2
        case .declaredEdge: 3
        }
    }

    private func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values)).sorted(by: utf8Less)
    }

    private func unique<T: Codable & Equatable>(_ values: [T]) -> [T] {
        var result: [T] = []
        for value in values where !result.contains(value) { result.append(value) }
        return result
    }

    private func canonicalDigest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Self.sha256(try encoder.encode(value))
    }

    private func normalizedSHA(_ value: String) throws -> String {
        let lower = value.lowercased()
        guard lower.count == 64, lower.allSatisfy({ $0.isHexDigit }) else {
            throw ChangeImpactError.invalidRequest("SHA-256 must be 64 lowercase hexadecimal characters")
        }
        return lower
    }

    private func tuple(_ values: [String]) -> String {
        values.map { "\(Data($0.utf8).count):\($0)" }.joined()
    }

    private func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private func fileIdentity(_ url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw AIShellError.invalidPath(url.path) }
        return "\(info.st_dev):\(info.st_ino)"
    }

    private static func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
