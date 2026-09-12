import CryptoKit
import Darwin
import Foundation

public struct LegacyControlCompatReceipt: Codable, Equatable, Sendable {
    public let expiresAt: Date
    public let requestDigest: String
    public let result: ApplyChangeSetControlResult

    public init(expiresAt: Date, requestDigest: String, result: ApplyChangeSetControlResult) {
        self.expiresAt = expiresAt
        self.requestDigest = requestDigest
        self.result = result
    }
}

public struct LegacyControlCompatSnapshot: Codable, Equatable, Sendable {
    public let sourceDigest: String
    public let receipts: [String: LegacyControlCompatReceipt]

    public init(
        sourceDigest: String,
        receipts: [String: LegacyControlCompatReceipt]
    ) {
        self.sourceDigest = sourceDigest
        self.receipts = receipts
    }
}

public enum LegacyControlCompatLookup: Equatable, Sendable {
    case missing
    case expired
    case replay(ApplyChangeSetControlResult)
}

public struct LegacyControlCompatStoreError: Error, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case storeCorrupt = "CHANGE_SET_STORE_CORRUPT"
        case secretStoreUnavailable = "CHANGE_SET_SECRET_STORE_UNAVAILABLE"
        case importConflict = "LEGACY_CONTROL_COMPAT_IMPORT_CONFLICT"
        case requestConflict = "CLIENT_CONTROL_REQUEST_CONFLICT"
        case capacityExceeded = "CLIENT_CONTROL_CAPACITY_EXCEEDED"
    }

    public let code: Code
    public let message: String

    public init(_ code: Code, _ message: String = "") {
        self.code = code
        self.message = message
    }
}

