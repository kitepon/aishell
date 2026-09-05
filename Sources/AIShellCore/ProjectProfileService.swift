import CryptoKit
import Darwin
import Foundation

public enum ProjectProfileStatus: String, Codable, Equatable, Sendable {
    case complete, partial, unsupported, invalid
}

public enum ProjectProfileFreshness: String, Codable, Equatable, Sendable {
    case freshComputed = "fresh_computed"
    case freshCached = "fresh_cached"
}

public struct ProjectProfileManifest: Codable, Equatable, Sendable {
    public let path: String
    public let role: String
    public let identity: String
    public let sha256: String
    public let parseStatus: String
}

public struct ProjectProfileProvenance: Codable, Equatable, Sendable {
    public let kind: String
    public let path: String
    public let contentSHA256: String?
    public let producerVersion: String
    public let confidence: String
}

public struct ProjectProfileTarget: Codable, Equatable, Sendable {
    public let targetId: String
    public let name: String
    public let kind: String
    public let dependencies: [String]
    public let sourceRoots: [String]
    public let resourceRoots: [String]
    public let testRelation: String?
    public let provenance: ProjectProfileProvenance
}

public enum ProjectProfileCheckInputCompleteness: String, Codable, Equatable, Sendable {
    case complete
    case ineligible
}

public enum ProjectProfileCheckEffectCompleteness: String, Codable, Equatable, Sendable {
    case projectRootClosed = "project_root_closed"
    case unprovenExternalEffects = "unproven_external_effects"
}

/// checkの再利用可否を決めるversioned closed contract。
/// `complete`はlisted rootとmissing pathがproject root内で閉じ、実行effectもroot内で閉じる場合だけ許す。
public struct ProjectProfileCheckInputContract: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let completeness: ProjectProfileCheckInputCompleteness
    public let provider: String
    public let providerVersion: String
    public let includedRoots: [String]
    /// 現在はmissingでも将来の出現を検知すべき個別path。存在時は通常nodeとして測る。
    public let trackedPaths: [String]
    public let effectCompleteness: ProjectProfileCheckEffectCompleteness
    public let reason: String?

    public init(
        schemaVersion: String = "aishell.project-profile-check-input.v1",
        completeness: ProjectProfileCheckInputCompleteness,
        provider: String,
        providerVersion: String,
        includedRoots: [String] = [],
        trackedPaths: [String] = [],
        effectCompleteness: ProjectProfileCheckEffectCompleteness,
        reason: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.completeness = completeness
        self.provider = provider
        self.providerVersion = providerVersion
        self.includedRoots = includedRoots
        self.trackedPaths = trackedPaths
        self.effectCompleteness = effectCompleteness
        self.reason = reason
    }

    public static func complete(
        provider: String,
        providerVersion: String,
        includedRoots: [String],
        trackedPaths: [String] = []
    ) -> Self {
        Self(
            completeness: .complete,
            provider: provider,
            providerVersion: providerVersion,
            includedRoots: includedRoots,
            trackedPaths: trackedPaths,
            effectCompleteness: .projectRootClosed
        )
    }

    public static func ineligible(provider: String, providerVersion: String, reason: String) -> Self {
        Self(
            completeness: .ineligible,
            provider: provider,
            providerVersion: providerVersion,
            effectCompleteness: .unprovenExternalEffects,
            reason: reason
        )
    }
}

public struct ProjectProfileCheck: Codable, Equatable, Sendable {
    public let checkId: String
    public let kind: String
    public let label: String
    public let displayCommand: String
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String
    public let environmentKeys: [String]
    public let provenance: ProjectProfileProvenance
    public let inputContract: ProjectProfileCheckInputContract

    public init(
        checkId: String,
        kind: String,
        label: String,
        displayCommand: String? = nil,
        executable: String,
        arguments: [String],
        workingDirectory: String,
        environmentKeys: [String],
        provenance: ProjectProfileProvenance,
        inputContract: ProjectProfileCheckInputContract = .ineligible(
            provider: "unspecified",
            providerVersion: "unknown",
            reason: "relevant input closureと実行effectの完全性が宣言されていません"
        )
    ) {
        self.checkId = checkId
        self.kind = kind
        self.label = label
        self.displayCommand = displayCommand ?? ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " ")
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environmentKeys = environmentKeys
        self.provenance = provenance
        self.inputContract = inputContract
    }

    private enum CodingKeys: String, CodingKey {
        case checkId, kind, label, displayCommand, executable, arguments, workingDirectory, environmentKeys, provenance, inputContract
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        checkId = try container.decode(String.self, forKey: .checkId)
        kind = try container.decode(String.self, forKey: .kind)
        label = try container.decode(String.self, forKey: .label)
        executable = try container.decode(String.self, forKey: .executable)
        arguments = try container.decode([String].self, forKey: .arguments)
        displayCommand = try container.decodeIfPresent(String.self, forKey: .displayCommand)
            ?? ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " ")
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        environmentKeys = try container.decode([String].self, forKey: .environmentKeys)
        provenance = try container.decode(ProjectProfileProvenance.self, forKey: .provenance)
        inputContract = try container.decodeIfPresent(ProjectProfileCheckInputContract.self, forKey: .inputContract)
            ?? .ineligible(provider: "legacy", providerVersion: "unknown", reason: "保存済みprofileにinput contractがありません")
    }
}

public struct ProjectProfileCheckResolution: Equatable, Sendable {
    public let catalogRoot: String
    public let observedCursor: String
    public let profile: ProjectProfile
    public let check: ProjectProfileCheck
}

/// focused selection receiptが持つprofile digestから、fresh catalog上のprofileをexactに得る結果。
public struct ProjectProfileResolution: Equatable, Sendable {
    public let catalogRoot: String
    public let observedCursor: String
    public let profile: ProjectProfile
}

public enum ProjectProfileResolutionError: Error, Equatable, Sendable {
    case projectNotFound(String)
    case projectAmbiguous(String)
    case profileDigestChanged(expected: String, actual: String)
    case checkNotFound(String)
    case checkAmbiguous(String)
    case profileDigestNotFound(String)
    case profileDigestAmbiguous(String)
}

public struct ProjectProfileToolchain: Codable, Equatable, Sendable {
    public let name: String
    public let executable: String
    public let identity: String
    public let sha256: String
    public let versionArguments: [String]
    public let version: String
    public let exitStatus: Int32
    public let evidenceSHA256: String
    public let evidenceHandle: String
    public let evidenceExpiresAt: String
}

public struct ProjectProfileEvidence: Codable, Equatable, Sendable {
    public let exitStatus: Int32
    public let sha256: String
    public let handle: String
    public let expiresAt: String
}

public struct ProjectProfileInvalidationReason: Codable, Equatable, Sendable {
    public let kind: String
    public let path: String?
    public let oldSHA256: String?
    public let newSHA256: String?
}

public struct ProjectProfileDiagnostic: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let path: String?
    public let evidence: ProjectProfileEvidence?

    public init(code: String, message: String, path: String?, evidence: ProjectProfileEvidence? = nil) {
        self.code = code
        self.message = message
        self.path = path
        self.evidence = evidence
    }
}

public struct ProjectProfile: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let projectId: String
    public let projectRoot: String
    public let projectRootIdentity: String
    public let displayName: String
    public let ecosystem: String
    public let classification: String
    public let status: ProjectProfileStatus
    public let provider: String
    public let providerVersion: String
    public let manifests: [ProjectProfileManifest]
    public let memberProjectIds: [String]
    public let targets: [ProjectProfileTarget]
    public let checks: [ProjectProfileCheck]
    public let toolchains: [ProjectProfileToolchain]
    public let providerEvidence: ProjectProfileEvidence?
    public let missingCapabilities: [String]
    public let diagnostics: [ProjectProfileDiagnostic]
    public let binding: String
    public let freshness: ProjectProfileFreshness
    public let observedCursor: String
    public let profileDigest: String
    public let invalidationReasons: [ProjectProfileInvalidationReason]
}

public struct ProjectProfileCatalogResult: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let root: String
    public let observedCursor: String
    public let profiles: [ProjectProfile]
    public let computedProfiles: Int
    public let cachedProfiles: Int
}

