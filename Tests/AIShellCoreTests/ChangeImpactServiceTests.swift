import CryptoKit
import Foundation
import XCTest
@testable import AIShellCore

final class ChangeImpactServiceTests: XCTestCase {
    func testDuplicateCandidateRetainsEveryProviderProvenanceDeterministically() async throws {
        let fixture = try ImpactFixture()
        defer { fixture.cleanup() }
        let sourceSHA = try fixture.write("Sources/App/Changed.swift", "struct Changed {}\n")
        let referenceSHA = try fixture.write("Sources/App/Use.swift", "let value = Changed()\n")
        let binding = ChangeImpactFreshnessBinding(
            role: .analysis,
            path: "Sources/App/Use.swift",
            contentSHA256: referenceSHA
        )
        let candidate = ChangeImpactCandidateSeed(
            category: .references,
            subject: .path("Sources/App/Use.swift")
        )
        let lexical = StubImpactProvider(
            id: "lexical",
            kind: .lexicalSearch,
            binding: binding,
            evidence: .init(
                inputIdentity: "changed:Changed.swift",
                candidate: candidate,
                relation: .lexicalReference,
                locator: .init(
                    path: "Sources/App/Use.swift",
                    contentSHA256: referenceSHA,
                    startOffset: 12,
                    endOffset: 19
                ),
                strength: .lexicalMatch,
                summary: "Changedのtoken一致"
            )
        )
        let index = StubImpactProvider(
            id: "workspace-index",
            kind: .workspaceIndex,
            binding: binding,
            evidence: .init(
                inputIdentity: "changed:Changed.swift",
                candidate: candidate,
                relation: .containsSource,
                locator: .init(
                    path: "Sources/App/Use.swift",
                    contentSHA256: referenceSHA,
                    edgeID: "source:Use.swift"
                ),
                strength: .declaredEdge,
                summary: "workspace indexのsource所属"
            )
        )
        let runtime = try await fixture.runtime()
        let request = ChangeImpactRequest(
            root: fixture.root.path,
            workspaceCursor: runtime.cursor,
            changedPaths: [.init(path: "Sources/App/Changed.swift", contentSHA256: sourceSHA)],
            requiredProviders: ["lexical", "workspace-index"],
            byteBudget: 1_048_576
        )
        let firstStore = fixture.evidenceStore(suffix: "first")
        let first = try await ChangeImpactService(
            runtimeStore: runtime.store,
            workspaceRuntime: runtime.workspace,
            evidenceStore: firstStore,
            providers: [index, lexical]
        ).analyze(request)

        XCTAssertEqual(first.coverage, "complete")
        XCTAssertEqual(first.counts.references, 1)
        XCTAssertEqual(first.items.filter { $0.kind == .candidate }.count, 1)
        XCTAssertEqual(first.items.filter { $0.kind == .evidence }.count, 2)
        XCTAssertEqual(first.items.filter { $0.kind == .candidateEvidence }.count, 2)
        XCTAssertEqual(
            Set(first.items.compactMap { $0.kind == .evidence ? $0.providerID : nil }),
            ["lexical", "workspace-index"]
        )
        XCTAssertEqual(first.freshness.bindingCount, 2)

        let second = try await ChangeImpactService(
            runtimeStore: runtime.store,
            workspaceRuntime: runtime.workspace,
            evidenceStore: fixture.evidenceStore(suffix: "second"),
            providers: [lexical, index]
        ).analyze(ChangeImpactRequest(
            root: fixture.root.path,
            workspaceCursor: runtime.cursor,
            changedPaths: [.init(path: "Sources/App/Changed.swift", contentSHA256: sourceSHA)],
            requiredProviders: ["workspace-index", "lexical"],
            byteBudget: 1_048_576
        ))
        XCTAssertEqual(first.items, second.items)
        XCTAssertEqual(first.artifact.sha256, second.artifact.sha256)
        XCTAssertEqual(first.freshness.bindingDigest, second.freshness.bindingDigest)
    }

    func testAnalysisMutationFailsClosedBeforeReturningCandidates() async throws {
        let fixture = try ImpactFixture()
        defer { fixture.cleanup() }
        let sourceSHA = try fixture.write("Changed.swift", "struct Changed {}\n")
        let referenceSHA = try fixture.write("Use.swift", "let value = Changed()\n")
        let provider = StubImpactProvider(
            id: "lexical",
            kind: .lexicalSearch,
            binding: .init(role: .analysis, path: "Use.swift", contentSHA256: referenceSHA),
            evidence: .init(
                inputIdentity: "changed",
                candidate: .init(category: .references, subject: .path("Use.swift")),
                relation: .lexicalReference,
                locator: .init(path: "Use.swift", contentSHA256: referenceSHA, startOffset: 12, endOffset: 19),
                strength: .lexicalMatch,
                summary: "token一致"
            )
        )
        let runtime = try await fixture.runtime()
        let changingURL = fixture.root.appendingPathComponent("Use.swift")
        let service = ChangeImpactService(
            runtimeStore: runtime.store,
            workspaceRuntime: runtime.workspace,
            evidenceStore: fixture.evidenceStore(),
            providers: [provider],
            beforeFinalFreshnessCheck: {
                try Data("let value = Other()\n".utf8).write(to: changingURL, options: .atomic)
            }
        )

        await XCTAssertThrowsImpactError(
            try await service.analyze(ChangeImpactRequest(
                root: fixture.root.path,
                workspaceCursor: runtime.cursor,
                changedPaths: [.init(path: "Changed.swift", contentSHA256: sourceSHA)]
            ))
        ) { error in
            guard case .contentChanged("Use.swift") = error else {
                return XCTFail("想定外のerror: \(error)")
            }
        }
    }

