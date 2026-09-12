import CryptoKit
import Foundation
import XCTest
@testable import AIShellCore

final class StaticImportChangeImpactProviderTests: XCTestCase {
    func testReverseTransitiveDependenciesSeparateSourceAndTestCandidates() async throws {
        let fixture = try StaticImportFixture()
        defer { fixture.cleanup() }
        let changedSHA = try fixture.write("src/a.mjs", "export const a = 1\n")
        _ = try fixture.write("src/b.mjs", "import { a } from './a.mjs'\nexport const b = a\n")
        _ = try fixture.write("test/b.test.mjs", "import { b } from '../src/b.mjs'\n")

        let output = try await StaticImportChangeImpactProvider().analyze(.init(
            root: fixture.root,
            workspaceCursor: "cursor-1",
            changedPaths: [.init(path: "src/a.mjs", contentSHA256: changedSHA)],
            changedSymbols: []
        ))

        XCTAssertEqual(output.report.descriptor.providerID, "static-import")
        XCTAssertEqual(output.report.status, .fresh)
        XCTAssertEqual(output.freshnessBindings.map(\.path), ["src/a.mjs", "src/b.mjs", "test/b.test.mjs"])
        XCTAssertEqual(output.evidence.count, 2)
        XCTAssertEqual(
            output.evidence.map {
                "\($0.candidate.category.rawValue):\($0.candidate.subject.kind.rawValue):\($0.candidate.subject.path ?? "")"
            },
            [
                "dependencies:path:src/b.mjs",
                "related_tests:test:test/b.test.mjs"
            ]
        )
        XCTAssertTrue(output.evidence.allSatisfy { $0.relation == .declaredDependency })
        XCTAssertTrue(output.evidence.allSatisfy { $0.strength == .declaredEdge })
        XCTAssertTrue(output.coverageGaps.isEmpty)
    }

    func testNonLiteralDynamicImportProducesOneDependencyGapPerSubject() async throws {
        let fixture = try StaticImportFixture()
        defer { fixture.cleanup() }
        let changedSHA = try fixture.write(
            "src/a.mjs",
            "await import(process.env.TARGET)\nawait import(getTarget())\n"
        )

        let output = try await StaticImportChangeImpactProvider().analyze(.init(
            root: fixture.root,
            workspaceCursor: "cursor-1",
            changedPaths: [.init(path: "src/a.mjs", contentSHA256: changedSHA)],
            changedSymbols: []
        ))

        XCTAssertTrue(output.evidence.isEmpty)
        XCTAssertEqual(output.coverageGaps.count, 1)
        XCTAssertEqual(output.coverageGaps[0].category, .dependencies)
        XCTAssertEqual(output.coverageGaps[0].reasonCode, "dynamic_import_non_literal")
        XCTAssertEqual(output.coverageGaps[0].providerID, "static-import")
        XCTAssertEqual(output.coverageGaps[0].subject, .path("src/a.mjs"))
    }