/// 旧monolithic control receiptをcutover後もexact replayするための小さな永続store。
/// sourceDigestはplaintextだけでなくAEADのAADにも含め、別snapshotへの差し替えを拒否する。
public actor LegacyControlCompatStore {
    public static let defaultReceiptCapacity = 128
    public static let maximumBankByteCount = 16 * 1_024 * 1_024

    private enum Bank: String, Codable, Sendable {
        case a
        case b

        var other: Bank { self == .a ? .b : .a }
    }

    private struct Image: Codable, Equatable, Sendable {
        let schema: String
        let sourceDigest: String
        var generation: UInt64
        var receipts: [String: LegacyControlCompatReceipt]
    }

    private struct Envelope: Codable, Sendable {
        let schema: String
        let sourceDigest: String
        let generation: UInt64
        let nonce: Data
        let ciphertext: Data
        let tag: Data
    }

    private struct AuthenticatedBinding: Codable, Sendable {
        let schema: String
        let sourceDigest: String
        let generation: UInt64
    }

    enum FailurePoint: Sendable {
        case beforeRename
        case afterRename
    }

    private enum BankLoad {
        case absent
        case valid(Image)
        case invalid
    }

    private let directory: URL
    private let legacyKey: Data?
    private let receiptCapacity: Int
    private let failurePoint: FailurePoint?
    private var image: Image?
    private var activeBank: Bank?

    public init(
        directory: URL,
        stateDirectory: URL,
        receiptCapacity: Int = LegacyControlCompatStore.defaultReceiptCapacity
    ) throws {
        let keyData = try LegacyChangeSetEncryption.key(in: stateDirectory)
        try self.init(directory: directory, keyData: keyData, receiptCapacity: receiptCapacity)
    }

    init(
        directory: URL,
        keyData: Data? = nil,
        receiptCapacity: Int = LegacyControlCompatStore.defaultReceiptCapacity,
        failurePoint: FailurePoint? = nil,
        loadHook: (@Sendable (URL) throws -> Void)? = nil
    ) throws {
        guard receiptCapacity > 0 else {
            throw LegacyControlCompatStoreError(.secretStoreUnavailable)
        }
        self.directory = directory
        self.legacyKey = keyData
        self.receiptCapacity = receiptCapacity
        self.failurePoint = failurePoint
        try Self.prepareDirectory(directory)

        let a = try Self.load(.a, directory: directory, key: self.legacyKey, afterOpen: loadHook)
        let b = try Self.load(.b, directory: directory, key: self.legacyKey, afterOpen: loadHook)
        switch (a, b) {
        case (.absent, .absent):
            image = nil
            activeBank = nil
        default:
            let valid: [(Bank, Image)] = [(.a, a), (.b, b)].compactMap { bank, load in
                if case let .valid(image) = load { return (bank, image) }
                return nil
            }
            if valid.count == 2 {
                try Self.validatePair(valid[0].1, valid[1].1)
            }
            guard let newest = valid.max(by: { $0.1.generation < $1.1.generation }) else {
                throw LegacyControlCompatStoreError(.storeCorrupt, "no compatibility bank")
            }
            image = newest.1
            activeBank = newest.0
        }
    }

    /// empty storeへの一度だけのimport。同じsnapshotの再試行だけをexact replayとして許可する。
    public func importLegacy(_ snapshot: LegacyControlCompatSnapshot) throws {
        try Self.validate(snapshot, receiptCapacity: receiptCapacity)
        let candidate = Image(
            schema: "aishell.change-set-legacy-control-compat.v1",
            sourceDigest: snapshot.sourceDigest,
            generation: 1,
            receipts: snapshot.receipts
        )
        if let image {
            guard image.sourceDigest == candidate.sourceDigest,
                  image.receipts == candidate.receipts else {
                throw LegacyControlCompatStoreError(.importConflict)
            }
            return
        }
        try persist(candidate)
    }

    public func sourceDigest() -> String? { image?.sourceDigest }

    public func lookup(
        controlRequestID: String,
        requestDigest: String,
        now: Date
    ) throws -> LegacyControlCompatLookup {
        guard let receipt = image?.receipts[controlRequestID] else { return .missing }
        guard receipt.requestDigest == requestDigest else {
            throw LegacyControlCompatStoreError(.requestConflict)
        }
        guard receipt.expiresAt > now else { return .expired }
        return .replay(receipt.result)
    }

    public func unexpiredReceiptCount(now: Date) -> Int {
        image?.receipts.values.lazy.filter { $0.expiresAt > now }.count ?? 0
    }

    public func remainingReceiptCapacity(now: Date) -> Int {
        max(0, receiptCapacity - unexpiredReceiptCount(now: now))
    }

    public func requireReceiptCapacity(additionalCount: Int, now: Date) throws {
        guard additionalCount >= 0,
              unexpiredReceiptCount(now: now) + additionalCount <= receiptCapacity else {
            throw LegacyControlCompatStoreError(.capacityExceeded)
        }
    }

    /// 編集取消しの結果を保存し、同じ依頼の再試行へ同じ結果を返す。
    @discardableResult
    public func record(
        controlRequestID: String,
        requestDigest: String,
        result: ApplyChangeSetControlResult,
        expiresAt: Date,
        now: Date
    ) throws -> ApplyChangeSetControlResult {
        guard var next = image else {
            throw LegacyControlCompatStoreError(.storeCorrupt, "compatibility store is not initialized")
        }
        if let existing = next.receipts[controlRequestID] {
            guard existing.requestDigest == requestDigest else {
                throw LegacyControlCompatStoreError(.requestConflict)
            }
            guard existing.expiresAt > now else {
                throw LegacyControlCompatStoreError(.requestConflict, "expired control request ID cannot be reused")
            }
            return existing.result
        }
        next.receipts = next.receipts.filter { $0.value.expiresAt > now }
        guard next.receipts.count < receiptCapacity else {
            throw LegacyControlCompatStoreError(.capacityExceeded)
        }
        next.receipts[controlRequestID] = .init(
            expiresAt: expiresAt,
            requestDigest: requestDigest,
            result: result
        )
        guard next.generation < UInt64.max else {
            throw LegacyControlCompatStoreError(.storeCorrupt, "compatibility generation exhausted")
        }
        next.generation += 1
        try persist(next)
        return result
    }

    /// 期限切れの結果記録を削除する。
    @discardableResult
    public func cleanupExpired(now: Date) throws -> Int {
        guard var next = image else { return 0 }
        let before = next.receipts.count
        next.receipts = next.receipts.filter { $0.value.expiresAt > now }
        let removed = before - next.receipts.count
        guard removed > 0 else { return 0 }
        next.generation += 1
        try persist(next)
        return removed
    }

    private func persist(_ next: Image) throws {
        let target = activeBank?.other ?? .a
        let destination = Self.bankURL(target, in: directory)
        let temporary = directory.appendingPathComponent(".compat-\(target.rawValue).\(UUID().uuidString).tmp")
        let data = try Self.sortedEncoder.encode(next)
        try Self.durableWrite(data, to: temporary)
        if failurePoint == .beforeRename {
            throw LegacyControlCompatStoreError(.storeCorrupt, "simulated crash before compatibility bank rename")
        }
        guard rename(temporary.path, destination.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw LegacyControlCompatStoreError(.storeCorrupt, "compatibility bank rename failed")
        }
        try Self.fsyncDirectory(directory)
        image = next
        activeBank = target
        if failurePoint == .afterRename {
            throw LegacyControlCompatStoreError(.storeCorrupt, "simulated crash after compatibility bank rename")
        }
    }

    private static func load(
        _ bank: Bank,
        directory: URL,
        key: Data?,
        afterOpen: (@Sendable (URL) throws -> Void)?
    ) throws -> BankLoad {
        let url = bankURL(bank, in: directory)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            return errno == ENOENT ? .absent : .invalid
        }
        var mustClose = true
        defer { if mustClose { close(descriptor) } }
        try afterOpen?(url)
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(), (status.st_mode & 0o077) == 0, status.st_nlink == 1,
              status.st_size > 0, status.st_size <= off_t(maximumBankByteCount),
              let data = try? readExact(descriptor, byteCount: Int(status.st_size)) else { return .invalid }
        guard close(descriptor) == 0 else { return .invalid }
        mustClose = false
        do {
            let plaintext: Data
            if try LegacyChangeSetEncryption.schema(data) == "aishell.change-set-legacy-control-compat-envelope.v1" {
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                let binding = AuthenticatedBinding(schema: envelope.schema,
                    sourceDigest: envelope.sourceDigest, generation: envelope.generation)
                plaintext = try LegacyChangeSetEncryption.decode(data, key: key,
                    aad: try sortedEncoder.encode(binding))
            } else {
                plaintext = data
            }
            let image = try JSONDecoder().decode(Image.self, from: plaintext)
            guard image.schema == "aishell.change-set-legacy-control-compat.v1",
                  isSHA256(image.sourceDigest), image.generation > 0 else { return .invalid }
            return .valid(image)
        } catch {
            return .invalid
        }
    }

    private static func readExact(_ descriptor: Int32, byteCount: Int) throws -> Data {
        var data = Data(count: byteCount)
        var offset = 0
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < byteCount {
                let count = Darwin.read(descriptor, base.advanced(by: offset), byteCount - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw LegacyControlCompatStoreError(.storeCorrupt, "truncated compatibility bank")
                }
                offset += count
            }
        }
        var trailing: UInt8 = 0
        while true {
            let count = Darwin.read(descriptor, &trailing, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 0 else {
                throw LegacyControlCompatStoreError(.storeCorrupt, "compatibility bank size changed while reading")
            }
            break
        }
        return data
    }

    private static func validate(
        _ snapshot: LegacyControlCompatSnapshot,
        receiptCapacity: Int
    ) throws {
        guard isSHA256(snapshot.sourceDigest), snapshot.receipts.count <= receiptCapacity,
              snapshot.receipts.allSatisfy({ id, receipt in
                  !id.isEmpty && id.utf8.count <= 128 && isSHA256(receipt.requestDigest)
                      && receipt.result.controlRequestID == id
              }) else {
            throw LegacyControlCompatStoreError(.storeCorrupt, "invalid legacy compatibility snapshot")
        }
    }

    /// 保存されたbank同士も、単一のcleanup又はcontrol追加として接続できなければforkである。
    private static func validatePair(_ lhs: Image, _ rhs: Image) throws {
        if lhs.generation == rhs.generation {
            guard lhs == rhs else {
                throw LegacyControlCompatStoreError(.storeCorrupt, "compatibility bank generation fork")
            }
            return
        }
        let low: Image
        let high: Image
        if lhs.generation < rhs.generation { (low, high) = (lhs, rhs) }
        else { (low, high) = (rhs, lhs) }
        let commonReceiptsAreStable = high.receipts.allSatisfy { id, receipt in
            guard let previous = low.receipts[id] else { return true }
            return previous == receipt
        }
        let addedReceiptCount = high.receipts.keys.filter { low.receipts[$0] == nil }.count
        let cleanupTransition = addedReceiptCount == 0
            && high.receipts.allSatisfy({ id, receipt in low.receipts[id] == receipt })
        let recordTransition = addedReceiptCount == 1 && commonReceiptsAreStable
        guard low.generation < UInt64.max, high.generation == low.generation + 1,
              high.sourceDigest == low.sourceDigest,
              cleanupTransition || recordTransition else {
            throw LegacyControlCompatStoreError(.storeCorrupt, "compatibility bank fork")
        }
    }

    private static func prepareDirectory(_ directory: URL) throws {
        var status = stat()
        if lstat(directory.path, &status) == 0 {
            guard (status.st_mode & S_IFMT) == S_IFDIR, status.st_uid == geteuid(),
                  (status.st_mode & 0o077) == 0 else {
                throw LegacyControlCompatStoreError(.storeCorrupt, "compatibility directory is not owner-only")
            }
        } else {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        guard chmod(directory.path, 0o700) == 0 else {
            throw LegacyControlCompatStoreError(.storeCorrupt, "compatibility directory chmod failed")
        }
    }

    private static func durableWrite(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw LegacyControlCompatStoreError(.storeCorrupt, "compatibility bank open failed")
        }
        var mustClose = true
        defer { if mustClose { close(descriptor) } }
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                guard count > 0 else {
                    throw LegacyControlCompatStoreError(.storeCorrupt, "compatibility bank write failed")
                }
                offset += count
            }
        }
        guard fchmod(descriptor, 0o600) == 0, fsync(descriptor) == 0, close(descriptor) == 0 else {
            throw LegacyControlCompatStoreError(.storeCorrupt, "compatibility bank fsync failed")
        }
        mustClose = false
    }

    private static func fsyncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw LegacyControlCompatStoreError(.storeCorrupt, "compatibility directory open failed")
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw LegacyControlCompatStoreError(.storeCorrupt, "compatibility directory fsync failed")
        }
    }

    private static func bankURL(_ bank: Bank, in directory: URL) -> URL {
        directory.appendingPathComponent("legacy-control-compat-\(bank.rawValue).enc")
    }

    private static var sortedEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
