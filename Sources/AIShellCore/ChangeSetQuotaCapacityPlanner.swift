import CryptoKit
import Darwin
import Foundation

/// `apply_change_set` が admission 後に生成し得る material を、実 payload の encode 結果から予約へ変換する。
///
/// byte 数の係数推定はここへ持ち込まない。呼び出し側は production と同じ encoder で作った候補を渡し、
/// planner は候補集合の最大値だけを採用する。
struct ChangeSetQuotaCapacityPlanner {
    struct EncodedCandidates: Sendable {
        let canonical: Data
        let manifest: Data
        let diff: ChangeSetDiffArtifactBuilder.Output
        let evidenceMetadata: [Data]
        let abortDiff: Data
        let abortEvidenceMetadata: [Data]
        let state: [Data]
        let wal: [Data]
        let terminal: [Data]

        init(
            canonical: Data,
            manifest: Data,
            diff: ChangeSetDiffArtifactBuilder.Output,
            evidenceMetadata: [Data],
            abortDiff: Data,
            abortEvidenceMetadata: [Data],
            state: [Data],
            wal: [Data],
            terminal: [Data]
        ) {
            self.canonical = canonical
            self.manifest = manifest
            self.diff = diff
            self.evidenceMetadata = evidenceMetadata
            self.abortDiff = abortDiff
            self.abortEvidenceMetadata = abortEvidenceMetadata
            self.state = state
            self.wal = wal
            self.terminal = terminal
        }
    }

    struct DirectMaterial: Sendable {
        let id: String
        let idempotencyKey: String
        let kind: ChangeSetQuotaLedger.MaterialKind
        let bytes: Int
        let directory: URL
    }

    static func capacities(
        digest: String,
        candidates: EncodedCandidates,
        reservationDirectory: URL,
        evidenceDirectory: URL,
        transactionDirectory: URL,
        stateDirectory: URL,
        direct: [DirectMaterial]
    ) throws -> [ChangeSetQuotaLedger.Capacity] {
        func maximum(_ values: [Data], material: String) throws -> Int {
            guard let result = values.map(\.count).max() else {
                throw ApplyChangeSetError(.changeSetStoreCorrupt, "quota candidate is empty: \(material)")
            }
            return result
        }

        var result: [ChangeSetQuotaLedger.Capacity] = [
            .init(id: "canonical", idempotencyKey: "canonical:\(digest)", kind: .canonicalEnvelope,
                maximumEncodedBytes: candidates.canonical.count, allocationDirectory: reservationDirectory),
            .init(id: "manifest", idempotencyKey: "manifest:\(digest)", kind: .transactionManifest,
                maximumEncodedBytes: candidates.manifest.count, allocationDirectory: transactionDirectory),
            .init(id: "diff_data", idempotencyKey: "diff-data:\(digest)", kind: .evidenceData,
                maximumEncodedBytes: candidates.diff.artifact.count, allocationDirectory: evidenceDirectory),
            .init(id: "diff_metadata", idempotencyKey: "diff-metadata:\(digest)", kind: .evidenceMetadata,
                maximumEncodedBytes: try maximum(candidates.evidenceMetadata, material: "diff_metadata"), allocationDirectory: evidenceDirectory),
            .init(id: "diff_metadata_final", idempotencyKey: "diff-metadata-final:\(digest)", kind: .evidenceMetadata,
                maximumEncodedBytes: try maximum(candidates.evidenceMetadata, material: "diff_metadata_final"), allocationDirectory: evidenceDirectory),
            .init(id: "abort_diff_data", idempotencyKey: "abort-diff-data:\(digest)", kind: .evidenceData,
                maximumEncodedBytes: candidates.abortDiff.count, allocationDirectory: evidenceDirectory),
            .init(id: "abort_diff_metadata", idempotencyKey: "abort-diff-metadata:\(digest)", kind: .evidenceMetadata,
                maximumEncodedBytes: try maximum(candidates.abortEvidenceMetadata, material: "abort_diff_metadata"), allocationDirectory: evidenceDirectory),
            .init(id: "abort_diff_metadata_final", idempotencyKey: "abort-diff-metadata-final:\(digest)", kind: .evidenceMetadata,
                maximumEncodedBytes: try maximum(candidates.abortEvidenceMetadata, material: "abort_diff_metadata_final"), allocationDirectory: evidenceDirectory),
        ]
        for (index, bytes) in candidates.state.enumerated() {
            result.append(.init(id: "state_\(index)", idempotencyKey: "state:\(index):\(digest)", kind: .stateSnapshot,
                maximumEncodedBytes: bytes.count, allocationDirectory: stateDirectory))
        }
        for (index, bytes) in candidates.wal.enumerated() {
            result.append(.init(id: "wal_\(index)", idempotencyKey: "wal:\(index):\(digest)", kind: .transactionJournal,
                maximumEncodedBytes: bytes.count, allocationDirectory: stateDirectory))
        }
        for (index, bytes) in candidates.terminal.enumerated() {
            result.append(.init(id: "terminal_\(index)", idempotencyKey: "terminal:\(index):\(digest)", kind: .terminalReplay,
                maximumEncodedBytes: bytes.count, allocationDirectory: stateDirectory))
        }
        result.append(contentsOf: direct.map {
            .init(id: $0.id, idempotencyKey: $0.idempotencyKey, kind: $0.kind,
                maximumEncodedBytes: $0.bytes, allocationDirectory: $0.directory)
        })
        return result
    }