/// Manifest解析とbinding cacheを所有するproject profileのdomain service。
/// filesystemを正本のまま保ち、cacheは現在のbinding inputが一致した場合だけ再利用する。
public actor ProjectProfileService {
    private static let providerTimeout: TimeInterval = 30
    private static let maximumProviderOutputBytes = 16 * 1_024 * 1_024

    private struct ProviderSpec: Sendable {
        let ecosystem: String
        let manifest: String
        let related: [String]
        let fullySupported: Bool
    }

    private struct Candidate: Sendable {
        let ownerRoot: URL
        let projectRoot: URL
        let relativeRoot: String
        let manifestURL: URL
        let manifestPath: String
        let spec: ProviderSpec
        let classification: String
        let rootIdentity: String
        let projectId: String
    }

    private struct InputState: Codable, Equatable, Sendable {
        let binding: String
        let fileHashes: [String: String]
        let fileIdentities: [String: String]
        let sourceLayout: [String]
        let toolchainIdentity: String?
    }

    private struct DeclaredNPMCheck: Sendable {
        let executable: URL
        let arguments: [String]
        let environmentKeys: [String]
        let inputContract: ProjectProfileCheckInputContract
    }

    private enum ProviderExecutionError: Error, CustomStringConvertible {
        case memberOutsideAllowedRoot(String)
        case duplicateWorkspaceOwner(String)
        case lockfileInvalid(String)
        case providerLaunch(String)
        case providerTimedOut
        case providerOutputLimit(Int)
        case providerNonzero(Int32, String, ProjectProfileEvidence?)
        case toolchainProbe(String, ProjectProfileEvidence?)
        case artifactWrite(String)

        var description: String {
            switch self {
            case .memberOutsideAllowedRoot(let path): return "workspace memberがallowed root外です: \(path)"
            case .duplicateWorkspaceOwner(let path): return "workspace memberのownerが重複しています: \(path)"
            case .lockfileInvalid(let path): return "lockfileが不正です: \(path)"
            case .providerLaunch(let message): return "providerを起動できません: \(message)"
            case .providerTimedOut: return "provider processがtimeoutしました"
            case .providerOutputLimit(let limit): return "provider outputが上限\(limit) bytesを超えました"
            case .providerNonzero(let status, let message, _): return "providerがstatus \(status)で終了しました: \(message)"
            case .toolchainProbe(let message, _): return "toolchain probeに失敗しました: \(message)"
            case .artifactWrite(let message): return "evidence artifactの保存に失敗しました: \(message)"
            }
        }
    }

    private struct ObservationCursor: Equatable, Sendable {
        let rootDigest: String
        let exclusionDigest: String
        let generation: String
        let sequence: UInt64
    }

    private struct ProcessEvidence: Sendable {
        let stdout: Data
        let stderr: Data
        let exitStatus: Int32
    }

    private struct CacheEntry: Codable, Sendable {
        let catalogKey: String
        let ownerRootPath: String
        let input: InputState
        let profile: ProjectProfile
    }

    private struct CacheEnvelope: Codable, Sendable {
        let schema: String
        let entries: [CacheEntry]
    }

    private let runtimeStore: RuntimeStore
    private let workspaceRuntime: WorkspaceStateRuntime
    private let evidenceStore: EvidenceStore
    private let cacheURL: URL
    private let providerVersion: String
    private let environmentKeys: [String]
    private let evidenceRetention: TimeInterval
    private var cache: [String: CacheEntry] = [:]
    private var cacheLoaded = false
    private var providerInvocationCounts: [String: Int] = [:]
    private var toolchainProbeCache: [String: ProjectProfileToolchain] = [:]
    private var inputContractsForTests: [String: ProjectProfileCheckInputContract] = [:]

    private static let providers = [
        ProviderSpec(ecosystem: "swiftpm", manifest: "Package.swift", related: ["Package.resolved"], fullySupported: true),
        ProviderSpec(ecosystem: "npm", manifest: "package.json", related: ["package-lock.json", "npm-shrinkwrap.json"], fullySupported: true),
        ProviderSpec(ecosystem: "xcodegen", manifest: "project.yml", related: [], fullySupported: false),
        ProviderSpec(ecosystem: "cargo", manifest: "Cargo.toml", related: ["Cargo.lock"], fullySupported: false),
        ProviderSpec(ecosystem: "python", manifest: "pyproject.toml", related: [], fullySupported: false),
        ProviderSpec(ecosystem: "go", manifest: "go.mod", related: ["go.sum"], fullySupported: false),
    ]

    public init(
        runtimeStore: RuntimeStore = RuntimeStore(),
        workspaceRuntime: WorkspaceStateRuntime? = nil,
        evidenceStore: EvidenceStore? = nil,
        providerVersion: String = "1",
        environmentKeys: [String] = [],
        evidenceRetention: TimeInterval = 24 * 60 * 60
    ) {
        self.runtimeStore = runtimeStore
        self.workspaceRuntime = workspaceRuntime ?? WorkspaceStateRuntime(runtimeStore: runtimeStore)
        self.evidenceStore = evidenceStore ?? EvidenceStore(
            baseDirectory: runtimeStore.baseDirectory.appendingPathComponent("evidence", isDirectory: true)
        )
        cacheURL = runtimeStore.baseDirectory.appendingPathComponent("project-profile-cache-v1.json")
        self.providerVersion = providerVersion
        self.environmentKeys = Array(Set(environmentKeys + ["DEVELOPER_DIR", "SDKROOT"])).sorted()
        self.evidenceRetention = evidenceRetention
    }

    public func catalog(for snapshot: WorkspaceSnapshot) async throws -> ProjectProfileCatalogResult {
        guard snapshot.freshness == "fresh" else {
            throw AIShellError.rescanRequired("workspace snapshot is not fresh: \(snapshot.freshness)")
        }
        try loadCacheIfNeeded()
        let snapshotCanonicalPath = try Self.canonicalURL(URL(fileURLWithPath: snapshot.root, isDirectory: true)).path
        let priorCursors = Set(cache.values.filter { entry in
            snapshotCanonicalPath == entry.ownerRootPath || snapshotCanonicalPath.hasPrefix(entry.ownerRootPath + "/")
        }.map { $0.profile.observedCursor })
        for priorCursor in priorCursors.isEmpty ? [snapshot.cursor] : priorCursors.sorted() {
            let attestation = try await workspaceRuntime.snapshot(
                path: snapshot.root, sinceCursor: priorCursor, entryLimit: 1, contextBudget: 0
            )
            guard attestation.cursor == snapshot.cursor else {
                throw AIShellError.contentChanged(snapshot.root)
            }
        }
        return try await catalog(rootPath: snapshot.root, observedCursor: snapshot.cursor)
    }

    public func catalog(
        rootPath: String? = nil,
        observedCursor: String
    ) async throws -> ProjectProfileCatalogResult {
        let configuration = try await runtimeStore.loadConfiguration()
        guard !configuration.isPaused else { throw AIShellError.paused }
        let currentCursor = try Self.parseObservationCursor(observedCursor)
        let resolver = await runtimeStore.pathResolver()
        try loadCacheIfNeeded()
        let requested = try resolver.resolveExisting(rootPath)
        let ownerRoot = try Self.canonicalURL(requested)
        let policyDigest = Self.digestStrings(["unrestricted-v1"])
        let catalogKey = try Self.digestJSON([
            "owner_root_identity": try Self.fileIdentity(ownerRoot),
            "owner_root_path": ownerRoot.path,
            "policy_digest": policyDigest,
            "schema": "aishell.project-profile-catalog-key.v1",
        ])
        let candidates = try discover(ownerRoot: ownerRoot)
        let liveKeys = Set(candidates.map(\.projectId))
        let previousCacheCount = cache.count
        cache = cache.filter { $0.value.catalogKey != catalogKey || liveKeys.contains($0.key) }
        var cacheChanged = cache.count != previousCacheCount

        var profiles: [ProjectProfile] = []
        var computed = 0
        var cached = 0
        for candidate in candidates {
            let input = try await inputState(for: candidate, policyDigest: policyDigest, cursor: currentCursor)
            let previous = cache[candidate.projectId]
            let previousCursor = try previous.map { try Self.parseObservationCursor($0.profile.observedCursor) }
            if let previousCursor {
                guard previousCursor.rootDigest == currentCursor.rootDigest,
                      previousCursor.exclusionDigest == currentCursor.exclusionDigest else {
                    throw AIShellError.rescanRequired("workspace cursor root or exclusion contract changed")
                }
                if previousCursor.generation == currentCursor.generation,
                   currentCursor.sequence < previousCursor.sequence {
                    throw AIShellError.cursorExpired(observedCursor)
                }
            }
            if let previous, previous.catalogKey == catalogKey,
               previous.input == input, let previousCursor,
               Self.isContinuous(previous: previousCursor, current: currentCursor),
               Self.profileEvidenceIsCurrent(previous.profile) {
                let refreshed = copy(
                    previous.profile,
                    freshness: .freshCached,
                    cursor: observedCursor,
                    reasons: []
                )
                profiles.append(refreshed)
                cache[candidate.projectId] = CacheEntry(
                    catalogKey: catalogKey, ownerRootPath: ownerRoot.path,
                    input: previous.input, profile: refreshed
                )
                cacheChanged = true
                cached += 1
            } else {
                var reasons = invalidationReasons(previous: previous?.input, current: input)
                if let previous, let previousCursor,
                   previousCursor.generation != currentCursor.generation {
                    reasons = [ProjectProfileInvalidationReason(
                        kind: "workspace_generation_changed", path: nil,
                        oldSHA256: Self.sha256(Data(previous.profile.observedCursor.utf8)),
                        newSHA256: Self.sha256(Data(observedCursor.utf8))
                    )]
                }
                let profile = try await compute(
                    candidate, input: input, policyDigest: policyDigest,
                    observationCursor: currentCursor, cursor: observedCursor, reasons: reasons
                )
                cache[candidate.projectId] = CacheEntry(
                    catalogKey: catalogKey, ownerRootPath: ownerRoot.path, input: input, profile: profile
                )
                profiles.append(profile)
                computed += 1
                cacheChanged = true
            }
        }

        let relations = npmMemberMap(candidates: candidates)
        for index in profiles.indices {
            let profile = profiles[index]
            let members = relations.members[profile.projectId] ?? []
            var updated = profile
            if profile.memberProjectIds != members {
                updated = try copy(profile, members: members)
            }
            if let paths = relations.conflicts[profile.projectId], !paths.isEmpty {
                updated = try copyInvalid(
                    updated,
                    diagnostic: ProjectProfileDiagnostic(
                        code: "PROJECT_MEMBER_DUPLICATE_OWNER",
                        message: "同一workspace memberが複数profileから宣言されています: \(paths.joined(separator: ", "))",
                        path: paths.first
                    )
                )
            }
            guard updated != profile else { continue }
            profiles[index] = updated
        }
        if cacheChanged { try persistCache() }
        profiles.sort(by: Self.profileOrder)
        return ProjectProfileCatalogResult(
            schemaVersion: "aishell.project-profile-catalog.v1",
            root: ownerRoot.path,
            observedCursor: observedCursor,
            profiles: profiles,
            computedProfiles: computed,
            cachedProfiles: cached
        )
    }

    /// cacheはowner root発見の索引にだけ使い、profile/checkのidentity判断には使わない。
    /// 指定projectを含むfresh catalogだけからexact profile/checkを選ぶ。
    public func resolveExactCheck(
        projectID: String,
        profileDigest: String,
        checkID: String,
        sinceCursor: String? = nil
    ) async throws -> ProjectProfileCheckResolution {
        try loadCacheIfNeeded()
        let roots = Dictionary(
            grouping: cache.values.filter { $0.profile.projectId == projectID },
            by: \.ownerRootPath
        )
        guard !roots.isEmpty else { throw ProjectProfileResolutionError.projectNotFound(projectID) }
        guard roots.count == 1 else { throw ProjectProfileResolutionError.projectAmbiguous(projectID) }
        var matches: [(catalog: ProjectProfileCatalogResult, profile: ProjectProfile)] = []
        for ownerRoot in roots.keys.sorted() {
            guard let entries = roots[ownerRoot], let indexed = entries.sorted(by: {
                $0.profile.observedCursor < $1.profile.observedCursor
            }).last else { continue }
            let snapshot = try await workspaceRuntime.snapshot(
                path: ownerRoot,
                sinceCursor: sinceCursor ?? indexed.profile.observedCursor,
                entryLimit: 1,
                contextBudget: 0
            )
            let fresh = try await catalog(for: snapshot)
            matches += fresh.profiles.filter { $0.projectId == projectID }.map { (fresh, $0) }
        }
        guard matches.count == 1, let match = matches.first else {
            if matches.isEmpty { throw ProjectProfileResolutionError.projectNotFound(projectID) }
            throw ProjectProfileResolutionError.projectAmbiguous(projectID)
        }
        let fresh = match.catalog
        let profile = match.profile
        guard profile.profileDigest == profileDigest else {
            throw ProjectProfileResolutionError.profileDigestChanged(
                expected: profileDigest,
                actual: profile.profileDigest
            )
        }
        let checks = profile.checks.filter { $0.checkId == checkID }
        guard checks.count == 1, let check = checks.first else {
            if checks.isEmpty { throw ProjectProfileResolutionError.checkNotFound(checkID) }
            throw ProjectProfileResolutionError.checkAmbiguous(checkID)
        }
        return ProjectProfileCheckResolution(
            catalogRoot: fresh.root,
            observedCursor: fresh.observedCursor,
            profile: profile,
            check: check
        )
    }

    /// focused preparation receiptのprofile digestを、cacheのprofile stateではなくfresh catalogへ
    /// exact joinする。root indexの候補の一つでも再観測不能なら、そのままfail closedする。
    public func resolveExactProfile(
        profileDigest: String,
        sinceCursor: String? = nil
    ) async throws -> ProjectProfileResolution {
        try loadCacheIfNeeded()
        let roots = Dictionary(
            grouping: cache.values.filter { $0.profile.profileDigest == profileDigest },
            by: \.ownerRootPath
        )
        guard !roots.isEmpty else { throw ProjectProfileResolutionError.profileDigestNotFound(profileDigest) }
        guard roots.count == 1 else { throw ProjectProfileResolutionError.profileDigestAmbiguous(profileDigest) }
        var catalogs: [ProjectProfileCatalogResult] = []
        for ownerRoot in roots.keys.sorted() {
            guard let entries = roots[ownerRoot], let indexed = entries.sorted(by: {
                $0.profile.observedCursor < $1.profile.observedCursor
            }).last else { continue }
            let snapshot = try await workspaceRuntime.snapshot(
                path: ownerRoot,
                sinceCursor: sinceCursor ?? indexed.profile.observedCursor,
                entryLimit: 1,
                contextBudget: 0
            )
            catalogs.append(try await catalog(for: snapshot))
        }
        return try Self.selectExactProfile(profileDigest: profileDigest, catalogs: catalogs)
    }

    /// fresh catalog群からのclosed exact choice。複数hitは同一digestでも受理しない。
    static func selectExactProfile(
        profileDigest: String,
        catalogs: [ProjectProfileCatalogResult]
    ) throws -> ProjectProfileResolution {
        let matches = catalogs.flatMap { catalog in
            catalog.profiles.filter { $0.profileDigest == profileDigest }.map { (catalog, $0) }
        }
        guard matches.count == 1, let match = matches.first else {
            if matches.isEmpty { throw ProjectProfileResolutionError.profileDigestNotFound(profileDigest) }
            throw ProjectProfileResolutionError.profileDigestAmbiguous(profileDigest)
        }
        return ProjectProfileResolution(
            catalogRoot: match.0.root,
            observedCursor: match.0.observedCursor,
            profile: match.1
        )
    }

    public func invalidateAll() throws {
        cache.removeAll()
        cacheLoaded = true
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            try FileManager.default.removeItem(at: cacheURL)
        }
    }

    func providerInvocationCountForTests(_ ecosystem: String) -> Int {
        providerInvocationCounts[ecosystem, default: 0]
    }

    func setInputContractForTests(
        ecosystem: String,
        kind: String,
        contract: ProjectProfileCheckInputContract
    ) {
        inputContractsForTests["\(ecosystem)\u{0}\(kind)"] = contract
    }

    private func loadCacheIfNeeded() throws {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        do {
            let envelope = try JSONDecoder().decode(CacheEnvelope.self, from: Data(contentsOf: cacheURL))
            guard envelope.schema == "aishell.project-profile-cache.v1" else {
                throw AIShellError.checkpointUnsupported(envelope.schema)
            }
            var restored: [String: CacheEntry] = [:]
            for entry in envelope.entries {
                guard restored[entry.profile.projectId] == nil else {
                    throw AIShellError.checkpointCorrupt("project profile cache has duplicate project ID")
                }
                guard entry.profile.binding == entry.input.binding,
                      entry.profile.profileDigest == (try Self.semanticDigest(entry.profile)),
                      Dictionary(uniqueKeysWithValues: entry.profile.manifests.map { ($0.path, $0.sha256) }) == entry.input.fileHashes,
                      Dictionary(uniqueKeysWithValues: entry.profile.manifests.map { ($0.path, $0.identity) }) == entry.input.fileIdentities else {
                    throw AIShellError.checkpointCorrupt("project profile cache binding or digest mismatch")
                }
                restored[entry.profile.projectId] = entry
            }
            cache = restored
        } catch let error as AIShellError {
            throw error
        } catch {
            throw AIShellError.checkpointCorrupt("project profile cache decode failed: \(error)")
        }
    }

    private func persistCache() throws {
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let entries = cache.values.sorted {
            if $0.catalogKey != $1.catalogKey { return $0.catalogKey < $1.catalogKey }
            return $0.profile.projectId < $1.profile.projectId
        }
        do {
            try encoder.encode(CacheEnvelope(schema: "aishell.project-profile-cache.v1", entries: entries))
                .write(to: cacheURL, options: .atomic)
        } catch {
            throw AIShellError.checkpointWriteFailed("project profile cache write failed: \(error)")
        }
    }

    private func discover(ownerRoot: URL) throws -> [Candidate] {
        let manager = FileManager.default
        var result: [Candidate] = []

        func appendCandidate(_ discoveredURL: URL) throws {
            let discoveredValues = try discoveredURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard discoveredValues.isSymbolicLink != true else { return }
            let url = try Self.canonicalURL(discoveredURL)
            let relative = Self.relative(url, to: ownerRoot)
            let components = relative.split(separator: "/").map(String.init)
            guard let spec = Self.providers.first(where: { $0.manifest == url.lastPathComponent }) else { return }
            let root = url.deletingLastPathComponent()
            guard root.path == ownerRoot.path || root.path.hasPrefix(ownerRoot.path + "/") else { return }
            let relativeRoot = Self.relative(root, to: ownerRoot)
            let manifestPath = Self.relative(url, to: ownerRoot)
            let identity = try Self.fileIdentity(root)
            let descriptor: [String: Any] = [
                "ecosystem": spec.ecosystem,
                "owner_root_identity": try Self.fileIdentity(ownerRoot),
                "primary_manifest": manifestPath,
                "project_root": relativeRoot,
                "schema": "aishell.project-id.v1",
            ]
            let auxiliary = Set(components.dropLast()).contains { ["fixtures", "examples", "benchmarks", "vendor"].contains($0) }
            result.append(Candidate(
                ownerRoot: ownerRoot,
                projectRoot: root,
                relativeRoot: relativeRoot,
                manifestURL: url,
                manifestPath: manifestPath,
                spec: spec,
                classification: auxiliary ? "auxiliary" : "primary",
                rootIdentity: identity,
                projectId: try Self.digestJSON(descriptor)
            ))
        }

        let manifestNames = Set(Self.providers.map(\.manifest))
        if let visibleManifests = try Self.gitVisibleFiles(under: ownerRoot, fileNames: manifestNames) {
            for url in visibleManifests {
                try appendCandidate(url)
            }
        } else {
            guard let enumerator = manager.enumerator(
                at: ownerRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            while let discoveredURL = enumerator.nextObject() as? URL {
                let discoveredValues = try discoveredURL.resourceValues(forKeys: [.isDirectoryKey])
                if discoveredValues.isDirectory == true,
                   [".git", ".build", "node_modules", ".aishell-transactions"].contains(discoveredURL.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                try appendCandidate(discoveredURL)
            }
        }
        return result.sorted {
            if $0.relativeRoot != $1.relativeRoot { return $0.relativeRoot.utf8.lexicographicallyPrecedes($1.relativeRoot.utf8) }
            if $0.spec.ecosystem != $1.spec.ecosystem { return $0.spec.ecosystem < $1.spec.ecosystem }
            return $0.manifestPath < $1.manifestPath
        }
    }

    private func inputState(
        for candidate: Candidate,
        policyDigest: String,
        cursor: ObservationCursor
    ) async throws -> InputState {
        let currentProjectRootIdentity = try Self.fileIdentity(candidate.projectRoot)
        guard currentProjectRootIdentity == candidate.rootIdentity else {
            throw AIShellError.contentChanged(candidate.relativeRoot)
        }
        var hashes: [String: String] = [:]
        var identities: [String: String] = [:]
        let primary = try Self.hashFile(candidate.manifestURL)
        hashes[candidate.manifestPath] = primary
        identities[candidate.manifestPath] = try Self.fileIdentity(candidate.manifestURL)
        for name in candidate.spec.related {
            let url = candidate.projectRoot.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                hashes[Self.relative(url, to: candidate.ownerRoot)] = try Self.hashFile(url)
                identities[Self.relative(url, to: candidate.ownerRoot)] = try Self.fileIdentity(url)
            }
        }
        if candidate.spec.ecosystem == "swiftpm" {
            let config = candidate.projectRoot.appendingPathComponent(".swiftpm/configuration", isDirectory: true)
            for url in try Self.regularFiles(under: config) {
                hashes[Self.relative(url, to: candidate.ownerRoot)] = try Self.hashFile(url)
                identities[Self.relative(url, to: candidate.ownerRoot)] = try Self.fileIdentity(url)
            }
        }
        var sourceLayout = try Self.sourceLayout(in: candidate)
        if candidate.spec.ecosystem == "npm" {
            do {
                sourceLayout.append(contentsOf: try Self.npmMemberLayout(in: candidate).map { "workspace-member:\($0)" })
            } catch {
                sourceLayout.append("workspace-declaration-invalid:\(Self.sha256(Data(String(describing: error).utf8)))")
            }
            sourceLayout.sort()
        }
        let toolchainNames = candidate.spec.ecosystem == "swiftpm" ? ["swift"]
            : (candidate.spec.ecosystem == "npm" ? ["node", "npm"] : [])
        var toolchainBindings: [String] = []
        for name in toolchainNames {
            guard let executable = Self.resolveExecutable(name) else {
                toolchainBindings.append("\(name):unavailable")
                continue
            }
            do {
                let evidence = try await probeToolchain(name: name, executable: executable, versionArguments: ["--version"])
                toolchainBindings.append("\(name):\(evidence.identity):\(evidence.sha256):\(evidence.evidenceSHA256):\(evidence.version)")
            } catch {
                toolchainBindings.append("\(name):probe-failed:\(Self.sha256(Data(String(describing: error).utf8)))")
            }
        }
        let toolchainIdentity = toolchainBindings.isEmpty ? nil : toolchainBindings.joined(separator: "|")
        var bindingEnvironmentKeys = environmentKeys
        if candidate.spec.ecosystem == "npm",
           let data = try? Data(contentsOf: candidate.manifestURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let declared = try? Self.declaredNPMChecks(json: json) {
            bindingEnvironmentKeys.append(contentsOf: declared.values.flatMap(\.environmentKeys))
            bindingEnvironmentKeys = Array(Set(bindingEnvironmentKeys)).sorted()
        }
        var environment: [String: String] = [:]
        let liveEnvironment = ProcessInfo.processInfo.environment
        for key in bindingEnvironmentKeys {
            environment[key] = liveEnvironment[key]
                .map { "set:\(Self.sha256(Data($0.utf8)))" }
                ?? "absent"
        }
        let object: [String: Any] = [
            "environment": environment,
            "files": hashes,
            "file_identities": identities,
            "owner_root_path": candidate.ownerRoot.path,
            "owner_root_identity": try Self.fileIdentity(candidate.ownerRoot),
            "observation_exclusion_digest": cursor.exclusionDigest,
            "observation_generation": cursor.generation,
            "observation_root_digest": cursor.rootDigest,
            "policy_digest": policyDigest,
            "project_root_identity": currentProjectRootIdentity,
            "provider": candidate.spec.ecosystem,
            "provider_version": providerVersion,
            "source_layout": sourceLayout,
            "toolchain_identity": toolchainIdentity ?? NSNull(),
        ]
        return InputState(
            binding: try Self.digestJSON(object),
            fileHashes: hashes,
            fileIdentities: identities,
            sourceLayout: sourceLayout,
            toolchainIdentity: toolchainIdentity
        )
    }

    private func compute(
        _ candidate: Candidate,
        input: InputState,
        policyDigest: String,
        observationCursor: ObservationCursor,
        cursor: String,
        reasons: [ProjectProfileInvalidationReason]
    ) async throws -> ProjectProfile {
        providerInvocationCounts[candidate.spec.ecosystem, default: 0] += 1
        let beforeSHA = try Self.hashFile(candidate.manifestURL)
        var status: ProjectProfileStatus = candidate.spec.fullySupported ? .complete : .partial
        var diagnostics: [ProjectProfileDiagnostic] = candidate.spec.fullySupported ? [] : [
            ProjectProfileDiagnostic(
                code: "PROVIDER_PARTIAL",
                message: "\(candidate.spec.ecosystem) providerはmanifest発見だけを所有し、target/check/toolchain解析は未対応です。",
                path: candidate.manifestPath
            )
        ]
        var missing = candidate.spec.fullySupported ? [] : ["targets", "checks", "toolchain"]
        var targets: [ProjectProfileTarget] = []
        var checks: [ProjectProfileCheck] = []
        var toolchains: [ProjectProfileToolchain] = []
        var providerEvidence: ProjectProfileEvidence?
        let provenance = ProjectProfileProvenance(
            kind: "manifest",
            path: candidate.manifestPath,
            contentSHA256: beforeSHA,
            producerVersion: providerVersion,
            confidence: "declared"
        )
        do {
            if candidate.spec.ecosystem == "npm" {
                let parsed = try await parseNPM(candidate, provenance: provenance)
                targets = parsed.targets
                checks = parsed.checks
                toolchains = parsed.toolchains
            } else if candidate.spec.ecosystem == "swiftpm" {
                let parsed = try await parseSwiftPM(candidate, provenance: provenance)
                targets = parsed.targets
                checks = parsed.checks
                toolchains = parsed.toolchains
                providerEvidence = parsed.providerEvidence
            }
        } catch {
            if let execution = error as? ProviderExecutionError,
               case .artifactWrite = execution {
                throw execution
            }
            let failure = Self.providerFailure(error)
            providerEvidence = failure.evidence
            status = failure.invalidManifest ? .invalid : .partial
            missing = failure.invalidManifest ? ["targets", "checks"] : ["targets", "checks", "toolchain"]
            diagnostics = [ProjectProfileDiagnostic(
                code: failure.code,
                message: String(describing: error),
                path: failure.path ?? candidate.manifestPath,
                evidence: failure.evidence
            )]
        }
        guard try Self.hashFile(candidate.manifestURL) == beforeSHA else {
            throw AIShellError.contentChanged(candidate.manifestPath)
        }
        guard try await inputState(for: candidate, policyDigest: policyDigest, cursor: observationCursor) == input else {
            throw AIShellError.contentChanged(candidate.manifestPath)
        }
        targets.sort { $0.targetId < $1.targetId }
        checks.sort { $0.checkId < $1.checkId }
        let manifests = input.fileHashes.keys.sorted().map { path in
            ProjectProfileManifest(
                path: path,
                role: path == candidate.manifestPath ? "primary" : (path.lowercased().contains("lock") || path.lowercased().contains("shrinkwrap") || path.lowercased().hasSuffix("resolved") ? "lockfile" : "configuration"),
                identity: input.fileIdentities[path]!,
                sha256: input.fileHashes[path]!,
                parseStatus: status == .invalid && path == candidate.manifestPath ? "invalid"
                    : (candidate.spec.fullySupported ? "parsed" : "recognized")
            )
        }
        let semantic: [String: Any] = [
            "binding": input.binding, "checks": checks.map { $0.checkId },
            "classification": candidate.classification, "diagnostics": diagnostics.map { $0.code },
            "ecosystem": candidate.spec.ecosystem, "manifests": input.fileHashes,
            "member_project_ids": [String](), "project_id": candidate.projectId,
            "provider_evidence_sha256": providerEvidence?.sha256 ?? NSNull(),
            "status": status.rawValue, "targets": targets.map { $0.targetId },
            "toolchains": toolchains.map { "\($0.identity):\($0.sha256):\($0.evidenceSHA256):\($0.version)" },
        ]
        return ProjectProfile(
            schemaVersion: "aishell.project-profile.v1",
            projectId: candidate.projectId,
            projectRoot: candidate.relativeRoot,
            projectRootIdentity: candidate.rootIdentity,
            displayName: candidate.projectRoot.lastPathComponent,
            ecosystem: candidate.spec.ecosystem,
            classification: candidate.classification,
            status: status,
            provider: candidate.spec.ecosystem,
            providerVersion: providerVersion,
            manifests: manifests,
            memberProjectIds: [],
            targets: targets,
            checks: checks,
            toolchains: toolchains,
            providerEvidence: providerEvidence,
            missingCapabilities: missing,
            diagnostics: diagnostics,
            binding: input.binding,
            freshness: .freshComputed,
            observedCursor: cursor,
            profileDigest: try Self.digestJSON(semantic),
            invalidationReasons: reasons
        )
    }

    private func parseNPM(
        _ candidate: Candidate,
        provenance: ProjectProfileProvenance
    ) async throws -> (targets: [ProjectProfileTarget], checks: [ProjectProfileCheck], toolchains: [ProjectProfileToolchain]) {
        let data = try Data(contentsOf: candidate.manifestURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIShellError.invalidArgument("package.jsonはobjectである必要があります。")
        }
        _ = try Self.npmWorkspacePatterns(json: json, candidate: candidate)
        for lockName in candidate.spec.related {
            let lockURL = candidate.projectRoot.appendingPathComponent(lockName)
            guard FileManager.default.fileExists(atPath: lockURL.path) else { continue }
            let lockObject: Any
            do {
                lockObject = try JSONSerialization.jsonObject(with: Data(contentsOf: lockURL))
            } catch {
                throw ProviderExecutionError.lockfileInvalid(Self.relative(lockURL, to: candidate.ownerRoot))
            }
            guard lockObject is [String: Any] else {
                throw ProviderExecutionError.lockfileInvalid(Self.relative(lockURL, to: candidate.ownerRoot))
            }
        }
        let providerKey = json["name"] as? String ?? candidate.relativeRoot
        let displayName = providerKey.isEmpty ? candidate.projectRoot.lastPathComponent : providerKey
        let targetId = try Self.stableId([
            "kind": "library", "profile_id": candidate.projectId,
            "provider_target_key": providerKey, "schema": "aishell.target-id.v1",
        ])
        let target = ProjectProfileTarget(
            targetId: targetId,
            name: displayName,
            kind: "library",
            dependencies: ((json["dependencies"] as? [String: Any])?.keys.sorted() ?? []),
            sourceRoots: sourceRoots(candidate),
            resourceRoots: [],
            testRelation: nil,
            provenance: provenance
        )
        let scripts = json["scripts"] as? [String: Any] ?? [:]
        guard let npm = Self.resolveExecutable("npm") else { throw AIShellError.workerUnavailable("npm") }
        guard let node = Self.resolveExecutable("node") else { throw AIShellError.workerUnavailable("node") }
        let toolchain = try await probeToolchain(name: "npm", executable: npm, versionArguments: ["--version"])
        let nodeToolchain = try await probeToolchain(name: "node", executable: node, versionArguments: ["--version"])
        let declaredChecks = try Self.declaredNPMChecks(json: json)
        let checks = try ["build", "test", "lint"].compactMap { kind -> ProjectProfileCheck? in
            if let declared = declaredChecks[kind] {
                return try makeCheck(
                    candidate: candidate, kind: kind, key: kind,
                    executable: declared.executable.path, arguments: declared.arguments,
                    displayCommand: ([declared.executable.lastPathComponent] + declared.arguments).joined(separator: " "),
                    provenance: provenance, environmentKeys: declared.environmentKeys,
                    inputContract: declared.inputContract
                )
            }
            guard scripts[kind] is String else { return nil }
            return try makeCheck(
                candidate: candidate, kind: kind, key: kind,
                executable: npm.path, arguments: ["run", kind, "--"],
                displayCommand: kind == "test" ? "npm test" : "npm run \(kind)", provenance: provenance
            )
        }
        return ([target], checks, [nodeToolchain, toolchain])
    }

    /// package.jsonの明示宣言だけをcache eligibleなcheckへ昇格する。
    /// script本文のshell分解や入力推測は行わず、closed argv/input/effectをfail-closedで検証する。
    private static func declaredNPMChecks(json: [String: Any]) throws -> [String: DeclaredNPMCheck] {
        guard let rawAIShell = json["aishell"] else { return [:] }
        guard let aishell = rawAIShell as? [String: Any],
              Set(aishell.keys) == ["schemaVersion", "checks"],
              aishell["schemaVersion"] as? String == "aishell.package-profile.v1",
              let checks = aishell["checks"] as? [String: Any] else {
            throw AIShellError.invalidArgument("package.json aishell宣言がaishell.package-profile.v1のclosed objectではありません。")
        }
        let supportedKinds = Set(["build", "test", "lint"])
        guard Set(checks.keys).isSubset(of: supportedKinds) else {
            throw AIShellError.invalidArgument("package.json aishell.checksに未対応kindがあります。")
        }
        var result: [String: DeclaredNPMCheck] = [:]
        for kind in checks.keys.sorted() {
            guard let check = checks[kind] as? [String: Any],
                  Set(check.keys) == ["executable", "arguments", "environmentKeys", "includedRoots", "trackedPaths", "effects"],
                  let executableName = check["executable"] as? String,
                  executableName == "node",
                  let executable = resolveExecutable(executableName),
                  let arguments = check["arguments"] as? [String],
                  arguments.allSatisfy({ !$0.contains("\0") }),
                  let environmentKeys = check["environmentKeys"] as? [String],
                  let includedRoots = check["includedRoots"] as? [String],
                  let trackedPaths = check["trackedPaths"] as? [String],
                  check["effects"] as? String == ProjectProfileCheckEffectCompleteness.projectRootClosed.rawValue else {
                throw AIShellError.invalidArgument("package.json aishell.checks.\(kind)がclosed check宣言ではありません。")
            }
            let included = try canonicalContractPaths(includedRoots, field: "includedRoots")
            let tracked = try canonicalContractPaths(trackedPaths, field: "trackedPaths")
            let environment = try canonicalEnvironmentKeys(environmentKeys)
            guard !included.isEmpty, Set(included).isDisjoint(with: Set(tracked)) else {
                throw AIShellError.invalidArgument("package.json aishell.checks.\(kind)のinput closureが空又は重複しています。")
            }
            result[kind] = DeclaredNPMCheck(
                executable: executable,
                arguments: arguments,
                environmentKeys: environment,
                inputContract: .complete(
                    provider: "npm-manifest",
                    providerVersion: "aishell.package-profile.v1",
                    includedRoots: included,
                    trackedPaths: tracked
                )
            )
        }
        return result
    }

    private static func canonicalContractPaths(_ paths: [String], field: String) throws -> [String] {
        guard Set(paths).count == paths.count else {
            throw AIShellError.invalidArgument("package.json aishell checkの\(field)に重複があります。")
        }
        for path in paths {
            let normalized = path.precomposedStringWithCanonicalMapping
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path == normalized, !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw AIShellError.invalidArgument("package.json aishell checkの\(field)に非canonical pathがあります: \(path)")
            }
        }
        return paths.sorted()
    }

    private static func canonicalEnvironmentKeys(_ keys: [String]) throws -> [String] {
        let valid = /^[A-Za-z_][A-Za-z0-9_]*$/
        guard Set(keys).count == keys.count, keys.allSatisfy({ $0.wholeMatch(of: valid) != nil }) else {
            throw AIShellError.invalidArgument("package.json aishell checkのenvironmentKeysが不正です。")
        }
        return keys.sorted()
    }

    private func parseSwiftPM(
        _ candidate: Candidate,
        provenance: ProjectProfileProvenance
    ) async throws -> (
        targets: [ProjectProfileTarget], checks: [ProjectProfileCheck],
        toolchains: [ProjectProfileToolchain], providerEvidence: ProjectProfileEvidence
    ) {
        guard let swift = Self.resolveExecutable("swift") else { throw AIShellError.workerUnavailable("swift") }
        let execution = try Self.run(swift, ["package", "--package-path", candidate.projectRoot.path, "dump-package"])
        let artifact = try await persistEvidence(
            stdout: execution.stdout, stderr: execution.stderr, exitStatus: execution.exitStatus,
            kind: "project-profile-provider"
        )
        let providerEvidence = ProjectProfileEvidence(
            exitStatus: execution.exitStatus, sha256: artifact.sha256,
            handle: artifact.handle, expiresAt: artifact.expiresAt
        )
        guard execution.exitStatus == 0 else {
            throw ProviderExecutionError.providerNonzero(
                execution.exitStatus,
                String(data: execution.stderr, encoding: .utf8) ?? "stderr is not lossless UTF-8",
                providerEvidence
            )
        }
        let data = execution.stdout
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawTargets = json["targets"] as? [[String: Any]] else {
            throw AIShellError.invalidArgument("swift package dump-packageのtarget graphが不正です。")
        }
        let targets = try rawTargets.map { raw -> ProjectProfileTarget in
            guard let name = raw["name"] as? String else { throw AIShellError.invalidArgument("Swift target nameがありません。") }
            let rawType = raw["type"] as? String ?? "unknown"
            let kind = ["executable", "test", "plugin"].contains(rawType) ? rawType
                : (rawType == "regular" ? "library" : "unknown")
            let id = try Self.stableId([
                "kind": kind, "profile_id": candidate.projectId,
                "provider_target_key": name, "schema": "aishell.target-id.v1",
            ])
            let declaredPath = raw["path"] as? String
            let defaultPath = kind == "test" ? "Tests/\(name)" : "Sources/\(name)"
            let sourcePath = declaredPath ?? defaultPath
            let prefix = candidate.relativeRoot.isEmpty ? "" : candidate.relativeRoot + "/"
            let resources = (raw["resources"] as? [[String: Any]] ?? [])
                .compactMap { $0["path"] as? String }
                .map { prefix + sourcePath + "/" + $0 }
            return ProjectProfileTarget(
                targetId: id, name: name, kind: kind,
                dependencies: Self.swiftDependencies(raw["dependencies"]),
                sourceRoots: [prefix + sourcePath], resourceRoots: resources,
                testRelation: kind == "test" ? "package-tests" : nil, provenance: provenance
            )
        }
        let toolchain = try await probeToolchain(name: "swift", executable: swift, versionArguments: ["--version"])
        let checks = try ["build", "test"].map {
            try makeCheck(candidate: candidate, kind: $0, key: $0, executable: swift.path, arguments: [$0],
                          displayCommand: "swift \($0)", provenance: provenance)
        }
        return (targets, checks, [toolchain], providerEvidence)
    }

    private func makeCheck(
        candidate: Candidate,
        kind: String,
        key: String,
        executable: String,
        arguments: [String],
        displayCommand: String? = nil,
        provenance: ProjectProfileProvenance,
        environmentKeys declaredEnvironmentKeys: [String]? = nil,
        inputContract: ProjectProfileCheckInputContract? = nil
    ) throws -> ProjectProfileCheck {
        let id = try Self.stableId([
            "kind": kind, "profile_id": candidate.projectId, "provider_check_key": key,
            "schema": "aishell.check-id.v1", "scope_id": candidate.projectId,
        ])
        return ProjectProfileCheck(
            checkId: id, kind: kind, label: key,
            displayCommand: displayCommand,
            executable: executable, arguments: arguments,
            workingDirectory: candidate.projectRoot.path,
            environmentKeys: declaredEnvironmentKeys ?? environmentKeys,
            provenance: provenance,
            inputContract: inputContract
                ?? inputContractsForTests["\(candidate.spec.ecosystem)\u{0}\(kind)"]
                ?? .ineligible(
                    provider: candidate.spec.ecosystem,
                    providerVersion: providerVersion,
                    reason: "providerはnetwork・project root外・生成物directoryへのeffect完全性を証明しません"
                )
        )
    }

    private func invalidationReasons(previous: InputState?, current: InputState) -> [ProjectProfileInvalidationReason] {
        guard let previous else {
            return [ProjectProfileInvalidationReason(kind: "initial_computation", path: nil, oldSHA256: nil, newSHA256: nil)]
        }
        var reasons: [ProjectProfileInvalidationReason] = []
        for path in Set(previous.fileHashes.keys).union(current.fileHashes.keys).sorted() {
            let old = previous.fileHashes[path]
            let new = current.fileHashes[path]
            if old != new {
                reasons.append(ProjectProfileInvalidationReason(
                    kind: old == nil ? "binding_file_created" : (new == nil ? "binding_file_deleted" : "binding_file_modified"),
                    path: path, oldSHA256: old, newSHA256: new
                ))
            }
        }
        for path in Set(previous.fileIdentities.keys).union(current.fileIdentities.keys).sorted() {
            let old = previous.fileIdentities[path]
            let new = current.fileIdentities[path]
            if old != new, previous.fileHashes[path] == current.fileHashes[path] {
                reasons.append(ProjectProfileInvalidationReason(
                    kind: "binding_file_identity_changed", path: path,
                    oldSHA256: old.map { Self.sha256(Data($0.utf8)) },
                    newSHA256: new.map { Self.sha256(Data($0.utf8)) }
                ))
            }
        }
        if previous.sourceLayout != current.sourceLayout {
            reasons.append(ProjectProfileInvalidationReason(kind: "source_layout_changed", path: nil, oldSHA256: Self.digestStrings(previous.sourceLayout), newSHA256: Self.digestStrings(current.sourceLayout)))
        }
        if previous.toolchainIdentity != current.toolchainIdentity {
            reasons.append(ProjectProfileInvalidationReason(kind: "toolchain_identity_changed", path: nil, oldSHA256: previous.toolchainIdentity.map { Self.sha256(Data($0.utf8)) }, newSHA256: current.toolchainIdentity.map { Self.sha256(Data($0.utf8)) }))
        }
        if reasons.isEmpty {
            reasons.append(ProjectProfileInvalidationReason(kind: "provider_or_environment_changed", path: nil, oldSHA256: previous.binding, newSHA256: current.binding))
        }
        return reasons
    }

    private func npmMemberMap(candidates: [Candidate]) -> (members: [String: [String]], conflicts: [String: [String]]) {
        let byRoot = Dictionary(uniqueKeysWithValues: candidates
            .filter { $0.spec.ecosystem == "npm" }
            .map { ($0.relativeRoot, $0.projectId) })
        var result: [String: [String]] = [:]
        var ownersByMember: [String: [(owner: String, path: String)]] = [:]
        for candidate in candidates where candidate.spec.ecosystem == "npm" {
            guard let data = try? Data(contentsOf: candidate.manifestURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard let patterns = try? Self.npmWorkspacePatterns(json: json, candidate: candidate) else { continue }
            var members: [String] = []
            for (root, id) in byRoot where id != candidate.projectId {
                let relative: String
                if candidate.relativeRoot.isEmpty { relative = root }
                else if root.hasPrefix(candidate.relativeRoot + "/") { relative = String(root.dropFirst(candidate.relativeRoot.count + 1)) }
                else { continue }
                if patterns.contains(where: { Self.glob($0, matches: relative) }) {
                    members.append(id)
                    ownersByMember[id, default: []].append((candidate.projectId, root))
                }
            }
            result[candidate.projectId] = members.sorted()
        }
        var conflicts: [String: [String]] = [:]
        for owners in ownersByMember.values where Set(owners.map(\.owner)).count > 1 {
            for owner in owners {
                conflicts[owner.owner, default: []].append(owner.path)
            }
        }
        return (
            result,
            conflicts.mapValues { Array(Set($0)).sorted() }
        )
    }

    private func copy(
        _ profile: ProjectProfile,
        freshness: ProjectProfileFreshness,
        cursor: String,
        reasons: [ProjectProfileInvalidationReason]
    ) -> ProjectProfile {
        return ProjectProfile(
            schemaVersion: profile.schemaVersion, projectId: profile.projectId,
            projectRoot: profile.projectRoot, projectRootIdentity: profile.projectRootIdentity,
            displayName: profile.displayName, ecosystem: profile.ecosystem,
            classification: profile.classification, status: profile.status,
            provider: profile.provider, providerVersion: profile.providerVersion,
            manifests: profile.manifests, memberProjectIds: profile.memberProjectIds,
            targets: profile.targets, checks: profile.checks, toolchains: profile.toolchains,
            providerEvidence: profile.providerEvidence,
            missingCapabilities: profile.missingCapabilities, diagnostics: profile.diagnostics,
            binding: profile.binding, freshness: freshness, observedCursor: cursor,
            profileDigest: profile.profileDigest, invalidationReasons: reasons
        )
    }

    private func copy(_ profile: ProjectProfile, members: [String]) throws -> ProjectProfile {
        let updated = ProjectProfile(
            schemaVersion: profile.schemaVersion, projectId: profile.projectId,
            projectRoot: profile.projectRoot, projectRootIdentity: profile.projectRootIdentity,
            displayName: profile.displayName, ecosystem: profile.ecosystem,
            classification: profile.classification, status: profile.status,
            provider: profile.provider, providerVersion: profile.providerVersion,
            manifests: profile.manifests, memberProjectIds: members,
            targets: profile.targets, checks: profile.checks, toolchains: profile.toolchains,
            providerEvidence: profile.providerEvidence,
            missingCapabilities: profile.missingCapabilities, diagnostics: profile.diagnostics,
            binding: profile.binding, freshness: profile.freshness, observedCursor: profile.observedCursor,
            profileDigest: "", invalidationReasons: profile.invalidationReasons
        )
        return ProjectProfile(
            schemaVersion: updated.schemaVersion, projectId: updated.projectId,
            projectRoot: updated.projectRoot, projectRootIdentity: updated.projectRootIdentity,
            displayName: updated.displayName, ecosystem: updated.ecosystem,
            classification: updated.classification, status: updated.status,
            provider: updated.provider, providerVersion: updated.providerVersion,
            manifests: updated.manifests, memberProjectIds: updated.memberProjectIds,
            targets: updated.targets, checks: updated.checks, toolchains: updated.toolchains,
            providerEvidence: updated.providerEvidence,
            missingCapabilities: updated.missingCapabilities, diagnostics: updated.diagnostics,
            binding: updated.binding, freshness: updated.freshness, observedCursor: updated.observedCursor,
            profileDigest: try Self.semanticDigest(updated), invalidationReasons: updated.invalidationReasons
        )
    }

    private func copyInvalid(_ profile: ProjectProfile, diagnostic: ProjectProfileDiagnostic) throws -> ProjectProfile {
        let diagnostics = (profile.diagnostics.filter { $0.code != diagnostic.code } + [diagnostic])
            .sorted { $0.code == $1.code ? ($0.path ?? "") < ($1.path ?? "") : $0.code < $1.code }
        let updated = ProjectProfile(
            schemaVersion: profile.schemaVersion, projectId: profile.projectId,
            projectRoot: profile.projectRoot, projectRootIdentity: profile.projectRootIdentity,
            displayName: profile.displayName, ecosystem: profile.ecosystem,
            classification: profile.classification, status: .invalid,
            provider: profile.provider, providerVersion: profile.providerVersion,
            manifests: profile.manifests, memberProjectIds: profile.memberProjectIds,
            targets: profile.targets, checks: profile.checks, toolchains: profile.toolchains,
            providerEvidence: profile.providerEvidence,
            missingCapabilities: Array(Set(profile.missingCapabilities + ["workspace_members"])).sorted(),
            diagnostics: diagnostics, binding: profile.binding, freshness: profile.freshness,
            observedCursor: profile.observedCursor, profileDigest: "",
            invalidationReasons: profile.invalidationReasons
        )
        return ProjectProfile(
            schemaVersion: updated.schemaVersion, projectId: updated.projectId,
            projectRoot: updated.projectRoot, projectRootIdentity: updated.projectRootIdentity,
            displayName: updated.displayName, ecosystem: updated.ecosystem,
            classification: updated.classification, status: updated.status,
            provider: updated.provider, providerVersion: updated.providerVersion,
            manifests: updated.manifests, memberProjectIds: updated.memberProjectIds,
            targets: updated.targets, checks: updated.checks, toolchains: updated.toolchains,
            providerEvidence: updated.providerEvidence,
            missingCapabilities: updated.missingCapabilities, diagnostics: updated.diagnostics,
            binding: updated.binding, freshness: updated.freshness, observedCursor: updated.observedCursor,
            profileDigest: try Self.semanticDigest(updated), invalidationReasons: updated.invalidationReasons
        )
    }

    private static func semanticDigest(_ profile: ProjectProfile) throws -> String {
        try digestJSON([
            "binding": profile.binding, "checks": profile.checks.map { $0.checkId },
            "classification": profile.classification, "diagnostics": profile.diagnostics.map { $0.code },
            "ecosystem": profile.ecosystem,
            "manifests": Dictionary(uniqueKeysWithValues: profile.manifests.map { ($0.path, $0.sha256) }),
            "member_project_ids": profile.memberProjectIds, "project_id": profile.projectId,
            "provider_evidence_sha256": profile.providerEvidence?.sha256 ?? NSNull(),
            "status": profile.status.rawValue, "targets": profile.targets.map { $0.targetId },
            "toolchains": profile.toolchains.map { "\($0.identity):\($0.sha256):\($0.evidenceSHA256):\($0.version)" },
        ] as [String: Any])
    }

    private func sourceRoots(_ candidate: Candidate) -> [String] {
        let prefix = candidate.relativeRoot.isEmpty ? "" : candidate.relativeRoot + "/"
        return ["Sources", "Tests", "src", "test"].filter {
            FileManager.default.fileExists(atPath: candidate.projectRoot.appendingPathComponent($0).path)
        }.map { prefix + $0 }
    }

    private static func sourceLayout(in candidate: Candidate) throws -> [String] {
        let names = candidate.spec.ecosystem == "swiftpm" ? ["Sources", "Tests"] : ["src", "test", "tests"]
        var result: [String] = []
        for name in names {
            let root = candidate.projectRoot.appendingPathComponent(name, isDirectory: true)
            for url in try regularFiles(under: root) {
                result.append(relative(url, to: candidate.ownerRoot))
            }
        }
        return result.sorted()
    }

    private static func npmMemberLayout(in candidate: Candidate) throws -> [String] {
        let data = try Data(contentsOf: candidate.manifestURL)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let patterns = try npmWorkspacePatterns(json: json, candidate: candidate)
        let packageFiles = try gitVisibleFiles(
            under: candidate.projectRoot,
            fileNames: ["package.json"]
        ) ?? regularFiles(under: candidate.projectRoot).filter { $0.lastPathComponent == "package.json" }
        return packageFiles
            .filter { $0.lastPathComponent == "package.json" && $0.path != candidate.manifestURL.path }
            .compactMap { url -> String? in
                let canonical: URL
                do { canonical = try canonicalURL(url) } catch { return nil }
                guard canonical.path == candidate.ownerRoot.path || canonical.path.hasPrefix(candidate.ownerRoot.path + "/") else {
                    return nil
                }
                let memberRoot = relative(url.deletingLastPathComponent(), to: candidate.projectRoot)
                guard patterns.contains(where: { glob($0, matches: memberRoot) }) else { return nil }
                return relative(url, to: candidate.ownerRoot)
            }
            .sorted()
    }

    private static func npmWorkspacePatterns(json: [String: Any], candidate: Candidate) throws -> [String] {
        let patterns: [String]
        if let list = json["workspaces"] as? [String] { patterns = list }
        else if let object = json["workspaces"] as? [String: Any], let list = object["packages"] as? [String] { patterns = list }
        else { return [] }
        for pattern in patterns {
            let components = pattern.split(separator: "/", omittingEmptySubsequences: false)
            if pattern.hasPrefix("/") || components.contains("..") {
                throw ProviderExecutionError.memberOutsideAllowedRoot(pattern)
            }
            let staticPrefix = components.prefix { !$0.contains("*") && !$0.contains("?") }.joined(separator: "/")
            guard !staticPrefix.isEmpty else { continue }
            let prefixURL = candidate.projectRoot.appendingPathComponent(staticPrefix)
            guard FileManager.default.fileExists(atPath: prefixURL.path) else { continue }
            let canonical = try canonicalURL(prefixURL)
            guard canonical.path == candidate.ownerRoot.path || canonical.path.hasPrefix(candidate.ownerRoot.path + "/") else {
                throw ProviderExecutionError.memberOutsideAllowedRoot(pattern)
            }
        }
        if let enumerator = FileManager.default.enumerator(
            at: candidate.projectRoot,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            while let url = enumerator.nextObject() as? URL {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values.isDirectory == true,
                   [".git", ".build", "node_modules", ".aishell-transactions"].contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                guard values.isSymbolicLink == true else { continue }
                enumerator.skipDescendants()
                let relativePath = relative(url, to: candidate.projectRoot)
                guard patterns.contains(where: { glob($0, matches: relativePath) }) else { continue }
                let canonical = try canonicalURL(url)
                guard canonical.path == candidate.ownerRoot.path || canonical.path.hasPrefix(candidate.ownerRoot.path + "/") else {
                    throw ProviderExecutionError.memberOutsideAllowedRoot(relativePath)
                }
            }
        }
        return patterns
    }

    /// Git workspaceではtracked fileと非ignored untracked fileだけを索引に使う。
    /// `rev-parse`で非Gitと確認できた時だけdirect filesystem列挙へ切り替える。
    private static func gitVisibleFiles(under root: URL, fileNames: Set<String>) throws -> [URL]? {
        let git = URL(fileURLWithPath: "/usr/bin/git")
        guard FileManager.default.isExecutableFile(atPath: git.path) else { return nil }
        let probe = try run(git, ["-C", root.path, "rev-parse", "--is-inside-work-tree"])
        let probeOutput = String(decoding: probe.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if probe.exitStatus != 0 {
            let message = String(decoding: probe.stderr, as: UTF8.self)
            if message.localizedCaseInsensitiveContains("not a git repository") { return nil }
            throw ProviderExecutionError.providerNonzero(probe.exitStatus, message, nil)
        }
        guard probeOutput == "true" else { return nil }

        var arguments = ["-C", root.path, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--"]
        for name in fileNames.sorted() {
            arguments.append(name)
            arguments.append(":(glob)**/\(name)")
        }
        let listing = try run(git, arguments)
        guard listing.exitStatus == 0 else {
            throw ProviderExecutionError.providerNonzero(
                listing.exitStatus,
                String(decoding: listing.stderr, as: UTF8.self),
                nil
            )
        }
        return try listing.stdout.split(separator: 0).compactMap { bytes -> URL? in
            let relative = String(decoding: bytes, as: UTF8.self)
            guard !relative.isEmpty, !relative.hasPrefix("/") else { return nil }
            let components = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.contains(".."), !components.contains(where: \.isEmpty),
                  !components.dropLast().contains(where: { $0.hasPrefix(".") }),
                  !ReservedNamespacePolicy.contains(relativePath: relative) else { return nil }
            let url = root.appendingPathComponent(relative).standardizedFileURL
            guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  fileNames.contains(url.lastPathComponent) else { return nil }
            return url
        }.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    private static func regularFiles(under root: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isDirectory == true, [".git", ".build", "node_modules", ".aishell-transactions"].contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            if values.isRegularFile == true, values.isSymbolicLink != true { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func resolveExecutable(_ name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        for directory in path.split(separator: ":") {
            let url = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url.resolvingSymlinksInPath() }
        }
        return nil
    }

    private func probeToolchain(name: String, executable: URL, versionArguments: [String]) async throws -> ProjectProfileToolchain {
        let executableBinding = try Self.executableBinding(executable)
        let environmentDigest = Self.digestStrings(environmentKeys.map {
            "\($0)=\(Self.sha256(Data((ProcessInfo.processInfo.environment[$0] ?? "").utf8)))"
        })
        let key = "\(name):\(executableBinding):\(versionArguments.joined(separator: "\u{0}")):\(environmentDigest)"
        if let cached = toolchainProbeCache[key], Self.evidenceIsCurrent(cached.evidenceExpiresAt) { return cached }
        do {
            let evidence = try Self.run(executable, versionArguments)
            let artifact = try await persistEvidence(
                stdout: evidence.stdout, stderr: evidence.stderr, exitStatus: evidence.exitStatus,
                kind: "project-profile-toolchain"
            )
            let failureEvidence = ProjectProfileEvidence(
                exitStatus: evidence.exitStatus, sha256: artifact.sha256,
                handle: artifact.handle, expiresAt: artifact.expiresAt
            )
            guard let version = String(data: evidence.stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty else {
                throw ProviderExecutionError.toolchainProbe(
                    "\(name) version evidence is not lossless UTF-8 or is empty", failureEvidence
                )
            }
            guard evidence.exitStatus == 0 else {
                throw ProviderExecutionError.toolchainProbe(
                    String(data: evidence.stderr, encoding: .utf8) ?? "stderr is not lossless UTF-8",
                    failureEvidence
                )
            }
            let result = ProjectProfileToolchain(
                name: name, executable: executable.path,
                identity: try Self.fileIdentity(executable), sha256: try Self.hashFile(executable),
                versionArguments: versionArguments, version: version,
                exitStatus: evidence.exitStatus, evidenceSHA256: artifact.sha256,
                evidenceHandle: artifact.handle, evidenceExpiresAt: artifact.expiresAt
            )
            toolchainProbeCache[key] = result
            return result
        } catch let error as ProviderExecutionError {
            switch error {
            case .toolchainProbe, .artifactWrite: throw error
            default: break
            }
            throw ProviderExecutionError.toolchainProbe(String(describing: error), nil)
        } catch {
            throw ProviderExecutionError.toolchainProbe(String(describing: error), nil)
        }
    }

    private func persistEvidence(
        stdout: Data, stderr: Data, exitStatus: Int32, kind: String
    ) async throws -> (sha256: String, handle: String, expiresAt: String) {
        var framed = Data()
        for bytes in [stdout, stderr] {
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
            framed.append(bytes)
        }
        var status = exitStatus.bigEndian
        withUnsafeBytes(of: &status) { framed.append(contentsOf: $0) }
        do {
            let metadata = try await evidenceStore.store(
                data: framed, kind: kind, producer: "ProjectProfileService",
                retentionSeconds: evidenceRetention
            )
            return (
                metadata.sha256, metadata.handle,
                ISO8601DateFormatter().string(from: metadata.expiresAt)
            )
        } catch {
            throw ProviderExecutionError.artifactWrite(String(describing: error))
        }
    }

    private static func profileEvidenceIsCurrent(_ profile: ProjectProfile) -> Bool {
        profile.toolchains.allSatisfy { evidenceIsCurrent($0.evidenceExpiresAt) }
            && profile.providerEvidence.map { evidenceIsCurrent($0.expiresAt) } ?? true
    }

    private static func evidenceIsCurrent(_ value: String) -> Bool {
        guard let date = ISO8601DateFormatter().date(from: value) else { return false }
        return date > Date()
    }

    private static func swiftDependencies(_ value: Any?) -> [String] {
        guard let dependencies = value as? [[String: Any]] else { return [] }
        var names: [String] = []
        for dependency in dependencies {
            for key in ["byName", "target", "product"] {
                guard let tuple = dependency[key] as? [Any], let name = tuple.first as? String else { continue }
                if !names.contains(name) { names.append(name) }
            }
        }
        return names.sorted()
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws -> ProcessEvidence {
        let process = Process()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("aishell-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outputURL = temporary.appendingPathComponent("stdout")
        let errorURL = temporary.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer {
            try? output.close()
            try? error.close()
        }
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        do { try process.run() } catch { throw ProviderExecutionError.providerLaunch(String(describing: error)) }
        let deadline = Date().addingTimeInterval(providerTimeout)
        while process.isRunning {
            let outputSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
            let errorSize = (try? FileManager.default.attributesOfItem(atPath: errorURL.path)[.size] as? NSNumber)?.intValue ?? 0
            if outputSize > maximumProviderOutputBytes || errorSize > maximumProviderOutputBytes {
                process.terminate()
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw ProviderExecutionError.providerOutputLimit(maximumProviderOutputBytes)
            }
            if Date() >= deadline {
                process.terminate()
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw ProviderExecutionError.providerTimedOut
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        try output.close()
        try error.close()
        let outputSize = (try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
        let errorSize = (try FileManager.default.attributesOfItem(atPath: errorURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard outputSize <= maximumProviderOutputBytes, errorSize <= maximumProviderOutputBytes else {
            throw ProviderExecutionError.providerOutputLimit(maximumProviderOutputBytes)
        }
        let stdout = try Data(contentsOf: outputURL)
        let stderr = try Data(contentsOf: errorURL)
        return ProcessEvidence(stdout: stdout, stderr: stderr, exitStatus: process.terminationStatus)
    }

    private static func providerFailure(
        _ error: Error
    ) -> (code: String, invalidManifest: Bool, path: String?, evidence: ProjectProfileEvidence?) {
        if let execution = error as? ProviderExecutionError {
            switch execution {
            case .memberOutsideAllowedRoot:
                return ("PROJECT_MEMBER_OUTSIDE_WORKSPACE", true, nil, nil)
            case .duplicateWorkspaceOwner:
                return ("PROJECT_MEMBER_DUPLICATE_OWNER", true, nil, nil)
            case .lockfileInvalid(let path):
                return ("PROJECT_MANIFEST_INVALID", true, path, nil)
            case .toolchainProbe(_, let evidence):
                return ("TOOLCHAIN_PROBE_FAILED", false, nil, evidence)
            case .artifactWrite:
                return ("ARTIFACT_WRITE_FAILED", false, nil, nil)
            case .providerNonzero(_, _, let evidence):
                return ("PROJECT_PROVIDER_FAILED", false, nil, evidence)
            case .providerLaunch, .providerTimedOut, .providerOutputLimit:
                return ("PROJECT_PROVIDER_FAILED", false, nil, nil)
            }
        }
        guard let aishell = error as? AIShellError else {
            return ("PROJECT_MANIFEST_INVALID", true, nil, nil)
        }
        switch aishell {
        case .workerUnavailable:
            return ("TOOLCHAIN_UNAVAILABLE", false, nil, nil)
        case .processLaunchFailed: return ("PROJECT_PROVIDER_FAILED", false, nil, nil)
        case .invalidArgument:
            return ("PROJECT_MANIFEST_INVALID", true, nil, nil)
        default:
            return ("PROJECT_PROVIDER_FAILED", false, nil, nil)
        }
    }

    private static func parseObservationCursor(_ cursor: String) throws -> ObservationCursor {
        let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "ws2",
              parts[1].count == 64, parts[2].count == 64,
              parts[1].allSatisfy({ $0.isHexDigit }), parts[2].allSatisfy({ $0.isHexDigit }),
              !parts[3].isEmpty, let sequence = UInt64(parts[4]) else {
            throw AIShellError.cursorExpired(cursor)
        }
        return ObservationCursor(
            rootDigest: String(parts[1]), exclusionDigest: String(parts[2]),
            generation: String(parts[3]), sequence: sequence
        )
    }

    private static func isContinuous(previous: ObservationCursor, current: ObservationCursor) -> Bool {
        previous.rootDigest == current.rootDigest
            && previous.exclusionDigest == current.exclusionDigest
            && previous.generation == current.generation
            && previous.sequence <= current.sequence
    }

    private static func executableBinding(_ url: URL) throws -> String {
        "\(try fileIdentity(url)):\(try hashFile(url))"
    }

    private static func hashFile(_ url: URL) throws -> String {
        sha256(try Data(contentsOf: url, options: .mappedIfSafe))
    }

    private static func fileIdentity(_ url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw AIShellError.invalidPath(url.path) }
        return "\(UInt64(info.st_dev)):\(UInt64(info.st_ino))"
    }

    private static func canonicalURL(_ url: URL) throws -> URL {
        guard let pointer = realpath(url.path, nil) else { throw AIShellError.invalidPath(url.path) }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer), isDirectory: url.hasDirectoryPath)
    }

    private static func relative(_ url: URL, to root: URL) -> String {
        if url.path == root.path { return "" }
        return String(url.path.dropFirst(root.path.count + 1))
    }

    private static func digestJSON(_ value: Any) throws -> String {
        sha256(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]))
    }

    private static func stableId(_ value: [String: String]) throws -> String { try digestJSON(value) }
    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func digestStrings(_ values: [String]) -> String { sha256(Data(values.joined(separator: "\n").utf8)) }

    private static func profileOrder(_ lhs: ProjectProfile, _ rhs: ProjectProfile) -> Bool {
        if lhs.projectRoot != rhs.projectRoot { return lhs.projectRoot.utf8.lexicographicallyPrecedes(rhs.projectRoot.utf8) }
        if lhs.ecosystem != rhs.ecosystem { return lhs.ecosystem < rhs.ecosystem }
        return lhs.manifests.first?.path ?? "" < rhs.manifests.first?.path ?? ""
    }

    private static func glob(_ pattern: String, matches path: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*\\*", with: ".*")
            .replacingOccurrences(of: "\\*", with: "[^/]*")
        return path.range(of: "^\(escaped)$", options: .regularExpression) != nil
    }
}
