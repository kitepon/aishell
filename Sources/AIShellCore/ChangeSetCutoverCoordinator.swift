import CryptoKit
import Darwin
import Foundation

public protocol ChangeSetCutoverCompatibilityPreparing: Sendable {
    func prepareLegacyCompatibility(sourceDigest: String, payloadDigest: String) async throws
    func validateLegacyCompatibility(sourceDigest: String, payloadDigest: String) async throws
}

public struct ChangeSetCutoverCursorBinding: Codable, Equatable, Sendable {
    public let root: String
    public let generation: String

    public init(root: String, generation: String) {
        self.root = root
        self.generation = generation
    }
}

public struct ChangeSetCutoverLegacySnapshot: Sendable {
    public let sourceDigest: String
    /// 旧snapshotから時刻依存retentionを導出した固定時刻。再開時もprogress markerから同じ値を使う。
    public let preparedAt: Date
    public let cursorBinding: ChangeSetCutoverCursorBinding
    public let registry: ChangeSetLegacyRegistrySnapshot
    public let transactions: [ChangeSetTransactionStore.Snapshot]
    public let runtimeReceipts: [ChangeSetTransactionStore.RuntimeReceipt]

    public init(
        sourceDigest: String,
        preparedAt: Date,
        cursorBinding: ChangeSetCutoverCursorBinding,
        registry: ChangeSetLegacyRegistrySnapshot,
        transactions: [ChangeSetTransactionStore.Snapshot],
        runtimeReceipts: [ChangeSetTransactionStore.RuntimeReceipt]
    ) {
        self.sourceDigest = sourceDigest
        self.preparedAt = preparedAt
        self.cursorBinding = cursorBinding
        self.registry = registry
        self.transactions = transactions
        self.runtimeReceipts = runtimeReceipts
    }
}

public enum ChangeSetCutoverPhase: String, Codable, Equatable, Sendable {
    case prepared
    case compatibilityPrepared = "compatibility_prepared"
    case registryImported = "registry_imported"
    case transactionsImported = "transactions_imported"
    case crossValidated = "cross_validated"
}

public enum ChangeSetCutoverStatus: Equatable, Sendable {
    case notStarted
    case inProgress(phase: ChangeSetCutoverPhase, sourceDigest: String)
    case complete(sourceDigest: String)
    /// complete markerと全storeを同一manifestに対して今この起動で照合した結果だけが公開を許可する。
    case validated(sourceDigest: String, manifestDigest: String)

    public var permitsDedicatedStorePublication: Bool {
        if case .validated = self { return true }
        return false
    }
}

public enum ChangeSetCutoverCrashPoint: String, Equatable, Sendable {
    case prepared
    case compatibilityPrepared = "compatibility_prepared"
    case registryImported = "registry_imported"
    case transactionsImported = "transactions_imported"
    case crossValidated = "cross_validated"
    case completeMarker = "complete_marker"
}

public struct ChangeSetCutoverSimulatedCrash: Error, Equatable, Sendable {
    public let point: ChangeSetCutoverCrashPoint
    public init(point: ChangeSetCutoverCrashPoint) { self.point = point }
}

public struct ChangeSetCutoverError: Error, Equatable, Sendable {
    public enum Code: String, Sendable {
        case invalidKey = "CHANGE_SET_CUTOVER_INVALID_KEY"
        case invalidSource = "CHANGE_SET_CUTOVER_INVALID_SOURCE"
        case sourceConflict = "CHANGE_SET_CUTOVER_SOURCE_CONFLICT"
        case stateCorrupt = "CHANGE_SET_CUTOVER_STATE_CORRUPT"
        case crossValidationFailed = "CHANGE_SET_CUTOVER_CROSS_VALIDATION_FAILED"
        case io = "CHANGE_SET_CUTOVER_IO"
    }

    public let code: Code
    public let message: String

    public init(_ code: Code, _ message: String = "") {
        self.code = code
        self.message = message
    }
}

