import CryptoKit
import XCTest
@testable import AIShellCore

final class SemanticSearchContextServiceTests: XCTestCase {
    func testFreshReferenceIsProjectedWithSourceKitEvidence() async throws {
        let fixture = try SemanticSearchFixture()
        defer { fixture.cleanup() }
        try await fixture.prepare()
        let worker = SemanticWorker(result: .success([
            .init(path: "src/b.swift", line: 0, character: 16),
        ]))
        let service = SemanticSearchContextService(
            runtimeStore: fixture.store,
            workspaceRuntime: fixture.workspace,
            evidenceStore: fixture.evidence,
            sourceKit: SourceKitLSPService(
                runtimeStore: fixture.store,
                workspaceRuntime: fixture.workspace,
                worker: worker
            )
        )

        let result = try await service.search(fixture.request(cursor: fixture.cursor))

        XCTAssertEqual(result.provider, "sourcekit-lsp")
        XCTAssertEqual(result.scanMode, "semantic_provider")
        XCTAssertEqual(result.freshness.state, "fresh")
        XCTAssertEqual(result.matches.map(\.path), ["src/b.swift"])
        XCTAssertEqual(result.matches.first?.line, 0)
        XCTAssertEqual(result.omittedMatches, 0)
        XCTAssertEqual(result.evidence.producer, "SemanticSearchContextService")
    }

    func testEditAfterCursorReturnsStaleWithoutCallingProvider() async throws {
        let fixture = try SemanticSearchFixture()
        defer { fixture.cleanup() }
        try await fixture.prepare()
        try "func renamed() {}\n".write(
            to: fixture.root.appendingPathComponent("src/a.swift"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await fixture.workspace.appendKnownMutation(
            transactionID: "semantic-edit",
            rootPath: fixture.root.path,
            changes: [.init(kind: .modified, path: "src/a.swift")]
        )
        let service = SemanticSearchContextService(
            runtimeStore: fixture.store,
            workspaceRuntime: fixture.workspace,
            evidenceStore: fixture.evidence,
            sourceKit: SourceKitLSPService(
                runtimeStore: fixture.store,
                workspaceRuntime: fixture.workspace,
                worker: FailingSemanticWorker()
            )
        )

        let result = try await service.search(fixture.request(cursor: fixture.cursor))

        XCTAssertEqual(result.freshness.state, "stale")
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.freshness.observedFrom, fixture.cursor)
    }
}

private struct SemanticWorker: SourceKitLSPWorker {
    let result: SourceKitLSPWorkerResult
    func query(_ request: SourceKitLSPRequest, document: Data) async throws -> SourceKitLSPWorkerResult {
        result
    }
}

private struct FailingSemanticWorker: SourceKitLSPWorker {
    func query(_ request: SourceKitLSPRequest, document: Data) async throws -> SourceKitLSPWorkerResult {
        XCTFail("stale request must not reach SourceKit-LSP")
        return .success([])
    }
}

private final class SemanticSearchFixture {
    let base: URL
    let root: URL
    let store: RuntimeStore
    let workspace: WorkspaceStateRuntime
    let evidence: EvidenceStore
    private(set) var cursor = ""

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("AIShellSemanticSearch-\(UUID().uuidString)")
        root = base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "func target() {}\n".write(
            to: root.appendingPathComponent("src/a.swift"), atomically: true, encoding: .utf8
        )
        try "func caller() { target() }\n".write(
            to: root.appendingPathComponent("src/b.swift"), atomically: true, encoding: .utf8
        )
        store = RuntimeStore(baseDirectory: base.appendingPathComponent("runtime"))
        workspace = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        evidence = EvidenceStore(baseDirectory: base.appendingPathComponent("evidence"))
    }

    func prepare() async throws {
        await store.setWorkingDirectoryForTesting(root)
        cursor = try await workspace.snapshot(path: root.path, contextBudget: 0).cursor
    }

    func request(cursor: String) -> SemanticSearchContextRequest {
        .init(
            path: root.path,
            queries: [.init(id: "refs", pattern: "target", operation: .references)],
            provider: "sourcekit-lsp",
            cursor: cursor
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
}
