import CryptoKit
import Foundation

/// ADR 0020 の focused candidate、immutable set、selection をコンパイルする純粋な domain service。
/// この型は check process を起動しない。実行は caller が明示した run_check に委ねる。
public actor FocusedCheckService {
    public static let schema = "aishell.focused-check.v1"

    public enum Selector: Codable, Equatable, Sendable {
        case testPath(path: String)
        case profileCheck(id: String)
        case target(ecosystemID: String, profileIdentity: String, manifestPath: String, declaredID: String)

        private enum CodingKeys: String, CodingKey { case kind, path, id, ecosystemID, profileIdentity, manifestPath, declaredID }
        private enum Kind: String, Codable { case testPath = "test_path", profileCheck = "profile_check", target }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            switch try values.decode(Kind.self, forKey: .kind) {
            case .testPath:
                self = .testPath(path: try values.decode(String.self, forKey: .path))
            case .profileCheck:
                self = .profileCheck(id: try values.decode(String.self, forKey: .id))
            case .target:
                self = .target(
                    ecosystemID: try values.decode(String.self, forKey: .ecosystemID),
                    profileIdentity: try values.decode(String.self, forKey: .profileIdentity),
                    manifestPath: try values.decode(String.self, forKey: .manifestPath),
                    declaredID: try values.decode(String.self, forKey: .declaredID)
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .testPath(let path):
                try values.encode(Kind.testPath, forKey: .kind); try values.encode(path, forKey: .path)
            case .profileCheck(let id):
                try values.encode(Kind.profileCheck, forKey: .kind); try values.encode(id, forKey: .id)
            case .target(let ecosystemID, let profileIdentity, let manifestPath, let declaredID):
                try values.encode(Kind.target, forKey: .kind)
                try values.encode(ecosystemID, forKey: .ecosystemID)
                try values.encode(profileIdentity, forKey: .profileIdentity)
                try values.encode(manifestPath, forKey: .manifestPath)
                try values.encode(declaredID, forKey: .declaredID)
            }
        }
    }

    public struct Provenance: Codable, Equatable, Sendable {
        public let providerID: String
        public let providerVersion: String
        public let artifactDigest: String
        public let freshness: String

        public init(providerID: String, providerVersion: String, artifactDigest: String, freshness: String) {
            self.providerID = providerID; self.providerVersion = providerVersion
            self.artifactDigest = artifactDigest; self.freshness = freshness
        }
    }

    public struct Evidence: Codable, Equatable, Sendable {
        public let id: String
        public let provenance: Provenance
        public init(id: String, provenance: Provenance) { self.id = id; self.provenance = provenance }
    }

    public struct Step: Codable, Equatable, Sendable {
        public let id: String
        public let descriptorDigest: String
        public let dependsOn: [String]
        public let ordinal: Int?

        public init(id: String, descriptorDigest: String, dependsOn: [String] = [], ordinal: Int? = nil) {
            self.id = id; self.descriptorDigest = descriptorDigest; self.dependsOn = dependsOn; self.ordinal = ordinal
        }
    }

    public struct Candidate: Codable, Equatable, Sendable {
        public let profileCheckID: String
        public let profileDigest: String
        public let selector: Selector
        public let steps: [Step]
        public let evidence: [Evidence]

        public init(profileCheckID: String, profileDigest: String, selector: Selector, steps: [Step], evidence: [Evidence]) {
            self.profileCheckID = profileCheckID; self.profileDigest = profileDigest; self.selector = selector
            self.steps = steps; self.evidence = evidence
        }
    }

    public struct CompileRequest: Sendable {
        public let rootIdentity: String
        public let generation: String
        public let cursor: String
        public let profileDigest: String
        public let manifestIdentity: String
        public let impactArtifactDigest: String
        public let coverage: [String]
        public let limitations: [String]
        public let candidates: [Candidate]
        public let expiresAt: Date

        public init(rootIdentity: String, generation: String, cursor: String, profileDigest: String, manifestIdentity: String, impactArtifactDigest: String, coverage: [String] = [], limitations: [String] = [], candidates: [Candidate], expiresAt: Date) {
            self.rootIdentity = rootIdentity; self.generation = generation; self.cursor = cursor
            self.profileDigest = profileDigest; self.manifestIdentity = manifestIdentity; self.impactArtifactDigest = impactArtifactDigest
            self.coverage = coverage; self.limitations = limitations; self.candidates = candidates; self.expiresAt = expiresAt
        }
    }

    public struct FocusedCandidate: Codable, Equatable, Sendable {
        public let focusedCheckID: String
        public let source: Candidate
        public let dagDigest: String
    }

    public struct FocusedSet: Codable, Equatable, Sendable {
        public let schema: String
        public let id: String
        public let digest: String
        public let rootIdentity: String
        public let generation: String
        public let cursor: String
        public let profileDigest: String
        public let manifestIdentity: String
        public let impactArtifactDigest: String
        public let coverage: [String]
        public let limitations: [String]
        public let candidates: [FocusedCandidate]
        public let expiresAt: Date
    }

    /// focused run_checkがcurrent profile/catalogを照合する前に読む、immutable setの
    /// read-only receipt。registry stateをコピーしてauthority化せず、set ID/digestとexpiryを
    /// actor内で検証してから返す。
    public struct PreparedSetReceipt: Codable, Equatable, Sendable {
        public let focusedSetID: String
        public let focusedSetDigest: String
        public let expiresAt: Date
        public let rootIdentity: String
        public let generation: String
        public let cursor: String
        public let profileDigest: String
        public let manifestIdentity: String
        public let impactArtifactDigest: String
    }

    public struct Selection: Codable, Equatable, Sendable {
        /// 返却selectionをcurrent admissionへ再照合するための、保存済みset由来receipt。
        public struct AdmissionReceipt: Codable, Equatable, Sendable {
            public let focusedSetID: String
            public let focusedSetDigest: String
            public let rootIdentity: String
            public let generation: String
            public let cursor: String
            public let profileDigest: String
            public let manifestIdentity: String
            public let impactArtifactDigest: String
            public let requestedCheckIDs: [String]
            public let plannedCheckIDs: [String]
            public let selectionDigest: String
        }

        public struct ResolvedCandidate: Codable, Equatable, Sendable {
            public let focusedCheckID: String
            public let profileCheckID: String
            public let selector: Selector
            public let steps: [Step]

            public init(focusedCheckID: String, profileCheckID: String, selector: Selector, steps: [Step]) {
                self.focusedCheckID = focusedCheckID
                self.profileCheckID = profileCheckID
                self.selector = selector
                self.steps = steps
            }
        }

        public let focusedSetID: String
        public let focusedSetDigest: String
        public let requestedCheckIDs: [String]
        public let plannedCheckIDs: [String]
        public let steps: [Step]
        /// 実行側が公開済みDAGの各stepを元candidateとexactに対応付けるための加法的情報。
        public let resolvedCandidates: [ResolvedCandidate]
        public let selectionDigest: String
        public let admissionReceipt: AdmissionReceipt
    }

    public struct Admission: Sendable {
        public let rootIdentity: String
        public let generation: String
        public let cursor: String
        public let profileDigest: String
        public let manifestIdentity: String
        public let impactArtifactDigest: String

        public init(rootIdentity: String, generation: String, cursor: String, profileDigest: String, manifestIdentity: String, impactArtifactDigest: String) {
            self.rootIdentity = rootIdentity; self.generation = generation; self.cursor = cursor
            self.profileDigest = profileDigest; self.manifestIdentity = manifestIdentity; self.impactArtifactDigest = impactArtifactDigest
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case invocationInvalid
        case selectionStale
    }

    private let now: @Sendable () -> Date
    private var sets: [String: FocusedSet] = [:]

    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    /// current catalog/profile admissionを組み立てる前のimmutable receipt取得。
    public func prepare(focusedSetID: String, focusedSetDigest: String) throws -> PreparedSetReceipt {
        guard let set = sets[focusedSetID],
              set.digest == focusedSetDigest,
              set.expiresAt > now() else {
            throw Error.selectionStale
        }
        return PreparedSetReceipt(
            focusedSetID: set.id,
            focusedSetDigest: set.digest,
            expiresAt: set.expiresAt,
            rootIdentity: set.rootIdentity,
            generation: set.generation,
            cursor: set.cursor,
            profileDigest: set.profileDigest,
            manifestIdentity: set.manifestIdentity,
            impactArtifactDigest: set.impactArtifactDigest
        )
    }

    /// 同じ logical descriptor の理由を一候補へ集約し、content-addressed set を登録する。
    /// expiry は admission validity であり identity ではない。同じ identity が既に登録済みなら、
    /// 既発行 receipt の expiry を短縮・延長せず、その receipt を返す。
    public func compile(_ request: CompileRequest) throws -> FocusedSet {
        guard nonEmpty(request.rootIdentity, request.generation, request.cursor, request.profileDigest, request.manifestIdentity, request.impactArtifactDigest), validSHA256(request.profileDigest), validSHA256(request.impactArtifactDigest), request.expiresAt > now() else { throw Error.invocationInvalid }
        var byID: [String: Candidate] = [:]
        for candidate in request.candidates {
            let normalized = try normalized(candidate)
            guard normalized.profileDigest == request.profileDigest else { throw Error.invocationInvalid }
            let key = try focusedCheckID(for: normalized)
            if let existing = byID[key] {
                guard existing.profileCheckID == normalized.profileCheckID, existing.profileDigest == normalized.profileDigest,
                      existing.selector == normalized.selector, existing.steps == normalized.steps else { throw Error.invocationInvalid }
                byID[key] = Candidate(profileCheckID: existing.profileCheckID, profileDigest: existing.profileDigest, selector: existing.selector, steps: existing.steps, evidence: uniqueEvidence(existing.evidence + normalized.evidence))
            } else { byID[key] = normalized }
        }
        guard !byID.isEmpty else { throw Error.invocationInvalid }
        let compiled = try byID.map { key, value in FocusedCandidate(focusedCheckID: key, source: value, dagDigest: try dagDigest(value.steps)) }
            .sorted { utf8Less($0.focusedCheckID, $1.focusedCheckID) }
        let coverage = request.coverage.sorted(by: utf8Less)
        let limitations = request.limitations.sorted(by: utf8Less)
        let digest = digest(parts: canonicalSetParts(request: request, coverage: coverage, limitations: limitations, candidates: compiled))
        let set = FocusedSet(schema: Self.schema, id: "fset_\(digest.prefix(24))", digest: digest, rootIdentity: request.rootIdentity, generation: request.generation, cursor: request.cursor, profileDigest: request.profileDigest, manifestIdentity: request.manifestIdentity, impactArtifactDigest: request.impactArtifactDigest, coverage: coverage, limitations: limitations, candidates: compiled, expiresAt: request.expiresAt)
        if let existing = sets[set.id] {
            guard existing.digest == set.digest else { throw Error.invocationInvalid }
            return existing
        }
        sets[set.id] = set
        return set
    }

    /// caller の順序を一切変えず、公開済み candidate と DAG だけを解決する。
    public func resolve(focusedSetID: String, focusedSetDigest: String, requestedCheckIDs: [String], admission: Admission) throws -> Selection {
        guard !requestedCheckIDs.isEmpty, Set(requestedCheckIDs).count == requestedCheckIDs.count else { throw Error.invocationInvalid }
        guard let set = sets[focusedSetID], set.digest == focusedSetDigest, set.expiresAt > now(), matches(set, admission) else { throw Error.selectionStale }
        let candidateByID = Dictionary(uniqueKeysWithValues: set.candidates.map { ($0.focusedCheckID, $0) })
        guard requestedCheckIDs.allSatisfy({ candidateByID[$0] != nil }) else { throw Error.invocationInvalid }
        var selectedSteps: [Step] = []
        var resolvedCandidates: [Selection.ResolvedCandidate] = []
        for id in requestedCheckIDs {
            guard let candidate = candidateByID[id] else { throw Error.invocationInvalid }
            let ordered = try topological(candidate.source.steps)
            selectedSteps.append(contentsOf: ordered)
            resolvedCandidates.append(.init(
                focusedCheckID: id,
                profileCheckID: candidate.source.profileCheckID,
                selector: candidate.source.selector,
                steps: ordered
            ))
        }
        guard Set(selectedSteps.map(\.id)).count == selectedSteps.count else { throw Error.invocationInvalid }
        let selectionDigest = digest(parts: [set.digest] + requestedCheckIDs + requestedCheckIDs.flatMap { [candidateByID[$0]!.dagDigest] })
        let receipt = Selection.AdmissionReceipt(
            focusedSetID: set.id,
            focusedSetDigest: set.digest,
            rootIdentity: set.rootIdentity,
            generation: set.generation,
            cursor: set.cursor,
            profileDigest: set.profileDigest,
            manifestIdentity: set.manifestIdentity,
            impactArtifactDigest: set.impactArtifactDigest,
            requestedCheckIDs: requestedCheckIDs,
            plannedCheckIDs: requestedCheckIDs,
            selectionDigest: selectionDigest
        )
        return Selection(
            focusedSetID: set.id,
            focusedSetDigest: set.digest,
            requestedCheckIDs: requestedCheckIDs,
            plannedCheckIDs: requestedCheckIDs,
            steps: selectedSteps,
            resolvedCandidates: resolvedCandidates,
            selectionDigest: selectionDigest,
            admissionReceipt: receipt
        )
    }

    /// public run_check join用のexact resolver。保存済みimmutable setのID/digestと、
    /// callerがplanへ束縛したselection digestを同じadmissionで再照合する。
    public func resolve(
        focusedSetID: String,
        focusedSetDigest: String,
        requestedCheckIDs: [String],
        expectedSelectionDigest: String,
        admission: Admission
    ) throws -> Selection {
        let selection = try resolve(
            focusedSetID: focusedSetID,
            focusedSetDigest: focusedSetDigest,
            requestedCheckIDs: requestedCheckIDs,
            admission: admission
        )
        guard selection.selectionDigest == expectedSelectionDigest,
              selection.admissionReceipt.focusedSetID == focusedSetID,
              selection.admissionReceipt.focusedSetDigest == focusedSetDigest,
              selection.admissionReceipt.requestedCheckIDs == requestedCheckIDs,
              selection.admissionReceipt.plannedCheckIDs == requestedCheckIDs else {
            throw Error.selectionStale
        }
        return selection
    }

    /// planがset digestを運ばない場合も、service内のimmutable receiptを正本として解決し、
    /// callerが束縛したselection digestとexactに照合する。
    public func resolve(
        focusedSetID: String,
        requestedCheckIDs: [String],
        expectedSelectionDigest: String,
        admission: Admission
    ) throws -> Selection {
        guard let set = sets[focusedSetID] else { throw Error.selectionStale }
        return try resolve(
            focusedSetID: focusedSetID,
            focusedSetDigest: set.digest,
            requestedCheckIDs: requestedCheckIDs,
            expectedSelectionDigest: expectedSelectionDigest,
            admission: admission
        )
    }

    private func normalized(_ candidate: Candidate) throws -> Candidate {
        guard nonEmpty(candidate.profileCheckID, candidate.profileDigest), validSelector(candidate.selector), !candidate.steps.isEmpty else { throw Error.invocationInvalid }
        guard validSHA256(candidate.profileDigest) else { throw Error.invocationInvalid }
        _ = try topological(candidate.steps)
        let evidence = uniqueEvidence(candidate.evidence)
        guard !evidence.isEmpty, evidence.allSatisfy({ nonEmpty($0.id, $0.provenance.providerID, $0.provenance.providerVersion, $0.provenance.artifactDigest, $0.provenance.freshness) && validSHA256($0.provenance.artifactDigest) }) else { throw Error.invocationInvalid }
        return Candidate(profileCheckID: candidate.profileCheckID, profileDigest: candidate.profileDigest, selector: candidate.selector, steps: candidate.steps, evidence: evidence)
    }

    private func focusedCheckID(for candidate: Candidate) throws -> String {
        "fcheck_\(digest(parts: [candidate.profileCheckID, candidate.profileDigest, selectorKey(candidate.selector), try dagDigest(candidate.steps)]).prefix(24))"
    }

    private func dagDigest(_ steps: [Step]) throws -> String {
        let ordered = try topological(steps)
        return digest(parts: ordered.flatMap { [$0.id, $0.descriptorDigest] + $0.dependsOn.sorted(by: utf8Less) })
    }

    private func topological(_ steps: [Step]) throws -> [Step] {
        guard !steps.isEmpty else { throw Error.invocationInvalid }
        let ids = steps.map(\.id)
        guard Set(ids).count == ids.count, steps.allSatisfy({ nonEmpty($0.id, $0.descriptorDigest) && validSHA256($0.descriptorDigest) }) else { throw Error.invocationInvalid }
        let table = Dictionary(uniqueKeysWithValues: steps.map { ($0.id, $0) })
        var dependencies: [String: Set<String>] = [:]
        for step in steps {
            let listed = Set(step.dependsOn)
            guard listed.count == step.dependsOn.count, !listed.contains(step.id), listed.allSatisfy({ table[$0] != nil }) else { throw Error.invocationInvalid }
            dependencies[step.id] = listed
        }
        var result: [Step] = []
        while !dependencies.isEmpty {
            let ready = dependencies.filter { $0.value.isEmpty }.map(\.key).sorted { left, right in
                let lhs = table[left]!.ordinal; let rhs = table[right]!.ordinal
                if lhs != rhs { return (lhs ?? Int.max) < (rhs ?? Int.max) }
                return utf8Less(left, right)
            }
            guard !ready.isEmpty else { throw Error.invocationInvalid }
            for id in ready { result.append(table[id]!); dependencies.removeValue(forKey: id) }
            for id in dependencies.keys { dependencies[id]?.subtract(ready) }
        }
        return result
    }

    private func matches(_ set: FocusedSet, _ admission: Admission) -> Bool {
        set.rootIdentity == admission.rootIdentity && set.generation == admission.generation && set.cursor == admission.cursor && set.profileDigest == admission.profileDigest && set.manifestIdentity == admission.manifestIdentity && set.impactArtifactDigest == admission.impactArtifactDigest
    }

    private func validSelector(_ value: Selector) -> Bool {
        switch value {
        case .testPath(let path): return !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
        case .profileCheck(let id): return !id.isEmpty
        case .target(let ecosystemID, let profileIdentity, let manifestPath, let declaredID): return nonEmpty(ecosystemID, profileIdentity, manifestPath, declaredID)
        }
    }
    private func selectorKey(_ value: Selector) -> String {
        switch value { case .testPath(let path): return "test_path\u{0}\(path)"; case .profileCheck(let id): return "profile_check\u{0}\(id)"; case .target(let ecosystemID, let profileIdentity, let manifestPath, let declaredID): return ["target", ecosystemID, profileIdentity, manifestPath, declaredID].joined(separator: "\u{0}") }
    }
    private func uniqueEvidence(_ values: [Evidence]) -> [Evidence] {
        Dictionary(grouping: values, by: { [$0.id, $0.provenance.providerID, $0.provenance.providerVersion, $0.provenance.artifactDigest, $0.provenance.freshness].joined(separator: "\u{0}") }).keys.sorted(by: utf8Less).compactMap { key in values.first { [$0.id, $0.provenance.providerID, $0.provenance.providerVersion, $0.provenance.artifactDigest, $0.provenance.freshness].joined(separator: "\u{0}") == key } }
    }
    private func canonicalSetParts(request: CompileRequest, coverage: [String], limitations: [String], candidates: [FocusedCandidate]) -> [String] {
        var result = ["schema", Self.schema, "root", request.rootIdentity, "generation", request.generation, "cursor", request.cursor, "profile", request.profileDigest, "manifest", request.manifestIdentity, "impact", request.impactArtifactDigest]
        appendArray("coverage", coverage, to: &result)
        appendArray("limitations", limitations, to: &result)
        result += ["candidate_count", String(candidates.count)]
        for candidate in candidates {
            result += ["candidate", candidate.focusedCheckID, "dag", candidate.dagDigest, "profile_check", candidate.source.profileCheckID, "profile_digest", candidate.source.profileDigest]
            result += selectorParts(candidate.source.selector)
            let steps = (try? topological(candidate.source.steps)) ?? []
            result += ["step_count", String(steps.count)]
            for step in steps { result += ["step", step.id, "descriptor", step.descriptorDigest, "ordinal", step.ordinal.map(String.init) ?? "none"]; appendArray("depends_on", step.dependsOn.sorted(by: utf8Less), to: &result) }
            result += ["evidence_count", String(candidate.source.evidence.count)]
            for evidence in candidate.source.evidence { result += ["evidence", evidence.id, "provider", evidence.provenance.providerID, "provider_version", evidence.provenance.providerVersion, "artifact", evidence.provenance.artifactDigest, "freshness", evidence.provenance.freshness] }
        }
        return result
    }
    private func selectorParts(_ value: Selector) -> [String] {
        switch value {
        case .testPath(let path): return ["selector", "test_path", "path", path]
        case .profileCheck(let id): return ["selector", "profile_check", "id", id]
        case .target(let ecosystemID, let profileIdentity, let manifestPath, let declaredID): return ["selector", "target", "ecosystem", ecosystemID, "profile_identity", profileIdentity, "manifest_path", manifestPath, "declared_id", declaredID]
        }
    }
    private func appendArray(_ name: String, _ values: [String], to result: inout [String]) { result += [name, String(values.count)]; result.append(contentsOf: values) }
    private func digest(parts: [String]) -> String {
        var data = Data()
        for part in parts {
            var length = UInt64(part.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(contentsOf: part.utf8)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func validSHA256(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 64 && bytes.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }
    private func nonEmpty(_ values: String...) -> Bool { values.allSatisfy { !$0.isEmpty } }
    private func utf8Less(_ lhs: String, _ rhs: String) -> Bool { Array(lhs.utf8).lexicographicallyPrecedes(Array(rhs.utf8)) }
}
