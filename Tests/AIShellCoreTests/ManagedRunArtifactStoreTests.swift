import CryptoKit
import Foundation
import XCTest
@testable import AIShellCore

final class ManagedRunArtifactStoreTests: XCTestCase {
    func testPublishesThreeArtifactsAndIndexAsOneReplayableRun() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let runID = UUID()
        let store = try ManagedRunArtifactStore(runtimeStore: fixture.runtimeStore)
        let stdout = Data("one\ntwo\n".utf8)
        let stderr = Data([0xff, 0x00, 0x0a])
        try stdout.write(to: fixture.stdout)
        try stderr.write(to: fixture.stderr)
        try Data().write(to: fixture.diagnostics)
        await store.prepare(
            runID: runID,
            requestDigest: "request-digest",
            stdoutURL: fixture.stdout,
            stderrURL: fixture.stderr,
            diagnosticURL: fixture.diagnostics
        )
        let inspection = try await store.fsyncAndInspect(
            stdoutURL: fixture.stdout, stderrURL: fixture.stderr
        )
        let diagnosticIdentity = ManagedArtifactIdentity(
            handle: "run_\(runID.uuidString.replacingOccurrences(of: "-", with: "").lowercased())_diagnostics",
            sizeBytes: 0,
            sha256: Self.digest(Data())
        )
        let finalizedAt = Date(timeIntervalSince1970: 1_720_000_000)
        let first = try await store.publishAtomically(
            inspection: inspection, diagnostics: diagnosticIdentity, finalizedAt: finalizedAt
        )
        let replay = try await store.publishAtomically(
            inspection: inspection, diagnostics: diagnosticIdentity, finalizedAt: finalizedAt
        )
        XCTAssertEqual(first, replay)
        let record = try await store.loadRecord(runID: runID)
        XCTAssertEqual(record.stdout.sha256, Self.digest(stdout))
        XCTAssertEqual(record.stderr.sha256, Self.digest(stderr))
        XCTAssertEqual(record.finalizedAt, finalizedAt)
        let artifacts = try await store.artifacts(
            runID: runID, channels: ["stdout", "stderr", "diagnostics"]
        )
        XCTAssertEqual(artifacts.map(\.kind), ["stdout", "stderr", "diagnostic"])
        XCTAssertEqual(artifacts.map(\.data), [stdout, stderr, Data()])
        await assertManagedArtifactThrows(
            try await store.queryArtifacts(runID: runID, projectID: "legacy-project")
        ) {
            XCTAssertEqual($0 as? ManagedRunArtifactStoreError, .legacyArtifactUnbound)
        }
    }

    func testBoundQueryRejectsWrongProjectAndExpiredRun() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let runID = UUID()
        let store = try ManagedRunArtifactStore(runtimeStore: fixture.runtimeStore)
        try Data("bound\n".utf8).write(to: fixture.stdout)
        try Data().write(to: fixture.stderr)
        try Data().write(to: fixture.diagnostics)
        await store.prepare(
            runID: runID,
            requestDigest: "request-digest",
            projectID: "project-a",
            expiresAt: Date().addingTimeInterval(60),
            stdoutURL: fixture.stdout,
            stderrURL: fixture.stderr,
            diagnosticURL: fixture.diagnostics
        )
        let inspection = try await store.fsyncAndInspect(
            stdoutURL: fixture.stdout, stderrURL: fixture.stderr
        )
        _ = try await store.publishAtomically(
            inspection: inspection,
            diagnostics: .init(handle: "diagnostics", sizeBytes: 0, sha256: Self.digest(Data())),
            finalizedAt: Date()
        )
        let boundArtifacts = try await store.queryArtifacts(runID: runID, projectID: "project-a")
        XCTAssertEqual(boundArtifacts.first?.data, Data("bound\n".utf8))
        let record = try await store.loadRecord(runID: runID)
        let reopened = try ManagedRunArtifactStore(runtimeStore: fixture.runtimeStore)
        let range = try await reopened.read(handle: record.stdout.handle, mode: .range(offset: 1, length: 5), byteBudget: 3)
        XCTAssertEqual(range.text, "oun")
        XCTAssertEqual(range.offset, 1)
        XCTAssertEqual(range.totalBytes, 6)
        XCTAssertEqual(range.omittedBytes, 3)
        XCTAssertFalse(range.eof)
        let tail = try await reopened.read(handle: record.stdout.handle, mode: .tail(lines: 1), byteBudget: 128)
        XCTAssertEqual(tail.text, "bound\n")
        let around = try await reopened.read(handle: record.stdout.handle, mode: .around(pattern: "bound", contextLines: 0), byteBudget: 128)
        XCTAssertEqual(around.text, "bound\n")
        await assertManagedArtifactThrows(
            try await store.queryArtifacts(runID: runID, projectID: "project-b")
        ) {
            XCTAssertEqual($0 as? ManagedRunArtifactStoreError, .scopeMismatch)
        }

        let expiredID = UUID()
        await store.prepare(
            runID: expiredID,
            requestDigest: "expired",
            projectID: "project-a",
            expiresAt: Date().addingTimeInterval(-1),
            stdoutURL: fixture.stdout,
            stderrURL: fixture.stderr,
            diagnosticURL: fixture.diagnostics
        )
        let expiredInspection = try await store.fsyncAndInspect(
            stdoutURL: fixture.stdout, stderrURL: fixture.stderr
        )
        _ = try await store.publishAtomically(
            inspection: expiredInspection,
            diagnostics: .init(handle: "expired-diagnostics", sizeBytes: 0, sha256: Self.digest(Data())),
            finalizedAt: Date()
        )
        await assertManagedArtifactThrows(
            try await store.queryArtifacts(runID: expiredID, projectID: "project-a")
        ) {
            XCTAssertEqual($0 as? ManagedRunArtifactStoreError, .runExpired)
        }
        let expiredRecord = try await store.loadRecord(runID: expiredID)
        await assertManagedArtifactThrows(try await reopened.read(handle: expiredRecord.stdout.handle,
            mode: .range(offset: 0, length: 1), byteBudget: 1)) {
            XCTAssertEqual($0 as? AIShellError, .handleExpired(expiredRecord.stdout.handle))
        }
    }

    func testReplayAndReadRejectTamperedPublishedArtifact() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let runID = UUID()
        let store = try ManagedRunArtifactStore(runtimeStore: fixture.runtimeStore)
        try Data("stable".utf8).write(to: fixture.stdout)
        try Data().write(to: fixture.stderr)
        try Data().write(to: fixture.diagnostics)
        await store.prepare(
            runID: runID,
            requestDigest: "request-digest",
            stdoutURL: fixture.stdout,
            stderrURL: fixture.stderr,
            diagnosticURL: fixture.diagnostics
        )
        let inspection = try await store.fsyncAndInspect(
            stdoutURL: fixture.stdout, stderrURL: fixture.stderr
        )
        let diagnostics = ManagedArtifactIdentity(
            handle: "diagnostics", sizeBytes: 0, sha256: Self.digest(Data())
        )
        _ = try await store.publishAtomically(
            inspection: inspection, diagnostics: diagnostics, finalizedAt: Date(timeIntervalSince1970: 1)
        )
        let published = fixture.runtimeStore.baseDirectory
            .appendingPathComponent("managed-runs/artifacts/published")
            .appendingPathComponent(runID.uuidString.lowercased())
            .appendingPathComponent("stdout.artifact")
        try Data("tampered".utf8).write(to: published)

        await assertManagedArtifactThrows(try await store.loadRecord(runID: runID)) {
            XCTAssertEqual($0 as? ManagedRunArtifactStoreError, .storeCorrupt("artifact digest"))
        }
        await assertManagedArtifactThrows(try await store.publishAtomically(
            inspection: inspection, diagnostics: diagnostics, finalizedAt: Date(timeIntervalSince1970: 1)
        )) {
            XCTAssertEqual($0 as? ManagedRunArtifactStoreError, .storeCorrupt("artifact digest"))
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private func assertManagedArtifactThrows<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("エラーが必要です。", file: file, line: line)
    } catch {
        verify(error)
    }
}

private struct Fixture {
    let root: URL
    let runtimeStore: RuntimeStore
    let stdout: URL
    let stderr: URL
    let diagnostics: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIShellManagedArtifactStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        runtimeStore = RuntimeStore(baseDirectory: root.appendingPathComponent("state", isDirectory: true))
        stdout = root.appendingPathComponent("stdout.spool")
        stderr = root.appendingPathComponent("stderr.spool")
        diagnostics = root.appendingPathComponent("diagnostics.spool")
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
