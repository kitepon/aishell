import CryptoKit
import Foundation
import XCTest
@testable import AIShellCore

final class BuildManifestChangeImpactProviderTests: XCTestCase {
    func testPhase6AblationSeparatesLexicalSemanticAndBuildEvidenceWithoutChangingDefaults() async throws {
        let fixture = try await ProviderFixture()
        defer { fixture.cleanup() }
        let aSHA = try fixture.write("Sources/Core/A.swift", "public struct A {}\n")
        _ = try fixture.write("Sources/App/B.swift", "let b = A()\n")
        _ = try fixture.write("Tests/CoreTests/ATests.swift", "let t = A()\n")
        try fixture.writeManifest([
            "Core": (sources: ["Sources/Core/A.swift"], dependencies: []),
            "App": (sources: ["Sources/App/B.swift"], dependencies: ["Core"]),
            "CoreTests": (sources: ["Tests/CoreTests/ATests.swift"], dependencies: ["Core"]),
        ])
        let cursor = try await fixture.runtime.snapshot(path: fixture.root.path).cursor
        let input = ChangeImpactProviderInput(root: fixture.root, workspaceCursor: cursor,
            changedPaths: [.init(path: "Sources/Core/A.swift", contentSHA256: aSHA)],
            changedSymbols: [.init(path: "Sources/Core/A.swift", contentSHA256: aSHA,
                name: "A", startOffset: 14, endOffset: 15)])
        let clock = ContinuousClock()
        let lexicalStart = clock.now
        let lexical = try await FileSystemChangeImpactProvider().analyze(input)
        let lexicalDuration = lexicalStart.duration(to: clock.now)
        let semanticService = SourceKitLSPService(runtimeStore: fixture.store,
            workspaceRuntime: fixture.runtime, worker: SemanticWorker(locations: [
                .init(path: "Sources/App/B.swift", line: 0, character: 8),
                .init(path: "Tests/CoreTests/ATests.swift", line: 0, character: 8),
            ]))
        let semanticStart = clock.now
        let semantic = try await SourceKitChangeImpactProvider(service: semanticService).analyze(input)
        let semanticDuration = semanticStart.duration(to: clock.now)
        let dependencyStart = clock.now
        let dependency = try await BuildManifestChangeImpactProvider().analyze(input)
        let dependencyDuration = dependencyStart.duration(to: clock.now)

        XCTAssertTrue(lexical.evidence.contains { $0.relation == .lexicalReference })
        XCTAssertEqual(Set(semantic.evidence.map(\.candidate.category)), [.dependencies, .relatedTests])
        XCTAssertTrue(semantic.evidence.allSatisfy { $0.strength == .semanticMatch })
        XCTAssertEqual(Set(dependency.evidence.map(\.candidate.category)), [.dependencies, .relatedTests, .buildTargets])
        XCTAssertTrue(dependency.evidence.allSatisfy { $0.strength == .declaredEdge })
        print("ACE064_ABLATION lexical=\(lexicalDuration) semantic=\(semanticDuration) dependency=\(dependencyDuration)")

        let defaultResult = try await ChangeImpactService(runtimeStore: fixture.store,
            workspaceRuntime: fixture.runtime,
            evidenceStore: fixture.evidenceStore()).analyze(.init(
                root: fixture.root.path, workspaceCursor: cursor,
                changedPaths: input.changedPaths, changedSymbols: input.changedSymbols,
                byteBudget: 1_048_576
            ))
        let defaultProviders = Set(defaultResult.items.compactMap { $0.providerReport?.descriptor.providerID })
        XCTAssertEqual(defaultProviders, ["aishell.filesystem-impact", "static-import"])
        XCTAssertFalse(defaultProviders.contains("sourcekit"))
        XCTAssertFalse(defaultProviders.contains("swiftpm-build-manifest"))
        XCTAssertFalse(defaultProviders.contains("depfile"))
    }

    func testSourceKitEditDuringProviderQueryReturnsStaleWithoutEvidence() async throws {
        let fixture = try await ProviderFixture()
        defer { fixture.cleanup() }
        let aSHA = try fixture.write("Sources/Core/A.swift", "public struct A {}\n")
        _ = try fixture.write("Sources/App/B.swift", "let b = A()\n")
        let cursor = try await fixture.runtime.snapshot(path: fixture.root.path).cursor
        let worker = EditingSemanticWorker(url: fixture.root.appendingPathComponent("Sources/Core/A.swift"),
            runtime: fixture.runtime)
        let service = SourceKitLSPService(runtimeStore: fixture.store,
            workspaceRuntime: fixture.runtime, worker: worker)
        let output = try await SourceKitChangeImpactProvider(service: service).analyze(.init(
            root: fixture.root, workspaceCursor: cursor, changedPaths: [],
            changedSymbols: [.init(path: "Sources/Core/A.swift", contentSHA256: aSHA,
                name: "A", startOffset: 14, endOffset: 15)]
        ))
        XCTAssertEqual(output.report.status, .stale)
        XCTAssertEqual(output.report.reasonCode, "sourcekit_stale")
        XCTAssertTrue(output.evidence.isEmpty)
        XCTAssertTrue(output.freshnessBindings.isEmpty)
    }

