import XCTest
import Darwin
@testable import AIShellCore

final class NativeProcessServiceTests: XCTestCase {
    func testRunsExecutableDirectlyAndCapturesStructuredResult() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.base.appendingPathComponent("runtime", isDirectory: true)
        let allowed = fixture.base.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        let store = RuntimeStore(baseDirectory: runtime)
        await store.setWorkingDirectoryForTesting(allowed)
        let service = NativeProcessService(store: store)

        let result = try await service.run(
            executable: "/usr/bin/printf",
            arguments: ["%s", "direct-process"],
            workingDirectory: ".",
            environment: ["AISHELL_TEST": "1"],
            timeoutSeconds: 5
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.terminationReason, "exit")
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout, "direct-process")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.workingDirectory, allowed.path)
    }

    func testResolvesExecutableNameFromProvidedPATH() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let allowed = fixture.base.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(allowed)
        let service = NativeProcessService(store: store)

        let result = try await service.run(
            executable: "printf",
            arguments: ["%s", "path-owned"],
            environment: ["PATH": "/usr/bin"]
        )

        XCTAssertEqual(result.executable, "/usr/bin/printf")
        XCTAssertEqual(result.stdout, "path-owned")
    }

    func testResolvesRelativePATHEntryFromRequestedWorkingDirectory() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let allowed = fixture.base.appendingPathComponent("allowed", isDirectory: true)
        let bin = allowed.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: bin.appendingPathComponent("printf"),
            withDestinationURL: URL(fileURLWithPath: "/usr/bin/printf")
        )
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(allowed)
        let service = NativeProcessService(store: store)

        let result = try await service.run(
            executable: "printf",
            arguments: ["%s", "relative-path"],
            workingDirectory: allowed.path,
            environment: ["PATH": "bin"]
        )

        XCTAssertEqual(result.executable, "/usr/bin/printf")
        XCTAssertEqual(result.stdout, "relative-path")
    }

    func testTimeoutTerminatesProcess() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let allowed = fixture.base.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(allowed)
        let service = NativeProcessService(store: store)

        let result = try await service.run(
            executable: "/bin/sleep",
            arguments: ["2"],
            timeoutSeconds: 0.1
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.terminationReason, "signal")
    }

    func testTimeoutTerminatesSpawnedDescendant() async throws {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw XCTSkip("/usr/bin/python3がありません。")
        }
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let allowed = fixture.base.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(allowed)
        let service = NativeProcessService(store: store)
        let script = "import subprocess,time; p=subprocess.Popen(['/bin/sleep','30']); open('child.pid','w').write(str(p.pid)); time.sleep(30)"

        let result = try await service.run(
            executable: python,
            arguments: ["-c", script],
            workingDirectory: allowed.path,
            timeoutSeconds: 0.5
        )
        let childPID = try XCTUnwrap(Int32(
            String(contentsOf: allowed.appendingPathComponent("child.pid"), encoding: .utf8)
        ))
        for _ in 0..<20 where Darwin.kill(childPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertTrue(result.timedOut)
        XCTAssertNotEqual(Darwin.kill(childPID, 0), 0, "timeout後もchild processが生存しています。")
    }

    func testRetainedRunDoesNotLeaveOrphanArtifactWhenSecondStreamExceedsQuota() async throws {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw XCTSkip("/usr/bin/python3がありません。")
        }
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let allowed = fixture.base.appendingPathComponent("allowed", isDirectory: true)
        let evidenceDirectory = fixture.base.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(allowed)
        let service = NativeProcessService(store: store)
        let evidence = EvidenceStore(baseDirectory: evidenceDirectory, maximumBytes: 5)

        do {
            _ = try await service.runRetained(
                executable: python,
                arguments: ["-c", "import sys; sys.stdout.write('abc'); sys.stderr.write('def')"],
                evidenceStore: evidence
            )
            XCTFail("quota超過を成功扱いしました。")
        } catch {
            guard case AIShellError.evidenceQuotaExceeded = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: evidenceDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(leftovers.isEmpty, "返されないstdout artifactが孤児化しました: \(leftovers)")
    }

    func testRunsWithSecondAllowedRootAsAbsoluteWorkingDirectory() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let first = fixture.base.appendingPathComponent("first", isDirectory: true)
        let second = fixture.base.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(first)
        let service = NativeProcessService(store: store)

        let result = try await service.run(
            executable: "/bin/pwd",
            workingDirectory: second.path
        )
        let canonicalSecond = second.resolvingSymlinksInPath().path
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.workingDirectory, canonicalSecond)
        XCTAssertTrue(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/second"))
    }

    func testRejectsShellAndAcceptsWorkingDirectoryOutsideBase() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let allowed = fixture.base.appendingPathComponent("allowed", isDirectory: true)
        let outside = fixture.base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        await store.setWorkingDirectoryForTesting(allowed)
        let service = NativeProcessService(store: store)

        do {
            _ = try await service.run(executable: "/bin/zsh", arguments: ["-c", "true"])
            XCTFail("shellを直接起動してしまいました。")
        } catch {
            guard case AIShellError.executableNotAllowed = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }

        let result = try await service.run(
            executable: "/usr/bin/true",
            workingDirectory: outside.path
        )
        XCTAssertEqual(result.exitCode, 0)
    }
}
