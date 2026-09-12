import CryptoKit
import Foundation
import XCTest
@testable import AIShellCore

final class DepfileChangeImpactProviderTests: XCTestCase {
    func testDepfileImpactProducesSourceAndMatchingTestCandidates() async throws {
        let fixture = try DepfileFixture()
        defer { fixture.cleanup() }
        _ = try fixture.write("src/a.c", "int a(void) { return 1; }\n")
        _ = try fixture.write("include/a.h", "int a(void);\n")
        _ = try fixture.write("test/a.test", "test a\n")
        _ = try fixture.write("build.dep", "out: src/a.c \\\n include/a\\ file.h include/a.h\n")
        _ = try fixture.write("include/a file.h", "int spaced(void);\n")
        let changedSHA = try fixture.digest("include/a.h")

        let output = try await DepfileChangeImpactProvider().analyze(.init(
            root: fixture.root,
            workspaceCursor: "cursor-1",
            changedPaths: [.init(path: "include/a.h", contentSHA256: changedSHA)],
            changedSymbols: []
        ))

        XCTAssertEqual(output.report.descriptor.providerID, "depfile")
        XCTAssertEqual(output.report.descriptor.kind, .depfile)
        XCTAssertEqual(output.report.status, .fresh)
        XCTAssertEqual(output.freshnessBindings.map(\.path), ["build.dep", "src/a.c", "test/a.test"])
        XCTAssertEqual(output.evidence.map(\.candidate.category), [.dependencies, .relatedTests])
        XCTAssertEqual(output.evidence.map(\.candidate.subject.kind), [.path, .test])
        XCTAssertEqual(output.evidence.map(\.candidate.subject.path), ["src/a.c", "test/a.test"])
        XCTAssertEqual(output.evidence[0].relation, .declaredDependency)
        XCTAssertEqual(output.evidence[0].strength, .declaredEdge)
        XCTAssertEqual(output.evidence[0].locator.path, "build.dep")
        XCTAssertEqual(output.evidence[1].relation, .namingHeuristic)
        XCTAssertEqual(output.evidence[1].strength, .heuristic)
        XCTAssertEqual(output.evidence[1].locator.path, "test/a.test")
        XCTAssertEqual(output.evidence[1].locator.contentSHA256, try fixture.digest("test/a.test"))
        XCTAssertNotNil(output.evidence[1].locator.edgeID)
        XCTAssertTrue(output.coverageGaps.isEmpty)
    }

    func testDeletedDepfileReturnsExactlyOneFreshCoverageGapWithoutGuessing() async throws {
        let fixture = try DepfileFixture()
        defer { fixture.cleanup() }

        let output = try await DepfileChangeImpactProvider().analyze(.init(
            root: fixture.root,
            workspaceCursor: "cursor-1",
            changedPaths: [.init(path: "build.dep", expectedAbsent: true)],
            changedSymbols: []
        ))

        XCTAssertEqual(output.report.status, .fresh)
        XCTAssertTrue(output.evidence.isEmpty)
        XCTAssertTrue(output.freshnessBindings.isEmpty)
        XCTAssertEqual(output.coverageGaps.count, 1)
        XCTAssertEqual(output.coverageGaps[0].reasonCode, "changed_depfile_absent")
        XCTAssertEqual(output.coverageGaps[0].subject, .path("build.dep"))
        XCTAssertTrue(output.coverageGaps.allSatisfy { $0.providerID == "depfile" })
    }

    func testChangedPresentDepfileRequiresRebuildWithoutGuessing() async throws {
        let fixture = try DepfileFixture()
        defer { fixture.cleanup() }
        _ = try fixture.write("src/a.c", "int a(void) { return 1; }\n")
        let depfileSHA = try fixture.write("build.dep", "out: src/a.c include/a.h\n")

        let output = try await DepfileChangeImpactProvider().analyze(.init(
            root: fixture.root,
            workspaceCursor: "cursor-1",
            changedPaths: [.init(path: "build.dep", contentSHA256: depfileSHA)],
            changedSymbols: []
        ))

        XCTAssertEqual(output.report.status, .fresh)
        XCTAssertTrue(output.evidence.isEmpty)
        XCTAssertEqual(output.coverageGaps.count, 1)
        XCTAssertEqual(output.coverageGaps[0].category, .dependencies)
        XCTAssertEqual(output.coverageGaps[0].reasonCode, "changed_depfile_requires_rebuild")
        XCTAssertEqual(output.coverageGaps[0].providerID, "depfile")
        XCTAssertEqual(output.coverageGaps[0].subject, .path("build.dep"))
    }

    func testProductionRuntimeRegistersDepfileProviderAndReturnsBothCandidateKinds() async throws {
        let fixture = try DepfileFixture()
        defer { fixture.cleanup() }
        _ = try fixture.write("src/a.c", "int a(void) { return 1; }\n")
        let changedSHA = try fixture.write("include/a.h", "int a(void);\n")
        _ = try fixture.write("test/a.test", "test a\n")
        _ = try fixture.write("build.dep", "out: src/a.c include/a.h\n")
        let runtime = try await fixture.runtime()
        let service = DevelopmentRuntimeService(
            runtimeStore: runtime.store,
            evidenceStore: fixture.evidenceStore(),
            workspaceRuntime: runtime.workspace
        )

        let result = try await service.analyzeChangeImpact(.init(
            root: fixture.root.path,
            workspaceCursor: runtime.cursor,
            changedPaths: [.init(path: "include/a.h", contentSHA256: changedSHA)],
            requiredProviders: ["depfile"],
            byteBudget: 1_048_576
        ))

        XCTAssertFalse(result.hasMore)
        XCTAssertEqual(result.counts.dependencies, 1)
        XCTAssertEqual(result.counts.relatedTests, 1)
        XCTAssertEqual(
            result.items.compactMap { item -> String? in
                guard item.kind == .candidate, let category = item.category, let subject = item.subject else {
                    return nil
                }
                return "\(category.rawValue):\(subject.kind.rawValue):\(subject.path ?? "")"
            },
            ["dependencies:path:src/a.c", "related_tests:test:test/a.test"]
        )
        XCTAssertEqual(
            result.items.compactMap { item in
                item.kind == .providerReport
                    && item.providerReport?.descriptor.providerID == "depfile"
                    ? item.providerReport?.status
                    : nil
            },
            [.fresh]
        )
    }
}

private final class DepfileFixture {
    let base: URL
    let root: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("aishell-depfile-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ relativePath: String, _ content: String) throws -> String {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(content.utf8)
        try data.write(to: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func digest(_ relativePath: String) throws -> String {
        let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func runtime() async throws -> (store: RuntimeStore, workspace: WorkspaceStateRuntime, cursor: String) {
        let store = RuntimeStore(baseDirectory: base.appendingPathComponent("runtime", isDirectory: true))
        await store.setWorkingDirectoryForTesting(root)
        let workspace = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        let snapshot = try await workspace.snapshot(path: root.path, contextBudget: 0)
        return (store, workspace, snapshot.cursor)
    }

    func evidenceStore() -> EvidenceStore {
        EvidenceStore(baseDirectory: base.appendingPathComponent("evidence", isDirectory: true))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: base)
    }
}
