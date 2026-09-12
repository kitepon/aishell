import CryptoKit
import Foundation

enum WorkspaceCheckpointEntryKind: String, Codable, Sendable {
    case file
    case directory
}

enum WorkspaceCheckpointHashState: String, Codable, Sendable {
    case hashed
    case deferred
    case notApplicable = "not_applicable"
}

struct WorkspaceCheckpointEntry: Codable, Equatable, Sendable {
    let path: String
    let identity: String
    let kind: WorkspaceCheckpointEntryKind
    let sizeBytes: Int64
    let modifiedAtNanoseconds: Int64?
    let sha256: String?
    let hashState: WorkspaceCheckpointHashState

    enum CodingKeys: String, CodingKey {
        case path, identity, kind, sha256
        case sizeBytes = "size_bytes"
        case modifiedAtNanoseconds = "modified_at_nanoseconds"
        case hashState = "hash_state"
    }
}

struct WorkspaceCheckpointJournalChange: Codable, Equatable, Sendable {
    let sequence: UInt64
    let change: WorkspaceChange
}

struct WorkspaceCheckpoint: Codable, Equatable, Sendable {
    static let currentSchema = "aishell.workspace-checkpoint.v1"

    let schema: String
    let rootPath: String
    let rootIdentity: String
    let rootDigest: String
    let exclusionDigest: String
    let eventStoreUUID: String?
    let generation: String
    let lastEventID: UInt64?
    let journalSequence: UInt64
    let journalEvents: [ObservationJournalEvent]
    let journalChanges: [WorkspaceCheckpointJournalChange]?
    let entries: [WorkspaceCheckpointEntry]
    let createdAt: Date
    let lastAccessedAt: Date
    let payloadSHA256: String?

    init(
        schema: String = Self.currentSchema,
        rootPath: String,
        rootIdentity: String,
        rootDigest: String,
        exclusionDigest: String,
        eventStoreUUID: String? = nil,
        generation: String,
        lastEventID: UInt64?,
        journalSequence: UInt64 = 0,
        journalEvents: [ObservationJournalEvent] = [],
        journalChanges: [WorkspaceCheckpointJournalChange]? = nil,
        entries: [WorkspaceCheckpointEntry],
        createdAt: Date,
        lastAccessedAt: Date,
        payloadSHA256: String? = nil
    ) {
        self.schema = schema
        self.rootPath = rootPath
        self.rootIdentity = rootIdentity
        self.rootDigest = rootDigest
        self.exclusionDigest = exclusionDigest
        self.eventStoreUUID = eventStoreUUID
        self.generation = generation
        self.lastEventID = lastEventID
        self.journalSequence = journalSequence
        self.journalEvents = journalEvents
        self.journalChanges = journalChanges
        self.entries = entries
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        self.payloadSHA256 = payloadSHA256
    }

    enum CodingKeys: String, CodingKey {
        case schema, generation, entries
        case rootPath = "root_path"
        case rootIdentity = "root_identity"
        case rootDigest = "root_digest"
        case exclusionDigest = "exclusion_digest"
        case eventStoreUUID = "event_store_uuid"
        case lastEventID = "last_event_id"
        case journalSequence = "journal_sequence"
        case journalEvents = "journal_events"
        case journalChanges = "journal_changes"
        case createdAt = "created_at"
        case lastAccessedAt = "last_accessed_at"
        case payloadSHA256 = "payload_sha256"
    }

    func normalized(payloadSHA256: String? = nil) -> WorkspaceCheckpoint {
        WorkspaceCheckpoint(
            schema: schema,
            rootPath: rootPath,
            rootIdentity: rootIdentity,
            rootDigest: rootDigest,
            exclusionDigest: exclusionDigest,
            eventStoreUUID: eventStoreUUID,
            generation: generation,
            lastEventID: lastEventID,
            journalSequence: journalSequence,
            journalEvents: journalEvents.sorted { $0.sequence < $1.sequence },
            journalChanges: journalChanges?.sorted { $0.sequence < $1.sequence },
            entries: entries.sorted { $0.path < $1.path },
            createdAt: createdAt,
            lastAccessedAt: lastAccessedAt,
            payloadSHA256: payloadSHA256
        )
    }
}