    func testDefaultServiceSatisfiesRequiredStaticImportAndReturnsBothCandidateKinds() async throws {
        let fixture = try StaticImportFixture()
        defer { fixture.cleanup() }
        let changedSHA = try fixture.write("src/a.mjs", "export const a = 1\n")
        _ = try fixture.write("src/b.mjs", "import { a } from './a.mjs'\nexport const b = a\n")
        _ = try fixture.write("test/b.test.mjs", "import { b } from '../src/b.mjs'\n")
        let runtime = try await fixture.runtime()
        let service = ChangeImpactService(
            runtimeStore: runtime.store,
            workspaceRuntime: runtime.workspace,
            evidenceStore: fixture.evidenceStore()
        )

        let result = try await service.analyze(.init(
            root: fixture.root.path,
            workspaceCursor: runtime.cursor,
            changedPaths: [.init(path: "src/a.mjs", contentSHA256: changedSHA)],
            requiredProviders: ["static-import"],
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
            [
                "dependencies:path:src/b.mjs",
                "related_tests:test:test/b.test.mjs"
            ]
        )
        XCTAssertEqual(
            result.items.compactMap { item in
                item.kind == .providerReport
                    && item.providerReport?.descriptor.providerID == "static-import"
                    ? item.providerReport?.status
                    : nil
            },
            [.fresh]
        )
    }

    func testDefaultServiceKeepsDynamicImportUnknownCountAtOne() async throws {
        let fixture = try StaticImportFixture()
        defer { fixture.cleanup() }
        let changedSHA = try fixture.write("src/dynamic.mjs", "await import(process.env.TARGET)\n")
        let runtime = try await fixture.runtime()
        let service = ChangeImpactService(
            runtimeStore: runtime.store,
            workspaceRuntime: runtime.workspace,
            evidenceStore: fixture.evidenceStore()
        )

        let result = try await service.analyze(.init(
            root: fixture.root.path,
            workspaceCursor: runtime.cursor,
            changedPaths: [.init(path: "src/dynamic.mjs", contentSHA256: changedSHA)],
            requiredProviders: ["static-import"],
            byteBudget: 1_048_576
        ))

        XCTAssertEqual(result.coverage, "partial")
        let gaps = result.items.compactMap { $0.kind == .coverageGap ? $0.coverageGap : nil }
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.reasonCode, "dynamic_import_non_literal")
        XCTAssertEqual(gaps.first?.providerID, "static-import")
    }

    func testRegexLiteralAndMemberImportDoNotCreateFalseCandidates() async throws {
        let fixture = try StaticImportFixture()
        defer { fixture.cleanup() }
        let changedSHA = try fixture.write("src/a.mjs", "export const a = 1\n")
        _ = try fixture.write("src/b.mjs", "import { a } from './a.mjs'\nexport const b = a\n")
        _ = try fixture.write(
            "src/regex-decoy.mjs",
            #"const pattern = /[\\/]import\(['\"]\.\/a\.mjs['\"]\)/g"# + "\n"
        )
        _ = try fixture.write("src/member-decoy.mjs", "object.import('./a.mjs')\nobject.export('./a.mjs')\n")

        let output = try await StaticImportChangeImpactProvider().analyze(.init(
            root: fixture.root,
            workspaceCursor: "cursor-1",
            changedPaths: [.init(path: "src/a.mjs", contentSHA256: changedSHA)],
            changedSymbols: []
        ))

        XCTAssertEqual(output.evidence.map { $0.candidate.subject.path }, ["src/b.mjs"])
        XCTAssertEqual(output.evidence.map { $0.locator.path }, ["src/b.mjs"])
        XCTAssertTrue(output.coverageGaps.isEmpty)
    }

    func testLongChainStopsDeterministicallyAtCandidateLimitWithGap() async throws {
        let fixture = try StaticImportFixture()
        defer { fixture.cleanup() }
        let changedSHA = try fixture.write("src/n0000.mjs", "export const value = 0\n")
        for index in 1...514 {
            let path = String(format: "src/n%04d.mjs", index)
            let dependency = String(format: "./n%04d.mjs", index - 1)
            _ = try fixture.write(path, "import { value } from '\(dependency)'\nexport { value }\n")
        }

        let output = try await StaticImportChangeImpactProvider().analyze(.init(
            root: fixture.root,
            workspaceCursor: "cursor-1",
            changedPaths: [.init(path: "src/n0000.mjs", contentSHA256: changedSHA)],
            changedSymbols: []
        ))

        XCTAssertEqual(output.evidence.count, 512)
        XCTAssertEqual(output.evidence.first?.candidate.subject.path, "src/n0001.mjs")
        XCTAssertEqual(output.evidence.last?.candidate.subject.path, "src/n0512.mjs")
        XCTAssertFalse(output.evidence.contains { $0.candidate.subject.path == "src/n0513.mjs" })
        let limitGaps = output.coverageGaps.filter { $0.reasonCode == "static_import_candidate_limit_reached" }
        XCTAssertEqual(limitGaps.count, 1)
        XCTAssertEqual(limitGaps.first?.category, .dependencies)
        XCTAssertEqual(limitGaps.first?.providerID, "static-import")
    }