    func testContinuationRevalidatesAllFreshnessBindings() async throws {
        let fixture = try ImpactFixture()
        defer { fixture.cleanup() }
        let sourceSHA = try fixture.write("Changed.swift", "struct Changed {}\n")
        let referenceSHA = try fixture.write("Use.swift", "let value = Changed()\n")
        let provider = StubImpactProvider(
            id: "lexical",
            kind: .lexicalSearch,
            binding: .init(role: .analysis, path: "Use.swift", contentSHA256: referenceSHA),
            evidence: .init(
                inputIdentity: "changed",
                candidate: .init(category: .references, subject: .path("Use.swift")),
                relation: .lexicalReference,
                locator: .init(path: "Use.swift", contentSHA256: referenceSHA, startOffset: 12, endOffset: 19),
                strength: .lexicalMatch,
                summary: "token一致"
            )
        )
        let runtime = try await fixture.runtime()
        let service = ChangeImpactService(
            runtimeStore: runtime.store,
            workspaceRuntime: runtime.workspace,
            evidenceStore: fixture.evidenceStore(),
            providers: [provider]
        )
        let first = try await service.analyze(ChangeImpactRequest(
            root: fixture.root.path,
            workspaceCursor: runtime.cursor,
            changedPaths: [.init(path: "Changed.swift", contentSHA256: sourceSHA)],
            byteBudget: 512
        ))
        let token = try XCTUnwrap(first.continuation)
        _ = try fixture.write("Use.swift", "let value = Other()\n")

        await XCTAssertThrowsImpactError(
            try await service.analyze(ChangeImpactRequest(
                operation: nil,
                byteBudget: 1_024,
                continuation: token
            ))
        ) { error in
            guard case .contentChanged("Use.swift") = error else {
                return XCTFail("想定外のerror: \(error)")
            }
        }
    }

    func testOpaqueContinuationResumesAnalyzeByExactRegistryMembershipAndConsumesItOnce() async throws {
        let fixture = try ImpactFixture()
        defer { fixture.cleanup() }
        let sourceSHA = try fixture.write("Changed.swift", "struct Changed {}\n")
        let referenceSHA = try fixture.write("Use.swift", "let value = Changed()\n")
        let provider = StubImpactProvider(
            id: "lexical",
            kind: .lexicalSearch,
            binding: .init(role: .analysis, path: "Use.swift", contentSHA256: referenceSHA),
            evidence: .init(
                inputIdentity: "changed",
                candidate: .init(category: .references, subject: .path("Use.swift")),
                relation: .lexicalReference,
                locator: .init(path: "Use.swift", contentSHA256: referenceSHA, startOffset: 12, endOffset: 19),
                strength: .lexicalMatch,
                summary: "token一致"
            )
        )
        let runtime = try await fixture.runtime()
        let service = ChangeImpactService(
            runtimeStore: runtime.store,
            workspaceRuntime: runtime.workspace,
            evidenceStore: fixture.evidenceStore(),
            providers: [provider]
        )
        let initial = try await service.analyze(.init(
            root: fixture.root.path,
            workspaceCursor: runtime.cursor,
            changedPaths: [.init(path: "Changed.swift", contentSHA256: sourceSHA)],
            byteBudget: 512
        ))
        let token = try XCTUnwrap(initial.continuation)

        let resumed = try await service.continueImpact(continuation: token, byteBudget: 1_024)
        guard case let .analyze(page) = resumed else {
            return XCTFail("analyze continuation が recommend として再開されました")
        }
        XCTAssertEqual(page.operation, .analyze)
        await XCTAssertThrowsImpactError(try await service.continueImpact(continuation: token)) { error in
            XCTAssertEqual(error, .invalidContinuation)
        }
    }

    func testOpaqueContinuationDoesNotUseTokenPrefixAsAuthority() async throws {
        let fixture = try ImpactFixture()
        defer { fixture.cleanup() }
        let sourceSHA = try fixture.write("Changed.swift", "struct Changed {}\n")
        let referenceSHA = try fixture.write("Use.swift", "let value = Changed()\n")
        let provider = StubImpactProvider(id: "lexical", kind: .lexicalSearch, binding: .init(role: .analysis, path: "Use.swift", contentSHA256: referenceSHA), evidence: .init(inputIdentity: "changed", candidate: .init(category: .references, subject: .path("Use.swift")), relation: .lexicalReference, locator: .init(path: "Use.swift", contentSHA256: referenceSHA), strength: .lexicalMatch, summary: "token一致"))
        let runtime = try await fixture.runtime()
        let service = ChangeImpactService(runtimeStore: runtime.store, workspaceRuntime: runtime.workspace, evidenceStore: fixture.evidenceStore(), providers: [provider])
        let initial = try await service.analyze(.init(root: fixture.root.path, workspaceCursor: runtime.cursor, changedPaths: [.init(path: "Changed.swift", contentSHA256: sourceSHA)], byteBudget: 512))
        let token = try XCTUnwrap(initial.continuation)
        let forgedPrefix = "cir2:" + token.dropFirst(4)

        await XCTAssertThrowsImpactError(try await service.continueImpact(continuation: forgedPrefix)) { error in
            XCTAssertEqual(error, .invalidContinuation)
        }
        _ = try await service.continueImpact(continuation: token, byteBudget: 1_024)
    }