/// 旧monolithic snapshotから専用store群への切替を、一つの公開gateとして永続化する。
/// state/complete markerはいずれもAEAD認証され、complete markerがdurableになるまで
/// callerは旧snapshotをread-onlyで保持し、専用storeを公開してはならない。
public actor ChangeSetCutoverCoordinator {
    private static let maximumRecordBytes = 16 * 1_024 * 1_024
    private static let maximumManifestPlaintextBytes = 64 * 1_024
    private static let maximumReplayCount = ChangeSetClientRegistry.slotCount * ChangeSetClientRegistry.replayCapacity
    private static let maximumTransactionCount = ChangeSetClientRegistry.slotCount * ChangeSetClientRegistry.replayCapacity
    private static let maximumRuntimeReceiptCount = ChangeSetClientRegistry.slotCount * ChangeSetClientRegistry.replayCapacity
    private static let maximumReferencesPerTransaction = 4_096
    private static let maximumPathsPerReceipt = 4_096
    private static let maximumPathBytes = 4_096
    private static let maximumIdentifierBytes = 4_096

    private struct ManifestPayload: Codable {
        let preparedAt: Date
        let cursorBinding: ChangeSetCutoverCursorBinding
        let replay: [ReplayExpectation]
        let transactions: [TransactionExpectation]
        let runtimeReceipts: [RuntimeReceiptExpectation]
    }

    private struct ReplayExpectation: Codable, Equatable {
        let clientID: String
        let epoch: UInt64
        let slotIndex: Int
        let sequence: UInt64
        let requestDigest: String
        let transactionID: String
        let state: ChangeSetReplayState
        let terminalResponseDigest: String?
        let artifactHandle: String?
        let artifactExpiresAt: Date?
        let retentionExpiresAt: Date?
    }

    private struct TransactionExpectation: Codable, Equatable {
        let transactionID: String
        let state: ApplyChangeSetTransactionState
        let terminalAt: Date?
        let retentionExpiresAt: Date?
        let manifestDigest: String
        let references: [ChangeSetTransactionStore.Reference]
        let referenceDigest: String
        let artifactDigests: [String]
        let payloadDigest: String
        let revision: UInt64
    }

    private struct RuntimeReceiptExpectation: Codable, Equatable {
        let transactionID: String
        let cursor: ApplyChangeSetCursor
        let pathsDigest: String
        let digest: String
        let recordedAt: Date
        let terminalAt: Date?
    }

    /// 旧snapshot全体はpayloadDigestだけへ束縛し、永続manifest自体は固定小サイズに保つ。
    /// 初回import時のfull expectationsは、認証済みlegacy sourceからメモリ上で再生成する。
    private struct ValidationManifest: Codable, Equatable {
        let schema: String
        let sourceDigest: String
        let payloadDigest: String
        let preparedAt: Date
        let cursorBinding: ChangeSetCutoverCursorBinding
    }

    private struct Progress: Codable, Equatable {
        let schema: String
        let sourceDigest: String
        let payloadDigest: String
        let manifestDigest: String
        let phase: ChangeSetCutoverPhase
        let preparedAt: Date
    }

    private struct Completion: Codable, Equatable {
        let schema: String
        let sourceDigest: String
        let payloadDigest: String
        let manifestDigest: String
        let registryImportReceipt: ChangeSetLegacyImportReceipt
        let transactionImportReceipt: ChangeSetTransactionStore.LegacyImportReceipt
        let preparedAt: Date
        let completedAt: Date
    }

    private struct Envelope: Codable {
        let schema: String
        let nonce: Data
        let ciphertext: Data
        let tag: Data
    }

    private let directory: URL
    private let registry: ChangeSetClientRegistry
    private let transactionStore: ChangeSetTransactionStore
    private let compatibility: any ChangeSetCutoverCompatibilityPreparing
    private let key: SymmetricKey
    private let now: @Sendable () -> Date
    private let crashAfter: ChangeSetCutoverCrashPoint?
    private let recordOpenedHook: (@Sendable (URL) -> Void)?

    public init(
        directory: URL,
        encryptionKey: Data,
        registry: ChangeSetClientRegistry,
        transactionStore: ChangeSetTransactionStore,
        compatibility: any ChangeSetCutoverCompatibilityPreparing,
        now: @escaping @Sendable () -> Date = { Date() },
        crashAfter: ChangeSetCutoverCrashPoint? = nil,
        recordOpenedHook: (@Sendable (URL) -> Void)? = nil
    ) throws {
        guard encryptionKey.count >= 32 else { throw ChangeSetCutoverError(.invalidKey) }
        self.directory = directory.standardizedFileURL
        self.registry = registry
        self.transactionStore = transactionStore
        self.compatibility = compatibility
        self.key = SymmetricKey(data: Data(SHA256.hash(data: encryptionKey)))
        self.now = now
        self.crashAfter = crashAfter
        self.recordOpenedHook = recordOpenedHook
        try Self.prepareOwnerOnlyDirectory(self.directory)
    }

    public func status() throws -> ChangeSetCutoverStatus {
        if let complete: Completion = try readRecord(at: completeURL) {
            try validate(complete)
            guard let manifest: ValidationManifest = try readRecord(at: manifestURL) else {
                throw ChangeSetCutoverError(.stateCorrupt, "completion lacks validation manifest")
            }
            try requireManifestBinding(manifest, complete: complete)
            return .complete(sourceDigest: complete.sourceDigest)
        }
        if let progress: Progress = try readRecord(at: progressURL) {
            try validate(progress)
            guard let manifest: ValidationManifest = try readRecord(at: manifestURL) else {
                throw ChangeSetCutoverError(.stateCorrupt, "progress lacks validation manifest")
            }
            try requireManifestBinding(manifest, progress: progress)
            return .inProgress(phase: progress.phase, sourceDigest: progress.sourceDigest)
        }
        if let manifest: ValidationManifest = try readRecord(at: manifestURL) {
            try validate(manifest)
            return .inProgress(phase: .prepared, sourceDigest: manifest.sourceDigest)
        }
        return .notStarted
    }

    /// legacy exportを再生成する前に呼び、時刻依存retentionを最初のsnapshotと同じ基準へ固定する。
    /// nilならcallerが現在時刻を一度選び、その値をChangeSetCutoverLegacySnapshotへ入れる。
    public func preparationDate() throws -> Date? {
        if let complete: Completion = try readRecord(at: completeURL) {
            try validate(complete)
            guard let manifest: ValidationManifest = try readRecord(at: manifestURL) else {
                throw ChangeSetCutoverError(.stateCorrupt, "completion lacks validation manifest")
            }
            try requireManifestBinding(manifest, complete: complete)
            return complete.preparedAt
        }
        if let progress: Progress = try readRecord(at: progressURL) {
            try validate(progress)
            guard let manifest: ValidationManifest = try readRecord(at: manifestURL) else {
                throw ChangeSetCutoverError(.stateCorrupt, "progress lacks validation manifest")
            }
            try requireManifestBinding(manifest, progress: progress)
            return progress.preparedAt
        }
        if let manifest: ValidationManifest = try readRecord(at: manifestURL) {
            try validate(manifest)
            return manifest.preparedAt
        }
        return nil
    }

    /// complete markerだけでは公開を許可しない。認証済manifestをcompat/registry/transactionへ
    /// 毎起動照合し、この呼び出しが成功した時だけvalidated statusを返す。
    public func validateForPublication(at instant: Date? = nil) async throws -> ChangeSetCutoverStatus {
        guard let complete: Completion = try readRecord(at: completeURL),
              let manifest: ValidationManifest = try readRecord(at: manifestURL) else {
            throw ChangeSetCutoverError(.crossValidationFailed, "cutover is not complete")
        }
        try validate(complete)
        try requireManifestBinding(manifest, complete: complete)
        let manifestDigest = complete.manifestDigest
        try await compatibility.validateLegacyCompatibility(
            sourceDigest: manifest.sourceDigest,
            payloadDigest: manifest.payloadDigest
        )
        guard await registry.legacyImportReceipt() == complete.registryImportReceipt,
              try await transactionStore.legacyImportReceipt() == complete.transactionImportReceipt else {
            throw ChangeSetCutoverError(.stateCorrupt, "dedicated-store import provenance changed")
        }
        try await crossValidate(manifest, importedPayload: nil, at: instant ?? now())
        return .validated(sourceDigest: complete.sourceDigest, manifestDigest: manifestDigest)
    }

    /// completeを返した時だけ新store群をpublic surfaceへ接続できる。
    /// 中断中は常に同一source snapshotを渡す必要があり、異なるdigest/payloadは拒否する。
    @discardableResult
    public func run(_ unnormalizedSource: ChangeSetCutoverLegacySnapshot) async throws -> ChangeSetCutoverStatus {
        if let complete: Completion = try readRecord(at: completeURL) {
            try validate(complete)
            try removeProgressAfterCompletion()
            return try await validateForPublication(at: now())
        }
        let source = try normalizedSource(unnormalizedSource)
        let identity = try sourceIdentity(source)
        let expectedManifest = try validationManifest(source, identity: identity)
        let expectedManifestDigest = Self.sha256(try Self.encode(expectedManifest))
        let manifest: ValidationManifest
        if let existing: ValidationManifest = try readRecord(at: manifestURL) {
            try validate(existing)
            guard existing == expectedManifest else {
                throw ChangeSetCutoverError(.sourceConflict, "cutover manifest differs from the prepared legacy snapshot")
            }
            manifest = existing
        } else {
            try writeRecord(expectedManifest, to: manifestURL)
            manifest = expectedManifest
        }
        var progress: Progress
        if let existing: Progress = try readRecord(at: progressURL) {
            try validate(existing)
            try requireSameSource(identity, sourceDigest: existing.sourceDigest, payloadDigest: existing.payloadDigest)
            guard existing.manifestDigest == expectedManifestDigest else {
                throw ChangeSetCutoverError(.sourceConflict, "progress manifest digest mismatch")
            }
            progress = existing
        } else {
            progress = Progress(
                schema: "aishell.change-set-cutover-progress.v1",
                sourceDigest: identity.sourceDigest,
                payloadDigest: identity.payloadDigest,
                manifestDigest: expectedManifestDigest,
                phase: .prepared,
                preparedAt: source.preparedAt
            )
            try writeRecord(progress, to: progressURL)
            try crashIfRequested(.prepared)
        }

        if progress.phase == .prepared {
            try await compatibility.prepareLegacyCompatibility(
                sourceDigest: identity.sourceDigest,
                payloadDigest: identity.payloadDigest
            )
            try crashIfRequested(.compatibilityPrepared)
            progress = try advancing(progress, to: .compatibilityPrepared)
        }

        if progress.phase == .compatibilityPrepared {
            _ = try await registry.initializeFromLegacy(legacySnapshot: source.registry)
            try crashIfRequested(.registryImported)
            progress = try advancing(progress, to: .registryImported)
        }

        if progress.phase == .registryImported {
            try await transactionStore.importLegacy(
                source.transactions,
                receipts: source.runtimeReceipts,
                provenance: identity.sourceDigest
            )
            try crashIfRequested(.transactionsImported)
            progress = try advancing(progress, to: .transactionsImported)
        }

        if progress.phase == .transactionsImported {
            try await compatibility.validateLegacyCompatibility(
                sourceDigest: identity.sourceDigest,
                payloadDigest: identity.payloadDigest
            )
            try await crossValidate(
                manifest,
                importedPayload: try manifestPayload(source),
                at: now()
            )
            try crashIfRequested(.crossValidated)
            progress = try advancing(progress, to: .crossValidated)
        }

        guard progress.phase == .crossValidated else {
            throw ChangeSetCutoverError(.stateCorrupt, "unknown cutover phase")
        }
        guard let registryImportReceipt = await registry.legacyImportReceipt(),
              let transactionImportReceipt = try await transactionStore.legacyImportReceipt() else {
            throw ChangeSetCutoverError(.stateCorrupt, "dedicated-store import receipt is missing")
        }
        let complete = Completion(
            schema: "aishell.change-set-cutover-complete.v1",
            sourceDigest: progress.sourceDigest,
            payloadDigest: progress.payloadDigest,
            manifestDigest: progress.manifestDigest,
            registryImportReceipt: registryImportReceipt,
            transactionImportReceipt: transactionImportReceipt,
            preparedAt: progress.preparedAt,
            completedAt: max(now(), progress.preparedAt)
        )
        try writeRecord(complete, to: completeURL)
        try crashIfRequested(.completeMarker)
        try removeProgressAfterCompletion()
        return try await validateForPublication(at: now())
    }

    private func advancing(_ progress: Progress, to phase: ChangeSetCutoverPhase) throws -> Progress {
        let next = Progress(
            schema: progress.schema,
            sourceDigest: progress.sourceDigest,
            payloadDigest: progress.payloadDigest,
            manifestDigest: progress.manifestDigest,
            phase: phase,
            preparedAt: progress.preparedAt
        )
        try writeRecord(next, to: progressURL)
        return next
    }

    private func crossValidate(
        _ manifest: ValidationManifest,
        importedPayload: ManifestPayload?,
        at instant: Date
    ) async throws {
        let actualReplay = await registry.replayReferences()
        let registrySnapshot = await registry.snapshot()
        let actualReplayExpectations = actualReplay.map(replayExpectation)
        let actualTransactions = try await transactionStore.listReferences(now: instant)
        let actualByID = Dictionary(uniqueKeysWithValues: actualTransactions.map { ($0.transactionID.rawValue, $0) })
        let storedReceipts = try await transactionStore.runtimeReceipts()
        let actualReceipts = try storedReceipts.map(runtimeReceiptExpectation)
            .sorted { $0.transactionID < $1.transactionID }
        guard actualReceipts.allSatisfy({
            $0.cursor.root == manifest.cursorBinding.root
                && $0.cursor.generation == manifest.cursorBinding.generation
        }) else {
            throw validationFailure("runtime receipt cursor root/generation binding mismatch")
        }
        let replayByTransaction = Dictionary(grouping: actualReplayExpectations, by: \.transactionID)
        guard replayByTransaction.values.allSatisfy({ $0.count == 1 }) else {
            throw validationFailure("a transaction has duplicate replay/tombstone references")
        }
        if let importedPayload {
            try validateImportedReplayInvalidations(
                importedPayload,
                actualReplay: actualReplayExpectations,
                registrySnapshot: registrySnapshot
            )
        }
        for replay in actualReplayExpectations {
            let expiredTombstone = replay.state.isTerminal
                && replay.retentionExpiresAt.map { $0 <= instant } == true
            guard let transaction = actualByID[replay.transactionID] else {
                if expiredTombstone { continue }
                throw validationFailure("live replay references missing transaction \(replay.transactionID)")
            }
            try validate(replay: replay, transaction: transaction)
        }
        for transaction in actualTransactions {
            let replay = replayByTransaction[transaction.transactionID.rawValue] ?? []
            if Self.isReplayTerminalTransaction(transaction.state) {
                // rotate/retireはterminal replay ringを正当に解放できる。registry→txは厳密、
                // terminal tx→registryだけは0又は1を許す。
                guard replay.count <= 1 else {
                    throw validationFailure("terminal transaction has duplicate replay references")
                }
            } else {
                guard replay.count == 1 else {
                    throw validationFailure("live transaction must have exactly one replay reference")
                }
            }
        }
        let receiptsByTransaction = Dictionary(uniqueKeysWithValues:
            actualReceipts.map { ($0.transactionID, $0) })
        for receipt in actualReceipts where actualByID[receipt.transactionID] == nil {
            throw validationFailure("runtime receipt references missing transaction")
        }
        for transaction in actualTransactions {
            let receipt = receiptsByTransaction[transaction.transactionID.rawValue]
            guard transaction.references.allSatisfy({ Self.isSHA256($0.digest) }),
                  Self.isSHA256(transaction.manifestDigest), Self.isSHA256(transaction.referenceDigest) else {
                throw validationFailure("transaction contains an invalid digest")
            }
            switch transaction.state {
            case .filesystemCommitted:
                let receiptBindingIsRecoverable = if let receipt {
                    transaction.runtimeReceiptDigest == receipt.digest && receipt.terminalAt != nil
                } else {
                    transaction.runtimeReceiptDigest == nil
                }
                guard transaction.terminalAt == nil, receiptBindingIsRecoverable else {
                    throw validationFailure("filesystem-committed recovery has invalid runtime receipt material")
                }
            case .runtimeCommitted, .trashCommitted:
                guard let receipt, transaction.runtimeReceiptDigest == receipt.digest,
                      receipt.terminalAt != nil, transaction.terminalAt == nil else {
                    throw validationFailure("runtime-committed transaction requires one exact runtime receipt")
                }
            case .finalized, .committed:
                guard let receipt, transaction.runtimeReceiptDigest == receipt.digest,
                      Self.sameStoredDate(receipt.terminalAt, transaction.terminalAt) else {
                    throw validationFailure("terminal transaction/runtime receipt time mismatch")
                }
            default:
                guard receipt == nil, transaction.runtimeReceiptDigest == nil else {
                    throw validationFailure("noncommitted transaction must not have a runtime receipt")
                }
            }
            guard transaction.runtimeReceiptDigest == receipt?.digest else {
                throw validationFailure("transaction/runtime receipt digest binding mismatch")
            }
        }
        if let importedPayload {
            try await validateImportedSubset(
                importedPayload,
                actualReplay: actualReplayExpectations,
                actualTransactions: actualByID,
                actualReceipts: receiptsByTransaction,
                now: instant
            )
        }
    }

    private func validateImportedReplayInvalidations(
        _ importedPayload: ManifestPayload,
        actualReplay: [ReplayExpectation],
        registrySnapshot: ChangeSetClientRegistrySnapshot
    ) throws {
        let actualIdentities = Set(actualReplay.map(Self.replayIdentity))
        for expected in importedPayload.replay where !actualIdentities.contains(Self.replayIdentity(expected)) {
            guard registrySnapshot.slots.indices.contains(expected.slotIndex) else {
                throw validationFailure("imported replay slot is outside the current registry")
            }
            let slot = registrySnapshot.slots[expected.slotIndex]
            let sameActiveEpoch = slot.allocationState == .active
                && slot.clientID == expected.clientID && slot.currentEpoch == expected.epoch
            let floor = max(1, slot.highWater > UInt64(ChangeSetClientRegistry.replayCapacity - 1)
                ? slot.highWater - UInt64(ChangeSetClientRegistry.replayCapacity - 1) : 1)
            if sameActiveEpoch, expected.sequence >= floor, expected.sequence <= slot.highWater {
                throw validationFailure("imported replay disappeared without rotate/retire/ring eviction")
            }
        }
    }

    /// 初期importの不変identityと未期限terminalを固定する。post-cutoverの新規recordと、
    /// 初期nonterminalの正当な単調遷移は上のcurrent structural validatorで扱う。
    private func validateImportedSubset(
        _ importedPayload: ManifestPayload,
        actualReplay: [ReplayExpectation],
        actualTransactions: [String: ChangeSetTransactionStore.TransactionReference],
        actualReceipts: [String: RuntimeReceiptExpectation],
        now: Date
    ) async throws {
        let replayByIdentity = Dictionary(uniqueKeysWithValues: actualReplay.map {
            (Self.replayIdentity($0), $0)
        })
        for expected in importedPayload.replay {
            if let actual = replayByIdentity[Self.replayIdentity(expected)] {
                guard actual.clientID == expected.clientID,
                      actual.epoch == expected.epoch,
                      actual.requestDigest == expected.requestDigest,
                      actual.transactionID == expected.transactionID else {
                    throw validationFailure("imported replay identity/request binding changed")
                }
                if expected.state.isTerminal, actual != expected {
                    throw validationFailure("imported terminal replay changed before retention cleanup")
                }
            } else {
                guard expected.state.isTerminal,
                      expected.retentionExpiresAt.map({ $0 <= now }) == true else {
                    throw validationFailure("live imported replay is missing")
                }
            }
        }

        let expectedTransactions = Dictionary(uniqueKeysWithValues:
            importedPayload.transactions.map { ($0.transactionID, $0) })
        for expected in importedPayload.transactions {
            guard let actual = actualTransactions[expected.transactionID] else {
                guard Self.isReplayTerminalTransaction(expected.state),
                      expected.retentionExpiresAt.map({ $0 <= now }) == true else {
                    throw validationFailure("live imported transaction is missing")
                }
                continue
            }
            guard Self.isReplayTerminalTransaction(expected.state) else { continue }
            guard let snapshot = try await transactionStore.load(.init(expected.transactionID)),
                  actual.state == expected.state,
                  Self.sameStoredDate(actual.terminalAt, expected.terminalAt),
                  Self.sameStoredDate(actual.retentionExpiresAt, expected.retentionExpiresAt),
                  actual.manifestDigest == expected.manifestDigest,
                  actual.references == expected.references,
                  actual.referenceDigest == expected.referenceDigest,
                  actual.artifactDigests == expected.artifactDigests,
                  actual.revision == expected.revision,
                  Self.sha256(snapshot.payload) == expected.payloadDigest else {
                throw validationFailure("imported terminal transaction changed")
            }
        }

        for expected in importedPayload.runtimeReceipts {
            if let actual = actualReceipts[expected.transactionID] {
                guard actual == expected else {
                    throw validationFailure("imported runtime receipt cursor/digest changed")
                }
            } else if let transaction = expectedTransactions[expected.transactionID] {
                guard Self.isReplayTerminalTransaction(transaction.state),
                      transaction.retentionExpiresAt.map({ $0 <= now }) == true else {
                    throw validationFailure("live imported runtime receipt is missing")
                }
            } else {
                throw validationFailure("imported runtime receipt manifest is orphaned")
            }
        }
    }

    private static func replayIdentity(_ replay: ReplayExpectation) -> String {
        "\(replay.slotIndex):\(replay.sequence)"
    }

    private func validate(
        replay: ReplayExpectation,
        transaction: ChangeSetTransactionStore.TransactionReference
    ) throws {
        switch replay.state {
        case .pending:
            guard !Self.isReplayTerminalTransaction(transaction.state), replay.retentionExpiresAt == nil,
                  transaction.terminalAt == nil, transaction.retentionExpiresAt == nil else {
                throw validationFailure("pending replay has terminal transaction material")
            }
        case .recoveryRequired:
            guard transaction.state == .recoveryRequired, replay.retentionExpiresAt == nil,
                  transaction.terminalAt == nil, transaction.retentionExpiresAt == nil else {
                throw validationFailure("recovery replay/transaction state mismatch")
            }
        case .committed:
            guard transaction.state == .committed || transaction.state == .finalized else {
                throw validationFailure("committed replay/transaction state mismatch")
            }
        case .rolledBack:
            throw validationFailure("rolled-back replay is not a terminal state")
        case .abortedBeforeSideEffect:
            guard transaction.state == .abortedBeforeSideEffect else {
                throw validationFailure("aborted replay/transaction state mismatch")
            }
        }
        let requestBindings = transaction.references.filter {
            $0.kind == "request"
        }
        let reservationBindings = transaction.references.filter { $0.kind == "reservation" }
        guard requestBindings.count == 1,
              requestBindings[0].digest == replay.requestDigest,
              reservationBindings.count <= 1,
              reservationBindings.allSatisfy({ $0.digest == replay.requestDigest }) else {
            throw validationFailure("replay request digest is not bound to its transaction")
        }
        if replay.state.isTerminal {
            let responseBindings = transaction.references.filter { $0.kind == "terminal_response" }
            guard let expiresAt = replay.retentionExpiresAt,
                  Self.sameStoredDate(transaction.retentionExpiresAt, expiresAt),
                  let responseDigest = replay.terminalResponseDigest,
                  responseBindings.count == 1,
                  responseBindings[0].identifier == replay.transactionID,
                  responseBindings[0].digest == responseDigest else {
                throw validationFailure("terminal replay retention expiry mismatch")
            }
            if let handle = replay.artifactHandle {
                let artifactBindings = transaction.references.filter { $0.kind == "artifact" }
                guard artifactBindings.count == 1,
                      artifactBindings[0].identifier == handle,
                      Self.isSHA256(artifactBindings[0].digest) else {
                    throw validationFailure("live terminal artifact handle/digest binding is missing")
                }
            } else if transaction.references.contains(where: { $0.kind == "artifact" }) {
                throw validationFailure("artifact reference exists without a replay artifact handle")
            }
        } else if transaction.references.contains(where: { $0.kind == "terminal_response" }) {
            throw validationFailure("nonterminal transaction has a terminal response binding")
        }
    }

    private func expectedReplayReferences(_ snapshot: ChangeSetLegacyRegistrySnapshot) -> [ChangeSetReplayReference] {
        snapshot.slots
            .filter { $0.allocationState == .active }
            .sorted { $0.number < $1.number }
            .flatMap { slot in
                slot.replay.compactMap { $0 }
                    .sorted { $0.sequence < $1.sequence }
                    .map { envelope in
                        ChangeSetReplayReference(
                            clientID: slot.clientID,
                            epoch: slot.currentEpoch,
                            slotIndex: slot.number,
                            sequence: envelope.sequence,
                            requestDigest: envelope.requestDigest,
                            transactionID: envelope.transactionID,
                            state: envelope.state,
                            terminalResponseDigest: envelope.terminalResponseDigest,
                            artifactHandle: envelope.artifact?.handle,
                            artifactExpiresAt: envelope.artifact?.expiresAt,
                            retentionExpiresAt: envelope.retentionExpiresAt
                        )
                    }
            }
    }

    private func replayExpectation(_ reference: ChangeSetReplayReference) -> ReplayExpectation {
        ReplayExpectation(
            clientID: reference.clientID,
            epoch: reference.epoch,
            slotIndex: reference.slotIndex,
            sequence: reference.sequence,
            requestDigest: reference.requestDigest,
            transactionID: reference.transactionID,
            state: reference.state,
            terminalResponseDigest: reference.terminalResponseDigest,
            artifactHandle: reference.artifactHandle,
            artifactExpiresAt: reference.artifactExpiresAt,
            retentionExpiresAt: reference.retentionExpiresAt
        )
    }

    private func runtimeReceiptExpectation(
        _ receipt: ChangeSetTransactionStore.RuntimeReceipt
    ) throws -> RuntimeReceiptExpectation {
        let semanticDigest = Self.sha256(try Self.encode(
            [receipt.cursor.root, receipt.cursor.generation, String(receipt.cursor.sequence)] + receipt.paths
        ))
        guard receipt.digest == semanticDigest,
              receipt.paths.count <= Self.maximumPathsPerReceipt,
              receipt.paths.allSatisfy({ !$0.isEmpty && $0.utf8.count <= Self.maximumPathBytes }) else {
            throw validationFailure("runtime receipt digest does not bind cursor and paths")
        }
        return RuntimeReceiptExpectation(
            transactionID: receipt.transactionID.rawValue,
            cursor: receipt.cursor,
            pathsDigest: Self.sha256(try Self.encode(receipt.paths)),
            digest: receipt.digest,
            recordedAt: receipt.recordedAt,
            terminalAt: receipt.terminalAt
        )
    }

    private func validationManifest(
        _ source: ChangeSetCutoverLegacySnapshot,
        identity: (sourceDigest: String, payloadDigest: String)
    ) throws -> ValidationManifest {
        let payload = try manifestPayload(source)
        guard Self.sha256(try Self.encode(payload)) == identity.payloadDigest else {
            throw ChangeSetCutoverError(.invalidSource, "legacy snapshot changed during manifest construction")
        }
        let manifest = ValidationManifest(
            schema: "aishell.change-set-cutover-validation-manifest.v1",
            sourceDigest: identity.sourceDigest,
            payloadDigest: identity.payloadDigest,
            preparedAt: payload.preparedAt,
            cursorBinding: payload.cursorBinding
        )
        try validate(manifest)
        let encoded = try Self.encode(manifest)
        guard encoded.count <= Self.maximumManifestPlaintextBytes else {
            throw ChangeSetCutoverError(.invalidSource, "cutover validation manifest exceeds its bound")
        }
        return manifest
    }

    private func manifestPayload(_ source: ChangeSetCutoverLegacySnapshot) throws -> ManifestPayload {
        let replay = expectedReplayReferences(source.registry).map(replayExpectation)
        let transactions = try source.transactions
            .sorted { $0.transactionID.rawValue < $1.transactionID.rawValue }
            .map { snapshot -> TransactionExpectation in
                let references = sortedReferences(snapshot.references)
                return TransactionExpectation(
                    transactionID: snapshot.transactionID.rawValue,
                    state: snapshot.state,
                    terminalAt: snapshot.terminalAt,
                    retentionExpiresAt: snapshot.retentionExpiresAt,
                    manifestDigest: snapshot.manifestDigest,
                    references: references,
                    referenceDigest: Self.sha256(try Self.encode(references)),
                    artifactDigests: references
                        .filter { $0.kind.localizedCaseInsensitiveContains("artifact") }
                        .map(\.digest),
                    payloadDigest: Self.sha256(snapshot.payload),
                    revision: snapshot.revision
                )
            }
        let receipts = try source.runtimeReceipts.map(runtimeReceiptExpectation)
            .sorted { $0.transactionID < $1.transactionID }
        return ManifestPayload(
            preparedAt: source.preparedAt,
            cursorBinding: source.cursorBinding,
            replay: replay,
            transactions: transactions,
            runtimeReceipts: receipts
        )
    }

    /// rolledBackは回復途中の非終端。opaque transaction payloadを外側だけ最終化できないため、
    /// Serviceが旧recoveryをabortedBeforeSideEffectまで完走したsnapshotだけを受け入れる。
    private func normalizedSource(_ source: ChangeSetCutoverLegacySnapshot) throws -> ChangeSetCutoverLegacySnapshot {
        if source.registry.slots.contains(where: { slot in
            slot.replay.contains(where: { $0?.state == .rolledBack })
        }) || source.transactions.contains(where: { $0.state == .rolledBack }) {
            throw ChangeSetCutoverError(.invalidSource,
                "legacy rolled-back recovery must finish before dedicated-store cutover")
        }
        return source
    }

    private func sortedReferences(_ references: [ChangeSetTransactionStore.Reference]) -> [ChangeSetTransactionStore.Reference] {
        references.sorted {
            if $0.kind != $1.kind { return $0.kind < $1.kind }
            if $0.identifier != $1.identifier { return $0.identifier < $1.identifier }
            return $0.digest < $1.digest
        }
    }

    private static func isReplayTerminalTransaction(_ state: ApplyChangeSetTransactionState) -> Bool {
        switch state {
        case .finalized, .committed, .abortedBeforeSideEffect: true
        default: false
        }
    }

    private func sourceIdentity(_ source: ChangeSetCutoverLegacySnapshot) throws -> (sourceDigest: String, payloadDigest: String) {
        guard source.sourceDigest.count == 64,
              source.sourceDigest.allSatisfy({ $0.isHexDigit }),
              !source.cursorBinding.root.isEmpty,
              source.cursorBinding.root.utf8.count <= Self.maximumPathBytes,
              !source.cursorBinding.generation.isEmpty,
              source.cursorBinding.generation.utf8.count <= Self.maximumIdentifierBytes,
              source.transactions.count <= Self.maximumTransactionCount,
              source.runtimeReceipts.count <= Self.maximumRuntimeReceiptCount,
              source.transactions.allSatisfy({
                  $0.references.count <= Self.maximumReferencesPerTransaction
              }),
              Set(source.transactions.map(\.transactionID.rawValue)).count == source.transactions.count,
              Set(source.runtimeReceipts.map(\.transactionID.rawValue)).count == source.runtimeReceipts.count else {
            throw ChangeSetCutoverError(.invalidSource)
        }
        let payload = try manifestPayload(source)
        return (source.sourceDigest.lowercased(), Self.sha256(try Self.encode(payload)))
    }

    private func requireSameSource(
        _ identity: (sourceDigest: String, payloadDigest: String),
        sourceDigest: String,
        payloadDigest: String
    ) throws {
        guard identity.sourceDigest == sourceDigest, identity.payloadDigest == payloadDigest else {
            throw ChangeSetCutoverError(.sourceConflict, "cutover must resume from the exact authenticated legacy snapshot")
        }
    }

    private func validationFailure(_ message: String) -> ChangeSetCutoverError {
        ChangeSetCutoverError(.crossValidationFailed, message)
    }

    private func validate(_ progress: Progress) throws {
        guard progress.schema == "aishell.change-set-cutover-progress.v1",
              progress.sourceDigest.count == 64, progress.payloadDigest.count == 64,
              progress.manifestDigest.count == 64 else {
            throw ChangeSetCutoverError(.stateCorrupt)
        }
    }

    private func validate(_ complete: Completion) throws {
        guard complete.schema == "aishell.change-set-cutover-complete.v1",
              complete.sourceDigest.count == 64, complete.payloadDigest.count == 64,
              complete.manifestDigest.count == 64,
              Self.isSHA256(complete.registryImportReceipt.snapshotDigest),
              complete.registryImportReceipt.registryGeneration > 0,
              complete.transactionImportReceipt.provenance == complete.sourceDigest,
              Self.isSHA256(complete.transactionImportReceipt.requestDigest),
              complete.completedAt >= complete.preparedAt else {
            throw ChangeSetCutoverError(.stateCorrupt)
        }
    }

    private func validate(_ manifest: ValidationManifest) throws {
        guard manifest.schema == "aishell.change-set-cutover-validation-manifest.v1",
              Self.isSHA256(manifest.sourceDigest), Self.isSHA256(manifest.payloadDigest),
              !manifest.cursorBinding.root.isEmpty,
              manifest.cursorBinding.root.utf8.count <= Self.maximumPathBytes,
              !manifest.cursorBinding.generation.isEmpty,
              manifest.cursorBinding.generation.utf8.count <= Self.maximumIdentifierBytes else {
            throw ChangeSetCutoverError(.stateCorrupt, "invalid cutover validation manifest")
        }
    }

    private func requireManifestBinding(_ manifest: ValidationManifest, progress: Progress) throws {
        try validate(manifest)
        guard progress.sourceDigest == manifest.sourceDigest,
              progress.payloadDigest == manifest.payloadDigest,
              progress.manifestDigest == Self.sha256(try Self.encode(manifest)),
              progress.preparedAt == manifest.preparedAt else {
            throw ChangeSetCutoverError(.stateCorrupt, "progress/manifest binding mismatch")
        }
    }

    private func requireManifestBinding(_ manifest: ValidationManifest, complete: Completion) throws {
        try validate(manifest)
        guard complete.sourceDigest == manifest.sourceDigest,
              complete.payloadDigest == manifest.payloadDigest,
              complete.manifestDigest == Self.sha256(try Self.encode(manifest)),
              complete.preparedAt == manifest.preparedAt else {
            throw ChangeSetCutoverError(.stateCorrupt, "completion/manifest binding mismatch")
        }
    }

    private func crashIfRequested(_ point: ChangeSetCutoverCrashPoint) throws {
        if crashAfter == point { throw ChangeSetCutoverSimulatedCrash(point: point) }
    }

    private var progressURL: URL { directory.appendingPathComponent("progress.enc") }
    private var completeURL: URL { directory.appendingPathComponent("complete.enc") }
    private var manifestURL: URL { directory.appendingPathComponent("validation-manifest.enc") }

    private func removeProgressAfterCompletion() throws {
        if unlink(progressURL.path) != 0, errno != ENOENT {
            throw ChangeSetCutoverError(.io, "cannot remove completed progress marker")
        }
        try Self.syncDirectory(directory)
    }

    private func writeRecord<T: Encodable>(_ value: T, to url: URL) throws {
        let plaintext = try Self.encode(value)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: Self.markerAAD)
        let envelope = Envelope(
            schema: "aishell.change-set-cutover-envelope.v1",
            nonce: Data(box.nonce), ciphertext: box.ciphertext, tag: box.tag
        )
        let record = try Self.encode(envelope)
        guard record.count <= Self.maximumRecordBytes else {
            throw ChangeSetCutoverError(.stateCorrupt, "cutover record exceeds 16 MiB")
        }
        try Self.atomicWrite(record, to: url)
    }

    private func readRecord<T: Decodable>(at url: URL) throws -> T? {
        guard Self.exists(url) else { return nil }
        do {
            let envelope = try Self.decode(Envelope.self, from: secureRead(url))
            guard envelope.schema == "aishell.change-set-cutover-envelope.v1" else {
                throw ChangeSetCutoverError(.stateCorrupt)
            }
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: envelope.nonce),
                ciphertext: envelope.ciphertext,
                tag: envelope.tag
            )
            return try Self.decode(T.self, from: AES.GCM.open(box, using: key, authenticating: Self.markerAAD))
        } catch let error as ChangeSetCutoverError {
            throw error
        } catch {
            throw ChangeSetCutoverError(.stateCorrupt, "cutover marker authentication failed")
        }
    }

    private static let markerAAD = Data("aishell.change-set-cutover-envelope.v1".utf8)

    private static func prepareOwnerOnlyDirectory(_ url: URL) throws {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            guard (status.st_mode & S_IFMT) == S_IFDIR,
                  status.st_uid == geteuid(), (status.st_mode & 0o077) == 0 else {
                throw ChangeSetCutoverError(.stateCorrupt, "cutover directory must be owner-only")
            }
            return
        }
        guard errno == ENOENT else { throw ChangeSetCutoverError(.io) }
        guard mkdir(url.path, S_IRWXU) == 0 else {
            throw ChangeSetCutoverError(.io, "cannot create cutover directory")
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    private static func exists(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }

    private func secureRead(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ChangeSetCutoverError(.stateCorrupt, "cannot securely open cutover record")
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(), (status.st_mode & 0o077) == 0,
              status.st_nlink == 1,
              status.st_size > 0, status.st_size <= off_t(Self.maximumRecordBytes) else {
            throw ChangeSetCutoverError(.stateCorrupt, "cutover record ownership/type/size mismatch")
        }
        recordOpenedHook?(url)
        let expectedCount = Int(status.st_size)
        var bytes = Data(capacity: expectedCount)
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while bytes.count < expectedCount {
            let count = read(descriptor, &buffer, min(buffer.count, expectedCount - bytes.count))
            guard count >= 0 else { throw ChangeSetCutoverError(.io) }
            guard count > 0 else { throw ChangeSetCutoverError(.stateCorrupt, "truncated cutover record") }
            bytes.append(contentsOf: buffer[0..<count])
        }
        var trailingByte: UInt8 = 0
        guard read(descriptor, &trailingByte, 1) == 0 else {
            throw ChangeSetCutoverError(.stateCorrupt, "cutover record changed while reading")
        }
        return bytes
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ChangeSetCutoverError(.io) }
        var descriptorIsOpen = true
        do {
            try writeAll(data, descriptor: descriptor)
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0, fsync(descriptor) == 0 else {
                throw ChangeSetCutoverError(.io)
            }
            guard close(descriptor) == 0 else { throw ChangeSetCutoverError(.io) }
            descriptorIsOpen = false
            guard rename(temporary.path, url.path) == 0 else { throw ChangeSetCutoverError(.io) }
            try syncDirectory(url.deletingLastPathComponent())
        } catch {
            if descriptorIsOpen { close(descriptor) }
            unlink(temporary.path)
            throw error
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = write(descriptor, base.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw ChangeSetCutoverError(.io) }
                offset += count
            }
        }
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ChangeSetCutoverError(.io) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw ChangeSetCutoverError(.io) }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }

    // transaction storeの日時表現で比較する。Dateへの復元で生じる丸めだけを吸収し、
    // 保存されるepoch milliseconds自体が異なる値は一致としない。
    static func sameStoredDate(_ lhs: Date?, _ rhs: Date?) -> Bool {
        lhs.map { $0.timeIntervalSince1970 * 1000 } == rhs.map { $0.timeIntervalSince1970 * 1000 }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }
}
