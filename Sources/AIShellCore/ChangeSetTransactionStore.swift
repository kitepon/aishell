import CryptoKit
import Darwin
import Foundation

/// ADR 0017 の transaction/runtime receipt を、root 全体の巨大 snapshot から分離して保持する。
/// 各 transaction は独立した暗号化 snapshot と append-only WAL を持つため、一件の更新が
/// 他 transaction の durable bytes を再書き込みしない。
public actor ChangeSetTransactionStore {
    public struct Snapshot: Codable, Equatable, Sendable {
        public let transactionID: ApplyChangeSetTransactionID
        public let state: ApplyChangeSetTransactionState
        public let manifestDigest: String
        public let references: [Reference]
        public let payload: Data
        public let terminalAt: Date?
        public let retentionExpiresAt: Date?
        public let revision: UInt64

        public init(
            transactionID: ApplyChangeSetTransactionID,
            state: ApplyChangeSetTransactionState,
            manifestDigest: String,
            references: [Reference] = [],
            payload: Data = Data(),
            terminalAt: Date? = nil,
            retentionExpiresAt: Date? = nil,
            revision: UInt64 = 0
        ) {
            self.transactionID = transactionID
            self.state = state
            self.manifestDigest = manifestDigest
            self.references = references
            self.payload = payload
            self.terminalAt = terminalAt
            self.retentionExpiresAt = retentionExpiresAt
            self.revision = revision
        }
    }

    public struct Reference: Codable, Equatable, Sendable {
        public let kind: String
        public let identifier: String
        public let digest: String

        public init(kind: String, identifier: String, digest: String) {
            self.kind = kind
            self.identifier = identifier
            self.digest = digest
        }
    }

    public struct RuntimeReceipt: Codable, Equatable, Sendable {
        public let transactionID: ApplyChangeSetTransactionID
        public let cursor: ApplyChangeSetCursor
        public let paths: [String]
        public let digest: String
        public let recordedAt: Date
        public let terminalAt: Date?

        public init(
            transactionID: ApplyChangeSetTransactionID,
            cursor: ApplyChangeSetCursor,
            paths: [String],
            digest: String,
            recordedAt: Date = Date(),
            terminalAt: Date? = nil
        ) {
            self.transactionID = transactionID
            self.cursor = cursor
            self.paths = paths
            self.digest = digest
            self.recordedAt = recordedAt
            self.terminalAt = terminalAt
        }
    }

    /// startup相互照合用のmetadata view。暗号化payload/evidence bytesは公開しない。
    public struct TransactionReference: Codable, Equatable, Sendable {
        public let transactionID: ApplyChangeSetTransactionID
        public let state: ApplyChangeSetTransactionState
        public let terminalAt: Date?
        public let retentionExpiresAt: Date?
        public let cleanupCandidate: Bool
        public let manifestDigest: String
        public let references: [Reference]
        public let referenceDigest: String
        public let artifactDigests: [String]
        public let runtimeReceiptDigest: String?
        public let revision: UInt64
    }

    /// legacy cutoverが一度完了した事実だけを表すcompact read model。
    /// import後のtransaction evolutionやretention cleanupとは独立して不変に残る。
    public struct LegacyImportReceipt: Codable, Equatable, Sendable {
        public let provenance: String
        public let requestDigest: String
    }

    public enum StoreError: Error, Equatable, Sendable {
        case invalidKey
        case invalidTransactionID
        case missingTransaction(String)
        case duplicateTransaction(String)
        case staleTransition(expected: ApplyChangeSetTransactionState, actual: ApplyChangeSetTransactionState)
        case staleRevision(expected: UInt64, actual: UInt64)
        case snapshotUpdateConflict(expectedRevision: UInt64)
        case invalidTransition(from: ApplyChangeSetTransactionState, to: ApplyChangeSetTransactionState)
        case corrupt(String)
        case orphan(String)
        case referenceCapacityExceeded(Int)
        case migrationInProgress(String)
        case migrationConflict
        case simulatedMigrationCrash(Int)
        case io(String)
    }

    private struct Index: Codable, Equatable, Sendable {
        let schema: String
        var transactionDirectories: [String: String]
    }

    private struct Identity: Codable, Equatable, Sendable {
        let schema: String
        let transactionID: String
        let directoryName: String
    }

    private struct Envelope: Codable, Sendable {
        let schema: String
        let nonce: Data
        let ciphertext: Data
        let tag: Data
    }

    private struct JournalPayload: Codable, Equatable, Sendable {
        let schema: String
        let sequence: UInt64
        let transactionID: String
        let fromState: ApplyChangeSetTransactionState?
        let toState: ApplyChangeSetTransactionState
        let previousDigest: String
        let sealedSnapshot: Data
        let snapshotDigest: String
        let kind: JournalKind?
        let snapshotRevision: UInt64?
        let payloadDigest: String?
        let referenceDigest: String?
    }

    private enum JournalKind: String, Codable, Equatable, Sendable { case stateTransition, snapshotUpdate, legacyImport }

    private struct JournalEntry: Codable, Equatable, Sendable {
        let payload: JournalPayload
        let digest: String
    }

    private struct MigrationRequest: Codable, Equatable, Sendable {
        let schema: String
        let provenance: String
        let snapshots: [Snapshot]
        let receipts: [RuntimeReceipt]
    }

    private struct MigrationRecord: Codable, Equatable, Sendable {
        let schema: String
        let provenance: String
        let requestDigest: String
        let request: MigrationRequest?
    }

    private let directory: URL
    private let transactionsDirectory: URL
    private let key: SymmetricKey
    private let maxRuntimeReceipts: Int
    private let maxTransactionReferences: Int
    private let terminalRetention: TimeInterval
    private let migrationCrashAfterImportedTransactions: Int?
    private let fileManager: FileManager
    private var loaded = false
    private var index = Index(schema: "aishell.change-set-transaction-index.v1", transactionDirectories: [:])
    private var receipts: [RuntimeReceipt] = []

    public init(
        directory: URL,
        encryptionKey: Data,
        maxRuntimeReceipts: Int = 512,
        maxTransactionReferences: Int = 4_096,
        terminalRetention: TimeInterval = 86_400,
        migrationCrashAfterImportedTransactions: Int? = nil,
        fileManager: FileManager = .default
    ) throws {
        guard !encryptionKey.isEmpty else { throw StoreError.invalidKey }
        self.directory = directory.standardizedFileURL
        self.transactionsDirectory = directory.appendingPathComponent("transactions", isDirectory: true)
        self.key = SymmetricKey(data: Data(SHA256.hash(data: encryptionKey)))
        self.maxRuntimeReceipts = max(1, maxRuntimeReceipts)
        self.maxTransactionReferences = max(1, maxTransactionReferences)
        self.terminalRetention = max(0, terminalRetention)
        self.migrationCrashAfterImportedTransactions = migrationCrashAfterImportedTransactions
        self.fileManager = fileManager
        try Self.createOwnerOnlyDirectory(self.directory, fileManager: fileManager)
        try Self.createOwnerOnlyDirectory(self.transactionsDirectory, fileManager: fileManager)
    }

    /// 保存済み transaction を読み、WAL が durable snapshot より一歩先なら WAL から補完する。
    public func load(_ transactionID: ApplyChangeSetTransactionID) throws -> Snapshot? {
        try ensureLoaded()
        guard let directoryName = index.transactionDirectories[transactionID.rawValue] else { return nil }
        return try reconcileTransaction(id: transactionID.rawValue, directoryName: directoryName)
    }

    public func listActive() throws -> [Snapshot] {
        try ensureLoaded()
        return try index.transactionDirectories.keys.sorted().compactMap { rawID in
            guard let directoryName = index.transactionDirectories[rawID] else { return nil }
            let snapshot = try reconcileTransaction(id: rawID, directoryName: directoryName)
            return Self.isTerminal(snapshot.state) ? nil : snapshot
        }
    }

    /// active/terminalを同じbounded viewで列挙する。期限切れterminalも黙って消さずcleanupCandidateで返す。
    public func listReferences(now: Date = Date()) throws -> [TransactionReference] {
        try ensureLoaded()
        guard index.transactionDirectories.count <= maxTransactionReferences else {
            throw StoreError.referenceCapacityExceeded(maxTransactionReferences)
        }
        return try index.transactionDirectories.keys.sorted().map { rawID in
            guard let directoryName = index.transactionDirectories[rawID] else {
                throw StoreError.corrupt("transaction index changed during reference enumeration")
            }
            return try makeReference(
                snapshot: reconcileTransaction(id: rawID, directoryName: directoryName),
                now: now
            )
        }
    }

    public func listTerminalReferences(now: Date = Date()) throws -> [TransactionReference] {
        try listReferences(now: now).filter { Self.isTerminal($0.state) }
    }

    public func legacyImportReceipt() throws -> LegacyImportReceipt? {
        try ensureLoaded()
        let completeURL = directory.appendingPathComponent("migration-complete.enc")
        guard fileManager.fileExists(atPath: completeURL.path) else { return nil }
        let complete = try open(MigrationRecord.self, data: try Self.secureRead(completeURL))
        guard complete.schema == "aishell.change-set-legacy-migration-complete.v1",
              complete.request == nil, !complete.provenance.isEmpty,
              complete.requestDigest.count == 64 else {
            throw StoreError.corrupt("legacy import receipt is invalid")
        }
        return LegacyImportReceipt(provenance: complete.provenance, requestDigest: complete.requestDigest)
    }

    /// 旧monolithic storeからempty storeへ一度だけcutoverする。
    /// intentが残る間、通常APIはpartial importを公開せず、同じrequestだけが再開できる。
    public func importLegacy(
        _ snapshots: [Snapshot],
        receipts importedReceipts: [RuntimeReceipt],
        provenance: String,
        expectedEmpty: Bool = true
    ) throws {
        try ensureLoaded(allowMigration: true)
        guard !provenance.isEmpty else { throw StoreError.migrationConflict }
        guard snapshots.count <= maxTransactionReferences, importedReceipts.count <= maxRuntimeReceipts else {
            throw StoreError.referenceCapacityExceeded(maxTransactionReferences)
        }
        let orderedSnapshots = snapshots.sorted { $0.transactionID.rawValue < $1.transactionID.rawValue }
        guard Set(orderedSnapshots.map(\.transactionID.rawValue)).count == orderedSnapshots.count else {
            throw StoreError.migrationConflict
        }
        let transactionIDs = Set(orderedSnapshots.map(\.transactionID.rawValue))
        guard importedReceipts.allSatisfy({ transactionIDs.contains($0.transactionID.rawValue) }),
              Set(importedReceipts.map(\.transactionID.rawValue)).count == importedReceipts.count else {
            throw StoreError.migrationConflict
        }
        let orderedReceipts = importedReceipts.sorted { $0.transactionID.rawValue < $1.transactionID.rawValue }
        let request = MigrationRequest(
            schema: "aishell.change-set-legacy-migration.v1", provenance: provenance,
            snapshots: orderedSnapshots, receipts: orderedReceipts
        )
        let requestDigest = Self.sha256(try Self.encode(request))
        let intentURL = directory.appendingPathComponent("migration-intent.enc")
        let completeURL = directory.appendingPathComponent("migration-complete.enc")

        if fileManager.fileExists(atPath: completeURL.path) {
            let complete = try open(MigrationRecord.self, data: try Self.secureRead(completeURL))
            guard complete.schema == "aishell.change-set-legacy-migration-complete.v1",
                  complete.provenance == provenance, complete.requestDigest == requestDigest else {
                throw StoreError.migrationConflict
            }
            if fileManager.fileExists(atPath: intentURL.path) {
                try fileManager.removeItem(at: intentURL)
                try Self.syncDirectory(directory)
            }
            return
        }

        if fileManager.fileExists(atPath: intentURL.path) {
            let intent = try open(MigrationRecord.self, data: try Self.secureRead(intentURL))
            guard intent.schema == "aishell.change-set-legacy-migration-intent.v1",
                  intent.provenance == provenance, intent.requestDigest == requestDigest,
                  intent.request == request else { throw StoreError.migrationConflict }
        } else {
            guard expectedEmpty, index.transactionDirectories.isEmpty, receipts.isEmpty else {
                throw StoreError.migrationConflict
            }
            let intent = MigrationRecord(
                schema: "aishell.change-set-legacy-migration-intent.v1", provenance: provenance,
                requestDigest: requestDigest, request: request
            )
            try atomicWrite(try seal(intent), to: intentURL)
        }

        var importedCount = 0
        for snapshot in orderedSnapshots {
            if let directoryName = index.transactionDirectories[snapshot.transactionID.rawValue] {
                guard try reconcileTransaction(id: snapshot.transactionID.rawValue, directoryName: directoryName) == snapshot else {
                    throw StoreError.migrationConflict
                }
            } else {
                try importLegacySnapshot(snapshot)
            }
            importedCount += 1
            if migrationCrashAfterImportedTransactions == importedCount {
                throw StoreError.simulatedMigrationCrash(importedCount)
            }
        }
        if !receipts.isEmpty, receipts != orderedReceipts { throw StoreError.migrationConflict }
        receipts = orderedReceipts
        try saveReceipts()
        let complete = MigrationRecord(
            schema: "aishell.change-set-legacy-migration-complete.v1", provenance: provenance,
            requestDigest: requestDigest, request: nil
        )
        try atomicWrite(try seal(complete), to: completeURL)
        try fileManager.removeItem(at: intentURL)
        try Self.syncDirectory(directory)
    }

    /// stateを進めずrich payload/referenceを更新するrevision CAS。
    /// 同じexpectedRevisionと同じ内容のretryだけは、既に確定したrevisionを返す。
    @discardableResult
    public func updateSnapshot(
        transactionID: ApplyChangeSetTransactionID,
        expectedState: ApplyChangeSetTransactionState,
        expectedRevision: UInt64,
        payload: Data,
        references: [Reference],
        manifestDigest: String,
        terminalAt: Date? = nil,
        retentionExpiresAt: Date? = nil
    ) throws -> UInt64 {
        try ensureLoaded()
        guard let directoryName = index.transactionDirectories[transactionID.rawValue] else {
            throw StoreError.missingTransaction(transactionID.rawValue)
        }
        let current = try reconcileTransaction(id: transactionID.rawValue, directoryName: directoryName)
        guard current.state == expectedState else {
            throw StoreError.staleTransition(expected: expectedState, actual: current.state)
        }
        let candidate = Snapshot(
            transactionID: transactionID, state: expectedState, manifestDigest: manifestDigest,
            references: references, payload: payload, terminalAt: terminalAt ?? current.terminalAt,
            retentionExpiresAt: retentionExpiresAt ?? current.retentionExpiresAt, revision: expectedRevision + 1
        )
        if current.revision == expectedRevision + 1 {
            guard current == candidate else { throw StoreError.snapshotUpdateConflict(expectedRevision: expectedRevision) }
            return current.revision
        }
        guard current.revision == expectedRevision else {
            throw StoreError.staleRevision(expected: expectedRevision, actual: current.revision)
        }
        try writeTransition(candidate, fromState: current.state, directoryName: directoryName, kind: .snapshotUpdate)
        return candidate.revision
    }

    /// expectedState を照合してから単調な遷移を永続化する。新規 transaction は preparing だけを受け付ける。
    public func persistTransition(_ snapshot: Snapshot, expectedState: ApplyChangeSetTransactionState? = nil) throws {
        try ensureLoaded()
        let rawID = snapshot.transactionID.rawValue
        guard !rawID.isEmpty else { throw StoreError.invalidTransactionID }

        if let directoryName = index.transactionDirectories[rawID] {
            let current = try reconcileTransaction(id: rawID, directoryName: directoryName)
            if let expectedState, current.state != expectedState {
                throw StoreError.staleTransition(expected: expectedState, actual: current.state)
            }
            guard current.state != snapshot.state else {
                let replayCandidate = Snapshot(
                    transactionID: snapshot.transactionID, state: snapshot.state, manifestDigest: snapshot.manifestDigest,
                    references: snapshot.references, payload: snapshot.payload, terminalAt: snapshot.terminalAt,
                    retentionExpiresAt: snapshot.retentionExpiresAt, revision: current.revision
                )
                guard current == replayCandidate else { throw StoreError.duplicateTransaction(rawID) }
                return
            }
            guard Self.canTransition(from: current.state, to: snapshot.state) else {
                throw StoreError.invalidTransition(from: current.state, to: snapshot.state)
            }
            let versioned = Snapshot(
                transactionID: snapshot.transactionID, state: snapshot.state, manifestDigest: snapshot.manifestDigest,
                references: snapshot.references, payload: snapshot.payload, terminalAt: snapshot.terminalAt,
                retentionExpiresAt: snapshot.retentionExpiresAt, revision: current.revision + 1
            )
            try writeTransition(versioned, fromState: current.state, directoryName: directoryName, kind: .stateTransition)
            return
        }

        guard expectedState == nil, snapshot.state == .preparing else {
            throw StoreError.missingTransaction(rawID)
        }
        guard index.transactionDirectories.count < maxTransactionReferences else {
            throw StoreError.referenceCapacityExceeded(maxTransactionReferences)
        }
        let directoryName = Self.directoryName(for: rawID)
        let transactionDirectory = transactionsDirectory.appendingPathComponent(directoryName, isDirectory: true)
        guard !fileManager.fileExists(atPath: transactionDirectory.path) else { throw StoreError.orphan(directoryName) }
        try Self.createOwnerOnlyDirectory(transactionDirectory, fileManager: fileManager)
        let identity = Identity(schema: "aishell.change-set-transaction-identity.v1", transactionID: rawID, directoryName: directoryName)
        try atomicWrite(try seal(identity), to: transactionDirectory.appendingPathComponent("identity.enc"))
        guard snapshot.revision == 0 else { throw StoreError.staleRevision(expected: 0, actual: snapshot.revision) }
        try writeTransition(snapshot, fromState: nil, directoryName: directoryName, kind: .stateTransition)
        index.transactionDirectories[rawID] = directoryName
        try saveIndex()
    }

    public func appendRuntimeReceipt(_ receipt: RuntimeReceipt) throws {
        try ensureLoaded()
        guard index.transactionDirectories[receipt.transactionID.rawValue] != nil else {
            throw StoreError.missingTransaction(receipt.transactionID.rawValue)
        }
        if let existing = receipts.first(where: { $0.transactionID == receipt.transactionID }) {
            guard existing == receipt else { throw StoreError.corrupt("runtime receipt digest/cursor conflict for \(receipt.transactionID.rawValue)") }
            return
        }
        receipts.append(receipt)
        receipts.sort { lhs, rhs in
            if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt < rhs.recordedAt }
            return lhs.transactionID.rawValue < rhs.transactionID.rawValue
        }
        if receipts.count > maxRuntimeReceipts {
            let now = Date()
            var removable: [Int] = []
            for receiptIndex in receipts.indices {
                let receipt = receipts[receiptIndex]
                guard let terminalAt = receipt.terminalAt,
                      let directoryName = index.transactionDirectories[receipt.transactionID.rawValue] else { continue }
                let snapshot = try reconcileTransaction(id: receipt.transactionID.rawValue, directoryName: directoryName)
                let expiresAt = snapshot.retentionExpiresAt ?? terminalAt.addingTimeInterval(terminalRetention)
                if now >= expiresAt { removable.append(receiptIndex) }
            }
            var removeCount = receipts.count - maxRuntimeReceipts
            let removedIndices = Set(removable.prefix(removeCount))
            removeCount -= removedIndices.count
            receipts = receipts.enumerated().compactMap { removedIndices.contains($0.offset) ? nil : $0.element }
            guard receipts.count <= maxRuntimeReceipts else {
                receipts.removeLast()
                throw StoreError.io("runtime receipt capacity is occupied by nonterminal transactions")
            }
        }
        try saveReceipts()
    }

    public func runtimeReceipts() throws -> [RuntimeReceipt] {
        try ensureLoaded()
        return receipts
    }

    func removeRuntimeReceiptForTesting(_ transactionID: ApplyChangeSetTransactionID) throws {
        try ensureLoaded()
        guard receipts.contains(where: { $0.transactionID == transactionID }) else {
            throw StoreError.missingTransaction(transactionID.rawValue)
        }
        receipts.removeAll { $0.transactionID == transactionID }
        try saveReceipts()
    }

    public func finalize(
        _ transactionID: ApplyChangeSetTransactionID,
        state: ApplyChangeSetTransactionState = .finalized,
        payload: Data? = nil,
        terminalAt: Date = Date(),
        retentionExpiresAt: Date? = nil
    ) throws {
        guard var snapshot = try load(transactionID) else { throw StoreError.missingTransaction(transactionID.rawValue) }
        snapshot = Snapshot(
            transactionID: snapshot.transactionID,
            state: state,
            manifestDigest: snapshot.manifestDigest,
            references: snapshot.references,
            payload: payload ?? snapshot.payload,
            terminalAt: terminalAt,
            retentionExpiresAt: retentionExpiresAt ?? snapshot.retentionExpiresAt
                ?? terminalAt.addingTimeInterval(terminalRetention),
            revision: snapshot.revision + 1
        )
        try persistTransition(snapshot, expectedState: (try load(transactionID))?.state)
        if let receiptIndex = receipts.firstIndex(where: { $0.transactionID == transactionID }) {
            let receipt = receipts[receiptIndex]
            receipts[receiptIndex] = RuntimeReceipt(
                transactionID: receipt.transactionID, cursor: receipt.cursor, paths: receipt.paths,
                digest: receipt.digest, recordedAt: receipt.recordedAt, terminalAt: terminalAt
            )
            try saveReceipts()
        }
    }

    /// retention を過ぎた terminal transaction と対応 receipt/reference を一緒に回収する。
    @discardableResult
    public func cleanup(now: Date = Date()) throws -> [ApplyChangeSetTransactionID] {
        try ensureLoaded()
        var removed: [ApplyChangeSetTransactionID] = []
        for rawID in index.transactionDirectories.keys.sorted() {
            guard let directoryName = index.transactionDirectories[rawID] else { continue }
            let snapshot = try reconcileTransaction(id: rawID, directoryName: directoryName)
            let expiresAt = snapshot.retentionExpiresAt
                ?? snapshot.terminalAt.map { $0.addingTimeInterval(terminalRetention) }
            guard Self.isTerminal(snapshot.state), let expiresAt, now >= expiresAt else { continue }
            try fileManager.removeItem(at: transactionsDirectory.appendingPathComponent(directoryName, isDirectory: true))
            try Self.syncDirectory(transactionsDirectory)
            index.transactionDirectories.removeValue(forKey: rawID)
            receipts.removeAll { $0.transactionID.rawValue == rawID }
            removed.append(ApplyChangeSetTransactionID(rawID))
        }
        if !removed.isEmpty {
            try saveIndex()
            try saveReceipts()
        }
        return removed
    }

    // MARK: - Recovery and persistence

    private func ensureLoaded(allowMigration: Bool = false) throws {
        if loaded {
            if !allowMigration, fileManager.fileExists(atPath: directory.appendingPathComponent("migration-intent.enc").path) {
                throw StoreError.migrationInProgress("legacy import must be resumed with the exact request")
            }
            return
        }
        let indexURL = directory.appendingPathComponent("index.enc")
        if fileManager.fileExists(atPath: indexURL.path) {
            index = try open(Index.self, data: try Self.secureRead(indexURL))
            guard index.schema == "aishell.change-set-transaction-index.v1" else { throw StoreError.corrupt("unknown index schema") }
            guard index.transactionDirectories.count <= maxTransactionReferences else {
                throw StoreError.referenceCapacityExceeded(maxTransactionReferences)
            }
        }
        let receiptsURL = directory.appendingPathComponent("runtime-receipts.enc")
        if fileManager.fileExists(atPath: receiptsURL.path) {
            receipts = try open([RuntimeReceipt].self, data: try Self.secureRead(receiptsURL))
            guard receipts.count <= maxRuntimeReceipts else { throw StoreError.corrupt("runtime receipt bound exceeded") }
        }
        try reconcileDirectoryMembership()
        for (rawID, directoryName) in index.transactionDirectories {
            _ = try reconcileTransaction(id: rawID, directoryName: directoryName)
        }
        if !allowMigration, fileManager.fileExists(atPath: directory.appendingPathComponent("migration-intent.enc").path) {
            throw StoreError.migrationInProgress("legacy import must be resumed with the exact request")
        }
        loaded = true
    }

    private func reconcileDirectoryMembership() throws {
        let entries = try fileManager.contentsOfDirectory(at: transactionsDirectory, includingPropertiesForKeys: [])
        var discovered: [String: String] = [:]
        for entry in entries {
            var status = stat()
            guard lstat(entry.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR,
                  status.st_uid == geteuid(), (status.st_mode & 0o077) == 0 else {
                throw StoreError.orphan(entry.lastPathComponent)
            }
            let identityURL = entry.appendingPathComponent("identity.enc")
            guard fileManager.fileExists(atPath: identityURL.path) else { throw StoreError.orphan(entry.lastPathComponent) }
            let identity = try open(Identity.self, data: try Self.secureRead(identityURL))
            guard identity.schema == "aishell.change-set-transaction-identity.v1",
                  identity.directoryName == entry.lastPathComponent,
                  Self.directoryName(for: identity.transactionID) == entry.lastPathComponent else {
                throw StoreError.orphan(entry.lastPathComponent)
            }
            guard discovered.updateValue(entry.lastPathComponent, forKey: identity.transactionID) == nil else {
                throw StoreError.corrupt("duplicate transaction identity \(identity.transactionID)")
            }
        }
        for (rawID, directoryName) in index.transactionDirectories where discovered[rawID] != directoryName {
            throw StoreError.corrupt("indexed transaction directory is missing: \(rawID)")
        }
        if discovered != index.transactionDirectories {
            index.transactionDirectories = discovered
            try saveIndex()
        }
    }

    private func writeTransition(
        _ snapshot: Snapshot,
        fromState: ApplyChangeSetTransactionState?,
        directoryName: String,
        kind: JournalKind
    ) throws {
        if let terminalAt = snapshot.terminalAt, let expiresAt = snapshot.retentionExpiresAt,
           expiresAt < terminalAt {
            throw StoreError.corrupt("transaction retention expires before terminal time")
        }
        let transactionDirectory = transactionsDirectory.appendingPathComponent(directoryName, isDirectory: true)
        let journalURL = transactionDirectory.appendingPathComponent("journal.wal")
        let entries = try readJournal(journalURL)
        let previousDigest = entries.last?.digest ?? String(repeating: "0", count: 64)
        let sealedSnapshot = try seal(snapshot)
        let payload = JournalPayload(
            schema: "aishell.change-set-transaction-journal.v1", sequence: UInt64(entries.count),
            transactionID: snapshot.transactionID.rawValue, fromState: fromState, toState: snapshot.state,
            previousDigest: previousDigest, sealedSnapshot: sealedSnapshot, snapshotDigest: Self.sha256(sealedSnapshot),
            kind: kind, snapshotRevision: snapshot.revision, payloadDigest: Self.sha256(snapshot.payload),
            referenceDigest: Self.sha256(try Self.encode(snapshot.references))
        )
        let payloadBytes = try Self.encode(payload)
        let entry = JournalEntry(payload: payload, digest: Self.sha256(Data(previousDigest.utf8) + payloadBytes))
        try appendLine(try Self.encode(entry), to: journalURL)
        try atomicWrite(sealedSnapshot, to: transactionDirectory.appendingPathComponent("snapshot.enc"))
    }

    private func importLegacySnapshot(_ snapshot: Snapshot) throws {
        let rawID = snapshot.transactionID.rawValue
        guard !rawID.isEmpty, index.transactionDirectories.count < maxTransactionReferences else {
            throw StoreError.referenceCapacityExceeded(maxTransactionReferences)
        }
        let directoryName = Self.directoryName(for: rawID)
        let transactionDirectory = transactionsDirectory.appendingPathComponent(directoryName, isDirectory: true)
        guard !fileManager.fileExists(atPath: transactionDirectory.path) else { throw StoreError.orphan(directoryName) }
        try Self.createOwnerOnlyDirectory(transactionDirectory, fileManager: fileManager)
        let identity = Identity(schema: "aishell.change-set-transaction-identity.v1", transactionID: rawID, directoryName: directoryName)
        try atomicWrite(try seal(identity), to: transactionDirectory.appendingPathComponent("identity.enc"))
        try writeTransition(snapshot, fromState: nil, directoryName: directoryName, kind: .legacyImport)
        index.transactionDirectories[rawID] = directoryName
        try saveIndex()
    }

    private func makeReference(snapshot: Snapshot, now: Date) throws -> TransactionReference {
        let sortedReferences = snapshot.references.sorted {
            if $0.kind != $1.kind { return $0.kind < $1.kind }
            if $0.identifier != $1.identifier { return $0.identifier < $1.identifier }
            return $0.digest < $1.digest
        }
        let expiresAt = snapshot.retentionExpiresAt
            ?? snapshot.terminalAt.map { $0.addingTimeInterval(terminalRetention) }
        let runtimeDigest = receipts.first { $0.transactionID == snapshot.transactionID }?.digest
        return TransactionReference(
            transactionID: snapshot.transactionID,
            state: snapshot.state,
            terminalAt: snapshot.terminalAt,
            retentionExpiresAt: expiresAt,
            cleanupCandidate: expiresAt.map { now >= $0 } ?? false,
            manifestDigest: snapshot.manifestDigest,
            references: sortedReferences,
            referenceDigest: Self.sha256(try Self.encode(sortedReferences)),
            artifactDigests: sortedReferences.filter { $0.kind.localizedCaseInsensitiveContains("artifact") }.map(\.digest),
            runtimeReceiptDigest: runtimeDigest,
            revision: snapshot.revision
        )
    }

    private func reconcileTransaction(id rawID: String, directoryName: String) throws -> Snapshot {
        let transactionDirectory = transactionsDirectory.appendingPathComponent(directoryName, isDirectory: true)
        let entries = try readJournal(transactionDirectory.appendingPathComponent("journal.wal"))
        guard let last = entries.last else { throw StoreError.corrupt("empty journal for \(rawID)") }
        guard last.payload.transactionID == rawID else { throw StoreError.corrupt("journal identity mismatch") }
        let snapshotURL = transactionDirectory.appendingPathComponent("snapshot.enc")
        let snapshotData: Data?
        var snapshotStatus = stat()
        if lstat(snapshotURL.path, &snapshotStatus) == 0 {
            snapshotData = try Self.secureRead(snapshotURL)
        } else if errno == ENOENT {
            snapshotData = nil
        } else {
            throw StoreError.corrupt("cannot inspect durable snapshot")
        }
        let durableData: Data
        if let snapshotData, Self.sha256(snapshotData) == last.payload.snapshotDigest {
            durableData = snapshotData
        } else if snapshotData == nil || (entries.dropLast().last.map { Self.sha256(snapshotData!) == $0.payload.snapshotDigest } == true) {
            // WAL fsync precedes snapshot replace。未作成又は直前世代のsnapshotだけが既知のcrash状態である。
            guard Self.sha256(last.payload.sealedSnapshot) == last.payload.snapshotDigest else {
                throw StoreError.corrupt("WAL snapshot digest mismatch")
            }
            durableData = last.payload.sealedSnapshot
            try atomicWrite(durableData, to: snapshotURL)
        } else {
            throw StoreError.corrupt("snapshot digest is neither current nor the known previous generation")
        }
        let snapshot = try open(Snapshot.self, data: durableData)
        let decodedReferenceDigest = Self.sha256(try Self.encode(snapshot.references))
        guard snapshot.transactionID.rawValue == rawID, snapshot.state == last.payload.toState,
              last.payload.snapshotRevision == nil || snapshot.revision == last.payload.snapshotRevision,
              last.payload.payloadDigest == nil || Self.sha256(snapshot.payload) == last.payload.payloadDigest,
              last.payload.referenceDigest == nil || decodedReferenceDigest == last.payload.referenceDigest else {
            throw StoreError.corrupt("snapshot/journal mismatch")
        }
        return snapshot
    }

    private func readJournal(_ url: URL) throws -> [JournalEntry] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Self.secureRead(url)
        guard !data.isEmpty else { return [] }
        let hasCompleteTail = data.last == 0x0A
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if !hasCompleteTail {
            if !lines.isEmpty { lines.removeLast() } // syscall途中の末尾だけは未commitとして無視する。
            let validLength = data.lastIndex(of: 0x0A).map { data.distance(from: data.startIndex, to: $0) + 1 } ?? 0
            let descriptor = Darwin.open(url.path, O_WRONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw StoreError.corrupt("cannot truncate crash tail") }
            defer { Darwin.close(descriptor) }
            guard ftruncate(descriptor, off_t(validLength)) == 0, fsync(descriptor) == 0 else {
                throw StoreError.io("cannot durably truncate crash tail")
            }
            try Self.syncDirectory(url.deletingLastPathComponent())
        }
        var entries: [JournalEntry] = []
        var previousDigest = String(repeating: "0", count: 64)
        for (offset, line) in lines.enumerated() {
            let entry: JournalEntry
            do { entry = try Self.decode(JournalEntry.self, from: Data(line)) }
            catch { throw StoreError.corrupt("journal decode failed at \(offset)") }
            guard entry.payload.schema == "aishell.change-set-transaction-journal.v1",
                  entry.payload.sequence == UInt64(offset), entry.payload.previousDigest == previousDigest,
                  Self.sha256(entry.payload.sealedSnapshot) == entry.payload.snapshotDigest,
                  Self.sha256(Data(previousDigest.utf8) + (try Self.encode(entry.payload))) == entry.digest else {
                throw StoreError.corrupt("journal hash chain mismatch at \(offset)")
            }
            if let previous = entries.last {
                let prior = previous.payload.toState
                let kind = entry.payload.kind ?? .stateTransition
                let validState = kind == .snapshotUpdate
                    ? entry.payload.fromState == prior && entry.payload.toState == prior
                    : entry.payload.fromState == prior && Self.canTransition(from: prior, to: entry.payload.toState)
                guard validState,
                      entry.payload.snapshotRevision == nil || entry.payload.snapshotRevision == (previous.payload.snapshotRevision ?? UInt64(offset - 1)) + 1 else {
                    throw StoreError.corrupt("journal state/revision ordering mismatch at \(offset)")
                }
            } else {
                let initialKind = entry.payload.kind ?? .stateTransition
                let validInitial = entry.payload.fromState == nil
                    && (initialKind == .legacyImport || entry.payload.toState == .preparing)
                    && (initialKind == .legacyImport || entry.payload.snapshotRevision == nil || entry.payload.snapshotRevision == 0)
                guard validInitial else { throw StoreError.corrupt("invalid initial journal state") }
            }
            entries.append(entry)
            previousDigest = entry.digest
        }
        return entries
    }

    private func saveIndex() throws { try atomicWrite(try seal(index), to: directory.appendingPathComponent("index.enc")) }
    private func saveReceipts() throws { try atomicWrite(try seal(receipts), to: directory.appendingPathComponent("runtime-receipts.enc")) }

    private func seal<T: Encodable>(_ value: T) throws -> Data {
        let plaintext = try Self.encode(value)
        let box = try AES.GCM.seal(plaintext, using: key)
        let envelope = Envelope(schema: "aishell.change-set-store.envelope.v1", nonce: Data(box.nonce), ciphertext: box.ciphertext, tag: box.tag)
        return try Self.encode(envelope)
    }

    private func open<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        do {
            let envelope = try Self.decode(Envelope.self, from: data)
            guard envelope.schema == "aishell.change-set-store.envelope.v1" else { throw StoreError.corrupt("unknown envelope schema") }
            let nonce = try AES.GCM.Nonce(data: envelope.nonce)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: envelope.ciphertext, tag: envelope.tag)
            return try Self.decode(T.self, from: AES.GCM.open(box, using: key))
        } catch let error as StoreError { throw error }
        catch { throw StoreError.corrupt("encrypted record authentication/decode failed") }
    }

    private func appendLine(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw StoreError.io("cannot open journal") }
        defer { Darwin.close(descriptor) }
        var bytes = data
        bytes.append(0x0A)
        try Self.writeAll(bytes, descriptor: descriptor)
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0, fsync(descriptor) == 0 else {
            throw StoreError.io("journal fsync failed")
        }
        try Self.syncDirectory(url.deletingLastPathComponent())
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw StoreError.io("cannot create temporary record")
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
            guard Darwin.rename(temporary.path, url.path) == 0 else { throw StoreError.io("atomic rename failed: \(String(cString: strerror(errno)))") }
            guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else { throw StoreError.io("chmod failed") }
            try Self.syncDirectory(url.deletingLastPathComponent())
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private static func createOwnerOnlyDirectory(_ url: URL, fileManager: FileManager) throws {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            guard (status.st_mode & S_IFMT) == S_IFDIR, status.st_uid == geteuid(), (status.st_mode & 0o077) == 0 else {
                throw StoreError.corrupt("transaction store directory must be owner-only and not a symlink")
            }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard chmod(url.path, S_IRWXU) == 0 else { throw StoreError.io("cannot enforce owner-only directory: \(url.path)") }
    }

    private static func secureRead(_ url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StoreError.corrupt("cannot securely open \(url.lastPathComponent)") }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(), (status.st_mode & 0o077) == 0 else {
            throw StoreError.corrupt("record is not an owner-only regular file")
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { throw StoreError.io("record read failed") }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), data.count - offset)
                guard count > 0 else { throw StoreError.io("record write failed") }
                offset += count
            }
        }
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw StoreError.io("cannot open directory for fsync") }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw StoreError.io("directory fsync failed") }
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
        return try decoder.decode(T.self, from: data)
    }

    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    internal static func directoryName(for rawID: String) -> String { sha256(Data(rawID.utf8)) }

    private static func isTerminal(_ state: ApplyChangeSetTransactionState) -> Bool {
        switch state {
        case .finalized, .committed, .abortedBeforeSideEffect: true
        default: false
        }
    }

    private static func canTransition(from: ApplyChangeSetTransactionState, to: ApplyChangeSetTransactionState) -> Bool {
        if to == .recoveryRequired { return !isTerminal(from) }
        return switch (from, to) {
        case (.preparing, .prepared), (.preparing, .rollbackDecided), (.preparing, .abortedBeforeSideEffect),
             (.prepared, .commitDecided), (.prepared, .rollbackDecided),
             (.prepared, .abortedBeforeSideEffect),
             (.commitDecided, .filesystemCommitted),
             (.filesystemCommitted, .runtimeCommitted),
             (.runtimeCommitted, .trashCommitted),
             (.trashCommitted, .finalized), (.trashCommitted, .committed),
             (.finalized, .committed),
             (.rollbackDecided, .rolledBack),
             (.recoveryRequired, .rollbackDecided), (.recoveryRequired, .filesystemCommitted),
             (.recoveryRequired, .runtimeCommitted), (.recoveryRequired, .trashCommitted),
             (.recoveryRequired, .finalized),
             (.rolledBack, .abortedBeforeSideEffect): true
        default: false
        }
    }
}
