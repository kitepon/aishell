import XCTest
@testable import AIShellCore

final class ContextCompilerServiceTests: XCTestCase {
    func testFairContinuationReassemblesFilesAndBindsCompletedTargets() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let contents = ["small.txt": "ok\n", "large.txt": String(repeating: "日本語\n", count: 20)]
        for (path, text) in contents { try text.write(to: root.appendingPathComponent(path), atomically: false, encoding: .utf8) }
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("state"))
        await store.setWorkingDirectoryForTesting(root)
        let service = ContextCompilerService(runtimeStore: store)
        let paths = ["small.txt", "large.txt"]
        let first = try await service.readContext(targets: paths, byteBudget: 30)
        var received = Dictionary(uniqueKeysWithValues: first.chunks.map { ($0.path, $0.text) })
        var continuation = first.continuation
        while let token = continuation {
            let page = try await service.readContext(targets: paths, byteBudget: 30, continuation: token)
            XCTAssertLessThanOrEqual(page.returnedBytes, 30)
            for chunk in page.chunks { received[chunk.path, default: ""] += chunk.text }
            continuation = page.continuation
        }
        XCTAssertEqual(received, contents)
        try "changed\n".write(to: root.appendingPathComponent("small.txt"), atomically: false, encoding: .utf8)
        do {
            _ = try await service.readContext(targets: paths, byteBudget: 30, continuation: first.continuation)
            XCTFail("完了済み対象の変更も同じ読取りの継続では拒否する")
        } catch let error as AIShellError {
            guard case .contentChanged = error else { return XCTFail("予期しないエラー: \(error)") }
        }
    }

    func testWorkspaceGitDiffContinuationSurvivesUnchangedSnapshotGeneration() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.runGit(["init"], at: root)
        try Self.runGit(["config", "user.email", "fixture@example.invalid"], at: root)
        try Self.runGit(["config", "user.name", "Fixture"], at: root)
        let source = root.appendingPathComponent("Source.swift")
        try "let value = 1\n".write(to: source, atomically: false, encoding: .utf8)
        try Self.runGit(["add", "Source.swift"], at: root)
        try Self.runGit(["commit", "-m", "fixture"], at: root)
        try "let value = 2\n".write(to: source, atomically: false, encoding: .utf8)
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(root)
        let runtime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        let service = ContextCompilerService(runtimeStore: store, workspaceRuntime: runtime)

        let first = try await service.workspaceSnapshot(
            path: root.path,
            contextBudget: 0,
            gitDiffRequest: GitDiffContextRequest(byteBudget: 1, includePatch: false)
        )
        let continuation = try XCTUnwrap(first.gitDiff?.continuation)
        let second = try await service.workspaceSnapshot(
            path: root.path,
            contextBudget: 0,
            gitDiffRequest: GitDiffContextRequest(byteBudget: 600, continuation: continuation)
        )

        XCTAssertNotEqual(first.cursor, second.cursor)
        XCTAssertEqual(second.gitDiff?.changes.map(\.path), ["Source.swift"])
        XCTAssertFalse(second.gitDiff?.hasMore ?? true)
    }

    func testWorkspaceV2IntegratesGitDiffAndProjectProfilesWithoutRemovingV1Fields() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.runGit(["init"], at: root)
        try Self.runGit(["config", "user.email", "fixture@example.invalid"], at: root)
        try Self.runGit(["config", "user.name", "Fixture"], at: root)
        let source = root.appendingPathComponent("Source.swift")
        try "let value = 1\n".write(to: source, atomically: false, encoding: .utf8)
        try "[package]\nname = \"fixture\"\nversion = \"0.1.0\"\n".write(
            to: root.appendingPathComponent("Cargo.toml"), atomically: false, encoding: .utf8
        )
        try Self.runGit(["add", "Source.swift", "Cargo.toml"], at: root)
        try Self.runGit(["commit", "-m", "fixture"], at: root)
        try "let value = 2\n".write(to: source, atomically: false, encoding: .utf8)
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(root)
        let runtime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        let service = ContextCompilerService(runtimeStore: store, workspaceRuntime: runtime)

        let result = try await service.workspaceSnapshot(
            path: root.path,
            gitDiffRequest: GitDiffContextRequest(byteBudget: 65_536),
            projectProfileRequest: ProjectProfileProjectionRequest(mode: .all)
        )

        XCTAssertEqual(result.schemaVersion, "aishell.workspace-snapshot.v2")
        XCTAssertEqual(result.gitStatusState, "dirty")
        XCTAssertEqual(result.gitDiff?.comparisonMode, .worktree)
        XCTAssertEqual(result.gitDiff?.dirtyState, "dirty")
        XCTAssertFalse(result.gitDiff?.repositoryIdentity.isEmpty ?? true)
        XCTAssertNotNil(result.gitDiff?.headBranch)
        XCTAssertTrue(result.manifests.contains("Cargo.toml"))
        XCTAssertTrue(result.gitDiff?.changes.contains {
            $0.layer == .unstaged && $0.path == "Source.swift" && $0.kind == .modified
        } == true)
        let profiles = result.projectProfiles?.compactMap { item -> ProjectProfile? in
            guard case let .profile(profile) = item else { return nil }
            return profile
        }
        XCTAssertEqual(profiles?.first(where: { $0.ecosystem == "cargo" })?.status, .partial)
        XCTAssertEqual(result.projectProfileSummary?.totalProfiles, 1)
    }

    func testWorkspaceV2UsesInjectedProjectProfileService() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "[package]\nname = \"fixture\"\nversion = \"0.1.0\"\n".write(
            to: root.appendingPathComponent("Cargo.toml"), atomically: false, encoding: .utf8
        )
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(root)
        let runtime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        let profiles = ProjectProfileService(
            runtimeStore: store,
            workspaceRuntime: runtime,
            providerVersion: "injected"
        )
        let service = ContextCompilerService(
            runtimeStore: store,
            workspaceRuntime: runtime,
            projectProfileService: profiles
        )

        let result = try await service.workspaceSnapshot(
            path: root.path,
            projectProfileRequest: ProjectProfileProjectionRequest(mode: .all)
        )
        let profile = try XCTUnwrap(result.projectProfiles?.compactMap { item -> ProjectProfile? in
            guard case let .profile(profile) = item else { return nil }
            return profile
        }.first)

        XCTAssertEqual(profile.providerVersion, "injected")
    }

    func testProjectProfileProjectionPagesRetainSnapshotAndAdvanceOpaqueContinuation() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "[package]\nname = \"root\"\nversion = \"0.1.0\"\n".write(
            to: root.appendingPathComponent("Cargo.toml"), atomically: false, encoding: .utf8
        )
        try "[package]\nname = \"nested\"\nversion = \"0.1.0\"\n".write(
            to: nested.appendingPathComponent("Cargo.toml"), atomically: false, encoding: .utf8
        )
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(root)
        let runtime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        let service = ContextCompilerService(runtimeStore: store, workspaceRuntime: runtime)

        let automatic = try await service.workspaceSnapshot(
            path: root.path,
            projectProfileRequest: ProjectProfileProjectionRequest(mode: .auto)
        )
        let automaticProfiles = automatic.projectProfiles?.compactMap { item -> ProjectProfile? in
            guard case let .profile(profile) = item else { return nil }
            return profile
        }
        XCTAssertEqual(automaticProfiles?.map(\.projectRoot), [""])

        let first = try await service.workspaceSnapshot(
            path: root.path,
            projectProfileRequest: ProjectProfileProjectionRequest(
                mode: .all, byteBudget: 262_144, profileLimit: 1
            )
        )
        let continuation = try XCTUnwrap(first.projectProfileContinuation)
        XCTAssertEqual(first.projectProfiles?.count, 1)
        XCTAssertEqual(first.projectProfileHasMore, true)
        XCTAssertEqual(first.projectProfileSummary?.returnedProfiles, 1)

        let second = try await service.workspaceSnapshot(
            path: root.path,
            projectProfileRequest: ProjectProfileProjectionRequest(
                byteBudget: 262_144, profileLimit: 1, continuation: continuation
            )
        )
        XCTAssertEqual(second.cursor, first.cursor)
        XCTAssertEqual(second.projectProfiles?.count, 1)
        XCTAssertEqual(second.projectProfileHasMore, false)
        XCTAssertNil(second.projectProfileContinuation)
        XCTAssertNotEqual(second.projectProfiles, first.projectProfiles)
    }

    func testOversizedProjectProfileBecomesBoundedLosslessArtifactDescriptor() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let targets = (0..<48).map { ".target(name: \"Target\($0)\")" }.joined(separator: ",\n")
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Oversized", targets: [
        \(targets)
        ])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: false, encoding: .utf8)
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(root)
        let runtime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        let evidence = EvidenceStore(baseDirectory: fixture.base.appendingPathComponent("evidence"))
        let service = ContextCompilerService(
            runtimeStore: store, workspaceRuntime: runtime, evidenceStore: evidence
        )

        let result = try await service.workspaceSnapshot(
            path: root.path,
            projectProfileRequest: ProjectProfileProjectionRequest(
                mode: .all, byteBudget: 1_024, profileLimit: 1
            )
        )
        let item = try XCTUnwrap(result.projectProfiles?.first)
        guard case let .oversized(descriptor) = item else {
            return XCTFail("budget超profileをinlineで返しました。")
        }
        XCTAssertGreaterThan(descriptor.requiredBytes, 1_024)
        XCTAssertLessThanOrEqual(result.projectProfileSummary?.returnedBytes ?? .max, 1_024)
        XCTAssertEqual(descriptor.sha256, descriptor.artifact.sha256)
        let recovered = try await evidence.read(
            handle: descriptor.artifact.handle,
            mode: .range(offset: 0, length: descriptor.artifact.sizeBytes),
            byteBudget: descriptor.artifact.sizeBytes
        )
        XCTAssertEqual(recovered.returnedBytes, descriptor.artifact.sizeBytes)
        XCTAssertEqual(recovered.sha256, descriptor.sha256)
        XCTAssertEqual(result.projectProfileHasMore, false)
        XCTAssertNil(result.projectProfileContinuation)
    }

    func testV2SearchUsesRetainedObservationAndDedicatedService() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("Find.swift")
        try "old value\n".write(to: file, atomically: false, encoding: .utf8)
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(root)
        let runtime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        let initial = try await runtime.snapshot()
        try "needle value\n".write(to: file, atomically: false, encoding: .utf8)
        await runtime.ingestObservedPaths([file.path])
        let service = ContextCompilerService(runtimeStore: store, workspaceRuntime: runtime)

        let result = try await service.searchContextV2(request: SearchContextRequestV2(
            path: root.path,
            queries: [SearchContextQueryV2(id: "q0", kind: .fixed, pattern: "needle")],
            ranking: [.changed],
            changedSinceCursor: initial.cursor,
            maxResults: 10,
            byteBudget: 65_536
        ))

        XCTAssertEqual(result.schema, "aishell.search-context.v2")
        XCTAssertEqual(result.matches.map(\.path), ["Find.swift"])
        XCTAssertEqual(result.matches.first?.queryIDs, ["q0"])
        XCTAssertEqual(result.rankingEvidence.fromCursor, initial.cursor)
        XCTAssertEqual(result.freshness.state, "fresh")
    }

    func testReadContextSharesOneBudgetAndContinuesExplicitly() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "first file content\n".write(
            to: root.appendingPathComponent("First.swift"), atomically: true, encoding: .utf8
        )
        try "second file content\n".write(
            to: root.appendingPathComponent("Second.swift"), atomically: true, encoding: .utf8
        )
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(root)
        let service = ContextCompilerService(runtimeStore: store)

        let first = try await service.readContext(
            targets: ["First.swift", "Second.swift"],
            byteBudget: 20
        )
        XCTAssertEqual(first.chunks.count, 2)
        XCTAssertNotNil(first.continuation)
        XCTAssertGreaterThan(first.omittedBytes, 0)
        XCTAssertFalse(first.chunks[0].sha256.isEmpty)

        let second = try await service.readContext(
            targets: ["First.swift", "Second.swift"],
            byteBudget: 64,
            continuation: first.continuation
        )
        XCTAssertEqual(second.chunks.map(\.path), ["First.swift", "Second.swift"])
        XCTAssertNil(second.continuation)
    }

    func testSearchContextUsesDirectRgWorkerAndReturnsBoundedMatches() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "needle one\nother\nneedle two\n".write(
            to: root.appendingPathComponent("Find.swift"), atomically: true, encoding: .utf8
        )
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(root)
        let service = ContextCompilerService(runtimeStore: store)

        let result = try await service.searchContext(
            query: "needle",
            maxResults: 1,
            byteBudget: 1_024
        )

        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.matches[0].path, "Find.swift")
        XCTAssertGreaterThan(result.omittedMatches, 0)
        XCTAssertEqual(result.worker, "rg --json")
    }

    func testSearchContextContinuationRetrievesOmittedMatchesAndRejectsChangedResult() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("Find.swift")
        try "needle one\nneedle two\nneedle three\n".write(
            to: file, atomically: true, encoding: .utf8
        )
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(root)
        let service = ContextCompilerService(runtimeStore: store)

        let first = try await service.searchContext(query: "needle", maxResults: 1)
        let second = try await service.searchContext(
            query: "needle", maxResults: 1, continuation: first.continuation
        )
        XCTAssertEqual(first.matches.first?.line, 1)
        XCTAssertEqual(second.matches.first?.line, 2)

        try "needle changed\n".write(to: file, atomically: true, encoding: .utf8)
        do {
            _ = try await service.searchContext(
                query: "needle", maxResults: 1, continuation: second.continuation
            )
            XCTFail("変更後の検索結果を旧cursorで継続しました。")
        } catch {
            guard case AIShellError.contentChanged = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }
    }

    func testReadContextRejectsContinuationAfterPartialFileChanges() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("Changing.swift")
        try "abcdefghij\n".write(to: file, atomically: true, encoding: .utf8)
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(root)
        let service = ContextCompilerService(runtimeStore: store)

        let first = try await service.readContext(targets: ["Changing.swift"], byteBudget: 5)
        XCTAssertNotNil(first.continuation)
        try "ABCDEFGHIJ\n".write(to: file, atomically: true, encoding: .utf8)

        do {
            _ = try await service.readContext(
                targets: ["Changing.swift"],
                byteBudget: 64,
                continuation: first.continuation
            )
            XCTFail("変更後のfileを旧offsetから黙って継続しました。")
        } catch {
            guard case AIShellError.contentChanged = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }
    }

    private static func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ContextCompilerServiceTests.git", code: Int(process.terminationStatus))
        }
    }

    func testReadContextKeepsUTF8BoundariesAcrossContinuation() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "あいうえお".write(
            to: root.appendingPathComponent("Japanese.txt"), atomically: true, encoding: .utf8
        )
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(root)
        let service = ContextCompilerService(runtimeStore: store)

        let first = try await service.readContext(targets: ["Japanese.txt"], byteBudget: 5)
        let second = try await service.readContext(
            targets: ["Japanese.txt"], byteBudget: 64, continuation: first.continuation
        )

        XCTAssertEqual((first.chunks.first?.text ?? "") + (second.chunks.first?.text ?? ""), "あいうえお")
    }
}