    func testRequiredProviderMustBeFreshAndDoesNotFallback() async throws {
        let fixture = try ImpactFixture()
        defer { fixture.cleanup() }
        let sourceSHA = try fixture.write("Changed.swift", "struct Changed {}\n")
        let runtime = try await fixture.runtime()
        let stale = StubImpactProvider(
            id: "sourcekit",
            kind: .sourceKit,
            status: .stale,
            reasonCode: "DOCUMENT_VERSION_MISMATCH"
        )
        let service = ChangeImpactService(
            runtimeStore: runtime.store,
            workspaceRuntime: runtime.workspace,
            evidenceStore: fixture.evidenceStore(),
            providers: [stale]
        )

        await XCTAssertThrowsImpactError(
            try await service.analyze(ChangeImpactRequest(
                root: fixture.root.path,
                workspaceCursor: runtime.cursor,
                changedPaths: [.init(path: "Changed.swift", contentSHA256: sourceSHA)],
                requiredProviders: ["sourcekit"]
            ))
        ) { error in
            XCTAssertEqual(error, .requiredProviderNotFresh(["sourcekit"]))
        }
    }

    func testFilesystemProviderReturnsLexicalTestAndTargetEvidenceWithoutExecution() async throws {
        let fixture = try ImpactFixture()
        defer { fixture.cleanup() }
        _ = try fixture.write("Package.swift", "// swift-tools-version: 6.0\n")
        let sourceSHA = try fixture.write("Sources/App/Widget.swift", "struct Widget {}\n")
        _ = try fixture.write("Sources/App/Use.swift", "let value = Widget()\n")
        _ = try fixture.write("Tests/AppTests/WidgetTests.swift", "func testWidget() {}\n")
        let runtime = try await fixture.runtime()
        let result = try await ChangeImpactService(
            runtimeStore: runtime.store,
            workspaceRuntime: runtime.workspace,
            evidenceStore: fixture.evidenceStore()
        ).analyze(ChangeImpactRequest(
            root: fixture.root.path,
            workspaceCursor: runtime.cursor,
            changedPaths: [.init(path: "Sources/App/Widget.swift", contentSHA256: sourceSHA)],
            changedSymbols: [.init(
                path: "Sources/App/Widget.swift",
                contentSHA256: sourceSHA,
                name: "Widget",
                startOffset: 7,
                endOffset: 13
            )],
            requiredProviders: ["aishell.filesystem-impact"],
            byteBudget: 1_048_576
        ))

        XCTAssertGreaterThanOrEqual(result.counts.references, 1)
        XCTAssertGreaterThanOrEqual(result.counts.relatedTests, 1)
        XCTAssertEqual(result.counts.buildTargets, 1)
        XCTAssertTrue(result.items.contains {
            $0.kind == .evidence && $0.evidenceStrength == .declaredEdge
        })
        XCTAssertEqual(result.coverage, "partial")
        XCTAssertTrue(result.items.contains {
            $0.kind == .providerReport
                && $0.providerReport?.descriptor.providerID == "static-import"
                && $0.providerReport?.status == .unsupported
        })
        XCTAssertTrue(result.items.contains {
            $0.kind == .coverageGap
                && $0.coverageGap?.providerID == "static-import"
                && $0.coverageGap?.reasonCode == "static_import_ecosystem_unsupported"
        })
    }

    func testFilesystemTestNameHeuristicRequiresAStemBoundary() async throws {
        let fixture = try ImpactFixture()
        defer { fixture.cleanup() }
        let changedSHA = try fixture.write("src/a.mjs", "export const a = 2;\n")
        _ = try fixture.write("test/a.test.mjs", "import '../src/a.mjs';\n")
        _ = try fixture.write("test/unrelated.test.mjs", "export const unrelated = true;\n")

        let output = try await FileSystemChangeImpactProvider().analyze(.init(
            root: fixture.root,
            workspaceCursor: "cursor-1",
            changedPaths: [.init(path: "src/a.mjs", contentSHA256: changedSHA)],
            changedSymbols: []
        ))

        XCTAssertEqual(
            output.evidence.compactMap { evidence in
                evidence.candidate.category == .relatedTests ? evidence.candidate.subject.path : nil
            },
            ["test/a.test.mjs"]
        )
    }

