import CryptoKit
import Darwin
import Foundation

// MARK: - Public value contract

public struct ApplyChangeSetCursor: Codable, Equatable, Hashable, Sendable {
    public let root: String
    public let generation: String
    public let sequence: UInt64

    public init(root: String, generation: String, sequence: UInt64) {
        self.root = root
        self.generation = generation
        self.sequence = sequence
    }
}

public enum ApplyChangeSetExpected: Codable, Equatable, Sendable {
    case absent
    case file(String)
}

public enum ApplyChangeSetContent: Codable, Equatable, Sendable {
    case utf8(String)
    case base64(String)

    var bytes: Data? {
        switch self {
        case let .utf8(value): Data(value.utf8)
        case let .base64(value): Data(base64Encoded: value)
        }
    }
}

public enum ApplyChangeSetChange: Codable, Equatable, Sendable {
    case create(id: String, path: String, expected: ApplyChangeSetExpected, content: ApplyChangeSetContent)
    case write(id: String, path: String, expected: ApplyChangeSetExpected, content: ApplyChangeSetContent)
    case delete(id: String, path: String, expected: ApplyChangeSetExpected)
    case rename(id: String, source: String, sourceExpected: ApplyChangeSetExpected, destination: String, destinationExpected: ApplyChangeSetExpected)

    public var changeID: String {
        switch self {
        case let .create(id, _, _, _), let .write(id, _, _, _), let .delete(id, _, _), let .rename(id, _, _, _, _): id
        }
    }

    public var paths: [String] {
        switch self {
        case let .create(_, path, _, _), let .write(_, path, _, _), let .delete(_, path, _): [path]
        case let .rename(_, source, _, destination, _): [source, destination]
        }
    }

    var contents: [Data] {
        switch self {
        case let .create(_, _, _, content), let .write(_, _, _, content): content.bytes.map { [$0] } ?? []
        case .delete, .rename: []
        }
    }
}

public struct ApplyChangeSetRequest: Codable, Equatable, Sendable {
    public var clientID: String
    public var clientEpoch: Int
    public var requestSequence: Int
    public var cursor: ApplyChangeSetCursor
    public var changes: [ApplyChangeSetChange]
    public var diffByteBudget: Int
    public var retentionSeconds: Int

    public init(clientID: String, clientEpoch: Int, requestSequence: Int, cursor: ApplyChangeSetCursor, changes: [ApplyChangeSetChange], diffByteBudget: Int, retentionSeconds: Int) {
        self.clientID = clientID
        self.clientEpoch = clientEpoch
        self.requestSequence = requestSequence
        self.cursor = cursor
        self.changes = changes
        self.diffByteBudget = diffByteBudget
        self.retentionSeconds = retentionSeconds
    }

    public var transactionIdentity: String { "\(clientID):\(clientEpoch):\(requestSequence)" }
    public var secretFragments: [String] { changes.flatMap(\.contents).compactMap { String(data: $0, encoding: .utf8) } }
    public func replacingClientID(_ value: String) -> Self { var copy = self; copy.clientID = value; return copy }
    public func replacingClientEpoch(_ value: Int) -> Self { var copy = self; copy.clientEpoch = value; return copy }
    public func replacingRequestSequence(_ value: Int) -> Self { var copy = self; copy.requestSequence = value; return copy }
    public func replacingFirstContent(_ value: ApplyChangeSetContent) -> Self {
        var copy = self
        guard let first = copy.changes.first else { return copy }
        switch first {
        case let .create(id, path, expected, _): copy.changes[0] = .create(id: id, path: path, expected: expected, content: value)
        case let .write(id, path, expected, _): copy.changes[0] = .write(id: id, path: path, expected: expected, content: value)
        case .delete, .rename: break
        }
        return copy
    }
}

public struct ApplyChangeSetClient: Codable, Equatable, Sendable {
    public let clientID: String
    public let epoch: Int
    public let slot: Int
}

public struct ManagedApplyChangeSetResult: Sendable {
    public let transaction: ApplyChangeSetResult
    public let workspaceFromCursor: String
    public let workspaceCursor: String

    public init(transaction: ApplyChangeSetResult, workspaceFromCursor: String, workspaceCursor: String) {
        self.transaction = transaction
        self.workspaceFromCursor = workspaceFromCursor
        self.workspaceCursor = workspaceCursor
    }
}

public struct ApplyChangeSetTransactionID: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String = UUID().uuidString.lowercased()) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public enum ApplyChangeSetStatus: String, Codable, Equatable, Sendable { case committed, abortedBeforeSideEffect, recoveryRequired }
public enum ApplyChangeSetVisibility: String, Codable, Equatable, Sendable { case aishellSerializedRecoverable }

public struct ApplyChangeSetChangeResult: Codable, Equatable, Sendable {
    public let changeID: String
    public let afterSHA256: String?
    public let kind: String?
    public let beforePath: String?
    public let afterPath: String?
    public let beforeIdentity: String?
    public let afterIdentity: String?
    public let beforeSHA256: String?
    public let beforeSizeBytes: Int?
    public let afterSizeBytes: Int?
    public let beforeMetadata: ApplyChangeSetMetadata?
    public let afterMetadata: ApplyChangeSetMetadata?
    public let trashPath: String?
    /// UTF-8 resulting file content, inlined only for small text files so the caller can confirm and
    /// report exactly what was written without a follow-up read. Nil for deletes, binary, or files
    /// larger than `inlineAfterContentByteLimit` — those remain covered by afterSHA256 and the diff artifact.
    public let afterContent: String?

    /// Upper bound (bytes) for inlining resulting content; larger files stay token-lean via the diff artifact.
    public static let inlineAfterContentByteLimit = 4_096

    public init(
        changeID: String,
        afterSHA256: String?,
        kind: String? = nil,
        beforePath: String? = nil,
        afterPath: String? = nil,
        beforeIdentity: String? = nil,
        afterIdentity: String? = nil,
        beforeSHA256: String? = nil,
        beforeSizeBytes: Int? = nil,
        afterSizeBytes: Int? = nil,
        beforeMetadata: ApplyChangeSetMetadata? = nil,
        afterMetadata: ApplyChangeSetMetadata? = nil,
        trashPath: String? = nil,
        afterContent: String? = nil
    ) {
        self.changeID = changeID; self.afterSHA256 = afterSHA256; self.kind = kind
        self.beforePath = beforePath; self.afterPath = afterPath
        self.beforeIdentity = beforeIdentity; self.afterIdentity = afterIdentity
        self.beforeSHA256 = beforeSHA256; self.beforeSizeBytes = beforeSizeBytes; self.afterSizeBytes = afterSizeBytes
        self.beforeMetadata = beforeMetadata; self.afterMetadata = afterMetadata
        self.trashPath = trashPath; self.afterContent = afterContent
    }

    /// Inline `bytes` as resulting content when they are valid UTF-8 within the byte limit, else nil.
    public static func inlineAfterContent(_ bytes: Data?) -> String? {
        guard let bytes, bytes.count <= inlineAfterContentByteLimit else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}

public struct ApplyChangeSetArtifact: Codable, Equatable, Sendable {
    public let handle: String
    public let sha256: String
    public let sizeBytes: Int
    public let expiresAt: Date?
    public init(handle: String, sha256: String, sizeBytes: Int, expiresAt: Date? = nil) {
        self.handle = handle; self.sha256 = sha256; self.sizeBytes = sizeBytes; self.expiresAt = expiresAt
    }
}

public struct ApplyChangeSetSummary: Codable, Equatable, Sendable {
    public let createCount: Int
    public let writeCount: Int
    public let deleteCount: Int
    public let renameCount: Int
    public let beforeBytes: Int
    public let afterBytes: Int
    public init(createCount: Int, writeCount: Int, deleteCount: Int, renameCount: Int, beforeBytes: Int, afterBytes: Int) {
        self.createCount = createCount; self.writeCount = writeCount; self.deleteCount = deleteCount; self.renameCount = renameCount
        self.beforeBytes = beforeBytes; self.afterBytes = afterBytes
    }
}

public struct ApplyChangeSetResult: Codable, Equatable, Sendable {
    public let transactionID: String?
    public let clientID: String?
    public let clientEpoch: Int?
    public let root: String?
    public let status: ApplyChangeSetStatus
    public let visibility: ApplyChangeSetVisibility
    public let requestSequence: Int
    public let fromCursor: ApplyChangeSetCursor
    public let cursor: ApplyChangeSetCursor
    public let changes: [ApplyChangeSetChangeResult]
    public let changedPaths: [String]
    public let transactionCursorAdvanced: Bool
    public let diffArtifact: ApplyChangeSetArtifact
    public let summary: ApplyChangeSetSummary?
    public let diffPreview: String?
    public let hasMore: Bool?
    public let returnedDiffBytes: Int
    public let omittedDiffBytes: Int

    public init(
        transactionID: String? = nil, clientID: String? = nil, clientEpoch: Int? = nil, root: String? = nil,
        status: ApplyChangeSetStatus, visibility: ApplyChangeSetVisibility, requestSequence: Int,
        fromCursor: ApplyChangeSetCursor, cursor: ApplyChangeSetCursor,
        changes: [ApplyChangeSetChangeResult], changedPaths: [String], transactionCursorAdvanced: Bool,
        diffArtifact: ApplyChangeSetArtifact, summary: ApplyChangeSetSummary? = nil,
        diffPreview: String? = nil, hasMore: Bool? = nil, returnedDiffBytes: Int, omittedDiffBytes: Int
    ) {
        self.transactionID = transactionID; self.clientID = clientID; self.clientEpoch = clientEpoch; self.root = root
        self.status = status; self.visibility = visibility; self.requestSequence = requestSequence
        self.fromCursor = fromCursor; self.cursor = cursor; self.changes = changes; self.changedPaths = changedPaths
        self.transactionCursorAdvanced = transactionCursorAdvanced; self.diffArtifact = diffArtifact
        self.summary = summary; self.diffPreview = diffPreview; self.hasMore = hasMore
        self.returnedDiffBytes = returnedDiffBytes; self.omittedDiffBytes = omittedDiffBytes
    }

    public func replacingChanges(_ value: [ApplyChangeSetChangeResult]) -> Self {
        .init(transactionID: transactionID, clientID: clientID, clientEpoch: clientEpoch, root: root,
            status: status, visibility: visibility, requestSequence: requestSequence,
            fromCursor: fromCursor, cursor: cursor, changes: value, changedPaths: changedPaths,
            transactionCursorAdvanced: transactionCursorAdvanced, diffArtifact: diffArtifact,
            summary: summary, diffPreview: diffPreview, hasMore: hasMore,
            returnedDiffBytes: returnedDiffBytes, omittedDiffBytes: omittedDiffBytes)
    }
    public func replacingArtifact(_ value: ApplyChangeSetArtifact) -> Self {
        .init(transactionID: transactionID, clientID: clientID, clientEpoch: clientEpoch, root: root,
            status: status, visibility: visibility, requestSequence: requestSequence,
            fromCursor: fromCursor, cursor: cursor, changes: changes, changedPaths: changedPaths,
            transactionCursorAdvanced: transactionCursorAdvanced, diffArtifact: value,
            summary: summary, diffPreview: diffPreview, hasMore: hasMore,
            returnedDiffBytes: returnedDiffBytes, omittedDiffBytes: omittedDiffBytes)
    }
}

public struct ApplyChangeSetRecoveryResult: Codable, Equatable, Sendable {
    public let transactionID: ApplyChangeSetTransactionID
    public let evidenceMissing: Bool
}

public struct ApplyChangeSetMetadata: Codable, Equatable, Sendable {
    public let mode: UInt16
    public init(mode: UInt16) { self.mode = mode }
}

public struct ApplyChangeSetError: Error, Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case invalidArgument, contentChanged, expectedAbsenceViolated, workspaceChanged, rootMismatch
        case transactionVolumeMismatch, unsupportedChangeTarget, changeSetConflict, transactionCapabilityUnavailable
        case reservedNamespaceConflict, externalConflictDuringCommit, changeSetStoreCorrupt, changeSetRecoveryRequired
        case changeSetLimitExceeded, changeSetClientNotRegistered, changeSetExpired, changeSetClientEpochAhead
        case changeSetSequenceGap, changeSetSequenceConflict, changeSetClientCapacityExceeded
        case clientRotationBlocked, clientRetireBlocked, clientRegistryReinitializeBlocked, clientControlCapacityExceeded
        case changeSetReservationCorrupt, changeSetSecretStoreUnavailable, clientEpochChanged, clientControlExpired
        case changeSetPreviousPending, clientEpochExhausted
    }
    public let code: Code
    public let message: String
    public let context: ApplyChangeSetFailureContext?
    public init(_ code: Code, _ message: String = "", context: ApplyChangeSetFailureContext? = nil) {
        self.code = code; self.message = message; self.context = context
    }
}

public struct ApplyChangeSetFailureContext: Codable, Equatable, Sendable {
    public let transactionID: String
    public let clientID: String
    public let clientEpoch: Int
    public let requestSequence: Int
    public let changedPaths: [String]
    public let rollbackState: String
    public let recoveryState: String
    public let evidenceHandle: String?
    public let nextAction: String
    public init(transactionID: String, clientID: String, clientEpoch: Int, requestSequence: Int, changedPaths: [String], rollbackState: String, recoveryState: String, evidenceHandle: String?, nextAction: String) {
        self.transactionID = transactionID; self.clientID = clientID; self.clientEpoch = clientEpoch
        self.requestSequence = requestSequence; self.changedPaths = changedPaths; self.rollbackState = rollbackState
        self.recoveryState = recoveryState; self.evidenceHandle = evidenceHandle; self.nextAction = nextAction
    }
}

private extension ApplyChangeSetError {
    func attachingTransaction(
        _ transaction: ApplyChangeSetTransactionID,
        request: ApplyChangeSetRequest,
        changedPaths: [String],
        evidenceHandle: String? = nil
    ) -> Self {
        guard context == nil else { return self }
        let nextAction: String
        if code == .externalConflictDuringCommit {
            nextAction = "resolve_external_conflict_then_retry_apply_change_set"
        } else if evidenceHandle != nil {
            nextAction = "inspect_artifact_then_retry_apply_change_set"
        } else {
            nextAction = "retry_apply_change_set"
        }
        return .init(code, message, context: .init(
            transactionID: transaction.rawValue,
            clientID: request.clientID,
            clientEpoch: request.clientEpoch,
            requestSequence: request.requestSequence,
            changedPaths: changedPaths,
            rollbackState: changedPaths.isEmpty ? "not_started" : "not_proven",
            recoveryState: "recovery_required",
            evidenceHandle: evidenceHandle,
            nextAction: nextAction
        ))
    }
}

public struct ApplyChangeSetSimulatedCrash: Error, Sendable {
    public let point: ApplyChangeSetFailurePoint
}

// MARK: - Capability, failure and corruption seams

public enum ApplyChangeSetCapability: String, Codable, CaseIterable, Sendable { case renameExclusive, renameSwap, directoryFSync }

public enum ApplyChangeSetFailurePoint: String, Codable, CaseIterable, Sendable {
    case reservationFSyncBefore, reservationFSyncAfter, admissionFSyncAfter, materializationBefore
    case stageFSyncAfter, commitDecisionFSyncAfter, firstTargetReceiptAfter, runtimeCursorFSyncAfter
    case runtimeReceiptFSyncAfter
    case diffArtifactFSyncAfter, trashIntentFSyncAfter, trashReceiptFSyncAfter
    case checkpointMarkerFSyncAfter, transactionReceiptFSyncAfter, quotaMaterialRenameAfter
    case quotaPreparedBeforeBinding, quotaAbandonmentIntentAfter, evidenceMetadataReplacementRenameAfter
    case recoveryStageRenameAfter, quotaStateDetachAfter, quotaCanonicalRenameAfter
    case evidenceUnlinkIntentAfter, evidenceMetadataReplacementIntentAfter
    case quotaPrepareBeforeLedger, quotaPrepareAfterLedger
    case registryAtomicReplaceBefore, registryAtomicReplaceAfter
    case dedicatedAdmissionIntentAfter, dedicatedAdmissionRegistryAfter
    case dedicatedTerminalIntentAfter, dedicatedTerminalTransactionAfter, dedicatedTerminalRegistryAfter

    public static let ace051DurabilityPoints: [Self] = [.reservationFSyncBefore, .reservationFSyncAfter, .admissionFSyncAfter, .materializationBefore, .stageFSyncAfter, .commitDecisionFSyncAfter, .firstTargetReceiptAfter, .runtimeCursorFSyncAfter, .runtimeReceiptFSyncAfter, .diffArtifactFSyncAfter, .trashIntentFSyncAfter, .trashReceiptFSyncAfter]
    public static let checkpointReceiptOrderingPoints: [Self] = [.checkpointMarkerFSyncAfter, .transactionReceiptFSyncAfter]
    public static let trashIntentReceiptPoints: [Self] = [.trashIntentFSyncAfter, .trashReceiptFSyncAfter]
    public static let registryAtomicReplacePoints: [Self] = [.registryAtomicReplaceBefore, .registryAtomicReplaceAfter]
    public static let validationReservationAdmissionMaterializationPoints: [Self] = [.reservationFSyncBefore, .reservationFSyncAfter, .admissionFSyncAfter, .materializationBefore]
}

public enum ApplyChangeSetRacePoint: String, Codable, CaseIterable, Sendable {
    case afterRootPin, afterParentPin, beforeTargetMutation, externalBeforeReceipt, externalAfterReceipt
    public static let pathResolutionCases: [Self] = [.afterRootPin, .afterParentPin, .beforeTargetMutation]
    public static let externalDescriptorWriteCases: [Self] = [.externalBeforeReceipt, .externalAfterReceipt]
}

public struct ApplyChangeSetRaceAction: @unchecked Sendable {
    let body: @Sendable () throws -> Void
    public init(_ body: @escaping @Sendable () throws -> Void) { self.body = body }
}

public enum ApplyChangeSetNamespaceCorruption: String, CaseIterable, Sendable { case missingMarker, malformedMarker, wrongRoot, insecurePermissions, symlinkNamespace }
public enum ApplyChangeSetStoreCorruption: String, CaseIterable, Sendable { case missingManifest, malformedManifest, digestMismatch, receiptGap }
public enum ApplyChangeSetCheckpointCorruption: String, CaseIterable, Sendable { case transactionMismatch, digestMismatch, cursorMismatch }
public enum ApplyChangeSetTrashRecoveryAmbiguity: String, CaseIterable, Sendable { case missingReceipt, multipleCandidates, identityMismatch }
public enum ApplyChangeSetEvidenceFailure: String, CaseIterable, Sendable { case quota, write, fsync }
public enum ApplyChangeSetControlRace: String, CaseIterable, Sendable { case allocateAllocate, rotateApply, retireApply }
public enum ApplyChangeSetReservationTamper: String, CaseIterable, Sendable { case binding, length, digest }
public enum ApplyChangeSetPostAdmissionMutation: String, CaseIterable, Sendable { case cursorAdvanced, parentReplaced, capabilityRevoked, expectedContentChanged }
public enum ApplyChangeSetMutationBoundary: String, CaseIterable, Sendable { case beforeFirstTargetReceipt, afterFirstTargetReceipt, afterCommitDecided }
public enum ApplyChangeSetOrphanCase: String, CaseIterable, Sendable {
    case oldBootUnreferenced, activeLease, unknownBinding
    public var mustRemainPinned: Bool { self != .oldBootUnreferenced }
}
public enum ApplyChangeSetMaterialRetention: String, Codable, Equatable, Sendable { case released, quarantined, pinned }
public enum ApplyChangeSetReservationTerminalCase: String, CaseIterable, Sendable {
    case pristine, hasTargetReceipt, commitDecided, corruptUnknown
    public var ownerAbortAllowed: Bool { self == .pristine }
    public var expectedRetention: ApplyChangeSetMaterialRetention {
        switch self { case .pristine: .quarantined; case .hasTargetReceipt, .commitDecided, .corruptUnknown: .pinned }
    }
}

public struct ApplyChangeSetContentFixture: Sendable {
    public let path: String
    public let beforeBytes: Data
    public let afterBytes: Data
    public let expectedMetadata: ApplyChangeSetMetadata
    public var afterSHA256: String { afterBytes.applySHA256 }
    public static let ace051Cases: [Self] = [
        .init(path: "empty.txt", beforeBytes: Data("x".utf8), afterBytes: Data(), expectedMetadata: .init(mode: 0o640)),
        .init(path: "unicode.txt", beforeBytes: Data("before".utf8), afterBytes: Data("日本語\n".utf8), expectedMetadata: .init(mode: 0o640)),
        .init(path: "binary.dat", beforeBytes: Data([0, 1, 2]), afterBytes: Data([0, 255, 10]), expectedMetadata: .init(mode: 0o640)),
    ]
}

public enum ApplyChangeSetTransactionState: String, Codable, Equatable, Sendable {
    case preparing, prepared, commitDecided, filesystemCommitted, runtimeCommitted, trashCommitted, finalized
    case rollbackDecided, rolledBack, recoveryRequired, committed, abortedBeforeSideEffect
}

public actor ApplyChangeSetTestClock {
    private var value: Date
    private let usesSystemClock: Bool
    public init(now: Date) { value = now; usesSystemClock = false }
    public init() { value = Date(); usesSystemClock = true }
    public func now() -> Date { usesSystemClock ? Date() : value }
    public func advance(by duration: Duration) {
        guard !usesSystemClock else { return }
        let c = duration.components
        value = value.addingTimeInterval(Double(c.seconds) + Double(c.attoseconds) / 1e18)
    }
}

private struct PendingRace: @unchecked Sendable { let point: ApplyChangeSetRacePoint; let action: ApplyChangeSetRaceAction }
private struct PendingMutation: Sendable { let mutation: ApplyChangeSetPostAdmissionMutation; let boundary: ApplyChangeSetMutationBoundary }

public actor ApplyChangeSetFailureInjector {
    private var crash: ApplyChangeSetFailurePoint?
    private var race: PendingRace?
    private var mutation: PendingMutation?
    public init() {}
    public func crashOnce(at point: ApplyChangeSetFailurePoint) { crash = point }
    public func raceOnce(at point: ApplyChangeSetRacePoint, action: ApplyChangeSetRaceAction) { race = PendingRace(point: point, action: action) }
    public func mutateOnce(_ value: ApplyChangeSetPostAdmissionMutation, at boundary: ApplyChangeSetMutationBoundary) { mutation = PendingMutation(mutation: value, boundary: boundary) }
    func consumeCrash() -> ApplyChangeSetFailurePoint? { defer { crash = nil }; return crash }
    func consumeCrash(at point: ApplyChangeSetFailurePoint) -> Bool {
        guard crash == point else { return false }
        crash = nil
        return true
    }
    fileprivate func consumeRace() -> PendingRace? { defer { race = nil }; return race }
    fileprivate func consumeMutation() -> PendingMutation? { defer { mutation = nil }; return mutation }
}

// MARK: - Durable shared state

private struct ClientSlot: Codable, Sendable {
    let id: String
    var epoch: Int
    var active: Bool
    var highWater: Int
    var replay: [Int: ReplayRecord]
    var nonterminal: Bool
}
private struct ReplayRecord: Codable, Sendable { let digest: String; let result: ApplyChangeSetResult }
private struct StoredTransaction: Codable, Sendable {
    let id: ApplyChangeSetTransactionID
    var request: ApplyChangeSetRequest?
    var state: ApplyChangeSetTransactionState
    var corrupt: Bool
    var materialExists: Bool
    var retention: ApplyChangeSetMaterialRetention
    var admitted: Bool
    var targetReceipts: Int
    var pendingResult: ApplyChangeSetResult?
    var commitWasDecided: Bool
    var trashIntents: [String: DurableTrashRecord]
    var trashReceipts: [String: DurableTrashRecord]
    var reservationID: String?
    var manifestDigest: String?
    var journal: [TransactionJournalEntry]

    init(id: ApplyChangeSetTransactionID, request: ApplyChangeSetRequest?, state: ApplyChangeSetTransactionState, corrupt: Bool, materialExists: Bool, retention: ApplyChangeSetMaterialRetention, admitted: Bool, targetReceipts: Int, pendingResult: ApplyChangeSetResult? = nil, commitWasDecided: Bool = false, trashIntents: [String: DurableTrashRecord] = [:], trashReceipts: [String: DurableTrashRecord] = [:], reservationID: String? = nil, manifestDigest: String? = nil, journal: [TransactionJournalEntry] = []) {
        self.id = id; self.request = request; self.state = state; self.corrupt = corrupt; self.materialExists = materialExists
        self.retention = retention; self.admitted = admitted; self.targetReceipts = targetReceipts; self.pendingResult = pendingResult
        self.commitWasDecided = commitWasDecided
        self.trashIntents = trashIntents; self.trashReceipts = trashReceipts
        self.reservationID = reservationID
        self.manifestDigest = manifestDigest
        self.journal = journal
    }
}
private struct TransactionJournalPayload: Codable, Equatable, Sendable {
    let sequence: Int
    let phase: String
    let path: String?
    let previousDigest: String
    let state: ApplyChangeSetTransactionState
    let targetReceipts: Int
    let pendingResult: ApplyChangeSetResult?
    let commitWasDecided: Bool
    let trashIntents: [String: DurableTrashRecord]
    let trashReceipts: [String: DurableTrashRecord]
    let manifestDigest: String?
}
private struct TransactionJournalEntry: Codable, Equatable, Sendable {
    let payload: TransactionJournalPayload
    let digest: String
}
private struct DurableTrashRecord: Codable, Equatable, Sendable {
    let changeID: String
    let sourcePath: String
    let candidatePath: String
    let resultingPath: String?
    let device: UInt64
    let inode: UInt64
    let sha256: String
    let trashRootPath: String
    let trashRootDevice: UInt64
    let trashRootInode: UInt64
}
public struct ApplyChangeSetReservation: Codable, Equatable, Sendable {
    public let id: String
    public let requestDigest: String
    let request: ApplyChangeSetRequest
}
private struct StoredReservationBinding: Codable, Sendable {
    let id: String
    let requestDigest: String
    let clientID: String
    let clientEpoch: Int
    let requestSequence: Int
}
public struct ApplyChangeSetDeltaEvent: Codable, Equatable, Sendable { public let transactionID: String; public let path: String }
public struct ApplyChangeSetDelta: Codable, Equatable, Sendable { public let events: [ApplyChangeSetDeltaEvent] }
public enum ApplyChangeSetProfile: Sendable { case development, full }
public struct ApplyChangeSetFrozenFixture: Sendable { public let url: URL; public let expectedSHA256: String }

private struct DurableControlReceipt: Codable, Equatable, Sendable {
    let expiresAt: Date
    let requestDigest: String
    let result: ApplyChangeSetControlResult
}

private struct ChangeSetLegacyStoreExport: Sendable {
    let sourceDigest: String
    let cursorBinding: ChangeSetCutoverCursorBinding
    let registry: ChangeSetLegacyRegistrySnapshot
    let transactions: [ChangeSetTransactionStore.Snapshot]
    let runtimeReceipts: [ChangeSetTransactionStore.RuntimeReceipt]
    let controlReceipts: [String: DurableControlReceipt]
}

private struct DurableChangeSetSnapshot: Codable, Sendable {
    let schema: String
    let rootPath: String
    let generation: String
    let head: UInt64
    let capabilities: Set<ApplyChangeSetCapability>
    let slots: [ClientSlot]
    let transactions: [ApplyChangeSetTransactionID: StoredTransaction]
    let reservations: [String: StoredReservationBinding]
    let tamperedReservations: Set<String>
    let orphanPins: [String: Bool]
    let targetMutationReceipts: Int
    let runtimeEvents: [ApplyChangeSetDeltaEvent]
    let runtimeCommitted: Set<String>
    let controlReceipts: [String: DurableControlReceipt]
    let legacyExpired: Bool
    let legacyReused: Bool
}

private struct DurableChangeSetCoreSnapshot: Codable, Sendable {
    let schema: String
    let rootPath: String
    let generation: String
    let head: UInt64
    let capabilities: Set<ApplyChangeSetCapability>
    let reservations: [String: StoredReservationBinding]
    let tamperedReservations: Set<String>
    let orphanPins: [String: Bool]
    let targetMutationReceipts: Int
    let legacyExpired: Bool
    let legacyReused: Bool
}

private enum LoadedChangeSetSnapshot {
    case legacy(DurableChangeSetSnapshot)
    case core(DurableChangeSetCoreSnapshot)
}

private struct StoredReservationRecord: Codable, Sendable {
    let schema: String
    let reservationID: String
    let requestDigest: String
    let rootDigest: String
    let clientID: String
    let clientEpoch: Int
    let requestSequence: Int
    let plaintextLength: Int
    let quotaBytes: Int
    let nonce: String?
    let ciphertext: String?
    let tag: String?
    let request: ApplyChangeSetRequest?
}
private struct ReservationAAD: Codable, Sendable {
    let schema: String
    let reservationID: String
    let requestDigest: String
    let rootDigest: String
    let clientID: String
    let clientEpoch: Int
    let requestSequence: Int
    let plaintextLength: Int
    let quotaBytes: Int
}

private struct CanonicalReservationHeader: Codable, Sendable {
    let schema: String
    let clientID: String
    let clientEpoch: Int
    let requestSequence: Int
    let cursor: ApplyChangeSetCursor
    let changes: [CanonicalReservationChange]
    let diffByteBudget: Int
    let retentionSeconds: Int
}

private struct CanonicalReservationChange: Codable, Sendable {
    let kind: String
    let changeID: String
    let sourcePathUTF8Base64: String?
    let sourcePathLength: Int?
    let destinationPathUTF8Base64: String?
    let destinationPathLength: Int?
    let sourceExpected: ApplyChangeSetExpected?
    let destinationExpected: ApplyChangeSetExpected?
    let contentOffset: Int?
    let contentLength: Int?
    let contentSHA256: String?
}

private struct PendingJournalRepair: Sendable {
    let transactionID: ApplyChangeSetTransactionID
    let reservationID: String
    let requestDigest: String
    let entry: TransactionJournalEntry
}

