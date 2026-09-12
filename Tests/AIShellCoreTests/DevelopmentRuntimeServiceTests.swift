import CryptoKit
import XCTest
@testable import AIShellCore

final class DevelopmentRuntimeServiceTests: XCTestCase {
    func testRunCheckReturnsSmallSummaryAndRetainedStreams() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let allowed = fixture.base.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        let runtimeStore = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await runtimeStore.setWorkingDirectoryForTesting(allowed)
        let evidenceStore = EvidenceStore(baseDirectory: fixture.base.appendingPathComponent("evidence"))
        let service = DevelopmentRuntimeService(runtimeStore: runtimeStore, evidenceStore: evidenceStore)

        let result = try await service.runCheck(
            executable: "/usr/bin/printf",
            arguments: ["%s", "direct-check"],
            workingDirectory: ".",
            timeoutSeconds: 5
        )

        XCTAssertEqual(result.status, .passed)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.summary, "成功: exit 0")
        XCTAssertLessThan(result.summary.utf8.count, 128)
        let stdout = try await evidenceStore.read(
            handle: result.stdoutArtifact.handle,
            mode: .range(offset: 0, length: 1_024),
            byteBudget: 1_024
        )
        XCTAssertEqual(stdout.text, "direct-check")
    }

    func testRunCheckExtractsPrimaryDiagnosticAndKeepsCompleteLog() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let allowed = fixture.base.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        let runtimeStore = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await runtimeStore.setWorkingDirectoryForTesting(allowed)
        let evidenceStore = EvidenceStore(baseDirectory: fixture.base.appendingPathComponent("evidence"))
        let service = DevelopmentRuntimeService(runtimeStore: runtimeStore, evidenceStore: evidenceStore)

        let result = try await service.runCheck(
            executable: "/usr/bin/false",
            workingDirectory: ".",
            timeoutSeconds: 5
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertNotNil(result.stderrArtifact.handle)
        XCTAssertTrue(result.summary.contains("失敗"))
    }

    func testRunCheckFindsPrimaryDiagnosticAtTailOfLargeLog() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let allowed = fixture.base.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        let runtimeStore = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await runtimeStore.setWorkingDirectoryForTesting(allowed)
        let evidenceStore = EvidenceStore(baseDirectory: fixture.base.appendingPathComponent("evidence"))
        let service = DevelopmentRuntimeService(runtimeStore: runtimeStore, evidenceStore: evidenceStore)

        let result = try await service.runCheck(
            executable: "/usr/bin/awk",
            arguments: [
                "BEGIN { for (i = 0; i < 4000; i++) print \"dependency diagnostic padding padding padding\" > \"/dev/stderr\"; print \"SyntaxError: primary failure\" > \"/dev/stderr\"; exit 1 }"
            ],
            workingDirectory: ".",
            timeoutSeconds: 5
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.primaryDiagnostic, "SyntaxError: primary failure")
        XCTAssertGreaterThan(result.stderrArtifact.sizeBytes, 65_536)
    }
}