    func testRecommendKeepsFocusedSetResolvableAndEmitsClosedItemsWithoutProcess() async throws {
        let fixture = try ImpactFixture()
        defer { fixture.cleanup() }
        let manifestSHA = try fixture.write("Package.swift", "// manifest\n")
        let changedSHA = try fixture.write("Sources/App/Widget.swift", "struct Widget {}\n")
        let testSHA = try fixture.write("Tests/AppTests/WidgetTests.swift", "func testWidget() {}\n")
        let runtime = try await fixture.runtime()
        let provider = StubImpactProvider(
            id: "impact", kind: .lexicalSearch,
            binding: .init(role: .analysis, path: "Tests/AppTests/WidgetTests.swift", contentSHA256: testSHA),
            evidence: .init(inputIdentity: "changed", candidate: .init(category: .relatedTests, subject: .test(path: "Tests/AppTests/WidgetTests.swift")),
                            relation: .containsTest, locator: .init(path: "Tests/AppTests/WidgetTests.swift", contentSHA256: testSHA), strength: .declaredEdge, summary: "declared test")
        )
        let digest = String(repeating: "b", count: 64)
        let projectID = "project-1"
        let provenance = ProjectProfileProvenance(kind: "manifest", path: "Package.swift", contentSHA256: manifestSHA, producerVersion: "test", confidence: "declared")
        let check = ProjectProfileCheck(checkId: "test-check", kind: "test", label: "test", executable: "/usr/bin/true", arguments: [], workingDirectory: fixture.root.path, environmentKeys: [], provenance: provenance)
        let profile = ProjectProfile(schemaVersion: "aishell.project-profile.v1", projectId: projectID, projectRoot: fixture.root.path, projectRootIdentity: "project-root", displayName: "fixture", ecosystem: "swiftpm", classification: "primary", status: .complete, provider: "test", providerVersion: "1", manifests: [.init(path: "Package.swift", role: "primary", identity: "manifest-identity", sha256: manifestSHA, parseStatus: "parsed")], memberProjectIds: [], targets: [.init(targetId: "test-target", name: "AppTests", kind: "test", dependencies: [], sourceRoots: ["Tests/AppTests"], resourceRoots: [], testRelation: "package-tests", provenance: provenance)], checks: [check], toolchains: [], providerEvidence: nil, missingCapabilities: [], diagnostics: [], binding: "binding", freshness: .freshComputed, observedCursor: runtime.cursor, profileDigest: digest, invalidationReasons: [])
        let catalog = ProjectProfileCatalogResult(schemaVersion: "aishell.project-profile-catalog.v1", root: fixture.root.path, observedCursor: runtime.cursor, profiles: [profile], computedProfiles: 1, cachedProfiles: 0)
        let focused = FocusedCheckService()
        let service = ChangeImpactService(runtimeStore: runtime.store, workspaceRuntime: runtime.workspace, evidenceStore: fixture.evidenceStore(), providers: [provider], focusedCheckService: focused)
        let impact = ChangeImpactRequest(operation: .analyze, root: fixture.root.path, workspaceCursor: runtime.cursor, changedPaths: [.init(path: "Sources/App/Widget.swift", contentSHA256: changedSHA)], byteBudget: 1_048_576)
        let expectedImpact = try await service.analyze(impact)
        let result = try await service.recommend(.init(impactRequest: impact, projectID: projectID, profileDigest: digest, catalog: catalog, byteBudget: 1_048_576))

        XCTAssertEqual(result.operation, .recommend)
        XCTAssertEqual(result.executionPolicy, "explicit_run_check_only")
        XCTAssertEqual(result.candidateCount, 1)
        XCTAssertFalse(result.hasMore)
        let candidateID = try XCTUnwrap(result.items.first { $0.kind == .focusedCandidate }?.focusedCheckID)
        let impactArtifact = try XCTUnwrap(result.items.first { $0.kind == .impactEvidence }?.evidence?.provenance.artifactDigest)
        XCTAssertEqual(impactArtifact, expectedImpact.artifact.sha256)
        XCTAssertNotEqual(result.artifact.sha256, impactArtifact)
        _ = try await focused.resolve(focusedSetID: result.focusedSetID, focusedSetDigest: result.focusedSetDigest, requestedCheckIDs: [candidateID], admission: .init(rootIdentity: result.freshness.rootIdentity, generation: result.freshness.workspaceGeneration, cursor: result.freshness.observedCursor, profileDigest: digest, manifestIdentity: "manifest-identity", impactArtifactDigest: impactArtifact))
        let encoded = try JSONEncoder().encode(result.items)
        let objects = try JSONSerialization.jsonObject(with: encoded) as! [[String: Any]]
        for object in objects {
            let kind = object["kind"] as! String
            let expected: Set<String> = switch kind {
            case "focused_candidate": ["kind", "itemID", "focusedCheckID", "profileCheckID", "profileDigest", "selector"]
            case "focused_step": ["kind", "itemID", "focusedCheckID", "step"]
            case "manifest_binding": ["kind", "itemID", "manifest"]
            case "impact_evidence": ["kind", "itemID", "focusedCheckID", "evidence"]
            default: ["kind", "itemID", "coverageGap"]
            }
            XCTAssertEqual(Set(object.keys), expected)
        }
    }

}

