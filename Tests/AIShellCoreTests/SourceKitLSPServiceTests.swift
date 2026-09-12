import CryptoKit
import Foundation
import XCTest
@testable import AIShellCore

final class SourceKitLSPServiceTests: XCTestCase {
    func testFreshReferenceBindsEveryLocationToCurrentFileSHA() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let worker = Worker { _, _ in
            .success([.init(path: "B.swift", line: 4, character: 8)])
        }
        let service = SourceKitLSPService(runtimeStore: fixture.store,
            workspaceRuntime: fixture.runtime, worker: worker)
        let result = try await service.query(fixture.request(.references))
        XCTAssertEqual(result.status, .fresh)
        XCTAssertEqual(result.locations, [.init(path: "B.swift", line: 4, character: 8,
            contentSHA256: fixture.bSHA)])
    }

    func testEditDuringQueryReturnsStaleWithoutLexicalFallback() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let worker = Worker { _, _ in
            try Data("let changed = 2\n".utf8).write(to: fixture.a)
            await fixture.runtime.ingestObservedPaths([fixture.a.path])
            return .success([.init(path: "B.swift", line: 1, character: 1)])
        }
        let service = SourceKitLSPService(runtimeStore: fixture.store,
            workspaceRuntime: fixture.runtime, worker: worker)
        let result = try await service.query(fixture.request(.definition))
        XCTAssertEqual(result.status, .stale)
        XCTAssertTrue(result.locations.isEmpty)
        XCTAssertEqual(result.reason, "document_changed_during_query")
    }

    func testIndexingAndUnavailableRemainExplicitStates() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        for (workerResult, expected) in [
            (SourceKitLSPWorkerResult.indexing("index build"), SourceKitLSPStatus.indexing),
            (.unavailable("worker missing"), .unavailable),
        ] {
            let service = SourceKitLSPService(runtimeStore: fixture.store,
                workspaceRuntime: fixture.runtime, worker: Worker { _, _ in workerResult })
            let result = try await service.query(fixture.request(.workspaceSymbols))
            XCTAssertEqual(result.status, expected)
            XCTAssertTrue(result.locations.isEmpty)
        }
    }

    func testProductionWorkerCompletesSourceKitLSPHandshake() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else {
            throw XCTSkip("xcrun is unavailable")
        }
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let response = try await SourceKitLSPProcessWorker().query(
            fixture.request(.workspaceSymbols),
            document: try Data(contentsOf: fixture.a)
        )
        if case let .unavailable(reason) = response {
            XCTFail("production sourcekit-lsp handshake failed: \(reason)")
        }
    }

    func testProcessWorkerTimeoutClosesBlockingReader() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        let worker = SourceKitLSPProcessWorker(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["60"],
            requestTimeout: .milliseconds(50)
        )
        let clock = ContinuousClock()
        let startedAt = clock.now
        let response = try await worker.query(
            fixture.request(.workspaceSymbols),
            document: Data(contentsOf: fixture.a)
        )
        let elapsed = startedAt.duration(to: clock.now)

        guard case let .unavailable(reason) = response else {
            return XCTFail("timeoutをunavailableとして返しませんでした: \(response)")
        }
        XCTAssertTrue(reason.contains("timed out"), reason)
        XCTAssertLessThan(elapsed, Duration.seconds(2))
    }
}

private struct Worker: SourceKitLSPWorker {
    let body: @Sendable (SourceKitLSPRequest, Data) async throws -> SourceKitLSPWorkerResult
    init(_ body: @escaping @Sendable (SourceKitLSPRequest, Data) async throws -> SourceKitLSPWorkerResult) {
        self.body = body
    }
    func query(_ request: SourceKitLSPRequest, document: Data) async throws -> SourceKitLSPWorkerResult {
        try await body(request, document)
    }
}

private final class Fixture: @unchecked Sendable {
    let base: URL
    let root: URL
    let a: URL
    let b: URL
    let store: RuntimeStore
    let runtime: WorkspaceStateRuntime
    let cursor: String
    let aSHA: String
    let bSHA: String

    init() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sourcekit-service-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        a = root.appendingPathComponent("A.swift")
        b = root.appendingPathComponent("B.swift")
        let aData = Data("let value = 1\n".utf8), bData = Data("print(value)\n".utf8)
        try aData.write(to: a); try bData.write(to: b)
        aSHA = Self.sha(aData); bSHA = Self.sha(bData)
        store = RuntimeStore(baseDirectory: base.appendingPathComponent("state", isDirectory: true))
        await store.setWorkingDirectoryForTesting(root)
        runtime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        cursor = try await runtime.snapshot(path: root.path).cursor
    }

    func request(_ operation: SourceKitLSPOperation) -> SourceKitLSPRequest {
        .init(root: root, workspaceCursor: cursor, path: "A.swift", contentSHA256: aSHA,
            operation: operation, symbol: "value", line: 0, character: 4)
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
