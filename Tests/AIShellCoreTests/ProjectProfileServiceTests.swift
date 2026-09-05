import CryptoKit
import XCTest
@testable import AIShellCore

final class ProjectProfileServiceTests: XCTestCase {
    func testNPMProfileKeepsStableIdsAndReturnsVerifiedWarmCacheHit() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        try writePackage(
            at: root,
            name: "root-package",
            scripts: ["build": "node build.mjs", "test": "node --test", "lint": "node --check src/index.mjs"]
        )
        let source = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "export const value = 1\n".write(to: source.appendingPathComponent("index.mjs"), atomically: true, encoding: .utf8)
        let service = try await makeService(root: root, fixture: fixture)

        let first = try await service.catalog(rootPath: root.path, observedCursor: cursor(1))
        let initial = try XCTUnwrap(first.profiles.first)
        XCTAssertEqual(initial.status, .complete)
        XCTAssertEqual(initial.freshness, .freshComputed)
        XCTAssertEqual(Set(initial.checks.map(\.kind)), ["build", "test", "lint"])
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: initial.checks.map { ($0.kind, $0.displayCommand) }),
            ["build": "npm run build", "test": "npm test", "lint": "npm run lint"]
        )
        XCTAssertEqual(Set(initial.toolchains.map(\.name)), ["node", "npm"])
        XCTAssertTrue(initial.checks.allSatisfy { $0.arguments.last == "--" })
        XCTAssertTrue(initial.targets.allSatisfy { $0.provenance.kind == "manifest" })

        let second = try await service.catalog(rootPath: root.path, observedCursor: cursor(2))
        let cached = try XCTUnwrap(second.profiles.first)
        XCTAssertEqual(cached.freshness, .freshCached)
        XCTAssertEqual(cached.observedCursor, cursor(2))
        XCTAssertEqual(cached.projectId, initial.projectId)
        XCTAssertEqual(cached.profileDigest, initial.profileDigest)
        XCTAssertEqual(cached.checks.map(\.checkId), initial.checks.map(\.checkId))
        let invocationCount = await service.providerInvocationCountForTests("npm")
        XCTAssertEqual(invocationCount, 1)

        let restarted = try await makeService(root: root, fixture: fixture)
        let restored = try await restarted.catalog(rootPath: root.path, observedCursor: cursor(3))
        XCTAssertEqual(restored.profiles.first?.freshness, .freshCached)
        XCTAssertEqual(restored.profiles.first?.profileDigest, initial.profileDigest)
        let restartedInvocationCount = await restarted.providerInvocationCountForTests("npm")
        XCTAssertEqual(restartedInvocationCount, 0)
    }

    func testManifestChangeInvalidatesOnlyOwningProfileWithOldAndNewSHA() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        let firstRoot = root.appendingPathComponent("first", isDirectory: true)
        let secondRoot = root.appendingPathComponent("second", isDirectory: true)
        try writePackage(at: firstRoot, name: "first", scripts: ["test": "node --test"])
        try writePackage(at: secondRoot, name: "second", scripts: ["test": "node --test"])
        let service = try await makeService(root: root, fixture: fixture)

        let initial = try await service.catalog(rootPath: root.path, observedCursor: cursor(1))
        let firstBefore = try profile(root: "first", in: initial)
        let secondBefore = try profile(root: "second", in: initial)
        try writePackage(at: firstRoot, name: "first", scripts: ["test": "node --test", "lint": "node --check index.mjs"])

        let updated = try await service.catalog(rootPath: root.path, observedCursor: cursor(2))
        let firstAfter = try profile(root: "first", in: updated)
        let secondAfter = try profile(root: "second", in: updated)
        XCTAssertEqual(firstAfter.projectId, firstBefore.projectId)
        XCTAssertNotEqual(firstAfter.profileDigest, firstBefore.profileDigest)
        XCTAssertEqual(firstAfter.freshness, .freshComputed)
        let reason = try XCTUnwrap(firstAfter.invalidationReasons.first { $0.kind == "binding_file_modified" })
        XCTAssertEqual(reason.path, "first/package.json")
        XCTAssertNotEqual(reason.oldSHA256, reason.newSHA256)
        XCTAssertEqual(secondAfter.freshness, .freshCached)
        XCTAssertEqual(secondAfter.profileDigest, secondBefore.profileDigest)
        let invocationCount = await service.providerInvocationCountForTests("npm")
        XCTAssertEqual(invocationCount, 3)
    }

    func testSourceContentAndREADMEReuseStructureButSourceCreationInvalidates() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        try writePackage(at: root, name: "sample", scripts: ["test": "node --test"])
        let sourceRoot = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("index.mjs")
        try "export const value = 1\n".write(to: source, atomically: true, encoding: .utf8)
        let service = try await makeService(root: root, fixture: fixture)
        _ = try await service.catalog(rootPath: root.path, observedCursor: cursor(1))

        try "export const value = 2\n".write(to: source, atomically: true, encoding: .utf8)
        try "notes\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let contentOnly = try await service.catalog(rootPath: root.path, observedCursor: cursor(2))
        XCTAssertEqual(contentOnly.profiles.first?.freshness, .freshCached)
        let contentInvocationCount = await service.providerInvocationCountForTests("npm")
        XCTAssertEqual(contentInvocationCount, 1)

        try "export const added = true\n".write(to: sourceRoot.appendingPathComponent("added.mjs"), atomically: true, encoding: .utf8)
        let structural = try await service.catalog(rootPath: root.path, observedCursor: cursor(3))
        XCTAssertEqual(structural.profiles.first?.freshness, .freshComputed)
        XCTAssertTrue(structural.profiles.first?.invalidationReasons.contains { $0.kind == "source_layout_changed" } == true)
        let structuralInvocationCount = await service.providerInvocationCountForTests("npm")
        XCTAssertEqual(structuralInvocationCount, 2)
    }

    func testInvalidManifestDoesNotHideValidSiblingOrPretendCompleteness() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        try writePackage(at: root.appendingPathComponent("valid"), name: "valid", scripts: ["test": "node --test"])
        let invalidRoot = root.appendingPathComponent("invalid", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidRoot, withIntermediateDirectories: true)
        try "{not-json\n".write(to: invalidRoot.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let service = try await makeService(root: root, fixture: fixture)

        let result = try await service.catalog(rootPath: root.path, observedCursor: cursor(1))
        XCTAssertEqual(try profile(root: "valid", in: result).status, .complete)
        let invalid = try profile(root: "invalid", in: result)
        XCTAssertEqual(invalid.status, .invalid)
        XCTAssertEqual(invalid.diagnostics.first?.code, "PROJECT_MANIFEST_INVALID")
        XCTAssertTrue(invalid.targets.isEmpty)
        XCTAssertTrue(invalid.checks.isEmpty)
        XCTAssertTrue(invalid.missingCapabilities.contains("targets"))
    }

    func testWorkspaceMembersMultipleEcosystemsAuxiliaryAndPartialAvailabilityStayVisible() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        try writePackage(
            at: root,
            name: "workspace",
            scripts: ["test": "node --test"],
            workspaces: ["packages/*"]
        )
        let member = root.appendingPathComponent("packages/member", isDirectory: true)
        try writePackage(at: member, name: "member", scripts: ["build": "node build.mjs"])
        try "[package]\nname = \"member-rust\"\nversion = \"0.1.0\"\n".write(
            to: member.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8
        )
        let auxiliary = root.appendingPathComponent("benchmarks/case", isDirectory: true)
        try FileManager.default.createDirectory(at: auxiliary, withIntermediateDirectories: true)
        try "module example.invalid/case\n".write(to: auxiliary.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        let service = try await makeService(root: root, fixture: fixture)

        let result = try await service.catalog(rootPath: root.path, observedCursor: cursor(1))
        XCTAssertEqual(result.profiles.count, 4)
        let npmRoot = try result.profiles.first { $0.ecosystem == "npm" && $0.projectRoot.isEmpty }.unwrapped()
        let npmMember = try result.profiles.first { $0.ecosystem == "npm" && $0.projectRoot == "packages/member" }.unwrapped()
        XCTAssertEqual(npmRoot.memberProjectIds, [npmMember.projectId])
        let cargo = try result.profiles.first { $0.ecosystem == "cargo" }.unwrapped()
        XCTAssertEqual(cargo.status, .partial)
        XCTAssertFalse(cargo.missingCapabilities.isEmpty)
        XCTAssertTrue(cargo.targets.isEmpty)
        let go = try result.profiles.first { $0.ecosystem == "go" }.unwrapped()
        XCTAssertEqual(go.classification, "auxiliary")
        XCTAssertEqual(go.status, .partial)

        let cached = try await service.catalog(rootPath: root.path, observedCursor: cursor(2))
        let cachedRoot = try cached.profiles.first { $0.projectId == npmRoot.projectId }.unwrapped()
        XCTAssertEqual(cachedRoot.profileDigest, npmRoot.profileDigest)
        try FileManager.default.removeItem(at: member.appendingPathComponent("package.json"))
        let removed = try await service.catalog(rootPath: root.path, observedCursor: cursor(3))
        let removedRoot = try removed.profiles.first { $0.projectId == npmRoot.projectId }.unwrapped()
        XCTAssertTrue(removedRoot.memberProjectIds.isEmpty)
        XCTAssertNotEqual(removedRoot.profileDigest, npmRoot.profileDigest)
        XCTAssertTrue(removedRoot.invalidationReasons.contains { $0.kind == "source_layout_changed" })
    }

    func testSwiftPMUsesDumpPackageForTargetsAndSeparatedStandardChecks() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "ProfileFixture",
            products: [.library(name: "ProfileFixture", targets: ["ProfileFixture"])],
            targets: [
                .target(name: "ProfileFixture"),
                .testTarget(name: "ProfileFixtureTests", dependencies: ["ProfileFixture"], resources: [.process("Fixtures")]),
            ]
        )
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let source = root.appendingPathComponent("Sources/ProfileFixture", isDirectory: true)
        let tests = root.appendingPathComponent("Tests/ProfileFixtureTests", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tests.appendingPathComponent("Fixtures"), withIntermediateDirectories: true)
        try "public struct Value {}\n".write(to: source.appendingPathComponent("Value.swift"), atomically: true, encoding: .utf8)
        try "import Testing\n@Test func value() {}\n".write(to: tests.appendingPathComponent("ValueTests.swift"), atomically: true, encoding: .utf8)
        try "fixture\n".write(to: tests.appendingPathComponent("Fixtures/value.txt"), atomically: true, encoding: .utf8)
        let service = try await makeService(root: root, fixture: fixture)

        let result = try await service.catalog(rootPath: root.path, observedCursor: cursor(1))
        let profile = try result.profiles.first { $0.ecosystem == "swiftpm" }.unwrapped()
        XCTAssertEqual(profile.status, .complete)
        XCTAssertEqual(Set(profile.targets.map(\.name)), ["ProfileFixture", "ProfileFixtureTests"])
        XCTAssertEqual(Set(profile.checks.map(\.kind)), ["build", "test"])
        XCTAssertEqual(Set(profile.checks.map(\.displayCommand)), ["swift build", "swift test"])
        XCTAssertTrue(profile.checks.allSatisfy { !$0.executable.contains(" ") && $0.arguments.count == 1 })
        XCTAssertEqual(profile.toolchains.map(\.name), ["swift"])
        XCTAssertTrue(profile.toolchains.allSatisfy { !$0.evidenceSHA256.isEmpty && $0.exitStatus == 0 })
        let testTarget = try profile.targets.first { $0.name == "ProfileFixtureTests" }.unwrapped()
        XCTAssertEqual(testTarget.dependencies, ["ProfileFixture"])
        XCTAssertEqual(testTarget.sourceRoots, ["Tests/ProfileFixtureTests"])
        XCTAssertEqual(testTarget.resourceRoots, ["Tests/ProfileFixtureTests/Fixtures"])
        XCTAssertTrue(profile.toolchains.allSatisfy { $0.evidenceHandle.hasPrefix("art_") })
        let providerEvidence = try profile.providerEvidence.unwrapped()
        XCTAssertTrue(providerEvidence.handle.hasPrefix("art_"))
        let evidenceStore = EvidenceStore(
            baseDirectory: fixture.base.appendingPathComponent("runtime/evidence", isDirectory: true)
        )
        for evidence in profile.toolchains.map({ ($0.evidenceHandle, $0.evidenceSHA256) })
            + [(providerEvidence.handle, providerEvidence.sha256)] {
            let slice = try await evidenceStore.read(
                handle: evidence.0, mode: .range(offset: 0, length: EvidenceStore.maximumReadBytes),
                byteBudget: EvidenceStore.maximumReadBytes
            )
            let bytes = try artifactBytes(slice)
            XCTAssertEqual(SHA256.hash(data: bytes).hex, evidence.1)
        }
        XCTAssertTrue(profile.diagnostics.isEmpty)
    }

    func testSwiftPMNonzeroProviderEvidenceRemainsReadable() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        try Data("// swift-tools-version: 6.0\nthis is invalid swift\n".utf8)
            .write(to: root.appendingPathComponent("Package.swift"))
        let service = try await makeService(root: root, fixture: fixture)

        let result = try await service.catalog(rootPath: root.path, observedCursor: cursor(1))
        let profile = try result.profiles.first { $0.ecosystem == "swiftpm" }.unwrapped()
        XCTAssertEqual(profile.status, .partial)
        let diagnostic = try profile.diagnostics.first.unwrapped()
        XCTAssertEqual(diagnostic.code, "PROJECT_PROVIDER_FAILED")
        let evidence = try diagnostic.evidence.unwrapped()
        XCTAssertNotEqual(evidence.exitStatus, 0)
        let store = EvidenceStore(
            baseDirectory: fixture.base.appendingPathComponent("runtime/evidence", isDirectory: true)
        )
        let slice = try await store.read(
            handle: evidence.handle, mode: .range(offset: 0, length: EvidenceStore.maximumReadBytes),
            byteBudget: EvidenceStore.maximumReadBytes
        )
        let bytes = try artifactBytes(slice)
        XCTAssertEqual(SHA256.hash(data: bytes).hex, evidence.sha256)
        XCTAssertEqual(bytes.suffix(4), withUnsafeBytes(of: evidence.exitStatus.bigEndian) { Data($0) })
    }

    func testCursorContinuityAndGenerationAreVerifiedBeforeCacheReuse() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        try writePackage(at: root, name: "sample", scripts: ["test": "node --test"])
        let service = try await makeService(root: root, fixture: fixture)
        _ = try await service.catalog(rootPath: root.path, observedCursor: cursor(4))

        do {
            _ = try await service.catalog(rootPath: root.path, observedCursor: "malformed")
            XCTFail("不正cursorを受理しました。")
        } catch {
            guard case AIShellError.cursorExpired = error else { return XCTFail("想定外のエラー: \(error)") }
        }
        do {
            _ = try await service.catalog(rootPath: root.path, observedCursor: cursor(3))
            XCTFail("sequence巻戻しを受理しました。")
        } catch {
            guard case AIShellError.cursorExpired = error else { return XCTFail("想定外のエラー: \(error)") }
        }
        let regenerated = try await service.catalog(rootPath: root.path, observedCursor: cursor(1, generation: "next"))
        XCTAssertEqual(regenerated.profiles.first?.freshness, .freshComputed)
        XCTAssertEqual(regenerated.profiles.first?.invalidationReasons.first?.kind, "workspace_generation_changed")
    }

    func testPublicSnapshotEntryReattestsCursorThroughWorkspaceRuntime() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        try writePackage(at: root, name: "sample", scripts: [:])
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime", isDirectory: true))
        await store.setWorkingDirectoryForTesting(root)
        let runtime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        let snapshot = try await runtime.snapshot(path: root.path)
        let service = ProjectProfileService(runtimeStore: store, workspaceRuntime: runtime)

        let result = try await service.catalog(for: snapshot)
        XCTAssertEqual(result.observedCursor, snapshot.cursor)
        XCTAssertEqual(result.profiles.first?.status, .complete)
    }

    func testPublicSnapshotEntryAttestsFromCachedProfileCursor() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        try writePackage(at: root, name: "sample", scripts: [:])
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime", isDirectory: true))
        await store.setWorkingDirectoryForTesting(root)
        let runtime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false, journalLimit: 1)
        let first = try await runtime.snapshot(path: root.path)
        let service = ProjectProfileService(runtimeStore: store, workspaceRuntime: runtime)
        _ = try await service.catalog(for: first)

        let source = root.appendingPathComponent("src.mjs")
        try Data("one".utf8).write(to: source)
        _ = try await runtime.appendKnownMutation(
            transactionID: "one", rootPath: root.path,
            changes: [.init(kind: .created, path: "src.mjs")]
        )
        let second = try await runtime.snapshot(path: root.path, sinceCursor: first.cursor)
        try Data("two".utf8).write(to: source)
        _ = try await runtime.appendKnownMutation(
            transactionID: "two", rootPath: root.path,
            changes: [.init(kind: .modified, path: "src.mjs")]
        )
        let latest = try await runtime.snapshot(path: root.path, sinceCursor: second.cursor)

        do {
            _ = try await service.catalog(for: latest)
            XCTFail("retention外のprofile cursorをfresh cacheとして再利用しました。")
        } catch {
            guard case AIShellError.cursorExpired = error else { return XCTFail("想定外のエラー: \(error)") }
        }
    }

    func testSameBytesAtomicManifestReplacementInvalidatesFileIdentity() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        try writePackage(at: root, name: "sample", scripts: ["test": "node --test"])
        let manifest = root.appendingPathComponent("package.json")
        let service = try await makeService(root: root, fixture: fixture)
        let before = try await service.catalog(rootPath: root.path, observedCursor: cursor(1))
        let bytes = try Data(contentsOf: manifest)
        try bytes.write(to: manifest, options: .atomic)

        let after = try await service.catalog(rootPath: root.path, observedCursor: cursor(2))
        XCTAssertNotEqual(before.profiles.first?.manifests.first?.identity, after.profiles.first?.manifests.first?.identity)
        XCTAssertTrue(after.profiles.first?.invalidationReasons.contains { $0.kind == "binding_file_identity_changed" } == true)
    }

    func testInvalidNPMWorkspaceLockAndDuplicateOwnershipHaveTypedDiagnostics() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        try writePackage(at: root, name: "root", scripts: [:], workspaces: ["packages/**"])
        let parent = root.appendingPathComponent("packages", isDirectory: true)
        try writePackage(at: parent, name: "parent", scripts: [:], workspaces: ["member"])
        try writePackage(at: parent.appendingPathComponent("member"), name: "member", scripts: [:])
        let escaped = root.appendingPathComponent("escaped", isDirectory: true)
        try writePackage(at: escaped, name: "escaped", scripts: [:], workspaces: ["../outside"])
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try writePackage(at: locked, name: "locked", scripts: [:])
        try Data("not-json".utf8).write(to: locked.appendingPathComponent("package-lock.json"))
        let service = try await makeService(root: root, fixture: fixture)

        let result = try await service.catalog(rootPath: root.path, observedCursor: cursor(1))
        XCTAssertEqual(try profile(root: "escaped", in: result).diagnostics.first?.code, "PROJECT_MEMBER_OUTSIDE_WORKSPACE")
        let lockedProfile = try profile(root: "locked", in: result)
        XCTAssertEqual(lockedProfile.diagnostics.first?.code, "PROJECT_MANIFEST_INVALID")
        XCTAssertEqual(lockedProfile.diagnostics.first?.path, "locked/package-lock.json")
        XCTAssertEqual(try profile(root: "", in: result).diagnostics.first?.code, "PROJECT_MEMBER_DUPLICATE_OWNER")
        XCTAssertEqual(try profile(root: "packages", in: result).diagnostics.first?.code, "PROJECT_MEMBER_DUPLICATE_OWNER")

        try writePackage(at: root, name: "root", scripts: [:], workspaces: ["other/*"])
        let resolved = try await service.catalog(rootPath: root.path, observedCursor: cursor(2))
        XCTAssertEqual(try profile(root: "", in: resolved).status, .complete)
        XCTAssertEqual(try profile(root: "packages", in: resolved).status, .complete)
    }

    func testWildcardWorkspaceSymlinkEscapeHasTypedDiagnostic() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        try writePackage(at: root, name: "root", scripts: [:], workspaces: ["packages/*"])
        let packages = root.appendingPathComponent("packages", isDirectory: true)
        let outside = fixture.base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: true)
        try writePackage(at: outside, name: "outside", scripts: [:])
        try FileManager.default.createSymbolicLink(
            at: packages.appendingPathComponent("outside"), withDestinationURL: outside
        )
        let service = try await makeService(root: root, fixture: fixture)

        let result = try await service.catalog(rootPath: root.path, observedCursor: cursor(1))
        let profile = try profile(root: "", in: result)
        XCTAssertEqual(profile.status, .invalid)
        XCTAssertEqual(profile.diagnostics.first?.code, "PROJECT_MEMBER_OUTSIDE_WORKSPACE")
    }

    func testWorkspaceSymlinkValidationStillExcludesNodeModules() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        try writePackage(at: root, name: "root", scripts: [:], workspaces: ["**"])
        let nodeModules = root.appendingPathComponent("node_modules", isDirectory: true)
        let outside = fixture.base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try writePackage(at: outside, name: "outside", scripts: [:])
        try FileManager.default.createSymbolicLink(
            at: nodeModules.appendingPathComponent("linked"), withDestinationURL: outside
        )
        let service = try await makeService(root: root, fixture: fixture)

        let result = try await service.catalog(rootPath: root.path, observedCursor: cursor(1))
        XCTAssertEqual(try profile(root: "", in: result).status, .complete)
    }

    func testExpiredToolchainEvidenceCannotProduceWarmCacheHit() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        try writePackage(at: root, name: "sample", scripts: [:])
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime", isDirectory: true))
        await store.setWorkingDirectoryForTesting(root)
        let service = ProjectProfileService(runtimeStore: store, evidenceRetention: 1)
        _ = try await service.catalog(rootPath: root.path, observedCursor: cursor(1))
        try await Task.sleep(for: .milliseconds(1_100))

        let second = try await service.catalog(rootPath: root.path, observedCursor: cursor(2))
        XCTAssertEqual(second.profiles.first?.freshness, .freshComputed)
        let count = await service.providerInvocationCountForTests("npm")
        XCTAssertEqual(count, 2)
    }

    func testReservedTransactionNamespaceIsNeverDiscovered() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        try writePackage(at: root, name: "visible", scripts: [:])
        try writePackage(at: root.appendingPathComponent(".aishell-transactions/staged"), name: "hidden", scripts: [:])
        let service = try await makeService(root: root, fixture: fixture)

        let result = try await service.catalog(rootPath: root.path, observedCursor: cursor(1))
        XCTAssertEqual(result.profiles.filter { $0.ecosystem == "npm" }.map(\.projectRoot), [""])
    }

    func testCorruptPersistentCacheFailsClosedInsteadOfReturningStaleProfile() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        try writePackage(at: root, name: "sample", scripts: ["test": "node --test"])
        let service = try await makeService(root: root, fixture: fixture)
        _ = try await service.catalog(rootPath: root.path, observedCursor: cursor(1))
        let cache = fixture.base.appendingPathComponent("runtime/project-profile-cache-v1.json")
        try Data("{corrupt".utf8).write(to: cache, options: .atomic)

        let restarted = try await makeService(root: root, fixture: fixture)
        do {
            _ = try await restarted.catalog(rootPath: root.path, observedCursor: cursor(2))
            XCTFail("破損cacheを黙って再scan又はstale profileへfallbackしました。")
        } catch {
            guard case AIShellError.checkpointCorrupt = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }
    }

    func testResolveExactCheckReattestsCatalogAndRejectsProfileOrCheckMismatch() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        try writePackage(at: root, name: "sample", scripts: ["test": "node --test"])
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime", isDirectory: true))
        await store.setWorkingDirectoryForTesting(root)
        let runtime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        let service = ProjectProfileService(runtimeStore: store, workspaceRuntime: runtime)
        let snapshot = try await runtime.snapshot()
        let catalog = try await service.catalog(for: snapshot)
        let profile = try XCTUnwrap(catalog.profiles.first)
        let check = try XCTUnwrap(profile.checks.first)

        let resolved = try await service.resolveExactCheck(
            projectID: profile.projectId,
            profileDigest: profile.profileDigest,
            checkID: check.checkId
        )
        XCTAssertEqual(resolved.profile.projectId, profile.projectId)
        XCTAssertEqual(resolved.check.checkId, check.checkId)
        XCTAssertEqual(
            (resolved.catalogRoot as NSString).resolvingSymlinksInPath,
            (root.path as NSString).resolvingSymlinksInPath
        )
        let profileResolution = try await service.resolveExactProfile(profileDigest: profile.profileDigest)
        XCTAssertEqual(profileResolution.profile.profileDigest, profile.profileDigest)
        XCTAssertEqual(profileResolution.profile.projectId, profile.projectId)
        XCTAssertEqual(profileResolution.catalogRoot, resolved.catalogRoot)

        do {
            _ = try await service.resolveExactProfile(profileDigest: String(repeating: "0", count: 64))
            XCTFail("unknown profile digestを受理しました")
        } catch {
            guard case ProjectProfileResolutionError.profileDigestNotFound = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }
        do {
            _ = try ProjectProfileService.selectExactProfile(
                profileDigest: profile.profileDigest,
                catalogs: [catalog, catalog]
            )
            XCTFail("duplicate profile digestを曖昧でないものとして受理しました")
        } catch {
            guard case ProjectProfileResolutionError.profileDigestAmbiguous(let digest) = error,
                  digest == profile.profileDigest else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }

        do {
            _ = try await service.resolveExactCheck(
                projectID: profile.projectId,
                profileDigest: String(repeating: "0", count: 64),
                checkID: check.checkId
            )
            XCTFail("profile digest mismatchを受理しました")
        } catch {
            guard case ProjectProfileResolutionError.profileDigestChanged = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }
        do {
            _ = try await service.resolveExactCheck(
                projectID: profile.projectId,
                profileDigest: profile.profileDigest,
                checkID: "missing-check"
            )
            XCTFail("unknown checkを受理しました")
        } catch {
            guard case ProjectProfileResolutionError.checkNotFound("missing-check") = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }

        // cacheに残る旧profileをauthorityにせず、rootからfresh catalogを作り直す。
        try FileManager.default.removeItem(at: root.appendingPathComponent("package.json"))
        do {
            _ = try await service.resolveExactCheck(
                projectID: profile.projectId,
                profileDigest: profile.profileDigest,
                checkID: check.checkId
            )
            XCTFail("消滅済みprojectをcacheから解決しました")
        } catch {
            guard case ProjectProfileResolutionError.projectNotFound(let id) = error,
                  id == profile.projectId else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }
    }

    func testProductionProvidersKeepExecutionButDeclareRelevantInputEffectsIneligible() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        try writePackage(at: root, name: "sample", scripts: ["test": "node --test"])
        let service = try await makeService(root: root, fixture: fixture)
        let result = try await service.catalog(rootPath: root.path, observedCursor: cursor(1))
        let check = try XCTUnwrap(result.profiles.first?.checks.first)

        XCTAssertFalse(check.executable.isEmpty)
        XCTAssertEqual(check.inputContract.completeness, .ineligible)
        XCTAssertEqual(check.inputContract.effectCompleteness, .unprovenExternalEffects)
        XCTAssertEqual(check.inputContract.provider, "npm")
        XCTAssertTrue(check.inputContract.reason?.contains("effect完全性") == true)
    }

    func testNPMManifestCanDeclareClosedDirectCheckAndRelevantInputs() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "export const value = 1\n".write(
            to: root.appendingPathComponent("src/value.mjs"), atomically: true, encoding: .utf8
        )
        try "import './src/value.mjs'\n".write(
            to: root.appendingPathComponent("check.mjs"), atomically: true, encoding: .utf8
        )
        try writeDeclaredPackage(at: root, includedRoots: ["src/value.mjs", "check.mjs"])
        let service = try await makeService(root: root, fixture: fixture)

        let result = try await service.catalog(rootPath: root.path, observedCursor: cursor(1))
        let check = try XCTUnwrap(result.profiles.first?.checks.first)
        XCTAssertEqual(check.kind, "test")
        XCTAssertEqual(URL(fileURLWithPath: check.executable).lastPathComponent, "node")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: check.executable))
        XCTAssertEqual(check.arguments, ["check.mjs"])
        XCTAssertEqual(check.environmentKeys, ["MODE"])
        XCTAssertEqual(check.inputContract.completeness, .complete)
        XCTAssertEqual(check.inputContract.effectCompleteness, .projectRootClosed)
        XCTAssertEqual(check.inputContract.provider, "npm-manifest")
        XCTAssertEqual(check.inputContract.includedRoots, ["check.mjs", "src/value.mjs"])
        XCTAssertTrue(check.inputContract.trackedPaths.isEmpty)
        XCTAssertNil(check.inputContract.reason)
    }

    func testNPMManifestRejectsEscapingClosedInputDeclaration() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        try writeDeclaredPackage(at: root, includedRoots: ["../outside"])
        let service = try await makeService(root: root, fixture: fixture)

        let result = try await service.catalog(rootPath: root.path, observedCursor: cursor(1))
        let profile = try XCTUnwrap(result.profiles.first)
        XCTAssertEqual(profile.status, .invalid)
        XCTAssertTrue(profile.checks.isEmpty)
        XCTAssertEqual(profile.diagnostics.first?.code, "PROJECT_MANIFEST_INVALID")
    }

    func testNPMManifestRejectsShellExecutableNULAndInvalidEnvironmentKeys() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        try writeDeclaredPackage(
            at: root.appendingPathComponent("npm"), includedRoots: ["check.mjs"], executable: "npm"
        )
        try writeDeclaredPackage(
            at: root.appendingPathComponent("nul"), includedRoots: ["bad\0path"]
        )
        try writeDeclaredPackage(
            at: root.appendingPathComponent("environment"), includedRoots: ["check.mjs"],
            environmentKeys: ["BAD=KEY"]
        )
        let service = try await makeService(root: root, fixture: fixture)

        let result = try await service.catalog(rootPath: root.path, observedCursor: cursor(1))
        XCTAssertEqual(result.profiles.count, 3)
        XCTAssertTrue(result.profiles.allSatisfy { profile in
            profile.status == .invalid && profile.checks.isEmpty
                && profile.diagnostics.first?.code == "PROJECT_MANIFEST_INVALID"
        })
    }

    func testDeclaredEnvironmentValueInvalidatesProfileBinding() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        try writeDeclaredPackage(at: root, includedRoots: ["check.mjs"])
        let previous = getenv("MODE").map { String(cString: $0) }
        defer {
            if let previous { setenv("MODE", previous, 1) }
            else { unsetenv("MODE") }
        }
        setenv("MODE", "first", 1)
        let service = try await makeService(root: root, fixture: fixture)
        let first = try await service.catalog(rootPath: root.path, observedCursor: cursor(1))
        let before = try XCTUnwrap(first.profiles.first)

        setenv("MODE", "second", 1)
        let second = try await service.catalog(rootPath: root.path, observedCursor: cursor(2))
        let after = try XCTUnwrap(second.profiles.first)

        XCTAssertEqual(after.freshness, .freshComputed)
        XCTAssertNotEqual(after.profileDigest, before.profileDigest)
        XCTAssertTrue(after.invalidationReasons.contains { $0.kind == "provider_or_environment_changed" })
    }

    func testGitDiscoveryExcludesIgnoredManifests() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = try workspace(in: fixture)
        try writePackage(at: root, name: "root", scripts: [:], workspaces: ["packages/*"])
        try writePackage(
            at: root.appendingPathComponent("packages/member", isDirectory: true),
            name: "member",
            scripts: [:]
        )
        try writePackage(
            at: root.appendingPathComponent("generated/ignored", isDirectory: true),
            name: "ignored",
            scripts: [:]
        )
        try "generated/\n".write(
            to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8
        )
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", root.path, "init", "--quiet"]
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        try git.run()
        git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0)
        let service = try await makeService(root: root, fixture: fixture)

        let result = try await service.catalog(rootPath: root.path, observedCursor: cursor(1))

        XCTAssertEqual(result.profiles.map(\.projectRoot).sorted(), ["", "packages/member"])
        XCTAssertFalse(result.profiles.contains { $0.projectRoot.hasPrefix("generated/") })
    }

    private func workspace(in fixture: TemporaryFixture) throws -> URL {
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func cursor(_ sequence: UInt64, generation: String = "generation") -> String {
        "ws2:\(String(repeating: "a", count: 64)):\(String(repeating: "b", count: 64)):\(generation):\(sequence)"
    }

    private func artifactBytes(_ slice: ArtifactSlice) throws -> Data {
        if let text = slice.text { return Data(text.utf8) }
        guard let base64 = slice.base64, let data = Data(base64Encoded: base64) else {
            throw NSError(domain: "ProjectProfileServiceTests", code: 2)
        }
        return data
    }

    private func makeService(root: URL, fixture: TemporaryFixture) async throws -> ProjectProfileService {
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime", isDirectory: true))
        await store.setWorkingDirectoryForTesting(root)
        return ProjectProfileService(runtimeStore: store)
    }

    private func writePackage(
        at root: URL,
        name: String,
        scripts: [String: String],
        workspaces: [String]? = nil
    ) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var object: [String: Any] = ["name": name, "scripts": scripts]
        if let workspaces { object["workspaces"] = workspaces }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("package.json"), options: .atomic)
    }

    private func writeDeclaredPackage(
        at root: URL,
        includedRoots: [String],
        executable: String = "node",
        environmentKeys: [String] = ["MODE"]
    ) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let object: [String: Any] = [
            "name": "declared-package",
            "aishell": [
                "schemaVersion": "aishell.package-profile.v1",
                "checks": [
                    "test": [
                        "executable": executable,
                        "arguments": ["check.mjs"],
                        "environmentKeys": environmentKeys,
                        "includedRoots": includedRoots,
                        "trackedPaths": [],
                        "effects": "project_root_closed",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("package.json"), options: .atomic)
    }

    private func profile(root: String, in result: ProjectProfileCatalogResult) throws -> ProjectProfile {
        try result.profiles.first { $0.projectRoot == root && $0.ecosystem == "npm" }.unwrapped()
    }
}

private extension Optional {
    func unwrapped(file: StaticString = #filePath, line: UInt = #line) throws -> Wrapped {
        guard let self else {
            XCTFail("期待した値がありません。", file: file, line: line)
            throw NSError(domain: "ProjectProfileServiceTests", code: 1)
        }
        return self
    }
}

private extension SHA256.Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
