import Foundation
import XCTest
@testable import AIShellCore

final class RunCheckResolutionServiceTests: XCTestCase {
    func testCompleteContractProducesDeterministicReceiptAndReobservation() async throws {
        let fixture = try ResolutionFixture(completeContract: .complete(
            provider: "fixture",
            providerVersion: "fixture-v1",
            includedRoots: ["Inputs"],
            trackedPaths: ["optional.json"]
        ))
        defer { fixture.cleanup() }
        try "value\n".write(to: fixture.inputs.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)
        let context = try await fixture.context()

        let first = try await context.resolver.resolve(context.request)
        let second = try await context.resolver.reobserve(first)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.schemaVersion, "aishell.run-check-relevant-input-receipt.v1")
        XCTAssertEqual(first.provider, "fixture")
        XCTAssertEqual(first.providerVersion, "fixture-v1")
        XCTAssertEqual(first.observationProviderVersion, "direct-os-merkle-v1")
        XCTAssertEqual(first.eligibility, .eligible)
        XCTAssertEqual(first.completeness, "complete")
        XCTAssertEqual(first.leafCount, 3)
        XCTAssertEqual(first.merkleDigest?.count, 64)
        XCTAssertEqual(first.bindingDigest?.count, 64)
        guard case .eligible(let digest) = first.cacheBinding else {
            return XCTFail("eligible cache bindingではありません")
        }
        XCTAssertEqual(digest, first.bindingDigest)
    }

    func testLargeFileContentParticipatesInBindingBeyondSnapshotHashLimit() async throws {
        let fixture = try ResolutionFixture(completeContract: .complete(provider: "fixture", providerVersion: "fixture-v1", includedRoots: ["Inputs"]))
        defer { fixture.cleanup() }
        let large = fixture.inputs.appendingPathComponent("large.bin")
        try Data(repeating: 0x11, count: 5 * 1_024 * 1_024).write(to: large)
        let context = try await fixture.context()
        let before = try await context.resolver.resolve(context.request)

        try Data(repeating: 0x22, count: 5 * 1_024 * 1_024).write(to: large)
        let after = try await context.resolver.resolve(context.request)

        XCTAssertNotEqual(before.merkleDigest, after.merkleDigest)
        XCTAssertNotEqual(before.bindingDigest, after.bindingDigest)
        XCTAssertEqual(before.leafCount, after.leafCount)
    }

    func testDirectoryMembershipAndTrackedMissingPathChangeBinding() async throws {
        let fixture = try ResolutionFixture(completeContract: .complete(
            provider: "fixture",
            providerVersion: "fixture-v1",
            includedRoots: ["Inputs"],
            trackedPaths: ["optional.json"]
        ))
        defer { fixture.cleanup() }
        let context = try await fixture.context()
        let missing = try await context.resolver.resolve(context.request)

        try "member\n".write(to: fixture.inputs.appendingPathComponent("member.txt"), atomically: true, encoding: .utf8)
        try "present\n".write(to: fixture.root.appendingPathComponent("optional.json"), atomically: true, encoding: .utf8)
        let present = try await context.resolver.resolve(context.request)

        XCTAssertEqual(missing.leafCount, 2)
        XCTAssertEqual(present.leafCount, 3)
        XCTAssertNotEqual(missing.merkleDigest, present.merkleDigest)
    }

    func testSymlinkAndRootEscapeContractsFailClosed() async throws {
        let fixture = try ResolutionFixture(completeContract: .complete(provider: "fixture", providerVersion: "fixture-v1", includedRoots: ["Inputs"]))
        defer { fixture.cleanup() }
        try FileManager.default.createSymbolicLink(
            at: fixture.inputs.appendingPathComponent("escape"),
            withDestinationURL: fixture.base
        )
        let symlinkContext = try await fixture.context()
        do {
            _ = try await symlinkContext.resolver.resolve(symlinkContext.request)
            XCTFail("symlink escapeをeligibleにしました")
        } catch {
            guard case WorkspaceRelevantInputObservationError.symlinkEncountered("Inputs/escape") = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }

        try FileManager.default.removeItem(at: fixture.inputs.appendingPathComponent("escape"))
        let outsideFixture = try ResolutionFixture(completeContract: .complete(provider: "fixture", providerVersion: "fixture-v1", includedRoots: ["../outside"]))
        defer { outsideFixture.cleanup() }
        let outsideContext = try await outsideFixture.context()
        do {
            _ = try await outsideContext.resolver.resolve(outsideContext.request)
            XCTFail("project root外contractをeligibleにしました")
        } catch {
            guard case WorkspaceRelevantInputObservationError.invalidContractPath("../outside") = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }
    }

    func testUnsupportedProviderReturnsTypedIneligibleReceiptWithoutRemovingExecution() async throws {
        let fixture = try ResolutionFixture(completeContract: nil)
        defer { fixture.cleanup() }
        let context = try await fixture.context()

        let receipt = try await context.resolver.resolve(context.request)

        XCTAssertEqual(receipt.eligibility, .ineligible)
        XCTAssertEqual(receipt.completeness, "incomplete")
        XCTAssertNil(receipt.merkleDigest)
        XCTAssertNil(receipt.bindingDigest)
        XCTAssertTrue(receipt.ineligibilityReason?.contains("effect完全性") == true)
        guard case .ineligible(.bindingIncomplete) = receipt.cacheBinding else {
            return XCTFail("typed ineligible bindingではありません")
        }
        XCTAssertFalse(context.check.executable.isEmpty)
        XCTAssertFalse(context.check.arguments.isEmpty)
    }

    func testRestartedServicesReobserveSameCompleteClosure() async throws {
        let contract = ProjectProfileCheckInputContract.complete(provider: "fixture", providerVersion: "fixture-v1", includedRoots: ["Inputs"])
        let fixture = try ResolutionFixture(completeContract: contract, startsFSEvents: true)
        defer { fixture.cleanup() }
        try "stable\n".write(to: fixture.inputs.appendingPathComponent("stable.txt"), atomically: true, encoding: .utf8)
        let firstContext = try await fixture.context()
        let before = try await firstContext.resolver.resolve(firstContext.request)

        let restartedRuntime = WorkspaceStateRuntime(runtimeStore: fixture.store, startsFSEvents: true)
        let restartedProfiles = ProjectProfileService(runtimeStore: fixture.store, workspaceRuntime: restartedRuntime)
        await restartedProfiles.setInputContractForTests(ecosystem: "npm", kind: "test", contract: contract)
        let restartedResolver = RunCheckResolutionService(
            projectProfiles: restartedProfiles,
            workspaceRuntime: restartedRuntime
        )
        let after = try await restartedResolver.reobserve(before)

        XCTAssertEqual(after, before)
    }

    func testProviderVersionIsIndependentAndChangesBindingDigest() async throws {
        let observation = WorkspaceRelevantInputObservation(
            schemaVersion: "aishell.relevant-input-observation.v1",
            providerVersion: "direct-os-merkle-v1",
            projectRoot: "/fixture",
            projectRootIdentity: "1:2",
            workspaceCursor: "ws2:root:exclusion:generation:0",
            leafCount: 2,
            completeness: "complete",
            merkleDigest: String(repeating: "a", count: 64)
        )
        let first = RunCheckResolutionService.bindingDigest(
            observation: observation,
            projectID: "project",
            profileDigest: String(repeating: "b", count: 64),
            checkID: "check",
            provider: "fixture",
            providerVersion: "fixture-v1",
            contractVersion: "aishell.project-profile-check-input.v1"
        )
        let second = RunCheckResolutionService.bindingDigest(
            observation: observation,
            projectID: "project",
            profileDigest: String(repeating: "b", count: 64),
            checkID: "check",
            provider: "fixture",
            providerVersion: "fixture-v2",
            contractVersion: "aishell.project-profile-check-input.v1"
        )

        XCTAssertEqual(first.count, 64)
        XCTAssertEqual(second.count, 64)
        XCTAssertNotEqual(first, second)
    }

    func testExactProjectProfileAndCheckAreRequiredBeforeObservation() async throws {
        let fixture = try ResolutionFixture(completeContract: .complete(provider: "fixture", providerVersion: "fixture-v1", includedRoots: ["Inputs"]))
        defer { fixture.cleanup() }
        let context = try await fixture.context()
        let wrongProfile = RunCheckResolutionRequest(
            projectID: context.request.projectID,
            profileDigest: String(repeating: "f", count: 64),
            checkID: context.request.checkID
        )
        do {
            _ = try await context.resolver.resolve(wrongProfile)
            XCTFail("profile mismatchを受理しました")
        } catch {
            guard case ProjectProfileResolutionError.profileDigestChanged = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }
        let wrongCheck = RunCheckResolutionRequest(
            projectID: context.request.projectID,
            profileDigest: context.request.profileDigest,
            checkID: "unknown"
        )
        do {
            _ = try await context.resolver.resolve(wrongCheck)
            XCTFail("check mismatchを受理しました")
        } catch {
            guard case ProjectProfileResolutionError.checkNotFound("unknown") = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }
    }
}