final class ChangeImpactRecommendationTests: XCTestCase {
    func testCandidateGenerationHasNoImplicitExecution() async throws {
        let fixture = try ImpactFixture()
        defer { fixture.cleanup() }
        let manifestSHA = try fixture.write("Package.swift", "// manifest\n")
        let changedSHA = try fixture.write("Sources/App/Changed.swift", "struct Changed {}\n")
        let testSHA = try fixture.write("Tests/AppTests/ChangedTests.swift", "func testChanged() {}\n")
        let runtime = try await fixture.runtime()
        let calls = ImpactProviderCallCounter()
        let provider = CountingImpactProvider(
            id: "impact", kind: .lexicalSearch,
            counter: calls,
            binding: .init(role: .analysis, path: "Tests/AppTests/ChangedTests.swift", contentSHA256: testSHA),
            evidence: .init(inputIdentity: "changed", candidate: .init(category: .relatedTests, subject: .test(path: "Tests/AppTests/ChangedTests.swift")), relation: .containsTest,
                            locator: .init(path: "Tests/AppTests/ChangedTests.swift", contentSHA256: testSHA), strength: .declaredEdge, summary: "test")
        )
        let digest = String(repeating: "a", count: 64)
        let marker = fixture.root.appendingPathComponent("unexpected-check-execution")
        let catalog = recommendationCatalog(fixture: fixture, runtimeCursor: runtime.cursor, manifestSHA: manifestSHA, digest: digest, checkExecutable: "/usr/bin/touch", checkArguments: [marker.path])
        let service = ChangeImpactService(runtimeStore: runtime.store, workspaceRuntime: runtime.workspace, evidenceStore: fixture.evidenceStore(), providers: [provider])
        let result = try await service.recommend(.init(impactRequest: recommendationImpact(fixture: fixture, cursor: runtime.cursor, changedSHA: changedSHA), projectID: "project-1", profileDigest: digest, catalog: catalog, byteBudget: 1_048_576))
        XCTAssertEqual(result.operation, .recommend)
        let analysisCalls = await calls.value
        let executionCalls = await calls.executionCount
        XCTAssertEqual(analysisCalls, 1, "recommend は impact analyze だけを明示的に呼ぶ")
        XCTAssertEqual(executionCalls, 0, "focused candidate 生成は check process を実行しない")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "recommend は profile check を暗黙実行しない")
    }

    func testAbsoluteProjectRootAndArtifactSeparation() async throws {
        let fixture = try ImpactFixture()
        defer { fixture.cleanup() }
        let manifestSHA = try fixture.write("Package.swift", "// manifest\n")
        let changedSHA = try fixture.write("Sources/App/Changed.swift", "struct Changed {}\n")
        let testSHA = try fixture.write("Tests/AppTests/ChangedTests.swift", "func testChanged() {}\n")
        let runtime = try await fixture.runtime()
        let digest = String(repeating: "b", count: 64)
        let catalog = recommendationCatalog(fixture: fixture, runtimeCursor: runtime.cursor, manifestSHA: manifestSHA, digest: digest, projectRoot: fixture.root.path)
        let provider = StubImpactProvider(id: "impact", kind: .lexicalSearch, binding: .init(role: .analysis, path: "Tests/AppTests/ChangedTests.swift", contentSHA256: testSHA), evidence: testEvidence(path: "Tests/AppTests/ChangedTests.swift", sha: testSHA, summary: "absolute root"))
        let focused = FocusedCheckService()
        let service = ChangeImpactService(runtimeStore: runtime.store, workspaceRuntime: runtime.workspace, evidenceStore: fixture.evidenceStore(), providers: [provider], focusedCheckService: focused)
        let impact = recommendationImpact(fixture: fixture, cursor: runtime.cursor, changedSHA: changedSHA)
        let analysis = try await service.analyze(impact)
        let result = try await service.recommend(.init(impactRequest: impact, projectID: "project-1", profileDigest: digest, catalog: catalog, byteBudget: 1_048_576))
        let candidateID = try XCTUnwrap(result.items.first(where: { $0.kind == .focusedCandidate })?.focusedCheckID)
        let impactDigest = try XCTUnwrap(result.items.first(where: { $0.kind == .impactEvidence })?.evidence?.provenance.artifactDigest)
        XCTAssertEqual(impactDigest, analysis.artifact.sha256)
        XCTAssertNotEqual(result.artifact.sha256, analysis.artifact.sha256)
        _ = try await focused.resolve(focusedSetID: result.focusedSetID, focusedSetDigest: result.focusedSetDigest, requestedCheckIDs: [candidateID], admission: .init(rootIdentity: result.freshness.rootIdentity, generation: result.freshness.workspaceGeneration, cursor: result.freshness.observedCursor, profileDigest: digest, manifestIdentity: "manifest-identity", impactArtifactDigest: impactDigest))
    }

    func testRootOutsideOwnershipFailsClosed() async throws {
        let fixture = try ImpactFixture()
        defer { fixture.cleanup() }
        let manifestSHA = try fixture.write("Package.swift", "// manifest\n")
        let changedSHA = try fixture.write("Sources/App/Changed.swift", "struct Changed {}\n")
        let testSHA = try fixture.write("Tests/AppTests/ChangedTests.swift", "func testChanged() {}\n")
        let runtime = try await fixture.runtime()
        let digest = String(repeating: "c", count: 64)
        let provider = StubImpactProvider(id: "impact", kind: .lexicalSearch, binding: .init(role: .analysis, path: "Tests/AppTests/ChangedTests.swift", contentSHA256: testSHA), evidence: testEvidence(path: "../Tests/AppTests/ChangedTests.swift", locatorPath: "Tests/AppTests/ChangedTests.swift", sha: testSHA, summary: "escape"))
        let service = ChangeImpactService(runtimeStore: runtime.store, workspaceRuntime: runtime.workspace, evidenceStore: fixture.evidenceStore(), providers: [provider])
        let outside = recommendationCatalog(fixture: fixture, runtimeCursor: runtime.cursor, manifestSHA: manifestSHA, digest: digest, projectRoot: "/outside/project")
        await XCTAssertThrowsImpactError(try await service.recommend(.init(impactRequest: recommendationImpact(fixture: fixture, cursor: runtime.cursor, changedSHA: changedSHA), projectID: "project-1", profileDigest: digest, catalog: outside))) { error in
            guard case .recommendationJoinFailed(let reason) = error else { return XCTFail("想定外のerror: \(error)") }
            XCTAssertTrue(reason.contains("exact join可能"))
            XCTAssertTrue(reason.contains("TEST_PATH_NOT_OWNED_BY_PROFILE"))
        }

        let valid = StubImpactProvider(id: "valid", kind: .lexicalSearch, binding: .init(role: .analysis, path: "Tests/AppTests/ChangedTests.swift", contentSHA256: testSHA), evidence: testEvidence(path: "Tests/AppTests/ChangedTests.swift", sha: testSHA, summary: "valid"))
        let escaped = StubImpactProvider(id: "escaped", kind: .workspaceIndex, binding: .init(role: .analysis, path: "Tests/AppTests/ChangedTests.swift", contentSHA256: testSHA), evidence: testEvidence(path: "../Tests/AppTests/ChangedTests.swift", locatorPath: "Tests/AppTests/ChangedTests.swift", sha: testSHA, summary: "escape"))
        let partial = ChangeImpactService(runtimeStore: runtime.store, workspaceRuntime: runtime.workspace, evidenceStore: fixture.evidenceStore(suffix: "partial"), providers: [valid, escaped])
        let result = try await partial.recommend(.init(impactRequest: recommendationImpact(fixture: fixture, cursor: runtime.cursor, changedSHA: changedSHA), projectID: "project-1", profileDigest: digest, catalog: recommendationCatalog(fixture: fixture, runtimeCursor: runtime.cursor, manifestSHA: manifestSHA, digest: digest)))
        XCTAssertEqual(result.candidateCount, 1)
        XCTAssertEqual(result.coverage, "partial")
        XCTAssertEqual(result.items.filter { $0.kind == .coverageGap }.map { $0.coverageGap?.reasonCode }, ["TEST_PATH_NOT_OWNED_BY_PROFILE"])
    }

    func testRecommendationItemKindsHaveClosedKeys() async throws {
        let fixture = try ImpactFixture()
        defer { fixture.cleanup() }
        let manifestSHA = try fixture.write("Package.swift", "// manifest\n")
        let changedSHA = try fixture.write("Sources/App/Changed.swift", "struct Changed {}\n")
        let testSHA = try fixture.write("Tests/AppTests/ChangedTests.swift", "func testChanged() {}\n")
        let runtime = try await fixture.runtime()
        let digest = String(repeating: "d", count: 64)
        let provider = StubImpactProvider(id: "impact", kind: .lexicalSearch, binding: .init(role: .analysis, path: "Tests/AppTests/ChangedTests.swift", contentSHA256: testSHA), evidence: testEvidence(path: "Tests/AppTests/ChangedTests.swift", sha: testSHA, summary: "keys"))
        let service = ChangeImpactService(runtimeStore: runtime.store, workspaceRuntime: runtime.workspace, evidenceStore: fixture.evidenceStore(), providers: [provider])
        let result = try await service.recommend(.init(impactRequest: recommendationImpact(fixture: fixture, cursor: runtime.cursor, changedSHA: changedSHA), projectID: "project-1", profileDigest: digest, catalog: recommendationCatalog(fixture: fixture, runtimeCursor: runtime.cursor, manifestSHA: manifestSHA, digest: digest)))
        let dependency = ChangeImpactRecommendationItem(kind: .dependencyEdge, itemID: "edge", focusedCheckID: "focused", dependsOn: "dependency")
        let gap = ChangeImpactRecommendationItem(kind: .coverageGap, itemID: "gap", coverageGap: .init(category: .references, reasonCode: "GAP", nextAction: "fix"))
        let allItems = result.items + [dependency, gap]
        let objects = try JSONSerialization.jsonObject(with: JSONEncoder().encode(allItems)) as! [[String: Any]]
        let expected: [String: Set<String>] = [
            "focused_candidate": ["kind", "itemID", "focusedCheckID", "profileCheckID", "profileDigest", "selector"],
            "focused_step": ["kind", "itemID", "focusedCheckID", "step"],
            "manifest_binding": ["kind", "itemID", "manifest"],
            "impact_evidence": ["kind", "itemID", "focusedCheckID", "evidence"],
            "dependency_edge": ["kind", "itemID", "focusedCheckID", "dependsOn"],
            "coverage_gap": ["kind", "itemID", "coverageGap"]
        ]
        XCTAssertEqual(Set(objects.compactMap { $0["kind"] as? String }), Set(expected.keys))
        for object in objects { XCTAssertEqual(Set(object.keys), expected[object["kind"] as! String]) }
    }

    func testDuplicateReasonsRemainOneCandidateWithAllEvidence() async throws {
        let fixture = try ImpactFixture()
        defer { fixture.cleanup() }
        let manifestSHA = try fixture.write("Package.swift", "// manifest\n")
        let changedSHA = try fixture.write("Sources/App/Changed.swift", "struct Changed {}\n")
        let testSHA = try fixture.write("Tests/AppTests/ChangedTests.swift", "func testChanged() {}\n")
        let runtime = try await fixture.runtime()
        let digest = String(repeating: "e", count: 64)
        let lexical = StubImpactProvider(id: "lexical", kind: .lexicalSearch, binding: .init(role: .analysis, path: "Tests/AppTests/ChangedTests.swift", contentSHA256: testSHA), evidence: testEvidence(path: "Tests/AppTests/ChangedTests.swift", sha: testSHA, summary: "lexical"))
        let index = StubImpactProvider(id: "index", kind: .workspaceIndex, binding: .init(role: .analysis, path: "Tests/AppTests/ChangedTests.swift", contentSHA256: testSHA), evidence: testEvidence(path: "Tests/AppTests/ChangedTests.swift", sha: testSHA, summary: "index"))
        let service = ChangeImpactService(runtimeStore: runtime.store, workspaceRuntime: runtime.workspace, evidenceStore: fixture.evidenceStore(), providers: [lexical, index])
        let result = try await service.recommend(.init(impactRequest: recommendationImpact(fixture: fixture, cursor: runtime.cursor, changedSHA: changedSHA), projectID: "project-1", profileDigest: digest, catalog: recommendationCatalog(fixture: fixture, runtimeCursor: runtime.cursor, manifestSHA: manifestSHA, digest: digest)))
        let evidence = result.items.filter { $0.kind == .impactEvidence }.compactMap(\.evidence)
        XCTAssertEqual(result.candidateCount, 1)
        XCTAssertEqual(evidence.count, 2)
        XCTAssertEqual(Set(evidence.map { $0.provenance.providerID }), ["index", "lexical"])
        XCTAssertTrue(evidence.allSatisfy { $0.provenance.providerVersion == "test-1" && $0.provenance.artifactDigest == result.items.first(where: { $0.kind == .impactEvidence })?.evidence?.provenance.artifactDigest && !$0.provenance.freshness.isEmpty })
    }

    func testContinuationPagesKeepFocusedSetIdentity() async throws {
        let fixture = try ImpactFixture()
        defer { fixture.cleanup() }
        let manifestSHA = try fixture.write("Package.swift", "// manifest\n")
        let changedSHA = try fixture.write("Sources/App/Changed.swift", "struct Changed {}\n")
        let testSHA = try fixture.write("Tests/AppTests/ChangedTests.swift", "func testChanged() {}\n")
        let runtime = try await fixture.runtime()
        let digest = String(repeating: "f", count: 64)
        let provider = StubImpactProvider(id: "impact", kind: .lexicalSearch, binding: .init(role: .analysis, path: "Tests/AppTests/ChangedTests.swift", contentSHA256: testSHA), evidence: testEvidence(path: "Tests/AppTests/ChangedTests.swift", sha: testSHA, summary: "page"))
        let service = ChangeImpactService(runtimeStore: runtime.store, workspaceRuntime: runtime.workspace, evidenceStore: fixture.evidenceStore(), providers: [provider])
        let initial = try await service.recommend(.init(impactRequest: recommendationImpact(fixture: fixture, cursor: runtime.cursor, changedSHA: changedSHA), projectID: "project-1", profileDigest: digest, catalog: recommendationCatalog(fixture: fixture, runtimeCursor: runtime.cursor, manifestSHA: manifestSHA, digest: digest), byteBudget: 600))
        XCTAssertTrue(initial.hasMore)
        var pages = [initial]
        while let token = pages.last?.continuation { pages.append(try await service.recommend(.init(byteBudget: 600, continuation: token))) }
        XCTAssertTrue(pages.allSatisfy { $0.focusedSetID == initial.focusedSetID && $0.focusedSetDigest == initial.focusedSetDigest })
        let ids = pages.flatMap(\.items).map(\.itemID)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(pages.flatMap(\.items).filter { $0.kind == .manifestBinding }.count, 1)
        XCTAssertEqual(pages.flatMap(\.items).filter { $0.kind == .focusedCandidate }.count, 1)
        XCTAssertEqual(pages.flatMap(\.items).filter { $0.kind == .focusedStep }.count, 1)
        XCTAssertEqual(pages.flatMap(\.items).filter { $0.kind == .impactEvidence }.count, 1)
    }

    func testOpaqueContinuationResumesRecommendByExactRegistryMembership() async throws {
        let fixture = try ImpactFixture()
        defer { fixture.cleanup() }
        let manifestSHA = try fixture.write("Package.swift", "// manifest\n")
        let changedSHA = try fixture.write("Sources/App/Changed.swift", "struct Changed {}\n")
        let testSHA = try fixture.write("Tests/AppTests/ChangedTests.swift", "func testChanged() {}\n")
        let runtime = try await fixture.runtime()
        let digest = String(repeating: "f", count: 64)
        let provider = StubImpactProvider(
            id: "impact",
            kind: .lexicalSearch,
            binding: .init(role: .analysis, path: "Tests/AppTests/ChangedTests.swift", contentSHA256: testSHA),
            evidence: testEvidence(path: "Tests/AppTests/ChangedTests.swift", sha: testSHA, summary: "page")
        )
        let service = ChangeImpactService(runtimeStore: runtime.store, workspaceRuntime: runtime.workspace, evidenceStore: fixture.evidenceStore(), providers: [provider])
        let initial = try await service.recommend(.init(
            impactRequest: recommendationImpact(fixture: fixture, cursor: runtime.cursor, changedSHA: changedSHA),
            projectID: "project-1",
            profileDigest: digest,
            catalog: recommendationCatalog(fixture: fixture, runtimeCursor: runtime.cursor, manifestSHA: manifestSHA, digest: digest),
            byteBudget: 600
        ))
        let token = try XCTUnwrap(initial.continuation)

        let resumed = try await service.continueImpact(continuation: token, byteBudget: 600)
        guard case let .recommend(page) = resumed else {
            return XCTFail("recommend continuation が analyze として再開されました")
        }
        XCTAssertEqual(page.operation, .recommend)
    }

    private func recommendationImpact(fixture: ImpactFixture, cursor: String, changedSHA: String) -> ChangeImpactRequest {
        .init(operation: .analyze, root: fixture.root.path, workspaceCursor: cursor, changedPaths: [.init(path: "Sources/App/Changed.swift", contentSHA256: changedSHA)], byteBudget: 1_048_576)
    }

    private func recommendationCatalog(fixture: ImpactFixture, runtimeCursor: String, manifestSHA: String, digest: String, projectRoot: String? = nil, checkExecutable: String = "/usr/bin/true", checkArguments: [String] = []) -> ProjectProfileCatalogResult {
        let provenance = ProjectProfileProvenance(kind: "manifest", path: "Package.swift", contentSHA256: manifestSHA, producerVersion: "test", confidence: "declared")
        let check = ProjectProfileCheck(checkId: "test-check", kind: "test", label: "test", executable: checkExecutable, arguments: checkArguments, workingDirectory: fixture.root.path, environmentKeys: [], provenance: provenance)
        let profile = ProjectProfile(schemaVersion: "aishell.project-profile.v1", projectId: "project-1", projectRoot: projectRoot ?? fixture.root.path, projectRootIdentity: "project-root", displayName: "fixture", ecosystem: "swiftpm", classification: "primary", status: .complete, provider: "test", providerVersion: "1", manifests: [.init(path: "Package.swift", role: "primary", identity: "manifest-identity", sha256: manifestSHA, parseStatus: "parsed")], memberProjectIds: [], targets: [.init(targetId: "test-target", name: "AppTests", kind: "test", dependencies: [], sourceRoots: ["Tests/AppTests"], resourceRoots: [], testRelation: "package-tests", provenance: provenance)], checks: [check], toolchains: [], providerEvidence: nil, missingCapabilities: [], diagnostics: [], binding: "binding", freshness: .freshComputed, observedCursor: runtimeCursor, profileDigest: digest, invalidationReasons: [])
        return .init(schemaVersion: "aishell.project-profile-catalog.v1", root: fixture.root.path, observedCursor: runtimeCursor, profiles: [profile], computedProfiles: 1, cachedProfiles: 0)
    }

    private func testEvidence(path: String, locatorPath: String? = nil, sha: String, summary: String) -> ChangeImpactEvidenceSeed {
        .init(inputIdentity: "changed", candidate: .init(category: .relatedTests, subject: .test(path: path)), relation: .containsTest, locator: .init(path: locatorPath ?? path, contentSHA256: sha), strength: .declaredEdge, summary: summary)
    }
}