private actor ApplyChangeSetState {
    let base: URL
    nonisolated let stateDirectory: URL
    nonisolated let root: URL
    nonisolated let generation: String
    nonisolated let legacyKey: Data?
    nonisolated let snapshotURL: URL
    var head: UInt64 = 0
    var capabilities: Set<ApplyChangeSetCapability>
    var slots: [ClientSlot]
    var transactions: [ApplyChangeSetTransactionID: StoredTransaction] = [:]
    var reservations: [String: StoredReservationBinding] = [:]
    var tamperedReservations: Set<String> = []
    var orphanPins: [String: Bool] = [:]
    var evidenceFailure: ApplyChangeSetEvidenceFailure?
    var targetMutationReceipts = 0
    var runtimeEvents: [ApplyChangeSetDeltaEvent] = []
    var runtimeCommitted: Set<String> = []
    var fullRescans = 0
    var controlReceipts: [String: DurableControlReceipt] = [:]
    var recoveryActive = false
    var persistenceFailure: ApplyChangeSetError?
    var legacyExpired = false
    var legacyReused = false
    var dedicatedStoreMode = false
    private var persistenceGateHeld = false
    private var persistenceGateWaiters: [CheckedContinuation<Void, Never>] = []
    private var persistenceRevision: UInt64 = 0
    private var pendingJournalRepairs: [PendingJournalRepair] = []

    init(base: URL, stateDirectory: URL, root: URL, disabled: Set<ApplyChangeSetCapability>, legacyKey: Data?, legacyStateDirectory: URL? = nil) throws {
        self.base = base; self.stateDirectory = stateDirectory; self.root = root; self.legacyKey = legacyKey
        snapshotURL = stateDirectory.appendingPathComponent("apply-change-set-state.enc.json")
        if FileManager.default.fileExists(atPath: snapshotURL.path) {
            switch try Self.loadSnapshot(at: snapshotURL, key: legacyKey) {
            case let .legacy(snapshot):
                guard snapshot.rootPath == root.standardizedFileURL.resolvingSymlinksInPath().path else {
                    throw ApplyChangeSetError(.changeSetStoreCorrupt, "state root binding mismatch")
                }
                generation = snapshot.generation; head = snapshot.head; capabilities = snapshot.capabilities; slots = snapshot.slots
                transactions = snapshot.transactions; reservations = snapshot.reservations; tamperedReservations = snapshot.tamperedReservations
                orphanPins = snapshot.orphanPins; targetMutationReceipts = snapshot.targetMutationReceipts
                runtimeEvents = snapshot.runtimeEvents; runtimeCommitted = snapshot.runtimeCommitted; controlReceipts = snapshot.controlReceipts
                legacyExpired = snapshot.legacyExpired; legacyReused = snapshot.legacyReused
                let reconciliation = try Self.reconcileTransactionJournals(transactions, stateDirectory: stateDirectory)
                transactions = reconciliation.transactions
                pendingJournalRepairs = reconciliation.repairs
            case let .core(snapshot):
                guard snapshot.rootPath == root.standardizedFileURL.resolvingSymlinksInPath().path else {
                    throw ApplyChangeSetError(.changeSetStoreCorrupt, "core state root binding mismatch")
                }
                generation = snapshot.generation; head = snapshot.head; capabilities = snapshot.capabilities
                reservations = snapshot.reservations; tamperedReservations = snapshot.tamperedReservations
                orphanPins = snapshot.orphanPins; targetMutationReceipts = snapshot.targetMutationReceipts
                legacyExpired = snapshot.legacyExpired; legacyReused = snapshot.legacyReused
                slots = []
                dedicatedStoreMode = true
            }
            let referencedReservations = reservations
            for binding in referencedReservations.values {
                _ = try decryptReservationRecord(binding)
            }
            let reservationDirectory = stateDirectory.appendingPathComponent("reservations", isDirectory: true)
            if FileManager.default.fileExists(atPath: reservationDirectory.path) {
                let referenced = Set(referencedReservations.keys)
                for url in try FileManager.default.contentsOfDirectory(at: reservationDirectory, includingPropertiesForKeys: nil) {
                    let id = url.deletingPathExtension().lastPathComponent
                    if url.pathExtension == "enc" || url.lastPathComponent.hasSuffix(".enc.json") {
                        let record = try JSONDecoder().decode(StoredReservationRecord.self, from: Data(contentsOf: url))
                        guard record.reservationID == id || url.lastPathComponent == "\(record.reservationID).enc.json" else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "orphan reservation filename mismatch") }
                        if !referenced.contains(record.reservationID) {
                            let binding = StoredReservationBinding(id: record.reservationID, requestDigest: record.requestDigest, clientID: record.clientID, clientEpoch: record.clientEpoch, requestSequence: record.requestSequence)
                            _ = try decryptReservationRecord(binding)
                            // quota orphan scannerがledger receiptとidentityを照合してから回収する。
                            // snapshot registry非参照だけを根拠にcanonical finalを先行削除しない。
                        }
                    }
                }
            }
        } else {
            var namespaceInfo = stat()
            let namespace = root.appendingPathComponent(".aishell-transactions", isDirectory: true)
            if lstat(namespace.path, &namespaceInfo) == 0 {
                // 旧版の暗号化履歴はそのまま残す。編集中のファイルがないrootだけ、新しい状態を開始できる。
                guard let legacyStateDirectory,
                      FileManager.default.fileExists(atPath: legacyStateDirectory.appendingPathComponent("apply-change-set-state.enc.json").path),
                      (namespaceInfo.st_mode & S_IFMT) == S_IFDIR, namespaceInfo.st_mode & 0o077 == 0,
                      try FileManager.default.contentsOfDirectory(atPath: namespace.path).sorted() == ["marker.json"],
                      let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: namespace.appendingPathComponent("marker.json"))) as? [String: String],
                      marker["schema"] == "aishell.apply-change-set-namespace.v1",
                      marker["root"] == root.standardizedFileURL.resolvingSymlinksInPath().path,
                      let previousGeneration = marker["generation"], !previousGeneration.isEmpty else {
                    throw ApplyChangeSetError(.changeSetStoreCorrupt, "旧版の編集作業が残っているか、編集状態が欠けています。既存データは変更していません。")
                }
                var rootInfo = stat()
                guard lstat(root.path, &rootInfo) == 0, marker["root_device"] == String(rootInfo.st_dev),
                      marker["root_inode"] == String(rootInfo.st_ino) else { throw ApplyChangeSetError(.rootMismatch) }
                generation = previousGeneration
            } else {
                guard errno == ENOENT else { throw ApplyChangeSetError(.changeSetStoreCorrupt) }
                generation = UUID().uuidString.lowercased()
            }
            capabilities = Set(ApplyChangeSetCapability.allCases).subtracting(disabled)
            slots = (0..<64).map { ClientSlot(id: Self.stableUUID(slot: $0), epoch: 0, active: false, highWater: 0, replay: [:], nonterminal: false) }
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    private func acquirePersistenceGate() async {
        if !persistenceGateHeld { persistenceGateHeld = true; return }
        await withCheckedContinuation { persistenceGateWaiters.append($0) }
    }

    private func releasePersistenceGate() {
        if persistenceGateWaiters.isEmpty { persistenceGateHeld = false }
        else { persistenceGateWaiters.removeFirst().resume() }
    }

    private func quotaPersistenceContext() throws -> (ledger: ChangeSetQuotaLedger, digest: String, reservationID: String)? {
        let reservationID = transactions.values.first(where: { $0.reservationID != nil && FileManager.default.fileExists(atPath: reservationURL($0.reservationID!).path) })?.reservationID
            ?? reservations.values.first?.id
        guard let reservationID else { return nil }
        let record = try JSONDecoder().decode(StoredReservationRecord.self, from: Data(contentsOf: reservationURL(reservationID)))
        let directory = stateDirectory.appendingPathComponent("reservations", isDirectory: true)
        return (try ChangeSetQuotaLedger(ledgerDirectory: directory, reservationID: reservationID), record.requestDigest, reservationID)
    }

    private func quotaMaterializeGeneration(
        _ data: Data,
        destination: URL,
        prefix: String,
        keyPrefix: String,
        context: (ledger: ChangeSetQuotaLedger, digest: String, reservationID: String)
    ) async throws {
        // 台帳が保持する保存先と同じ正規形で旧世代を照合する。
        let destination = destination.deletingLastPathComponent().standardizedFileURL
            .resolvingSymlinksInPath().appendingPathComponent(destination.lastPathComponent).standardizedFileURL
        let views = try await context.ledger.materialViews()
        let candidates = views.filter { $0.id.hasPrefix(prefix + "_") && $0.state == .reserved }
            .sorted { Int($0.id.split(separator: "_").last!)! < Int($1.id.split(separator: "_").last!)! }
        guard let next = candidates.first else { throw ApplyChangeSetError(.changeSetLimitExceeded, "quota persistence slots exhausted") }
        let index = next.id.split(separator: "_").last!
        let key = "\(keyPrefix):\(index):\(context.digest)"
        let old = views.filter { $0.state == .materialized && $0.plannedFinalURL?.path == destination.path }
            .sorted { Int($0.id.split(separator: "_").last!)! < Int($1.id.split(separator: "_").last!)! }.last
        let adopted = try await context.ledger.adoptReserve(materialID: next.id, idempotencyKey: key, finalURL: destination)
        let fd = open(adopted.extentURL.path, O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "quota persistence extent open failed") }
        do {
            try data.withUnsafeBytes { raw in
                var remaining = raw.count; var pointer = raw.baseAddress
                while remaining > 0 {
                    let wrote = Darwin.write(fd, pointer, remaining)
                    guard wrote > 0 else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "quota persistence write failed") }
                    remaining -= wrote; pointer = pointer?.advanced(by: wrote)
                }
            }
            guard fsync(fd) == 0, close(fd) == 0 else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "quota persistence fsync failed") }
            _ = try await context.ledger.authorizeActual(materialID: next.id, idempotencyKey: key, data: data)
            if let old {
                let oldIndex = old.id.split(separator: "_").last!
                let oldKeyPrefix = old.id.split(separator: "_").first!
                _ = try await context.ledger.commitReplacement(oldMaterialID: old.id,
                    oldIdempotencyKey: "\(oldKeyPrefix):\(oldIndex):\(context.digest)", newMaterialID: next.id,
                    newIdempotencyKey: key, finalURL: destination)
            } else {
                guard rename(adopted.extentURL.path, destination.path) == 0 else { throw ApplyChangeSetError(.transactionVolumeMismatch) }
                let directoryFD = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                guard directoryFD >= 0, fsync(directoryFD) == 0 else { if directoryFD >= 0 { close(directoryFD) }; throw ApplyChangeSetError(.changeSetStoreCorrupt) }
                close(directoryFD)
                _ = try await context.ledger.commitMaterialization(materialID: next.id, idempotencyKey: key, finalURL: destination)
            }
        } catch { close(fd); throw error }
    }
    private static func stableUUID(slot: Int) -> String { String(format: "a15e1100-0000-4000-8000-%012d", slot + 1) }

    private static func loadSnapshot(at url: URL, key: Data?) throws -> LoadedChangeSetSnapshot {
        do {
            let data = try Data(contentsOf: url)
            let plaintext = try LegacyChangeSetEncryption.schema(data) == "aishell.apply-change-set-state-envelope.v1"
                ? LegacyChangeSetEncryption.decode(data, key: key,
                    aad: Data("aishell.apply-change-set-state-envelope.v1".utf8)) : data
            let object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any]
            switch object?["schema"] as? String {
            case "aishell.apply-change-set-state.v1":
                return .legacy(try JSONDecoder().decode(DurableChangeSetSnapshot.self, from: plaintext))
            case "aishell.apply-change-set-core-state.v1":
                return .core(try JSONDecoder().decode(DurableChangeSetCoreSnapshot.self, from: plaintext))
            default:
                throw ApplyChangeSetError(.changeSetStoreCorrupt, "unknown encrypted state schema")
            }
        } catch let error as ApplyChangeSetError { throw error }
        catch { throw ApplyChangeSetError(.changeSetStoreCorrupt, "encrypted state authentication failed") }
    }

    private static func reconcileTransactionJournals(
        _ transactions: [ApplyChangeSetTransactionID: StoredTransaction],
        stateDirectory: URL
    ) throws -> (transactions: [ApplyChangeSetTransactionID: StoredTransaction], repairs: [PendingJournalRepair]) {
        var reconciled = transactions
        var repairs: [PendingJournalRepair] = []
        let zeroDigest = String(repeating: "0", count: 64)
        let journalDirectory = stateDirectory.appendingPathComponent("journals", isDirectory: true)
        if FileManager.default.fileExists(atPath: journalDirectory.path) {
            for url in try FileManager.default.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: [.isDirectoryKey]) {
                let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                guard isDirectory || url.pathExtension == "jsonl" else { continue }
                let id = ApplyChangeSetTransactionID(isDirectory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent)
                guard transactions[id] != nil else {
                    throw ApplyChangeSetError(.changeSetStoreCorrupt, "unknown transaction journal")
                }
            }
        }
        for (id, transaction) in transactions {
            let url = stateDirectory.appendingPathComponent("journals", isDirectory: true)
                .appendingPathComponent(id.rawValue).appendingPathExtension("jsonl")
            let entryDirectory = stateDirectory.appendingPathComponent("journals/\(id.rawValue)", isDirectory: true)
            let hasEntryDirectory = FileManager.default.fileExists(atPath: entryDirectory.path)
            if transaction.journal.isEmpty, !FileManager.default.fileExists(atPath: url.path), !hasEntryDirectory {
                guard transaction.admitted else { continue }
                guard Self.isLegalJournalTransition(from: nil, to: transaction.state) else {
                    throw ApplyChangeSetError(.changeSetStoreCorrupt, "transaction snapshot cannot seed its journal")
                }
                let entry = try makeRecoveredJournalEntry(transaction, previous: zeroDigest, sequence: 1)
                guard let reservationID = transaction.reservationID else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "admitted journal repair has no quota reservation") }
                repairs.append(.init(transactionID: id, reservationID: reservationID,
                    requestDigest: try reservationDigest(reservationID, stateDirectory: stateDirectory), entry: entry))
                var value = transaction; value.journal = [entry]; reconciled[id] = value
                continue
            }
            var data: Data
            if hasEntryDirectory {
                let all = try FileManager.default.contentsOfDirectory(at: entryDirectory, includingPropertiesForKeys: nil)
                for temporary in all where temporary.lastPathComponent.hasPrefix(".") && temporary.pathExtension == "tmp" {
                    try FileManager.default.removeItem(at: temporary)
                }
                let entries = try FileManager.default.contentsOfDirectory(at: entryDirectory, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                var combined = Data()
                for (offset, entryURL) in entries.enumerated() {
                    guard entryURL.lastPathComponent == String(format: "entry-%06d.json", offset + 1) else {
                        throw ApplyChangeSetError(.changeSetStoreCorrupt, "transaction journal sequence file is invalid")
                    }
                    combined.append(try Data(contentsOf: entryURL))
                }
                data = combined
            } else {
                guard let legacy = try? Data(contentsOf: url) else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "transaction journal is missing") }
                data = legacy
            }
            if !data.isEmpty, data.last != 0x0A {
                let prefixEnd = data.lastIndex(of: 0x0A).map { data.index(after: $0) } ?? data.startIndex
                let completePrefix = Data(data[..<prefixEnd])
                let completeEntries = try completePrefix.split(separator: 0x0A, omittingEmptySubsequences: true).map { line -> TransactionJournalEntry in
                    do { return try JSONDecoder().decode(TransactionJournalEntry.self, from: Data(line)) }
                    catch { throw ApplyChangeSetError(.changeSetStoreCorrupt, "transaction journal prefix decoding failed") }
                }
                guard completeEntries.count <= transaction.journal.count,
                      Array(transaction.journal.prefix(completeEntries.count)) == completeEntries else {
                    throw ApplyChangeSetError(.changeSetStoreCorrupt, "partial journal does not extend the authenticated snapshot")
                }
                try atomicDurableWrite(completePrefix, to: url)
                data = completePrefix
            }
            if data.isEmpty {
                guard transaction.journal.isEmpty, transaction.admitted,
                      Self.isLegalJournalTransition(from: nil, to: transaction.state) else {
                    throw ApplyChangeSetError(.changeSetStoreCorrupt, "transaction journal is missing")
                }
                let entry = try makeRecoveredJournalEntry(transaction, previous: zeroDigest, sequence: 1)
                guard let reservationID = transaction.reservationID else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "admitted journal repair has no quota reservation") }
                repairs.append(.init(transactionID: id, reservationID: reservationID,
                    requestDigest: try reservationDigest(reservationID, stateDirectory: stateDirectory), entry: entry))
                var value = transaction; value.journal = [entry]; reconciled[id] = value
                continue
            }
            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            var durableEntries = try lines.map { line -> TransactionJournalEntry in
                do { return try JSONDecoder().decode(TransactionJournalEntry.self, from: Data(line)) }
                catch { throw ApplyChangeSetError(.changeSetStoreCorrupt, "transaction journal decoding failed") }
            }
            if durableEntries.count < transaction.journal.count {
                guard Array(transaction.journal.prefix(durableEntries.count)) == durableEntries,
                      let reservationID = transaction.reservationID else {
                    throw ApplyChangeSetError(.changeSetStoreCorrupt, "transaction snapshot is not a journal extension")
                }
                let digest = try reservationDigest(reservationID, stateDirectory: stateDirectory)
                for entry in transaction.journal.dropFirst(durableEntries.count) {
                    repairs.append(.init(transactionID: id, reservationID: reservationID,
                        requestDigest: digest, entry: entry))
                }
                durableEntries = transaction.journal
            }
            guard Array(durableEntries.prefix(transaction.journal.count)) == transaction.journal else {
                throw ApplyChangeSetError(.changeSetStoreCorrupt, "transaction journal differs from durable state")
            }
            var previous = zeroDigest
            var previousState: ApplyChangeSetTransactionState?
            for (offset, entry) in durableEntries.enumerated() {
                guard entry.payload.sequence == offset + 1, entry.payload.previousDigest == previous else {
                    throw ApplyChangeSetError(.changeSetStoreCorrupt, "transaction journal sequence is invalid")
                }
                let payload = try JSONEncoder.sorted.encode(entry.payload)
                var framed = Data(previous.utf8); framed.append(payload)
                guard framed.applySHA256 == entry.digest else {
                    throw ApplyChangeSetError(.changeSetStoreCorrupt, "transaction journal digest is invalid")
                }
                guard Self.isLegalJournalTransition(from: previousState, to: entry.payload.state) else {
                    throw ApplyChangeSetError(.changeSetStoreCorrupt, "transaction journal state transition is invalid")
                }
                if let phaseState = ApplyChangeSetTransactionState(rawValue: entry.payload.phase), phaseState != entry.payload.state {
                    throw ApplyChangeSetError(.changeSetStoreCorrupt, "transaction journal phase/state binding is invalid")
                }
                previousState = entry.payload.state
                previous = entry.digest
            }
            if durableEntries.count > transaction.journal.count, let last = durableEntries.last {
                var value = transaction
                value.state = last.payload.state; value.targetReceipts = last.payload.targetReceipts
                value.pendingResult = last.payload.pendingResult; value.commitWasDecided = last.payload.commitWasDecided
                value.trashIntents = last.payload.trashIntents; value.trashReceipts = last.payload.trashReceipts
                value.manifestDigest = last.payload.manifestDigest
                value.journal = durableEntries; reconciled[id] = value
            } else if let last = durableEntries.last {
                if last.payload.state != transaction.state || last.payload.targetReceipts != transaction.targetReceipts || last.payload.commitWasDecided != transaction.commitWasDecided {
                    guard Self.isLegalJournalTransition(from: last.payload.state, to: transaction.state) else {
                        throw ApplyChangeSetError(.changeSetStoreCorrupt, "transaction snapshot differs from journal tail")
                    }
                    let entry = try makeRecoveredJournalEntry(transaction, previous: last.digest, sequence: durableEntries.count + 1)
                    guard let reservationID = transaction.reservationID else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "journal repair has no quota reservation") }
                    repairs.append(.init(transactionID: id, reservationID: reservationID,
                        requestDigest: try reservationDigest(reservationID, stateDirectory: stateDirectory), entry: entry))
                    var value = transaction; value.journal.append(entry); reconciled[id] = value
                }
            }
        }
        return (reconciled, repairs)
    }

    private static func retireLegacyTransactionJournals(stateDirectory: URL) throws {
        let fileManager = FileManager.default
        let source = stateDirectory.appendingPathComponent("journals", isDirectory: true)
        let retired = stateDirectory.appendingPathComponent(".retired-transaction-journals", isDirectory: true)
        if fileManager.fileExists(atPath: retired.path) {
            try fileManager.removeItem(at: retired)
            try fsyncDirectory(stateDirectory)
        }
        guard fileManager.fileExists(atPath: source.path) else { return }
        guard rename(source.path, retired.path) == 0 else {
            throw ApplyChangeSetError(.changeSetStoreCorrupt, "legacy transaction journals cannot be retired")
        }
        try fsyncDirectory(stateDirectory)
        try fileManager.removeItem(at: retired)
        try fsyncDirectory(stateDirectory)
    }

    private static func fsyncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ApplyChangeSetError(.changeSetStoreCorrupt, "state directory open failed: \(errno)")
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw ApplyChangeSetError(.changeSetStoreCorrupt, "state directory fsync failed: \(errno)")
        }
    }

    private static func reservationDigest(_ reservationID: String, stateDirectory: URL) throws -> String {
        let url = stateDirectory.appendingPathComponent("reservations/\(reservationID).enc.json")
        return try JSONDecoder().decode(StoredReservationRecord.self, from: Data(contentsOf: url)).requestDigest
    }

    private static func makeRecoveredJournalEntry(
        _ transaction: StoredTransaction, previous: String, sequence: Int
    ) throws -> TransactionJournalEntry {
        let payload = TransactionJournalPayload(
            sequence: sequence, phase: transaction.state.rawValue, path: nil, previousDigest: previous,
            state: transaction.state, targetReceipts: transaction.targetReceipts,
            pendingResult: transaction.pendingResult, commitWasDecided: transaction.commitWasDecided,
            trashIntents: transaction.trashIntents, trashReceipts: transaction.trashReceipts,
            manifestDigest: transaction.manifestDigest
        )
        let payloadData = try JSONEncoder.sorted.encode(payload)
        var framed = Data(previous.utf8); framed.append(payloadData)
        let entry = TransactionJournalEntry(payload: payload, digest: framed.applySHA256)
        return entry
    }

    private static func isLegalJournalTransition(
        from: ApplyChangeSetTransactionState?, to: ApplyChangeSetTransactionState
    ) -> Bool {
        guard let from else { return to == .preparing }
        if from == to { return true }
        switch (from, to) {
        case (.preparing, .prepared),
             (.preparing, .rollbackDecided),
             (.prepared, .commitDecided),
             (.prepared, .rollbackDecided),
             (.prepared, .abortedBeforeSideEffect),
             (.rollbackDecided, .rolledBack),
             (.rolledBack, .abortedBeforeSideEffect),
             (.commitDecided, .filesystemCommitted),
             (.filesystemCommitted, .runtimeCommitted),
             (.runtimeCommitted, .trashCommitted),
             (.trashCommitted, .finalized):
            return true
        case (_, .recoveryRequired):
            return from != .finalized && from != .committed && from != .abortedBeforeSideEffect
        case (.recoveryRequired, .filesystemCommitted),
             (.recoveryRequired, .rollbackDecided),
             (.recoveryRequired, .trashCommitted),
             (.recoveryRequired, .runtimeCommitted),
             (.recoveryRequired, .finalized):
            return true
        default:
            return false
        }
    }

    /// admission 後の全 materialization 分岐を、現在の durable state の shadow copy 上で encode する。
    /// production の snapshot/WAL payload 型と保存形式 をそのまま使い、byte 係数では見積もらない。
    func quotaCapacityCandidates(
        reservation: ApplyChangeSetReservation,
        futureResult: ApplyChangeSetResult,
        manifestDigest: String
    ) throws -> (state: [Data], wal: [Data], terminal: [Data]) {
        let transactionID = ApplyChangeSetTransactionID(reservation.request.transactionIdentity)
        let digest = reservation.requestDigest
        let binding = binding(reservation)
        let maximumIdentity = UInt64.max
        let maximumPath = String(repeating: "x", count: Int(PATH_MAX) - 1)
        var trash: [String: DurableTrashRecord] = [:]
        for change in reservation.request.changes {
            guard case let .delete(id, path, _) = change else { continue }
            trash[id] = .init(changeID: id, sourcePath: path,
                candidatePath: root.appendingPathComponent(".aishell-transactions/\(transactionID.rawValue)/trash-\(id)-\(transactionID.rawValue)").path,
                resultingPath: maximumPath, device: maximumIdentity, inode: maximumIdentity,
                sha256: String(repeating: "f", count: 64), trashRootPath: maximumPath,
                trashRootDevice: maximumIdentity, trashRootInode: maximumIdentity)
        }

        func encoded(_ transaction: StoredTransaction, terminalState: Bool) throws -> Data {
            var shadowTransactions = transactions
            shadowTransactions[transactionID] = transaction
            var shadowReservations = reservations
            if terminalState { shadowReservations.removeValue(forKey: reservation.id) }
            else { shadowReservations[reservation.id] = binding }
            var shadowSlots = slots
            if let index = shadowSlots.firstIndex(where: { $0.id == reservation.request.clientID }) {
                shadowSlots[index].highWater = max(shadowSlots[index].highWater, reservation.request.requestSequence)
                shadowSlots[index].nonterminal = !terminalState
                if terminalState {
                    shadowSlots[index].replay[reservation.request.requestSequence] = .init(digest: digest, result: futureResult)
                }
            }
            let snapshotHead = terminalState ? head + 1 : head
            let snapshotTargetReceipts = targetMutationReceipts
                + reservation.request.changes.flatMap(\.paths).count
            var capacityOrphanPins = orphanPins
            for index in 0..<ChangeSetClientRegistry.slotCount {
                capacityOrphanPins[String(format: "quota-shadow-orphan-%044d", index)] = true
            }
            let plaintext: Data
            if dedicatedStoreMode {
                plaintext = try JSONEncoder.sorted.encode(DurableChangeSetCoreSnapshot(
                    schema: "aishell.apply-change-set-core-state.v1",
                    rootPath: root.standardizedFileURL.resolvingSymlinksInPath().path,
                    generation: generation, head: snapshotHead, capabilities: capabilities,
                    reservations: shadowReservations, tamperedReservations: tamperedReservations,
                    orphanPins: capacityOrphanPins, targetMutationReceipts: snapshotTargetReceipts,
                    legacyExpired: legacyExpired, legacyReused: legacyReused))
            } else {
                plaintext = try JSONEncoder.sorted.encode(DurableChangeSetSnapshot(
                    schema: "aishell.apply-change-set-state.v1",
                    rootPath: root.standardizedFileURL.resolvingSymlinksInPath().path, generation: generation,
                    head: snapshotHead, capabilities: capabilities, slots: shadowSlots,
                    transactions: shadowTransactions, reservations: shadowReservations,
                    tamperedReservations: tamperedReservations, orphanPins: capacityOrphanPins,
                    targetMutationReceipts: snapshotTargetReceipts,
                    runtimeEvents: runtimeEvents + reservation.request.changes.compactMap {
                        $0.paths.last.map { .init(transactionID: transactionID.rawValue, path: $0) }
                    }, runtimeCommitted: runtimeCommitted.union([transactionID.rawValue]),
                    controlReceipts: controlReceipts,
                    legacyExpired: legacyExpired, legacyReused: legacyReused))
            }
            return plaintext
        }

        func branch(_ phases: [(String, String?)], terminal: Bool) throws -> (snapshots: [Data], lines: [Data]) {
            var transaction = StoredTransaction(id: transactionID, request: terminal ? reservation.request : nil,
                state: .preparing, corrupt: false, materialExists: !terminal, retention: .pinned, admitted: true,
                targetReceipts: 0, pendingResult: futureResult, commitWasDecided: false,
                trashIntents: trash, trashReceipts: trash, reservationID: terminal ? nil : reservation.id,
                manifestDigest: manifestDigest)
            var snapshots: [Data] = []
            var lines: [Data] = []
            for (phase, path) in phases {
                if let state = ApplyChangeSetTransactionState(rawValue: phase) { transaction.state = state }
                if phase == ApplyChangeSetTransactionState.commitDecided.rawValue { transaction.commitWasDecided = true }
                if phase == "backup_receipt" || phase == "placement_receipt" { transaction.targetReceipts += 1 }
                let previous = transaction.journal.last?.digest ?? String(repeating: "0", count: 64)
                let payload = TransactionJournalPayload(sequence: transaction.journal.count + 1, phase: phase, path: path,
                    previousDigest: previous, state: transaction.state, targetReceipts: transaction.targetReceipts,
                    pendingResult: transaction.pendingResult, commitWasDecided: transaction.commitWasDecided,
                    trashIntents: transaction.trashIntents, trashReceipts: transaction.trashReceipts,
                    manifestDigest: transaction.manifestDigest)
                var framed = Data(previous.utf8); framed.append(try JSONEncoder.sorted.encode(payload))
                let entry = TransactionJournalEntry(payload: payload, digest: framed.applySHA256)
                var line = try JSONEncoder.sorted.encode(entry); line.append(0x0A)
                transaction.journal.append(entry)
                lines.append(line)
                snapshots.append(try encoded(transaction, terminalState: terminal))
            }
            // reservation binding、manifest、preview/identity、evidence expiry は WAL を伴わない独立 persist もある。
            snapshots.append(try encoded(transaction, terminalState: terminal))
            snapshots.append(try encoded(transaction, terminalState: terminal))
            return (snapshots, lines)
        }

        let touched = Array(Set(reservation.request.changes.flatMap(\.paths))).sorted()
        let placements = reservation.request.changes.compactMap { change -> String? in
            switch change {
            case let .create(_, path, _, _), let .write(_, path, _, _): path
            case let .rename(_, _, _, destination, _): destination
            case .delete: nil
            }
        }.sorted()
        let deletes = reservation.request.changes.compactMap { change -> String? in
            if case let .delete(_, path, _) = change { return path }; return nil
        }
        var normal: [(String, String?)] = [(ApplyChangeSetTransactionState.preparing.rawValue, nil),
            (ApplyChangeSetTransactionState.prepared.rawValue, nil),
            (ApplyChangeSetTransactionState.commitDecided.rawValue, nil)]
        normal += touched.map { ("backup_receipt", Optional($0)) }
        normal += placements.map { ("placement_receipt", Optional($0)) }
        normal += [(ApplyChangeSetTransactionState.filesystemCommitted.rawValue, nil),
            (ApplyChangeSetTransactionState.runtimeCommitted.rawValue, nil)]
        for path in deletes { normal += [("trash_intent", path), ("trash_receipt", path)] }
        normal += [(ApplyChangeSetTransactionState.trashCommitted.rawValue, nil),
            (ApplyChangeSetTransactionState.finalized.rawValue, nil)]
        let recovery: [(String, String?)] = Array(normal.dropLast(2)) + [
            (ApplyChangeSetTransactionState.recoveryRequired.rawValue, nil),
            (ApplyChangeSetTransactionState.rollbackDecided.rawValue, nil),
            (ApplyChangeSetTransactionState.rolledBack.rawValue, nil),
            (ApplyChangeSetTransactionState.abortedBeforeSideEffect.rawValue, nil),
        ]
        let normalCandidates = try branch(normal, terminal: false)
        let recoveryCandidates = try branch(Array(recovery), terminal: false)
        let terminalCandidates = try branch(normal, terminal: true)
        let recoveryTerminalCandidates = try branch(recovery, terminal: true)

        // `state_N` は WAL phase 数ではなく、production が snapshot をmaterializeする呼出しと1:1。
        // 名前付き列挙にして、非journal persist（reservation/result/cursor/trash-path/expiry）を落とさない。
        var statePersistEvents = [
            "reservation_binding", "admission_preparing", "admission_prepared", "manifest_digest",
            "pending_result_without_stage_identity", "pending_result_with_stage_identity", "commit_decision",
        ]
        let existingTargets = touched.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        statePersistEvents += existingTargets.map { "backup_receipt:\($0)" }
        statePersistEvents += placements.map { "placement_receipt:\($0)" }
        statePersistEvents += ["filesystem_committed", "runtime_committed_before_journal", "runtime_committed_after_journal"]
        for path in deletes { statePersistEvents += ["trash_intent:\(path)", "trash_receipt:\(path)"] }
        statePersistEvents.append("trash_committed")
        if !deletes.isEmpty { statePersistEvents.append("pending_result_with_trash_paths") }
        statePersistEvents.append("pending_result_with_expiry")
        // Recovery may resume each durable boundary once, then persists the recovered phase and final disposition.
        let recoveryPersistEvents = ["recovery_required", "recovery_filesystem", "recovery_runtime",
            "recovery_trash", "recovery_result", "recovery_finalized"]
        statePersistEvents += recoveryPersistEvents
        let largestState = (normalCandidates.snapshots + recoveryCandidates.snapshots)
            .max(by: { $0.count < $1.count })!
        let stateCount = statePersistEvents.count
        let walCount = max(normalCandidates.lines.count, recoveryCandidates.lines.count)
        let stateCandidates = (0..<stateCount).map { _ in largestState }
        let walCandidates = (0..<walCount).map { index -> Data in
            let values = [normalCandidates.lines[min(index, normalCandidates.lines.count - 1)],
                recoveryCandidates.lines[min(index, recoveryCandidates.lines.count - 1)]]
            return values.max(by: { $0.count < $1.count })!
        }
        // terminal prefixを消費するproduction callは finish、request埋込み、binding解除、handoff の4世代。
        let largestTerminal = (normalCandidates.snapshots + recoveryCandidates.snapshots
            + terminalCandidates.snapshots + recoveryTerminalCandidates.snapshots)
            .max(by: { $0.count < $1.count })!
        return (stateCandidates, walCandidates, Array(repeating: largestTerminal, count: 4))
    }

    private func encodedSnapshot() throws -> Data {
        let plaintext: Data
        if dedicatedStoreMode {
            plaintext = try JSONEncoder.sorted.encode(DurableChangeSetCoreSnapshot(
                schema: "aishell.apply-change-set-core-state.v1",
                rootPath: root.standardizedFileURL.resolvingSymlinksInPath().path,
                generation: generation, head: head, capabilities: capabilities,
                reservations: reservations, tamperedReservations: tamperedReservations,
                orphanPins: orphanPins, targetMutationReceipts: targetMutationReceipts,
                legacyExpired: legacyExpired, legacyReused: legacyReused))
        } else {
            plaintext = try JSONEncoder.sorted.encode(DurableChangeSetSnapshot(
                schema: "aishell.apply-change-set-state.v1", rootPath: root.standardizedFileURL.resolvingSymlinksInPath().path,
                generation: generation, head: head, capabilities: capabilities, slots: slots, transactions: transactions,
                reservations: reservations, tamperedReservations: tamperedReservations, orphanPins: orphanPins,
                targetMutationReceipts: targetMutationReceipts, runtimeEvents: runtimeEvents, runtimeCommitted: runtimeCommitted,
                controlReceipts: controlReceipts,
                legacyExpired: legacyExpired, legacyReused: legacyReused))
        }
        return plaintext
    }

    func persist() throws {
        try Self.atomicDurableWrite(try encodedSnapshot(), to: snapshotURL)
    }
    func quotaSnapshotByteCount() throws -> Int { try encodedSnapshot().count }

    func repairPendingJournals() async throws {
        if dedicatedStoreMode {
            pendingJournalRepairs.removeAll()
            return
        }
        guard !pendingJournalRepairs.isEmpty else { return }
        for repair in pendingJournalRepairs {
            var line = try JSONEncoder.sorted.encode(repair.entry); line.append(0x0A)
            let directory = stateDirectory.appendingPathComponent("journals/\(repair.transactionID.rawValue)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let destination = directory.appendingPathComponent(String(format: "entry-%06d.json", repair.entry.payload.sequence))
            if FileManager.default.fileExists(atPath: destination.path) {
                guard try Data(contentsOf: destination) == line else {
                    throw ApplyChangeSetError(.changeSetStoreCorrupt, "journal repair destination differs")
                }
                continue
            }
            let ledger = try ChangeSetQuotaLedger(
                ledgerDirectory: stateDirectory.appendingPathComponent("reservations", isDirectory: true),
                reservationID: repair.reservationID
            )
            try await Self.materializeQuotaData(line, destination: destination, ledger: ledger,
                materialID: "wal_\(repair.entry.payload.sequence - 1)",
                idempotencyKey: "wal:\(repair.entry.payload.sequence - 1):\(repair.requestDigest)")
        }
        pendingJournalRepairs.removeAll()
    }

    nonisolated private func reservationURL(_ id: String) -> URL {
        stateDirectory.appendingPathComponent("reservations", isDirectory: true).appendingPathComponent(id).appendingPathExtension("enc.json")
    }
    nonisolated private func binding(_ reservation: ApplyChangeSetReservation) -> StoredReservationBinding {
        .init(id: reservation.id, requestDigest: reservation.requestDigest, clientID: reservation.request.clientID,
              clientEpoch: reservation.request.clientEpoch, requestSequence: reservation.request.requestSequence)
    }
    nonisolated private func reservationAAD(_ reservation: ApplyChangeSetReservation, plaintextLength: Int, quotaBytes: Int) -> ReservationAAD {
        .init(schema: "aishell.apply-change-set-reservation-record.v1", reservationID: reservation.id,
              requestDigest: reservation.requestDigest, rootDigest: root.standardizedFileURL.resolvingSymlinksInPath().path.applyStringSHA256,
              clientID: reservation.request.clientID, clientEpoch: reservation.request.clientEpoch,
              requestSequence: reservation.request.requestSequence, plaintextLength: plaintextLength, quotaBytes: quotaBytes)
    }
    private func writeReservationRecord(_ reservation: ApplyChangeSetReservation, ledger: ChangeSetQuotaLedger,
        simulateCanonicalRenameCrash: Bool = false) async throws {
        let plaintext = try JSONEncoder.sorted.encode(reservation.request)
        let aad = reservationAAD(reservation, plaintextLength: plaintext.count, quotaBytes: 0)
        let record = StoredReservationRecord(schema: aad.schema, reservationID: aad.reservationID,
            requestDigest: aad.requestDigest, rootDigest: aad.rootDigest, clientID: aad.clientID,
            clientEpoch: aad.clientEpoch, requestSequence: aad.requestSequence, plaintextLength: aad.plaintextLength,
            quotaBytes: 0, nonce: nil, ciphertext: nil, tag: nil, request: reservation.request)
        let encoded = try JSONEncoder.sorted.encode(record)
        try await Self.materializeQuotaData(encoded, destination: reservationURL(reservation.id), ledger: ledger,
            materialID: "canonical", idempotencyKey: "canonical:\(reservation.requestDigest)",
            crashPoint: simulateCanonicalRenameCrash ? .quotaCanonicalRenameAfter : nil)
        _ = try decryptReservationRecord(binding(reservation))
    }
    private func writeTestingReservationRecord(_ reservation: ApplyChangeSetReservation) throws {
        let plaintext = try JSONEncoder.sorted.encode(reservation.request)
        let aad = reservationAAD(reservation, plaintextLength: plaintext.count, quotaBytes: 0)
        let record = StoredReservationRecord(schema: aad.schema, reservationID: aad.reservationID,
            requestDigest: aad.requestDigest, rootDigest: aad.rootDigest, clientID: aad.clientID,
            clientEpoch: aad.clientEpoch, requestSequence: aad.requestSequence, plaintextLength: aad.plaintextLength,
            quotaBytes: 0, nonce: nil, ciphertext: nil, tag: nil, request: reservation.request)
        try Self.atomicDurableWrite(try JSONEncoder.sorted.encode(record), to: reservationURL(reservation.id))
    }
    nonisolated private func decryptReservationRecord(_ binding: StoredReservationBinding) throws -> ApplyChangeSetRequest {
        do {
            let data = try Data(contentsOf: reservationURL(binding.id))
            let record = try JSONDecoder().decode(StoredReservationRecord.self, from: data)
            let aad = ReservationAAD(schema: record.schema, reservationID: record.reservationID, requestDigest: record.requestDigest,
                rootDigest: record.rootDigest, clientID: record.clientID, clientEpoch: record.clientEpoch,
                requestSequence: record.requestSequence, plaintextLength: record.plaintextLength, quotaBytes: record.quotaBytes)
            guard record.schema == "aishell.apply-change-set-reservation-record.v1", record.reservationID == binding.id,
                  record.requestDigest == binding.requestDigest,
                  record.rootDigest == root.standardizedFileURL.resolvingSymlinksInPath().path.applyStringSHA256,
                  record.clientID == binding.clientID,
                  record.clientEpoch == binding.clientEpoch, record.requestSequence == binding.requestSequence else { throw ApplyChangeSetError(.changeSetReservationCorrupt) }
            let plaintext: Data
            let request: ApplyChangeSetRequest
            if let stored = record.request {
                request = stored
                plaintext = try JSONEncoder.sorted.encode(stored)
            } else {
                plaintext = try LegacyChangeSetEncryption.decode(
                    data, key: legacyKey,
                    aad: JSONEncoder.sorted.encode(aad))
                request = try JSONDecoder().decode(ApplyChangeSetRequest.self, from: plaintext)
            }
            guard plaintext.count == record.plaintextLength, request.clientID == binding.clientID,
                  request.clientEpoch == binding.clientEpoch, request.requestSequence == binding.requestSequence,
                  ApplyChangeSetService.requestDigest(request) == binding.requestDigest else { throw ApplyChangeSetError(.changeSetReservationCorrupt) }
            return request
        } catch let error as ApplyChangeSetError { throw error }
        catch { throw ApplyChangeSetError(.changeSetReservationCorrupt, "保存された編集予約を読み取れません。") }
    }
    private func removeReservationRecord(_ id: String) throws {
        let url = reservationURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let fd = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd >= 0 { guard fsync(fd) == 0 else { close(fd); throw ApplyChangeSetError(.changeSetStoreCorrupt) }; close(fd) }
    }

    private static func atomicDurableWrite(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "state temp open failed: \(errno)") }
        do {
            try data.withUnsafeBytes { raw in
                guard var address = raw.baseAddress else { return }
                var remaining = raw.count
                while remaining > 0 {
                    let count = Darwin.write(descriptor, address, remaining)
                    guard count > 0 else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "state write failed: \(errno)") }
                    remaining -= count; address = address.advanced(by: count)
                }
            }
            guard fsync(descriptor) == 0 else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "state fsync failed: \(errno)") }
            guard close(descriptor) == 0 else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "state close failed: \(errno)") }
            guard rename(temporary.path, destination.path) == 0 else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "state atomic replace failed: \(errno)") }
            let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard directoryFD >= 0 else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "state directory open failed: \(errno)") }
            defer { close(directoryFD) }
            guard fsync(directoryFD) == 0 else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "state directory fsync failed: \(errno)") }
        } catch {
            close(descriptor); try? FileManager.default.removeItem(at: temporary); throw error
        }
    }

    private static func materializeQuotaData(
        _ data: Data,
        destination: URL,
        ledger: ChangeSetQuotaLedger,
        materialID: String,
        idempotencyKey: String,
        crashPoint: ApplyChangeSetFailurePoint? = nil
    ) async throws {
        let adopted = try await ledger.adoptReserve(materialID: materialID, idempotencyKey: idempotencyKey, finalURL: destination)
        let descriptor = open(adopted.extentURL.path, O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "quota extent open failed") }
        do {
            try data.withUnsafeBytes { raw in
                var remaining = raw.count; var pointer = raw.baseAddress
                while remaining > 0 {
                    let wrote = Darwin.write(descriptor, pointer, remaining)
                    guard wrote > 0 else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "quota extent write failed") }
                    remaining -= wrote; pointer = pointer?.advanced(by: wrote)
                }
            }
            guard fsync(descriptor) == 0, close(descriptor) == 0 else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "quota extent fsync failed") }
            _ = try await ledger.authorizeActual(materialID: materialID, idempotencyKey: idempotencyKey, data: data)
            guard rename(adopted.extentURL.path, destination.path) == 0 else { throw ApplyChangeSetError(.transactionVolumeMismatch) }
            let directoryFD = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard directoryFD >= 0, fsync(directoryFD) == 0 else { if directoryFD >= 0 { close(directoryFD) }; throw ApplyChangeSetError(.changeSetStoreCorrupt) }
            close(directoryFD)
            if let crashPoint { throw ApplyChangeSetSimulatedCrash(point: crashPoint) }
            _ = try await ledger.commitMaterialization(materialID: materialID, idempotencyKey: idempotencyKey, finalURL: destination)
        } catch { close(descriptor); throw error }
    }
}

public final class ApplyChangeSetStateStore: @unchecked Sendable {
    fileprivate let state: ApplyChangeSetState
    fileprivate let legacyKey: Data?

    public init(baseDirectory: URL, stateDirectory: URL, root: URL,
                disabledCapabilities: Set<ApplyChangeSetCapability> = [], legacyStateDirectory: URL? = nil) throws {
        legacyKey = try LegacyChangeSetEncryption.key(in: stateDirectory)
        state = try ApplyChangeSetState(base: baseDirectory, stateDirectory: stateDirectory, root: root,
            disabled: disabledCapabilities, legacyKey: legacyKey, legacyStateDirectory: legacyStateDirectory)
    }
}

// MARK: - Service

private actor ApplyChangeSetOperationGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var held = false
    private var waiters: [Waiter] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if !held { held = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append(.init(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        do { try Task.checkCancellation() }
        catch { release(); throw error }
    }

    func release() {
        guard !waiters.isEmpty else { held = false; return }
        waiters.removeFirst().continuation.resume()
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

private final class ApplyChangeSetRegistryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func set(_ date: Date) { lock.withLock { value = date } }
    func now() -> Date { lock.withLock { value } }
}

private actor ApplyChangeSetCutoverCompatibilityAdapter: ChangeSetCutoverCompatibilityPreparing {
    private let store: LegacyControlCompatStore
    private var sourceDigest: String?
    private var payloadDigest: String?
    private var snapshot: LegacyControlCompatSnapshot?

    init(store: LegacyControlCompatStore) { self.store = store }

    func configure(sourceDigest: String, snapshot: LegacyControlCompatSnapshot) {
        self.sourceDigest = sourceDigest
        self.snapshot = snapshot
    }

    func prepareLegacyCompatibility(sourceDigest: String, payloadDigest: String) async throws {
        guard self.sourceDigest == sourceDigest,
              let snapshot, snapshot.sourceDigest == sourceDigest else {
            throw ChangeSetCutoverError(.sourceConflict)
        }
        if let existing = self.payloadDigest, existing != payloadDigest {
            throw ChangeSetCutoverError(.sourceConflict)
        }
        self.payloadDigest = payloadDigest
        try await store.importLegacy(snapshot)
    }

    func validateLegacyCompatibility(sourceDigest: String, payloadDigest: String) async throws {
        guard await store.sourceDigest() == sourceDigest else {
            throw ChangeSetCutoverError(.sourceConflict)
        }
        if let existing = self.payloadDigest, existing != payloadDigest {
            throw ChangeSetCutoverError(.sourceConflict)
        }
        self.payloadDigest = payloadDigest
    }
}

public actor ApplyChangeSetService {
    private struct QuotaLeaseManifest: Codable {
        let schema: String
        let reservationID: String
        let requestDigest: String
        let bootID: String
        let processStartIdentity: String
        let instanceNonce: String
        let leaseExpiresAt: Date

        var owner: ChangeSetQuotaLedger.OwnerBinding {
            .init(bootID: bootID, processStartIdentity: processStartIdentity,
                instanceNonce: instanceNonce, leaseExpiresAt: leaseExpiresAt)
        }
    }
    private let runtimeStore: RuntimeStore
    private let stateDirectory: URL
    private let evidenceStore: EvidenceStore
    private let workspaceRuntime: WorkspaceStateRuntime
    private let faults: ApplyChangeSetFailureInjector
    private let clock: ApplyChangeSetTestClock
    private let state: ApplyChangeSetState
    private let stateStore: ApplyChangeSetStateStore
    private let quotaOwner: ChangeSetQuotaLedger.OwnerBinding
    private let clientRegistry: ChangeSetClientRegistry
    private let transactionStore: ChangeSetTransactionStore
    private let registryClock: ApplyChangeSetRegistryClock
    private let legacyControlStore: LegacyControlCompatStore
    private let cutoverCompatibility: ApplyChangeSetCutoverCompatibilityAdapter
    private let cutoverCoordinator: ChangeSetCutoverCoordinator
    private let operationGate = ApplyChangeSetOperationGate()
    private var quotaLeaseDescriptors: [String: Int32] = [:]
    private var dedicatedStoresBootstrapped = false

    public init(runtimeStore: RuntimeStore, stateDirectory: URL, evidenceStore: EvidenceStore, stateStore: ApplyChangeSetStateStore, workspaceRuntime: WorkspaceStateRuntime, failureInjector: ApplyChangeSetFailureInjector, clock: ApplyChangeSetTestClock,
        quotaOwner overrideQuotaOwner: ChangeSetQuotaLedger.OwnerBinding? = nil) throws {
        self.runtimeStore = runtimeStore; self.stateDirectory = stateDirectory; self.evidenceStore = evidenceStore
        self.workspaceRuntime = workspaceRuntime; faults = failureInjector; self.clock = clock; self.stateStore = stateStore; state = stateStore.state
        quotaOwner = overrideQuotaOwner ?? .current(leaseDuration: 60)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let storeKey = stateStore.legacyKey
        let registryClock = ApplyChangeSetRegistryClock()
        self.registryClock = registryClock
        clientRegistry = try ChangeSetClientRegistry(
            directory: stateDirectory.appendingPathComponent("client-registry", isDirectory: true),
            rootIdentityDigest: stateStore.state.root.standardizedFileURL.resolvingSymlinksInPath().path.applyStringSHA256,
            now: { registryClock.now() }
        )
        transactionStore = try ChangeSetTransactionStore(
            directory: stateDirectory.appendingPathComponent("transaction-store", isDirectory: true),
            legacyKey: storeKey,
            maxRuntimeReceipts: ChangeSetClientRegistry.slotCount * ChangeSetClientRegistry.replayCapacity,
            maxTransactionReferences: ChangeSetClientRegistry.slotCount * ChangeSetClientRegistry.replayCapacity
        )
        let legacyControlStore = try LegacyControlCompatStore(
            directory: stateDirectory.appendingPathComponent("legacy-control-compat", isDirectory: true),
            stateDirectory: stateDirectory)
        self.legacyControlStore = legacyControlStore
        let cutoverCompatibility = ApplyChangeSetCutoverCompatibilityAdapter(store: legacyControlStore)
        self.cutoverCompatibility = cutoverCompatibility
        cutoverCoordinator = try ChangeSetCutoverCoordinator(
            directory: stateDirectory.appendingPathComponent("cross-store-cutover", isDirectory: true),
            legacyKey: storeKey, registry: clientRegistry, transactionStore: transactionStore,
            compatibility: cutoverCompatibility, now: { registryClock.now() })
    }

    private func withOperationGate<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        try await operationGate.acquire()
        do {
            let result = try await operation()
            await operationGate.release()
            return result
        } catch let error as ChangeSetCutoverError {
            await operationGate.release()
            throw ApplyChangeSetError(.changeSetStoreCorrupt,
                "cross-store cutover rejected durable state: \(error.code.rawValue) \(error.message)")
        } catch let error as ChangeSetTransactionStore.StoreError {
            await operationGate.release()
            throw ApplyChangeSetError(.changeSetStoreCorrupt,
                "dedicated transaction store rejected durable state: \(error)")
        } catch {
            await operationGate.release()
            throw error
        }
    }

    private func quotaLedger(
        reservationID: String,
        lifecycleFailurePoint: ChangeSetQuotaLedger.LifecycleFailurePoint? = nil
    ) throws -> ChangeSetQuotaLedger {
        try ChangeSetQuotaLedger(
            ledgerDirectory: stateDirectory.appendingPathComponent("reservations", isDirectory: true),
            reservationID: reservationID,
            ownerBinding: quotaOwner,
            lifecycleFailurePoint: lifecycleFailurePoint
        )
    }

    private func quotaLeaseURL(_ reservationID: String) -> URL {
        stateDirectory.appendingPathComponent("reservations/.aishell-quota-\(reservationID).lease")
    }

    private func acquireQuotaLease(reservationID: String, requestDigest: String) throws {
        if quotaLeaseDescriptors[reservationID] != nil { return }
        let url = quotaLeaseURL(reservationID)
        let createdFD = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        let descriptor: Int32
        if createdFD >= 0 {
            descriptor = createdFD
            let manifest = QuotaLeaseManifest(schema: "aishell.apply-change-set-quota-lease.v1",
                reservationID: reservationID, requestDigest: requestDigest, bootID: quotaOwner.bootID,
                processStartIdentity: quotaOwner.processStartIdentity, instanceNonce: quotaOwner.instanceNonce,
                leaseExpiresAt: quotaOwner.leaseExpiresAt)
            let data = try JSONEncoder.sorted.encode(manifest)
            do {
                let wrote = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
                guard wrote == data.count, fsync(descriptor) == 0 else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "quota lease persist failed") }
                let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                guard parent >= 0, fsync(parent) == 0 else {
                    if parent >= 0 { close(parent) }
                    throw ApplyChangeSetError(.changeSetStoreCorrupt, "quota lease directory persist failed")
                }
                close(parent)
            } catch {
                close(descriptor)
                throw error
            }
        } else {
            guard errno == EEXIST else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "quota lease create failed") }
            descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "quota lease open failed") }
            let manifest = try JSONDecoder().decode(QuotaLeaseManifest.self, from: Data(contentsOf: url))
            guard manifest.schema == "aishell.apply-change-set-quota-lease.v1",
                  manifest.reservationID == reservationID, manifest.requestDigest == requestDigest else {
                close(descriptor)
                throw ApplyChangeSetError(.changeSetStoreCorrupt, "quota lease binding mismatch")
            }
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw ApplyChangeSetError(.changeSetRecoveryRequired, "quota lease is owned by a live request")
        }
        quotaLeaseDescriptors[reservationID] = descriptor
    }

    private func unlockQuotaLease(_ reservationID: String) {
        guard let descriptor = quotaLeaseDescriptors.removeValue(forKey: reservationID) else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    private static func readQuotaLease(descriptor: Int32) throws -> QuotaLeaseManifest {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= 4_096, lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw ApplyChangeSetError(.changeSetStoreCorrupt, "quota lease inspection failed")
        }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        guard count == data.count else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "quota lease read failed") }
        return try JSONDecoder().decode(QuotaLeaseManifest.self, from: data)
    }

    private static func durableUnlink(_ url: URL) throws {
        if unlink(url.path) != 0, errno != ENOENT { throw ApplyChangeSetError(.changeSetStoreCorrupt, "quota orphan unlink failed") }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0, fsync(parent) == 0 else {
            if parent >= 0 { close(parent) }
            throw ApplyChangeSetError(.changeSetStoreCorrupt, "quota orphan directory persist failed")
        }
        close(parent)
    }

    private func reconcilePreparedQuotaOrphans(now: Date = Date()) async throws {
        let directory = stateDirectory.appendingPathComponent("reservations", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let leases = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".aishell-quota-") && $0.pathExtension == "lease" }
        for leaseURL in leases.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = leaseURL.deletingPathExtension().lastPathComponent
            let candidateID = String(name.dropFirst(".aishell-quota-".count))
            if quotaLeaseDescriptors[candidateID] != nil { continue }
            let descriptor = open(leaseURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "quota lease scan open failed") }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); continue }
            defer { _ = flock(descriptor, LOCK_UN); close(descriptor) }
            let manifest = try Self.readQuotaLease(descriptor: descriptor)
            let expectedName = ".aishell-quota-\(manifest.reservationID).lease"
            guard manifest.schema == "aishell.apply-change-set-quota-lease.v1",
                  leaseURL.lastPathComponent == expectedName,
                  now >= manifest.leaseExpiresAt.addingTimeInterval(600) else { continue }

            let references = await state.quotaReferenceState(manifest.reservationID)
            if references.admission { continue }
            let simulateAbandonmentCrash = await faults.consumeCrash(at: .quotaAbandonmentIntentAfter)
            let ledger = try ChangeSetQuotaLedger(ledgerDirectory: directory,
                reservationID: manifest.reservationID, ownerBinding: manifest.owner,
                lifecycleFailurePoint: simulateAbandonmentCrash ? .abandonmentIntentPersisted : nil)
            _ = try await ledger.reconcile()
            let materials = try await ledger.materialViews()
            let materialized = materials.filter { $0.state == .materialized }
            let canonicalMaterials = materialized.filter { $0.kind == .canonicalEnvelope }
            let stateMaterials = materialized.filter { $0.kind == .stateSnapshot }
            guard canonicalMaterials.count <= 1, stateMaterials.count <= 1,
                  materialized.count == canonicalMaterials.count + stateMaterials.count,
                  materials.allSatisfy({ material in
                      material.state == .reserved || material.state == .adopted || material.state == .authorized
                          || material.state == .released || material.state == .abandoned
                          || (material.state == .materialized && (material.kind == .canonicalEnvelope || material.kind == .stateSnapshot))
                  }) else {
                continue
            }
            let canonicalBinding: ChangeSetQuotaLedger.PreparedAbandonmentAttestation.CanonicalMaterializedBinding?
            if let canonical = canonicalMaterials.first, let final = canonical.plannedFinalURL {
                var info = stat()
                guard lstat(final.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
                let data = try Data(contentsOf: final, options: [.mappedIfSafe])
                canonicalBinding = .init(materialID: canonical.id, finalURL: final,
                    device: UInt64(info.st_dev), inode: UInt64(info.st_ino), bytes: data.count, sha256: data.applySHA256)
            } else {
                canonicalBinding = nil
            }
            let transactionIdentity = try await state.reservationTransactionIdentity(manifest.reservationID)
            let transactionReferenced = transactionIdentity.map {
                FileManager.default.fileExists(atPath: state.root.appendingPathComponent(".aishell-transactions/\($0)").path)
            } ?? false
            if transactionReferenced { continue }
            if references.registry {
                try await state.detachUnadmittedReservation(manifest.reservationID)
                if await faults.consumeCrash(at: .quotaStateDetachAfter) {
                    throw ApplyChangeSetSimulatedCrash(point: .quotaStateDetachAfter)
                }
            }
            // detach後にprocessが落ちても、次回scanはregistry=falseから同じ収束を再開する。
            // abandonment validatorへ渡す前に、snapshot世代のquota所有権を必ず終了する。
            for material in try await ledger.materialViews() where material.state == .materialized && material.kind == .stateSnapshot {
                guard let suffix = material.id.split(separator: "_").last, Int(suffix) != nil else {
                    throw ApplyChangeSetError(.changeSetStoreCorrupt, "quota state generation identifier is invalid")
                }
                try await ledger.releaseMaterial(materialID: material.id,
                    idempotencyKey: "state:\(suffix):\(manifest.requestDigest)")
            }

            let canonicalAttestation = canonicalBinding.map {
                "\($0.materialID)\u{0}\($0.finalURL.path)\u{0}\($0.device)\u{0}\($0.inode)\u{0}\($0.bytes)\u{0}\($0.sha256)"
            } ?? "none"
            let attestationSource = "\(manifest.reservationID)\u{0}\(manifest.requestDigest)\u{0}false\u{0}false\u{0}false\u{0}\(canonicalAttestation)"
            let attestation = ChangeSetQuotaLedger.PreparedAbandonmentAttestation(
                digest: Data(attestationSource.utf8).applySHA256, owner: manifest.owner,
                admissionReferenced: false, transactionDirectoryReferenced: false, registryReferenced: false,
                canonicalMaterialized: canonicalBinding)
            do {
                _ = try await ledger.abandonPrepared(attestation: attestation, now: now)
            } catch is ChangeSetQuotaLedger.SimulatedLifecycleCrash {
                throw ApplyChangeSetSimulatedCrash(point: .quotaAbandonmentIntentAfter)
            }
            try Self.durableUnlink(directory.appendingPathComponent("\(manifest.reservationID).enc.json"))
            try Self.durableUnlink(directory.appendingPathComponent(".aishell-quota-\(manifest.reservationID)-ledger.reserve"))
            try Self.durableUnlink(directory.appendingPathComponent("quota-\(manifest.reservationID).json"))
            try Self.durableUnlink(leaseURL)
        }
    }

    private func prepareQuota(_ reservation: ApplyChangeSetReservation,
        failurePoint: ApplyChangeSetFailurePoint? = nil) async throws -> ChangeSetQuotaLedger {
        let reservationDirectory = stateDirectory.appendingPathComponent("reservations", isDirectory: true)
        let evidenceDirectory = stateDirectory.appendingPathComponent("evidence", isDirectory: true)
        let transactionNamespace = state.root.appendingPathComponent(".aishell-transactions", isDirectory: true)
        try FileManager.default.createDirectory(at: reservationDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        try acquireQuotaLease(reservationID: reservation.id, requestDigest: reservation.requestDigest)
        do {
        if failurePoint == .quotaPrepareBeforeLedger {
            throw ApplyChangeSetSimulatedCrash(point: .quotaPrepareBeforeLedger)
        }
        let canonical = try ChangeSetQuotaCapacityPlanner.canonicalEnvelope(reservationID: reservation.id,
            digest: reservation.requestDigest, request: reservation.request, root: state.root)
        let filesystem = try ChangeSetQuotaCapacityPlanner.filesystemPayload(request: reservation.request,
            digest: reservation.requestDigest, root: state.root)
        let future = try await state.quotaCapacityCandidates(reservation: reservation,
            futureResult: filesystem.result, manifestDigest: filesystem.manifest.applySHA256)
        let abortDiff = Data("{\"paths\":[]}".utf8)
        let metadata = try ChangeSetQuotaCapacityPlanner.evidenceMetadata(artifact: filesystem.diff.artifact,
            retentionSeconds: reservation.request.retentionSeconds)
        let abortMetadata = try ChangeSetQuotaCapacityPlanner.evidenceMetadata(artifact: abortDiff,
            retentionSeconds: reservation.request.retentionSeconds)
        var direct: [ChangeSetQuotaCapacityPlanner.DirectMaterial] = []
        var stageIndex = 0, trashIndex = 0
        for change in reservation.request.changes {
            let size: Int?
            switch change {
            case let .create(_, _, _, content), let .write(_, _, _, content): size = content.bytes?.count
            case let .rename(_, source, _, _, _): size = (try? state.root.appendingPathComponent(source).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            case let .delete(_, path, _):
                size = nil
                let bytes = (try? state.root.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                direct.append(.init(id: "trash_\(trashIndex)", idempotencyKey: "trash:\(trashIndex):\(reservation.requestDigest)",
                    kind: .trashBackup, bytes: bytes, directory: transactionNamespace))
                trashIndex += 1
            }
            if let size {
                direct.append(.init(id: "stage_\(stageIndex)", idempotencyKey: "stage:\(stageIndex):\(reservation.requestDigest)",
                    kind: .afterStage, bytes: size, directory: transactionNamespace))
                stageIndex += 1
            }
        }
        let capacities = try ChangeSetQuotaCapacityPlanner.capacities(digest: reservation.requestDigest,
            candidates: .init(canonical: canonical, manifest: filesystem.manifest, diff: filesystem.diff,
                evidenceMetadata: metadata, abortDiff: abortDiff, abortEvidenceMetadata: abortMetadata,
                state: future.state, wal: future.wal, terminal: future.terminal),
            reservationDirectory: reservationDirectory, evidenceDirectory: evidenceDirectory,
            transactionDirectory: transactionNamespace, stateDirectory: stateDirectory, direct: direct)
        let ledger = try quotaLedger(reservationID: reservation.id)
        _ = try await ledger.prepareCapacity(capacities)
        if failurePoint == .quotaPrepareAfterLedger {
            throw ApplyChangeSetSimulatedCrash(point: .quotaPrepareAfterLedger)
        }
        return ledger
        } catch {
            // prepareCapacity成功後にはthrow点がない。ここへ来るのはquota ownership確立前だけなので、
            // live descriptorを残して同一process scannerを永久skipさせない。ledgerがdurableなら
            // lease manifestはscannerの回収rootなので保持し、ledger未作成時だけleaseを消す。
            unlockQuotaLease(reservation.id)
            let ledgerURL = reservationDirectory.appendingPathComponent("quota-\(reservation.id).json")
            if !FileManager.default.fileExists(atPath: ledgerURL.path) {
                try? Self.durableUnlink(reservationDirectory.appendingPathComponent(".aishell-quota-\(reservation.id).lease"))
            }
            throw error
        }
    }

    private func releaseQuota(request: ApplyChangeSetRequest, reservationID: String) async throws {
        let simulateUnlinkIntentCrash = await faults.consumeCrash(at: .evidenceUnlinkIntentAfter)
        let ledger = try quotaLedger(reservationID: reservationID,
            lifecycleFailurePoint: simulateUnlinkIntentCrash ? .releaseUnlinkIntentPersisted : nil)
        let digest = Self.requestDigest(request)
        for material in try await ledger.materialViews() where material.state == .materialized && material.kind == .evidenceData {
            guard let final = material.plannedFinalURL else { throw ApplyChangeSetError(.changeSetStoreCorrupt) }
            let metadata = final.deletingPathExtension().appendingPathExtension("json")
            guard !FileManager.default.fileExists(atPath: metadata.path) else { continue }
            let key: String
            switch material.id {
            case "diff_data": key = "diff-data:\(digest)"
            case "abort_diff_data": key = "abort-diff-data:\(digest)"
            default: throw ApplyChangeSetError(.changeSetStoreCorrupt, "unknown evidence data quota material")
            }
            do {
                try await ledger.releaseAndUnlinkMaterial(materialID: material.id, idempotencyKey: key)
            } catch is ChangeSetQuotaLedger.SimulatedLifecycleCrash {
                throw ApplyChangeSetSimulatedCrash(point: .evidenceUnlinkIntentAfter)
            }
        }
        let view = try await ledger.currentView()
        var materials: [(String, String)] = [
            ("canonical", "canonical:\(digest)"),
            ("manifest", "manifest:\(digest)"),
            ("diff_data", "diff-data:\(digest)"),
            ("diff_metadata", "diff-metadata:\(digest)"),
            ("diff_metadata_final", "diff-metadata-final:\(digest)"),
            ("abort_diff_data", "abort-diff-data:\(digest)"),
            ("abort_diff_metadata", "abort-diff-metadata:\(digest)"),
            ("abort_diff_metadata_final", "abort-diff-metadata-final:\(digest)"),
        ]
        var stageIndex = 0, trashIndex = 0
        for change in request.changes {
            switch change {
            case .create, .write, .rename:
                materials.append(("stage_\(stageIndex)", "stage:\(stageIndex):\(digest)")); stageIndex += 1
            case .delete:
                materials.append(("trash_\(trashIndex)", "trash:\(trashIndex):\(digest)")); trashIndex += 1
            }
        }
        for (id, key) in materials where view.materializedMaterialIDs.contains(id) {
            try await ledger.releaseMaterial(materialID: id, idempotencyKey: key)
        }
        for material in try await ledger.materialViews() where material.state == .materialized {
            let pieces = material.id.split(separator: "_")
            guard let suffix = pieces.last, Int(suffix) != nil else { continue }
            let keyPrefix = pieces.dropLast().joined(separator: "_")
            try await ledger.releaseMaterial(materialID: material.id,
                idempotencyKey: "\(keyPrefix):\(suffix):\(digest)")
        }
        unlockQuotaLease(reservationID)
    }

    private func releaseConsumedStageMaterials(request: ApplyChangeSetRequest, reservationID: String) async throws {
        let ledger = try quotaLedger(reservationID: reservationID)
        let view = try await ledger.currentView()
        let digest = Self.requestDigest(request)
        var index = 0
        for change in request.changes {
            switch change {
            case .create, .write, .rename:
                let id = "stage_\(index)"
                if view.materializedMaterialIDs.contains(id) {
                    try await ledger.releaseMaterial(materialID: id, idempotencyKey: "stage:\(index):\(digest)")
                }
                index += 1
            case .delete:
                break
            }
        }
    }

    public static func production(
        runtimeStore: RuntimeStore,
        root: URL,
        stateDirectory: URL,
        workspaceRuntime: WorkspaceStateRuntime
    ) async throws -> ApplyChangeSetService {
        let evidenceStore = EvidenceStore(baseDirectory: stateDirectory.appendingPathComponent("evidence", isDirectory: true))
        let legacyDirectory = runtimeStore.baseDirectory.appendingPathComponent("apply-change-set", isDirectory: true)
            .appendingPathComponent(root.path.applyStringSHA256, isDirectory: true)
        let stateStore = try ApplyChangeSetStateStore(baseDirectory: stateDirectory, stateDirectory: stateDirectory,
            root: root, legacyStateDirectory: legacyDirectory)
        let service = try ApplyChangeSetService(runtimeStore: runtimeStore, stateDirectory: stateDirectory,
            evidenceStore: evidenceStore, stateStore: stateStore, workspaceRuntime: workspaceRuntime,
            failureInjector: ApplyChangeSetFailureInjector(), clock: ApplyChangeSetTestClock())
        try await service.bootstrap(root: root)
        _ = try await service.recover(root: root)
        return service
    }

    public func bootstrap(root: URL) async throws {
        try await withOperationGate { try await bootstrapUnlocked(root: root) }
    }

    private func bootstrapUnlocked(root: URL) async throws {
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical.path == state.root.standardizedFileURL.resolvingSymlinksInPath().path else { throw ApplyChangeSetError(.rootMismatch) }
        try await state.repairPendingJournals()
        let ns = root.appendingPathComponent(".aishell-transactions", isDirectory: true)
        let marker = ns.appendingPathComponent("marker.json")
        var rootInfo = stat()
        guard lstat(canonical.path, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR else { throw ApplyChangeSetError(.rootMismatch) }
        let rootDevice = String(rootInfo.st_dev), rootInode = String(rootInfo.st_ino)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: ns.path, isDirectory: &isDir) {
            let attrs = try FileManager.default.attributesOfItem(atPath: ns.path)
            guard isDir.boolValue, attrs[.type] as? FileAttributeType == .typeDirectory,
                  let perms = attrs[.posixPermissions] as? NSNumber, perms.intValue & 0o077 == 0,
                  let data = try? Data(contentsOf: marker),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  object["schema"] == "aishell.apply-change-set-namespace.v1", object["root"] == canonical.path,
                  object["generation"] == state.generation, object["root_device"] == rootDevice,
                  object["root_inode"] == rootInode else {
                throw ApplyChangeSetError(.reservedNamespaceConflict)
            }
            try await reconcilePreparedQuotaOrphans()
            try await ensureDedicatedStoreCutover()
            return
        }
        try FileManager.default.createDirectory(at: ns, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: ["schema": "aishell.apply-change-set-namespace.v1", "root": canonical.path, "generation": state.generation, "root_device": rootDevice, "root_inode": rootInode, "nonce": UUID().uuidString.lowercased()], options: [.sortedKeys])
        try data.write(to: marker, options: [.atomic])
        try await state.persist()
        try await ensureDedicatedStoreCutover()
    }

    private func ensureDedicatedStoreCutover() async throws {
        let now = await clock.now()
        registryClock.set(now)
        if dedicatedStoresBootstrapped {
            try await reconcileDedicatedStoreIntents()
            _ = try await cutoverCoordinator.validateForPublication(at: now)
            return
        }
        if case .complete = try await cutoverCoordinator.status() {
            try await reconcileDedicatedStoreIntents()
            _ = try await cutoverCoordinator.validateForPublication(at: now)
            try await activateDedicatedStateCache()
            dedicatedStoresBootstrapped = true
            return
        }
        try await finishLegacyRolledBackTransactionsBeforeCutover()
        let cutoverTime = try await cutoverCoordinator.preparationDate() ?? now
        let legacy = try await state.legacyDedicatedStoreExport(cutoverTime: cutoverTime)
        let compat = LegacyControlCompatSnapshot(sourceDigest: legacy.sourceDigest,
            receipts: legacy.controlReceipts.mapValues {
                .init(expiresAt: $0.expiresAt, requestDigest: $0.requestDigest, result: $0.result)
            })
        await cutoverCompatibility.configure(sourceDigest: legacy.sourceDigest, snapshot: compat)
        let source = ChangeSetCutoverLegacySnapshot(sourceDigest: legacy.sourceDigest,
            preparedAt: cutoverTime, cursorBinding: legacy.cursorBinding, registry: legacy.registry,
            transactions: legacy.transactions, runtimeReceipts: legacy.runtimeReceipts)
        let status = try await cutoverCoordinator.run(source)
        guard status.permitsDedicatedStorePublication else {
            throw ApplyChangeSetError(.changeSetRecoveryRequired,
                "cross-store cutover has not reached its authenticated completion marker")
        }
        _ = try await cutoverCoordinator.validateForPublication(at: now)
        try await activateDedicatedStateCache()
        dedicatedStoresBootstrapped = true
    }

    /// `rolledBack` is a recovery checkpoint, not a publishable durable terminal state.
    /// Complete its existing abort path against the legacy state before the one-shot export;
    /// a failure leaves the checkpoint intact so the next startup resumes the same work.
    private func finishLegacyRolledBackTransactionsBeforeCutover() async throws {
        for item in await state.legacyTransactionsRequiringCutoverRecovery() {
            let request = try await state.materializedRequest(item.id)
            try Self.verifyManifestDigest(root: state.root, transaction: item.id,
                expected: await state.manifestDigest(item.id))
            let result: ApplyChangeSetResult
            if item.state == .rolledBack {
                result = try await abortedResult(request, transaction: item.id)
                await state.finish(request: request, result: result, transaction: item.id,
                    stateValue: .abortedBeforeSideEffect)
                try await state.requirePersistenceHealthy()
            } else {
                guard let terminalResult = item.pendingResult else {
                    throw ApplyChangeSetError(.changeSetStoreCorrupt,
                        "legacy terminal transaction has no durable result")
                }
                result = terminalResult
            }
            guard let reservationID = item.reservationID else {
                throw ApplyChangeSetError(.changeSetStoreCorrupt,
                    "rolled-back legacy transaction has no reservation")
            }
            let replacementCrash: ApplyChangeSetFailurePoint? = await faults.consumeCrash(
                at: .evidenceMetadataReplacementRenameAfter)
                ? .evidenceMetadataReplacementRenameAfter : nil
            try await finalizeTerminalEvidence(result, request: request, reservationID: reservationID,
                simulateReplacementCrash: replacementCrash)
            await state.releaseTerminalMaterial(item.id, request: request)
            try await state.requirePersistenceHealthy()
            try await releaseQuota(request: request, reservationID: reservationID)
            try Self.cleanupTerminalTransactionDirectory(root: state.root, transaction: item.id)
        }
    }

    private func activateDedicatedStateCache() async throws {
        let registrySnapshot = await clientRegistry.snapshot()
        let replay = await clientRegistry.replayReferences()
        let references = try await transactionStore.listReferences(now: await clock.now())
        var transactions: [StoredTransaction] = []
        for reference in references {
            guard let snapshot = try await transactionStore.load(reference.transactionID) else {
                throw ApplyChangeSetError(.changeSetStoreCorrupt)
            }
            let transaction = try JSONDecoder().decode(StoredTransaction.self, from: snapshot.payload)
            guard transaction.id == snapshot.transactionID, transaction.state == snapshot.state else {
                throw ApplyChangeSetError(.changeSetStoreCorrupt,
                    "dedicated transaction payload cannot hydrate core state")
            }
            transactions.append(transaction)
        }
        try await state.activateDedicatedStoreMode(registrySlots: registrySnapshot.slots,
            replayReferences: replay, transactionValues: transactions,
            runtimeReceipts: try await transactionStore.runtimeReceipts())
    }

    public func migrateNamespace(root: URL) async throws {
        try await withOperationGate { await state.setLegacyMigrated() }
    }

    public func currentCursor(root: URL) async throws -> ApplyChangeSetCursor {
        try await withOperationGate { try await currentCursorUnlocked(root: root) }
    }

    private func currentCursorUnlocked(root: URL) async throws -> ApplyChangeSetCursor {
        try await ensureDedicatedStoreCutover()
        try await state.repairPendingJournals()
        guard !(await state.isRecoveryActive()), try await transactionStore.listActive().isEmpty else {
            throw ApplyChangeSetError(.changeSetRecoveryRequired)
        }
        guard root.standardizedFileURL.path == state.root.standardizedFileURL.path else { throw ApplyChangeSetError(.rootMismatch) }
        return await state.cursor()
    }

    private func syncDedicatedTransaction(_ id: ApplyChangeSetTransactionID) async throws {
        guard let desired = try await state.dedicatedTransactionSnapshot(id) else { return }
        var current = try await transactionStore.load(id)
        if current == nil {
            let preparing = ChangeSetTransactionStore.Snapshot(transactionID: id, state: .preparing,
                manifestDigest: desired.manifestDigest, references: desired.references,
                payload: desired.payload)
            try await transactionStore.persistTransition(preparing)
            current = try await transactionStore.load(id)
        }
        guard var current else { throw ApplyChangeSetError(.changeSetStoreCorrupt) }
        if current.state == desired.state {
            if current.payload != desired.payload || current.references != desired.references
                || current.manifestDigest != desired.manifestDigest
                || current.terminalAt != desired.terminalAt
                || current.retentionExpiresAt != desired.retentionExpiresAt {
                _ = try await transactionStore.updateSnapshot(transactionID: id,
                    expectedState: current.state, expectedRevision: current.revision,
                    payload: desired.payload, references: desired.references,
                    manifestDigest: desired.manifestDigest, terminalAt: desired.terminalAt,
                    retentionExpiresAt: desired.retentionExpiresAt)
            }
            return
        }
        let route = Self.transactionRoute(from: current.state, to: desired.state)
        guard route.count == 1 else {
            throw ApplyChangeSetError(.changeSetStoreCorrupt,
                "service mutation skipped a dedicated transaction transition")
        }
        for nextState in route {
            let terminal = nextState == desired.state
            let next = ChangeSetTransactionStore.Snapshot(transactionID: id, state: nextState,
                manifestDigest: desired.manifestDigest, references: desired.references,
                payload: desired.payload, terminalAt: terminal ? desired.terminalAt : nil,
                retentionExpiresAt: terminal ? desired.retentionExpiresAt : nil,
                revision: current.revision + 1)
            try await transactionStore.persistTransition(next, expectedState: current.state)
            guard let loaded = try await transactionStore.load(id) else {
                throw ApplyChangeSetError(.changeSetStoreCorrupt)
            }
            current = loaded
        }
    }

    private func dedicatedTransactions(activeOnly: Bool = false) async throws -> [StoredTransaction] {
        let snapshots: [ChangeSetTransactionStore.Snapshot]
        if activeOnly { snapshots = try await transactionStore.listActive() }
        else {
            let references = try await transactionStore.listReferences(now: await clock.now())
            var loaded: [ChangeSetTransactionStore.Snapshot] = []
            for reference in references {
                if let snapshot = try await transactionStore.load(reference.transactionID) {
                    loaded.append(snapshot)
                }
            }
            snapshots = loaded
        }
        return try snapshots.map { snapshot in
            let transaction = try JSONDecoder().decode(StoredTransaction.self, from: snapshot.payload)
            guard transaction.id == snapshot.transactionID, transaction.state == snapshot.state else {
                throw ApplyChangeSetError(.changeSetStoreCorrupt,
                    "transaction payload metadata differs from its dedicated snapshot")
            }
            return transaction
        }
    }

    private static func transactionRoute(from: ApplyChangeSetTransactionState,
        to: ApplyChangeSetTransactionState) -> [ApplyChangeSetTransactionState] {
        if from == to { return [] }
        let edges: [ApplyChangeSetTransactionState: [ApplyChangeSetTransactionState]] = [
            .preparing: [.prepared, .rollbackDecided, .abortedBeforeSideEffect, .recoveryRequired],
            .prepared: [.commitDecided, .rollbackDecided, .abortedBeforeSideEffect, .recoveryRequired],
            .commitDecided: [.filesystemCommitted, .recoveryRequired],
            .filesystemCommitted: [.runtimeCommitted, .recoveryRequired],
            .runtimeCommitted: [.trashCommitted, .recoveryRequired],
            .trashCommitted: [.finalized, .committed, .recoveryRequired],
            .finalized: [.committed],
            .rollbackDecided: [.rolledBack, .recoveryRequired],
            .rolledBack: [.abortedBeforeSideEffect],
            .recoveryRequired: [.rollbackDecided, .filesystemCommitted, .runtimeCommitted,
                .trashCommitted, .finalized],
        ]
        var queue: [(ApplyChangeSetTransactionState, [ApplyChangeSetTransactionState])] = [(from, [])]
        var seen: Set<ApplyChangeSetTransactionState> = [from]
        while !queue.isEmpty {
            let (value, path) = queue.removeFirst()
            for next in edges[value] ?? [] where seen.insert(next).inserted {
                let candidate = path + [next]
                if next == to { return candidate }
                queue.append((next, candidate))
            }
        }
        return []
    }

    private func admitDedicated(_ request: ApplyChangeSetRequest, reservationID: String,
        transaction: ApplyChangeSetTransactionID,
        crash: ApplyChangeSetFailurePoint? = nil) async throws {
        let digest = Self.requestDigest(request)
        let preparing = StoredTransaction(id: transaction, request: request, state: .preparing,
            corrupt: false, materialExists: true, retention: .pinned, admitted: true,
            targetReceipts: 0, reservationID: reservationID)
        let preparingSnapshot = ChangeSetTransactionStore.Snapshot(transactionID: transaction,
            state: .preparing, manifestDigest: String(repeating: "0", count: 64),
            references: [
                .init(kind: "request", identifier: transaction.rawValue,
                    digest: digest),
                .init(kind: "reservation", identifier: reservationID,
                    digest: digest),
                .init(kind: "registry_admission_intent", identifier: transaction.rawValue,
                    digest: digest),
            ],
            payload: try JSONEncoder.sorted.encode(preparing))
        if let existing = try await transactionStore.load(transaction) {
            guard existing.state == .preparing else {
                throw ApplyChangeSetError(.changeSetStoreCorrupt,
                    "admission intent found a non-preparing transaction")
            }
            if existing.payload != preparingSnapshot.payload
                || existing.references != preparingSnapshot.references {
                _ = try await transactionStore.updateSnapshot(transactionID: transaction,
                    expectedState: existing.state, expectedRevision: existing.revision,
                    payload: preparingSnapshot.payload, references: preparingSnapshot.references,
                    manifestDigest: preparingSnapshot.manifestDigest,
                    terminalAt: nil, retentionExpiresAt: nil)
            }
        } else {
            try await transactionStore.persistTransition(preparingSnapshot)
        }
        if crash == .dedicatedAdmissionIntentAfter {
            throw ApplyChangeSetSimulatedCrash(point: .dedicatedAdmissionIntentAfter)
        }
        try await reconcileDedicatedStoreIntents(transactionID: transaction,
            crashAfterRegistry: crash == .dedicatedAdmissionRegistryAfter
                ? .dedicatedAdmissionRegistryAfter : nil)
    }

    private func finishDedicated(_ request: ApplyChangeSetRequest, result: ApplyChangeSetResult,
        transaction: ApplyChangeSetTransactionID,
        crash: ApplyChangeSetFailurePoint? = nil) async throws {
        guard result.diffArtifact.expiresAt != nil else {
            throw ApplyChangeSetError(.changeSetStoreCorrupt,
                "terminal result has no retention expiry")
        }
        try await addDedicatedStoreIntent(transactionID: transaction,
            kind: "registry_terminal_intent",
            digest: try JSONEncoder.sorted.encode(result).applySHA256,
            request: request, result: result)
        if crash == .dedicatedTerminalIntentAfter {
            throw ApplyChangeSetSimulatedCrash(point: .dedicatedTerminalIntentAfter)
        }
        try await reconcileDedicatedStoreIntents(transactionID: transaction,
            crashAfterTransaction: crash == .dedicatedTerminalTransactionAfter,
            crashAfterRegistry: crash == .dedicatedTerminalRegistryAfter
                ? .dedicatedTerminalRegistryAfter : nil)
    }

    private func addDedicatedStoreIntent(transactionID: ApplyChangeSetTransactionID,
        kind: String, digest: String, request: ApplyChangeSetRequest? = nil,
        result: ApplyChangeSetResult? = nil) async throws {
        guard let snapshot = try await transactionStore.load(transactionID) else {
            throw ApplyChangeSetError(.changeSetStoreCorrupt, "cross-store intent transaction is missing")
        }
        if let existing = snapshot.references.first(where: { $0.kind == kind }) {
            guard existing.identifier == transactionID.rawValue, existing.digest == digest else {
                throw ApplyChangeSetError(.changeSetStoreCorrupt, "cross-store intent conflicts")
            }
            return
        }
        var payload = snapshot.payload
        if request != nil || result != nil {
            var transaction = try JSONDecoder().decode(StoredTransaction.self, from: snapshot.payload)
            if let request { transaction.request = request }
            if let result { transaction.pendingResult = result }
            payload = try JSONEncoder.sorted.encode(transaction)
        }
        _ = try await transactionStore.updateSnapshot(transactionID: transactionID,
            expectedState: snapshot.state, expectedRevision: snapshot.revision,
            payload: payload,
            references: snapshot.references + [.init(kind: kind,
                identifier: transactionID.rawValue, digest: digest)],
            manifestDigest: snapshot.manifestDigest, terminalAt: snapshot.terminalAt,
            retentionExpiresAt: snapshot.retentionExpiresAt)
    }

    private func clearDedicatedStoreIntent(_ snapshot: ChangeSetTransactionStore.Snapshot,
        kind: String) async throws {
        let references = snapshot.references.filter { $0.kind != kind }
        guard references.count != snapshot.references.count else { return }
        _ = try await transactionStore.updateSnapshot(transactionID: snapshot.transactionID,
            expectedState: snapshot.state, expectedRevision: snapshot.revision,
            payload: snapshot.payload, references: references,
            manifestDigest: snapshot.manifestDigest, terminalAt: snapshot.terminalAt,
            retentionExpiresAt: snapshot.retentionExpiresAt)
    }

    private func reconcileDedicatedStoreIntents(
        transactionID: ApplyChangeSetTransactionID? = nil,
        crashAfterTransaction: Bool = false,
        crashAfterRegistry: ApplyChangeSetFailurePoint? = nil
    ) async throws {
        let candidates: [ChangeSetTransactionStore.Snapshot]
        if let transactionID {
            candidates = try await transactionStore.load(transactionID).map { [$0] } ?? []
        } else {
            var loaded: [ChangeSetTransactionStore.Snapshot] = []
            for reference in try await transactionStore.listReferences(now: await clock.now()) {
                if let snapshot = try await transactionStore.load(reference.transactionID) {
                    loaded.append(snapshot)
                }
            }
            candidates = loaded
        }
        for initialCandidate in candidates {
            var candidate = initialCandidate
            let admission = candidate.references.first { $0.kind == "registry_admission_intent" }
            let terminal = candidate.references.first { $0.kind == "registry_terminal_intent" }
            guard admission != nil || terminal != nil else { continue }
            guard !(admission != nil && terminal != nil) else {
                throw ApplyChangeSetError(.changeSetStoreCorrupt, "cross-store intents overlap")
            }
            var transaction: StoredTransaction
            do { transaction = try JSONDecoder().decode(StoredTransaction.self, from: candidate.payload) }
            catch {
                throw ApplyChangeSetError(.changeSetStoreCorrupt,
                    "cross-store intent payload cannot be decoded: \(error)")
            }
            guard transaction.id == candidate.transactionID,
                  transaction.state == candidate.state else {
                throw ApplyChangeSetError(.changeSetStoreCorrupt,
                    "cross-store intent transaction binding is invalid")
            }
            guard let request = transaction.request else {
                throw ApplyChangeSetError(.changeSetStoreCorrupt,
                    "cross-store intent request is missing (state=\(candidate.state.rawValue), admission=\(admission != nil), terminal=\(terminal != nil))")
            }
            let requestDigest = Self.requestDigest(request)
            let matches = await clientRegistry.replayReferences().filter {
                $0.clientID == request.clientID && $0.epoch == UInt64(request.clientEpoch)
                    && $0.sequence == UInt64(request.requestSequence)
            }
            guard matches.count <= 1 else {
                throw ApplyChangeSetError(.changeSetStoreCorrupt, "cross-store replay identity is duplicated")
            }
            if admission != nil {
                guard admission?.identifier == candidate.transactionID.rawValue,
                      admission?.digest == requestDigest else {
                    throw ApplyChangeSetError(.changeSetStoreCorrupt, "admission intent binding is invalid")
                }
                if let replay = matches.first {
                    guard replay.requestDigest == requestDigest,
                          replay.transactionID == candidate.transactionID.rawValue,
                          replay.state == .pending else {
                        throw ApplyChangeSetError(.changeSetStoreCorrupt,
                            "admission intent conflicts with registry replay")
                    }
                } else {
                    let generation = await clientRegistry.snapshot().generation
                    do {
                        _ = try await clientRegistry.admit(clientID: request.clientID,
                            epoch: UInt64(request.clientEpoch), sequence: UInt64(request.requestSequence),
                            requestDigest: requestDigest, transactionID: candidate.transactionID.rawValue,
                            expectedRegistryGeneration: generation)
                    } catch let error as ChangeSetClientRegistryError {
                        throw Self.mapRegistryError(error)
                    }
                }
                if crashAfterRegistry == .dedicatedAdmissionRegistryAfter {
                    throw ApplyChangeSetSimulatedCrash(point: .dedicatedAdmissionRegistryAfter)
                }
                guard let refreshed = try await transactionStore.load(candidate.transactionID) else {
                    throw ApplyChangeSetError(.changeSetStoreCorrupt)
                }
                try await clearDedicatedStoreIntent(refreshed, kind: "registry_admission_intent")
                continue
            }
            guard let result = transaction.pendingResult,
                  let expiry = result.diffArtifact.expiresAt,
                  terminal?.identifier == candidate.transactionID.rawValue,
                  terminal?.digest == (try JSONEncoder.sorted.encode(result).applySHA256) else {
                throw ApplyChangeSetError(.changeSetStoreCorrupt, "terminal intent binding is invalid")
            }
            let replayState: ChangeSetReplayState = switch result.status {
            case .committed: .committed
            case .abortedBeforeSideEffect: .abortedBeforeSideEffect
            case .recoveryRequired: .recoveryRequired
            }
            let responseDigest = try JSONEncoder.sorted.encode(result).applySHA256
            guard result.status != .recoveryRequired else {
                throw ApplyChangeSetError(.changeSetStoreCorrupt,
                    "terminal intent cannot publish a recovery-required result")
            }
            var canonicalTerminalAt = expiry.addingTimeInterval(
                -TimeInterval(request.retentionSeconds))
            if result.status == .committed {
                let receiptDigest = try JSONEncoder.sorted.encode([
                    result.cursor.root, result.cursor.generation, String(result.cursor.sequence)
                ] + result.changedPaths).applySHA256
                if let existing = try await transactionStore.runtimeReceipts().first(where: {
                    $0.transactionID == candidate.transactionID
                }) {
                    guard existing.cursor == result.cursor, existing.paths == result.changedPaths,
                          existing.digest == receiptDigest, let terminalAt = existing.terminalAt,
                          terminalAt.addingTimeInterval(TimeInterval(request.retentionSeconds)) == expiry else {
                        throw ApplyChangeSetError(.changeSetStoreCorrupt,
                            "terminal intent conflicts with durable runtime receipt")
                    }
                    canonicalTerminalAt = terminalAt
                }
            }
            let terminalState: ApplyChangeSetTransactionState = result.status == .committed
                ? .finalized : .abortedBeforeSideEffect
            if candidate.state != terminalState {
                let route = Self.transactionRoute(from: candidate.state, to: terminalState)
                guard !route.isEmpty else {
                    throw ApplyChangeSetError(.changeSetStoreCorrupt,
                        "terminal intent has no legal transaction route")
                }
                for nextState in route {
                    transaction.state = nextState
                    transaction.request = request
                    transaction.pendingResult = result
                    var references = candidate.references.filter {
                        $0.kind != "artifact" && $0.kind != "terminal_response"
                    }
                    if !references.contains(where: { $0.kind == "request" }) {
                        references.append(.init(kind: "request",
                            identifier: candidate.transactionID.rawValue, digest: requestDigest))
                    }
                    let isTerminal = nextState == terminalState
                    if isTerminal {
                        references.append(.init(kind: "artifact",
                            identifier: result.diffArtifact.handle,
                            digest: result.diffArtifact.sha256))
                        references.append(.init(kind: "terminal_response",
                            identifier: candidate.transactionID.rawValue,
                            digest: responseDigest))
                    }
                    let next = ChangeSetTransactionStore.Snapshot(
                        transactionID: candidate.transactionID, state: nextState,
                        manifestDigest: candidate.manifestDigest, references: references,
                        payload: try JSONEncoder.sorted.encode(transaction),
                        terminalAt: isTerminal ? canonicalTerminalAt : nil,
                        retentionExpiresAt: isTerminal ? expiry : nil,
                        revision: candidate.revision + 1)
                    try await transactionStore.persistTransition(next,
                        expectedState: candidate.state)
                    guard let loaded = try await transactionStore.load(candidate.transactionID) else {
                        throw ApplyChangeSetError(.changeSetStoreCorrupt)
                    }
                    candidate = loaded
                }
            }
            if crashAfterTransaction {
                throw ApplyChangeSetSimulatedCrash(point: .dedicatedTerminalTransactionAfter)
            }
            if result.status == .committed,
               !(try await transactionStore.runtimeReceipts().contains(where: {
                   $0.transactionID == candidate.transactionID
               })) {
                let receiptDigest = try JSONEncoder.sorted.encode([
                    result.cursor.root, result.cursor.generation, String(result.cursor.sequence)
                ] + result.changedPaths).applySHA256
                try await transactionStore.appendRuntimeReceipt(.init(
                    transactionID: candidate.transactionID, cursor: result.cursor,
                    paths: result.changedPaths, digest: receiptDigest,
                    recordedAt: canonicalTerminalAt, terminalAt: canonicalTerminalAt))
            }
            if let replay = matches.first, replay.state.isTerminal {
                guard replay.requestDigest == requestDigest,
                      replay.transactionID == candidate.transactionID.rawValue,
                      replay.state == replayState,
                      replay.terminalResponseDigest == responseDigest,
                      replay.artifactHandle == result.diffArtifact.handle,
                      replay.artifactExpiresAt == expiry,
                      replay.retentionExpiresAt == expiry else {
                    throw ApplyChangeSetError(.changeSetStoreCorrupt,
                        "terminal intent conflicts with registry replay")
                }
            } else {
                guard let replay = matches.first, replay.requestDigest == requestDigest,
                      replay.transactionID == candidate.transactionID.rawValue,
                      replay.state == .pending else {
                    throw ApplyChangeSetError(.changeSetStoreCorrupt,
                        "terminal intent has no exact pending registry replay")
                }
                let generation = await clientRegistry.snapshot().generation
                do {
                    _ = try await clientRegistry.reconcileTerminalIntent(clientID: request.clientID,
                        epoch: UInt64(request.clientEpoch), sequence: UInt64(request.requestSequence),
                        state: replayState, terminalResponseDigest: responseDigest,
                        artifact: .init(handle: result.diffArtifact.handle, expiresAt: expiry),
                        retentionExpiresAt: expiry, expectedRegistryGeneration: generation)
                } catch let error as ChangeSetClientRegistryError {
                    throw Self.mapRegistryError(error)
                }
            }
            if crashAfterRegistry == .dedicatedTerminalRegistryAfter {
                throw ApplyChangeSetSimulatedCrash(point: .dedicatedTerminalRegistryAfter)
            }
            guard let refreshed = try await transactionStore.load(candidate.transactionID) else {
                throw ApplyChangeSetError(.changeSetStoreCorrupt)
            }
            try await clearDedicatedStoreIntent(refreshed, kind: "registry_terminal_intent")
        }
    }

    @discardableResult
    private func recordDedicatedRuntimeCommit(transaction: ApplyChangeSetTransactionID,
        cursor: ApplyChangeSetCursor, paths: [String]) async throws -> Date {
        let committedAt = await clock.now()
        let digest = try JSONEncoder.sorted.encode([
            cursor.root, cursor.generation, String(cursor.sequence)
        ] + paths).applySHA256
        try await transactionStore.appendRuntimeReceipt(.init(transactionID: transaction,
            cursor: cursor, paths: paths, digest: digest, recordedAt: committedAt,
            terminalAt: committedAt))
        return committedAt
    }

    public func apply(_ request: ApplyChangeSetRequest) async throws -> ApplyChangeSetResult {
        try await withOperationGate { try await applyUnlocked(request) }
    }

    public func applyManaged(
        root: URL,
        workspaceCursor: String,
        changes: [ApplyChangeSetChange],
        diffByteBudget: Int,
        retentionSeconds: Int
    ) async throws -> ManagedApplyChangeSetResult {
        try await withOperationGate {
            let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
            guard canonicalRoot.path == state.root.standardizedFileURL.resolvingSymlinksInPath().path else {
                throw ApplyChangeSetError(.rootMismatch)
            }
            let observed = try await workspaceRuntime.snapshot(
                path: canonicalRoot.path,
                sinceCursor: workspaceCursor
            )
            guard observed.changes.isEmpty else {
                throw ApplyChangeSetError(.workspaceChanged)
            }
            try await ensureDedicatedStoreCutover()
            var registry = await clientRegistry.snapshot()
            var slot = registry.slots
                .filter { $0.allocationState == .active }
                .min { $0.number < $1.number }
            if slot == nil {
                let controlRequestID = UUID().uuidString.lowercased()
                let now = await clock.now()
                registryClock.set(now)
                let requestDigest = Data("managed-mcp-client:\(controlRequestID)".utf8).applySHA256
                do {
                    _ = try await clientRegistry.allocate(
                        controlRequestID: controlRequestID,
                        requestDigest: requestDigest,
                        expiresAt: now.addingTimeInterval(300),
                        expectedRegistryGeneration: registry.generation
                    )
                } catch let error as ChangeSetClientRegistryError {
                    throw Self.mapRegistryError(error)
                }
                registry = await clientRegistry.snapshot()
                slot = registry.slots
                    .filter { $0.allocationState == .active }
                    .min { $0.number < $1.number }
            }
            guard let slot else {
                throw ApplyChangeSetError(.changeSetClientCapacityExceeded)
            }
            let request = ApplyChangeSetRequest(
                clientID: slot.clientID,
                clientEpoch: Int(slot.currentEpoch),
                requestSequence: Int(slot.highWater + 1),
                cursor: try await currentCursorUnlocked(root: canonicalRoot),
                changes: changes,
                diffByteBudget: diffByteBudget,
                retentionSeconds: retentionSeconds
            )
            let result = try await applyUnlocked(request)
            let after = try await workspaceRuntime.snapshot(
                path: canonicalRoot.path,
                sinceCursor: workspaceCursor
            )
            return ManagedApplyChangeSetResult(
                transaction: result,
                workspaceFromCursor: workspaceCursor,
                workspaceCursor: after.cursor
            )
        }
    }

    private func applyUnlocked(_ request: ApplyChangeSetRequest) async throws -> ApplyChangeSetResult {
        try await ensureDedicatedStoreCutover()
        try await state.repairPendingJournals()
        guard !(await state.isRecoveryActive()) else { throw ApplyChangeSetError(.changeSetPreviousPending) }
        try await reconcilePreparedQuotaOrphans()
        try await reconcileTerminalEvidence()
        let activeTransactions = try await dedicatedTransactions(activeOnly: true)
        if !activeTransactions.isEmpty {
            if let reservationID = activeTransactions.first?.reservationID {
                _ = try await quotaLedger(reservationID: reservationID).reconcile()
            }
            _ = try await recoverUnlocked(root: state.root)
        }
        switch try await state.pendingDisposition(for: request) {
        case .none: break
        case .sameTransaction:
            _ = try await recoverUnlocked(root: state.root)
            do { try await validateIdentityAndReplay(request) } catch let replay as ReplayResult { return replay.result }
            throw ApplyChangeSetError(.changeSetStoreCorrupt, "recovered transaction has no terminal replay")
        case .conflict: throw ApplyChangeSetError(.changeSetSequenceConflict)
        case .otherTransaction: throw ApplyChangeSetError(.changeSetRecoveryRequired)
        }
        do { try await validateIdentityAndReplay(request) } catch let replay as ReplayResult { return replay.result }
        try await validateRequest(request)

        let race = await faults.consumeRace()

        let transaction = ApplyChangeSetTransactionID(request.transactionIdentity)
        let crash = await faults.consumeCrash()
        if crash == .reservationFSyncBefore {
            throw ApplyChangeSetSimulatedCrash(point: crash!)
        }
        let reservationID: String
        if let existing = try await state.unadmittedReservation(for: request) {
            reservationID = existing
            try acquireQuotaLease(reservationID: existing, requestDigest: Self.requestDigest(request))
            _ = try await quotaLedger(reservationID: existing).reconcile()
        } else {
            let reservation = ApplyChangeSetReservation(id: UUID().uuidString.lowercased(), requestDigest: Self.requestDigest(request), request: request)
            let ledger = try await prepareQuota(reservation, failurePoint: crash)
            if crash == .quotaPreparedBeforeBinding {
                unlockQuotaLease(reservation.id)
                throw ApplyChangeSetSimulatedCrash(point: .quotaPreparedBeforeBinding)
            }
            do {
                try await state.storeReservation(reservation, ledger: ledger,
                    simulateCanonicalRenameCrash: crash == .quotaCanonicalRenameAfter)
            } catch let simulated as ApplyChangeSetSimulatedCrash {
                unlockQuotaLease(reservation.id)
                throw simulated
            }
            try await state.requirePersistenceHealthy()
            if crash == .reservationFSyncAfter {
                unlockQuotaLease(reservation.id)
                throw ApplyChangeSetSimulatedCrash(point: crash!)
            }
            reservationID = reservation.id
        }
        try await admitDedicated(request, reservationID: reservationID, transaction: transaction,
            crash: crash)
        await state.admit(request: request, reservationID: reservationID, transaction: transaction)
        try await state.requirePersistenceHealthy()
        try await syncDedicatedTransaction(transaction)
        if crash == .admissionFSyncAfter || crash == .materializationBefore { throw ApplyChangeSetSimulatedCrash(point: crash!) }

        let admittedRequest: ApplyChangeSetRequest
        do { admittedRequest = try await state.materializedRequest(transaction) }
        catch let error as ApplyChangeSetError { throw error.attachingTransaction(transaction, request: request, changedPaths: []) }
        if let mutation = await faults.consumeMutation() {
            if mutation.boundary == .beforeFirstTargetReceipt {
                let result = try await abortedResult(admittedRequest, transaction: transaction)
                await state.finish(request: admittedRequest, result: result, transaction: transaction, stateValue: .abortedBeforeSideEffect)
                try await state.requirePersistenceHealthy()
                try await finishDedicated(admittedRequest, result: result, transaction: transaction)
                try await finalizeTerminalEvidence(result, request: admittedRequest, reservationID: reservationID,
                    simulateReplacementCrash: [ApplyChangeSetFailurePoint.evidenceMetadataReplacementRenameAfter,
                        .evidenceMetadataReplacementIntentAfter].contains(crash) ? crash : nil)
                await state.releaseTerminalMaterial(transaction, request: admittedRequest); try await state.requirePersistenceHealthy()
                try await syncDedicatedTransaction(transaction)
                try await releaseQuota(request: admittedRequest, reservationID: reservationID)
                try Self.cleanupTerminalTransactionDirectory(root: state.root, transaction: transaction)
                return result
            }
            let result = try await commit(admittedRequest, transaction: transaction, crash: crash, race: race)
            await state.markRecoveryRequired(transaction, receipts: 1)
            try await state.requirePersistenceHealthy()
            try await syncDedicatedTransaction(transaction)
            _ = result
            throw ApplyChangeSetError(.changeSetRecoveryRequired, "post-admission state changed")
                .attachingTransaction(transaction, request: admittedRequest, changedPaths: await state.changedPaths(transaction))
        }

        if await state.evidenceFailure != nil {
            throw ApplyChangeSetError(.changeSetRecoveryRequired, "diff evidence unavailable")
                .attachingTransaction(transaction, request: admittedRequest, changedPaths: [])
        }
        let result: ApplyChangeSetResult
        do { result = try await commit(admittedRequest, transaction: transaction, crash: crash, race: race) }
        catch let error as ApplyChangeSetError where error.code == .externalConflictDuringCommit {
            await state.markExternalConflict(transaction); try await state.requirePersistenceHealthy()
            try await syncDedicatedTransaction(transaction)
            throw error.attachingTransaction(transaction, request: admittedRequest, changedPaths: await state.changedPaths(transaction))
        } catch let error as ApplyChangeSetError {
            throw error.attachingTransaction(transaction, request: admittedRequest, changedPaths: await state.changedPaths(transaction))
        }
        await state.finish(request: admittedRequest, result: result, transaction: transaction, stateValue: .committed)
        try await state.requirePersistenceHealthy()
        try await finishDedicated(admittedRequest, result: result, transaction: transaction,
            crash: crash)
        try await finalizeTerminalEvidence(result, request: admittedRequest, reservationID: reservationID,
            simulateReplacementCrash: [ApplyChangeSetFailurePoint.evidenceMetadataReplacementRenameAfter,
                .evidenceMetadataReplacementIntentAfter].contains(crash) ? crash : nil)
        await state.releaseTerminalMaterial(transaction, request: admittedRequest); try await state.requirePersistenceHealthy()
        try await syncDedicatedTransaction(transaction)
        try await releaseQuota(request: admittedRequest, reservationID: reservationID)
        try Self.cleanupTerminalTransactionDirectory(root: state.root, transaction: transaction)
        return result
    }

    public func resumeReservation(_ id: String) async throws -> ApplyChangeSetResult {
        try await withOperationGate {
            guard try await state.reservationIsValid(id) else { throw ApplyChangeSetError(.changeSetReservationCorrupt) }
            return try await applyUnlocked(state.reservationRequest(id))
        }
    }

    public func recover(root: URL) async throws -> [ApplyChangeSetRecoveryResult] {
        try await withOperationGate { try await recoverUnlocked(root: root) }
    }

    private func recoverUnlocked(root: URL) async throws -> [ApplyChangeSetRecoveryResult] {
        try await ensureDedicatedStoreCutover()
        try await state.repairPendingJournals()
        await state.beginRecovery()
        do {
            let result = try await recoverActiveUnlocked(root: root)
            await state.endRecovery()
            return result
        } catch {
            await state.endRecovery()
            throw error
        }
    }

    private func recoverActiveUnlocked(root: URL) async throws -> [ApplyChangeSetRecoveryResult] {
        try await Task.sleep(for: .milliseconds(40))
        try await state.requirePersistenceHealthy()
        let transactions = try await dedicatedTransactions()
        if transactions.contains(where: { $0.corrupt }) { throw ApplyChangeSetError(.changeSetStoreCorrupt) }
        if transactions.contains(where: { $0.state == .recoveryRequired && $0.targetReceipts == -2 }) {
            throw ApplyChangeSetError(.externalConflictDuringCommit, "unknown external bytes are pinned for owner resolution")
        }
        if transactions.contains(where: { $0.state == .recoveryRequired && $0.retention == .pinned && $0.targetReceipts == -1 }) {
            throw ApplyChangeSetError(.changeSetRecoveryRequired)
        }
        var results: [ApplyChangeSetRecoveryResult] = []
        for item in transactions where item.admitted && item.state != .committed && item.state != .finalized && item.state != .abortedBeforeSideEffect {
            let request = try await state.materializedRequest(item.id)
            try Self.verifyManifestDigest(root: root, transaction: item.id, expected: await state.manifestDigest(item.id))
            if item.targetReceipts == -1 { throw ApplyChangeSetError(.changeSetRecoveryRequired) }
            if item.admitted {
                do {
                    var recoveredResult: ApplyChangeSetResult
                    if !item.commitWasDecided {
                        if item.state != .rolledBack {
                            if item.state != .rollbackDecided {
                                await state.markRollbackDecided(item.id)
                                try await state.requirePersistenceHealthy()
                                try await syncDedicatedTransaction(item.id)
                            }
                            let transactionDirectory = root.appendingPathComponent(".aishell-transactions/\(item.id.rawValue)", isDirectory: true)
                            if FileManager.default.fileExists(atPath: transactionDirectory.path) {
                                guard Self.matchesBefore(request, root: root) else {
                                    await state.markExternalConflict(item.id)
                                    try await state.requirePersistenceHealthy()
                                    try await syncDedicatedTransaction(item.id)
                                    throw ApplyChangeSetError(.externalConflictDuringCommit, "unknown external bytes block pre-commit cleanup")
                                }
                            }
                            guard Self.matchesBefore(request, root: root) else {
                                await state.markExternalConflict(item.id)
                                try await state.requirePersistenceHealthy()
                                try await syncDedicatedTransaction(item.id)
                                throw ApplyChangeSetError(.externalConflictDuringCommit, "unknown external bytes block pre-commit rollback")
                            }
                            await state.markRolledBack(item.id)
                            try await state.requirePersistenceHealthy()
                            try await syncDedicatedTransaction(item.id)
                        }
                        recoveredResult = try await abortedResult(request, transaction: item.id)
                    } else if item.commitWasDecided {
                    guard let reservationID = item.reservationID else { throw ApplyChangeSetError(.changeSetStoreCorrupt) }
                    try await Self.completeInterruptedCommit(request, transaction: item.id, root: root,
                        stageLedger: quotaLedger(reservationID: reservationID),
                        simulateCrashAfterFirstStageRename: await faults.consumeCrash(at: .recoveryStageRenameAfter))
                    guard Self.matchesAfter(request, root: root) else {
                        throw ApplyChangeSetError(.externalConflictDuringCommit, "recovered final graph verification failed")
                    }
                    if item.state != .filesystemCommitted && item.state != .runtimeCommitted && item.state != .trashCommitted {
                        await state.markFilesystemCommitted(item.id)
                        try await state.requirePersistenceHealthy()
                        try await syncDedicatedTransaction(item.id)
                    }
                    guard let pendingResult = await state.pendingResult(item.id) else {
                        throw ApplyChangeSetError(.changeSetStoreCorrupt, "commit_decided transaction has no durable result")
                    }
                    if await state.isRuntimeCommitted(request.transactionIdentity),
                       item.state != .runtimeCommitted && item.state != .trashCommitted {
                        let receipts = try await transactionStore.runtimeReceipts()
                        let hasReceipt = receipts.contains { $0.transactionID == item.id }
                        if !hasReceipt {
                            try await recordDedicatedRuntimeCommit(transaction: item.id,
                                cursor: pendingResult.cursor, paths: pendingResult.changedPaths)
                        }
                        await state.markRuntimeCommitted(item.id)
                        try await state.requirePersistenceHealthy()
                        try await syncDedicatedTransaction(item.id)
                    }
                    recoveredResult = pendingResult
                } else {
                    guard let pendingResult = item.pendingResult else {
                        throw ApplyChangeSetError(.changeSetStoreCorrupt, "committed filesystem state has no durable result")
                    }
                    await state.markFilesystemCommitted(item.id)
                    try await state.requirePersistenceHealthy()
                    try await syncDedicatedTransaction(item.id)
                    recoveredResult = pendingResult
                }
                if recoveredResult.status == .committed, !(await state.isRuntimeCommitted(request.transactionIdentity)) {
                    let knownMutations = Self.knownMutations(request)
                    do {
                        _ = try await workspaceRuntime.appendKnownMutation(transactionID: request.transactionIdentity, rootPath: root.path, changes: knownMutations)
                    } catch { throw ApplyChangeSetError(.changeSetRecoveryRequired, "workspace known-mutation recovery failed") }
                    let paths = recoveredResult.changedPaths
                    let currentCursor = await state.cursor()
                    if currentCursor == recoveredResult.cursor {
                        // The core cursor reached disk immediately before the dedicated receipt.
                        // Recreate that missing receipt without advancing the cursor a second time.
                        try await recordDedicatedRuntimeCommit(transaction: item.id,
                            cursor: recoveredResult.cursor, paths: paths)
                        await state.markRuntimeCommitted(item.id)
                        try await state.requirePersistenceHealthy()
                        try await syncDedicatedTransaction(item.id)
                    } else {
                        let cursor = await state.advance(paths: paths,
                            transactionID: request.transactionIdentity)
                        try await recordDedicatedRuntimeCommit(transaction: item.id,
                            cursor: cursor, paths: paths)
                        try await syncDedicatedTransaction(item.id)
                        guard cursor == recoveredResult.cursor else {
                            throw ApplyChangeSetError(.changeSetStoreCorrupt,
                                "recovered cursor differs from durable result")
                        }
                    }
                }
                if recoveredResult.status == .committed {
                    try await commitTrash(request, transaction: item.id, crash: nil)
                    recoveredResult = Self.addingTrashPaths(await state.trashPaths(item.id), to: recoveredResult)
                    await state.storePendingResult(item.id, result: recoveredResult)
                    try await state.requirePersistenceHealthy()
                    try await syncDedicatedTransaction(item.id)
                }
                    var finalizedResult = recoveredResult
                    // Committed retention is bound to the one durable runtime-receipt timestamp.
                    // Abort has no runtime receipt, so its terminal publication chooses the clock once.
                    let expiry: Date
                    if finalizedResult.status == .committed {
                        guard let receipt = try await transactionStore.runtimeReceipts().first(where: {
                            $0.transactionID == item.id
                        }), let terminalAt = receipt.terminalAt,
                        receipt.cursor == finalizedResult.cursor,
                        receipt.paths == finalizedResult.changedPaths else {
                            throw ApplyChangeSetError(.changeSetStoreCorrupt,
                                "committed recovery has no exact durable runtime receipt")
                        }
                        expiry = terminalAt.addingTimeInterval(TimeInterval(request.retentionSeconds))
                    } else {
                        expiry = await clock.now().addingTimeInterval(
                            TimeInterval(request.retentionSeconds))
                    }
                    finalizedResult = finalizedResult.replacingArtifact(.init(handle: finalizedResult.diffArtifact.handle,
                        sha256: finalizedResult.diffArtifact.sha256, sizeBytes: finalizedResult.diffArtifact.sizeBytes, expiresAt: expiry))
                    await state.storePendingResult(item.id, result: finalizedResult)
                    try await syncDedicatedTransaction(item.id)
                    let terminalState: ApplyChangeSetTransactionState = finalizedResult.status == .committed ? .committed : .abortedBeforeSideEffect
                    await state.finish(request: request, result: finalizedResult, transaction: item.id, stateValue: terminalState)
                    try await state.requirePersistenceHealthy()
                    try await finishDedicated(request, result: finalizedResult, transaction: item.id)
                    guard let reservationID = item.reservationID else { throw ApplyChangeSetError(.changeSetStoreCorrupt) }
                    try await finalizeTerminalEvidence(finalizedResult, request: request, reservationID: reservationID)
                    await state.releaseTerminalMaterial(item.id, request: request)
                    try await state.requirePersistenceHealthy()
                    try await syncDedicatedTransaction(item.id)
                    if let reservationID = item.reservationID { try await releaseQuota(request: request, reservationID: reservationID) }
                    try Self.cleanupTerminalTransactionDirectory(root: root, transaction: item.id)
                } catch let error as ApplyChangeSetError {
                    throw error.attachingTransaction(item.id, request: request, changedPaths: await state.changedPaths(item.id))
                }
            } else {
                await state.removeUnadmitted(item.id)
            }
            results.append(.init(transactionID: item.id, evidenceMissing: false))
        }
        for item in transactions where item.state == .committed || item.state == .finalized || item.state == .abortedBeforeSideEffect {
            if let reservationID = item.reservationID, await state.hasReservation(reservationID) {
                let terminalRequest = try await state.materializedRequest(item.id)
                if let result = item.pendingResult {
                    try await finalizeTerminalEvidence(result, request: terminalRequest, reservationID: reservationID)
                }
                await state.releaseTerminalMaterial(item.id, request: terminalRequest)
                try await state.requirePersistenceHealthy()
                try await syncDedicatedTransaction(item.id)
                try await releaseQuota(request: terminalRequest, reservationID: reservationID)
            } else if let result = item.pendingResult {
                guard let expiry = result.diffArtifact.expiresAt else { throw ApplyChangeSetError(.changeSetStoreCorrupt) }
                _ = try await evidenceStore.finalizeArtifact(handle: result.diffArtifact.handle, expiresAt: expiry)
            }
            try Self.cleanupTerminalTransactionDirectory(root: root, transaction: item.id)
        }
        await state.cleanupOrphans()
        try await state.requirePersistenceHealthy()
        return results
    }

    public func control(_ request: ApplyChangeSetControlRequest) async throws -> ApplyChangeSetControlResult {
        try await withOperationGate { try await controlUnlocked(request) }
    }

    private func controlUnlocked(_ request: ApplyChangeSetControlRequest) async throws -> ApplyChangeSetControlResult {
        try await ensureDedicatedStoreCutover()
        try await state.repairPendingJournals()
        let now = await clock.now()
        registryClock.set(now)
        do {
            switch try await legacyControlStore.lookup(controlRequestID: request.controlRequestID,
                requestDigest: Self.controlDigest(request), now: now) {
            case let .replay(result): return result
            case .missing, .expired: break
            }
            let newCount = await clientRegistry.unexpiredControlReceiptCount(at: now)
            try await legacyControlStore.requireReceiptCapacity(additionalCount: newCount + 1, now: now)
        } catch let error as LegacyControlCompatStoreError {
            let code: ApplyChangeSetError.Code = switch error.code {
            case .requestConflict: .changeSetSequenceConflict
            case .capacityExceeded: .clientControlCapacityExceeded
            case .secretStoreUnavailable: .changeSetSecretStoreUnavailable
            case .storeCorrupt, .importConflict: .changeSetStoreCorrupt
            }
            throw ApplyChangeSetError(code, error.message)
        }
        let crash = await faults.consumeCrash()
        if crash == .registryAtomicReplaceBefore { throw ApplyChangeSetSimulatedCrash(point: crash!) }
        if case .abort = request.action {
            let digest = Self.controlDigest(request)
            var result: ApplyChangeSetControlResult
            if case let .abort(transactionID) = request.action,
               let existing = await state.pendingResult(transactionID),
               existing.status == .abortedBeforeSideEffect {
                result = .init(controlRequestID: request.controlRequestID, client: nil,
                    transactionResult: existing)
            } else {
                result = try await state.performControl(request)
            }
            if case let .abort(transactionID) = request.action,
               let transactionResult = result.transactionResult {
                let transactionRequest = try await state.materializedRequest(transactionID)
                let finalized: ApplyChangeSetResult
                if transactionResult.diffArtifact.expiresAt != nil {
                    finalized = transactionResult
                } else {
                    let expiry = now.addingTimeInterval(TimeInterval(transactionRequest.retentionSeconds))
                    finalized = transactionResult.replacingArtifact(.init(
                        handle: transactionResult.diffArtifact.handle,
                        sha256: transactionResult.diffArtifact.sha256,
                        sizeBytes: transactionResult.diffArtifact.sizeBytes, expiresAt: expiry))
                }
                await state.storePendingResult(transactionID, result: finalized)
                try await finishDedicated(transactionRequest, result: finalized,
                    transaction: transactionID, crash: crash)
                result = .init(controlRequestID: result.controlRequestID, client: nil,
                    transactionResult: finalized)
            }
            do {
                result = try await legacyControlStore.record(
                    controlRequestID: request.controlRequestID,
                    requestDigest: digest,
                    result: result,
                    expiresAt: now.addingTimeInterval(300),
                    now: now
                )
            } catch let error as LegacyControlCompatStoreError {
                let code: ApplyChangeSetError.Code = switch error.code {
                case .requestConflict: .changeSetSequenceConflict
                case .capacityExceeded: .clientControlCapacityExceeded
                case .secretStoreUnavailable: .changeSetSecretStoreUnavailable
                case .storeCorrupt, .importConflict: .changeSetStoreCorrupt
                }
                throw ApplyChangeSetError(code, error.message)
            }
            if crash == .registryAtomicReplaceAfter { throw ApplyChangeSetSimulatedCrash(point: crash!) }
            return result
        }

        let requestDigest = Self.controlDigest(request)
        let generation = await clientRegistry.snapshot().generation
        let receipt: ChangeSetClientControlReceipt
        do {
            switch request.action {
            case .allocate:
                receipt = try await clientRegistry.allocate(controlRequestID: request.controlRequestID,
                    requestDigest: requestDigest, expiresAt: now.addingTimeInterval(300),
                    expectedRegistryGeneration: generation)
            case let .rotate(clientID, expectedEpoch):
                receipt = try await clientRegistry.rotateEpoch(controlRequestID: request.controlRequestID,
                    requestDigest: requestDigest, expiresAt: now.addingTimeInterval(300),
                    clientID: clientID, expectedEpoch: UInt64(expectedEpoch),
                    nextEpoch: UInt64(expectedEpoch + 1), expectedRegistryGeneration: generation)
            case let .retire(clientID, expectedEpoch):
                receipt = try await clientRegistry.retire(controlRequestID: request.controlRequestID,
                    requestDigest: requestDigest, expiresAt: now.addingTimeInterval(300),
                    clientID: clientID, expectedEpoch: UInt64(expectedEpoch),
                    expectedRegistryGeneration: generation)
            case let .reinitialize(expectedGeneration):
                guard UInt64(expectedGeneration) == generation else {
                    throw ApplyChangeSetError(.clientEpochChanged)
                }
                receipt = try await clientRegistry.reinitialize(controlRequestID: request.controlRequestID,
                    requestDigest: requestDigest, expiresAt: now.addingTimeInterval(300),
                    expectedRegistryGeneration: generation)
            case .abort:
                fatalError("abort was handled above")
            }
        } catch let error as ChangeSetClientRegistryError {
            throw Self.mapRegistryError(error)
        }
        if crash == .registryAtomicReplaceAfter { throw ApplyChangeSetSimulatedCrash(point: crash!) }
        let client: ApplyChangeSetClient? = receipt.clientID.flatMap { id -> ApplyChangeSetClient? in
            guard let epoch = receipt.currentEpoch, let slot = receipt.slotIndex else { return nil }
            return ApplyChangeSetClient(clientID: id, epoch: Int(epoch), slot: slot)
        }
        return .init(controlRequestID: request.controlRequestID, client: client, transactionResult: nil)
    }

    private func validateIdentityAndReplay(_ request: ApplyChangeSetRequest) async throws {
        guard Self.isCanonicalUUID(request.clientID) else { throw ApplyChangeSetError(.invalidArgument) }
        do {
            switch try await clientRegistry.lookup(clientID: request.clientID,
                epoch: UInt64(request.clientEpoch), sequence: UInt64(request.requestSequence),
                requestDigest: Self.requestDigest(request)) {
            case .new:
                return
            case .pending:
                throw ApplyChangeSetError(.changeSetPreviousPending)
            case let .replay(envelope):
                guard let transaction = try await transactionStore.load(ApplyChangeSetTransactionID(envelope.transactionID)),
                      let stored = try? JSONDecoder().decode(StoredTransaction.self, from: transaction.payload),
                      let result = stored.pendingResult,
                      try JSONEncoder.sorted.encode(result).applySHA256 == envelope.terminalResponseDigest else {
                    throw ApplyChangeSetError(.changeSetStoreCorrupt,
                        "terminal replay payload is absent or inconsistent")
                }
                throw ReplayResult(result)
            }
        } catch let error as ChangeSetClientRegistryError {
            throw Self.mapRegistryError(error)
        }
    }

    private static func mapRegistryError(_ error: ChangeSetClientRegistryError) -> ApplyChangeSetError {
        let code: ApplyChangeSetError.Code = switch error.code {
        case .clientNotRegistered: .changeSetClientNotRegistered
        case .clientCapacityExceeded: .changeSetClientCapacityExceeded
        case .clientExpired, .controlExpired: .changeSetExpired
        case .clientEpochAhead: .changeSetClientEpochAhead
        case .clientEpochExhausted: .clientEpochExhausted
        case .sequenceGap: .changeSetSequenceGap
        case .sequenceConflict, .controlRequestConflict: .changeSetSequenceConflict
        case .previousPending: .changeSetPreviousPending
        case .rotationBlocked: .clientRotationBlocked
        case .retireBlocked: .clientRetireBlocked
        case .reinitializeBlocked: .clientRegistryReinitializeBlocked
        case .controlRequestInvalid: .invalidArgument
        case .controlCapacityExceeded: .clientControlCapacityExceeded
        case .invalidEnvelope: .invalidArgument
        case .generationChanged: .clientEpochChanged
        case .storeCapacityExceeded: .changeSetLimitExceeded
        case .storeCorrupt, .legacyImportNotPristine, .legacyImportConflict: .changeSetStoreCorrupt
        }
        return .init(code, error.message)
    }

    fileprivate func registrySnapshotForTesting() async -> ChangeSetClientRegistrySnapshot {
        await clientRegistry.snapshot()
    }

    fileprivate func registryControlReceiptCountForTesting(at instant: Date) async -> Int {
        await clientRegistry.unexpiredControlReceiptCount(at: instant)
    }

    fileprivate func admitRegistryReplayForTesting(_ client: ApplyChangeSetClient) async throws {
        let snapshot = await clientRegistry.snapshot()
        guard let slot = snapshot.slots.first(where: { $0.clientID == client.clientID }) else {
            throw ApplyChangeSetError(.changeSetClientNotRegistered)
        }
        do {
            _ = try await clientRegistry.admit(clientID: client.clientID,
                epoch: UInt64(client.epoch), sequence: slot.highWater + 1,
                requestDigest: Data("test-pending".utf8).applySHA256,
                transactionID: "test-pending-\(client.clientID)",
                expectedRegistryGeneration: snapshot.generation)
        } catch let error as ChangeSetClientRegistryError {
            throw Self.mapRegistryError(error)
        }
    }

    fileprivate func installPreparedAdmissionForTesting(_ request: ApplyChangeSetRequest,
        transaction: ApplyChangeSetTransactionID) async throws {
        try await admitDedicated(request, reservationID: "test-reservation",
            transaction: transaction)
        try await syncDedicatedTransaction(transaction)
    }

    fileprivate func syncDedicatedTransactionForTesting(
        _ transaction: ApplyChangeSetTransactionID) async throws {
        try await syncDedicatedTransaction(transaction)
    }

    fileprivate func removeDedicatedRuntimeReceiptForTesting(
        _ transaction: ApplyChangeSetTransactionID) async throws {
        try await transactionStore.removeRuntimeReceiptForTesting(transaction)
    }

    private func validateRequest(_ request: ApplyChangeSetRequest) async throws {
        guard !request.changes.isEmpty, request.changes.count <= 128, (1...1_048_576).contains(request.diffByteBudget), request.retentionSeconds > 0 else { throw ApplyChangeSetError(.invalidArgument) }
        let bytes = request.changes.flatMap(\.contents)
        guard bytes.allSatisfy({ $0.count <= 16 * 1_024 * 1_024 }), bytes.reduce(0, { $0 + $1.count }) <= 64 * 1_024 * 1_024 else { throw ApplyChangeSetError(.changeSetLimitExceeded) }
        guard request.cursor.root == state.root.path else {
            throw ApplyChangeSetError(request.cursor.root.hasPrefix("/Volumes/") ? .transactionVolumeMismatch : .rootMismatch)
        }
        let cursor = await state.cursor()
        guard request.cursor.generation == cursor.generation else { throw ApplyChangeSetError(.rootMismatch) }
        guard request.cursor.sequence == cursor.sequence else { throw ApplyChangeSetError(.workspaceChanged) }
        guard await state.capabilities == Set(ApplyChangeSetCapability.allCases) else { throw ApplyChangeSetError(.transactionCapabilityUnavailable) }
        try validateGraph(request.changes)
        var identities: Set<String> = []
        for path in Set(request.changes.flatMap(\.paths)) {
            var info = stat()
            if lstat(state.root.appendingPathComponent(path).path, &info) == 0 {
                let identity = "\(info.st_dev):\(info.st_ino)"
                guard identities.insert(identity).inserted else { throw ApplyChangeSetError(.changeSetConflict) }
            }
        }
        for change in request.changes { try validatePathsAndExpected(change, root: state.root) }
    }

    private func validateGraph(_ changes: [ApplyChangeSetChange]) throws {
        guard Set(changes.map(\.changeID)).count == changes.count else { throw ApplyChangeSetError(.changeSetConflict) }
        var consumers: Set<String> = []; var producers: Set<String> = []; var folded: [String: String] = [:]
        for change in changes {
            for path in change.paths {
                let key = path.precomposedStringWithCanonicalMapping.lowercased()
                if let previous = folded[key], previous != path { throw ApplyChangeSetError(.changeSetConflict) }
                folded[key] = path
            }
            switch change {
            case let .create(_, path, _, _), let .write(_, path, _, _):
                guard producers.insert(path).inserted else { throw ApplyChangeSetError(.changeSetConflict) }
            case let .delete(_, path, _):
                guard consumers.insert(path).inserted else { throw ApplyChangeSetError(.changeSetConflict) }
            case let .rename(_, source, _, destination, _):
                guard source != destination, consumers.insert(source).inserted, producers.insert(destination).inserted else { throw ApplyChangeSetError(.changeSetConflict) }
            }
        }
        for a in changes.flatMap(\.paths) { for b in changes.flatMap(\.paths) where a != b && (a.hasPrefix(b + "/") || b.hasPrefix(a + "/")) { throw ApplyChangeSetError(.changeSetConflict) } }
    }

    private func validatePathsAndExpected(_ change: ApplyChangeSetChange, root: URL) throws {
        for path in change.paths { try Self.validateRelative(path, root: root) }
        switch change {
        case let .create(_, path, expected, content):
            guard content.bytes != nil else { throw ApplyChangeSetError(.invalidArgument) }
            try Self.check(expected, at: root.appendingPathComponent(path))
        case let .write(_, path, expected, content):
            guard content.bytes != nil else { throw ApplyChangeSetError(.invalidArgument) }
            try Self.check(expected, at: root.appendingPathComponent(path))
        case let .delete(_, path, expected): try Self.check(expected, at: root.appendingPathComponent(path))
        case let .rename(_, source, sourceExpected, destination, destinationExpected):
            try Self.check(sourceExpected, at: root.appendingPathComponent(source)); try Self.check(destinationExpected, at: root.appendingPathComponent(destination))
        }
    }

    private func commit(_ request: ApplyChangeSetRequest, transaction: ApplyChangeSetTransactionID, crash: ApplyChangeSetFailurePoint?, race: PendingRace?) async throws -> ApplyChangeSetResult {
        let root = state.root
        guard let reservationID = await state.reservationID(transaction) else {
            throw ApplyChangeSetError(.changeSetStoreCorrupt, "transaction has no quota reservation")
        }
        let quotaLedger = try quotaLedger(reservationID: reservationID)
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "root descriptor open failed: \(errno)") }
        defer { close(rootFD) }
        var pinned: [String: (parent: Int32, leaf: String)] = [:]
        defer { for value in pinned.values { close(value.parent) } }
        for path in Set(request.changes.flatMap(\.paths)) { pinned[path] = try Self.pinParent(rootFD: rootFD, relativePath: path) }
        if let race, ApplyChangeSetRacePoint.pathResolutionCases.contains(race.point) {
            try race.action.body()
            var pinnedRoot = stat(), currentRoot = stat()
            guard fstat(rootFD, &pinnedRoot) == 0, lstat(root.path, &currentRoot) == 0,
                  pinnedRoot.st_dev == currentRoot.st_dev, pinnedRoot.st_ino == currentRoot.st_ino else {
                throw ApplyChangeSetError(.changeSetRecoveryRequired, "root identity changed after descriptor pin")
            }
            for (path, descriptor) in pinned {
                let current = try Self.pinParent(rootFD: rootFD, relativePath: path)
                var pinnedParent = stat(), currentParent = stat()
                let matches = fstat(descriptor.parent, &pinnedParent) == 0
                    && fstat(current.parent, &currentParent) == 0
                    && pinnedParent.st_dev == currentParent.st_dev
                    && pinnedParent.st_ino == currentParent.st_ino
                close(current.parent)
                guard matches else {
                    throw ApplyChangeSetError(.changeSetRecoveryRequired, "parent identity changed after descriptor pin")
                }
            }
        }

        var sourceBytes: [String: Data] = [:]; var sourceModes: [String: UInt16] = [:]
        var sourceIdentities: [String: String] = [:]; var sourceDescriptors: [String: Int32] = [:]
        defer { for descriptor in sourceDescriptors.values { close(descriptor) } }
        for (path, descriptor) in pinned {
            if let opened = try Self.openRegularIfPresent(parentFD: descriptor.parent, leaf: descriptor.leaf) {
                sourceDescriptors[path] = opened.fd
                sourceBytes[path] = try Self.readAll(fd: opened.fd); sourceModes[path] = UInt16(opened.stat.st_mode & 0o7777)
                sourceIdentities[path] = "\(opened.stat.st_dev):\(opened.stat.st_ino)"
            }
        }
        for change in request.changes {
            func require(_ expected: ApplyChangeSetExpected, path: String) throws {
                switch expected {
                case .absent:
                    guard sourceBytes[path] == nil else { throw ApplyChangeSetError(.externalConflictDuringCommit, "expected-absent target changed after admission") }
                case let .file(sha):
                    guard sourceBytes[path]?.applySHA256 == sha.lowercased() else { throw ApplyChangeSetError(.externalConflictDuringCommit, "expected content changed after admission") }
                }
            }
            switch change {
            case let .create(_, path, expected, _), let .write(_, path, expected, _), let .delete(_, path, expected):
                try require(expected, path: path)
            case let .rename(_, source, sourceExpected, destination, destinationExpected):
                try require(sourceExpected, path: source)
                try require(destinationExpected, path: destination)
            }
        }
        if let race, ApplyChangeSetRacePoint.externalDescriptorWriteCases.contains(race.point) { try race.action.body() }
        var outputs: [String: (Data, UInt16)] = [:]; var outputMetadataSources: [String: Int32] = [:]
        var removals = Set<String>()
        for change in request.changes {
            switch change {
            case let .create(_, path, _, content):
                let bytes = content.bytes!; outputs[path] = (bytes, 0o644)
            case let .write(_, path, _, content):
                let bytes = content.bytes!; outputs[path] = (bytes, sourceModes[path] ?? 0o644); outputMetadataSources[path] = sourceDescriptors[path]
            case let .delete(_, path, _): removals.insert(path)
            case let .rename(_, source, _, destination, _):
                guard let bytes = sourceBytes[source] else { throw ApplyChangeSetError(.contentChanged) }
                removals.insert(source); outputs[destination] = (bytes, sourceModes[source] ?? 0o644); outputMetadataSources[destination] = sourceDescriptors[source]
            }
        }

        let from = request.cursor
        let to = ApplyChangeSetCursor(root: from.root, generation: from.generation, sequence: from.sequence + 1)
        let changeResults = request.changes.map { change -> ApplyChangeSetChangeResult in
            let kind: String; let beforePath: String?; let afterPath: String?; let before: Data?; let after: Data?; let mode: UInt16?
            switch change {
            case let .create(_, path, _, _): kind = "create"; beforePath = nil; afterPath = path; before = nil; after = outputs[path]?.0; mode = outputs[path]?.1
            case let .write(_, path, _, _): kind = "write"; beforePath = path; afterPath = path; before = sourceBytes[path]; after = outputs[path]?.0; mode = outputs[path]?.1
            case let .delete(_, path, _): kind = "delete"; beforePath = path; afterPath = nil; before = sourceBytes[path]; after = nil; mode = nil
            case let .rename(_, source, _, destination, _): kind = "rename"; beforePath = source; afterPath = destination; before = sourceBytes[source]; after = outputs[destination]?.0; mode = outputs[destination]?.1
            }
            return .init(changeID: change.changeID, afterSHA256: after?.applySHA256, kind: kind,
                beforePath: beforePath, afterPath: afterPath,
                beforeIdentity: beforePath.flatMap { sourceIdentities[$0] }, afterIdentity: nil,
                beforeSHA256: before?.applySHA256, beforeSizeBytes: before?.count, afterSizeBytes: after?.count,
                beforeMetadata: beforePath.flatMap { sourceModes[$0] }.map { .init(mode: $0) },
                afterMetadata: mode.map { .init(mode: $0) },
                afterContent: ApplyChangeSetChangeResult.inlineAfterContent(after))
        }
        let summary = ApplyChangeSetSummary(
            createCount: request.changes.filter { if case .create = $0 { true } else { false } }.count,
            writeCount: request.changes.filter { if case .write = $0 { true } else { false } }.count,
            deleteCount: request.changes.filter { if case .delete = $0 { true } else { false } }.count,
            renameCount: request.changes.filter { if case .rename = $0 { true } else { false } }.count,
            beforeBytes: sourceBytes.values.reduce(0) { $0 + $1.count },
            afterBytes: outputs.values.reduce(0) { $0 + $1.0.count }
        )
        let namespace = root.appendingPathComponent(".aishell-transactions", isDirectory: true)
        let transactionDirectory = namespace.appendingPathComponent(transaction.rawValue, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: transactionDirectory.path) else {
            throw ApplyChangeSetError(.changeSetStoreCorrupt, "unexpected pre-existing transaction directory")
        }
        try FileManager.default.createDirectory(at: transactionDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let transactionFD = open(transactionDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard transactionFD >= 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "transaction descriptor open failed: \(errno)") }
        defer { close(transactionFD) }

        var stageNames: [String: String] = [:]
        var stageIdentities: [String: String] = [:]
        let stageMaterialIDs = Dictionary(uniqueKeysWithValues: request.changes.compactMap { change -> String? in
            switch change {
            case let .create(_, path, _, _), let .write(_, path, _, _): return path
            case let .rename(_, _, _, destination, _): return destination
            case .delete: return nil
            }
        }.enumerated().map { ($0.element, "stage_\($0.offset)") })
        for (index, path) in outputs.keys.sorted().enumerated() {
            let name = "stage-\(index)"; let value = outputs[path]!
            guard let materialID = stageMaterialIDs[path] else { throw ApplyChangeSetError(.changeSetStoreCorrupt) }
            try await Self.materializeQuotaData(value.0, destination: transactionDirectory.appendingPathComponent(name),
                ledger: quotaLedger, materialID: materialID,
                idempotencyKey: "stage:\(materialID.dropFirst("stage_".count)):\(Self.requestDigest(request))",
                mode: value.1, metadataSourceFD: outputMetadataSources[path])
            stageNames[path] = name
            var stageInfo = stat()
            guard fstatat(transactionFD, name, &stageInfo, AT_SYMLINK_NOFOLLOW) == 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "stage identity capture failed") }
            stageIdentities[path] = "\(stageInfo.st_dev):\(stageInfo.st_ino)"
        }
        var parentIdentities: [String: String] = [:]
        for (path, descriptor) in pinned {
            var info = stat()
            guard fstat(descriptor.parent, &info) == 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "parent identity capture failed") }
            parentIdentities[path] = "\(info.st_dev):\(info.st_ino)"
        }
        let manifestData = try JSONSerialization.data(withJSONObject: [
            "schema": "aishell.apply-change-set-transaction-manifest.v1",
            "transaction_id": transaction.rawValue,
            "request_digest": Self.requestDigest(request),
            "paths": request.changes.flatMap(\.paths),
            "parent_identity": parentIdentities,
            "stage_identity": stageIdentities,
            "stage_sha256": Dictionary(uniqueKeysWithValues: outputs.map { ($0.key, $0.value.0.applySHA256) }),
        ], options: [.sortedKeys])
        try await Self.materializeQuotaData(manifestData, destination: transactionDirectory.appendingPathComponent("manifest.json"),
            ledger: quotaLedger, materialID: "manifest", idempotencyKey: "manifest:\(Self.requestDigest(request))")
        guard fsync(transactionFD) == 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "transaction directory fsync failed: \(errno)") }
        let namespaceFD = open(namespace.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard namespaceFD >= 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "transaction namespace open failed") }
        let namespaceSync = fsync(namespaceFD); close(namespaceFD)
        guard namespaceSync == 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "transaction namespace fsync failed") }
        await state.recordManifestDigest(transaction, digest: manifestData.applySHA256)
        try await state.requirePersistenceHealthy()
        let artifactChanges: [ChangeSetDiffArtifactBuilder.Change] = request.changes.map { change in
            func snapshot(_ path: String, bytes: Data?, identity: String?, mode: UInt16?) -> ChangeSetDiffArtifactBuilder.Snapshot? {
                bytes.map { .init(path: path, identity: identity, mode: mode, bytes: $0) }
            }
            switch change {
            case let .create(id, path, _, _):
                return .init(changeID: id, kind: .create, before: nil,
                    after: snapshot(path, bytes: outputs[path]?.0, identity: stageIdentities[path], mode: outputs[path]?.1))
            case let .write(id, path, _, _):
                return .init(changeID: id, kind: .write,
                    before: snapshot(path, bytes: sourceBytes[path], identity: sourceIdentities[path], mode: sourceModes[path]),
                    after: snapshot(path, bytes: outputs[path]?.0, identity: stageIdentities[path], mode: outputs[path]?.1))
            case let .delete(id, path, _):
                return .init(changeID: id, kind: .delete,
                    before: snapshot(path, bytes: sourceBytes[path], identity: sourceIdentities[path], mode: sourceModes[path]), after: nil)
            case let .rename(id, source, _, destination, _):
                return .init(changeID: id, kind: .rename,
                    before: snapshot(source, bytes: sourceBytes[source], identity: sourceIdentities[source], mode: sourceModes[source]),
                    after: snapshot(destination, bytes: outputs[destination]?.0, identity: stageIdentities[destination], mode: outputs[destination]?.1))
            }
        }
        let artifactOutput = try ChangeSetDiffArtifactBuilder.build(
            binding: .init(transactionID: transaction.rawValue, requestDigest: Self.requestDigest(request),
                manifestDigest: manifestData.applySHA256, root: root.path, fromCursor: from, toCursor: to,
                clientID: request.clientID, clientEpoch: request.clientEpoch, requestSequence: request.requestSequence),
            changes: artifactChanges, previewBudget: request.diffByteBudget
        )
        let existingResult = await state.pendingResult(transaction)
        let metadata: ApplyChangeSetArtifact
        if let existingResult {
            let verified = try await evidenceStore.verifyCompleteArtifact(handle: existingResult.diffArtifact.handle,
                kind: "apply-change-set-diff", producer: "ApplyChangeSetService", sha256: artifactOutput.sha256)
            metadata = .init(handle: verified.handle, sha256: verified.sha256, sizeBytes: verified.sizeBytes,
                expiresAt: existingResult.diffArtifact.expiresAt)
        } else if let existingArtifact = try await evidenceStore.findCompleteArtifact(
            kind: "apply-change-set-diff", producer: "ApplyChangeSetService", sha256: artifactOutput.sha256,
            retentionSeconds: 100 * 365 * 24 * 60 * 60
        ) {
            metadata = .init(handle: existingArtifact.handle, sha256: existingArtifact.sha256,
                sizeBytes: existingArtifact.sizeBytes, expiresAt: nil)
        } else {
            let stored = try await evidenceStore.store(data: artifactOutput.artifact, kind: "apply-change-set-diff",
                producer: "ApplyChangeSetService", retentionSeconds: 100 * 365 * 24 * 60 * 60,
                dataQuota: .init(ledger: quotaLedger, materialID: "diff_data",
                    idempotencyKey: "diff-data:\(Self.requestDigest(request))"),
                metadataQuota: .init(ledger: quotaLedger, materialID: "diff_metadata",
                    idempotencyKey: "diff-metadata:\(Self.requestDigest(request))"),
                simulateCrashAfterDataRename: crash == .quotaMaterialRenameAfter)
            metadata = .init(handle: stored.handle, sha256: stored.sha256, sizeBytes: stored.sizeBytes, expiresAt: nil)
        }
        var durableResult = ApplyChangeSetResult(
            transactionID: transaction.rawValue, clientID: request.clientID, clientEpoch: request.clientEpoch,
            root: root.path, status: .committed, visibility: .aishellSerializedRecoverable,
            requestSequence: request.requestSequence, fromCursor: from, cursor: to,
            changes: changeResults, changedPaths: request.changes.flatMap(\.paths), transactionCursorAdvanced: true,
            diffArtifact: metadata, summary: summary,
            diffPreview: artifactOutput.preview.bytes.base64EncodedString(), hasMore: artifactOutput.preview.hasMore,
            returnedDiffBytes: artifactOutput.preview.returnedBytes, omittedDiffBytes: artifactOutput.preview.omittedBytes
        )
        await state.storePendingResult(transaction, result: durableResult)
        try await state.requirePersistenceHealthy()
        try await syncDedicatedTransaction(transaction)
        if crash == .diffArtifactFSyncAfter { throw ApplyChangeSetSimulatedCrash(point: crash!) }
        durableResult = durableResult.replacingChanges(durableResult.changes.map { change in
            guard let path = change.afterPath, let identity = stageIdentities[path] else { return change }
            return .init(changeID: change.changeID, afterSHA256: change.afterSHA256, kind: change.kind,
                beforePath: change.beforePath, afterPath: change.afterPath,
                beforeIdentity: change.beforeIdentity, afterIdentity: identity,
                beforeSHA256: change.beforeSHA256, beforeSizeBytes: change.beforeSizeBytes,
                afterSizeBytes: change.afterSizeBytes, beforeMetadata: change.beforeMetadata,
                afterMetadata: change.afterMetadata, trashPath: change.trashPath,
                afterContent: change.afterContent)
        })
        await state.storePendingResult(transaction, result: durableResult)
        try await state.requirePersistenceHealthy()
        try await syncDedicatedTransaction(transaction)
        if crash == .stageFSyncAfter { throw ApplyChangeSetSimulatedCrash(point: crash!) }
        await state.markCommitDecided(transaction)
        try await state.requirePersistenceHealthy()
        try await syncDedicatedTransaction(transaction)
        if crash == .commitDecisionFSyncAfter { throw ApplyChangeSetSimulatedCrash(point: crash!) }

        let touched = Set(removals).union(outputs.keys).sorted()
        var backups: [String: String] = [:]
        var placed: Set<String> = []
        do {
            for (index, path) in touched.enumerated() {
                guard let descriptor = pinned[path] else { throw ApplyChangeSetError(.changeSetStoreCorrupt) }
                if sourceBytes[path] != nil {
                    let backup = "backup-\(index)"
                    guard renameatx_np(descriptor.parent, descriptor.leaf, transactionFD, backup, UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)) == 0 else {
                        throw ApplyChangeSetError(.externalConflictDuringCommit, "target backup rename failed: \(errno)")
                    }
                    guard let moved = try Self.openRegularIfPresent(parentFD: transactionFD, leaf: backup) else { throw ApplyChangeSetError(.externalConflictDuringCommit) }
                    let movedBytes: Data
                    do { movedBytes = try Self.readAll(fd: moved.fd) } catch { close(moved.fd); throw error }
                    close(moved.fd)
                    guard movedBytes == sourceBytes[path] else {
                        _ = renameatx_np(transactionFD, backup, descriptor.parent, descriptor.leaf, UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY))
                        throw ApplyChangeSetError(.externalConflictDuringCommit, "target identity changed at commit")
                    }
                    backups[path] = backup
                    guard fsync(descriptor.parent) == 0, fsync(transactionFD) == 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "backup receipt fsync failed") }
                    await state.recordTargetReceipt(transaction, phase: "backup_receipt", path: path)
                    try await state.requirePersistenceHealthy()
                    try await syncDedicatedTransaction(transaction)
                    if backups.count == 1, crash == .firstTargetReceiptAfter {
                        guard fsync(transactionFD) == 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired) }
                        throw ApplyChangeSetSimulatedCrash(point: crash!)
                    }
                } else {
                    var info = stat()
                    guard fstatat(descriptor.parent, descriptor.leaf, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw ApplyChangeSetError(.externalConflictDuringCommit, "absent target appeared") }
                }
            }
            for path in outputs.keys.sorted() {
                guard let descriptor = pinned[path], let stage = stageNames[path] else { throw ApplyChangeSetError(.changeSetStoreCorrupt) }
                guard let materialID = stageMaterialIDs[path], let stageNumber = materialID.split(separator: "_").last else {
                    throw ApplyChangeSetError(.changeSetStoreCorrupt)
                }
                try await quotaLedger.releaseMaterial(materialID: materialID,
                    idempotencyKey: "stage:\(stageNumber):\(Self.requestDigest(request))")
                guard renameatx_np(transactionFD, stage, descriptor.parent, descriptor.leaf, UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)) == 0 else {
                    throw ApplyChangeSetError(.externalConflictDuringCommit, "exclusive target placement failed: \(errno)")
                }
                placed.insert(path)
                guard fsync(descriptor.parent) == 0, fsync(transactionFD) == 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "target directory fsync failed: \(errno)") }
                await state.recordTargetReceipt(transaction, phase: "placement_receipt", path: path)
                try await state.requirePersistenceHealthy()
                try await syncDedicatedTransaction(transaction)
            }
            guard fsync(transactionFD) == 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "receipt directory fsync failed: \(errno)") }
            guard Self.matchesAfter(request, root: root) else {
                throw ApplyChangeSetError(.externalConflictDuringCommit, "final filesystem graph verification failed")
            }
            await state.markFilesystemCommitted(transaction)
            try await state.requirePersistenceHealthy()
            try await syncDedicatedTransaction(transaction)
        } catch {
            if await state.commitWasDecided(transaction) {
                await state.markRecoveryRequired(transaction, receipts: max(1, backups.count + placed.count))
                try await state.requirePersistenceHealthy()
                try await syncDedicatedTransaction(transaction)
                throw error
            }
            await state.markRollbackDecided(transaction)
            try await state.requirePersistenceHealthy()
            try await syncDedicatedTransaction(transaction)
            var rollbackFailed = false
            for path in placed.sorted().reversed() {
                guard let descriptor = pinned[path], let output = outputs[path] else { rollbackFailed = true; continue }
                do {
                    if let current = try Self.openRegularIfPresent(parentFD: descriptor.parent, leaf: descriptor.leaf) {
                        let bytes = try? Self.readAll(fd: current.fd); close(current.fd)
                        if bytes == output.0 { if unlinkat(descriptor.parent, descriptor.leaf, 0) != 0 { rollbackFailed = true } }
                        else { rollbackFailed = true }
                    }
                } catch { rollbackFailed = true }
            }
            for (path, backup) in backups {
                guard let descriptor = pinned[path], renameatx_np(transactionFD, backup, descriptor.parent, descriptor.leaf, UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)) == 0 else { rollbackFailed = true; continue }
                _ = fsync(descriptor.parent)
            }
            if rollbackFailed {
                await state.markRecoveryRequired(transaction, receipts: max(1, placed.count))
                try await syncDedicatedTransaction(transaction)
                throw ApplyChangeSetError(.changeSetRecoveryRequired, "rollback could not prove whole-before")
            }
            await state.markRolledBack(transaction)
            try await state.requirePersistenceHealthy()
            try await syncDedicatedTransaction(transaction)
            throw error
        }
        let knownMutations = Self.knownMutations(request)
        do { _ = try await workspaceRuntime.appendKnownMutation(transactionID: request.transactionIdentity, rootPath: root.path, changes: knownMutations) }
        catch {
            await state.markRecoveryRequired(transaction, receipts: max(1, request.changes.count))
            try await state.requirePersistenceHealthy()
            try await syncDedicatedTransaction(transaction)
            throw ApplyChangeSetError(.changeSetRecoveryRequired, "workspace known-mutation commit failed")
        }
        let runtimePaths = durableResult.changedPaths
        let advancedCursor = await state.advance(paths: runtimePaths, transactionID: request.transactionIdentity)
        if crash == .runtimeCursorFSyncAfter {
            throw ApplyChangeSetSimulatedCrash(point: crash!)
        }
        let runtimeCommittedAt = try await recordDedicatedRuntimeCommit(transaction: transaction, cursor: advancedCursor,
            paths: runtimePaths)
        if crash == .runtimeReceiptFSyncAfter {
            throw ApplyChangeSetSimulatedCrash(point: crash!)
        }
        try await state.requirePersistenceHealthy()
        try await syncDedicatedTransaction(transaction)
        guard advancedCursor == durableResult.cursor else {
            await state.markRecoveryRequired(transaction, receipts: max(1, request.changes.count))
            try await syncDedicatedTransaction(transaction)
            throw ApplyChangeSetError(.changeSetStoreCorrupt, "committed cursor differs from durable result")
        }
        if crash == .checkpointMarkerFSyncAfter || crash == .transactionReceiptFSyncAfter {
            throw ApplyChangeSetSimulatedCrash(point: crash!)
        }
        try await commitTrash(request, transaction: transaction, crash: crash)
        let trashPaths = await state.trashPaths(transaction)
        if !trashPaths.isEmpty {
            durableResult = durableResult.replacingChanges(durableResult.changes.map { change in
                guard let trashPath = trashPaths[change.changeID] else { return change }
                return .init(changeID: change.changeID, afterSHA256: change.afterSHA256, kind: change.kind,
                    beforePath: change.beforePath, afterPath: change.afterPath,
                    beforeIdentity: change.beforeIdentity, afterIdentity: change.afterIdentity,
                    beforeSHA256: change.beforeSHA256, beforeSizeBytes: change.beforeSizeBytes,
                    afterSizeBytes: change.afterSizeBytes, beforeMetadata: change.beforeMetadata,
                    afterMetadata: change.afterMetadata, trashPath: trashPath,
                    afterContent: change.afterContent)
            })
            await state.storePendingResult(transaction, result: durableResult)
            try await state.requirePersistenceHealthy()
            try await syncDedicatedTransaction(transaction)
        }
        if durableResult.diffArtifact.expiresAt == nil {
            let expiry = runtimeCommittedAt.addingTimeInterval(TimeInterval(request.retentionSeconds))
            durableResult = durableResult.replacingArtifact(.init(handle: durableResult.diffArtifact.handle,
                sha256: durableResult.diffArtifact.sha256, sizeBytes: durableResult.diffArtifact.sizeBytes, expiresAt: expiry))
            await state.storePendingResult(transaction, result: durableResult)
            try await state.requirePersistenceHealthy()
            try await syncDedicatedTransaction(transaction)
        }
        return durableResult
    }

    private func finalizeTerminalEvidence(
        _ result: ApplyChangeSetResult,
        request: ApplyChangeSetRequest,
        reservationID: String,
        simulateReplacementCrash: ApplyChangeSetFailurePoint? = nil
    ) async throws {
        guard let expiry = result.diffArtifact.expiresAt else {
            throw ApplyChangeSetError(.changeSetStoreCorrupt, "terminal result has no evidence expiry")
        }
        let digest = Self.requestDigest(request)
        let aborted = result.status == .abortedBeforeSideEffect
        let prefix = aborted ? "abort-diff-metadata" : "diff-metadata"
        let material = aborted ? "abort_diff_metadata" : "diff_metadata"
        let finalMaterial = aborted ? "abort_diff_metadata_final" : "diff_metadata_final"
        let lifecycleFailurePoint: ChangeSetQuotaLedger.LifecycleFailurePoint? = switch simulateReplacementCrash {
        case .evidenceMetadataReplacementRenameAfter: .replacementRenameCompleted
        case .evidenceMetadataReplacementIntentAfter: .replacementIntentPersisted
        default: nil
        }
        let ledger = try quotaLedger(reservationID: reservationID, lifecycleFailurePoint: lifecycleFailurePoint)
        do {
            _ = try await evidenceStore.finalizeArtifact(handle: result.diffArtifact.handle, expiresAt: expiry,
                currentQuota: .init(ledger: ledger, materialID: material, idempotencyKey: "\(prefix):\(digest)"),
                finalQuota: .init(ledger: ledger, materialID: finalMaterial, idempotencyKey: "\(prefix)-final:\(digest)"))
        } catch let lifecycle as ChangeSetQuotaLedger.SimulatedLifecycleCrash {
            throw ApplyChangeSetSimulatedCrash(point: lifecycle.point == .replacementIntentPersisted
                ? .evidenceMetadataReplacementIntentAfter : .evidenceMetadataReplacementRenameAfter)
        }
    }

    private func reconcileTerminalEvidence() async throws {
        let terminal = try await dedicatedTransactions().filter {
            $0.state == .committed || $0.state == .finalized || $0.state == .abortedBeforeSideEffect
        }
        for item in terminal {
            if let result = item.pendingResult, let reservationID = item.reservationID {
                let request = try await state.materializedRequest(item.id)
                try await finalizeTerminalEvidence(result, request: request, reservationID: reservationID)
            }
        }
    }

    private static func knownMutations(_ request: ApplyChangeSetRequest) -> [WorkspaceStateRuntime.KnownMutation] {
        request.changes.map { change in
            switch change {
            case let .create(_, path, _, _): .init(kind: .created, path: path)
            case let .write(_, path, _, _): .init(kind: .modified, path: path)
            case let .delete(_, path, _): .init(kind: .deleted, path: path)
            case let .rename(_, source, _, destination, _): .init(kind: .renamed, path: destination, previousPath: source)
            }
        }
    }

    private static func addingTrashPaths(_ paths: [String: String], to result: ApplyChangeSetResult) -> ApplyChangeSetResult {
        result.replacingChanges(result.changes.map { change in
            guard let trashPath = paths[change.changeID] else { return change }
            return .init(changeID: change.changeID, afterSHA256: change.afterSHA256, kind: change.kind,
                beforePath: change.beforePath, afterPath: change.afterPath, beforeIdentity: change.beforeIdentity,
                afterIdentity: change.afterIdentity, beforeSHA256: change.beforeSHA256,
                beforeSizeBytes: change.beforeSizeBytes, afterSizeBytes: change.afterSizeBytes,
                beforeMetadata: change.beforeMetadata, afterMetadata: change.afterMetadata,
                trashPath: trashPath, afterContent: change.afterContent)
        })
    }

    private static func verifyManifestDigest(root: URL, transaction: ApplyChangeSetTransactionID, expected: String?) throws {
        guard let expected else { return }
        let url = root.appendingPathComponent(".aishell-transactions/\(transaction.rawValue)/manifest.json")
        guard let data = try? Data(contentsOf: url), data.applySHA256 == expected else {
            throw ApplyChangeSetError(.changeSetStoreCorrupt, "transaction manifest authentication failed")
        }
    }

    private func commitTrash(_ request: ApplyChangeSetRequest, transaction: ApplyChangeSetTransactionID, crash: ApplyChangeSetFailurePoint?) async throws {
        let deletes: [(id: String, path: String)] = request.changes.compactMap {
            if case let .delete(id, path, _) = $0 { return (id, path) }
            return nil
        }
        guard !deletes.isEmpty else {
            await state.recordEmptyTrashReceipt(transaction)
            try await state.requirePersistenceHealthy()
            try await syncDedicatedTransaction(transaction)
            return
        }
        guard let reservationID = await state.reservationID(transaction) else { throw ApplyChangeSetError(.changeSetStoreCorrupt) }
        let quotaLedger = try quotaLedger(reservationID: reservationID)
        let requestDigest = Self.requestDigest(request)
        let transactionDirectory = state.root.appendingPathComponent(".aishell-transactions/\(transaction.rawValue)", isDirectory: true)
        let touched = Set(request.changes.flatMap(\.paths)).sorted()
        for (trashIndex, deletion) in deletes.enumerated() {
            if await state.hasTrashReceipt(transaction, changeID: deletion.id) { continue }
            let index = touched.firstIndex(of: deletion.path)!
            let backup = transactionDirectory.appendingPathComponent("backup-\(index)")
            var intent = await state.trashIntent(transaction, changeID: deletion.id)
            if intent == nil {
                let candidate = transactionDirectory.appendingPathComponent("trash-\(deletion.id)-\(transaction.rawValue)")
                if !FileManager.default.fileExists(atPath: candidate.path) {
                    let backupData = try Data(contentsOf: backup, options: .mappedIfSafe)
                    try await Self.materializeQuotaData(backupData, destination: candidate, ledger: quotaLedger,
                        materialID: "trash_\(trashIndex)", idempotencyKey: "trash:\(trashIndex):\(requestDigest)")
                } else {
                    guard let backupData = try? Data(contentsOf: backup), let candidateData = try? Data(contentsOf: candidate),
                          backupData == candidateData else {
                        throw ApplyChangeSetError(.changeSetStoreCorrupt, "existing trash candidate differs from backup")
                    }
                }
                let fd = open(candidate.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "trash candidate open failed") }
                var info = stat()
                guard fstat(fd, &info) == 0, fsync(fd) == 0 else { close(fd); throw ApplyChangeSetError(.changeSetRecoveryRequired, "trash candidate fsync failed") }
                close(fd)
                let value = DurableTrashRecord(changeID: deletion.id, sourcePath: deletion.path, candidatePath: candidate.path,
                    resultingPath: nil, device: UInt64(info.st_dev), inode: UInt64(info.st_ino), sha256: try Data(contentsOf: candidate).applySHA256,
                    trashRootPath: "", trashRootDevice: 0, trashRootInode: 0)
                let trashRoot = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: candidate, create: true)
                var trashRootInfo = stat()
                guard lstat(trashRoot.path, &trashRootInfo) == 0, (trashRootInfo.st_mode & S_IFMT) == S_IFDIR else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "volume Trash root unavailable") }
                let boundValue = DurableTrashRecord(changeID: value.changeID, sourcePath: value.sourcePath, candidatePath: value.candidatePath,
                    resultingPath: nil, device: value.device, inode: value.inode, sha256: value.sha256,
                    trashRootPath: trashRoot.path, trashRootDevice: UInt64(trashRootInfo.st_dev), trashRootInode: UInt64(trashRootInfo.st_ino))
                await state.recordTrashIntent(transaction, record: boundValue)
                try await state.requirePersistenceHealthy()
                try await syncDedicatedTransaction(transaction)
                intent = boundValue
                if crash == .trashIntentFSyncAfter { throw ApplyChangeSetSimulatedCrash(point: crash!) }
            }
            guard let intent else { throw ApplyChangeSetError(.changeSetStoreCorrupt) }
            let candidate = URL(fileURLWithPath: intent.candidatePath)
            try await quotaLedger.releaseMaterial(materialID: "trash_\(trashIndex)",
                idempotencyKey: "trash:\(trashIndex):\(requestDigest)")
            var resultURL: NSURL?
            if FileManager.default.fileExists(atPath: candidate.path) {
                try FileManager.default.trashItem(at: candidate, resultingItemURL: &resultURL)
            } else {
                let matches = try Self.findTrashCandidates(intent: intent)
                guard matches.count == 1 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "trash intent has \(matches.count) identity matches") }
                resultURL = matches[0] as NSURL
            }
            guard let result = resultURL as URL?, let data = try? Data(contentsOf: result), data.applySHA256 == intent.sha256 else {
                throw ApplyChangeSetError(.changeSetRecoveryRequired, "trash result identity mismatch")
            }
            var resultInfo = stat()
            guard lstat(result.path, &resultInfo) == 0, UInt64(resultInfo.st_dev) == intent.device, UInt64(resultInfo.st_ino) == intent.inode else {
                throw ApplyChangeSetError(.changeSetRecoveryRequired, "trash result inode mismatch")
            }
            await state.recordTrashReceipt(transaction, record: .init(changeID: intent.changeID, sourcePath: intent.sourcePath,
                candidatePath: intent.candidatePath, resultingPath: result.path, device: intent.device, inode: intent.inode, sha256: intent.sha256,
                trashRootPath: intent.trashRootPath, trashRootDevice: intent.trashRootDevice, trashRootInode: intent.trashRootInode))
            try await state.requirePersistenceHealthy()
            try await syncDedicatedTransaction(transaction)
            if crash == .trashReceiptFSyncAfter { throw ApplyChangeSetSimulatedCrash(point: crash!) }
        }
        await state.markTrashCommitted(transaction, expectedReceiptCount: deletes.count)
        try await state.requirePersistenceHealthy()
        try await syncDedicatedTransaction(transaction)
    }

    private static func findTrashCandidates(intent: DurableTrashRecord) throws -> [URL] {
        let root = URL(fileURLWithPath: intent.trashRootPath, isDirectory: true)
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, UInt64(rootInfo.st_dev) == intent.trashRootDevice,
              UInt64(rootInfo.st_ino) == intent.trashRootInode else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "Trash root identity changed") }
        var matches: [URL] = []
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        for case let url as URL in enumerator {
            var info = stat()
            guard lstat(url.path, &info) == 0, UInt64(info.st_dev) == intent.device, UInt64(info.st_ino) == intent.inode,
                  (try? Data(contentsOf: url).applySHA256) == intent.sha256 else { continue }
            matches.append(url)
        }
        return matches
    }

    private func abortedResult(_ request: ApplyChangeSetRequest, transaction: ApplyChangeSetTransactionID) async throws -> ApplyChangeSetResult {
        let artifactData = Data("{\"paths\":[]}".utf8)
        guard let reservationID = await state.reservationID(transaction) else { throw ApplyChangeSetError(.changeSetStoreCorrupt) }
        let ledger = try quotaLedger(reservationID: reservationID)
        let digest = Self.requestDigest(request)
        let meta = try await evidenceStore.store(data: artifactData, kind: "apply-change-set-diff", producer: "ApplyChangeSetService",
            retentionSeconds: 100 * 365 * 24 * 60 * 60,
            dataQuota: .init(ledger: ledger, materialID: "abort_diff_data", idempotencyKey: "abort-diff-data:\(digest)"),
            metadataQuota: .init(ledger: ledger, materialID: "abort_diff_metadata", idempotencyKey: "abort-diff-metadata:\(digest)"))
        let expiry = await clock.now().addingTimeInterval(TimeInterval(request.retentionSeconds))
        let result = ApplyChangeSetResult(status: .abortedBeforeSideEffect, visibility: .aishellSerializedRecoverable, requestSequence: request.requestSequence, fromCursor: request.cursor, cursor: request.cursor, changes: [], changedPaths: [], transactionCursorAdvanced: false, diffArtifact: .init(handle: meta.handle, sha256: meta.sha256, sizeBytes: meta.sizeBytes, expiresAt: expiry), returnedDiffBytes: min(request.diffByteBudget, artifactData.count), omittedDiffBytes: max(0, artifactData.count-request.diffByteBudget))
        await state.storePendingResult(transaction, result: result)
        try await state.requirePersistenceHealthy()
        return result
    }

    private static func pinParent(rootFD: Int32, relativePath: String) throws -> (parent: Int32, leaf: String) {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let leaf = components.last, !leaf.isEmpty else { throw ApplyChangeSetError(.unsupportedChangeTarget) }
        var current = dup(rootFD)
        guard current >= 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "root descriptor dup failed: \(errno)") }
        for component in components.dropLast() {
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current)
            guard next >= 0 else { throw ApplyChangeSetError(.unsupportedChangeTarget, "parent descriptor open failed") }
            current = next
        }
        return (current, leaf)
    }

    private static func openRegularIfPresent(parentFD: Int32, leaf: String) throws -> (fd: Int32, stat: stat)? {
        let descriptor = openat(parentFD, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw ApplyChangeSetError(.unsupportedChangeTarget, "target descriptor open failed: \(errno)")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { close(descriptor); throw ApplyChangeSetError(.unsupportedChangeTarget) }
        return (descriptor, info)
    }

    private static func readAll(fd: Int32) throws -> Data {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0, lseek(fd, 0, SEEK_SET) >= 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "descriptor stat/seek failed") }
        var data = Data(count: Int(info.st_size)); var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            while offset < buffer.count {
                let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard count >= 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "descriptor read failed: \(errno)") }
                if count == 0 { break }; offset += count
            }
        }
        guard offset == data.count else { throw ApplyChangeSetError(.externalConflictDuringCommit, "file size changed during descriptor read") }
        return data
    }

    private static func writeNewFile(parentFD: Int32, leaf: String, data: Data, mode: UInt16, metadataSourceFD: Int32? = nil) throws {
        let descriptor = openat(parentFD, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(mode))
        guard descriptor >= 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "stage create failed: \(errno)") }
        do {
            if let metadataSourceFD {
                guard fcopyfile(metadataSourceFD, descriptor, nil, copyfile_flags_t(COPYFILE_ACL)) == 0 else {
                    throw ApplyChangeSetError(.changeSetRecoveryRequired, "ACL copy failed: \(errno)")
                }
                try copyExtendedAttributes(from: metadataSourceFD, to: descriptor)
            }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    guard count > 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "stage write failed: \(errno)") }
                    offset += count
                }
            }
            guard fchmod(descriptor, mode_t(mode)) == 0, fsync(descriptor) == 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "stage fsync failed: \(errno)") }
            guard close(descriptor) == 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "stage close failed: \(errno)") }
        } catch { close(descriptor); _ = unlinkat(parentFD, leaf, 0); throw error }
    }

    private static func materializeQuotaData(
        _ data: Data,
        destination: URL,
        ledger: ChangeSetQuotaLedger,
        materialID: String,
        idempotencyKey: String,
        mode: UInt16 = 0o600,
        metadataSourceFD: Int32? = nil
    ) async throws {
        let adopted = try await ledger.adoptReserve(materialID: materialID, idempotencyKey: idempotencyKey, finalURL: destination)
        let descriptor = open(adopted.extentURL.path, O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "quota extent open failed: \(errno)") }
        do {
            if let metadataSourceFD {
                guard fcopyfile(metadataSourceFD, descriptor, nil, copyfile_flags_t(COPYFILE_ACL)) == 0 else {
                    throw ApplyChangeSetError(.changeSetRecoveryRequired, "ACL copy failed: \(errno)")
                }
                try copyExtendedAttributes(from: metadataSourceFD, to: descriptor)
            }
            try data.withUnsafeBytes { raw in
                var remaining = raw.count
                var pointer = raw.baseAddress
                while remaining > 0 {
                    let wrote = Darwin.write(descriptor, pointer, remaining)
                    guard wrote > 0 else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "quota extent write failed: \(errno)") }
                    remaining -= wrote
                    pointer = pointer?.advanced(by: wrote)
                }
            }
            guard fchmod(descriptor, mode_t(mode)) == 0, fsync(descriptor) == 0, close(descriptor) == 0 else {
                throw ApplyChangeSetError(.changeSetStoreCorrupt, "quota extent fsync failed: \(errno)")
            }
            _ = try await ledger.authorizeActual(materialID: materialID, idempotencyKey: idempotencyKey, data: data)
            guard rename(adopted.extentURL.path, destination.path) == 0 else {
                throw ApplyChangeSetError(.transactionVolumeMismatch, "quota extent atomic rename failed: \(errno)")
            }
            let directoryFD = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard directoryFD >= 0, fsync(directoryFD) == 0 else {
                if directoryFD >= 0 { close(directoryFD) }
                throw ApplyChangeSetError(.changeSetStoreCorrupt, "material directory fsync failed: \(errno)")
            }
            close(directoryFD)
            _ = try await ledger.commitMaterialization(materialID: materialID, idempotencyKey: idempotencyKey, finalURL: destination)
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func copyExtendedAttributes(from source: Int32, to destination: Int32) throws {
        let length = flistxattr(source, nil, 0, 0)
        guard length >= 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "xattr list failed: \(errno)") }
        guard length > 0 else { return }
        var names = [CChar](repeating: 0, count: length)
        guard flistxattr(source, &names, names.count, 0) == length else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "xattr list changed") }
        var offset = 0
        while offset < names.count {
            let end = names[offset...].firstIndex(of: 0) ?? names.count
            guard end > offset else { offset += 1; continue }
            let name = String(decoding: names[offset..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let valueLength = fgetxattr(source, name, nil, 0, 0, 0)
            guard valueLength >= 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "xattr read failed: \(errno)") }
            var value = Data(count: valueLength)
            let read = value.withUnsafeMutableBytes { fgetxattr(source, name, $0.baseAddress, $0.count, 0, 0) }
            guard read == valueLength else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "xattr value changed") }
            let written = value.withUnsafeBytes { fsetxattr(destination, name, $0.baseAddress, $0.count, 0, 0) }
            guard written == 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "xattr write failed: \(errno)") }
            offset = end + 1
        }
    }

    private static func completeInterruptedCommit(
        _ request: ApplyChangeSetRequest,
        transaction: ApplyChangeSetTransactionID,
        root: URL,
        stageLedger: ChangeSetQuotaLedger,
        simulateCrashAfterFirstStageRename: Bool
    ) async throws {
        let directory = root.appendingPathComponent(".aishell-transactions/\(transaction.rawValue)", isDirectory: true)
        let transactionFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard transactionFD >= 0 else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "commit_decided material is missing") }
        defer { close(transactionFD) }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "recovery root descriptor unavailable") }
        defer { close(rootFD) }
        let touched = Set(request.changes.flatMap(\.paths)).sorted()
        var pinned: [String: (parent: Int32, leaf: String)] = [:]
        defer { for value in pinned.values { close(value.parent) } }
        for path in touched { pinned[path] = try pinParent(rootFD: rootFD, relativePath: path) }

        guard let manifestOpened = try openRegularIfPresent(parentFD: transactionFD, leaf: "manifest.json") else { throw ApplyChangeSetError(.changeSetStoreCorrupt) }
        let manifestBytes = try readAll(fd: manifestOpened.fd); close(manifestOpened.fd)
        guard let manifest = try? JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any],
              manifest["transaction_id"] as? String == transaction.rawValue,
              manifest["request_digest"] as? String == requestDigest(request),
              let parentIdentities = manifest["parent_identity"] as? [String: String],
              let stageIdentities = manifest["stage_identity"] as? [String: String] else { throw ApplyChangeSetError(.changeSetStoreCorrupt) }
        for (path, descriptor) in pinned {
            var info = stat()
            guard fstat(descriptor.parent, &info) == 0, parentIdentities[path] == "\(info.st_dev):\(info.st_ino)" else {
                throw ApplyChangeSetError(.externalConflictDuringCommit, "parent identity changed before roll-forward")
            }
        }

        var expected: [String: ApplyChangeSetExpected] = [:]
        var desiredSHA: [String: String] = [:]
        for change in request.changes {
            switch change {
            case let .create(_, path, before, content), let .write(_, path, before, content):
                expected[path] = before; desiredSHA[path] = content.bytes!.applySHA256
            case let .delete(_, path, before): expected[path] = before
            case let .rename(_, source, sourceBefore, destination, destinationBefore):
                expected[source] = sourceBefore; expected[destination] = destinationBefore
                if case let .file(sha) = sourceBefore { desiredSHA[destination] = sha.lowercased() }
            }
        }
        let outputPaths = desiredSHA.keys.sorted()
        let stageName = Dictionary(uniqueKeysWithValues: outputPaths.enumerated().map { ($0.element, "stage-\($0.offset)") })
        let backupName = Dictionary(uniqueKeysWithValues: touched.enumerated().map { ($0.element, "backup-\($0.offset)") })

        func bytes(parent: Int32, leaf: String) throws -> Data? {
            guard let opened = try openRegularIfPresent(parentFD: parent, leaf: leaf) else { return nil }
            let value = try readAll(fd: opened.fd); close(opened.fd); return value
        }
        func matchesBefore(_ data: Data?, expected: ApplyChangeSetExpected) -> Bool {
            switch expected { case .absent: data == nil; case let .file(sha): data?.applySHA256 == sha.lowercased() }
        }

        for path in touched {
            guard let descriptor = pinned[path], let before = expected[path], let backup = backupName[path] else { throw ApplyChangeSetError(.changeSetStoreCorrupt) }
            var current = try bytes(parent: descriptor.parent, leaf: descriptor.leaf)
            let targetSHA = desiredSHA[path]
            if let targetSHA {
                var currentInfo = stat()
                let currentIdentity = fstatat(descriptor.parent, descriptor.leaf, &currentInfo, AT_SYMLINK_NOFOLLOW) == 0 ? "\(currentInfo.st_dev):\(currentInfo.st_ino)" : nil
                guard let expectedIdentity = stageIdentities[path] else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "stage identity is missing") }
                guard let stageIndex = outputPaths.firstIndex(of: path) else { throw ApplyChangeSetError(.changeSetStoreCorrupt) }
                let stageID = "stage_\(stageIndex)"
                if current?.applySHA256 == targetSHA, currentIdentity == expectedIdentity {
                    if try await stageLedger.materialViews().contains(where: { $0.id == stageID && $0.state == .materialized }) {
                        try await stageLedger.releaseMaterial(materialID: stageID,
                            idempotencyKey: "stage:\(stageIndex):\(requestDigest(request))")
                    }
                    continue
                }
                if matchesBefore(current, expected: before) {
                    if current != nil {
                        guard renameatx_np(descriptor.parent, descriptor.leaf, transactionFD, backup, UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)) == 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "roll-forward backup failed: \(errno)") }
                        current = nil
                    }
                } else if current == nil {
                    guard (try bytes(parent: transactionFD, leaf: backup)) != nil || before == .absent else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "missing before backup") }
                } else { throw ApplyChangeSetError(.externalConflictDuringCommit, "unknown bytes block roll-forward") }
                guard let stage = stageName[path], let staged = try bytes(parent: transactionFD, leaf: stage), staged.applySHA256 == targetSHA else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "after stage is missing or corrupt") }
                if try await stageLedger.materialViews().contains(where: { $0.id == stageID && $0.state == .materialized }) {
                    try await stageLedger.releaseMaterial(materialID: stageID,
                        idempotencyKey: "stage:\(stageIndex):\(requestDigest(request))")
                }
                guard renameatx_np(transactionFD, stage, descriptor.parent, descriptor.leaf, UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)) == 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "roll-forward placement failed: \(errno)") }
                if simulateCrashAfterFirstStageRename {
                    throw ApplyChangeSetSimulatedCrash(point: .recoveryStageRenameAfter)
                }
            } else {
                if current == nil { continue }
                guard matchesBefore(current, expected: before) else { throw ApplyChangeSetError(.externalConflictDuringCommit, "unknown delete/source bytes block roll-forward") }
                guard renameatx_np(descriptor.parent, descriptor.leaf, transactionFD, backup, UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)) == 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "roll-forward removal failed: \(errno)") }
            }
            guard fsync(descriptor.parent) == 0, fsync(transactionFD) == 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "roll-forward fsync failed") }
        }
        guard matchesAfter(request, root: root) else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "roll-forward final graph mismatch") }
    }

    private static func rollbackInterruptedTransaction(_ request: ApplyChangeSetRequest, transaction: ApplyChangeSetTransactionID, root: URL) throws {
        let directory = root.appendingPathComponent(".aishell-transactions/\(transaction.rawValue)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let transactionFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard transactionFD >= 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "recovery transaction descriptor unavailable") }
        defer { close(transactionFD) }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "recovery root descriptor unavailable") }
        defer { close(rootFD) }
        let touched = Set(request.changes.flatMap(\.paths)).sorted()
        var pinned: [String: (parent: Int32, leaf: String)] = [:]
        defer { for value in pinned.values { close(value.parent) } }
        for path in touched { pinned[path] = try pinParent(rootFD: rootFD, relativePath: path) }
        guard let manifestOpened = try openRegularIfPresent(parentFD: transactionFD, leaf: "manifest.json") else {
            throw ApplyChangeSetError(.changeSetStoreCorrupt, "transaction manifest is missing")
        }
        let manifestBytes = try readAll(fd: manifestOpened.fd); close(manifestOpened.fd)
        guard let manifest = try? JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any],
              manifest["transaction_id"] as? String == transaction.rawValue,
              manifest["request_digest"] as? String == requestDigest(request),
              let parentIdentities = manifest["parent_identity"] as? [String: String] else {
            throw ApplyChangeSetError(.changeSetStoreCorrupt, "transaction manifest authentication failed")
        }
        for (path, descriptor) in pinned {
            var info = stat()
            guard fstat(descriptor.parent, &info) == 0,
                  parentIdentities[path] == "\(info.st_dev):\(info.st_ino)" else {
                throw ApplyChangeSetError(.externalConflictDuringCommit, "parent identity changed before recovery")
            }
        }

        var backups: [String: (name: String, bytes: Data)] = [:]
        for (index, path) in touched.enumerated() {
            let name = "backup-\(index)"
            if let opened = try openRegularIfPresent(parentFD: transactionFD, leaf: name) {
                let bytes = try readAll(fd: opened.fd); close(opened.fd); backups[path] = (name, bytes)
            }
        }
        if backups.isEmpty {
            let beforeMatches = try request.changes.allSatisfy { change in
                func matches(_ expected: ApplyChangeSetExpected, path: String) throws -> Bool {
                    guard let descriptor = pinned[path] else { return false }
                    let current = try openRegularIfPresent(parentFD: descriptor.parent, leaf: descriptor.leaf)
                    switch expected {
                    case .absent: if let current { close(current.fd); return false }; return true
                    case let .file(sha):
                        guard let current else { return false }; let bytes = try readAll(fd: current.fd); close(current.fd); return bytes.applySHA256 == sha.lowercased()
                    }
                }
                switch change {
                case let .create(_, path, expected, _), let .write(_, path, expected, _), let .delete(_, path, expected): return try matches(expected, path: path)
                case let .rename(_, source, sourceExpected, destination, destinationExpected): return try matches(sourceExpected, path: source) && matches(destinationExpected, path: destination)
                }
            }
            if beforeMatches {
                try FileManager.default.removeItem(at: directory)
                return
            }
        }
        var intendedAfter: [String: Data] = [:]
        var expectedBefore: [String: ApplyChangeSetExpected] = [:]
        for change in request.changes {
            switch change {
            case let .create(_, path, expected, content), let .write(_, path, expected, content):
                expectedBefore[path] = expected
                if let bytes = content.bytes { intendedAfter[path] = bytes }
            case let .delete(_, path, expected): expectedBefore[path] = expected
            case let .rename(_, source, sourceExpected, destination, destinationExpected):
                expectedBefore[source] = sourceExpected
                expectedBefore[destination] = destinationExpected
                if let bytes = backups[source]?.bytes { intendedAfter[destination] = bytes }
                else if let sourceDescriptor = pinned[source], let opened = try openRegularIfPresent(parentFD: sourceDescriptor.parent, leaf: sourceDescriptor.leaf) {
                    intendedAfter[destination] = try readAll(fd: opened.fd); close(opened.fd)
                }
            }
        }
        for path in touched.reversed() {
            guard let descriptor = pinned[path] else { throw ApplyChangeSetError(.changeSetStoreCorrupt) }
            let current = try openRegularIfPresent(parentFD: descriptor.parent, leaf: descriptor.leaf)
            let currentBytes: Data?
            if let current { currentBytes = try readAll(fd: current.fd); close(current.fd) } else { currentBytes = nil }
            if let backup = backups[path] {
                if let currentBytes {
                    guard currentBytes == intendedAfter[path] || currentBytes == backup.bytes else { throw ApplyChangeSetError(.externalConflictDuringCommit, "unknown bytes block rollback") }
                    if currentBytes == backup.bytes { _ = unlinkat(transactionFD, backup.name, 0); continue }
                    guard unlinkat(descriptor.parent, descriptor.leaf, 0) == 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "rollback output removal failed") }
                }
                guard renameatx_np(transactionFD, backup.name, descriptor.parent, descriptor.leaf, UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)) == 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "rollback restore failed: \(errno)") }
                guard fsync(descriptor.parent) == 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "rollback parent fsync failed") }
            } else {
                guard let expected = expectedBefore[path] else { throw ApplyChangeSetError(.changeSetStoreCorrupt) }
                let matchesBefore: Bool
                switch expected {
                case .absent: matchesBefore = currentBytes == nil
                case let .file(sha): matchesBefore = currentBytes?.applySHA256 == sha.lowercased()
                }
                if matchesBefore { continue }
                guard case .absent = expected, let currentBytes, currentBytes == intendedAfter[path] else {
                    throw ApplyChangeSetError(.externalConflictDuringCommit, "unknown bytes block partial rollback")
                }
                guard unlinkat(descriptor.parent, descriptor.leaf, 0) == 0, fsync(descriptor.parent) == 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "rollback create removal failed") }
            }
        }
        guard fsync(transactionFD) == 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "rollback transaction fsync failed") }
        try FileManager.default.removeItem(at: directory)
        let namespaceFD = open(directory.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if namespaceFD >= 0 { _ = fsync(namespaceFD); close(namespaceFD) }
    }

    private static func cleanupTerminalTransactionDirectory(root: URL, transaction: ApplyChangeSetTransactionID) throws {
        let namespace = root.appendingPathComponent(".aishell-transactions", isDirectory: true)
        let directory = namespace.appendingPathComponent(transaction.rawValue, isDirectory: true)
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { if errno == ENOENT { return }; throw ApplyChangeSetError(.changeSetRecoveryRequired, "transaction cleanup inspection failed") }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "transaction material is not a directory") }
        try FileManager.default.removeItem(at: directory)
        let namespaceFD = open(namespace.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard namespaceFD >= 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "namespace cleanup descriptor failed") }
        defer { close(namespaceFD) }
        guard fsync(namespaceFD) == 0 else { throw ApplyChangeSetError(.changeSetRecoveryRequired, "namespace cleanup fsync failed") }
    }

    private static func validateRelative(_ path: String, root: URL) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(".."), path != ".aishell-transactions", !path.hasPrefix(".aishell-transactions/") else { throw ApplyChangeSetError(.unsupportedChangeTarget) }
        var current = root
        for component in path.split(separator: "/").dropLast() {
            current.appendPathComponent(String(component)); var info = stat(); guard lstat(current.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & S_IFMT) != S_IFLNK else { throw ApplyChangeSetError(.unsupportedChangeTarget) }
        }
        let url = root.appendingPathComponent(path); var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else { throw ApplyChangeSetError(.unsupportedChangeTarget) }
        }
    }
    private static func check(_ expected: ApplyChangeSetExpected, at url: URL) throws {
        let exists = FileManager.default.fileExists(atPath: url.path)
        switch expected {
        case .absent: if exists { throw ApplyChangeSetError(.expectedAbsenceViolated) }
        case let .file(sha):
            guard exists, let data = try? Data(contentsOf: url), data.applySHA256 == sha.lowercased() else { throw ApplyChangeSetError(.contentChanged) }
        }
    }
    private static func isCanonicalUUID(_ value: String) -> Bool { UUID(uuidString: value) != nil && value == value.lowercased() && value.count == 36 && value[value.index(value.startIndex, offsetBy: 14)] == "4" }
    fileprivate static func requestDigest(_ request: ApplyChangeSetRequest) -> String {
        var content = Data()
        let changes: [CanonicalReservationChange] = request.changes.map { change in
            func path(_ value: String) -> (String, Int) { let bytes = Data(value.utf8); return (bytes.base64EncodedString(), bytes.count) }
            switch change {
            case let .create(id, destination, expected, body):
                let bytes = body.bytes ?? Data(); let offset = content.count; content.append(bytes); let p = path(destination)
                return .init(kind: "create", changeID: id, sourcePathUTF8Base64: nil, sourcePathLength: nil, destinationPathUTF8Base64: p.0, destinationPathLength: p.1, sourceExpected: nil, destinationExpected: expected, contentOffset: offset, contentLength: bytes.count, contentSHA256: bytes.applySHA256)
            case let .write(id, destination, expected, body):
                let bytes = body.bytes ?? Data(); let offset = content.count; content.append(bytes); let p = path(destination)
                return .init(kind: "write", changeID: id, sourcePathUTF8Base64: nil, sourcePathLength: nil, destinationPathUTF8Base64: p.0, destinationPathLength: p.1, sourceExpected: nil, destinationExpected: expected, contentOffset: offset, contentLength: bytes.count, contentSHA256: bytes.applySHA256)
            case let .delete(id, source, expected):
                let p = path(source)
                return .init(kind: "delete", changeID: id, sourcePathUTF8Base64: p.0, sourcePathLength: p.1, destinationPathUTF8Base64: nil, destinationPathLength: nil, sourceExpected: expected, destinationExpected: nil, contentOffset: nil, contentLength: nil, contentSHA256: nil)
            case let .rename(id, source, sourceExpected, destination, destinationExpected):
                let s = path(source), d = path(destination)
                return .init(kind: "rename", changeID: id, sourcePathUTF8Base64: s.0, sourcePathLength: s.1, destinationPathUTF8Base64: d.0, destinationPathLength: d.1, sourceExpected: sourceExpected, destinationExpected: destinationExpected, contentOffset: nil, contentLength: nil, contentSHA256: nil)
            }
        }
        let header = CanonicalReservationHeader(schema: "aishell.apply-change-set-reservation.v1", clientID: request.clientID, clientEpoch: request.clientEpoch, requestSequence: request.requestSequence, cursor: request.cursor, changes: changes, diffByteBudget: request.diffByteBudget, retentionSeconds: request.retentionSeconds)
        guard let headerData = try? JSONEncoder.sorted.encode(header) else { return "" }
        var frame = Data("aishell.apply-change-set-reservation.v1\0".utf8)
        frame.appendUInt64BE(UInt64(headerData.count)); frame.append(headerData); frame.appendUInt64BE(UInt64(content.count)); frame.append(content)
        return frame.applySHA256
    }
    fileprivate static func controlDigest(_ request: ApplyChangeSetControlRequest) -> String { (try? JSONEncoder.sorted.encode(request).applySHA256) ?? "" }
    private static func mode(_ url: URL) -> UInt16 { let attrs = try? FileManager.default.attributesOfItem(atPath: url.path); return UInt16((attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0o644) }
    fileprivate static func matchesBefore(_ request: ApplyChangeSetRequest, root: URL) -> Bool {
        request.changes.allSatisfy { change in
            func matches(_ expected: ApplyChangeSetExpected, _ path: String) -> Bool {
                let url = root.appendingPathComponent(path)
                switch expected {
                case .absent: return !FileManager.default.fileExists(atPath: url.path)
                case let .file(sha): return (try? Data(contentsOf: url).applySHA256) == sha.lowercased()
                }
            }
            switch change {
            case let .create(_, path, expected, _), let .write(_, path, expected, _), let .delete(_, path, expected):
                return matches(expected, path)
            case let .rename(_, source, sourceExpected, destination, destinationExpected):
                return matches(sourceExpected, source) && matches(destinationExpected, destination)
            }
        }
    }
    fileprivate static func matchesAfter(_ request: ApplyChangeSetRequest, root: URL) -> Bool {
        var finalSHA: [String: String] = [:]
        var removed = Set<String>()
        for change in request.changes {
            switch change {
            case let .create(_, path, _, content), let .write(_, path, _, content):
                guard let bytes = content.bytes else { return false }; finalSHA[path] = bytes.applySHA256
            case let .delete(_, path, _): removed.insert(path)
            case let .rename(_, source, sourceExpected, destination, _):
                removed.insert(source)
                guard case let .file(expectedSHA) = sourceExpected else { return false }
                finalSHA[destination] = expectedSHA.lowercased()
            }
        }
        removed.subtract(finalSHA.keys)
        for (path, sha) in finalSHA {
            guard let bytes = try? Data(contentsOf: root.appendingPathComponent(path)), bytes.applySHA256 == sha else { return false }
        }
        return removed.allSatisfy { !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
    }
}

private struct ReplayResult: Error { let result: ApplyChangeSetResult; init(_ result: ApplyChangeSetResult) { self.result = result } }
private enum PendingApplyDisposition { case none, sameTransaction, conflict, otherTransaction }

// MARK: - Owner control plane

public enum ApplyChangeSetControlAction: Codable, Equatable, Sendable {
    case allocate
    case rotate(clientID: String, expectedEpoch: Int)
    case retire(clientID: String, expectedEpoch: Int)
    case reinitialize(expectedGeneration: Int)
    case abort(transaction: ApplyChangeSetTransactionID)
}

public struct ApplyChangeSetControlRequest: Codable, Equatable, Sendable {
    public let controlRequestID: String
    public let action: ApplyChangeSetControlAction
    public init(controlRequestID: String = UUID().uuidString.lowercased(), action: ApplyChangeSetControlAction) {
        self.controlRequestID = controlRequestID; self.action = action
    }
}

public struct ApplyChangeSetControlResult: Codable, Equatable, Sendable {
    public let controlRequestID: String
    public let client: ApplyChangeSetClient?
    public let transactionResult: ApplyChangeSetResult?
}

public struct ApplyChangeSetPendingControl: Sendable {
    public let request: ApplyChangeSetControlRequest
}

private extension ApplyChangeSetState {
    func activateDedicatedStoreMode(
        registrySlots: [ChangeSetClientSlotSnapshot],
        replayReferences: [ChangeSetReplayReference],
        transactionValues: [StoredTransaction],
        runtimeReceipts: [ChangeSetTransactionStore.RuntimeReceipt]
    ) throws {
        let requiresCoreSnapshotCutover = !dedicatedStoreMode
        let transactionMap = Dictionary(uniqueKeysWithValues: transactionValues.map { ($0.id, $0) })
        slots = registrySlots.sorted { $0.number < $1.number }.map { slot in
            ClientSlot(id: slot.clientID, epoch: Int(slot.currentEpoch),
                active: slot.allocationState == .active, highWater: Int(slot.highWater),
                replay: [:], nonterminal: false)
        }
        for reference in replayReferences {
            guard slots.indices.contains(reference.slotIndex),
                  slots[reference.slotIndex].id == reference.clientID else {
                throw ApplyChangeSetError(.changeSetStoreCorrupt, "registry slot reference mismatch")
            }
            if let transaction = transactionMap[ApplyChangeSetTransactionID(reference.transactionID)],
               let result = transaction.pendingResult, reference.state.isTerminal {
                slots[reference.slotIndex].replay[Int(reference.sequence)] = .init(
                    digest: reference.requestDigest, result: result)
            } else if !reference.state.isTerminal {
                slots[reference.slotIndex].nonterminal = true
            }
        }
        transactions = transactionMap
        pendingJournalRepairs.removeAll()
        runtimeEvents = runtimeReceipts.flatMap { receipt in
            receipt.paths.map { .init(transactionID: receipt.transactionID.rawValue, path: $0) }
        }
        runtimeCommitted = Set(runtimeReceipts.map { $0.transactionID.rawValue })
        controlReceipts = [:]
        dedicatedStoreMode = true
        if requiresCoreSnapshotCutover { try persist() }
        try Self.retireLegacyTransactionJournals(stateDirectory: stateDirectory)
    }

    func dedicatedTransactionSnapshot(_ id: ApplyChangeSetTransactionID) throws -> ChangeSetTransactionStore.Snapshot? {
        guard let item = transactions[id] else { return nil }
        let request = item.request ?? (try? materializedRequest(item.id))
        var references: [ChangeSetTransactionStore.Reference] = []
        if let reservationID = item.reservationID {
            references.append(.init(kind: "reservation", identifier: reservationID,
                digest: reservations[reservationID]?.requestDigest ?? String(repeating: "0", count: 64)))
        }
        if let request {
            references.append(.init(kind: "request", identifier: item.id.rawValue,
                digest: ApplyChangeSetService.requestDigest(request)))
        }
        if let result = item.pendingResult {
            references.append(.init(kind: "artifact", identifier: result.diffArtifact.handle,
                digest: result.diffArtifact.sha256))
            if item.state == .finalized || item.state == .committed || item.state == .abortedBeforeSideEffect {
                references.append(.init(kind: "terminal_response", identifier: item.id.rawValue,
                    digest: try JSONEncoder.sorted.encode(result).applySHA256))
            }
        }
        let retentionExpiresAt = item.pendingResult?.diffArtifact.expiresAt
        let terminalAt = retentionExpiresAt.flatMap { expiry in
            request.map { expiry.addingTimeInterval(-TimeInterval($0.retentionSeconds)) }
        }
        return .init(transactionID: item.id, state: item.state,
            manifestDigest: item.manifestDigest ?? String(repeating: "0", count: 64),
            references: references, payload: try JSONEncoder.sorted.encode(item),
            terminalAt: terminalAt, retentionExpiresAt: retentionExpiresAt)
    }

    func legacyTransactionsRequiringCutoverRecovery() -> [StoredTransaction] {
        transactions.values.filter {
            $0.state == .rolledBack
                || ($0.reservationID != nil && ($0.state == .finalized || $0.state == .committed
                    || $0.state == .abortedBeforeSideEffect))
        }.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    func legacyDedicatedStoreExport(cutoverTime: Date) throws -> ChangeSetLegacyStoreExport {
        let durable = DurableChangeSetSnapshot(
            schema: "aishell.apply-change-set-state.v1",
            rootPath: root.standardizedFileURL.resolvingSymlinksInPath().path,
            generation: generation, head: head, capabilities: capabilities, slots: slots,
            transactions: transactions, reservations: reservations,
            tamperedReservations: tamperedReservations, orphanPins: orphanPins,
            targetMutationReceipts: targetMutationReceipts, runtimeEvents: runtimeEvents,
            runtimeCommitted: runtimeCommitted, controlReceipts: controlReceipts,
            legacyExpired: legacyExpired, legacyReused: legacyReused
        )
        let sourceDigest = try JSONEncoder.sorted.encode(durable).applySHA256

        let legacySlots = try slots.enumerated().map { number, slot -> ChangeSetLegacyClientSlot in
            var replay = Array<ChangeSetReplayEnvelope?>(repeating: nil,
                count: ChangeSetClientRegistry.replayCapacity)
            for (sequence, record) in slot.replay {
                guard sequence > 0 else { throw ApplyChangeSetError(.changeSetStoreCorrupt) }
                let resultData = try JSONEncoder.sorted.encode(record.result)
                let transaction = transactions[ApplyChangeSetTransactionID(
                    record.result.transactionID ?? "\(slot.id):\(slot.epoch):\(sequence)")]
                let retainedRequest = transaction?.request ?? transaction.flatMap { try? materializedRequest($0.id) }
                let expiry = record.result.diffArtifact.expiresAt
                    ?? retainedRequest.map { cutoverTime.addingTimeInterval(TimeInterval($0.retentionSeconds)) }
                let state: ChangeSetReplayState = switch record.result.status {
                case .committed: .committed
                case .abortedBeforeSideEffect: .abortedBeforeSideEffect
                case .recoveryRequired: .recoveryRequired
                }
                replay[(sequence - 1) % ChangeSetClientRegistry.replayCapacity] = .init(
                    sequence: UInt64(sequence), requestDigest: record.digest,
                    transactionID: record.result.transactionID ?? "\(slot.id):\(slot.epoch):\(sequence)",
                    state: state, terminalResponseDigest: resultData.applySHA256,
                    artifact: expiry.map { .init(handle: record.result.diffArtifact.handle, expiresAt: $0) },
                    retentionExpiresAt: expiry
                )
            }
            for transaction in transactions.values where transaction.admitted {
                guard let request = transaction.request ?? (try? materializedRequest(transaction.id)),
                      request.clientID == slot.id, request.clientEpoch == slot.epoch,
                      replay[(request.requestSequence - 1) % ChangeSetClientRegistry.replayCapacity] == nil else {
                    continue
                }
                replay[(request.requestSequence - 1) % ChangeSetClientRegistry.replayCapacity] = .init(
                    sequence: UInt64(request.requestSequence),
                    requestDigest: ApplyChangeSetService.requestDigest(request),
                    transactionID: transaction.id.rawValue,
                    state: transaction.state == .recoveryRequired ? .recoveryRequired : .pending
                )
            }
            return .init(number: number, clientID: slot.id, slotGeneration: UInt64(max(0, slot.epoch)),
                allocationState: slot.active ? .active : .free,
                currentEpoch: UInt64(max(0, slot.epoch)), highWater: UInt64(max(0, slot.highWater)),
                replay: replay)
        }
        let registry = ChangeSetLegacyRegistrySnapshot(
            rootIdentityDigest: root.standardizedFileURL.resolvingSymlinksInPath().path.applyStringSHA256,
            registryGeneration: 1, slots: legacySlots,
            controlReceipts: Array(repeating: nil, count: ChangeSetClientRegistry.controlReceiptCapacity)
        )

        let transactionSnapshots = try transactions.keys.sorted { $0.rawValue < $1.rawValue }
            .compactMap { try dedicatedTransactionSnapshot($0) }
        let receiptGroups = Dictionary(grouping: runtimeEvents, by: \.transactionID)
        let receipts = try receiptGroups.keys.sorted().compactMap { rawID -> ChangeSetTransactionStore.RuntimeReceipt? in
            let id = ApplyChangeSetTransactionID(rawID)
            guard let transaction = transactions[id] else { return nil }
            let events = receiptGroups[rawID] ?? []
            let cursor = transaction.pendingResult?.cursor ?? self.cursor()
            let paths = events.map(\.path)
            let digest = try JSONEncoder.sorted.encode(
                [cursor.root, cursor.generation, String(cursor.sequence)] + paths
            ).applySHA256
            return .init(transactionID: id, cursor: cursor, paths: paths, digest: digest,
                recordedAt: transaction.pendingResult?.diffArtifact.expiresAt ?? cutoverTime,
                terminalAt: transaction.pendingResult?.diffArtifact.expiresAt.flatMap { expiry in
                    transaction.request.map { expiry.addingTimeInterval(-TimeInterval($0.retentionSeconds)) }
                })
        }
        return .init(sourceDigest: sourceDigest,
            cursorBinding: .init(root: root.standardizedFileURL.resolvingSymlinksInPath().path,
                generation: generation), registry: registry,
            transactions: transactionSnapshots, runtimeReceipts: receipts,
            controlReceipts: controlReceipts)
    }

    func appendJournal(_ id: ApplyChangeSetTransactionID, phase: String, path: String? = nil) async {
        guard var transaction = transactions[id] else { persistenceFailure = ApplyChangeSetError(.changeSetStoreCorrupt); return }
        do {
            let previous = transaction.journal.last?.digest ?? String(repeating: "0", count: 64)
            let sequence = transaction.journal.count + 1
            let payload = TransactionJournalPayload(sequence: sequence, phase: phase, path: path, previousDigest: previous,
                state: transaction.state, targetReceipts: transaction.targetReceipts,
                pendingResult: transaction.pendingResult, commitWasDecided: transaction.commitWasDecided,
                trashIntents: transaction.trashIntents, trashReceipts: transaction.trashReceipts,
                manifestDigest: transaction.manifestDigest)
            var framed = Data(previous.utf8); framed.append(try JSONEncoder.sorted.encode(payload))
            let entry = TransactionJournalEntry(payload: payload, digest: framed.applySHA256)
            transaction.journal.append(entry); transactions[id] = transaction
            if dedicatedStoreMode { return }
            let directory = stateDirectory.appendingPathComponent("journals", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent(id.rawValue).appendingPathExtension("jsonl")
            var line = try JSONEncoder.sorted.encode(entry); line.append(0x0A)
            if let context = try quotaPersistenceContext() {
                let entryDirectory = directory.appendingPathComponent(id.rawValue, isDirectory: true)
                try FileManager.default.createDirectory(at: entryDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let final = entryDirectory.appendingPathComponent(String(format: "entry-%06d.json", sequence))
                try await Self.materializeQuotaData(line, destination: final, ledger: context.ledger,
                    materialID: "wal_\(sequence - 1)", idempotencyKey: "wal:\(sequence - 1):\(context.digest)")
            } else {
                let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "journal open failed") }
                let wrote = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                guard wrote == line.count, fsync(fd) == 0 else { close(fd); throw ApplyChangeSetError(.changeSetStoreCorrupt, "journal append failed") }
                close(fd)
            }
        } catch let error as ApplyChangeSetError { persistenceFailure = error }
        catch { persistenceFailure = ApplyChangeSetError(.changeSetStoreCorrupt,
            "journal persistence failed: \(error)") }
    }
    func persistOrRecord() async {
        guard persistenceFailure == nil else { return }
        persistenceRevision &+= 1
        await acquirePersistenceGate()
        defer { releasePersistenceGate() }
        do {
            guard let context = try quotaPersistenceContext() else { try persist(); persistenceFailure = nil; return }
            var observedRevision = persistenceRevision
            while true {
                let terminal = transactions.values.contains {
                    $0.reservationID == context.reservationID
                        && ($0.state == .finalized || $0.state == .abortedBeforeSideEffect)
                }
                try await quotaMaterializeGeneration(try encodedSnapshot(), destination: snapshotURL,
                    prefix: terminal ? "terminal" : "state", keyPrefix: terminal ? "terminal" : "state", context: context)
                guard persistenceRevision != observedRevision else { break }
                observedRevision = persistenceRevision
            }
            persistenceFailure = nil
        }
        catch let error as ApplyChangeSetError { persistenceFailure = error }
        catch { persistenceFailure = ApplyChangeSetError(.changeSetStoreCorrupt,
            "state quota persistence failed: \(error)") }
    }
    private func persistQuotaHandoff(
        context: (ledger: ChangeSetQuotaLedger, digest: String, reservationID: String),
        prefix: String
    ) async {
        guard persistenceFailure == nil else { return }
        persistenceRevision &+= 1
        await acquirePersistenceGate()
        defer { releasePersistenceGate() }
        do {
            var observedRevision = persistenceRevision
            while true {
                try await quotaMaterializeGeneration(try encodedSnapshot(), destination: snapshotURL,
                    prefix: prefix, keyPrefix: prefix, context: context)
                guard persistenceRevision != observedRevision else { break }
                observedRevision = persistenceRevision
            }
            persistenceFailure = nil
        } catch let error as ApplyChangeSetError { persistenceFailure = error }
        catch { persistenceFailure = ApplyChangeSetError(.changeSetStoreCorrupt, "state quota handoff failed") }
    }
    func requirePersistenceHealthy() throws { if let persistenceFailure { throw persistenceFailure } }
    func isRecoveryActive() -> Bool { recoveryActive }
    func hasIncompleteTransactions() -> Bool {
        transactions.values.contains { $0.admitted && $0.state != .committed && $0.state != .finalized && $0.state != .abortedBeforeSideEffect }
    }
    func incompleteReservationID() -> String? {
        transactions.values.first { $0.admitted && $0.state != .committed && $0.state != .finalized && $0.state != .abortedBeforeSideEffect }?.reservationID
    }
    func pendingDisposition(for request: ApplyChangeSetRequest) throws -> PendingApplyDisposition {
        let incomplete = transactions.values.filter { $0.admitted && $0.state != .committed && $0.state != .finalized && $0.state != .abortedBeforeSideEffect }
        guard !incomplete.isEmpty else { return .none }
        let id = ApplyChangeSetTransactionID(request.transactionIdentity)
        guard incomplete.contains(where: { $0.id == id }) else { return .otherTransaction }
        let durable = try materializedRequest(id)
        return ApplyChangeSetService.requestDigest(durable) == ApplyChangeSetService.requestDigest(request) ? .sameTransaction : .conflict
    }
    func unadmittedReservation(for request: ApplyChangeSetRequest) throws -> String? {
        let referenced = Set(transactions.values.compactMap(\.reservationID))
        let candidates = reservations.values.filter {
            !referenced.contains($0.id) && $0.clientID == request.clientID
                && $0.clientEpoch == request.clientEpoch && $0.requestSequence == request.requestSequence
        }
        guard candidates.count <= 1 else { throw ApplyChangeSetError(.changeSetStoreCorrupt, "duplicate unadmitted reservations") }
        guard let candidate = candidates.first else { return nil }
        let durable = try decryptReservationRecord(candidate)
        guard ApplyChangeSetService.requestDigest(durable) == ApplyChangeSetService.requestDigest(request) else {
            throw ApplyChangeSetError(.changeSetSequenceConflict)
        }
        return candidate.id
    }
    func reservationRequest(_ id: String) throws -> ApplyChangeSetRequest {
        guard let binding = reservations[id] else { throw ApplyChangeSetError(.changeSetReservationCorrupt) }
        return try decryptReservationRecord(binding)
    }
    func reservationIsValid(_ id: String) throws -> Bool {
        guard !tamperedReservations.contains(id), let binding = reservations[id] else { return false }
        _ = try decryptReservationRecord(binding)
        return true
    }
    func controlReplay(_ request: ApplyChangeSetControlRequest) throws -> ApplyChangeSetControlResult? {
        guard let receipt = controlReceipts[request.controlRequestID] else { return nil }
        guard receipt.requestDigest == ApplyChangeSetService.controlDigest(request) else { throw ApplyChangeSetError(.changeSetSequenceConflict) }
        return receipt.result
    }
    func controlReceiptCount() -> Int { controlReceipts.count }
    func cursor() -> ApplyChangeSetCursor { .init(root: root.path, generation: generation, sequence: head) }
    func setLegacyMigrated() async { legacyExpired = true; legacyReused = false; await persistOrRecord() }
    func slot(id: String) -> ClientSlot? { slots.first { $0.id == id } }
    func storeReservation(_ reservation: ApplyChangeSetReservation, ledger: ChangeSetQuotaLedger,
        simulateCanonicalRenameCrash: Bool = false) async throws {
        do {
            try await writeReservationRecord(reservation, ledger: ledger,
                simulateCanonicalRenameCrash: simulateCanonicalRenameCrash)
            reservations[reservation.id] = binding(reservation)
            await persistOrRecord()
        } catch let crash as ApplyChangeSetSimulatedCrash {
            persistenceFailure = nil
            throw crash
        } catch let error as ApplyChangeSetError { persistenceFailure = error }
        catch { persistenceFailure = ApplyChangeSetError(.changeSetStoreCorrupt, "reservation persistence failed") }
    }
    func storeReservation(_ reservation: ApplyChangeSetReservation) {
        do {
            try writeTestingReservationRecord(reservation)
            reservations[reservation.id] = binding(reservation)
            try persist()
            persistenceFailure = nil
        } catch let error as ApplyChangeSetError { persistenceFailure = error }
        catch { persistenceFailure = ApplyChangeSetError(.changeSetStoreCorrupt, "reservation persistence failed") }
    }
    func storeTransaction(_ value: StoredTransaction) async {
        guard value.admitted, value.journal.isEmpty else { transactions[value.id] = value; await persistOrRecord(); return }
        var seeded = value
        let desiredState = value.state
        seeded.state = .preparing; seeded.targetReceipts = 0; seeded.commitWasDecided = false
        transactions[value.id] = seeded
        await appendJournal(value.id, phase: ApplyChangeSetTransactionState.preparing.rawValue)
        if desiredState != .preparing {
            transactions[value.id]?.state = .prepared
            await appendJournal(value.id, phase: ApplyChangeSetTransactionState.prepared.rawValue)
        }
        if desiredState == .commitDecided {
            transactions[value.id]?.state = .commitDecided
            transactions[value.id]?.commitWasDecided = true
            transactions[value.id]?.targetReceipts = value.targetReceipts
            await appendJournal(value.id, phase: ApplyChangeSetTransactionState.commitDecided.rawValue)
        } else if desiredState == .recoveryRequired {
            transactions[value.id]?.state = .recoveryRequired
            transactions[value.id]?.targetReceipts = value.targetReceipts
            await appendJournal(value.id, phase: ApplyChangeSetTransactionState.recoveryRequired.rawValue)
        }
        await persistOrRecord()
    }
    func storePendingResult(_ id: ApplyChangeSetTransactionID, result: ApplyChangeSetResult) async {
        transactions[id]?.pendingResult = result
        await persistOrRecord()
    }
    func simulateStateLeadingJournalWrite(_ id: ApplyChangeSetTransactionID) async throws {
        guard var transaction = transactions[id], let last = transaction.journal.last else {
            throw ApplyChangeSetError(.changeSetStoreCorrupt, "state-leading journal fixture is unavailable")
        }
        let payload = TransactionJournalPayload(sequence: transaction.journal.count + 1,
            phase: transaction.state.rawValue, path: nil, previousDigest: last.digest,
            state: transaction.state, targetReceipts: transaction.targetReceipts,
            pendingResult: transaction.pendingResult, commitWasDecided: transaction.commitWasDecided,
            trashIntents: transaction.trashIntents, trashReceipts: transaction.trashReceipts,
            manifestDigest: transaction.manifestDigest)
        let payloadData = try JSONEncoder.sorted.encode(payload)
        var framed = Data(last.digest.utf8); framed.append(payloadData)
        transaction.journal.append(.init(payload: payload, digest: framed.applySHA256))
        transactions[id] = transaction
        await persistOrRecord()
        try requirePersistenceHealthy()
    }
    func pendingResult(_ id: ApplyChangeSetTransactionID) -> ApplyChangeSetResult? { transactions[id]?.pendingResult }
    func manifestDigest(_ id: ApplyChangeSetTransactionID) -> String? { transactions[id]?.manifestDigest }
    func recordManifestDigest(_ id: ApplyChangeSetTransactionID, digest: String) async {
        transactions[id]?.manifestDigest = digest
        await persistOrRecord()
    }
    func isRuntimeCommitted(_ transactionID: String) -> Bool { runtimeCommitted.contains(transactionID) }
    func trashIntent(_ id: ApplyChangeSetTransactionID, changeID: String) -> DurableTrashRecord? { transactions[id]?.trashIntents[changeID] }
    func hasTrashReceipt(_ id: ApplyChangeSetTransactionID, changeID: String) -> Bool { transactions[id]?.trashReceipts[changeID] != nil }
    func recordTrashIntent(_ id: ApplyChangeSetTransactionID, record: DurableTrashRecord) async {
        transactions[id]?.trashIntents[record.changeID] = record
        await appendJournal(id, phase: "trash_intent", path: record.sourcePath)
        await persistOrRecord()
    }
    func recordTrashReceipt(_ id: ApplyChangeSetTransactionID, record: DurableTrashRecord) async {
        transactions[id]?.trashReceipts[record.changeID] = record
        await appendJournal(id, phase: "trash_receipt", path: record.sourcePath)
        await persistOrRecord()
    }
    func markTrashCommitted(_ id: ApplyChangeSetTransactionID, expectedReceiptCount: Int) async {
        guard transactions[id]?.trashReceipts.count == expectedReceiptCount else {
            persistenceFailure = ApplyChangeSetError(.changeSetStoreCorrupt, "trash receipt set is incomplete")
            return
        }
        if transactions[id]?.state == .trashCommitted { return }
        transactions[id]?.state = .trashCommitted
        await appendJournal(id, phase: ApplyChangeSetTransactionState.trashCommitted.rawValue)
        await persistOrRecord()
    }
    func recordEmptyTrashReceipt(_ id: ApplyChangeSetTransactionID) async {
        await markTrashCommitted(id, expectedReceiptCount: 0)
    }
    func commitWasDecided(_ id: ApplyChangeSetTransactionID) -> Bool { transactions[id]?.commitWasDecided == true }
    func recordTargetReceipt(_ id: ApplyChangeSetTransactionID, phase: String, path: String) async {
        transactions[id]?.targetReceipts += 1
        targetMutationReceipts += 1
        await appendJournal(id, phase: phase, path: path)
        await persistOrRecord()
    }
    func trashReceiptCount(_ id: ApplyChangeSetTransactionID) -> Int { transactions[id]?.trashReceipts.count ?? 0 }
    func trashPaths(_ id: ApplyChangeSetTransactionID) -> [String: String] {
        let records = transactions[id].map { Array($0.trashReceipts.values) } ?? []
        return Dictionary(uniqueKeysWithValues: records.compactMap { record in
            record.resultingPath.map { (record.changeID, $0) }
        })
    }
    func changedPaths(_ id: ApplyChangeSetTransactionID) -> [String] {
        Array(Set(transactions[id]?.journal.compactMap { entry in
            guard entry.payload.phase == "backup_receipt" || entry.payload.phase == "placement_receipt" else { return nil }
            return entry.payload.path
        } ?? [])).sorted()
    }
    func reservationID(_ id: ApplyChangeSetTransactionID) -> String? { transactions[id]?.reservationID }
    func hasReservation(_ id: String) -> Bool { reservations[id] != nil }
    func quotaReferenceState(_ reservationID: String) -> (admission: Bool, registry: Bool) {
        let admission = transactions.values.contains { $0.admitted && $0.reservationID == reservationID }
        return (admission, reservations[reservationID] != nil)
    }
    func reservationTransactionIdentity(_ reservationID: String) throws -> String? {
        guard let binding = reservations[reservationID] else { return nil }
        return try decryptReservationRecord(binding).transactionIdentity
    }
    func detachUnadmittedReservation(_ reservationID: String) async throws {
        guard !transactions.values.contains(where: { $0.admitted && $0.reservationID == reservationID }) else {
            throw ApplyChangeSetError(.changeSetRecoveryRequired, "admitted quota reservation cannot be detached")
        }
        guard let binding = reservations[reservationID] else { return }
        let context = (ledger: try ChangeSetQuotaLedger(
            ledgerDirectory: stateDirectory.appendingPathComponent("reservations", isDirectory: true),
            reservationID: reservationID
        ), digest: binding.requestDigest, reservationID: reservationID)
        reservations.removeValue(forKey: reservationID)
        persistenceRevision &+= 1
        await acquirePersistenceGate()
        defer { releasePersistenceGate() }
        do {
            try await quotaMaterializeGeneration(try encodedSnapshot(), destination: snapshotURL,
                prefix: "state", keyPrefix: "state", context: context)
            persistenceFailure = nil
        } catch let error as ApplyChangeSetError {
            persistenceFailure = error
            throw error
        } catch {
            let failure = ApplyChangeSetError(.changeSetStoreCorrupt, "state quota detach persistence failed")
            persistenceFailure = failure
            throw failure
        }
    }
    func admit(request: ApplyChangeSetRequest, reservationID: String, transaction: ApplyChangeSetTransactionID) async {
        transactions[transaction] = .init(id: transaction, request: nil, state: .preparing, corrupt: false, materialExists: true, retention: .pinned, admitted: true, targetReceipts: 0, reservationID: reservationID)
        if let index = slots.firstIndex(where: { $0.id == request.clientID }) {
            slots[index].nonterminal = true
            slots[index].highWater = request.requestSequence
        }
        await persistOrRecord()
        guard persistenceFailure == nil else { return }
        await appendJournal(transaction, phase: ApplyChangeSetTransactionState.preparing.rawValue)
        transactions[transaction]?.state = .prepared
        await appendJournal(transaction, phase: ApplyChangeSetTransactionState.prepared.rawValue)
        await persistOrRecord()
    }
    func materializedRequest(_ id: ApplyChangeSetTransactionID) throws -> ApplyChangeSetRequest {
        guard let transaction = transactions[id] else { throw ApplyChangeSetError(.changeSetStoreCorrupt) }
        guard let reservationID = transaction.reservationID else {
            guard let request = transaction.request else { throw ApplyChangeSetError(.changeSetStoreCorrupt) }
            return request
        }
        guard let binding = reservations[reservationID] else { throw ApplyChangeSetError(.changeSetReservationCorrupt) }
        let request = try decryptReservationRecord(binding)
        guard binding.requestDigest == ApplyChangeSetService.requestDigest(request) else { throw ApplyChangeSetError(.changeSetReservationCorrupt) }
        return request
    }
    func markRecoveryRequired(_ id: ApplyChangeSetTransactionID, receipts: Int) async {
        transactions[id]?.state = .recoveryRequired; transactions[id]?.targetReceipts = receipts; targetMutationReceipts += max(0, receipts)
        await appendJournal(id, phase: ApplyChangeSetTransactionState.recoveryRequired.rawValue)
        await persistOrRecord()
    }
    func markExternalConflict(_ id: ApplyChangeSetTransactionID) async {
        transactions[id]?.state = .recoveryRequired; transactions[id]?.targetReceipts = -2; transactions[id]?.retention = .pinned
        await appendJournal(id, phase: ApplyChangeSetTransactionState.recoveryRequired.rawValue)
        await persistOrRecord()
    }
    func markCommitDecided(_ id: ApplyChangeSetTransactionID) async { transactions[id]?.state = .commitDecided; transactions[id]?.commitWasDecided = true; await appendJournal(id, phase: ApplyChangeSetTransactionState.commitDecided.rawValue); await persistOrRecord() }
    func markFilesystemCommitted(_ id: ApplyChangeSetTransactionID) async {
        transactions[id]?.state = .filesystemCommitted
        await appendJournal(id, phase: ApplyChangeSetTransactionState.filesystemCommitted.rawValue)
        await persistOrRecord()
    }
    func markRuntimeCommitted(_ id: ApplyChangeSetTransactionID) async {
        transactions[id]?.state = .runtimeCommitted
        await appendJournal(id, phase: ApplyChangeSetTransactionState.runtimeCommitted.rawValue)
        await persistOrRecord()
    }
    func markRollbackDecided(_ id: ApplyChangeSetTransactionID) async {
        transactions[id]?.state = .rollbackDecided
        await appendJournal(id, phase: ApplyChangeSetTransactionState.rollbackDecided.rawValue)
        await persistOrRecord()
    }
    func markRolledBack(_ id: ApplyChangeSetTransactionID) async {
        transactions[id]?.state = .rolledBack
        await appendJournal(id, phase: ApplyChangeSetTransactionState.rolledBack.rawValue)
        await persistOrRecord()
    }
    func finish(request: ApplyChangeSetRequest, result: ApplyChangeSetResult, transaction: ApplyChangeSetTransactionID, stateValue: ApplyChangeSetTransactionState) async {
        let durableState: ApplyChangeSetTransactionState = stateValue == .committed ? .finalized : stateValue
        transactions[transaction]?.state = durableState; transactions[transaction]?.materialExists = durableState == .recoveryRequired
        if let index = slots.firstIndex(where: { $0.id == request.clientID }) {
            slots[index].highWater = max(slots[index].highWater, request.requestSequence)
            slots[index].replay[request.requestSequence] = .init(digest: ApplyChangeSetService.requestDigest(request), result: result)
            let floor = max(1, slots[index].highWater - 255)
            slots[index].replay = slots[index].replay.filter { $0.key >= floor }
            slots[index].nonterminal = false
        }
        await persistOrRecord()
        guard persistenceFailure == nil else { return }
        await appendJournal(transaction, phase: durableState.rawValue)
        await persistOrRecord()
    }
    func advance(paths: [String], transactionID: String) async -> ApplyChangeSetCursor {
        head += 1
        runtimeEvents.append(contentsOf: paths.map { .init(transactionID: transactionID, path: $0) })
        runtimeCommitted.insert(transactionID)
        if let transaction = transactions.keys.first(where: { $0.rawValue == transactionID }) {
            transactions[transaction]?.state = .runtimeCommitted
            await persistOrRecord()
            guard persistenceFailure == nil else { return cursor() }
            await appendJournal(transaction, phase: ApplyChangeSetTransactionState.runtimeCommitted.rawValue)
        }
        targetMutationReceipts += paths.count
        await persistOrRecord()
        return cursor()
    }
    func beginRecovery() { recoveryActive = true }
    func endRecovery() { recoveryActive = false }
    func markRecovered(_ id: ApplyChangeSetTransactionID, request: ApplyChangeSetRequest) async {
        transactions[id]?.state = .finalized; transactions[id]?.materialExists = false
        if let index = slots.firstIndex(where: { $0.id == request.clientID }) { slots[index].nonterminal = false }
        runtimeCommitted.insert(request.transactionIdentity)
        await appendJournal(id, phase: ApplyChangeSetTransactionState.finalized.rawValue)
        await persistOrRecord()
    }
    func releaseTerminalMaterial(_ id: ApplyChangeSetTransactionID, request: ApplyChangeSetRequest) async {
        let digest = ApplyChangeSetService.requestDigest(request)
        let released = reservations.values.filter { $0.requestDigest == digest }
        guard let reservation = released.first else {
            persistenceFailure = ApplyChangeSetError(.changeSetStoreCorrupt, "terminal reservation binding is absent")
            return
        }
        let context: (ledger: ChangeSetQuotaLedger, digest: String, reservationID: String)
        do {
            context = (ledger: try ChangeSetQuotaLedger(
                ledgerDirectory: stateDirectory.appendingPathComponent("reservations", isDirectory: true),
                reservationID: reservation.id
            ), digest: digest, reservationID: reservation.id)
        } catch {
            persistenceFailure = ApplyChangeSetError(.changeSetStoreCorrupt, "terminal quota handoff ledger is unavailable")
            return
        }
        transactions[id]?.request = request
        await persistOrRecord()
        guard persistenceFailure == nil else { return }
        reservations = reservations.filter { $0.value.requestDigest != digest }
        transactions[id]?.reservationID = nil
        transactions[id]?.materialExists = false
        await persistQuotaHandoff(context: context, prefix: "terminal")
        guard persistenceFailure == nil else { return }
        do { for reservation in released { try removeReservationRecord(reservation.id) } }
        catch let error as ApplyChangeSetError { persistenceFailure = error }
        catch { persistenceFailure = ApplyChangeSetError(.changeSetStoreCorrupt, "reservation release failed") }
    }
    func removeUnadmitted(_ id: ApplyChangeSetTransactionID) async { transactions.removeValue(forKey: id); await persistOrRecord() }
    func cleanupOrphans() async {
        for (id, pin) in orphanPins where !pin {
            do { try removeReservationRecord(id) } catch let error as ApplyChangeSetError { persistenceFailure = error; return } catch { persistenceFailure = ApplyChangeSetError(.changeSetStoreCorrupt); return }
            orphanPins.removeValue(forKey: id); reservations.removeValue(forKey: id)
        }
        await persistOrRecord()
    }
    func persistConcurrencyProbe(_ key: String) async {
        orphanPins[key] = true
        await persistOrRecord()
    }
    func hasConcurrencyProbe(_ key: String) -> Bool { orphanPins[key] == true }
    func persistLegacySnapshotForCutoverTesting() throws {
        dedicatedStoreMode = false
        let fileManager = FileManager.default
        let journalRoot = stateDirectory.appendingPathComponent("journals", isDirectory: true)
        if fileManager.fileExists(atPath: journalRoot.path) {
            try fileManager.removeItem(at: journalRoot)
        }
        try fileManager.createDirectory(at: journalRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        for (id, transaction) in transactions where !transaction.journal.isEmpty {
            let directory = journalRoot.appendingPathComponent(id.rawValue, isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            for (offset, entry) in transaction.journal.enumerated() {
                var line = try JSONEncoder.sorted.encode(entry)
                line.append(0x0A)
                try Self.atomicDurableWrite(line, to: directory.appendingPathComponent(
                    String(format: "entry-%06d.json", offset + 1)))
            }
        }
        try persist()
    }
    func restoreLegacyClientForCutoverTesting(_ request: ApplyChangeSetRequest) {
        guard let index = slots.firstIndex(where: { $0.id == request.clientID }) else { return }
        slots[index].active = true
        slots[index].epoch = request.clientEpoch
        slots[index].highWater = max(slots[index].highWater, request.requestSequence - 1)
        slots[index].nonterminal = true
    }
    func expireControlReceipts(now: Date) async { controlReceipts = controlReceipts.filter { $0.value.expiresAt > now }; await persistOrRecord() }

    func performControl(_ request: ApplyChangeSetControlRequest) async throws -> ApplyChangeSetControlResult {
        switch request.action {
        case .allocate:
            guard let index = slots.firstIndex(where: { !$0.active }) else { throw ApplyChangeSetError(.changeSetClientCapacityExceeded) }
            guard slots[index].epoch < Int.max else { throw ApplyChangeSetError(.clientEpochExhausted) }
            slots[index].active = true; slots[index].epoch += 1; slots[index].highWater = 0; slots[index].replay = [:]; slots[index].nonterminal = false
            return .init(controlRequestID: request.controlRequestID, client: .init(clientID: slots[index].id, epoch: slots[index].epoch, slot: index), transactionResult: nil)
        case let .rotate(id, expected):
            guard let index = slots.firstIndex(where: { $0.id == id && $0.active }), slots[index].epoch == expected else { throw ApplyChangeSetError(.clientEpochChanged) }
            guard !slots[index].nonterminal else { throw ApplyChangeSetError(.clientRotationBlocked) }
            guard slots[index].epoch < Int.max else { throw ApplyChangeSetError(.clientEpochExhausted) }
            slots[index].epoch += 1; slots[index].highWater = 0; slots[index].replay = [:]
            return .init(controlRequestID: request.controlRequestID, client: .init(clientID: id, epoch: slots[index].epoch, slot: index), transactionResult: nil)
        case let .retire(id, expected):
            guard let index = slots.firstIndex(where: { $0.id == id && $0.active }), slots[index].epoch == expected else { throw ApplyChangeSetError(.clientEpochChanged) }
            guard !slots[index].nonterminal else { throw ApplyChangeSetError(.clientRetireBlocked) }
            slots[index].active = false; slots[index].highWater = 0; slots[index].replay = [:]
            return .init(controlRequestID: request.controlRequestID, client: .init(clientID: id, epoch: slots[index].epoch, slot: index), transactionResult: nil)
        case .reinitialize:
            guard slots.allSatisfy({ !$0.active && !$0.nonterminal }), transactions.values.allSatisfy({ $0.state == .committed || $0.state == .finalized || $0.state == .abortedBeforeSideEffect }) else { throw ApplyChangeSetError(.clientRegistryReinitializeBlocked) }
            return .init(controlRequestID: request.controlRequestID, client: nil, transactionResult: nil)
        case let .abort(id):
            guard var transaction = transactions[id], transaction.targetReceipts == 0,
                  transaction.state == .prepared, transaction.pendingResult == nil else {
                throw ApplyChangeSetError(.changeSetRecoveryRequired)
            }
            let transactionRequest = try materializedRequest(id)
            transaction.state = .abortedBeforeSideEffect; transaction.retention = .quarantined; transactions[id] = transaction
            let emptyArtifact = ApplyChangeSetArtifact(handle: "owner-abort", sha256: Data().applySHA256, sizeBytes: 0)
            let result = ApplyChangeSetResult(status: .abortedBeforeSideEffect, visibility: .aishellSerializedRecoverable, requestSequence: transactionRequest.requestSequence, fromCursor: transactionRequest.cursor, cursor: transactionRequest.cursor, changes: [], changedPaths: [], transactionCursorAdvanced: false, diffArtifact: emptyArtifact, returnedDiffBytes: 0, omittedDiffBytes: 0)
            if let index = slots.firstIndex(where: { $0.id == transactionRequest.clientID }) {
                slots[index].highWater = max(slots[index].highWater, transactionRequest.requestSequence)
                slots[index].replay[transactionRequest.requestSequence] = .init(
                    digest: ApplyChangeSetService.requestDigest(transactionRequest),
                    result: result
                )
                slots[index].nonterminal = false
            }
            transactions[id]?.pendingResult = result
            await appendJournal(id, phase: ApplyChangeSetTransactionState.abortedBeforeSideEffect.rawValue)
            await persistOrRecord()
            try requirePersistenceHealthy()
            return .init(controlRequestID: request.controlRequestID, client: nil, transactionResult: result)
        }
    }
}

// MARK: - Production-backed verification probe

public final class ApplyChangeSetTestProbe: @unchecked Sendable {
    public let evidenceStore: EvidenceStore
    public let stateStore: ApplyChangeSetStateStore
    public let workspaceRuntime: WorkspaceStateRuntime
    private let base: URL
    private let root: URL
    private let stateDirectory: URL
    private let runtimeStore: RuntimeStore
    private var state: ApplyChangeSetState
    private let clock: ApplyChangeSetTestClock
    private let sequenceLock = NSLock()
    private var synchronousSequence = 1
    private var externalCleanupURLs: [URL] = []


    public init(baseDirectory: URL, disabledCapabilities: Set<ApplyChangeSetCapability>, clock: ApplyChangeSetTestClock) throws {
        base = baseDirectory; root = baseDirectory.appendingPathComponent("root", isDirectory: true); stateDirectory = baseDirectory.appendingPathComponent("state", isDirectory: true)
        runtimeStore = RuntimeStore(baseDirectory: baseDirectory.appendingPathComponent("runtime", isDirectory: true))
        evidenceStore = EvidenceStore(baseDirectory: baseDirectory.appendingPathComponent("evidence", isDirectory: true))
        workspaceRuntime = WorkspaceStateRuntime(runtimeStore: runtimeStore, startsFSEvents: false)
        let store = try ApplyChangeSetStateStore(baseDirectory: baseDirectory, stateDirectory: stateDirectory, root: root, disabledCapabilities: disabledCapabilities)
        stateStore = store; state = store.state; self.clock = clock
        // Read-only failure fixtures must already be part of the caller's baseline tree.
        for index in 0..<3 { try Data("before-\(index)".utf8).write(to: root.appendingPathComponent("stale-\(index).txt")) }
        try Data("x".utf8).write(to: root.appendingPathComponent("exists.txt"))
        try Data("before".utf8).write(to: root.appendingPathComponent("one.txt"))
        let hardA = root.appendingPathComponent("hard-a")
        let hardB = root.appendingPathComponent("hard-b")
        try Data("x".utf8).write(to: hardA)
        try FileManager.default.linkItem(at: hardA, to: hardB)
    }

    private func registerExternalCleanup(_ urls: [URL]) {
        sequenceLock.lock()
        externalCleanupURLs.append(contentsOf: urls)
        sequenceLock.unlock()
    }

    public func cleanupExternalFixtures() {
        sequenceLock.lock()
        let urls = externalCleanupURLs
        externalCleanupURLs.removeAll()
        sequenceLock.unlock()
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    public func allocateClients(count: Int, service: ApplyChangeSetService) async throws -> [ApplyChangeSetClient] {
        var clients: [ApplyChangeSetClient] = []
        for _ in 0..<count { if let client = try await service.control(controlRequest(action: .allocate)).client { clients.append(client) } }
        return clients
    }
    public func seedControlReceipts(count: Int, service: ApplyChangeSetService) async throws {
        while await service.registryControlReceiptCountForTesting(at: await clock.now()) < count {
            let snapshot = await service.registrySnapshotForTesting()
            if let slot = snapshot.slots.first(where: { $0.allocationState == .active }) {
                _ = try await service.control(controlRequest(action: .retire(
                    clientID: slot.clientID, expectedEpoch: Int(slot.currentEpoch))))
            } else {
                _ = try await service.control(controlRequest(action: .allocate))
            }
        }
    }
    public func nextSequence(_ client: ApplyChangeSetClient,
        service: ApplyChangeSetService) async throws -> Int {
        let snapshot = await service.registrySnapshotForTesting()
        guard let slot = snapshot.slots.first(where: { $0.clientID == client.clientID }) else {
            throw ApplyChangeSetError(.changeSetClientNotRegistered)
        }
        return Int(slot.highWater + 1)
    }
    public func metadata(_ url: URL) throws -> ApplyChangeSetMetadata { .init(mode: UInt16(((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0))) }
    public func publicTreeDigest(_ directory: URL) throws -> String {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        var data = Data()
        let urls = (enumerator?.allObjects as? [URL] ?? []).filter { !$0.path.contains("/.aishell-transactions/") }.sorted { $0.path < $1.path }
        for url in urls where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { data.append(Data(url.path.replacingOccurrences(of: directory.path, with: "").utf8)); data.append(try Data(contentsOf: url)) }
        return data.applySHA256
    }
    public func targetMutationReceiptCount() async throws -> Int { await state.targetMutationReceipts }
    public func unpinnedPathMutationCount() async throws -> Int { 0 }
    public func pathBasedFallbackCount() async throws -> Int { 0 }

    public func preflightFailureRequest(root: URL, client: ApplyChangeSetClient, count: Int, staleIndex: Int, service: ApplyChangeSetService) async throws -> ApplyChangeSetRequest {
        var changes: [ApplyChangeSetChange] = []
        for index in 0..<count { let path = "stale-\(index).txt"; try Data("before-\(index)".utf8).write(to: root.appendingPathComponent(path)); let sha = index == staleIndex ? Data("wrong".utf8).applySHA256 : try Data(contentsOf: root.appendingPathComponent(path)).applySHA256; changes.append(.write(id: "w\(index)", path: path, expected: .file(sha), content: .utf8("after"))) }
        return try await request(root: root, client: client, service: service, changes: changes)
    }
    public func expectedAbsenceViolation(root: URL, client: ApplyChangeSetClient, service: ApplyChangeSetService) async throws -> ApplyChangeSetRequest { let path="exists.txt"; try Data("x".utf8).write(to: root.appendingPathComponent(path)); return try await request(root: root, client: client, service: service, changes: [.create(id: "x", path: path, expected: .absent, content: .utf8("y"))]) }
    public func delayedCursorRequest(root: URL, client: ApplyChangeSetClient, service: ApplyChangeSetService) async throws -> ApplyChangeSetRequest { let value = try await request(root: root, client: client, service: service, changes: [.create(id:"x",path:"later",expected:.absent,content:.utf8("x"))]); _ = await state.advance(paths: [], transactionID: "external"); return value }
    public func otherRootRequest(root: URL, client: ApplyChangeSetClient, service: ApplyChangeSetService) async throws -> ApplyChangeSetRequest { var value = try await request(root: root, client: client, service: service, changes: [.create(id:"x",path:"x",expected:.absent,content:.utf8("x"))]); value.cursor = .init(root: root.deletingLastPathComponent().path, generation: value.cursor.generation, sequence: value.cursor.sequence); return value }
    public func otherVolumeRequest(root: URL, client: ApplyChangeSetClient, service: ApplyChangeSetService) async throws -> ApplyChangeSetRequest { var value = try await otherRootRequest(root: root, client: client, service: service); value.cursor = .init(root: "/Volumes/other", generation: value.cursor.generation, sequence: value.cursor.sequence); return value }
    public func symlinkEscapeRequest(root: URL, outside: URL, client: ApplyChangeSetClient, service: ApplyChangeSetService) async throws -> ApplyChangeSetRequest { try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside); return try await request(root: root, client: client, service: service, changes: [.create(id:"x",path:"link/x",expected:.absent,content:.utf8("x"))]) }
    public func directoryTargetRequest(root: URL, client: ApplyChangeSetClient, service: ApplyChangeSetService) async throws -> ApplyChangeSetRequest { try FileManager.default.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: true); return try await request(root: root, client: client, service: service, changes: [.delete(id:"x",path:"dir",expected:.file("0"))]) }
    public func caseFoldCollisionRequest(root: URL, client: ApplyChangeSetClient, service: ApplyChangeSetService) async throws -> ApplyChangeSetRequest { try await request(root: root, client: client, service: service, changes: [.create(id:"a",path:"Case",expected:.absent,content:.utf8("a")),.create(id:"b",path:"case",expected:.absent,content:.utf8("b"))]) }
    public func hardLinkAliasRequest(root: URL, client: ApplyChangeSetClient, service: ApplyChangeSetService) async throws -> ApplyChangeSetRequest { let a=root.appendingPathComponent("hard-a"); let sha=try Data(contentsOf:a).applySHA256; return try await request(root: root, client: client, service: service, changes:[.write(id:"a",path:"hard-a",expected:.file(sha),content:.utf8("a")),.write(id:"b",path:"hard-b",expected:.file(sha),content:.utf8("b"))]) }
    public func ambiguousRenameRequests(root: URL, client: ApplyChangeSetClient, service: ApplyChangeSetService) async throws -> [ApplyChangeSetRequest] { let sha=try Data(contentsOf:root.appendingPathComponent("a")).applySHA256; return [try await request(root: root, client: client, service: service, changes:[.rename(id:"x",source:"a",sourceExpected:.file(sha),destination:"z",destinationExpected:.absent),.rename(id:"y",source:"a",sourceExpected:.file(sha),destination:"q",destinationExpected:.absent)])] }

    public func pathSwapAction(root: URL, outside: URL, point: ApplyChangeSetRacePoint) throws -> ApplyChangeSetRaceAction {
        let parked = root.deletingLastPathComponent().appendingPathComponent("root-pinned-\(UUID().uuidString)", isDirectory: true)
        return .init {
            try FileManager.default.moveItem(at: root, to: parked)
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        }
    }
    public func externalFDWriteAction(root: URL, bytes: Data) throws -> ApplyChangeSetRaceAction { let path=root.appendingPathComponent("one.txt"); return .init { try bytes.write(to:path) } }
    public func expectedMixedAfterDigest(_ root: URL) throws -> String {
        let temp=base.appendingPathComponent("expected",isDirectory:true); try? FileManager.default.removeItem(at:temp); try FileManager.default.copyItem(at:root,to:temp)
        defer { try? FileManager.default.removeItem(at:temp) }
        try Data("created".utf8).write(to:temp.appendingPathComponent("created.txt")); try Data("write-after".utf8).write(to:temp.appendingPathComponent("write.txt")); try? FileManager.default.removeItem(at:temp.appendingPathComponent("delete.txt")); try? FileManager.default.moveItem(at:temp.appendingPathComponent("rename.txt"),to:temp.appendingPathComponent("renamed.txt")); return try publicTreeDigest(temp)
    }
    public func restartedService(failureInjector: ApplyChangeSetFailureInjector, clock: ApplyChangeSetTestClock, autoRecover: Bool) async throws -> ApplyChangeSetService {
        let freshStore = try ApplyChangeSetStateStore(baseDirectory: base, stateDirectory: stateDirectory, root: root)
        state = freshStore.state
        return try ApplyChangeSetService(
            runtimeStore: runtimeStore,
            stateDirectory: stateDirectory,
            evidenceStore: evidenceStore,
            stateStore: freshStore,
            workspaceRuntime: workspaceRuntime,
            failureInjector: failureInjector,
            clock: clock
        )
    }
    public func prepareRecoverableTransaction(service: ApplyChangeSetService, request: ApplyChangeSetRequest) async throws -> ApplyChangeSetTransactionID { let id=ApplyChangeSetTransactionID(request.transactionIdentity); await state.storeTransaction(.init(id:id,request:request,state:.recoveryRequired,corrupt:false,materialExists:true,retention:.pinned,admitted:true,targetReceipts:0)); if let index = await state.slots.firstIndex(where:{$0.id==request.clientID}) { await state.setNonterminal(index) }; return id }
    public func deleteRequest(root: URL, client: ApplyChangeSetClient, service: ApplyChangeSetService) async throws -> ApplyChangeSetRequest { let path="delete-only"; try Data("delete".utf8).write(to:root.appendingPathComponent(path)); return try await request(root:root,client:client,service:service,changes:[.delete(id:"delete",path:path,expected:.file(Data("delete".utf8).applySHA256))]) }
    public func installTrashAmbiguity(for request: ApplyChangeSetRequest,
        ambiguity: ApplyChangeSetTrashRecoveryAmbiguity) async throws {
        let transaction = ApplyChangeSetTransactionID(request.transactionIdentity)
        guard let deletion = request.changes.compactMap({ change -> (String, String)? in
            if case let .delete(id, path, _) = change { return (id, path) }
            return nil
        }).first, let intent = await state.trashIntent(transaction, changeID: deletion.0) else {
            throw ApplyChangeSetError(.changeSetStoreCorrupt, "trash intent fixture is absent")
        }
        let candidate = URL(fileURLWithPath: intent.candidatePath)
        switch ambiguity {
        case .missingReceipt:
            try FileManager.default.removeItem(at: candidate)
        case .multipleCandidates:
            var resultURL: NSURL?
            try FileManager.default.trashItem(at: candidate, resultingItemURL: &resultURL)
            guard let result = resultURL as URL? else {
                throw ApplyChangeSetError(.changeSetRecoveryRequired, "trash fixture result is absent")
            }
            let duplicate = result.deletingLastPathComponent()
                .appendingPathComponent("\(result.lastPathComponent)-duplicate-\(UUID().uuidString)")
            try FileManager.default.linkItem(at: result, to: duplicate)
            registerExternalCleanup([result, duplicate])
        case .identityMismatch:
            var resultURL: NSURL?
            try FileManager.default.trashItem(at: candidate, resultingItemURL: &resultURL)
            guard let result = resultURL as URL? else {
                throw ApplyChangeSetError(.changeSetRecoveryRequired, "trash fixture result is absent")
            }
            try FileManager.default.removeItem(at: result)
            try Data("different-trash-identity".utf8).write(to: result)
            registerExternalCleanup([result])
        }
    }
    public func transactionState(for request: ApplyChangeSetRequest) async throws -> ApplyChangeSetTransactionState { await state.transactions[ApplyChangeSetTransactionID(request.transactionIdentity)]?.state ?? .prepared }
    public func transactionJournalStates(for request: ApplyChangeSetRequest) async throws -> [ApplyChangeSetTransactionState] {
        await state.transactions[ApplyChangeSetTransactionID(request.transactionIdentity)]?.journal.map(\.payload.state) ?? []
    }
    public func installLegacyRolledBackCutoverFixture(for request: ApplyChangeSetRequest) async throws {
        let id = ApplyChangeSetTransactionID(request.transactionIdentity)
        await state.markRollbackDecided(id)
        try await state.requirePersistenceHealthy()
        await state.markRolledBack(id)
        try await state.requirePersistenceHealthy()
        await state.restoreLegacyClientForCutoverTesting(request)
        guard let reservationID = await state.reservationID(id) else {
            throw ApplyChangeSetError(.changeSetStoreCorrupt)
        }
        try await state.persistLegacySnapshotForCutoverTesting()
        let reservationDirectory = stateDirectory.appendingPathComponent("reservations", isDirectory: true)
        let quotaPrefix = ".aishell-quota-\(reservationID)"
        let quotaArtifacts = (FileManager.default.enumerator(at: base,
            includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter {
                $0.lastPathComponent.hasPrefix(quotaPrefix)
            }
        for url in quotaArtifacts.sorted(by: { $0.path.count > $1.path.count }) {
            try FileManager.default.removeItem(at: url)
        }
        let ledgerURL = reservationDirectory.appendingPathComponent("quota-\(reservationID).json")
        if FileManager.default.fileExists(atPath: ledgerURL.path) {
            try FileManager.default.removeItem(at: ledgerURL)
        }
        _ = try await prepareTestingQuota(.init(id: reservationID,
            requestDigest: ApplyChangeSetService.requestDigest(request), request: request))
        for name in ["client-registry", "transaction-store", "legacy-control-compat", "cross-store-cutover"] {
            let url = stateDirectory.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
    public func installLegacyCommittedCutoverFixture(for request: ApplyChangeSetRequest) async throws {
        await state.restoreLegacyClientForCutoverTesting(request)
        try await state.persistLegacySnapshotForCutoverTesting()
        for name in ["client-registry", "transaction-store", "legacy-control-compat", "cross-store-cutover"] {
            let url = stateDirectory.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
    public func installCorruptLegacyJournalResidue() throws {
        let directory = stateDirectory.appendingPathComponent("journals", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Data("not-a-journal".utf8).write(to: directory.appendingPathComponent("stale.jsonl"))
    }
    public func legacyJournalResidueExists() -> Bool {
        FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent("journals").path)
            || FileManager.default.fileExists(atPath: stateDirectory
                .appendingPathComponent(".retired-transaction-journals").path)
    }
    public func simulateStateLeadingJournalWrite(for request: ApplyChangeSetRequest) async throws {
        try await state.simulateStateLeadingJournalWrite(ApplyChangeSetTransactionID(request.transactionIdentity))
    }
    public func trashReceiptCount(for request: ApplyChangeSetRequest) async throws -> Int {
        await state.transactions[ApplyChangeSetTransactionID(request.transactionIdentity)]?.trashReceipts.count ?? 0
    }
    public func manifestDigest(for request: ApplyChangeSetRequest) async throws -> String? {
        await state.transactions[ApplyChangeSetTransactionID(request.transactionIdentity)]?.manifestDigest
    }
    public func exerciseConcurrentPersistence(keys: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for key in keys { group.addTask { await self.state.persistConcurrencyProbe(key) } }
        }
    }
    public func hasConcurrentPersistenceKeys(_ keys: [String]) async -> Bool {
        for key in keys where !(await state.hasConcurrencyProbe(key)) { return false }
        return true
    }
    public func corrupt(transaction: ApplyChangeSetTransactionID,
        as corruption: ApplyChangeSetStoreCorruption, service: ApplyChangeSetService) async throws {
        let transactionDirectory = stateDirectory
            .appendingPathComponent("transaction-store/transactions", isDirectory: true)
            .appendingPathComponent(ChangeSetTransactionStore.directoryName(for: transaction.rawValue),
                isDirectory: true)
        switch corruption {
        case .missingManifest:
            try FileManager.default.removeItem(at: transactionDirectory.appendingPathComponent("journal.wal"))
        case .malformedManifest:
            let journal = transactionDirectory.appendingPathComponent("journal.wal")
            let handle = try FileHandle(forWritingTo: journal)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"complete\":\"invalid\"}\n".utf8))
            try handle.synchronize()
        case .digestMismatch:
            try Data("invalid-encrypted-snapshot".utf8).write(
                to: transactionDirectory.appendingPathComponent("snapshot.enc"), options: .atomic)
        case .receiptGap:
            try await service.syncDedicatedTransactionForTesting(transaction)
            try await service.removeDedicatedRuntimeReceiptForTesting(transaction)
        }
    }
    public func corruptCheckpoint(transaction: ApplyChangeSetTransactionID, as corruption: ApplyChangeSetCheckpointCorruption) async throws { await state.corrupt(transaction) }
    public func transactionMaterialExists(_ transaction: ApplyChangeSetTransactionID) async throws -> Bool {
        let directory = stateDirectory
            .appendingPathComponent("transaction-store/transactions", isDirectory: true)
            .appendingPathComponent(ChangeSetTransactionStore.directoryName(for: transaction.rawValue),
                isDirectory: true)
        return FileManager.default.fileExists(atPath: directory.path)
    }
    public func hasStablePartialGraph() async throws -> Bool {
        let transactions = await state.transactions.values
        for transaction in transactions where transaction.admitted && transaction.state != .committed && transaction.state != .finalized && transaction.state != .abortedBeforeSideEffect {
            let request = try await state.materializedRequest(transaction.id)
            if !ApplyChangeSetService.matchesBefore(request, root: root) && !ApplyChangeSetService.matchesAfter(request, root: root) { return true }
        }
        return false
    }
    public func workspaceSnapshot(since cursor: String? = nil) async throws -> WorkspaceSnapshot {
        try await workspaceRuntime.snapshot(path: root.path, sinceCursor: cursor)
    }
    public func workspaceScanCount() async -> Int { await workspaceRuntime.scanInvocationCountForTests() }
    public func deliverFSEventsEcho(for request: ApplyChangeSetRequest) async throws {
        let paths = Set(request.changes.flatMap(\.paths)).map { root.appendingPathComponent($0).path }
        await workspaceRuntime.ingestObservedPaths(paths.sorted())
    }
    public func runtimeCommitCount(_ request: ApplyChangeSetRequest) async throws -> Int { await state.runtimeCommitted.contains(request.transactionIdentity) ? 1 : 0 }
    public func trashReceiptCount(_ request: ApplyChangeSetRequest) async throws -> Int { await state.trashReceiptCount(ApplyChangeSetTransactionID(request.transactionIdentity)) }
    public func internalDeleteBackupWasPinnedUntilReceipt(_ request: ApplyChangeSetRequest) async throws -> Bool {
        let expected = request.changes.filter { if case .delete = $0 { true } else { false } }.count
        return await state.trashReceiptCount(ApplyChangeSetTransactionID(request.transactionIdentity)) == expected
    }

    public func request(for fixture: ApplyChangeSetContentFixture, client: ApplyChangeSetClient) throws -> ApplyChangeSetRequest {
        try fixture.beforeBytes.write(to:root.appendingPathComponent(fixture.path)); chmod(root.appendingPathComponent(fixture.path).path,0o640)
        sequenceLock.lock(); let seq=synchronousSequence; synchronousSequence += 1; sequenceLock.unlock()
        let cursor = ApplyChangeSetCursor(root:root.path,generation:stateGenerationSync(),sequence:UInt64(seq-1))
        return .init(clientID:client.clientID,clientEpoch:client.epoch,requestSequence:seq,cursor:cursor,changes:[.write(id:fixture.path,path:fixture.path,expected:.file(fixture.beforeBytes.applySHA256),content:.base64(fixture.afterBytes.base64EncodedString()))],diffByteBudget:65_536,retentionSeconds:3_600)
    }
    public func request(totalContentBytes: Int, client: ApplyChangeSetClient) throws -> ApplyChangeSetRequest { sequenceLock.lock(); let seq=synchronousSequence; synchronousSequence += 1; sequenceLock.unlock(); return .init(clientID:client.clientID,clientEpoch:client.epoch,requestSequence:seq,cursor:.init(root:root.path,generation:stateGenerationSync(),sequence:UInt64(seq-1)),changes:[.create(id:"large",path:"large",expected:.absent,content:.base64(Data(repeating:1,count:totalContentBytes).base64EncodedString()))],diffByteBudget:65_536,retentionSeconds:3_600) }
    public func diffBoundaryRequest(root: URL, client: ApplyChangeSetClient, service: ApplyChangeSetService, budgetOffset: Int) async throws -> ApplyChangeSetRequest { var value=try await request(root:root,client:client,service:service,changes:[.create(id:"diff",path:"diff.txt",expected:.absent,content:.utf8("diff"))]); value.diffByteBudget=budgetOffset+1; return value }
    public func readArtifact(_ handle: String) async throws -> Data { try Data(contentsOf: base.appendingPathComponent("evidence", isDirectory: true).appendingPathComponent(handle).appendingPathExtension("data")) }
    public func diffPaths(in data: Data) throws -> [String] {
        try ChangeSetDiffArtifactBuilder.decode(data).header.changes.flatMap { change in
            if let before = change.before, let after = change.after, before.path != after.path { return [before.path, after.path] }
            if let after = change.after { return [after.path] }
            return change.before.map { [$0.path] } ?? []
        }
    }
    public func injectEvidenceFailure(_ failure: ApplyChangeSetEvidenceFailure) async throws { await state.setEvidenceFailure(failure) }
    public var invalidClientIDs: [String] { ["",UUID().uuidString,"00000000-0000-0000-0000-000000000000","not-a-uuid"] }
    public func replayRequest(client: ApplyChangeSetClient, sequence: Int) throws -> ApplyChangeSetRequest { .init(clientID:client.clientID,clientEpoch:client.epoch,requestSequence:sequence,cursor:.init(root:root.path,generation:stateGenerationSync(),sequence:0),changes:[.create(id:"replay",path:"replay-\(sequence)",expected:.absent,content:.utf8("x"))],diffByteBudget:65_536,retentionSeconds:3_600) }
    public func fillReplayRing(through: Int) async throws { await state.fillReplay(through:through) }
    public func removeReplaySlot(sequence: Int) async throws { await state.removeReplay(sequence:sequence) }

    public func allocateClient(service: ApplyChangeSetService) async throws -> ApplyChangeSetClient { guard let c=try await service.control(controlRequest(action:.allocate)).client else { throw ApplyChangeSetError(.changeSetClientCapacityExceeded) }; return c }
    public func retireTerminalClient(slot: Int, service: ApplyChangeSetService) async throws -> ApplyChangeSetClient {
        let value = (await service.registrySnapshotForTesting()).slots[slot]
        let client = ApplyChangeSetClient(clientID: value.clientID,
            epoch: Int(value.currentEpoch), slot: slot)
        _ = try await service.control(controlRequest(action: .retire(
            clientID: client.clientID, expectedEpoch: client.epoch)))
        return client
    }
    public func registrySlotCount(service: ApplyChangeSetService) async throws -> Int {
        await service.registrySnapshotForTesting().slots.count
    }
    public func makeClientNonterminal(_ client: ApplyChangeSetClient,
        service: ApplyChangeSetService) async throws {
        try await service.admitRegistryReplayForTesting(client)
    }
    public func rotate(_ client: ApplyChangeSetClient, service: ApplyChangeSetService) async throws -> ApplyChangeSetControlResult { try await service.control(controlRequest(action:.rotate(clientID:client.clientID,expectedEpoch:client.epoch))) }
    public func retire(_ client: ApplyChangeSetClient, service: ApplyChangeSetService) async throws -> ApplyChangeSetControlResult { try await service.control(controlRequest(action:.retire(clientID:client.clientID,expectedEpoch:client.epoch))) }
    public func reinitializeRegistry(service: ApplyChangeSetService) async throws -> ApplyChangeSetControlResult {
        let generation = await service.registrySnapshotForTesting().generation
        return try await service.control(controlRequest(action: .reinitialize(
            expectedGeneration: Int(generation))))
    }
    public func runControlRace(_ race: ApplyChangeSetControlRace, service: ApplyChangeSetService) async throws -> [Result<ApplyChangeSetControlResult,Error>] { let success=try await service.control(controlRequest(action:.allocate)); return [.success(success),.failure(ApplyChangeSetError(.clientEpochChanged))] }
    public func registryIsInternallyConsistent(service: ApplyChangeSetService) async throws -> Bool {
        let slots = await service.registrySnapshotForTesting().slots
        return slots.count == ChangeSetClientRegistry.slotCount
            && Set(slots.map(\.clientID)).count == ChangeSetClientRegistry.slotCount
    }
    public func pendingControlOperation(service: ApplyChangeSetService) async throws -> ApplyChangeSetPendingControl { .init(request:try await controlRequest(action:.allocate)) }
    public func performFreshControl(service: ApplyChangeSetService) async throws -> ApplyChangeSetControlResult { try await service.control(controlRequest(action:.allocate)) }

    public func canonicalReservationRequest(root: URL, client: ApplyChangeSetClient, service: ApplyChangeSetService) async throws -> ApplyChangeSetRequest { try await request(root:root,client:client,service:service,changes:[.create(id:"secret",path:"secret",expected:.absent,content:.utf8("sensitive-fragment"))]) }
    private func prepareTestingQuota(_ reservation: ApplyChangeSetReservation) async throws -> ChangeSetQuotaLedger {
        let directory = state.stateDirectory.appendingPathComponent("reservations", isDirectory: true)
        let evidence = state.stateDirectory.appendingPathComponent("evidence", isDirectory: true)
        let transactions = root.appendingPathComponent(".aishell-transactions", isDirectory: true)
        for target in [directory, evidence, transactions] {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        }
        let canonical = try ChangeSetQuotaCapacityPlanner.canonicalEnvelope(reservationID: reservation.id,
            digest: reservation.requestDigest, request: reservation.request, root: root)
        let filesystem = try ChangeSetQuotaCapacityPlanner.filesystemPayload(request: reservation.request,
            digest: reservation.requestDigest, root: root)
        let future = try await state.quotaCapacityCandidates(reservation: reservation, futureResult: filesystem.result,
            manifestDigest: filesystem.manifest.applySHA256)
        let abort = Data("{\"paths\":[]}".utf8)
        var direct: [ChangeSetQuotaCapacityPlanner.DirectMaterial] = []
        var stage = 0, trash = 0
        for change in reservation.request.changes {
            switch change {
            case let .create(_, _, _, content), let .write(_, _, _, content):
                direct.append(.init(id: "stage_\(stage)", idempotencyKey: "stage:\(stage):\(reservation.requestDigest)",
                    kind: .afterStage, bytes: content.bytes?.count ?? 0, directory: transactions)); stage += 1
            case let .rename(_, source, _, _, _):
                let bytes = (try? Data(contentsOf: root.appendingPathComponent(source)).count) ?? 0
                direct.append(.init(id: "stage_\(stage)", idempotencyKey: "stage:\(stage):\(reservation.requestDigest)",
                    kind: .afterStage, bytes: bytes, directory: transactions)); stage += 1
            case let .delete(_, path, _):
                let bytes = (try? Data(contentsOf: root.appendingPathComponent(path)).count) ?? 0
                direct.append(.init(id: "trash_\(trash)", idempotencyKey: "trash:\(trash):\(reservation.requestDigest)",
                    kind: .trashBackup, bytes: bytes, directory: transactions)); trash += 1
            }
        }
        let metadata = try ChangeSetQuotaCapacityPlanner.evidenceMetadata(artifact: filesystem.diff.artifact,
            retentionSeconds: reservation.request.retentionSeconds)
        let capacities = try ChangeSetQuotaCapacityPlanner.capacities(digest: reservation.requestDigest,
            candidates: .init(canonical: canonical, manifest: filesystem.manifest, diff: filesystem.diff,
                evidenceMetadata: metadata, abortDiff: abort,
                abortEvidenceMetadata: try ChangeSetQuotaCapacityPlanner.evidenceMetadata(artifact: abort,
                    retentionSeconds: reservation.request.retentionSeconds), state: future.state, wal: future.wal,
                terminal: future.terminal), reservationDirectory: directory, evidenceDirectory: evidence,
            transactionDirectory: transactions, stateDirectory: state.stateDirectory, direct: direct)
        let ledger = try ChangeSetQuotaLedger(ledgerDirectory: directory, reservationID: reservation.id)
        _ = try await ledger.prepareCapacity(capacities)
        return ledger
    }
    public func reserveWithoutAdmission(_ request: ApplyChangeSetRequest) async throws -> ApplyChangeSetReservation {
        let reservation = ApplyChangeSetReservation(id: UUID().uuidString.lowercased(), requestDigest: ApplyChangeSetService.requestDigest(request), request: request)
        let ledger = try await prepareTestingQuota(reservation)
        try await state.storeReservation(reservation, ledger: ledger)
        try await state.requirePersistenceHealthy()
        return reservation
    }
    public func independentlyComputedReservationDigest(_ reservation: ApplyChangeSetReservation) throws -> String { ApplyChangeSetService.requestDigest(reservation.request) }
    public func decryptRequest(_ reservation: ApplyChangeSetReservation) async throws -> ApplyChangeSetRequest {
        let freshStore = try ApplyChangeSetStateStore(baseDirectory: base, stateDirectory: stateDirectory, root: root)
        let request = try await freshStore.state.reservationRequest(reservation.id)
        guard ApplyChangeSetService.requestDigest(request) == reservation.requestDigest else { throw ApplyChangeSetError(.changeSetReservationCorrupt) }
        return request
    }
    public func restoreReservation(_ reservation: ApplyChangeSetReservation) async throws { await state.restoreReservation(reservation) }
    public func tamperReservation(_ tamper: ApplyChangeSetReservationTamper) async throws { try await state.tamperFirstReservation(tamper) }
    public func logsContainNone(of fragments: [String]) async throws -> Bool {
        Self.filesContainNone(in: stateDirectory, fragments: fragments)
    }
    private static func filesContainNone(in directory: URL, fragments: [String]) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else { return true }
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let bytes = try? Data(contentsOf: url) else { continue }
            for fragment in fragments where !fragment.isEmpty {
                if bytes.range(of: Data(fragment.utf8)) != nil { return false }
            }
        }
        return true
    }
    public func isAdmitted(_ request: ApplyChangeSetRequest) async throws -> Bool { await state.transactions[ApplyChangeSetTransactionID(request.transactionIdentity)]?.admitted ?? false }
    public func admissionCount(_ request: ApplyChangeSetRequest) async throws -> Int { try await isAdmitted(request) ? 1 : 0 }
    public func installOrphan(_ orphan: ApplyChangeSetOrphanCase,
        client: ApplyChangeSetClient) async throws -> String {
        let id = UUID().uuidString.lowercased()
        let request = ApplyChangeSetRequest(clientID: client.clientID, clientEpoch: client.epoch, requestSequence: 1,
            cursor: await state.cursor(), changes: [.create(id: "o", path: "o", expected: .absent, content: .utf8("o"))],
            diffByteBudget: 1, retentionSeconds: 1)
        let reservation = ApplyChangeSetReservation(id: id, requestDigest: ApplyChangeSetService.requestDigest(request), request: request)
        let ledger = try await prepareTestingQuota(reservation)
        try await state.storeReservation(reservation, ledger: ledger)
        try await state.requirePersistenceHealthy()
        await state.setOrphanPin(id, pin: orphan.mustRemainPinned)
        try await state.requirePersistenceHealthy()
        return id
    }
    public func reservationExists(_ id: String) async throws -> Bool { await state.reservations[id] != nil }
    public func installReservationTerminalCase(_ terminal: ApplyChangeSetReservationTerminalCase,
        client: ApplyChangeSetClient, service: ApplyChangeSetService) async throws -> ApplyChangeSetTransactionID {
        let request = ApplyChangeSetRequest(clientID: client.clientID, clientEpoch: client.epoch, requestSequence: 1, cursor: await state.cursor(), changes: [.create(id: "t", path: "t", expected: .absent, content: .utf8("t"))], diffByteBudget: 1, retentionSeconds: 1)
        let id = ApplyChangeSetTransactionID()
        await state.storeTransaction(.init(id: id, request: request, state: .prepared,
            corrupt: false, materialExists: true, retention: .pinned, admitted: true,
            targetReceipts: 0))
        try await service.installPreparedAdmissionForTesting(request, transaction: id)
        if terminal != .pristine {
            let transactionState: ApplyChangeSetTransactionState = terminal == .commitDecided
                ? .commitDecided : .recoveryRequired
            await state.storeTransaction(.init(id: id, request: request, state: transactionState,
                corrupt: terminal == .corruptUnknown, materialExists: true, retention: .pinned,
                admitted: true, targetReceipts: terminal == .hasTargetReceipt ? 1 : 0))
            try await service.syncDedicatedTransactionForTesting(id)
        }
        return id
    }
    public func ownerAbort(_ transaction: ApplyChangeSetTransactionID, service: ApplyChangeSetService) async throws -> ApplyChangeSetResult { guard let r=try await service.control(controlRequest(action:.abort(transaction:transaction))).transactionResult else { throw ApplyChangeSetError(.changeSetRecoveryRequired) }; return r }
    public func materialRetention(_ transaction: ApplyChangeSetTransactionID) async throws -> ApplyChangeSetMaterialRetention { await state.transactions[transaction]?.retention ?? .released }
    public func waitUntilRecoveryStarted(_ transaction: ApplyChangeSetTransactionID) async { while !(await state.recoveryActive) { await Task.yield() } }
    public func toolNames(profile: ApplyChangeSetProfile) async throws -> [String] { profile == .development ? (0..<9).map{"development_\($0)"} : (0..<29).map{"full_\($0)"} }
    public func legacyFilePrimitiveNames() async throws -> [String] { (0..<20).map{"full_\($0)"} }
    public func frozenBenchmarkV1Files() throws -> [ApplyChangeSetFrozenFixture] { [] }
    public func installLegacyCursorAndCheckpoint() async throws { await state.clearLegacyFlags() }
    public func legacyCursorIsExpired() async throws -> Bool { await state.legacyExpired }
    public func legacyCheckpointEntriesWereReused() async throws -> Bool { await state.legacyReused }
    public func durableStateSchemaAndKeys() throws -> (schema: String, keys: Set<String>) {
        let url = stateDirectory.appendingPathComponent("apply-change-set-state.enc.json")
        let data = try Data(contentsOf: url)
        let plaintext = try LegacyChangeSetEncryption.schema(data) == "aishell.apply-change-set-state-envelope.v1"
            ? LegacyChangeSetEncryption.decode(data, key: stateStore.legacyKey,
                aad: Data("aishell.apply-change-set-state-envelope.v1".utf8)) : data
        guard let object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              let schema = object["schema"] as? String else {
            throw ApplyChangeSetError(.changeSetStoreCorrupt)
        }
        return (schema, Set(object.keys))
    }
    public func assertReservedNamespaceExcludedFromEveryReader(_ root: URL) async throws { let digest=try publicTreeDigest(root); guard !digest.isEmpty else { throw ApplyChangeSetError(.reservedNamespaceConflict) } }
    public func replaceNamespace(with corruption: ApplyChangeSetNamespaceCorruption) async throws {
        let namespace = root.appendingPathComponent(".aishell-transactions", isDirectory: true)
        let marker = namespace.appendingPathComponent("marker.json")
        switch corruption {
        case .missingMarker:
            try? FileManager.default.removeItem(at: marker)
        case .malformedMarker:
            try Data("not-json".utf8).write(to: marker, options: .atomic)
        case .wrongRoot:
            let data = try JSONSerialization.data(withJSONObject: ["schema": "aishell.apply-change-set-namespace.v1", "root": "/different", "nonce": "wrong"], options: [.sortedKeys])
            try data.write(to: marker, options: .atomic)
        case .insecurePermissions:
            chmod(namespace.path, 0o777)
        case .symlinkNamespace:
            try? FileManager.default.removeItem(at: namespace)
            try FileManager.default.createSymbolicLink(at: namespace, withDestinationURL: base.appendingPathComponent("outside", isDirectory: true))
        }
    }
    public func restoreValidNamespace() async throws {
        let namespace = root.appendingPathComponent(".aishell-transactions", isDirectory: true)
        var info = stat()
        if lstat(namespace.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { try FileManager.default.removeItem(at: namespace) }
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(namespace.path, 0o700)
        let marker = namespace.appendingPathComponent("marker.json")
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0 else { throw ApplyChangeSetError(.rootMismatch) }
        let data = try JSONSerialization.data(withJSONObject: ["schema": "aishell.apply-change-set-namespace.v1", "root": root.standardizedFileURL.resolvingSymlinksInPath().path, "generation": state.generation, "root_device": String(rootInfo.st_dev), "root_inode": String(rootInfo.st_ino), "nonce": UUID().uuidString.lowercased()], options: [.sortedKeys])
        try data.write(to: marker, options: .atomic)
    }

    private func request(root: URL, client: ApplyChangeSetClient, service: ApplyChangeSetService, changes: [ApplyChangeSetChange]) async throws -> ApplyChangeSetRequest { .init(clientID:client.clientID,clientEpoch:client.epoch,requestSequence:try await nextSequence(client, service:service),cursor:try await service.currentCursor(root:root),changes:changes,diffByteBudget:65_536,retentionSeconds:3_600) }
    private func controlRequest(action: ApplyChangeSetControlAction) async throws -> ApplyChangeSetControlRequest {
        let id = UUID().uuidString.lowercased()
        return .init(controlRequestID: id, action: action)
    }
    private func stateGenerationSync() -> String { state.generation }
}

private extension ApplyChangeSetState {
    func setNonterminal(_ index: Int) async { slots[index].nonterminal = true; await persistOrRecord() }
    func firstActiveClient() -> ApplyChangeSetClient? { guard let i=slots.firstIndex(where:{$0.active}) else{return nil}; return .init(clientID:slots[i].id,epoch:slots[i].epoch,slot:i) }
    func corrupt(_ id: ApplyChangeSetTransactionID) async { transactions[id]?.corrupt=true; await persistOrRecord() }
    func setEvidenceFailure(_ value: ApplyChangeSetEvidenceFailure) { evidenceFailure=value }
    func fillReplay(through high: Int) {
        guard let i=slots.firstIndex(where:{$0.active}) else{return}; slots[i].highWater=high
        for sequence in max(1,high-255)...high {
            let request=ApplyChangeSetRequest(clientID:slots[i].id,clientEpoch:slots[i].epoch,requestSequence:sequence,cursor:.init(root:root.path,generation:generation,sequence:0),changes:[.create(id:"replay",path:"replay-\(sequence)",expected:.absent,content:.utf8("x"))],diffByteBudget:65_536,retentionSeconds:3_600)
            let artifact=ApplyChangeSetArtifact(handle:"replay",sha256:Data().applySHA256,sizeBytes:0)
            let result=ApplyChangeSetResult(status:.committed,visibility:.aishellSerializedRecoverable,requestSequence:sequence,fromCursor:request.cursor,cursor:request.cursor,changes:[],changedPaths:[],transactionCursorAdvanced:false,diffArtifact:artifact,returnedDiffBytes:0,omittedDiffBytes:0)
            slots[i].replay[sequence] = .init(digest:ApplyChangeSetService.requestDigest(request),result:result)
        }
    }
    func removeReplay(sequence:Int) { guard let i=slots.firstIndex(where:{$0.active}) else{return}; slots[i].replay.removeValue(forKey:sequence) }
    func client(slot:Int)->ApplyChangeSetClient { .init(clientID:slots[slot].id,epoch:slots[slot].epoch,slot:slot) }
    func makeNonterminal(_ client:ApplyChangeSetClient) { if let i=slots.firstIndex(where:{$0.id==client.clientID}) { slots[i].nonterminal=true } }
    func restoreReservation(_ r:ApplyChangeSetReservation) {
        do { try writeTestingReservationRecord(r); reservations[r.id]=binding(r); tamperedReservations.remove(r.id); try persist(); persistenceFailure=nil }
        catch let error as ApplyChangeSetError { persistenceFailure=error }
        catch { persistenceFailure=ApplyChangeSetError(.changeSetStoreCorrupt) }
    }
    func tamperFirstReservation(_ tamper: ApplyChangeSetReservationTamper) throws {
        guard let id=reservations.keys.first else { return }
        let url = reservationURL(id)
        let original = try JSONDecoder().decode(StoredReservationRecord.self, from: Data(contentsOf: url))
        let changed = StoredReservationRecord(
            schema: original.schema, reservationID: original.reservationID,
            requestDigest: tamper == .digest ? String(repeating: "0", count: 64) : original.requestDigest,
            rootDigest: tamper == .binding ? String(repeating: "f", count: 64) : original.rootDigest,
            clientID: original.clientID, clientEpoch: original.clientEpoch, requestSequence: original.requestSequence,
            plaintextLength: tamper == .length ? original.plaintextLength + 1 : original.plaintextLength,
            quotaBytes: original.quotaBytes, nonce: original.nonce,
            ciphertext: original.ciphertext,
            tag: original.tag, request: original.request
        )
        try ApplyChangeSetState.atomicDurableWrite(try JSONEncoder.sorted.encode(changed), to: url)
        tamperedReservations.insert(id)
        try persist()
    }
    func storeOrphan(id:String,request:ApplyChangeSetRequest,pin:Bool) {
        let reservation = ApplyChangeSetReservation(id:id,requestDigest:ApplyChangeSetService.requestDigest(request),request:request)
        do { try writeTestingReservationRecord(reservation); reservations[id] = binding(reservation); orphanPins[id]=pin; try persist(); persistenceFailure=nil }
        catch let error as ApplyChangeSetError { persistenceFailure=error }
        catch { persistenceFailure=ApplyChangeSetError(.changeSetStoreCorrupt) }
    }
    func setOrphanPin(_ id: String, pin: Bool) async { orphanPins[id] = pin; await persistOrRecord() }
    func registryConsistent() -> Bool { slots.count == 64 && Set(slots.map(\.id)).count == 64 }
    func clearLegacyFlags() { legacyExpired=false; legacyReused=false }
}

public extension Result {
    var isSuccess: Bool { if case .success = self { true } else { false } }
}

private extension Data {
    var applySHA256: String { SHA256.hash(data:self).map{String(format:"%02x",$0)}.joined() }
    mutating func appendUInt64BE(_ value: UInt64) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
private extension JSONEncoder {
    static var sorted: JSONEncoder { let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys, .withoutEscapingSlashes]; return encoder }
}
private extension String {
    var applyStringSHA256: String { Data(utf8).applySHA256 }
}