    func testSwiftPMManifestReturnsDependentSourceTestAndTargets() async throws {
        let fixture = try await ProviderFixture()
        defer { fixture.cleanup() }
        let changedSHA = try fixture.write("Sources/Core/A.swift", "public struct A {}\n")
        _ = try fixture.write("Sources/App/B.swift", "import Core\nlet b = A()\n")
        _ = try fixture.write("Tests/CoreTests/ATests.swift", "import Core\n")
        try fixture.writeManifest([
            "Core": (sources: ["Sources/Core/A.swift"], dependencies: []),
            "App": (sources: ["Sources/App/B.swift"], dependencies: ["Core"]),
            "CoreTests": (sources: ["Tests/CoreTests/ATests.swift"], dependencies: ["Core"]),
        ])

        let output = try await BuildManifestChangeImpactProvider().analyze(.init(
            root: fixture.root, workspaceCursor: fixture.cursor,
            changedPaths: [.init(path: "Sources/Core/A.swift", contentSHA256: changedSHA)],
            changedSymbols: []
        ))

        XCTAssertEqual(output.report.status, .fresh)
        XCTAssertEqual(Set(output.evidence.map(\.candidate.category)), [.dependencies, .relatedTests, .buildTargets])
        XCTAssertTrue(output.evidence.contains { $0.candidate.subject.path == "Sources/App/B.swift" })
        XCTAssertTrue(output.evidence.contains { $0.candidate.subject.path == "Tests/CoreTests/ATests.swift" })
        XCTAssertTrue(output.evidence.allSatisfy { $0.strength == .declaredEdge })
        XCTAssertTrue(output.freshnessBindings.contains { $0.path.hasSuffix("description.json") })
    }

    func testSourceKitProviderReturnsSemanticDependencyAndTestWithSHABindings() async throws {
        let fixture = try await ProviderFixture()
        defer { fixture.cleanup() }
        let aSHA = try fixture.write("Sources/Core/A.swift", "public struct A {}\n")
        let bSHA = try fixture.write("Sources/App/B.swift", "let b = A()\n")
        let testSHA = try fixture.write("Tests/CoreTests/ATests.swift", "let t = A()\n")
        let worker = SemanticWorker(locations: [
            .init(path: "Sources/App/B.swift", line: 0, character: 8),
            .init(path: "Tests/CoreTests/ATests.swift", line: 0, character: 8),
        ])
        let service = SourceKitLSPService(runtimeStore: fixture.store,
            workspaceRuntime: fixture.runtime, worker: worker)
        let currentCursor = try await fixture.runtime.snapshot(path: fixture.root.path).cursor
        let output = try await SourceKitChangeImpactProvider(service: service).analyze(.init(
            root: fixture.root, workspaceCursor: currentCursor, changedPaths: [],
            changedSymbols: [.init(path: "Sources/Core/A.swift", contentSHA256: aSHA,
                name: "A", startOffset: 14, endOffset: 15)]
        ))

        XCTAssertEqual(output.report.status, .fresh)
        XCTAssertEqual(output.evidence.map(\.relation), [.semanticReference, .semanticReference])
        XCTAssertEqual(output.evidence.map(\.strength), [.semanticMatch, .semanticMatch])
        XCTAssertEqual(Set(output.evidence.map(\.candidate.category)), [.dependencies, .relatedTests])
        XCTAssertTrue(output.freshnessBindings.contains { $0.path == "Sources/App/B.swift" && $0.contentSHA256 == bSHA })
        XCTAssertTrue(output.freshnessBindings.contains { $0.path == "Tests/CoreTests/ATests.swift" && $0.contentSHA256 == testSHA })
    }
}

private struct SemanticWorker: SourceKitLSPWorker {
    let locations: [SourceKitLSPWorkerLocation]
    func query(_ request: SourceKitLSPRequest, document: Data) async throws -> SourceKitLSPWorkerResult {
        .success(locations)
    }
}

private struct EditingSemanticWorker: SourceKitLSPWorker {
    let url: URL
    let runtime: WorkspaceStateRuntime
    func query(_ request: SourceKitLSPRequest, document: Data) async throws -> SourceKitLSPWorkerResult {
        try Data("public struct Changed {}\n".utf8).write(to: url)
        await runtime.ingestObservedPaths([url.path])
        return .success([.init(path: "Sources/App/B.swift", line: 0, character: 8)])
    }
}

private final class ProviderFixture: @unchecked Sendable {
    let base: URL
    let root: URL
    let store: RuntimeStore
    let runtime: WorkspaceStateRuntime
    let cursor: String

    init() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("impact-provider-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = RuntimeStore(baseDirectory: base.appendingPathComponent("state", isDirectory: true))
        await store.setWorkingDirectoryForTesting(root)
        runtime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        cursor = try await runtime.snapshot(path: root.path).cursor
    }

    func write(_ path: String, _ text: String) throws -> String {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(text.utf8)
        try data.write(to: url)
        return Self.sha(data)
    }

    func writeManifest(_ modules: [String: (sources: [String], dependencies: [String])]) throws {
        let directory = root.appendingPathComponent(".build/debug", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var commands: [String: Any] = [:]
        for (name, module) in modules {
            var inputs = module.sources.map { ["kind": "file", "name": root.appendingPathComponent($0).path] }
            inputs += module.dependencies.map {
                ["kind": "file", "name": root.appendingPathComponent(".build/debug/Modules/\($0).swiftmodule").path]
            }
            commands[name] = ["moduleName": name, "inputs": inputs]
        }
        let data = try JSONSerialization.data(withJSONObject: ["swiftCommands": commands], options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("description.json"))
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
    func evidenceStore() -> EvidenceStore {
        EvidenceStore(baseDirectory: base.appendingPathComponent("evidence", isDirectory: true))
    }
    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