private actor ImpactProviderCallCounter {
    private(set) var value = 0
    private(set) var executionCount = 0

    func recordAnalysis() { value += 1 }
}

private struct CountingImpactProvider: ChangeImpactProvider {
    let descriptor: ChangeImpactProviderDescriptor
    let counter: ImpactProviderCallCounter
    let binding: ChangeImpactFreshnessBinding
    let evidence: ChangeImpactEvidenceSeed

    init(id: String, kind: ChangeImpactProviderKind, counter: ImpactProviderCallCounter, binding: ChangeImpactFreshnessBinding, evidence: ChangeImpactEvidenceSeed) {
        descriptor = .init(providerID: id, kind: kind, version: "test-1")
        self.counter = counter; self.binding = binding; self.evidence = evidence
    }

    func analyze(_ input: ChangeImpactProviderInput) async throws -> ChangeImpactProviderOutput {
        await counter.recordAnalysis()
        return .init(report: .init(descriptor: descriptor, status: .fresh, inputDigest: String(repeating: "a", count: 64), observedAtCursor: input.workspaceCursor), evidence: [evidence], freshnessBindings: [binding])
    }
}

private struct StubImpactProvider: ChangeImpactProvider {
    let descriptor: ChangeImpactProviderDescriptor
    let status: ChangeImpactProviderStatus
    let reasonCode: String?
    let binding: ChangeImpactFreshnessBinding?
    let evidence: ChangeImpactEvidenceSeed?

