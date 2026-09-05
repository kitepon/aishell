import CryptoKit
import Foundation
import XCTest
@testable import AIShellCore

/// ACE-035: frozen Phase 3 scenariosをproduction service/providerへ通す受入網。
final class Phase3AcceptanceTests: XCTestCase {
    func testRepeatedCheckReusesExactProductionResultWithoutSecondExecution() async throws {
        let fixture = try await Phase3RunCheckFixture()
        defer { fixture.cleanup() }

        let first = try await fixture.run(cache: .prefer, inputDigest: try fixture.inputDigest())
        let repeated = try await fixture.run(cache: .prefer, inputDigest: try fixture.inputDigest())

        XCTAssertEqual(first.cacheState, .missExecuted)
        XCTAssertEqual(first.processesStarted, 1)
        XCTAssertEqual(first.publications, 1)
        XCTAssertEqual(repeated.cacheState, .hit)
        XCTAssertEqual(repeated.processesStarted, 0)
        XCTAssertEqual(repeated.publications, 0)
        XCTAssertEqual(repeated.steps.map(\.sourceRunID), first.steps.map(\.sourceRunID))
        XCTAssertEqual(repeated.steps.map(\.artifacts), first.steps.map(\.artifacts))
    }

    func testEditedRelevantInputCannotReusePreviousFreshResult() async throws {
        let fixture = try await Phase3RunCheckFixture()
        defer { fixture.cleanup() }

        let firstDigest = try fixture.inputDigest()
        let first = try await fixture.run(cache: .prefer, inputDigest: firstDigest)
        try fixture.writeInput("export const value = 2;\n")
        let editedDigest = try fixture.inputDigest()
        let afterEdit = try await fixture.run(cache: .prefer, inputDigest: editedDigest)

        XCTAssertNotEqual(firstDigest, editedDigest)
        XCTAssertEqual(first.cacheState, .missExecuted)
        XCTAssertEqual(afterEdit.cacheState, .missExecuted)
        XCTAssertEqual(afterEdit.processesStarted, 1)
        XCTAssertEqual(afterEdit.publications, 1)
        XCTAssertNotEqual(afterEdit.steps.map(\.sourceRunID), first.steps.map(\.sourceRunID))
    }

    func testMultiFileChangeProducesDeduplicatedTransitiveProductionImpact() async throws {
        let fixture = try Phase3ImpactFixture()
        defer { fixture.cleanup() }
        let aSHA = try fixture.write("src/a.mjs", "export const a = 2;\n")
        let cSHA = try fixture.write("src/c.mjs", "export const c = 2;\n")
        _ = try fixture.write(
            "src/b.mjs",
            "import { a } from './a.mjs'; import { c } from './c.mjs'; export const b = a + c;\n"
        )
        _ = try fixture.write("test/b.test.mjs", "import '../src/b.mjs';\n")
        let runtime = try await fixture.runtime()

        let result = try await ChangeImpactService(
            runtimeStore: runtime.store,
            workspaceRuntime: runtime.workspace,
            evidenceStore: fixture.evidenceStore()
        ).analyze(.init(
            root: fixture.root.path,
            workspaceCursor: runtime.cursor,
            changedPaths: [
                .init(path: "src/a.mjs", contentSHA256: aSHA),
                .init(path: "src/c.mjs", contentSHA256: cSHA),
            ],
            requiredProviders: ["static-import"],
            byteBudget: 1_048_576
        ))

        XCTAssertEqual(result.counts.dependencies, 1)
        XCTAssertEqual(result.counts.relatedTests, 1)
        XCTAssertEqual(
            result.items.compactMap { item -> String? in
                guard item.kind == .candidate, let subject = item.subject else { return nil }
                return subject.path
            },
            ["src/b.mjs", "test/b.test.mjs"]
        )
        let providerEvidence = result.items.filter {
            $0.kind == .evidence && $0.providerID == "static-import"
        }
        XCTAssertEqual(providerEvidence.count, 4, "2 inputs x direct/transitive evidenceを保持する")
        XCTAssertTrue(providerEvidence.allSatisfy { $0.evidenceStrength == .declaredEdge })
    }

    func testUnresolvedDynamicEdgeReportsUnknownGapWithoutSilentComplete() async throws {
        let fixture = try Phase3ImpactFixture()
        defer { fixture.cleanup() }
        let dynamicSHA = try fixture.write(
            "src/dynamic.mjs",
            "await import(process.env.TARGET);\n"
        )
        let runtime = try await fixture.runtime()

        let result = try await ChangeImpactService(
            runtimeStore: runtime.store,
            workspaceRuntime: runtime.workspace,
            evidenceStore: fixture.evidenceStore()
        ).analyze(.init(
            root: fixture.root.path,
            workspaceCursor: runtime.cursor,
            changedPaths: [.init(path: "src/dynamic.mjs", contentSHA256: dynamicSHA)],
            requiredProviders: ["static-import"],
            byteBudget: 1_048_576
        ))

        XCTAssertEqual(result.coverage, "partial")
        let gaps = result.items.compactMap { $0.kind == .coverageGap ? $0.coverageGap : nil }
        XCTAssertEqual(gaps.map(\.reasonCode), ["dynamic_import_non_literal"])
        XCTAssertEqual(gaps.map(\.providerID), ["static-import"])
    }