    private struct ReservationAAD: Codable {
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

    private struct ReservationRecord: Codable {
        let schema: String
        let reservationID: String
        let requestDigest: String
        let rootDigest: String
        let clientID: String
        let clientEpoch: Int
        let requestSequence: Int
        let plaintextLength: Int
        let quotaBytes: Int
        let nonce: String
        let ciphertext: String
        let tag: String
    }

    static func canonicalEnvelope(
        reservationID: String,
        digest: String,
        request: ApplyChangeSetRequest,
        root: URL,
        encryptionKey: SymmetricKey
    ) throws -> Data {
        let plaintext = try sortedEncoder.encode(request)
        let aad = ReservationAAD(schema: "aishell.apply-change-set-reservation-record.v1", reservationID: reservationID,
            requestDigest: digest, rootDigest: root.standardizedFileURL.resolvingSymlinksInPath().path.sha256,
            clientID: request.clientID, clientEpoch: request.clientEpoch, requestSequence: request.requestSequence,
            plaintextLength: plaintext.count, quotaBytes: 0)
        let sealed = try AES.GCM.seal(plaintext, using: encryptionKey, authenticating: try sortedEncoder.encode(aad))
        return try sortedEncoder.encode(ReservationRecord(schema: aad.schema, reservationID: aad.reservationID,
            requestDigest: aad.requestDigest, rootDigest: aad.rootDigest, clientID: aad.clientID,
            clientEpoch: aad.clientEpoch, requestSequence: aad.requestSequence,
            plaintextLength: aad.plaintextLength, quotaBytes: 0, nonce: Data(sealed.nonce).base64EncodedString(),
            ciphertext: sealed.ciphertext.base64EncodedString(), tag: sealed.tag.base64EncodedString()))
    }

    struct FilesystemPayload: Sendable {
        let manifest: Data
        let diff: ChangeSetDiffArtifactBuilder.Output
        let result: ApplyChangeSetResult
    }