    func testSwiftOnlyInputReportsUnsupportedWithoutProviderItems() async throws {
        let fixture = try StaticImportFixture()
        defer { fixture.cleanup() }
        let changedSHA = try fixture.write("Sources/App/Changed.swift", "struct Changed {}\n")
        _ = try fixture.write("web/unrelated.mjs", "export const unrelated = true\n")

        let output = try await StaticImportChangeImpactProvider().analyze(.init(
            root: fixture.root,
            workspaceCursor: "cursor-1",
            changedPaths: [.init(path: "Sources/App/Changed.swift", contentSHA256: changedSHA)],
            changedSymbols: []
        ))

        XCTAssertEqual(output.report.status, .unsupported)
        XCTAssertEqual(output.report.reasonCode, "static_import_ecosystem_unsupported")
        XCTAssertEqual(output.report.inputDigest.count, 64)
        XCTAssertTrue(output.evidence.isEmpty)
        XCTAssertTrue(output.freshnessBindings.isEmpty)
        XCTAssertTrue(output.coverageGaps.isEmpty)
    }

    func testMissingJavaScriptInputStaysFreshWithOneExplicitGap() async throws {
        let fixture = try StaticImportFixture()
        defer { fixture.cleanup() }

        let output = try await StaticImportChangeImpactProvider().analyze(.init(
            root: fixture.root,
            workspaceCursor: "cursor-1",
            changedPaths: [.init(path: "src/deleted.mjs", expectedAbsent: true)],
            changedSymbols: []
        ))

        XCTAssertEqual(output.report.status, .fresh)
        XCTAssertEqual(output.coverageGaps.count, 1)
        XCTAssertEqual(output.coverageGaps.first?.reasonCode, "static_import_analysis_input_missing")
        XCTAssertEqual(output.coverageGaps.first?.providerID, "static-import")
        XCTAssertEqual(output.coverageGaps.first?.subject, .path("src/deleted.mjs"))
    }

    func testDefaultServiceMarksSwiftOnlyWorkspacePartialWithUnsupportedReport() async throws {
        let fixture = try StaticImportFixture()
        defer { fixture.cleanup() }
        let changedSHA = try fixture.write("Sources/App/Changed.swift", "struct Changed {}\n")
        _ = try fixture.write("web/unrelated.mjs", "export const unrelated = true\n")
        let runtime = try await fixture.runtime()
        let service = ChangeImpactService(
            runtimeStore: runtime.store,
            workspaceRuntime: runtime.workspace,
            evidenceStore: fixture.evidenceStore()
        )

        let result = try await service.analyze(.init(
            root: fixture.root.path,
            workspaceCursor: runtime.cursor,
            changedPaths: [.init(path: "Sources/App/Changed.swift", contentSHA256: changedSHA)],
            byteBudget: 1_048_576
        ))

        XCTAssertEqual(result.coverage, "partial")
        let report = try XCTUnwrap(result.items.first {
            $0.kind == .providerReport && $0.providerReport?.descriptor.providerID == "static-import"
        }?.providerReport)
        XCTAssertEqual(report.status, .unsupported)
        XCTAssertEqual(report.reasonCode, "static_import_ecosystem_unsupported")
    }

    func testMixedInputsStayFreshAndDeduplicateUnsupportedInputGap() async throws {
        let fixture = try StaticImportFixture()
        defer { fixture.cleanup() }
        let javascriptSHA = try fixture.write("src/a.mjs", "export const a = 1\n")
        let swiftSHA = try fixture.write("Sources/App/Changed.swift", "struct Changed {}\n")

        let output = try await StaticImportChangeImpactProvider().analyze(.init(
            root: fixture.root,
            workspaceCursor: "cursor-1",
            changedPaths: [
                .init(path: "src/a.mjs", contentSHA256: javascriptSHA),
                .init(path: "Sources/App/Changed.swift", contentSHA256: swiftSHA)
            ],
            changedSymbols: [.init(
                path: "Sources/App/Changed.swift",
                contentSHA256: swiftSHA,
                name: "Changed",
                startOffset: 7,
                endOffset: 14
            )]
        ))

        XCTAssertEqual(output.report.status, .fresh)
        let unsupported = output.coverageGaps.filter { $0.reasonCode == "static_import_input_unsupported" }
        XCTAssertEqual(unsupported.count, 1)
        XCTAssertEqual(unsupported.first?.category, .dependencies)
        XCTAssertEqual(unsupported.first?.providerID, "static-import")
        XCTAssertEqual(unsupported.first?.subject, .path("Sources/App/Changed.swift"))
    }

