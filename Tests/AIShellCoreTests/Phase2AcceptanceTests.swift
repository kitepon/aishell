import Foundation
import XCTest
@testable import AIShellCore

final class Phase2AcceptanceTests: XCTestCase {
    func testIntegratedContextPreservesRecallBudgetAndContinuationWithFewerModelVisibleCalls() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Self.run("/usr/bin/git", ["init"], at: root)
        try Self.run("/usr/bin/git", ["config", "user.email", "fixture@example.invalid"], at: root)
        try Self.run("/usr/bin/git", ["config", "user.name", "Fixture"], at: root)

        try "let alpha = 1\n".write(
            to: sources.appendingPathComponent("Alpha.swift"), atomically: false, encoding: .utf8
        )
        for index in 0..<12 {
            try "let shared\(index) = \"alpha beta\"\n".write(
                to: sources.appendingPathComponent("Search\(index).swift"), atomically: false, encoding: .utf8
            )
        }
        try Self.run("/usr/bin/git", ["add", "."], at: root)
        let tree = try Self.capture("/usr/bin/git", ["write-tree"], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = try Self.capture("/usr/bin/git", ["commit-tree", tree, "-m", "fixture"], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.run("/usr/bin/git", ["update-ref", "HEAD", commit], at: root)

        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(root)
        let runtime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        let before = try await runtime.snapshot(entryLimit: 500, contextBudget: 0)

        try Self.run("/usr/bin/git", ["mv", "Sources/Alpha.swift", "Sources/RenamedAlpha.swift"], at: root)
        try "let alpha = 2\n".write(
            to: sources.appendingPathComponent("RenamedAlpha.swift"), atomically: false, encoding: .utf8
        )
        try "alpha beta notes\n".write(
            to: root.appendingPathComponent("Notes.txt"), atomically: false, encoding: .utf8
        )
        await runtime.ingestObservedPaths([
            sources.appendingPathComponent("Alpha.swift").path,
            sources.appendingPathComponent("RenamedAlpha.swift").path,
            root.appendingPathComponent("Notes.txt").path,
        ])

        var nativeCalls = 0
        let nativeStatus = try Self.capture("/usr/bin/git", ["status", "--porcelain=v1"], at: root)
        nativeCalls += 1
        let nativeStaged = try Self.capture("/usr/bin/git", ["diff", "--cached", "--name-status"], at: root)
        nativeCalls += 1
        let nativeUnstaged = try Self.capture("/usr/bin/git", ["diff", "--name-status"], at: root)
        nativeCalls += 1
        let rg = try XCTUnwrap(Self.executable(named: "rg"))
        let nativeAlpha = try Self.capture(rg, ["-l", "--fixed-strings", "alpha", "."], at: root)
        nativeCalls += 1
        let nativeBeta = try Self.capture(rg, ["-l", "--fixed-strings", "beta", "."], at: root)
        nativeCalls += 1
        XCTAssertTrue(nativeStatus.contains("RenamedAlpha.swift"))
        XCTAssertTrue(nativeStatus.contains("Notes.txt"))
        XCTAssertTrue(nativeStaged.contains("Sources/Alpha.swift"))
        XCTAssertTrue(nativeStaged.contains("Sources/RenamedAlpha.swift"))
        XCTAssertTrue(nativeUnstaged.contains("Sources/RenamedAlpha.swift"))
        XCTAssertTrue(nativeAlpha.contains("Notes.txt"))
        XCTAssertTrue(nativeBeta.contains("Sources/Search11.swift"))

        let service = ContextCompilerService(runtimeStore: store, workspaceRuntime: runtime)
        var aishellCalls = 0
        let integratedSearch = try await service.searchContextV2(request: SearchContextRequestV2(
            path: root.path,
            queries: [
                SearchContextQueryV2(id: "alpha", kind: .fixed, pattern: "alpha"),
                SearchContextQueryV2(id: "beta", kind: .fixed, pattern: "beta"),
            ],
            ranking: [.changed],
            changedSinceCursor: before.cursor,
            maxResults: 100,
            byteBudget: 1_048_576
        ))
        aishellCalls += 1

        XCTAssertEqual(Set(integratedSearch.matches.map(\.path)), Set(
            ["Notes.txt", "Sources/RenamedAlpha.swift"] + (0..<12).map { "Sources/Search\($0).swift" }
        ))
        XCTAssertEqual(Set(integratedSearch.matches.flatMap(\.queryIDs)), ["alpha", "beta"])
        XCTAssertEqual(
            Set(integratedSearch.matches.filter { $0.path == "Sources/RenamedAlpha.swift" }.flatMap(\.queryIDs)),
            ["alpha"]
        )
        var searchPage = try await service.searchContextV2(request: SearchContextRequestV2(
            path: root.path,
            queries: [
                SearchContextQueryV2(id: "alpha", kind: .fixed, pattern: "alpha"),
                SearchContextQueryV2(id: "beta", kind: .fixed, pattern: "beta"),
            ],
            ranking: [.changed],
            changedSinceCursor: before.cursor,
            maxResults: 100,
            byteBudget: 1_024
        ))
        var pagedSearchMatches: [SearchContextMatchV2] = []
        var searchPages = 0
        while true {
            searchPages += 1
            XCTAssertLessThanOrEqual(searchPage.returnedBytes, 1_024)
            XCTAssertEqual(searchPage.hasMore, searchPage.continuation != nil)
            pagedSearchMatches += searchPage.matches
            guard let continuation = searchPage.continuation else { break }
            searchPage = try await service.searchContextV2(continuation: continuation)
        }
        XCTAssertGreaterThan(searchPages, 1)
        XCTAssertEqual(pagedSearchMatches, integratedSearch.matches)

        let firstSearchPage = try await service.searchContextV2(request: SearchContextRequestV2(
            path: root.path,
            queries: [SearchContextQueryV2(id: "alpha", kind: .fixed, pattern: "alpha")],
            ranking: [], maxResults: 100, byteBudget: 1_024
        ))
        let searchToken = try XCTUnwrap(firstSearchPage.continuation)
        var tamperedCharacters = Array(searchToken)
        let last = tamperedCharacters.index(before: tamperedCharacters.endIndex)
        tamperedCharacters[last] = tamperedCharacters[last] == "a" ? "b" : "a"
        do {
            _ = try await service.searchContextV2(continuation: String(tamperedCharacters))
            XCTFail("改ざんしたsearch continuationを受理しました。")
        } catch {
            XCTAssertEqual(error as? SearchContextServiceError, .cursorExpired(reason: "integrity_mismatch"))
        }

        let integratedDiff = try await service.workspaceSnapshot(
            path: root.path,
            entryLimit: 500,
            contextBudget: 0,
            gitDiffRequest: GitDiffContextRequest(byteBudget: 1_048_576, includePatch: false)
        )
        aishellCalls += 1
        let fullDiff = try XCTUnwrap(integratedDiff.gitDiff)
        XCTAssertTrue(fullDiff.changes.contains {
            $0.layer == .staged && $0.kind == .renamed
                && $0.previousPath == "Sources/Alpha.swift" && $0.path == "Sources/RenamedAlpha.swift"
        })
        XCTAssertTrue(fullDiff.changes.contains {
            $0.layer == .unstaged && $0.path == "Sources/RenamedAlpha.swift"
        })
        XCTAssertTrue(fullDiff.changes.contains {
            $0.layer == .untracked && $0.path == "Notes.txt"
        })
        XCTAssertLessThanOrEqual(fullDiff.returnedBytes, 1_048_576)
        XCTAssertFalse(fullDiff.hasMore)
        XCTAssertEqual(nativeCalls, 5)
        XCTAssertEqual(aishellCalls, 2)

        let report: [String: Any] = [
            "schema": "aishell.phase2-acceptance.v1",
            "diff_recall": fullDiff.changes.count,
            "search_recall": integratedSearch.matches.count,
            "diff_pages": 1,
            "search_pages": searchPages,
            "native_model_visible_calls": nativeCalls,
            "aishell_model_visible_calls": aishellCalls,
            "token_measurement": "not_measured",
        ]
        let reportData = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: reportData, as: UTF8.self))
    }

    func testWorkspaceSnapshotKeepsChangedSearchCursorConsumableForDrilldown() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.run("/usr/bin/git", ["init"], at: root)
        try Self.run("/usr/bin/git", ["config", "user.email", "fixture@example.invalid"], at: root)
        try Self.run("/usr/bin/git", ["config", "user.name", "Fixture"], at: root)
        let source = root.appendingPathComponent("Source.swift")
        try "let value = 1\n".write(to: source, atomically: false, encoding: .utf8)
        try Self.run("/usr/bin/git", ["add", "."], at: root)
        let tree = try Self.capture("/usr/bin/git", ["write-tree"], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = try Self.capture("/usr/bin/git", ["commit-tree", tree, "-m", "fixture"], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.run("/usr/bin/git", ["update-ref", "HEAD", commit], at: root)

        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(root)
        let runtime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        let before = try await runtime.snapshot(entryLimit: 100, contextBudget: 0)
        try "let value = \"needle\"\n".write(to: source, atomically: false, encoding: .utf8)
        await runtime.ingestObservedPaths([source.path])
        let service = ContextCompilerService(runtimeStore: store, workspaceRuntime: runtime)

        let snapshot = try await service.workspaceSnapshot(
            path: root.path, sinceCursor: before.cursor, entryLimit: 100, contextBudget: 0
        )
        XCTAssertTrue(snapshot.changes.contains { $0.kind == .modified && $0.path == "Source.swift" })
        let drilldown = try await service.searchContextV2(request: SearchContextRequestV2(
            path: root.path,
            queries: [SearchContextQueryV2(id: "needle", kind: .fixed, pattern: "needle")],
            ranking: [.changed],
            changedSinceCursor: before.cursor,
            maxResults: 10,
            byteBudget: 4_096
        ))
        XCTAssertEqual(drilldown.matches.map(\.path), ["Source.swift"])
    }

    func testWorkspaceSnapshotGitDiffContinuationRoundTripsWithoutFilesystemChange() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let root = fixture.base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.run("/usr/bin/git", ["init"], at: root)
        try Self.run("/usr/bin/git", ["config", "user.email", "fixture@example.invalid"], at: root)
        try Self.run("/usr/bin/git", ["config", "user.name", "Fixture"], at: root)
        let source = root.appendingPathComponent("Source.swift")
        try "let value = 1\n".write(to: source, atomically: false, encoding: .utf8)
        try Self.run("/usr/bin/git", ["add", "."], at: root)
        let tree = try Self.capture("/usr/bin/git", ["write-tree"], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = try Self.capture("/usr/bin/git", ["commit-tree", tree, "-m", "fixture"], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.run("/usr/bin/git", ["update-ref", "HEAD", commit], at: root)
        try "let value = 2\n".write(to: source, atomically: false, encoding: .utf8)

        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(root)
        let runtime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        let service = ContextCompilerService(runtimeStore: store, workspaceRuntime: runtime)
        let first = try await service.workspaceSnapshot(
            path: root.path,
            entryLimit: 100,
            contextBudget: 0,
            gitDiffRequest: GitDiffContextRequest(byteBudget: 1, includePatch: false)
        )
        let continuation = try XCTUnwrap(first.gitDiff?.continuation)
        let second = try await service.workspaceSnapshot(
            path: root.path,
            entryLimit: 100,
            contextBudget: 0,
            gitDiffRequest: GitDiffContextRequest(byteBudget: 4_096, continuation: continuation)
        )
        XCTAssertEqual(second.gitDiff?.changes.map(\.path), ["Source.swift"])
        XCTAssertFalse(second.gitDiff?.hasMore ?? true)
    }

    private static func executable(named name: String) -> String? {
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String], at directory: URL) throws -> String {
        try capture(executable, arguments, at: directory)
    }

    private static func capture(_ executable: String, _ arguments: [String], at directory: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "Phase2AcceptanceTests.process",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: stderr, as: UTF8.self)]
            )
        }
        return String(decoding: stdout, as: UTF8.self)
    }
}
