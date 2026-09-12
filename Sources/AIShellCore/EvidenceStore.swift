import CryptoKit
import Darwin
import Foundation

public actor EvidenceStore {
    public static let defaultRetentionSeconds: TimeInterval = 86_400
    public static let defaultMaximumBytes = 512 * 1_024 * 1_024
    public static let maximumReadBytes = 1_048_576

    private let baseDirectory: URL
    private let maximumBytes: Int
    private let clock: @Sendable () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public struct QuotaMaterial: Sendable {
        public let ledger: ChangeSetQuotaLedger
        public let materialID: String
        public let idempotencyKey: String

        public init(ledger: ChangeSetQuotaLedger, materialID: String, idempotencyKey: String) {
            self.ledger = ledger
            self.materialID = materialID
            self.idempotencyKey = idempotencyKey
        }
    }

    public init(
        baseDirectory: URL,
        maximumBytes: Int = EvidenceStore.defaultMaximumBytes,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.baseDirectory = baseDirectory
        self.maximumBytes = max(1, maximumBytes)
        self.clock = clock
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func store(
        text: String,
        kind: String,
        producer: String,
        retentionSeconds: TimeInterval = EvidenceStore.defaultRetentionSeconds
    ) throws -> ArtifactMetadata {
        try store(
            data: Data(text.utf8),
            kind: kind,
            producer: producer,
            retentionSeconds: retentionSeconds
        )
    }

    public func store(
        data: Data,
        kind: String,
        producer: String,
        retentionSeconds: TimeInterval = EvidenceStore.defaultRetentionSeconds
    ) throws -> ArtifactMetadata {
        guard !kind.isEmpty, !producer.isEmpty else {
            throw AIShellError.invalidArgument("artifactのkindとproducerは必須です。")
        }
        try ensureDirectory()
        try garbageCollectExpired()
        let usedBytes = try currentStoredBytes()
        guard data.count <= maximumBytes - usedBytes else {
            throw AIShellError.evidenceQuotaExceeded(maximumBytes)
        }

        let now = clock()
        let handle = "art_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let metadata = ArtifactMetadata(
            handle: handle,
            kind: kind,
            sizeBytes: data.count,
            lineCount: Self.lineCount(in: data),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            createdAt: now,
            expiresAt: now.addingTimeInterval(max(1, retentionSeconds)),
            producer: producer
        )
        try Self.atomicDurableWrite(data, to: dataURL(for: handle))
        do {
            try Self.atomicDurableWrite(encoder.encode(metadata), to: metadataURL(for: handle))
            _ = try verifyCompleteArtifact(handle: handle, kind: kind, producer: producer, sha256: metadata.sha256)
        } catch {
            try? FileManager.default.removeItem(at: dataURL(for: handle))
            throw error
        }
        return metadata
    }

    /// apply_change_set用のquota-controlled write。
    /// dataとmetadataを、それぞれ事前予約されたextentへ直接書いてから最終pathへmaterializeする。
    public func store(
        data: Data,
        kind: String,
        producer: String,
        retentionSeconds: TimeInterval = EvidenceStore.defaultRetentionSeconds,
        dataQuota: QuotaMaterial,
        metadataQuota: QuotaMaterial,
        simulateCrashAfterDataRename: Bool = false
    ) async throws -> ArtifactMetadata {
        guard !kind.isEmpty, !producer.isEmpty else {
            throw AIShellError.invalidArgument("artifactのkindとproducerは必須です。")
        }
        try ensureDirectory()
        try garbageCollectExpired()
        let now = clock()
        let stableHandleDigest = SHA256.hash(data: Data((dataQuota.materialID + "\u{0}" + dataQuota.idempotencyKey).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let handle = "art_" + stableHandleDigest.prefix(32)
        let metadata = ArtifactMetadata(
            handle: handle,
            kind: kind,
            sizeBytes: data.count,
            lineCount: Self.lineCount(in: data),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            createdAt: now,
            expiresAt: now.addingTimeInterval(max(1, retentionSeconds)),
            producer: producer
        )
        let metadataData = try encoder.encode(metadata)
        do {
            try await Self.materialize(data, to: dataURL(for: handle), quota: dataQuota,
                crashPoint: simulateCrashAfterDataRename ? .quotaMaterialRenameAfter : nil)
            try await Self.materialize(metadataData, to: metadataURL(for: handle), quota: metadataQuota)
            return try verifyCompleteArtifact(handle: handle, kind: kind, producer: producer, sha256: metadata.sha256)
        } catch let crash as ApplyChangeSetSimulatedCrash {
            throw crash
        } catch {
            // quota ledgerがstatus=3で所有するfinalをここで直接消すと、次回reconcileが
            // identity欠損で停止する。terminal recoveryがledger identity照合付きで収束させる。
            throw error
        }
    }

    public func findCompleteArtifact(kind: String, producer: String, sha256: String, retentionSeconds: TimeInterval = EvidenceStore.defaultRetentionSeconds) throws -> ArtifactMetadata? {
        guard FileManager.default.fileExists(atPath: baseDirectory.path) else { return nil }
        let urls = try FileManager.default.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in urls {
            guard let metadata = try? decoder.decode(ArtifactMetadata.self, from: Data(contentsOf: url)),
                  metadata.kind == kind, metadata.producer == producer, metadata.sha256 == sha256,
                  clock() <= metadata.expiresAt else { continue }
            return try verifyCompleteArtifact(handle: metadata.handle, kind: kind, producer: producer, sha256: sha256)
        }
        let dataURLs = try FileManager.default.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "data" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in dataURLs where !FileManager.default.fileExists(atPath: metadataURL(for: url.deletingPathExtension().lastPathComponent).path) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == sha256 else { continue }
            let created = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? clock()
            let metadata = ArtifactMetadata(handle: url.deletingPathExtension().lastPathComponent, kind: kind,
                sizeBytes: data.count, lineCount: Self.lineCount(in: data), sha256: digest, createdAt: created,
                expiresAt: created.addingTimeInterval(max(1, retentionSeconds)), producer: producer)
            try Self.atomicDurableWrite(encoder.encode(metadata), to: metadataURL(for: metadata.handle))
            return try verifyCompleteArtifact(handle: metadata.handle, kind: kind, producer: producer, sha256: sha256)
        }
        return nil
    }

    public func finalizeArtifact(handle: String, expiresAt: Date) throws -> ArtifactMetadata {
        let current = try loadMetadata(handle: handle)
        if current.expiresAt == expiresAt {
            return try verifyCompleteArtifact(handle: handle, kind: current.kind, producer: current.producer, sha256: current.sha256)
        }
        let finalized = ArtifactMetadata(handle: current.handle, kind: current.kind, sizeBytes: current.sizeBytes,
            lineCount: current.lineCount, sha256: current.sha256, createdAt: current.createdAt,
            expiresAt: expiresAt, producer: current.producer)
        try Self.atomicDurableWrite(encoder.encode(finalized), to: metadataURL(for: handle))
        return try verifyCompleteArtifact(handle: handle, kind: current.kind, producer: current.producer, sha256: current.sha256)
    }

    /// quota-controlled artifact metadataのterminal世代を、旧世代とのatomic replacementで確定する。
    public func finalizeArtifact(
        handle: String,
        expiresAt: Date,
        currentQuota: QuotaMaterial,
        finalQuota: QuotaMaterial
    ) async throws -> ArtifactMetadata {
        // replacement intentの再開でfinal pathが新世代へ収束し得るため、metadataはreconcile後に読む。
        _ = try await finalQuota.ledger.reconcile()
        let current = try loadMetadata(handle: handle)
        let finalized = ArtifactMetadata(handle: current.handle, kind: current.kind, sizeBytes: current.sizeBytes,
            lineCount: current.lineCount, sha256: current.sha256, createdAt: current.createdAt,
            expiresAt: expiresAt, producer: current.producer)
        let data = try encoder.encode(finalized)
        let destination = metadataURL(for: handle)
        let views = try await finalQuota.ledger.materialViews()
        if views.contains(where: { $0.id == finalQuota.materialID && $0.state == .materialized }) {
            guard current.expiresAt == expiresAt else {
                throw ApplyChangeSetError(.changeSetStoreCorrupt, "terminal evidence expiry differs from quota receipt")
            }
            return try verifyCompleteArtifact(handle: handle, kind: current.kind, producer: current.producer, sha256: current.sha256)
        }

        let adopted = try await finalQuota.ledger.adoptReserve(materialID: finalQuota.materialID,
            idempotencyKey: finalQuota.idempotencyKey, finalURL: destination)
        let descriptor = open(adopted.extentURL.path, O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        do {
            try data.withUnsafeBytes { raw in
                var remaining = raw.count
                var pointer = raw.baseAddress
                while remaining > 0 {
                    let wrote = Darwin.write(descriptor, pointer, remaining)
                    guard wrote > 0 else { throw POSIXError(.EIO) }
                    remaining -= wrote
                    pointer = pointer?.advanced(by: wrote)
                }
            }
            guard fsync(descriptor) == 0, close(descriptor) == 0 else { throw POSIXError(.EIO) }
            _ = try await finalQuota.ledger.authorizeActual(materialID: finalQuota.materialID,
                idempotencyKey: finalQuota.idempotencyKey, data: data)
            _ = try await finalQuota.ledger.commitReplacement(oldMaterialID: currentQuota.materialID,
                oldIdempotencyKey: currentQuota.idempotencyKey, newMaterialID: finalQuota.materialID,
                newIdempotencyKey: finalQuota.idempotencyKey, finalURL: destination)
        } catch {
            close(descriptor)
            throw error
        }
        return try verifyCompleteArtifact(handle: handle, kind: finalized.kind, producer: finalized.producer, sha256: finalized.sha256)
    }

    public func verifyCompleteArtifact(handle: String, kind: String, producer: String, sha256: String) throws -> ArtifactMetadata {
        let metadata = try loadMetadata(handle: handle)
        // Expiry controls public reads and garbage collection. Recovery must still be able to
        // authenticate a complete artifact after its public retention window has elapsed.
        guard metadata.kind == kind, metadata.producer == producer, metadata.sha256 == sha256,
              let data = try? Data(contentsOf: dataURL(for: handle), options: .mappedIfSafe), data.count == metadata.sizeBytes,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == metadata.sha256 else {
            throw ApplyChangeSetError(.changeSetStoreCorrupt, "EVIDENCE_CORRUPT: artifact verification failed")
        }
        return metadata
    }

    public func completeData(handle: String, maximumBytes: Int) throws -> Data {
        let metadata = try loadMetadata(handle: handle)
        guard clock() <= metadata.expiresAt else { throw AIShellError.handleExpired(handle) }
        guard maximumBytes > 0, metadata.sizeBytes <= maximumBytes else {
            throw AIShellError.invalidArgument("diagnostic artifact exceeds the configured parse limit")
        }
        let data = try Data(contentsOf: dataURL(for: handle), options: .mappedIfSafe)
        guard data.count == metadata.sizeBytes,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == metadata.sha256 else {
            throw ApplyChangeSetError(.changeSetStoreCorrupt, "EVIDENCE_CORRUPT: artifact verification failed")
        }
        return data
    }

    public func store(
        fileAt sourceURL: URL,
        kind: String,
        producer: String,
        retentionSeconds: TimeInterval = EvidenceStore.defaultRetentionSeconds
    ) throws -> ArtifactMetadata {
        guard !kind.isEmpty, !producer.isEmpty else {
            throw AIShellError.invalidArgument("artifactのkindとproducerは必須です。")
        }
        try ensureDirectory()
        try garbageCollectExpired()
        let sourceInspection = try Self.inspectFile(sourceURL)
        let usedBytes = try currentStoredBytes()
        guard sourceInspection.size <= maximumBytes - usedBytes else {
            throw AIShellError.evidenceQuotaExceeded(maximumBytes)
        }
        let now = clock()
        let handle = "art_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        do {
            let destination = dataURL(for: handle)
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            let inspection = try Self.inspectFile(destination)
            guard inspection.size <= maximumBytes - usedBytes else {
                throw AIShellError.evidenceQuotaExceeded(maximumBytes)
            }
            let metadata = ArtifactMetadata(
                handle: handle,
                kind: kind,
                sizeBytes: inspection.size,
                lineCount: inspection.lineCount,
                sha256: inspection.sha256,
                createdAt: now,
                expiresAt: now.addingTimeInterval(max(1, retentionSeconds)),
                producer: producer
            )
            try encoder.encode(metadata).write(to: metadataURL(for: handle), options: [.atomic])
            return metadata
        } catch {
            discard(handle: handle)
            throw error
        }
    }

    public func read(
        handle: String,
        mode: ArtifactReadMode = .range(offset: 0, length: 65_536),
        byteBudget: Int = 65_536
    ) throws -> ArtifactSlice {
        let metadata = try loadMetadata(handle: handle)
        guard clock() <= metadata.expiresAt else {
            throw AIShellError.handleExpired(handle)
        }
        guard FileManager.default.fileExists(atPath: dataURL(for: handle).path) else {
            throw AIShellError.handleNotFound(handle)
        }
        return try Self.readSlice(handle: handle, url: dataURL(for: handle), totalBytes: metadata.sizeBytes,
            sha256: metadata.sha256, expiresAt: metadata.expiresAt, mode: mode, byteBudget: byteBudget)
    }

    static func readSlice(handle: String, url: URL, totalBytes: Int, sha256: String,
                          expiresAt: Date, mode: ArtifactReadMode, byteBudget: Int) throws -> ArtifactSlice {
        let budget = min(max(1, byteBudget), Self.maximumReadBytes)

        let selection: (offset: Int, data: Data, matchLine: Int?)
        switch mode {
        case let .range(offset, length):
            let start = min(max(0, offset), totalBytes)
            let count = min(max(0, length), budget, totalBytes - start)
            selection = (start, try Self.readRange(url: url, offset: start, count: count), nil)
        case let .tail(lines):
            let windowStart = max(0, totalBytes - budget)
            let window = try Self.readRange(
                url: url, offset: windowStart, count: totalBytes - windowStart
            )
            let tail = Self.tail(data: window, lines: max(1, lines), budget: budget)
            selection = (windowStart + tail.0, tail.1, nil)
        case let .around(pattern, contextLines):
            guard !pattern.isEmpty else {
                throw AIShellError.invalidArgument("patternは空にできません。")
            }
            guard totalBytes <= 64 * 1_024 * 1_024 else {
                throw AIShellError.invalidArgument("64MiB超のartifactではrangeまたはtailを使ってください。")
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            selection = try Self.around(
                data: data,
                pattern: pattern,
                contextLines: max(0, contextLines),
                budget: budget
            )
        }

        let end = selection.offset + selection.data.count
        let utf8 = String(data: selection.data, encoding: .utf8)
        return ArtifactSlice(
            handle: handle,
            encoding: utf8 == nil ? "base64" : "utf-8",
            text: utf8,
            base64: utf8 == nil ? selection.data.base64EncodedString() : nil,
            offset: selection.offset,
            returnedBytes: selection.data.count,
            totalBytes: totalBytes,
            omittedBytes: max(0, totalBytes - selection.data.count),
            eof: end == totalBytes,
            sha256: sha256,
            expiresAt: expiresAt,
            matchLine: selection.matchLine
        )
    }

    @discardableResult
    public func garbageCollectExpired() throws -> Int {
        guard FileManager.default.fileExists(atPath: baseDirectory.path) else { return 0 }
        var removed = 0
        for url in try FileManager.default.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)
        where url.pathExtension == "json" {
            guard let metadata = try? decoder.decode(ArtifactMetadata.self, from: Data(contentsOf: url)),
                  clock() > metadata.expiresAt else { continue }
            try? FileManager.default.removeItem(at: dataURL(for: metadata.handle))
            removed += 1
        }
        return removed
    }

    private func loadMetadata(handle: String) throws -> ArtifactMetadata {
        guard handle.hasPrefix("art_"),
              FileManager.default.fileExists(atPath: metadataURL(for: handle).path) else {
            throw AIShellError.handleNotFound(handle)
        }
        return try decoder.decode(ArtifactMetadata.self, from: Data(contentsOf: metadataURL(for: handle)))
    }

    private static func atomicDurableWrite(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        do {
            try data.withUnsafeBytes { raw in
                var remaining = raw.count; var pointer = raw.baseAddress
                while remaining > 0 {
                    let wrote = Darwin.write(fd, pointer, remaining)
                    guard wrote > 0 else { throw POSIXError(.EIO) }
                    remaining -= wrote; pointer = pointer?.advanced(by: wrote)
                }
            }
            guard fsync(fd) == 0, close(fd) == 0, rename(temporary.path, destination.path) == 0 else { throw POSIXError(.EIO) }
            let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard directoryFD >= 0, fsync(directoryFD) == 0 else { if directoryFD >= 0 { close(directoryFD) }; throw POSIXError(.EIO) }
            close(directoryFD)
        } catch {
            close(fd); unlink(temporary.path); throw error
        }
    }

    private static func materialize(_ data: Data, to destination: URL, quota: QuotaMaterial,
        crashPoint: ApplyChangeSetFailurePoint? = nil) async throws {
        do {
            _ = try await quota.ledger.reconcile()
            _ = try await quota.ledger.commitMaterialization(materialID: quota.materialID,
                idempotencyKey: quota.idempotencyKey, finalURL: destination)
            return
        } catch ChangeSetQuotaLedger.LedgerError.materializationIncomplete { }
        catch ChangeSetQuotaLedger.LedgerError.finalPathMismatch { }
        let adopted = try await quota.ledger.adoptReserve(
            materialID: quota.materialID,
            idempotencyKey: quota.idempotencyKey,
            finalURL: destination
        )
        let descriptor = open(adopted.extentURL.path, O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        do {
            try data.withUnsafeBytes { raw in
                var remaining = raw.count
                var pointer = raw.baseAddress
                while remaining > 0 {
                    let wrote = Darwin.write(descriptor, pointer, remaining)
                    guard wrote > 0 else { throw POSIXError(.EIO) }
                    remaining -= wrote
                    pointer = pointer?.advanced(by: wrote)
                }
            }
            guard fsync(descriptor) == 0, close(descriptor) == 0 else { throw POSIXError(.EIO) }
            _ = try await quota.ledger.authorizeActual(
                materialID: quota.materialID,
                idempotencyKey: quota.idempotencyKey,
                data: data
            )
            guard rename(adopted.extentURL.path, destination.path) == 0 else { throw POSIXError(.EXDEV) }
            let directoryFD = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard directoryFD >= 0, fsync(directoryFD) == 0 else {
                if directoryFD >= 0 { close(directoryFD) }
                throw POSIXError(.EIO)
            }
            close(directoryFD)
            if let crashPoint { throw ApplyChangeSetSimulatedCrash(point: crashPoint) }
            _ = try await quota.ledger.commitMaterialization(
                materialID: quota.materialID,
                idempotencyKey: quota.idempotencyKey,
                finalURL: destination
            )
        } catch {
            close(descriptor)
            throw error
        }
    }

    func discard(handle: String) {
        try? FileManager.default.removeItem(at: dataURL(for: handle))
        try? FileManager.default.removeItem(at: metadataURL(for: handle))
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    private func currentStoredBytes() throws -> Int {
        try FileManager.default.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ).filter { $0.pathExtension == "data" }.reduce(0) { total, url in
            total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
    }

    private func dataURL(for handle: String) -> URL {
        baseDirectory.appendingPathComponent(handle).appendingPathExtension("data")
    }

    private func metadataURL(for handle: String) -> URL {
        baseDirectory.appendingPathComponent(handle).appendingPathExtension("json")
    }

    private static func lineCount(in data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        let newlines = data.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        return newlines + (data.last == 0x0A ? 0 : 1)
    }

    private static func inspectFile(_ url: URL) throws -> (size: Int, lineCount: Int, sha256: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size = 0
        var newlines = 0
        var lastByte: UInt8?
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
            size += data.count
            newlines += data.reduce(into: 0) { count, byte in if byte == 0x0A { count += 1 } }
            lastByte = data.last
        }
        let lineCount = size == 0 ? 0 : newlines + (lastByte == 0x0A ? 0 : 1)
        return (
            size,
            lineCount,
            hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func readRange(url: URL, offset: Int, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: count) ?? Data()
    }

    private static func tail(data: Data, lines: Int, budget: Int) -> (Int, Data, Int?) {
        var start = data.count
        var newlines = 0
        while start > 0 {
            start -= 1
            if data[start] == 0x0A, start < data.count - 1 {
                newlines += 1
                if newlines == lines { start += 1; break }
            }
        }
        if data.count - start > budget { start = data.count - budget }
        return (start, data.subdata(in: start..<data.count), nil)
    }

    private static func around(
        data: Data,
        pattern: String,
        contextLines: Int,
        budget: Int
    ) throws -> (Int, Data, Int?) {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AIShellError.notTextFile("artifact")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let index = lines.firstIndex(where: { $0.contains(pattern) }) else {
            throw AIShellError.invalidArgument("patternがartifactに見つかりません。")
        }
        let lower = max(0, index - contextLines)
        let upper = min(lines.count - 1, index + contextLines)
        var selected = lines[lower...upper].joined(separator: "\n")
        if upper < lines.count - 1 || text.hasSuffix("\n") { selected += "\n" }
        var selectedData = Data(selected.utf8)
        if selectedData.count > budget { selectedData = Data(selectedData.prefix(budget)) }
        let offset = Data(lines[..<lower].joined(separator: "\n").utf8).count + (lower == 0 ? 0 : 1)
        return (offset, selectedData, index + 1)
    }
}
