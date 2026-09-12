import CryptoKit
import Darwin
import Foundation

/// ADR 0018/0019 の cache ownership seam。invocation と step 順は呼出側が所有する。
public actor CheckFreshnessCache {
    public enum Policy: String, Sendable { case off, prefer, only, refresh }
    public enum TerminalState: String, Codable, Sendable {
        case passed, failed, timedOut = "timed_out", cancelled, signaled, launchFailed = "launch_failed", artifactFailed = "artifact_failed"
        fileprivate var isCacheable: Bool { self == .passed || self == .failed }
    }
    public enum State: String, Codable, Sendable { case disabled, hit, missExecuted = "miss_executed", refreshExecuted = "refresh_executed", ineligible }
    public enum IneligibilityReason: String, Codable, Equatable, Sendable { case bindingUnavailable = "binding_unavailable", bindingIncomplete = "binding_incomplete", unsupported = "unsupported" }
    public enum Binding: Equatable, Sendable {
        case eligible(digest: String)
        case ineligible(reason: IneligibilityReason)

        fileprivate var digest: String? { if case let .eligible(digest) = self { return digest }; return nil }
    }
    public enum LookupStatus: String, Codable, Equatable, Sendable { case hit, miss, expired, incomplete, ineligible }
    public enum ArtifactVerification: Sendable { case valid, expired, corrupt }
    public struct LookupEvidence: Codable, Equatable, Sendable {
        public let stepID: String
        public let status: LookupStatus
        public let ineligibilityReason: IneligibilityReason?
        public init(stepID: String, status: LookupStatus, ineligibilityReason: IneligibilityReason? = nil) {
            self.stepID = stepID; self.status = status; self.ineligibilityReason = ineligibilityReason
        }
    }
    enum PublicationFailure: Sendable { case quota, store }
    public enum Error: Swift.Error, Equatable, Sendable {
        case cacheMiss, cacheExpired, cacheMissWithEvidence([LookupEvidence]), cacheExpiredWithEvidence([LookupEvidence]), cacheCorrupt, cacheConflict, cacheQuotaExceeded, cacheStoreFailed, contentChanged, invalidRequest
    }

    public struct Plan: Equatable, Sendable {
        public let invocationID: String
        public let orderedStepIDs: [String]
        public let selectionDigest: String
        public init(invocationID: String, orderedStepIDs: [String], selectionDigest: String) {
            self.invocationID = invocationID; self.orderedStepIDs = orderedStepIDs; self.selectionDigest = selectionDigest
        }
    }
    /// Binding は空文字列などの曖昧値ではなく closed union で受け取る。
    public struct Step: Equatable, Sendable {
        public let id: String
        public let binding: Binding
        public init(id: String, binding: Binding) { self.id = id; self.binding = binding }
    }
    public struct Request: Equatable, Sendable {
        public let policy: Policy
        public let plan: Plan
        public let orderedSteps: [Step]
        public init(policy: Policy, plan: Plan, orderedSteps: [Step]) { self.policy = policy; self.plan = plan; self.orderedSteps = orderedSteps }
    }
    /// EvidenceStore が所有する handle receipt。cache は physical path を知り得ない。
    public struct Result: Codable, Equatable, Sendable {
        public let stepID: String
        public let terminalState: TerminalState
        public let sourceRunID: String
        public let stdoutArtifactSHA256: String
        public let stderrArtifactSHA256: String
        public let payloadDigest: String
        public let artifacts: [ArtifactMetadata]
        public init(stepID: String, terminalState: TerminalState, sourceRunID: String, stdoutArtifactSHA256: String, stderrArtifactSHA256: String, payloadDigest: String, artifacts: [ArtifactMetadata] = []) {
            self.stepID = stepID; self.terminalState = terminalState; self.sourceRunID = sourceRunID
            self.stdoutArtifactSHA256 = stdoutArtifactSHA256; self.stderrArtifactSHA256 = stderrArtifactSHA256; self.payloadDigest = payloadDigest; self.artifacts = artifacts
        }
    }
    /// executor が観測した実際の process 起動数。cache は step 数から推測しない。
    public struct ExecutionBatch: Equatable, Sendable {
        public let results: [Result]
        public let processesStarted: Int
        public init(results: [Result], processesStarted: Int) { self.results = results; self.processesStarted = processesStarted }
    }
    public struct Outcome: Equatable, Sendable {
        public let state: State
        public let plan: Plan
        public let results: [Result]
        public let processesStarted: Int
        public let publications: Int
        public let lookupEvidence: [LookupEvidence]
        fileprivate init(state: State, plan: Plan, results: [Result], processesStarted: Int, publications: Int, lookupEvidence: [LookupEvidence]) {
            self.state = state; self.plan = plan; self.results = results; self.processesStarted = processesStarted
            self.publications = publications; self.lookupEvidence = lookupEvidence
        }
    }

    private struct Entry: Codable, Sendable { let result: Result; let expiresAt: Date; var isComplete: Bool; var isCorrupt: Bool }
    private let ttl: TimeInterval
    private let maximumEntryCount: Int
    private let now: @Sendable () -> Date
    private enum Storage { case memory, directory(URL) }
    private let storage: Storage
    private var didLoadStore = false
    private var entries: [String: [Entry]] = [:]
    private var injectedPublicationFailure: PublicationFailure?

    public init(storeDirectory: URL, ttl: TimeInterval = 600, maximumEntryCount: Int = .max, now: @escaping @Sendable () -> Date = Date.init) {
        storage = .directory(storeDirectory); self.ttl = max(0, ttl); self.maximumEntryCount = max(0, maximumEntryCount); self.now = now
    }
    static func inMemory(ttl: TimeInterval = 600, maximumEntryCount: Int = .max, now: @escaping @Sendable () -> Date = Date.init) -> CheckFreshnessCache {
        CheckFreshnessCache(storage: .memory, ttl: ttl, maximumEntryCount: maximumEntryCount, now: now)
    }
    private init(storage: Storage, ttl: TimeInterval, maximumEntryCount: Int, now: @escaping @Sendable () -> Date) {
        self.storage = storage; self.ttl = max(0, ttl); self.maximumEntryCount = max(0, maximumEntryCount); self.now = now
    }
    func markEntryCorrupt(for request: Request, stepID: String) throws {
        try validate(request); try loadStoreIfNeeded()
        guard let index = request.orderedSteps.firstIndex(where: { $0.id == stepID }), let key = cacheKey(plan: request.plan, index: index, step: request.orderedSteps[index]), var generations = entries[key], !generations.isEmpty else { throw Error.cacheMiss }
        generations[generations.count - 1].isCorrupt = true; entries[key] = generations; try persist(entries)
    }
    func markEntryIncomplete(for request: Request, stepID: String) throws {
        try validate(request); try loadStoreIfNeeded()
        guard let index = request.orderedSteps.firstIndex(where: { $0.id == stepID }), let key = cacheKey(plan: request.plan, index: index, step: request.orderedSteps[index]), var generations = entries[key], !generations.isEmpty else { throw Error.cacheMiss }
        generations[generations.count - 1].isComplete = false; entries[key] = generations; try persist(entries)
    }
    func injectPublicationFailure(_ failure: PublicationFailure?) { injectedPublicationFailure = failure }

    /// verifier は EvidenceStore handle receipt を再検証する。false は expiry でなく破損として fail closed する。
    public func execute(
        _ request: Request,
        executeUncached: @Sendable ([Step]) async throws -> ExecutionBatch,
        validateBindingAfterExecution: @Sendable ([Step]) async -> Bool = { _ in true },
        verifyArtifact: (@Sendable (ArtifactMetadata) async -> ArtifactVerification)? = nil
    ) async throws -> Outcome {
        try validate(request)
        if request.policy == .off {
            let batch = try await executeAndValidate(request, executeUncached: executeUncached, verifyArtifact: nil)
            return Outcome(state: .disabled, plan: request.plan, results: batch.results, processesStarted: batch.processesStarted, publications: 0, lookupEvidence: [])
        }
        guard let verifyArtifact else { throw Error.invalidRequest }

        let ineligible = request.orderedSteps.compactMap { step -> LookupEvidence? in
            guard case let .ineligible(reason) = step.binding else { return nil }
            return LookupEvidence(stepID: step.id, status: .ineligible, ineligibilityReason: reason)
        }
        if !ineligible.isEmpty {
            if request.policy == .only { throw Error.cacheMissWithEvidence(ineligible) }
            let batch = try await executeAndValidate(request, executeUncached: executeUncached, verifyArtifact: verifyArtifact)
            guard await validateBindingAfterExecution(request.orderedSteps) else { throw Error.contentChanged }
            // ineligible step は key を作れず、aggregate transactionとして publish 0。
            return Outcome(state: .ineligible, plan: request.plan, results: batch.results, processesStarted: batch.processesStarted, publications: 0, lookupEvidence: ineligible)
        }

        try loadStoreIfNeeded()
        let keys = request.orderedSteps.enumerated().map { cacheKey(plan: request.plan, index: $0.offset, step: $0.element)! }
        if request.policy == .refresh {
            let batch = try await executeAndValidate(request, executeUncached: executeUncached, verifyArtifact: verifyArtifact)
            guard await validateBindingAfterExecution(request.orderedSteps) else { throw Error.contentChanged }
            let publications = try await publish(batch.results, for: keys, verifyArtifact: verifyArtifact)
            return Outcome(state: .refreshExecuted, plan: request.plan, results: batch.results, processesStarted: batch.processesStarted, publications: publications, lookupEvidence: [])
        }

        let lookupTime = now()
        var observed: [Entry?] = []
        var evidence: [LookupEvidence] = []
        for (index, key) in keys.enumerated() {
            let lookup = try await validatedEntry(for: key, at: lookupTime, verifyArtifact: verifyArtifact)
            observed.append(lookup.entry)
            evidence.append(LookupEvidence(stepID: request.orderedSteps[index].id, status: lookup.status))
        }
        let completeHit = observed.allSatisfy { $0?.isComplete == true && $0!.expiresAt > lookupTime }
            && evidence.allSatisfy { $0.status == .hit }
        if request.policy == .only && !completeHit {
            if evidence.contains(where: { $0.status == .expired }) { throw Error.cacheExpiredWithEvidence(evidence) }
            throw Error.cacheMissWithEvidence(evidence)
        }
        if completeHit {
            return Outcome(state: .hit, plan: request.plan, results: observed.compactMap { $0?.result }, processesStarted: 0, publications: 0, lookupEvidence: evidence)
        }
        let batch = try await executeAndValidate(request, executeUncached: executeUncached, verifyArtifact: verifyArtifact)
        guard await validateBindingAfterExecution(request.orderedSteps) else { throw Error.contentChanged }
        let publications = try await publish(batch.results, for: keys, verifyArtifact: verifyArtifact)
        return Outcome(state: .missExecuted, plan: request.plan, results: batch.results, processesStarted: batch.processesStarted, publications: publications, lookupEvidence: evidence)
    }

    private func publish(_ results: [Result], for keys: [String], verifyArtifact: @Sendable (ArtifactMetadata) async -> ArtifactVerification) async throws -> Int {
        let eligible = zip(keys, results).filter { $0.1.terminalState.isCacheable }
        guard !eligible.isEmpty else { return 0 }
        let publicationTime = now()
        for (_, result) in eligible { guard await artifactInputIsValid(result, at: publicationTime, verifyArtifact: verifyArtifact) == .valid else { throw Error.cacheStoreFailed } }
        var reusableKeys = Set<String>()
        for (key, result) in eligible {
            guard let existing = entries[key]?.last, existing.isComplete, !existing.isCorrupt, existing.expiresAt > publicationTime else { continue }
            switch await artifactInputIsValid(existing.result, at: publicationTime, verifyArtifact: verifyArtifact) {
            case .corrupt: throw Error.cacheCorrupt
            case .expired: continue
            case .valid:
                if existing.result.payloadDigest == result.payloadDigest { reusableKeys.insert(key) }
                else { throw Error.cacheConflict }
            }
        }
        if let injectedPublicationFailure { throw injectedPublicationFailure == .quota ? Error.cacheQuotaExceeded : Error.cacheStoreFailed }
        var candidate: [String: [Entry]] = [:]
        for (key, generations) in entries {
            var retained: [Entry] = []
            for entry in generations {
                if entry.isCorrupt { throw Error.cacheCorrupt }
                if entry.isComplete, entry.expiresAt > publicationTime {
                    switch await artifactInputIsValid(entry.result, at: publicationTime, verifyArtifact: verifyArtifact) {
                    case .valid: retained.append(entry)
                    case .expired: continue
                    case .corrupt: throw Error.cacheCorrupt
                    }
                }
            }
            if !retained.isEmpty { candidate[key] = retained }
        }
        let currentEntryCount = candidate.values.reduce(0) { $0 + $1.count }
        let newEntries = eligible.count - reusableKeys.count
        guard currentEntryCount <= maximumEntryCount, newEntries <= maximumEntryCount - currentEntryCount else { throw Error.cacheQuotaExceeded }
        for (key, result) in eligible where !reusableKeys.contains(key) {
            let expiry = min(result.artifacts.map(\.expiresAt).min()!, publicationTime.addingTimeInterval(ttl))
            candidate[key, default: []].append(Entry(result: result, expiresAt: expiry, isComplete: true, isCorrupt: false))
        }
        try persist(candidate); entries = candidate; return newEntries
    }

    private struct PersistentEntry: Codable { let keyHash: String; let payloadHash: String; let entry: Entry }
    private struct Manifest: Codable { let schema: String; let entries: [String: [PersistentEntry]] }
    private static let manifestSchema = "aishell.check-freshness-cache-manifest.v1"
    private func loadStoreIfNeeded() throws {
        guard !didLoadStore else { return }
        guard case let .directory(directory) = storage else { didLoadStore = true; return }
        let manifestURL = directory.appendingPathComponent("freshness-cache-manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { didLoadStore = true; return }
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)) } catch { throw Error.cacheCorrupt }
        guard manifest.schema == Self.manifestSchema else { throw Error.cacheCorrupt }
        for (key, persistent) in manifest.entries { guard persistent.allSatisfy({ $0.keyHash == key && $0.payloadHash == entryHash($0.entry) }) else { throw Error.cacheCorrupt } }
        entries = manifest.entries.mapValues { $0.map(\.entry) }; didLoadStore = true
    }
    private enum ArtifactValidation { case valid, expired, corrupt }
    private func validatedEntry(for key: String, at time: Date, verifyArtifact: @Sendable (ArtifactMetadata) async -> ArtifactVerification) async throws -> (entry: Entry?, status: LookupStatus) {
        guard let entry = entries[key]?.last else { return (nil, .miss) }
        guard !entry.isCorrupt else { throw Error.cacheCorrupt }
        guard entry.isComplete else { return (entry, .incomplete) }
        guard entry.expiresAt > time, entry.result.artifacts.allSatisfy({ $0.expiresAt > time }) else { return (entry, .expired) }
        switch await artifactInputIsValid(entry.result, at: time, verifyArtifact: verifyArtifact) {
        case .valid: break
        case .expired: return (entry, .expired)
        case .corrupt: throw Error.cacheCorrupt
        }
        return (entry, .hit)
    }
    private func artifactInputIsValid(_ result: Result, at time: Date, verifyArtifact: @Sendable (ArtifactMetadata) async -> ArtifactVerification) async -> ArtifactValidation {
        let hashes = Set(result.artifacts.map(\.sha256))
        guard !result.artifacts.isEmpty, hashes.contains(result.stdoutArtifactSHA256), hashes.contains(result.stderrArtifactSHA256), result.artifacts.allSatisfy({ !$0.handle.isEmpty && $0.sizeBytes >= 0 && isSHA256($0.sha256) }) else { return .corrupt }
        for artifact in result.artifacts {
            if artifact.expiresAt <= time { return .expired }
            switch await verifyArtifact(artifact) { case .valid: continue; case .expired: return .expired; case .corrupt: return .corrupt }
        }
        return .valid
    }
    private func entryHash(_ entry: Entry) -> String { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return SHA256.hash(data: (try? encoder.encode(entry)) ?? Data()).map { String(format: "%02x", $0) }.joined() }
    private func persist(_ candidate: [String: [Entry]]) throws {
        guard case let .directory(directory) = storage else { return }
        let persistent = candidate.mapValues { generations in generations.map { PersistentEntry(keyHash: "", payloadHash: entryHash($0), entry: $0) } }
        let withKeys = Dictionary(uniqueKeysWithValues: persistent.map { key, generations in (key, generations.map { PersistentEntry(keyHash: key, payloadHash: $0.payloadHash, entry: $0.entry) }) })
        let data: Data; do { data = try JSONEncoder().encode(Manifest(schema: Self.manifestSchema, entries: withKeys)) } catch { throw Error.cacheStoreFailed }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try durableReplace(data: data, temporary: directory.appendingPathComponent(".freshness-cache-\(UUID().uuidString).tmp"), destination: directory.appendingPathComponent("freshness-cache-manifest.json"), directory: directory) } catch { throw Error.cacheStoreFailed }
    }
    private func durableReplace(data: Data, temporary: URL, destination: URL, directory: URL) throws {
        var descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR); guard descriptor >= 0 else { throw Error.cacheStoreFailed }
        var shouldRemove = true; defer { if descriptor >= 0 { _ = close(descriptor) }; if shouldRemove { try? FileManager.default.removeItem(at: temporary) } }
        try data.withUnsafeBytes { raw in var offset = 0; while offset < raw.count { let written = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset); if written > 0 { offset += written; continue }; if written < 0 && errno == EINTR { continue }; throw Error.cacheStoreFailed } }
        guard fsync(descriptor) == 0, close(descriptor) == 0 else { throw Error.cacheStoreFailed }; descriptor = -1
        let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC); guard directoryDescriptor >= 0 else { throw Error.cacheStoreFailed }; defer { _ = close(directoryDescriptor) }
        guard temporary.path.withCString({ source in destination.path.withCString { Darwin.rename(source, $0) } }) == 0, fsync(directoryDescriptor) == 0 else { throw Error.cacheStoreFailed }; shouldRemove = false
    }
    private func validate(_ request: Request) throws {
        guard !request.plan.invocationID.isEmpty, !request.plan.orderedStepIDs.isEmpty, request.plan.orderedStepIDs == request.orderedSteps.map(\.id), Set(request.plan.orderedStepIDs).count == request.plan.orderedStepIDs.count, isSHA256(request.plan.selectionDigest), request.orderedSteps.allSatisfy({ !$0.id.isEmpty && ($0.binding.digest.map(isSHA256) ?? true) }) else { throw Error.invalidRequest }
    }
    private func executeAndValidate(_ request: Request, executeUncached: @Sendable ([Step]) async throws -> ExecutionBatch, verifyArtifact: (@Sendable (ArtifactMetadata) async -> ArtifactVerification)?) async throws -> ExecutionBatch {
        let batch = try await executeUncached(request.orderedSteps)
        guard batch.processesStarted >= 0, batch.results.map(\.stepID) == request.plan.orderedStepIDs, batch.results.allSatisfy({ !$0.sourceRunID.isEmpty && isSHA256($0.stdoutArtifactSHA256) && isSHA256($0.stderrArtifactSHA256) && isSHA256($0.payloadDigest) }) else { throw Error.invalidRequest }
        for result in batch.results where result.terminalState.isCacheable {
            guard artifactReceiptIsStructurallyValid(result, at: now()) else { throw Error.cacheStoreFailed }
            if let verifyArtifact, await artifactInputIsValid(result, at: now(), verifyArtifact: verifyArtifact) != .valid { throw Error.cacheStoreFailed }
        }
        return batch
    }
    private func artifactReceiptIsStructurallyValid(_ result: Result, at time: Date) -> Bool {
        let hashes = Set(result.artifacts.map(\.sha256))
        return !result.artifacts.isEmpty && hashes.contains(result.stdoutArtifactSHA256) && hashes.contains(result.stderrArtifactSHA256)
            && result.artifacts.allSatisfy { !$0.handle.isEmpty && $0.sizeBytes >= 0 && isSHA256($0.sha256) && $0.expiresAt > time }
    }
    private func cacheKey(plan: Plan, index: Int, step: Step) -> String? {
        guard let bindingDigest = step.binding.digest else { return nil }
        let fields = [plan.selectionDigest, String(index), step.id, bindingDigest]
        return SHA256.hash(data: Data(fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func isSHA256(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}