    /// inode は admission 後に割り当てられるため、合法値の最大 decimal 表現で shadow encode する。
    static func filesystemPayload(request: ApplyChangeSetRequest, digest: String, root: URL) throws -> FilesystemPayload {
        let transactionID = request.transactionIdentity
        let identity = "\(UInt64.max):\(UInt64.max)"
        var parent: [String: String] = [:]
        var stageIdentity: [String: String] = [:]
        var stageSHA: [String: String] = [:]
        var changes: [ChangeSetDiffArtifactBuilder.Change] = []
        var changeResults: [ApplyChangeSetChangeResult] = []
        var beforeTotal = 0
        var afterTotal = 0

        func current(_ path: String) throws -> (Data, UInt16)? {
            let url = root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw POSIXError(.EIO) }
            return (try Data(contentsOf: url), UInt16(info.st_mode & 0o7777))
        }
        for path in Set(request.changes.flatMap(\.paths)) { parent[path] = identity }
        for change in request.changes {
            switch change {
            case let .create(id, path, _, content):
                let after = content.bytes ?? Data(); afterTotal += after.count
                stageIdentity[path] = identity; stageSHA[path] = after.sha256
                changes.append(.init(changeID: id, kind: .create, before: nil,
                    after: .init(path: path, identity: identity, mode: 0o644, bytes: after)))
                changeResults.append(.init(changeID: id, afterSHA256: after.sha256, kind: "create", afterPath: path,
                    afterIdentity: identity, afterSizeBytes: after.count, afterMetadata: .init(mode: 0o644)))
            case let .write(id, path, _, content):
                let before = try current(path) ?? (Data(), 0o644); let after = content.bytes ?? Data()
                let maximumMode: UInt16 = 0o7777
                beforeTotal += before.0.count; afterTotal += after.count; stageIdentity[path] = identity; stageSHA[path] = after.sha256
                changes.append(.init(changeID: id, kind: .write,
                    before: .init(path: path, identity: identity, mode: maximumMode, bytes: before.0),
                    after: .init(path: path, identity: identity, mode: maximumMode, bytes: after)))
                changeResults.append(.init(changeID: id, afterSHA256: after.sha256, kind: "write", beforePath: path,
                    afterPath: path, beforeIdentity: identity, afterIdentity: identity, beforeSHA256: before.0.sha256,
                    beforeSizeBytes: before.0.count, afterSizeBytes: after.count, beforeMetadata: .init(mode: maximumMode),
                    afterMetadata: .init(mode: maximumMode)))
            case let .delete(id, path, _):
                let before = try current(path) ?? (Data(), 0o644); beforeTotal += before.0.count
                let maximumMode: UInt16 = 0o7777
                changes.append(.init(changeID: id, kind: .delete,
                    before: .init(path: path, identity: identity, mode: maximumMode, bytes: before.0), after: nil))
                changeResults.append(.init(changeID: id, afterSHA256: nil, kind: "delete", beforePath: path,
                    beforeIdentity: identity, beforeSHA256: before.0.sha256, beforeSizeBytes: before.0.count,
                    beforeMetadata: .init(mode: maximumMode)))
            case let .rename(id, source, _, destination, _):
                let before = try current(source) ?? (Data(), 0o644); beforeTotal += before.0.count; afterTotal += before.0.count
                let maximumMode: UInt16 = 0o7777
                stageIdentity[destination] = identity; stageSHA[destination] = before.0.sha256
                changes.append(.init(changeID: id, kind: .rename,
                    before: .init(path: source, identity: identity, mode: maximumMode, bytes: before.0),
                    after: .init(path: destination, identity: identity, mode: maximumMode, bytes: before.0)))
                changeResults.append(.init(changeID: id, afterSHA256: before.0.sha256, kind: "rename", beforePath: source,
                    afterPath: destination, beforeIdentity: identity, afterIdentity: identity, beforeSHA256: before.0.sha256,
                    beforeSizeBytes: before.0.count, afterSizeBytes: before.0.count, beforeMetadata: .init(mode: maximumMode),
                    afterMetadata: .init(mode: maximumMode)))
            }
        }
        let manifest = try JSONSerialization.data(withJSONObject: [
            "schema": "aishell.apply-change-set-transaction-manifest.v1", "transaction_id": transactionID,
            "request_digest": digest, "paths": request.changes.flatMap(\.paths), "parent_identity": parent,
            "stage_identity": stageIdentity, "stage_sha256": stageSHA,
        ], options: [.sortedKeys])
        let to = ApplyChangeSetCursor(root: request.cursor.root, generation: request.cursor.generation,
            sequence: request.cursor.sequence + 1)
        let output = try ChangeSetDiffArtifactBuilder.build(binding: .init(transactionID: transactionID,
            requestDigest: digest, manifestDigest: manifest.sha256, root: root.path, fromCursor: request.cursor, toCursor: to,
            clientID: request.clientID, clientEpoch: request.clientEpoch, requestSequence: request.requestSequence),
            changes: changes, previewBudget: request.diffByteBudget)
        let artifact = ApplyChangeSetArtifact(handle: "art_" + String(repeating: "f", count: 32), sha256: output.sha256,
            sizeBytes: output.artifact.count, expiresAt: .distantFuture)
        let summary = ApplyChangeSetSummary(createCount: changes.filter { $0.kind == .create }.count,
            writeCount: changes.filter { $0.kind == .write }.count, deleteCount: changes.filter { $0.kind == .delete }.count,
            renameCount: changes.filter { $0.kind == .rename }.count, beforeBytes: beforeTotal, afterBytes: afterTotal)
        let result = ApplyChangeSetResult(transactionID: transactionID, clientID: request.clientID,
            clientEpoch: request.clientEpoch, root: root.path, status: .committed, visibility: .aishellSerializedRecoverable,
            requestSequence: request.requestSequence, fromCursor: request.cursor, cursor: to, changes: changeResults,
            changedPaths: request.changes.flatMap(\.paths), transactionCursorAdvanced: true, diffArtifact: artifact,
            summary: summary, diffPreview: output.preview.bytes.base64EncodedString(), hasMore: output.preview.hasMore,
            returnedDiffBytes: output.preview.returnedBytes, omittedDiffBytes: output.preview.omittedBytes)
        return .init(manifest: manifest, diff: output, result: result)
    }

    static func evidenceMetadata(artifact: Data, retentionSeconds: Int) throws -> [Data] {
        let handle = "art_" + String(repeating: "f", count: 32)
        let metadata = ArtifactMetadata(handle: handle, kind: "apply-change-set-diff", sizeBytes: artifact.count,
            lineCount: artifact.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }, sha256: artifact.sha256,
            createdAt: .distantPast, expiresAt: .distantFuture, producer: "ApplyChangeSetService")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return [try encoder.encode(metadata)]
    }

    private static var sortedEncoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder
    }
}

private extension Data {
    var sha256: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}

private extension String {
    var sha256: String { Data(utf8).sha256 }
}