final class RunCheckPipelineIntegrationTests: XCTestCase {
    func testPublicProfileAndFocusedRunCheckResolveFromOwnedDirectOSState() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        {"name":"runtime-public-path","version":"1.0.0","scripts":{"test":"node --version"}}
        """.write(
            to: root.appendingPathComponent("package.json"),
            atomically: true,
            encoding: .utf8
        )
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(root)
        let workspace = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        let evidence = EvidenceStore(baseDirectory: fixture.base.appendingPathComponent("evidence"))
        let focused = FocusedCheckService()
        let profiles = ProjectProfileService(
            runtimeStore: store,
            workspaceRuntime: workspace,
            evidenceStore: evidence
        )
        let service = DevelopmentRuntimeService(
            runtimeStore: store,
            evidenceStore: evidence,
            workspaceRuntime: workspace,
            focusedChecks: focused,
            freshnessCache: .inMemory(),
            projectProfiles: profiles
        )
        let snapshot = try await workspace.snapshot(path: root.path, contextBudget: 0)
        let catalog = try await profiles.catalog(for: snapshot)
        let profile = try XCTUnwrap(catalog.profiles.first)
        let check = try XCTUnwrap(profile.checks.first(where: { $0.kind == "test" }))
        let profilePlan = try RunCheckInvocationPlan.prepare(.init(
            invocation: .profileCheck(.init(
                projectID: profile.projectId,
                profileDigest: profile.profileDigest,
                checkID: check.checkId
            )),
            dispatch: .sync,
            cachePolicy: .off,
            executionPolicy: .init(timeoutMilliseconds: 5_000, retentionSeconds: 3_600)
        ))

        let profileResult = try await service.runCheck(plan: profilePlan)
        XCTAssertEqual(profileResult.processesStarted, 1)
        XCTAssertEqual(profileResult.requestedCheckIDs, [check.checkId])
        XCTAssertEqual(profileResult.steps.first?.terminalState, .passed)

        let cursorParts = catalog.observedCursor.split(separator: ":", omittingEmptySubsequences: false)
        let generation = try XCTUnwrap(cursorParts.count == 5 ? String(cursorParts[3]) : nil)
        let manifest = try XCTUnwrap(profile.manifests.first)
        let impactDigest = SHA256.hash(data: Data("impact-artifact".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let descriptorDigest = SHA256.hash(data: Data("focused-descriptor".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let set = try await focused.compile(.init(
            rootIdentity: profile.projectRootIdentity,
            generation: generation,
            cursor: catalog.observedCursor,
            profileDigest: profile.profileDigest,
            manifestIdentity: manifest.identity,
            impactArtifactDigest: impactDigest,
            candidates: [.init(
                profileCheckID: check.checkId,
                profileDigest: profile.profileDigest,
                selector: .profileCheck(id: check.checkId),
                steps: [.init(id: "focused-test", descriptorDigest: descriptorDigest)],
                evidence: [.init(
                    id: "focused-evidence",
                    provenance: .init(
                        providerID: "test",
                        providerVersion: "1",
                        artifactDigest: impactDigest,
                        freshness: "fresh"
                    )
                )]
            )],
            expiresAt: .distantFuture
        ))
        let admission = FocusedCheckService.Admission(
            rootIdentity: profile.projectRootIdentity,
            generation: generation,
            cursor: catalog.observedCursor,
            profileDigest: profile.profileDigest,
            manifestIdentity: manifest.identity,
            impactArtifactDigest: impactDigest
        )
        let candidateID = try XCTUnwrap(set.candidates.first?.focusedCheckID)
        let selection = try await focused.resolve(
            focusedSetID: set.id,
            focusedSetDigest: set.digest,
            requestedCheckIDs: [candidateID],
            admission: admission
        )
        let focusedPlan = try RunCheckInvocationPlan.compile(.v2(.init(
            invocation: .focusedSet(.init(setID: set.id, orderedCheckIDs: [candidateID])),
            dispatch: .sync,
            cachePolicy: .off,
            executionPolicy: .init(timeoutMilliseconds: 5_000, retentionSeconds: 3_600),
            selectionDigest: selection.selectionDigest
        )))

        let focusedResult = try await service.runCheck(
            plan: focusedPlan,
            focusedSetDigest: set.digest
        )
        XCTAssertEqual(focusedResult.processesStarted, 1)
        XCTAssertEqual(focusedResult.requestedCheckIDs, [candidateID])
        XCTAssertEqual(focusedResult.plannedCheckIDs, [candidateID])
        XCTAssertEqual(focusedResult.steps.map { $0.stepID }, ["focused-test"])

        try await profiles.invalidateAll()
        await assertPipelineError({
            try await service.runCheck(plan: focusedPlan, focusedSetDigest: set.digest)
        }) {
            XCTAssertEqual($0.code, "RUN_CHECK_SELECTION_STALE")
            XCTAssertEqual($0.processesStarted, 0)
        }
    }

    func testLegacyV1StillReturnsOriginalSummaryAndArtifact() async throws {
        let fixture = try await PipelineFixture()
        defer { fixture.cleanup() }
        let result = try await fixture.service.runCheck(
            executable: "/usr/bin/printf", arguments: ["%s", "legacy"], workingDirectory: ".", timeoutSeconds: 5
        )
        XCTAssertEqual(result.schemaVersion, "aishell.run-check.v1")
        XCTAssertEqual(result.summary, "成功: exit 0")
        let stdout = try await fixture.stdout(result.stdoutArtifact)
        XCTAssertEqual(stdout, "legacy")
    }

    func testProfileCheckRequiresExactProjectDigestAndCheckID() async throws {
        let fixture = try await PipelineFixture()
        defer { fixture.cleanup() }
        let valid = try fixture.profilePlan(cache: .off)
        let result = try await fixture.service.runCheck(plan: valid, resolution: fixture.context)
        XCTAssertEqual(result.processesStarted, 1)
        XCTAssertEqual(result.requestedCheckIDs, [fixture.check.checkId])

        let stale = try fixture.profilePlan(cache: .off, profileDigest: PipelineFixture.hash("stale"))
        await assertPipelineError({ try await fixture.service.runCheck(plan: stale, resolution: fixture.context) }) {
            XCTAssertEqual($0.code, "RUN_CHECK_SELECTION_STALE")
            XCTAssertEqual($0.processesStarted, 0)
        }
    }

    func testFocusedSelectionPreservesRequestedOrderAndPublishedSteps() async throws {
        let fixture = try await PipelineFixture()
        defer { fixture.cleanup() }
        let focused = fixture.focused
        let first = fixture.candidate(name: "first", path: "Tests/First.swift")
        let second = fixture.candidate(name: "second", path: "Tests/Second.swift")
        let set = try await focused.compile(fixture.compileRequest(candidates: [first, second]))
        let ids = set.candidates.map(\.focusedCheckID)
        let requested = [ids[1], ids[0]]
        let selection = try await focused.resolve(
            focusedSetID: set.id, focusedSetDigest: set.digest,
            requestedCheckIDs: requested, admission: fixture.admission
        )
        let plan = try fixture.focusedPlan(setID: set.id, ids: requested, digest: selection.selectionDigest, cache: .off)
        let result = try await fixture.service.runCheck(plan: plan, resolution: fixture.focusedContext)
        XCTAssertEqual(result.requestedCheckIDs, requested)
        XCTAssertEqual(result.plannedCheckIDs, requested)
        XCTAssertEqual(result.steps.map(\.stepID), selection.steps.map(\.id))
        XCTAssertEqual(result.processesStarted, 2)
    }

    func testPreferMissExecutesThenPreferHitStartsZeroProcesses() async throws {
        let fixture = try await PipelineFixture()
        defer { fixture.cleanup() }
        let first = try await fixture.service.runCheck(
            plan: fixture.profilePlan(cache: .prefer), resolution: fixture.context
        )
        XCTAssertEqual(first.cacheState, .missExecuted)
        XCTAssertEqual(first.processesStarted, 1)
        let hit = try await fixture.service.runCheck(
            plan: fixture.profilePlan(cache: .prefer), resolution: fixture.context
        )
        XCTAssertEqual(hit.cacheState, .hit)
        XCTAssertEqual(hit.processesStarted, 0)
        XCTAssertEqual(hit.steps.map(\.sourceRunID), first.steps.map(\.sourceRunID))
    }

    func testOnlyMissIsTypedAndStartsNoProcess() async throws {
        let fixture = try await PipelineFixture()
        defer { fixture.cleanup() }
        await assertPipelineError({
            try await fixture.service.runCheck(plan: fixture.profilePlan(cache: .only), resolution: fixture.context)
        }) {
            XCTAssertEqual($0.code, "RUN_CHECK_CACHE_MISS")
            XCTAssertEqual($0.processesStarted, 0)
        }
    }

    func testPreferIneligibleExecutesSamePlanWithoutPublicationOrLaterHit() async throws {
        let fixture = try await PipelineFixture()
        defer { fixture.cleanup() }
        let ineligible = RunCheckResolutionContext(profileCatalog: fixture.catalog)
        let first = try await fixture.service.runCheck(
            plan: fixture.profilePlan(cache: .prefer), resolution: ineligible
        )
        let second = try await fixture.service.runCheck(
            plan: fixture.profilePlan(cache: .prefer), resolution: ineligible
        )
        XCTAssertEqual(first.cacheState, .ineligible)
        XCTAssertEqual(second.cacheState, .ineligible)
        XCTAssertEqual(first.processesStarted, 1)
        XCTAssertEqual(second.processesStarted, 1)
        XCTAssertEqual(first.publications, 0)
        XCTAssertEqual(second.publications, 0)
        XCTAssertNotEqual(first.steps[0].sourceRunID, second.steps[0].sourceRunID)
    }

    func testOnlyIneligibleReturnsOrderedMissEvidenceWithProcessZero() async throws {
        let fixture = try await PipelineFixture()
        defer { fixture.cleanup() }
        let ineligible = RunCheckResolutionContext(profileCatalog: fixture.catalog)
        await assertPipelineError({
            try await fixture.service.runCheck(plan: fixture.profilePlan(cache: .only), resolution: ineligible)
        }) { error in
            XCTAssertEqual(error.code, "RUN_CHECK_CACHE_MISS")
            XCTAssertEqual(error.processesStarted, 0)
            guard case .cacheMiss(_, let evidence) = error else { return XCTFail("cache miss evidence expected") }
            XCTAssertEqual(evidence.map(\.stepID), [fixture.check.checkId])
            XCTAssertEqual(evidence.map(\.status), [.ineligible])
            XCTAssertEqual(evidence.map(\.ineligibilityReason), [.bindingIncomplete])
        }
    }

    func testRefreshIneligibleExecutesWithoutPublicationOrHit() async throws {
        let fixture = try await PipelineFixture()
        defer { fixture.cleanup() }
        let ineligible = RunCheckResolutionContext(profileCatalog: fixture.catalog)
        let refreshed = try await fixture.service.runCheck(
            plan: fixture.profilePlan(cache: .refresh), resolution: ineligible
        )
        XCTAssertEqual(refreshed.cacheState, .ineligible)
        XCTAssertEqual(refreshed.processesStarted, 1)
        XCTAssertEqual(refreshed.publications, 0)
        let repeated = try await fixture.service.runCheck(
            plan: fixture.profilePlan(cache: .prefer), resolution: ineligible
        )
        XCTAssertEqual(repeated.cacheState, .ineligible)
        XCTAssertEqual(repeated.processesStarted, 1)
        XCTAssertEqual(repeated.publications, 0)
    }

    func testRefreshExecutesWithoutLookupReuse() async throws {
        let fixture = try await PipelineFixture()
        defer { fixture.cleanup() }
        let first = try await fixture.service.runCheck(
            plan: fixture.profilePlan(cache: .refresh), resolution: fixture.context
        )
        let second = try await fixture.service.runCheck(
            plan: fixture.profilePlan(cache: .refresh), resolution: fixture.context
        )
        XCTAssertEqual(first.cacheState, .refreshExecuted)
        XCTAssertEqual(second.cacheState, .refreshExecuted)
        XCTAssertEqual(first.processesStarted, 1)
        XCTAssertEqual(second.processesStarted, 1)
    }

    func testCorruptCachedArtifactFailsClosedWithoutRerun() async throws {
        let fixture = try await PipelineFixture()
        defer { fixture.cleanup() }
        let seeded = try await fixture.service.runCheck(
            plan: fixture.profilePlan(cache: .refresh), resolution: fixture.context
        )
        await fixture.evidence.discard(handle: seeded.steps[0].artifacts[0].handle)
        await assertPipelineError({
            try await fixture.service.runCheck(plan: fixture.profilePlan(cache: .prefer), resolution: fixture.context)
        }) {
            XCTAssertEqual($0.code, "CACHE_CORRUPT")
            XCTAssertEqual($0.processesStarted, 0)
        }
    }

    func testRelevantInputChangeAfterExecutionRejectsPublication() async throws {
        let fixture = try await PipelineFixture()
        defer { fixture.cleanup() }
        let before = PipelineFixture.hash("before")
        let changed = PipelineFixture.hash("changed")
        let context = RunCheckResolutionContext(
            profileCatalog: fixture.catalog,
            relevantInputsByCheckID: [fixture.check.checkId: .init(digest: before, reobserveDigest: { changed })]
        )
        await assertPipelineError({
            try await fixture.service.runCheck(plan: fixture.profilePlan(cache: .refresh), resolution: context)
        }) {
            XCTAssertEqual($0.code, "CONTENT_CHANGED")
            XCTAssertEqual($0.processesStarted, 1)
        }
    }

    func testStartReturnsTypedNotReadyBeforeResolutionOrProcess() async throws {
        let fixture = try await PipelineFixture()
        defer { fixture.cleanup() }
        let plan = try fixture.profilePlan(cache: .off, dispatch: .start(clientRunKey: "start-key"))
        await assertPipelineError({ try await fixture.service.runCheck(plan: plan, resolution: fixture.context) }) {
            XCTAssertEqual($0.code, "RUN_CHECK_START_NOT_READY")
            XCTAssertEqual($0.processesStarted, 0)
        }
    }

    func testFocusedTestPathDoesNotExpandToAllTests() async throws {
        let fixture = try await PipelineFixture()
        defer { fixture.cleanup() }
        let path = "Tests/OnlyThis.swift"
        let set = try await fixture.focused.compile(fixture.compileRequest(candidates: [fixture.candidate(name: "only", path: path)]))
        let id = set.candidates[0].focusedCheckID
        let selection = try await fixture.focused.resolve(
            focusedSetID: set.id, focusedSetDigest: set.digest,
            requestedCheckIDs: [id], admission: fixture.admission
        )
        let plan = try fixture.focusedPlan(setID: set.id, ids: [id], digest: selection.selectionDigest, cache: .off)
        let result = try await fixture.service.runCheck(plan: plan, resolution: fixture.focusedContext)
        XCTAssertEqual(result.processesStarted, 1)
        let stdout = try await fixture.stdout(result.steps[0].artifacts[0])
        XCTAssertEqual(stdout, path)
    }

    func testFailedDAGStepSkipsOnlyDependentAndRunsIndependentStep() async throws {
        let fixture = try await PipelineFixture(executable: "/usr/bin/false", arguments: [])
        defer { fixture.cleanup() }
        let candidate = fixture.candidate(
            name: "dag", path: nil,
            steps: [fixture.step("fail"), fixture.step("dependent", dependsOn: ["fail"]), fixture.step("independent")]
        )
        let set = try await fixture.focused.compile(fixture.compileRequest(candidates: [candidate]))
        let id = set.candidates[0].focusedCheckID
        let selection = try await fixture.focused.resolve(
            focusedSetID: set.id, focusedSetDigest: set.digest,
            requestedCheckIDs: [id], admission: fixture.admission
        )
        let plan = try fixture.focusedPlan(setID: set.id, ids: [id], digest: selection.selectionDigest, cache: .off)
        let result = try await fixture.service.runCheck(plan: plan, resolution: fixture.focusedContext)
        XCTAssertEqual(result.processesStarted, 2)
        XCTAssertEqual(result.steps.map(\.stepID), ["fail", "independent", "dependent"])
        XCTAssertTrue(result.steps.first(where: { $0.stepID == "dependent" })!.skippedBecauseDependencyFailed)
        XCTAssertFalse(result.steps.first(where: { $0.stepID == "independent" })!.skippedBecauseDependencyFailed)
    }
}

private final class PipelineFixture {
    let fixture: TemporaryFixture
    let root: URL
    let evidence: EvidenceStore
    let focused: FocusedCheckService
    let service: DevelopmentRuntimeService
    let check: ProjectProfileCheck
    let profile: ProjectProfile
    let catalog: ProjectProfileCatalogResult
    let admission: FocusedCheckService.Admission

    init(executable: String = "/usr/bin/printf", arguments: [String] = ["%s"]) async throws {
        fixture = try TemporaryFixture()
        root = fixture.base.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifestURL = root.appendingPathComponent("package.json")
        try Data("{}".utf8).write(to: manifestURL)
        let runtime = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime", isDirectory: true))
        await runtime.setWorkingDirectoryForTesting(root)
        evidence = EvidenceStore(baseDirectory: fixture.base.appendingPathComponent("evidence", isDirectory: true))
        focused = FocusedCheckService()
        let cache = CheckFreshnessCache.inMemory()
        service = DevelopmentRuntimeService(
            runtimeStore: runtime, evidenceStore: evidence,
            focusedChecks: focused, freshnessCache: cache
        )
        let manifestBytes = try Data(contentsOf: manifestURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        let manifestIdentity = "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? "")"
        let executableURL = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        let executableAttributes = try FileManager.default.attributesOfItem(atPath: executableURL.path)
        let toolIdentity = "\(executableAttributes[.systemNumber] ?? ""):\(executableAttributes[.systemFileNumber] ?? "")"
        check = ProjectProfileCheck(
            checkId: Self.hash("check"), kind: "test", label: "test",
            executable: executable, arguments: arguments, workingDirectory: root.path,
            environmentKeys: [],
            provenance: .init(kind: "manifest", path: "package.json", contentSHA256: Self.sha256(manifestBytes), producerVersion: "1", confidence: "declared")
        )
        profile = ProjectProfile(
            schemaVersion: "aishell.project-profile.v1", projectId: "project", projectRoot: "",
            projectRootIdentity: "root", displayName: "fixture", ecosystem: "npm",
            classification: "root", status: .complete, provider: "npm", providerVersion: "1",
            manifests: [.init(path: "package.json", role: "primary", identity: manifestIdentity, sha256: Self.sha256(manifestBytes), parseStatus: "parsed")],
            memberProjectIds: [], targets: [], checks: [check],
            toolchains: [.init(name: "tool", executable: executable, identity: toolIdentity, sha256: Self.sha256(try Data(contentsOf: executableURL, options: .mappedIfSafe)), versionArguments: [], version: "1", exitStatus: 0, evidenceSHA256: Self.hash("tool-evidence"), evidenceHandle: "tool", evidenceExpiresAt: "future")],
            providerEvidence: nil, missingCapabilities: [], diagnostics: [], binding: Self.hash("binding"),
            freshness: .freshComputed, observedCursor: "cursor", profileDigest: Self.hash("profile"), invalidationReasons: []
        )
        catalog = ProjectProfileCatalogResult(
            schemaVersion: "aishell.project-profile-catalog.v1", root: root.path,
            observedCursor: "cursor", profiles: [profile], computedProfiles: 1, cachedProfiles: 0
        )
        admission = .init(
            rootIdentity: profile.projectRootIdentity, generation: "generation", cursor: "cursor",
            profileDigest: profile.profileDigest, manifestIdentity: manifestIdentity,
            impactArtifactDigest: Self.hash("impact")
        )
    }

    var context: RunCheckResolutionContext {
        .init(profileCatalog: catalog, relevantInputsByCheckID: relevantInputBindings)
    }
    var focusedContext: RunCheckResolutionContext {
        .init(profileCatalog: catalog, focusedAdmission: admission, relevantInputsByCheckID: relevantInputBindings)
    }
    private var relevantInputBindings: [String: RunCheckRelevantInputBinding] {
        let digest = Self.hash("complete-input-closure")
        return [check.checkId: .init(digest: digest, reobserveDigest: { digest })]
    }

    func profilePlan(
        cache: RunCheckInvocationPlan.CachePolicy,
        profileDigest: String? = nil,
        dispatch: RunCheckInvocationPlan.Dispatch = .sync
    ) throws -> RunCheckInvocationPlan {
        try RunCheckInvocationPlan.compile(.v2(.init(
            invocation: .profileCheck(.init(projectID: profile.projectId, profileDigest: profileDigest ?? profile.profileDigest, checkID: check.checkId)),
            dispatch: dispatch, cachePolicy: cache,
            executionPolicy: .init(timeoutMilliseconds: 5_000, retentionSeconds: 3_600),
            selectionDigest: Self.hash("profile-selection")
        )))
    }

    func focusedPlan(setID: String, ids: [String], digest: String, cache: RunCheckInvocationPlan.CachePolicy) throws -> RunCheckInvocationPlan {
        try RunCheckInvocationPlan.compile(.v2(.init(
            invocation: .focusedSet(.init(setID: setID, orderedCheckIDs: ids)), dispatch: .sync,
            cachePolicy: cache, executionPolicy: .init(timeoutMilliseconds: 5_000, retentionSeconds: 3_600),
            selectionDigest: digest
        )))
    }

    func compileRequest(candidates: [FocusedCheckService.Candidate]) -> FocusedCheckService.CompileRequest {
        .init(
            rootIdentity: admission.rootIdentity, generation: admission.generation, cursor: admission.cursor,
            profileDigest: admission.profileDigest, manifestIdentity: admission.manifestIdentity,
            impactArtifactDigest: admission.impactArtifactDigest, candidates: candidates, expiresAt: .distantFuture
        )
    }

    func candidate(name: String, path: String?, steps: [FocusedCheckService.Step]? = nil) -> FocusedCheckService.Candidate {
        .init(
            profileCheckID: check.checkId, profileDigest: profile.profileDigest,
            selector: path.map { .testPath(path: $0) } ?? .profileCheck(id: check.checkId),
            steps: steps ?? [step("\(name)-step")],
            evidence: [.init(id: name, provenance: .init(providerID: "impact", providerVersion: "1", artifactDigest: Self.hash("artifact-\(name)"), freshness: "fresh"))]
        )
    }

    func step(_ id: String, dependsOn: [String] = []) -> FocusedCheckService.Step {
        .init(id: id, descriptorDigest: Self.hash("descriptor-\(id)"), dependsOn: dependsOn)
    }

    func stdout(_ artifact: ArtifactMetadata) async throws -> String? {
        try await evidence.read(handle: artifact.handle, mode: .range(offset: 0, length: 4_096), byteBudget: 4_096).text
    }

    func cleanup() { fixture.cleanup() }
    static func hash(_ value: String) -> String { sha256(Data(value.utf8)) }
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

private func assertPipelineError<T>(
    _ expression: @escaping () async throws -> T,
    _ check: (RunCheckPipelineError) -> Void
) async {
    do { _ = try await expression(); XCTFail("error expected") }
    catch let error as RunCheckPipelineError { check(error) }
    catch { XCTFail("unexpected error: \(error)") }
}