private struct WorkspaceCheckpointSchemaEnvelope: Decodable {
    let schema: String
}

struct WorkspaceCheckpointQuota: Sendable {
    var maximumRoots = 8
    var maximumEntriesPerRoot = 500_000
    var maximumBytesPerRoot = 128 * 1_024 * 1_024
    var maximumTotalBytes = 512 * 1_024 * 1_024
}

actor WorkspaceCheckpointStore {
    private let baseDirectory: URL
    private let quota: WorkspaceCheckpointQuota
    private let beforeCommit: (@Sendable () throws -> Void)?
    private let fileManager = FileManager.default
    private var recentEvictedRootDigests: [String] = []

    init(
        baseDirectory: URL,
        quota: WorkspaceCheckpointQuota = WorkspaceCheckpointQuota(),
        beforeCommit: (@Sendable () throws -> Void)? = nil
    ) {
        self.baseDirectory = baseDirectory.appendingPathComponent("workspaces", isDirectory: true)
        self.quota = quota
        self.beforeCommit = beforeCommit
    }

    func load(rootDigest: String) throws -> WorkspaceCheckpoint? {
        let url = try checkpointURL(rootDigest: rootDigest)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw AIShellError.checkpointCorrupt("\(url.path): \(error.localizedDescription)")
        }
        let schema: String
        do {
            schema = try Self.decoder.decode(WorkspaceCheckpointSchemaEnvelope.self, from: data).schema
        } catch {
            throw AIShellError.checkpointCorrupt("schemaをdecodeできません: \(url.path)")
        }
        guard schema == WorkspaceCheckpoint.currentSchema else {
            throw AIShellError.checkpointUnsupported(schema)
        }
        let checkpoint: WorkspaceCheckpoint
        do {
            checkpoint = try Self.decoder.decode(WorkspaceCheckpoint.self, from: data)
        } catch {
            throw AIShellError.checkpointCorrupt("schema payloadをdecodeできません: \(url.path)")
        }
        guard checkpoint.rootDigest == rootDigest else {
            throw AIShellError.checkpointCorrupt("directoryとroot_digestが一致しません: \(url.path)")
        }
        if let eventStoreUUID = checkpoint.eventStoreUUID, UUID(uuidString: eventStoreUUID) == nil {
            throw AIShellError.checkpointCorrupt("event_store_uuidが不正です: \(url.path)")
        }
        guard let storedDigest = checkpoint.payloadSHA256 else {
            throw AIShellError.checkpointCorrupt("payload_sha256がありません: \(url.path)")
        }
        let normalized = checkpoint.normalized()
        let actualDigest = Self.digest(try Self.encoder.encode(normalized))
        guard storedDigest == actualDigest else {
            throw AIShellError.checkpointCorrupt("payload_sha256が一致しません: \(url.path)")
        }
        try Self.validateEntries(checkpoint.entries, path: url.path, requiresCanonicalOrder: true)
        try Self.validateJournal(checkpoint, path: url.path)
        return checkpoint
    }

    @discardableResult
    func save(
        _ checkpoint: WorkspaceCheckpoint,
        activeRootDigests: Set<String> = []
    ) throws -> URL {
        guard checkpoint.schema == WorkspaceCheckpoint.currentSchema else {
            throw AIShellError.checkpointUnsupported(checkpoint.schema)
        }
        _ = try checkpointURL(rootDigest: checkpoint.rootDigest)
        try Self.validateJournal(checkpoint, path: checkpoint.rootPath)
        guard checkpoint.entries.count <= quota.maximumEntriesPerRoot else {
            throw AIShellError.checkpointQuotaExceeded(
                "entry上限（\(quota.maximumEntriesPerRoot) entries）を超えます。"
            )
        }
        let withoutDigest = checkpoint.normalized()
        try Self.validateEntries(
            withoutDigest.entries,
            path: checkpoint.rootPath,
            requiresCanonicalOrder: true
        )
        let digest = Self.digest(try Self.encoder.encode(withoutDigest))
        let encoded = try Self.encoder.encode(withoutDigest.normalized(payloadSHA256: digest))
        guard encoded.count <= quota.maximumBytesPerRoot else {
            throw AIShellError.checkpointQuotaExceeded(
                "1 root容量上限（\(quota.maximumBytesPerRoot) bytes）を超えます。"
            )
        }

        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let evictionPlan = try planEvictions(
            incomingRootDigest: checkpoint.rootDigest,
            incomingBytes: encoded.count,
            activeRootDigests: activeRootDigests.union([checkpoint.rootDigest])
        )
        let directory = baseDirectory.appendingPathComponent(checkpoint.rootDigest, isDirectory: true)
        let directoryExisted = fileManager.fileExists(atPath: directory.path)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("checkpoint.json")
        let temporary = directory.appendingPathComponent("checkpoint.\(UUID().uuidString).tmp")
        let evictionStaging = baseDirectory.appendingPathComponent(".eviction-\(UUID().uuidString)")
        var stagedEvictions: [(original: URL, staged: URL)] = []
        do {
            fileManager.createFile(atPath: temporary.path, contents: nil)
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: encoded)
            try handle.synchronize()
            try handle.close()
            if !evictionPlan.isEmpty {
                try fileManager.createDirectory(at: evictionStaging, withIntermediateDirectories: true)
                for original in evictionPlan {
                    let staged = evictionStaging.appendingPathComponent(original.lastPathComponent)
                    try fileManager.moveItem(at: original, to: staged)
                    stagedEvictions.append((original, staged))
                }
            }
            try beforeCommit?()
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            recentEvictedRootDigests.append(contentsOf: stagedEvictions.map { $0.original.lastPathComponent })
            try? fileManager.removeItem(at: evictionStaging)
            return destination
        } catch {
            try? fileManager.removeItem(at: temporary)
            var rollbackFailures: [String] = []
            for item in stagedEvictions.reversed() where fileManager.fileExists(atPath: item.staged.path) {
                do {
                    try fileManager.moveItem(at: item.staged, to: item.original)
                } catch {
                    rollbackFailures.append("\(item.original.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if rollbackFailures.isEmpty {
                try? fileManager.removeItem(at: evictionStaging)
                if !directoryExisted {
                    try? fileManager.removeItem(at: directory)
                }
            } else {
                throw AIShellError.checkpointWriteFailed(
                    "checkpoint commit failed (\(error.localizedDescription)); eviction rollback failed: "
                        + rollbackFailures.joined(separator: "; ")
                        + "; staging preserved at \(evictionStaging.path)"
                )
            }
            if let aishellError = error as? AIShellError { throw aishellError }
            throw AIShellError.checkpointWriteFailed(error.localizedDescription)
        }
    }

    func takeRecentEvictions() -> [String] {
        defer { recentEvictedRootDigests.removeAll(keepingCapacity: true) }
        return recentEvictedRootDigests
    }

    private func planEvictions(
        incomingRootDigest: String,
        incomingBytes: Int,
        activeRootDigests: Set<String>
    ) throws -> [URL] {
        let directories = try checkpointDirectories()
        let existingIncomingBytes = try fileSize(
            baseDirectory.appendingPathComponent(incomingRootDigest).appendingPathComponent("checkpoint.json")
        )
        var currentTotal = 0
        for directory in directories {
            currentTotal += try fileSize(directory.appendingPathComponent("checkpoint.json"))
        }
        var total = currentTotal - existingIncomingBytes + incomingBytes
        var rootCount = directories.contains { $0.lastPathComponent == incomingRootDigest }
            ? directories.count : directories.count + 1
        guard total > quota.maximumTotalBytes || rootCount > quota.maximumRoots else { return [] }

        var candidates: [(URL, Date)] = []
        for directory in directories where !activeRootDigests.contains(directory.lastPathComponent) {
            guard let checkpoint = try? load(rootDigest: directory.lastPathComponent) else { continue }
            candidates.append((directory, checkpoint.lastAccessedAt))
        }
        candidates.sort {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.lastPathComponent < $1.0.lastPathComponent
        }
        var planned: [URL] = []
        for (directory, _) in candidates
            where total > quota.maximumTotalBytes || rootCount > quota.maximumRoots {
            let bytes = try fileSize(directory.appendingPathComponent("checkpoint.json"))
            planned.append(directory)
            total -= bytes
            rootCount -= 1
        }
        guard total <= quota.maximumTotalBytes, rootCount <= quota.maximumRoots else {
            throw AIShellError.checkpointQuotaExceeded(
                "全体容量上限（\(quota.maximumTotalBytes) bytes）又はroot数上限を満たせません。"
            )
        }
        return planned
    }

    private func checkpointDirectories() throws -> [URL] {
        guard fileManager.fileExists(atPath: baseDirectory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                && fileManager.fileExists(atPath: $0.appendingPathComponent("checkpoint.json").path)
        }
    }

    private func checkpointURL(rootDigest: String) throws -> URL {
        guard rootDigest.count == 64,
              rootDigest.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...102).contains($0.value)
              }) else {
            throw AIShellError.invalidArgument("root_digestはlowercase SHA-256である必要があります")
        }
        return baseDirectory.appendingPathComponent(rootDigest, isDirectory: true)
            .appendingPathComponent("checkpoint.json")
    }

    private func fileSize(_ url: URL) throws -> Int {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        return try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }

    private static func validateEntries(
        _ entries: [WorkspaceCheckpointEntry],
        path: String,
        requiresCanonicalOrder: Bool = false
    ) throws {
        var previousPath: String?
        var seen = Set<String>()
        for entry in entries {
            guard !entry.path.isEmpty,
                  !entry.path.hasPrefix("/"),
                  !containsParentTraversalComponent(entry.path),
                  previousPath.map({ !requiresCanonicalOrder || $0 < entry.path }) ?? true,
                  requiresCanonicalOrder || seen.insert(entry.path).inserted else {
                throw AIShellError.checkpointCorrupt("不正又は重複したentry path: \(path)")
            }
            previousPath = entry.path
            switch (entry.kind, entry.hashState, entry.sha256) {
            case (.directory, .notApplicable, nil), (.file, .deferred, nil):
                break
            case let (.file, .hashed, digest?) where digest.count == 64:
                break
            default:
                throw AIShellError.checkpointCorrupt("entry hash invariant違反: \(entry.path)")
            }
        }
    }

    private static func containsParentTraversalComponent(_ path: String) -> Bool {
        path == ".." || path.hasPrefix("../") || path.hasSuffix("/..") || path.contains("/../")
    }

    private static func validateJournal(_ checkpoint: WorkspaceCheckpoint, path: String) throws {
        let sequences = checkpoint.journalEvents.map(\.sequence)
        let changeSequences = (checkpoint.journalChanges ?? []).map(\.sequence)
        guard sequences == sequences.sorted(),
              Set(sequences).count == sequences.count,
              checkpoint.journalEvents.allSatisfy({ $0.sequence <= checkpoint.journalSequence }),
              changeSequences == changeSequences.sorted(),
              Set(changeSequences).count == changeSequences.count,
              Set(changeSequences).isSubset(of: Set(sequences)),
              checkpoint.lastEventID.map({ last in
                  checkpoint.journalEvents.compactMap(\.eventID).allSatisfy { $0 <= last }
              }) ?? checkpoint.journalEvents.allSatisfy({ $0.eventID == nil }) else {
            throw AIShellError.checkpointCorrupt("journal invariant違反: \(path)")
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