    init(
        id: String,
        kind: ChangeImpactProviderKind,
        status: ChangeImpactProviderStatus = .fresh,
        reasonCode: String? = nil,
        binding: ChangeImpactFreshnessBinding? = nil,
        evidence: ChangeImpactEvidenceSeed? = nil
    ) {
        descriptor = .init(providerID: id, kind: kind, version: "test-1")
        self.status = status
        self.reasonCode = reasonCode
        self.binding = binding
        self.evidence = evidence
    }

    func analyze(_ input: ChangeImpactProviderInput) async throws -> ChangeImpactProviderOutput {
        ChangeImpactProviderOutput(
            report: .init(
                descriptor: descriptor,
                status: status,
                inputDigest: String(repeating: "a", count: 64),
                observedAtCursor: input.workspaceCursor,
                reasonCode: reasonCode,
                nextAction: status == .fresh ? nil : "providerを再同期してください。"
            ),
            evidence: evidence.map { [$0] } ?? [],
            freshnessBindings: binding.map { [$0] } ?? []
        )
    }
}

private final class ImpactFixture: @unchecked Sendable {
    let base: URL
    let root: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIShellChangeImpact-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ relativePath: String, _ text: String) throws -> String {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Data(text.utf8)
        try data.write(to: url, options: .atomic)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func runtime(suffix: String = "default") async throws -> (
        store: RuntimeStore,
        workspace: WorkspaceStateRuntime,
        cursor: String
    ) {
        let store = RuntimeStore(baseDirectory: base.appendingPathComponent("runtime-\(suffix)"))
        await store.setWorkingDirectoryForTesting(root)
        let workspace = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        let snapshot = try await workspace.snapshot(path: root.path, contextBudget: 0)
        return (store, workspace, snapshot.cursor)
    }

    func evidenceStore(suffix: String = "default") -> EvidenceStore {
        EvidenceStore(baseDirectory: base.appendingPathComponent("evidence-\(suffix)", isDirectory: true))
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

private func XCTAssertThrowsImpactError<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ inspect: (ChangeImpactError) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("errorになりませんでした。", file: file, line: line)
    } catch let error as ChangeImpactError {
        inspect(error)
    } catch {
        XCTFail("想定外のerror: \(error)", file: file, line: line)
    }
}
