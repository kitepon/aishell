import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import AIShellCore

final class GitContextProviderTests: XCTestCase {
    func testStagedRenamePreservesBothPathsObjectIDsAndFramedEvidence() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        try fixture.write("old.txt", "same bytes\n")
        try fixture.git(["add", "old.txt"])
        try fixture.git(["commit", "-m", "initial"])
        try fixture.git(["mv", "old.txt", "new.txt"])

        let (provider, store, binding) = try fixture.provider()
        let result = try await provider.context(request: .init(includePatch: false), comparisonBinding: binding)
        let rename = try XCTUnwrap(result.changes.first { $0.layer == .staged && $0.kind == .renamed })
        XCTAssertEqual(rename.previousPath, "old.txt")
        XCTAssertEqual(rename.path, "new.txt")
        XCTAssertNotNil(rename.oldObjectID)
        XCTAssertEqual(rename.oldObjectID, rename.newObjectID)
        XCTAssertEqual(rename.oldObjectIDSource, .tree)
        XCTAssertEqual(rename.newObjectIDSource, .index)

        let slice = try await store.read(handle: result.artifact.handle, mode: .range(offset: 0, length: result.artifact.sizeBytes), byteBudget: result.artifact.sizeBytes)
        let bytes = try XCTUnwrap(slice.base64.flatMap { Data(base64Encoded: $0) } ?? slice.text.map { Data($0.utf8) })
        XCTAssertTrue(bytes.starts(with: Data("AISHELL-GIT-DIFF\0\u{1}".utf8)))
        XCTAssertEqual(Self.sha256(bytes), result.artifact.sha256)
    }

    func testMixedLayersAndContinuationConcatenateToSingleResult() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        try fixture.write("README.md", "first\n")
        try fixture.git(["add", "README.md"])
        try fixture.git(["commit", "-m", "initial"])
        try fixture.write("README.md", "second\n")
        try fixture.write("Source.swift", "let answer = 42\n")

        let (completeProvider, _, binding) = try fixture.provider(suffix: "complete")
        let complete = try await completeProvider.context(request: .init(byteBudget: 1_048_576, includePatch: false), comparisonBinding: binding)
        XCTAssertEqual(complete.changes.map(\.layer), [.unstaged, .untracked])

        let (pagedProvider, _, _) = try fixture.provider(suffix: "paged")
        var page = try await pagedProvider.context(request: .init(byteBudget: 1, includePatch: false), comparisonBinding: binding)
        XCTAssertEqual(page.byteBudget, 1)
        XCTAssertLessThanOrEqual(page.returnedBytes, page.byteBudget)
        XCTAssertTrue(page.changes.isEmpty)
        XCTAssertTrue(page.hasMore)
        var collected: [GitDiffChange] = []
        while let continuation = page.continuation {
            page = try await pagedProvider.context(
                request: .init(byteBudget: 600, continuation: continuation),
                comparisonBinding: binding
            )
            collected += page.changes
        }
        XCTAssertEqual(collected, complete.changes)
    }

    func testContinuationRejectsTamperingAndChangedWorktree() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        try fixture.write("tracked", "a\n")
        try fixture.git(["add", "tracked"])
        try fixture.git(["commit", "-m", "initial"])
        try fixture.write("tracked", "b\n")
        let (provider, _, binding) = try fixture.provider()
        let first = try await provider.context(request: .init(byteBudget: 1, includePatch: false), comparisonBinding: binding)
        let token = try XCTUnwrap(first.continuation)

        await XCTAssertThrowsErrorAsync(try await provider.context(request: .init(continuation: token + "x"), comparisonBinding: binding)) {
            XCTAssertEqual($0 as? GitContextError, .invalidContinuation)
        }
        try fixture.write("tracked", "c\n")
        let changedBinding = GitWorkspaceComparisonBinding(
            entries: [.init(
                hashState: "hashed", identity: "changed", kind: "regular",
                modifiedAtNanoseconds: nil, path: "tracked", sha256: "changed", sizeBytes: 2
            )],
            eventHighWater: nil,
            generation: "generation-2",
            rootIdentity: "fixture-root",
            workspaceCursor: "cursor-2"
        )
        await XCTAssertThrowsErrorAsync(try await provider.context(request: .init(continuation: token), comparisonBinding: changedBinding)) {
            XCTAssertEqual($0 as? GitContextError, .contentChanged)
        }
    }

    func testContinuationRejectsRepositoryRootSwapWithoutReadingOutsideRepository() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        try fixture.write("tracked", "safe base\n")
        try fixture.git(["add", "tracked"])
        try fixture.git(["commit", "-m", "initial"])
        try fixture.write("tracked", "safe change\n")

        let outside = try GitFixture()
        defer { outside.cleanup() }
        try outside.write("tracked", "outside secret\n")
        try outside.git(["add", "tracked"])

        let (provider, _, binding) = try fixture.provider()
        let first = try await provider.context(
            request: .init(byteBudget: 1, includePatch: false),
            comparisonBinding: binding
        )
        let token = try XCTUnwrap(first.continuation)
        let repositoryRoot = URL(fileURLWithPath: first.repositoryRoot, isDirectory: true)
        let held = repositoryRoot.deletingLastPathComponent()
            .appendingPathComponent(repositoryRoot.lastPathComponent + ".continuation-held", isDirectory: true)

        try FileManager.default.moveItem(at: repositoryRoot, to: held)
        try FileManager.default.createSymbolicLink(at: repositoryRoot, withDestinationURL: outside.base)
        await XCTAssertThrowsErrorAsync(
            try await provider.context(request: .init(continuation: token), comparisonBinding: binding)
        ) {
            guard let error = $0 as? AIShellError else { return XCTFail("unexpected error: \($0)") }
            if case .invalidPath = error {} else { XCTFail("unexpected error: \(error)") }
        }
        try FileManager.default.removeItem(at: repositoryRoot)
        try FileManager.default.moveItem(at: held, to: repositoryRoot)

        XCTAssertEqual(
            try String(contentsOf: repositoryRoot.appendingPathComponent("tracked"), encoding: .utf8),
            "safe change\n"
        )
    }

    func testUnbornRepositoryUsesEmptyTreeForStagedAndRejectsExplicitBase() async throws {
        let fixture = try GitFixture(makeInitialCommit: false)
        defer { fixture.cleanup() }
        try fixture.write("new.txt", "new\n")
        try fixture.git(["add", "new.txt"])
        let (provider, _, binding) = try fixture.provider()
        let result = try await provider.context(request: .init(includePatch: false), comparisonBinding: binding)
        XCTAssertNil(result.headSHA)
        XCTAssertNil(result.baseSHA)
        XCTAssertEqual(result.changes.first?.layer, .staged)
        XCTAssertEqual(result.changes.first?.kind, .added)

        await XCTAssertThrowsErrorAsync(try await provider.context(request: .init(baseRef: "main"), comparisonBinding: binding)) {
            XCTAssertEqual($0 as? GitContextError, .unbornHeadWithExplicitBase)
        }
    }

    func testLiteralSubdirectoryScopeDoesNotMatchGlobLikeSibling() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        try fixture.write("a[1]/inside.txt", "one\n")
        try fixture.write("a1/outside.txt", "one\n")
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "initial"])
        try fixture.write("a[1]/inside.txt", "two\n")
        try fixture.write("a1/outside.txt", "two\n")
        let (provider, _, binding) = try fixture.provider()
        let result = try await provider.context(path: "a[1]", request: .init(includePatch: false), comparisonBinding: binding)
        XCTAssertEqual(result.changes.map(\.path), ["a[1]/inside.txt"])
    }

    func testBaseStagedAndUnstagedRemainSeparateForSamePath() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let baseSHA = String(decoding: try fixture.git(["rev-parse", "HEAD"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.write("shared.txt", "committed\n")
        try fixture.git(["add", "shared.txt"])
        try fixture.git(["commit", "-m", "second"])
        try fixture.write("shared.txt", "staged\n")
        try fixture.git(["add", "shared.txt"])
        try fixture.write("shared.txt", "worktree\n")
        let (provider, _, binding) = try fixture.provider()
        let result = try await provider.context(
            request: .init(mode: .branch, baseRef: baseSHA, includePatch: false),
            comparisonBinding: binding
        )
        XCTAssertEqual(result.comparisonMode, .branch)
        XCTAssertEqual(result.headBranch, "main")
        XCTAssertEqual(result.dirtyState, "dirty")
        XCTAssertEqual(result.baseSHA, baseSHA)
        XCTAssertFalse(result.repositoryIdentity.isEmpty)
        XCTAssertEqual(result.changes.filter { $0.path == "shared.txt" }.map(\.layer), [.baseToHead, .staged, .unstaged])
        XCTAssertEqual(result.changes.last?.newObjectIDSource, .worktreeRaw)
    }

    func testExternalCleanFilterIsNotStartedAndWorktreeOIDUsesRawBytes() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let marker = fixture.base.appendingPathComponent("filter-ran")
        let filter = fixture.base.appendingPathComponent("evil-filter")
        let script = "#!/bin/sh\nprintf ran > '\(marker.path)'\n/bin/cat\n"
        try Data(script.utf8).write(to: filter)
        XCTAssertEqual(chmod(filter.path, 0o755), 0)
        try fixture.git(["config", "filter.evil.clean", filter.path])
        try fixture.git(["config", "filter.evil.required", "true"])
        try fixture.write(".gitattributes", "filtered filter=evil\n")
        try fixture.write("filtered", "initial\r\n")
        try fixture.git(["add", ".gitattributes", "filtered"])
        try fixture.git(["commit", "-m", "filtered"])
        try? FileManager.default.removeItem(at: marker)
        try fixture.write("filtered", "raw\r\nbytes\n")

        let (provider, _, binding) = try fixture.provider()
        let result = try await provider.context(request: .init(includePatch: false), comparisonBinding: binding)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let change = try XCTUnwrap(result.changes.first { $0.path == "filtered" && $0.layer == .unstaged })
        let expected = String(decoding: try fixture.gitWithInput(["hash-object", "--no-filters", "--stdin"], input: Data("raw\r\nbytes\n".utf8)), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(change.newObjectID, expected)
    }

    func testGitRoutingEnvironmentInjectionIsRemoved() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        try fixture.write("actual.txt", "actual\n")
        let decoy = try GitFixture()
        defer { decoy.cleanup() }
        try decoy.write("decoy.txt", "decoy\n")
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_DIR"] = decoy.base.appendingPathComponent(".git").path
        environment["GIT_WORK_TREE"] = decoy.base.path
        environment["GIT_INDEX_FILE"] = decoy.base.appendingPathComponent(".git/index").path
        environment["GIT_OBJECT_DIRECTORY"] = decoy.base.appendingPathComponent(".git/objects").path
        let (provider, _, binding) = try fixture.provider(environment: environment)
        let result = try await provider.context(request: .init(includePatch: false), comparisonBinding: binding)
        XCTAssertTrue(result.changes.contains { $0.path == "actual.txt" })
        XCTAssertFalse(result.changes.contains { $0.path == "decoy.txt" })
        XCTAssertEqual(URL(fileURLWithPath: result.repositoryRoot).lastPathComponent, fixture.base.lastPathComponent)
    }

    func testDirtySubmoduleUsesGitlinkOIDWithoutReadingDirectoryAsFile() async throws {
        let child = try GitFixture()
        defer { child.cleanup() }
        try child.write("child.txt", "child\n")
        try child.git(["add", "child.txt"])
        try child.git(["commit", "-m", "child"])
        let parent = try GitFixture()
        defer { parent.cleanup() }
        try parent.git(["-c", "protocol.file.allow=always", "submodule", "add", child.base.path, "Sub"])
        try parent.git(["commit", "-am", "submodule"])
        try Data("dirty\n".utf8).write(to: parent.base.appendingPathComponent("Sub/child.txt"))
        let (provider, _, binding) = try parent.provider()
        let result = try await provider.context(request: .init(includePatch: false), comparisonBinding: binding)
        let change = try XCTUnwrap(result.changes.first { $0.path == "Sub" && $0.layer == .unstaged })
        XCTAssertEqual(change.modeAfter, "160000")
        XCTAssertEqual(change.oldObjectIDSource, .gitlink)
        XCTAssertEqual(change.newObjectIDSource, .gitlink)
        XCTAssertNil(change.contentSHA256)
    }

    func testLargePatchIsChunkedAndEveryContinuationAdvances() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let original = String(repeating: "old line 0123456789\n", count: 70_000)
        let changed = String(repeating: "new line 9876543210\n", count: 70_000)
        try fixture.write("large.txt", original)
        try fixture.git(["add", "large.txt"])
        try fixture.git(["commit", "-m", "large"])
        try fixture.write("large.txt", changed)
        let (provider, _, binding) = try fixture.provider()
        var result = try await provider.context(request: .init(byteBudget: 1_048_576), comparisonBinding: binding)
        var patches = result.patches
        var tokens: [String] = []
        while let continuation = result.continuation {
            XCTAssertFalse(tokens.contains(continuation), "continuation offset must advance")
            tokens.append(continuation)
            result = try await provider.context(request: .init(byteBudget: 1_048_576, continuation: continuation), comparisonBinding: binding)
            patches += result.patches
        }
        let chunks = patches.filter { $0.layer == .unstaged }.sorted { $0.offset < $1.offset }
        XCTAssertGreaterThan(chunks.count, 1)
        var expectedOffset = 0
        for chunk in chunks {
            XCTAssertEqual(chunk.offset, expectedOffset)
            let bytes = try XCTUnwrap(chunk.text.map { Data($0.utf8) } ?? chunk.base64.flatMap { Data(base64Encoded: $0) })
            expectedOffset += bytes.count
            XCTAssertEqual(chunk.totalBytes, chunks.first?.totalBytes)
        }
        XCTAssertEqual(expectedOffset, chunks.first?.totalBytes)
    }

    func testArtifactDecoderValidatesUntrackedTripletFramingAndCanonicalBodies() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        try fixture.write("new.txt", "new bytes\n")
        let (provider, store, binding) = try fixture.provider()
        let result = try await provider.context(request: .init(), comparisonBinding: binding)
        let slice = try await store.read(handle: result.artifact.handle, mode: .range(offset: 0, length: result.artifact.sizeBytes), byteBudget: result.artifact.sizeBytes)
        let artifact = try XCTUnwrap(slice.base64.flatMap { Data(base64Encoded: $0) } ?? slice.text.map { Data($0.utf8) })
        let records = try ArtifactDecoder.decode(artifact)
        XCTAssertEqual(records.prefix(12).map(\.kind), [1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2, 3])
        let untracked = Array(records[9...11])
        XCTAssertEqual(untracked.map { $0.header["layer"] as? String }, ["untracked", "untracked", "untracked"])
        XCTAssertEqual(untracked.map { $0.header["recordKind"] as? String }, ["raw_stdout", "patch_stdout", "worker_stderr"])
        XCTAssertNotNil(untracked[0].header["argumentsDigest"] as? String)
        XCTAssertTrue(untracked[1].header["argumentsDigest"] is NSNull)
        XCTAssertTrue(untracked[0].body.contains(Data("new.txt\0".utf8)))
        XCTAssertTrue(untracked[1].body.contains(Data("untracked new.txt\nnew bytes\n".utf8)))
        let digestRecord = try XCTUnwrap(records.first { $0.kind == 4 })
        XCTAssertEqual(String(decoding: digestRecord.body, as: UTF8.self), "{\"path\":\"new.txt\",\"sha256\":\"\(Self.sha256(Data("new bytes\n".utf8)))\"}")
        XCTAssertEqual(Self.sha256(artifact), result.artifact.sha256)
    }

    func testFaultyGitAndCorruptIndexFailClosed() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let faulty = fixture.base.appendingPathComponent("faulty-git")
        try Data("#!/bin/sh\nprintf 'worker exploded' >&2\nexit 2\n".utf8).write(to: faulty)
        XCTAssertEqual(chmod(faulty.path, 0o755), 0)
        let resolver = PathResolver(baseDirectory: URL(fileURLWithPath: fixture.base.path))
        let store = EvidenceStore(baseDirectory: fixture.base.appendingPathComponent(".git/faulty-evidence"))
        let provider = GitContextProvider(resolver: resolver, evidenceStore: store, gitURL: faulty)
        let binding = fixture.binding()
        await XCTAssertThrowsErrorAsync(try await provider.context(request: .init(), comparisonBinding: binding)) {
            guard let error = $0 as? GitContextError else { return XCTFail("unexpected error: \($0)") }
            if case let .gitFailed(_, _, stderr) = error { XCTAssertTrue(stderr.contains("worker exploded")) }
            else { XCTFail("unexpected error: \(error)") }
        }

        try Data("corrupt-index".utf8).write(to: fixture.base.appendingPathComponent(".git/index"))
        let (normal, _, _) = try fixture.provider(suffix: "corrupt")
        await XCTAssertThrowsErrorAsync(try await normal.context(request: .init(), comparisonBinding: binding)) {
            guard let error = $0 as? GitContextError else { return XCTFail("unexpected error: \($0)") }
            if case .gitFailed = error {} else { XCTFail("unexpected error: \(error)") }
        }
    }

    func testContinuationDetectsUnmergedStageTupleChange() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        try fixture.write("conflict.txt", "base\n")
        try fixture.git(["add", "conflict.txt"])
        try fixture.git(["commit", "-m", "base"])
        try fixture.git(["checkout", "-b", "other"])
        try fixture.write("conflict.txt", "other\n")
        try fixture.git(["commit", "-am", "other"])
        try fixture.git(["checkout", "main"])
        try fixture.write("conflict.txt", "main\n")
        try fixture.git(["commit", "-am", "main"])
        XCTAssertNotEqual(try fixture.gitStatus(["merge", "other"]), 0)

        let (provider, _, binding) = try fixture.provider()
        let first = try await provider.context(request: .init(byteBudget: 1, includePatch: false), comparisonBinding: binding)
        let token = try XCTUnwrap(first.continuation)
        let replacement = String(decoding: try fixture.gitWithInput(["hash-object", "-w", "--stdin"], input: Data("replacement\n".utf8)), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let indexInfo = Data("100644 \(replacement) 2\tconflict.txt\0".utf8)
        try fixture.gitWithInput(["update-index", "-z", "--index-info"], input: indexInfo)
        await XCTAssertThrowsErrorAsync(try await provider.context(request: .init(continuation: token), comparisonBinding: binding)) {
            XCTAssertEqual($0 as? GitContextError, .contentChanged)
        }
    }

    func testParentDirectoryABASwapCannotReadOutsideRoot() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        try fixture.write("inside/file.txt", "original\n")
        try fixture.git(["add", "inside/file.txt"])
        try fixture.git(["commit", "-m", "inside"])
        try fixture.write("inside/file.txt", "safe changed\n")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("GitContextOutside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside secret\n".utf8).write(to: outside.appendingPathComponent("file.txt"))
        let inside = fixture.base.appendingPathComponent("inside", isDirectory: true)
        let held = fixture.base.appendingPathComponent("held", isDirectory: true)
        let (provider, _, binding) = try fixture.provider(rawContentHook: { _, phase in
            switch phase {
            case .beforeRootOpen, .rootOpenCompleted, .rootAnchored, .workersCompleted:
                break
            case .parentOpened:
                try FileManager.default.moveItem(at: inside, to: held)
                try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: outside)
            case .contentRead:
                try FileManager.default.removeItem(at: inside)
                try FileManager.default.moveItem(at: held, to: inside)
            }
        })
        let result = try await provider.context(request: .init(includePatch: false), comparisonBinding: binding)
        let change = try XCTUnwrap(result.changes.first { $0.path == "inside/file.txt" && $0.layer == .unstaged })
        XCTAssertEqual(change.contentSHA256, Self.sha256(Data("safe changed\n".utf8)))
        XCTAssertNotEqual(change.contentSHA256, Self.sha256(Data("outside secret\n".utf8)))
    }

    func testRepositoryRootABASwapFailsBeforeOutsideRead() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        try fixture.write("tracked.txt", "safe\n")
        try fixture.git(["add", "tracked.txt"])
        try fixture.git(["commit", "-m", "tracked"])
        try fixture.write("tracked.txt", "changed\n")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("GitContextRootOutside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside secret\n".utf8).write(to: outside.appendingPathComponent("tracked.txt"))
        let (provider, _, binding) = try fixture.provider(rawContentHook: { repositoryRoot, phase in
            let held = repositoryRoot.deletingLastPathComponent().appendingPathComponent(repositoryRoot.lastPathComponent + ".held")
            switch phase {
            case .beforeRootOpen:
                try FileManager.default.moveItem(at: repositoryRoot, to: held)
                try FileManager.default.createSymbolicLink(at: repositoryRoot, withDestinationURL: outside)
            case .rootOpenCompleted:
                if FileManager.default.fileExists(atPath: repositoryRoot.path) {
                    try FileManager.default.removeItem(at: repositoryRoot)
                }
                try FileManager.default.moveItem(at: held, to: repositoryRoot)
            case .rootAnchored, .workersCompleted, .parentOpened, .contentRead:
                break
            }
        })
        await XCTAssertThrowsErrorAsync(try await provider.context(request: .init(includePatch: false), comparisonBinding: binding)) {
            guard let error = $0 as? AIShellError else { return XCTFail("unexpected error: \($0)") }
            if case .invalidPath = error {} else { XCTFail("unexpected error: \(error)") }
        }
        XCTAssertEqual(try String(contentsOf: fixture.base.appendingPathComponent("tracked.txt"), encoding: .utf8), "changed\n")
    }

    func testGitWorkersStayOnHeldRootFDAfterPathABASwap() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        try fixture.write("tracked.txt", "base\n")
        try fixture.git(["add", "tracked.txt"])
        try fixture.git(["commit", "-m", "base"])
        try fixture.write("tracked.txt", "original safe change\n")
        let outside = try GitFixture()
        defer { outside.cleanup() }
        try outside.write("tracked.txt", "outside base\n")
        try outside.git(["add", "tracked.txt"])
        try outside.git(["commit", "-m", "outside"])
        try outside.write("tracked.txt", "outside secret\n")
        let (provider, _, binding) = try fixture.provider(rawContentHook: { repositoryRoot, phase in
            let held = repositoryRoot.deletingLastPathComponent().appendingPathComponent(repositoryRoot.lastPathComponent + ".held")
            switch phase {
            case .rootAnchored:
                try FileManager.default.moveItem(at: repositoryRoot, to: held)
                try FileManager.default.createSymbolicLink(at: repositoryRoot, withDestinationURL: outside.base)
            case .workersCompleted:
                try FileManager.default.removeItem(at: repositoryRoot)
                try FileManager.default.moveItem(at: held, to: repositoryRoot)
            case .beforeRootOpen, .rootOpenCompleted, .parentOpened, .contentRead:
                break
            }
        })
        let result = try await provider.context(request: .init(), comparisonBinding: binding)
        let patchText = result.patches.compactMap(\.text).joined()
        XCTAssertTrue(patchText.contains("original safe change"))
        XCTAssertFalse(patchText.contains("outside secret"))
        XCTAssertEqual(result.changes.first { $0.path == "tracked.txt" }?.contentSHA256, Self.sha256(Data("original safe change\n".utf8)))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct GitFixture {
    let base: URL

    init(makeInitialCommit: Bool = true) throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("GitContextTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "AIShell Tests"])
        try git(["config", "user.email", "aishell@example.invalid"])
        if makeInitialCommit {
            try write(".seed", "seed\n")
            try git(["add", ".seed"])
            try git(["commit", "-m", "seed"])
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }

    func write(_ path: String, _ text: String) throws {
        let url = base.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @discardableResult
    func git(_ arguments: [String]) throws -> Data {
        try gitWithInput(arguments, input: nil)
    }

    @discardableResult
    func gitWithInput(_ arguments: [String], input: Data?) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = base
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        if let input {
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            stdin.fileHandleForWriting.write(input)
            try stdin.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitFixture", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: errors, as: UTF8.self)])
        }
        return output
    }

    func gitStatus(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = base
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func binding(cursor: String = "cursor-1") -> GitWorkspaceComparisonBinding {
        GitWorkspaceComparisonBinding(
            entries: [], eventHighWater: nil, generation: "generation-1",
            rootIdentity: "fixture-root", workspaceCursor: cursor
        )
    }

    func provider(
        suffix: String = "default",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        rawContentHook: (@Sendable (URL, GitRawContentHookPhase) throws -> Void)? = nil
    ) throws -> (GitContextProvider, EvidenceStore, GitWorkspaceComparisonBinding) {
        let store = EvidenceStore(baseDirectory: base.appendingPathComponent(".git/aishell-evidence-\(suffix)"))
        let resolver = PathResolver(baseDirectory: URL(fileURLWithPath: base.path))
        let provider: GitContextProvider
        if let rawContentHook {
            provider = GitContextProvider(
                resolver: resolver, evidenceStore: store, environment: environment,
                rawContentOpenHookForTests: rawContentHook
            )
        } else {
            provider = GitContextProvider(resolver: resolver, evidenceStore: store, environment: environment)
        }
        return (
            provider,
            store,
            binding()
        )
    }
}

private enum ArtifactDecoder {
    struct Record {
        let kind: UInt8
        let header: [String: Any]
        let body: Data
    }

    static func decode(_ data: Data) throws -> [Record] {
        let prefix = Data("AISHELL-GIT-DIFF\0\u{1}".utf8)
        guard data.starts(with: prefix) else { throw DecodeError.invalidPrefix }
        var offset = prefix.count
        var records: [Record] = []
        while offset < data.count {
            let kind = try byte(data, &offset)
            let headerLength = Int(try integer(data, &offset, count: 4))
            let headerBytes = try slice(data, &offset, count: headerLength)
            let bodyLength64 = try integer(data, &offset, count: 8)
            guard bodyLength64 <= UInt64(Int.max) else { throw DecodeError.invalidLength }
            let body = try slice(data, &offset, count: Int(bodyLength64))
            let object = try JSONSerialization.jsonObject(with: headerBytes)
            guard let header = object as? [String: Any],
                  Set(header.keys) == Set(["argumentsDigest", "layer", "path", "recordKind", "stream"]),
                  try canonicalJSON(header) == headerBytes else { throw DecodeError.nonCanonicalHeader }
            records.append(Record(kind: kind, header: header, body: body))
        }
        guard offset == data.count else { throw DecodeError.invalidLength }
        return records
    }

    private static func byte(_ data: Data, _ offset: inout Int) throws -> UInt8 {
        guard offset < data.count else { throw DecodeError.invalidLength }
        defer { offset += 1 }
        return data[offset]
    }

    private static func integer(_ data: Data, _ offset: inout Int, count: Int) throws -> UInt64 {
        let bytes = try slice(data, &offset, count: count)
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func slice(_ data: Data, _ offset: inout Int, count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else { throw DecodeError.invalidLength }
        defer { offset += count }
        return Data(data[offset..<(offset + count)])
    }

    private static func canonicalJSON(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    enum DecodeError: Error { case invalidPrefix, invalidLength, nonCanonicalHeader }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch { handler(error) }
}