private final class ResolutionFixture: @unchecked Sendable {
    struct Context {
        let resolver: RunCheckResolutionService
        let request: RunCheckResolutionRequest
        let check: ProjectProfileCheck
    }

    let base: URL
    let root: URL
    let inputs: URL
    let store: RuntimeStore
    let runtime: WorkspaceStateRuntime
    let profiles: ProjectProfileService
    let completeContract: ProjectProfileCheckInputContract?

    init(completeContract: ProjectProfileCheckInputContract?, startsFSEvents: Bool = false) throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIShellResolutionTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("workspace", isDirectory: true)
        inputs = root.appendingPathComponent("Inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let package: [String: Any] = [
            "name": "resolution-fixture",
            "scripts": ["test": "node --test"],
        ]
        try JSONSerialization.data(withJSONObject: package, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("package.json"), options: .atomic)
        store = RuntimeStore(baseDirectory: base.appendingPathComponent("runtime", isDirectory: true))
        runtime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: startsFSEvents)
        profiles = ProjectProfileService(runtimeStore: store, workspaceRuntime: runtime)
        self.completeContract = completeContract
    }

    func context() async throws -> Context {
        await store.setWorkingDirectoryForTesting(root)
        if let completeContract {
            await profiles.setInputContractForTests(ecosystem: "npm", kind: "test", contract: completeContract)
        }
        let snapshot = try await runtime.snapshot()
        let catalog = try await profiles.catalog(for: snapshot)
        let profile = try XCTUnwrap(catalog.profiles.first { $0.ecosystem == "npm" })
        let check = try XCTUnwrap(profile.checks.first { $0.kind == "test" })
        return Context(
            resolver: RunCheckResolutionService(projectProfiles: profiles, workspaceRuntime: runtime),
            request: RunCheckResolutionRequest(
                projectID: profile.projectId,
                profileDigest: profile.profileDigest,
                checkID: check.checkId
            ),
            check: check
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: base)
    }
}