    func testFocusedRecommendOnlyReturnsCandidateWithoutStartingProcess() async throws {
        let fixture = try await Phase3FocusedFixture()
        defer { fixture.cleanup() }

        let recommendation = try await fixture.recommend()

        XCTAssertEqual(recommendation.executionPolicy, "explicit_run_check_only")
        XCTAssertEqual(recommendation.candidateCount, 1)
        XCTAssertEqual(fixture.recommendedTestPaths(recommendation), ["test/a.test.mjs"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.executionMarker.path))
    }

    func testFocusedExplicitRunStartsOnlyAfterCallerSelectsCandidate() async throws {
        let fixture = try await Phase3FocusedFixture()
        defer { fixture.cleanup() }
        let recommendation = try await fixture.recommend()
        let candidateID = try XCTUnwrap(
            recommendation.items.first(where: { $0.kind == .focusedCandidate })?.focusedCheckID
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.executionMarker.path))
        let executed = try await fixture.run(recommendation: recommendation, requestedIDs: [candidateID])

        XCTAssertEqual(executed.requestedCheckIDs, [candidateID])
        XCTAssertEqual(executed.plannedCheckIDs, [candidateID])
        XCTAssertEqual(executed.processesStarted, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.executionMarker.path))
    }
}

private final class Phase3RunCheckFixture: @unchecked Sendable {
    let base: URL
    let root: URL
    let inputURL: URL
    let service: DevelopmentRuntimeService
    let check: ProjectProfileCheck
    let catalog: ProjectProfileCatalogResult

    init() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIShellPhase3RunCheck-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("workspace", isDirectory: true)
        inputURL = root.appendingPathComponent("src/value.mjs")
        try FileManager.default.createDirectory(at: inputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("export const value = 1;\n".utf8).write(to: inputURL, options: .atomic)
        let manifestURL = root.appendingPathComponent("package.json")
        try Data("{}\n".utf8).write(to: manifestURL, options: .atomic)

        let runtime = RuntimeStore(baseDirectory: base.appendingPathComponent("runtime", isDirectory: true))
        await runtime.setWorkingDirectoryForTesting(root)
        let evidence = EvidenceStore(baseDirectory: base.appendingPathComponent("evidence", isDirectory: true))
        service = DevelopmentRuntimeService(
            runtimeStore: runtime,
            evidenceStore: evidence,
            focusedChecks: FocusedCheckService(),
            freshnessCache: CheckFreshnessCache.inMemory()
        )

        let manifestData = try Data(contentsOf: manifestURL)
        let manifestIdentity = try Self.fileIdentity(manifestURL)
        let executable = URL(fileURLWithPath: "/usr/bin/true").resolvingSymlinksInPath()
        check = ProjectProfileCheck(
            checkId: Self.hash("phase3-check"),
            kind: "test",
            label: "phase3 fixture check",
            executable: executable.path,
            arguments: [],
            workingDirectory: root.path,
            environmentKeys: [],
            provenance: .init(
                kind: "manifest",
                path: "package.json",
                contentSHA256: Self.sha256(manifestData),
                producerVersion: "phase3-acceptance",
                confidence: "declared"
            )
        )
        let profile = ProjectProfile(
            schemaVersion: "aishell.project-profile.v1",
            projectId: "phase3-project",
            projectRoot: "",
            projectRootIdentity: try Self.fileIdentity(root),
            displayName: "phase3 fixture",
            ecosystem: "npm",
            classification: "root",
            status: .complete,
            provider: "phase3-acceptance",
            providerVersion: "1",
            manifests: [.init(
                path: "package.json",
                role: "primary",
                identity: manifestIdentity,
                sha256: Self.sha256(manifestData),
                parseStatus: "parsed"
            )],
            memberProjectIds: [],
            targets: [],
            checks: [check],
            toolchains: [.init(
                name: "true",
                executable: executable.path,
                identity: try Self.fileIdentity(executable),
                sha256: Self.sha256(try Data(contentsOf: executable, options: .mappedIfSafe)),
                versionArguments: [],
                version: "system",
                exitStatus: 0,
                evidenceSHA256: Self.hash("toolchain-evidence"),
                evidenceHandle: "phase3-toolchain",
                evidenceExpiresAt: "future"
            )],
            providerEvidence: nil,
            missingCapabilities: [],
            diagnostics: [],
            binding: Self.hash("phase3-binding"),
            freshness: .freshComputed,
            observedCursor: "phase3-cursor",
            profileDigest: Self.hash("phase3-profile"),
            invalidationReasons: []
        )
        catalog = .init(
            schemaVersion: "aishell.project-profile-catalog.v1",
            root: root.path,
            observedCursor: "phase3-cursor",
            profiles: [profile],
            computedProfiles: 1,
            cachedProfiles: 0
        )
    }

