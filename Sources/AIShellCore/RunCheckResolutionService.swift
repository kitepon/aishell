import CryptoKit
import Foundation

public enum RunCheckRelevantInputEligibility: String, Codable, Equatable, Sendable {
    case eligible
    case ineligible
}

/// Public cache callerへ返す、ProjectProfileとDirect OS observationを束縛したreceipt。
public struct RunCheckRelevantInputReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let provider: String
    public let providerVersion: String
    public let observationProviderVersion: String
    public let projectRoot: String
    public let projectRootIdentity: String
    public let workspaceCursor: String
    public let projectID: String
    public let profileDigest: String
    public let checkID: String
    public let leafCount: Int
    public let completeness: String
    public let merkleDigest: String?
    public let eligibility: RunCheckRelevantInputEligibility
    public let ineligibilityReason: String?
    public let bindingDigest: String?

    public var cacheBinding: CheckFreshnessCache.Binding {
        guard eligibility == .eligible, let bindingDigest else {
            return .ineligible(reason: .bindingIncomplete)
        }
        return .eligible(digest: bindingDigest)
    }
}

public struct RunCheckResolutionRequest: Equatable, Sendable {
    public let projectID: String
    public let profileDigest: String
    public let checkID: String

    public init(projectID: String, profileDigest: String, checkID: String) {
        self.projectID = projectID
        self.profileDigest = profileDigest
        self.checkID = checkID
    }
}

/// caller supplied digestを受け取らず、profileのexact descriptorとDirect OS observationだけからbindingを作る。
public actor RunCheckResolutionService {
    private let projectProfiles: ProjectProfileService
    private let workspaceRuntime: WorkspaceStateRuntime

    public init(projectProfiles: ProjectProfileService, workspaceRuntime: WorkspaceStateRuntime) {
        self.projectProfiles = projectProfiles
        self.workspaceRuntime = workspaceRuntime
    }

    public func resolve(_ request: RunCheckResolutionRequest) async throws -> RunCheckRelevantInputReceipt {
        let resolution = try await projectProfiles.resolveExactCheck(
            projectID: request.projectID,
            profileDigest: request.profileDigest,
            checkID: request.checkID
        )
        return try await receipt(for: resolution)
    }

    /// publication直前の再観測。元receiptの任意digestは入力に使わず、IDをfreshに再解決する。
    public func reobserve(_ receipt: RunCheckRelevantInputReceipt) async throws -> RunCheckRelevantInputReceipt {
        let resolution = try await projectProfiles.resolveExactCheck(
            projectID: receipt.projectID,
            profileDigest: receipt.profileDigest,
            checkID: receipt.checkID,
            sinceCursor: receipt.workspaceCursor
        )
        return try await self.receipt(for: resolution)
    }

    private func receipt(for resolution: ProjectProfileCheckResolution) async throws -> RunCheckRelevantInputReceipt {
        let profile = resolution.profile
        let check = resolution.check
        let projectRoot = profile.projectRoot.isEmpty
            ? URL(fileURLWithPath: resolution.catalogRoot, isDirectory: true)
            : URL(fileURLWithPath: resolution.catalogRoot, isDirectory: true)
                .appendingPathComponent(profile.projectRoot, isDirectory: true)
        let contract = check.inputContract
        guard contract.completeness == .complete,
              contract.effectCompleteness == .projectRootClosed else {
            return RunCheckRelevantInputReceipt(
                schemaVersion: "aishell.run-check-relevant-input-receipt.v1",
                provider: contract.provider,
                providerVersion: contract.providerVersion,
                observationProviderVersion: "direct-os-merkle-v1",
                projectRoot: projectRoot.standardizedFileURL.path,
                projectRootIdentity: profile.projectRootIdentity,
                workspaceCursor: resolution.observedCursor,
                projectID: profile.projectId,
                profileDigest: profile.profileDigest,
                checkID: check.checkId,
                leafCount: 0,
                completeness: "incomplete",
                merkleDigest: nil,
                eligibility: .ineligible,
                ineligibilityReason: contract.reason ?? "input/effect completenessが証明されていません",
                bindingDigest: nil
            )
        }

        let observation = try await workspaceRuntime.observeRelevantInputs(
            ownerRootPath: resolution.catalogRoot,
            projectRootPath: projectRoot.path,
            expectedProjectRootIdentity: profile.projectRootIdentity,
            expectedCursor: resolution.observedCursor,
            contract: contract
        )
        let post = try await projectProfiles.resolveExactCheck(
            projectID: profile.projectId,
            profileDigest: profile.profileDigest,
            checkID: check.checkId,
            sinceCursor: observation.workspaceCursor
        )
        guard post.profile.projectRootIdentity == profile.projectRootIdentity,
              post.check == check,
              post.observedCursor == observation.workspaceCursor else {
            throw AIShellError.contentChanged(projectRoot.path)
        }
        let binding = Self.bindingDigest(
            observation: observation,
            projectID: profile.projectId,
            profileDigest: profile.profileDigest,
            checkID: check.checkId,
            provider: contract.provider,
            providerVersion: contract.providerVersion,
            contractVersion: contract.schemaVersion
        )
        return RunCheckRelevantInputReceipt(
            schemaVersion: "aishell.run-check-relevant-input-receipt.v1",
            provider: contract.provider,
            providerVersion: contract.providerVersion,
            observationProviderVersion: observation.providerVersion,
            projectRoot: observation.projectRoot,
            projectRootIdentity: observation.projectRootIdentity,
            workspaceCursor: observation.workspaceCursor,
            projectID: profile.projectId,
            profileDigest: profile.profileDigest,
            checkID: check.checkId,
            leafCount: observation.leafCount,
            completeness: observation.completeness,
            merkleDigest: observation.merkleDigest,
            eligibility: .eligible,
            ineligibilityReason: nil,
            bindingDigest: binding
        )
    }

    static func bindingDigest(
        observation: WorkspaceRelevantInputObservation,
        projectID: String,
        profileDigest: String,
        checkID: String,
        provider: String,
        providerVersion: String,
        contractVersion: String
    ) -> String {
        let fields = [
            "aishell.run-check-relevant-input-binding.v1",
            provider,
            providerVersion,
            contractVersion,
            observation.providerVersion,
            observation.projectRoot,
            observation.projectRootIdentity,
            observation.workspaceCursor,
            projectID,
            profileDigest,
            checkID,
            String(observation.leafCount),
            observation.completeness,
            observation.merkleDigest,
        ]
        var data = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            var count = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