    func testCommonJSLiteralRequireCreatesReverseDependency() async throws {
        let fixture = try StaticImportFixture()
        defer { fixture.cleanup() }
        let changedSHA = try fixture.write("src/a.cjs", "module.exports = 1\n")
        _ = try fixture.write("src/b.cjs", "const a = require('./a.cjs')\nmodule.exports = a\n")

        let output = try await StaticImportChangeImpactProvider().analyze(.init(
            root: fixture.root,
            workspaceCursor: "cursor-1",
            changedPaths: [.init(path: "src/a.cjs", contentSHA256: changedSHA)],
            changedSymbols: []
        ))

        XCTAssertEqual(output.evidence.map { $0.candidate.subject.path }, ["src/b.cjs"])
        XCTAssertEqual(output.evidence.first?.relation, .declaredDependency)
        XCTAssertEqual(output.evidence.first?.strength, .declaredEdge)
        XCTAssertTrue(output.coverageGaps.isEmpty)
    }

    func testCommonJSNonLiteralRequireProducesGapAndMemberRequireIsIgnored() async throws {
        let fixture = try StaticImportFixture()
        defer { fixture.cleanup() }
        let changedSHA = try fixture.write("src/a.cjs", "module.exports = 1\n")
        _ = try fixture.write(
            "src/dynamic.cjs",
            "require(process.env.TARGET)\nobject.require('./a.cjs')\n"
        )

        let output = try await StaticImportChangeImpactProvider().analyze(.init(
            root: fixture.root,
            workspaceCursor: "cursor-1",
            changedPaths: [.init(path: "src/a.cjs", contentSHA256: changedSHA)],
            changedSymbols: []
        ))

        XCTAssertTrue(output.evidence.isEmpty)
        let gaps = output.coverageGaps.filter { $0.reasonCode == "commonjs_require_non_literal" }
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.category, .dependencies)
        XCTAssertEqual(gaps.first?.providerID, "static-import")
        XCTAssertEqual(gaps.first?.subject, .path("src/dynamic.cjs"))
    }

    func testRequireOutsideExplicitCommonJSExtensionsFailsClosedWithoutEdges() async throws {
        let fixture = try StaticImportFixture()
        defer { fixture.cleanup() }
        let changedSHA = try fixture.write("src/a.js", "export const a = 1\n")
        _ = try fixture.write("src/b.js", "const a = require('./a.js')\n")
        _ = try fixture.write("src/type.ts", "import a = require('./a.js')\nexport { a }\n")
        _ = try fixture.write("src/member.js", "object.require('./a.js')\n")

        let output = try await StaticImportChangeImpactProvider().analyze(.init(
            root: fixture.root,
            workspaceCursor: "cursor-1",
            changedPaths: [.init(path: "src/a.js", contentSHA256: changedSHA)],
            changedSymbols: []
        ))

        XCTAssertTrue(output.evidence.isEmpty)
        let gaps = output.coverageGaps.filter { $0.reasonCode == "commonjs_module_kind_unresolved" }
        XCTAssertEqual(gaps.count, 2)
        XCTAssertEqual(gaps.map { $0.subject?.path }, ["src/type.ts", "src/b.js"])
        XCTAssertTrue(gaps.allSatisfy { $0.category == .dependencies && $0.providerID == "static-import" })
    }
}

private final class StaticImportFixture {
    let base: URL
    let root: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("aishell-static-import-\(UUID().uuidString)", isDirectory: true)
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