    func writeInput(_ value: String) throws {
        try Data(value.utf8).write(to: inputURL, options: .atomic)
    }

    func inputDigest() throws -> String {
        Self.sha256(try Data(contentsOf: inputURL))
    }

    func run(cache: RunCheckInvocationPlan.CachePolicy, inputDigest: String) async throws -> RunCheckPipelineResult {
        let plan = try RunCheckInvocationPlan.compile(.v2(.init(
            invocation: .profileCheck(.init(
                projectID: "phase3-project",
                profileDigest: Self.hash("phase3-profile"),
                checkID: check.checkId
            )),
            dispatch: .sync,
            cachePolicy: cache,
            executionPolicy: .init(timeoutMilliseconds: 5_000, retentionSeconds: 3_600),
            selectionDigest: Self.hash("phase3-selection")
        )))
        return try await service.runCheck(
            plan: plan,
            resolution: .init(
                profileCatalog: catalog,
                relevantInputsByCheckID: [
                    check.checkId: .init(
                        digest: inputDigest,
                        reobserveDigest: { [inputURL] in
                            Self.sha256(try Data(contentsOf: inputURL))
                        }
                    )
                ]
            )
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }

    private static func fileIdentity(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? "")"
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hash(_ value: String) -> String { sha256(Data(value.utf8)) }
}

private final class Phase3ImpactFixture: @unchecked Sendable {
    let base: URL
    let root: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIShellPhase3Impact-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ relativePath: String, _ text: String) throws -> String {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(text.utf8)
        try data.write(to: url, options: .atomic)
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
        EvidenceStore(baseDirectory: base.appendingPathComponent("impact-evidence", isDirectory: true))
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

private final class Phase3FocusedFixture: @unchecked Sendable {
    let base: URL
    let root: URL
    let executionMarker: URL
    let focused: FocusedCheckService
    let impactService: ChangeImpactService
    let runtimeService: DevelopmentRuntimeService
    let catalog: ProjectProfileCatalogResult
    let check: ProjectProfileCheck
    let changedSHA: String
    let cursor: String
    let manifestIdentity: String

    init() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIShellPhase3Focused-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("workspace", isDirectory: true)
        executionMarker = base.appendingPathComponent("focused-check-executed")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifestURL = root.appendingPathComponent("package.json")
        try Data("{}\n".utf8).write(to: manifestURL, options: .atomic)
        let sourceURL = root.appendingPathComponent("src/a.mjs")
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourceData = Data("export const a = 2;\n".utf8)
        try sourceData.write(to: sourceURL, options: .atomic)
        changedSHA = Self.sha256(sourceData)
        let testURL = root.appendingPathComponent("test/a.test.mjs")
        try FileManager.default.createDirectory(at: testURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("import '../src/a.mjs';\n".utf8).write(to: testURL, options: .atomic)

        let runtime = RuntimeStore(baseDirectory: base.appendingPathComponent("runtime", isDirectory: true))
        await runtime.setWorkingDirectoryForTesting(root)
        let workspace = WorkspaceStateRuntime(runtimeStore: runtime, startsFSEvents: false)
        cursor = try await workspace.snapshot(path: root.path, contextBudget: 0).cursor
        let evidence = EvidenceStore(baseDirectory: base.appendingPathComponent("evidence", isDirectory: true))
        focused = FocusedCheckService()
        impactService = ChangeImpactService(
            runtimeStore: runtime,
            workspaceRuntime: workspace,
            evidenceStore: evidence,
            focusedCheckService: focused
        )
        runtimeService = DevelopmentRuntimeService(
            runtimeStore: runtime,
            evidenceStore: evidence,
            focusedChecks: focused,
            freshnessCache: CheckFreshnessCache.inMemory()
        )

        let manifestData = try Data(contentsOf: manifestURL)
        manifestIdentity = try Self.fileIdentity(manifestURL)
        let executable = URL(fileURLWithPath: "/usr/bin/touch").resolvingSymlinksInPath()
        check = ProjectProfileCheck(
            checkId: Self.hash("phase3-focused-check"),
            kind: "test",
            label: "phase3 focused fixture check",
            executable: executable.path,
            arguments: [executionMarker.path],
            workingDirectory: root.path,
            environmentKeys: [],
            provenance: .init(
                kind: "manifest",
                path: "package.json",
                contentSHA256: Self.sha256(manifestData),
                producerVersion: "phase3-acceptance",
                confidence: "declared"
            )
        )
        let profileDigest = Self.hash("phase3-focused-profile")
        let profile = ProjectProfile(
            schemaVersion: "aishell.project-profile.v1",
            projectId: "phase3-focused-project",
            projectRoot: "",
            projectRootIdentity: try Self.fileIdentity(root),
            displayName: "phase3 focused fixture",
            ecosystem: "npm",
            classification: "root",
            status: .complete,
            provider: "phase3-acceptance",
            providerVersion: "1",
            manifests: [.init(
                path: "package.json",
                role: "primary",
                identity: manifestIdentity,
                sha256: Self.sha256(manifestData),
                parseStatus: "parsed"
            )],
            memberProjectIds: [],
            targets: [.init(
                targetId: "phase3-tests",
                name: "phase3 npm package",
                kind: "library",
                dependencies: [],
                sourceRoots: ["src", "test"],
                resourceRoots: [],
                testRelation: nil,
                provenance: check.provenance
            )],
            checks: [check],
            toolchains: [.init(
                name: "touch",
                executable: executable.path,
                identity: try Self.fileIdentity(executable),
                sha256: Self.sha256(try Data(contentsOf: executable, options: .mappedIfSafe)),
                versionArguments: [],
                version: "system",
                exitStatus: 0,
                evidenceSHA256: Self.hash("phase3-focused-toolchain-evidence"),
                evidenceHandle: "phase3-focused-toolchain",
                evidenceExpiresAt: "future"
            )],
            providerEvidence: nil,
            missingCapabilities: [],
            diagnostics: [],
            binding: Self.hash("phase3-focused-binding"),
            freshness: .freshComputed,
            observedCursor: cursor,
            profileDigest: profileDigest,
            invalidationReasons: []
        )
        catalog = .init(
            schemaVersion: "aishell.project-profile-catalog.v1",
            root: root.path,
            observedCursor: cursor,
            profiles: [profile],
            computedProfiles: 1,
            cachedProfiles: 0
        )
    }

    func recommend() async throws -> ChangeImpactRecommendationResult {
        let profile = catalog.profiles[0]
        return try await impactService.recommend(.init(
            impactRequest: .init(
                operation: .analyze,
                root: root.path,
                workspaceCursor: cursor,
                changedPaths: [.init(path: "src/a.mjs", contentSHA256: changedSHA)],
                requiredProviders: ["static-import"],
                byteBudget: 1_048_576
            ),
            projectID: profile.projectId,
            profileDigest: profile.profileDigest,
            catalog: catalog,
            byteBudget: 1_048_576
        ))
    }

    func recommendedTestPaths(_ result: ChangeImpactRecommendationResult) -> [String] {
        result.items.compactMap { item in
            guard item.kind == .focusedCandidate,
                  case let .testPath(path) = item.selector else { return nil }
            return path
        }
    }

    func run(
        recommendation: ChangeImpactRecommendationResult,
        requestedIDs: [String]
    ) async throws -> RunCheckPipelineResult {
        let impactDigest = try XCTUnwrap(
            recommendation.items.first(where: { $0.kind == .impactEvidence })?.evidence?.provenance.artifactDigest
        )
        let profile = catalog.profiles[0]
        let admission = FocusedCheckService.Admission(
            rootIdentity: recommendation.freshness.rootIdentity,
            generation: recommendation.freshness.workspaceGeneration,
            cursor: recommendation.freshness.observedCursor,
            profileDigest: profile.profileDigest,
            manifestIdentity: manifestIdentity,
            impactArtifactDigest: impactDigest
        )
        let selection = try await focused.resolve(
            focusedSetID: recommendation.focusedSetID,
            focusedSetDigest: recommendation.focusedSetDigest,
            requestedCheckIDs: requestedIDs,
            admission: admission
        )
        let plan = try RunCheckInvocationPlan.compile(.v2(.init(
            invocation: .focusedSet(.init(
                setID: recommendation.focusedSetID,
                orderedCheckIDs: requestedIDs
            )),
            dispatch: .sync,
            cachePolicy: .off,
            executionPolicy: .init(timeoutMilliseconds: 5_000, retentionSeconds: 3_600),
            selectionDigest: selection.selectionDigest
        )))
        return try await runtimeService.runCheck(
            plan: plan,
            resolution: .init(profileCatalog: catalog, focusedAdmission: admission)
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }

    private static func fileIdentity(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? "")"
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hash(_ value: String) -> String { sha256(Data(value.utf8)) }
}
