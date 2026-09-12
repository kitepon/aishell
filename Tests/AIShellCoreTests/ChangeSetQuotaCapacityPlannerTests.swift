import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import AIShellCore

final class ChangeSetQuotaCapacityPlannerTests: XCTestCase {
    func test128ShortPathsManifestUsesActualEncodedSize() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = makeRequest(root: root, changes: (0..<128).map {
            .create(id: "c\($0)", path: "p\($0)", expected: .absent, content: .utf8("x"))
        })
        let digest = String(repeating: "d", count: 64)
        let filesystem = try ChangeSetQuotaCapacityPlanner.filesystemPayload(request: request, digest: digest, root: root)
        XCTAssertGreaterThan(filesystem.manifest.count, 8_192)
        let capacities = try capacities(root: root, request: request, filesystem: filesystem, digest: digest)
        XCTAssertEqual(capacities.first(where: { $0.id == "manifest" })?.maximumEncodedBytes,
            filesystem.manifest.count)
    }

    func testLongChangeIDAndMaximumModeAreIncludedInDiffCapacity() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "mode.txt"
        try Data("before\n".utf8).write(to: root.appendingPathComponent(path))
        chmod(root.appendingPathComponent(path).path, 0o600)
        let longID = String(repeating: "identifier/日本語", count: 4_096)
        let request = makeRequest(root: root, changes: [.write(id: longID, path: path,
            expected: .file(Data("before\n".utf8).sha256), content: .utf8("after\n"))])
        let digest = String(repeating: "d", count: 64)
        let filesystem = try ChangeSetQuotaCapacityPlanner.filesystemPayload(request: request, digest: digest, root: root)
        let decoded = try ChangeSetDiffArtifactBuilder.decode(filesystem.diff.artifact)
        XCTAssertEqual(decoded.header.changes.first?.before?.mode, 0o7777)
        XCTAssertEqual(decoded.header.changes.first?.changeID, longID)
        let capacities = try capacities(root: root, request: request, filesystem: filesystem, digest: digest)
        XCTAssertEqual(capacities.first(where: { $0.id == "diff_data" })?.maximumEncodedBytes,
            filesystem.diff.artifact.count)
    }

    func testEveryEncodedCandidateFitsItsTypedCapacity() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = makeRequest(root: root, changes: [.create(id: "id", path: "created", expected: .absent,
            content: .base64(Data(repeating: 0xff, count: 1_024).base64EncodedString()))])
        let digest = String(repeating: "d", count: 64)
        let filesystem = try ChangeSetQuotaCapacityPlanner.filesystemPayload(request: request, digest: digest, root: root)
        let canonical = try ChangeSetQuotaCapacityPlanner.canonicalEnvelope(reservationID: String(repeating: "r", count: 36),
            digest: digest, request: request, root: root, encryptionKey: SymmetricKey(size: .bits256))
        let metadata = try ChangeSetQuotaCapacityPlanner.evidenceMetadata(artifact: filesystem.diff.artifact,
            retentionSeconds: request.retentionSeconds)
        let abort = Data("{\"paths\":[]}".utf8)
        let abortMetadata = try ChangeSetQuotaCapacityPlanner.evidenceMetadata(artifact: abort,
            retentionSeconds: request.retentionSeconds)
        let state = [Data(repeating: 1, count: 7), Data(repeating: 2, count: 11)]
        let wal = [Data(repeating: 3, count: 13)]
        let terminal = [Data(repeating: 4, count: 17)]
        let encoded = ChangeSetQuotaCapacityPlanner.EncodedCandidates(canonical: canonical,
            manifest: filesystem.manifest, diff: filesystem.diff, evidenceMetadata: metadata,
            abortDiff: abort, abortEvidenceMetadata: abortMetadata, state: state, wal: wal, terminal: terminal)
        let capacities = try ChangeSetQuotaCapacityPlanner.capacities(digest: digest, candidates: encoded,
            reservationDirectory: root, evidenceDirectory: root, transactionDirectory: root,
            stateDirectory: root, direct: [])
        let planned = Dictionary(uniqueKeysWithValues: capacities.map { ($0.id, $0.maximumEncodedBytes) })
        XCTAssertLessThanOrEqual(canonical.count, planned["canonical"]!)
        XCTAssertLessThanOrEqual(filesystem.manifest.count, planned["manifest"]!)
        XCTAssertLessThanOrEqual(filesystem.diff.artifact.count, planned["diff_data"]!)
        for (index, candidate) in state.enumerated() { XCTAssertLessThanOrEqual(candidate.count, planned["state_\(index)"]!) }
        for (index, candidate) in wal.enumerated() { XCTAssertLessThanOrEqual(candidate.count, planned["wal_\(index)"]!) }
        for (index, candidate) in terminal.enumerated() { XCTAssertLessThanOrEqual(candidate.count, planned["terminal_\(index)"]!) }
    }

    private func capacities(root: URL, request: ApplyChangeSetRequest,
        filesystem: ChangeSetQuotaCapacityPlanner.FilesystemPayload, digest: String
    ) throws -> [ChangeSetQuotaLedger.Capacity] {
        let canonical = try ChangeSetQuotaCapacityPlanner.canonicalEnvelope(reservationID: String(repeating: "r", count: 36),
            digest: digest, request: request, root: root, encryptionKey: SymmetricKey(size: .bits256))
        let metadata = try ChangeSetQuotaCapacityPlanner.evidenceMetadata(artifact: filesystem.diff.artifact,
            retentionSeconds: request.retentionSeconds)
        let abort = Data("{\"paths\":[]}".utf8)
        return try ChangeSetQuotaCapacityPlanner.capacities(digest: digest,
            candidates: .init(canonical: canonical, manifest: filesystem.manifest, diff: filesystem.diff,
                evidenceMetadata: metadata, abortDiff: abort,
                abortEvidenceMetadata: try ChangeSetQuotaCapacityPlanner.evidenceMetadata(artifact: abort,
                    retentionSeconds: request.retentionSeconds), state: [Data()], wal: [Data()], terminal: [Data()]),
            reservationDirectory: root, evidenceDirectory: root, transactionDirectory: root,
            stateDirectory: root, direct: [])
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeRequest(root: URL, changes: [ApplyChangeSetChange]) -> ApplyChangeSetRequest {
        .init(clientID: "a15e1100-0000-4000-8000-000000000001", clientEpoch: 1, requestSequence: 1,
            cursor: .init(root: root.path, generation: String(repeating: "g", count: 64), sequence: 0),
            changes: changes, diffByteBudget: 1_048_576, retentionSeconds: 3_600)
    }
}

private extension Data {
    var sha256: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}
