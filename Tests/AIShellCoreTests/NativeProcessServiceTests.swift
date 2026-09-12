import Darwin
import XCTest
@testable import AIShellCore

final class NativeProcessServiceTests: XCTestCase, @unchecked Sendable {
    func testArgumentsAreLiteralAndStdinIsExplicit() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let process = NativeProcessService(workingDirectory: fixture.base)
        let literal = "$HOME; $(touch must-not-exist) * 日本語\n"
        let echoed = try await process.run(executable: "/usr/bin/printf", arguments: ["%s", literal])
        XCTAssertEqual(echoed.stdout.encoding, "utf8")
        XCTAssertEqual(echoed.stdout.data, literal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.appendingPathComponent("must-not-exist").path))
        let cat = try await process.run(executable: "/bin/cat", input: literal)
        XCTAssertEqual(cat.stdout.data, literal)
        let empty = try await process.run(executable: "/bin/cat")
        XCTAssertEqual(empty.stdout.data, "")
    }

    func testPathEnvironmentDirectoryAndExitStatusAreReturned() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let script = fixture.base.appendingPathComponent("probe")
        try Data("#!/bin/sh\nprintf '%s' \"$AISHELL_TEST_VALUE\"\nprintf 'diagnostic' >&2\npwd\nexit 7\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let process = NativeProcessService(workingDirectory: fixture.base)
        let result = try await process.run(executable: "probe", environment: ["PATH": ".", "AISHELL_TEST_VALUE": "literal;"])
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.terminationReason, "exit")
        XCTAssertFalse(result.timedOut)
        let physicalPath = try XCTUnwrap(realpath(fixture.base.path, nil))
        defer { free(physicalPath) }
        XCTAssertEqual(result.stdout.data, "literal;" + String(cString: physicalPath) + "\n")
        XCTAssertEqual(result.stderr.data, "diagnostic")
        let relative = try await process.run(executable: "./probe")
        XCTAssertEqual(relative.exitCode, 7)
    }

    func testOutputIsNotTruncatedAndBinaryIsLossless() async throws {
        let process = NativeProcessService()
        let count = 1_048_617
        let large = try await process.run(executable: "/usr/bin/head", arguments: ["-c", String(count), "/dev/zero"])
        XCTAssertEqual(large.stdout.data.utf8.count, count)
        let binary = try await process.run(executable: "/usr/bin/printf", arguments: ["\\377\\000"])
        XCTAssertEqual(binary.stdout.encoding, "base64")
        XCTAssertEqual(Data(base64Encoded: binary.stdout.data), Data([0xFF, 0]))
    }

    func testTimeoutAndCancellationStopRequestedProcessTree() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let script = fixture.base.appendingPathComponent("delayed")
        try Data("#!/bin/sh\n(sleep 0.4; printf late > late.txt) &\nwait\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let process = NativeProcessService(workingDirectory: fixture.base)
        let timeout = try await process.run(executable: "./delayed", timeoutSeconds: 0.05)
        XCTAssertTrue(timeout.timedOut)
        let task = Task { try await process.run(executable: "./delayed") }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do { _ = try await task.value; XCTFail("中止が成功扱いになりました。") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.appendingPathComponent("late.txt").path))
    }

    func testInvalidInputAndMissingProgramFail() async throws {
        let process = NativeProcessService()
        for timeout in [0.0, -1.0, Double.infinity] {
            do {
                _ = try await process.run(executable: "/usr/bin/true", timeoutSeconds: timeout)
                XCTFail("不正なtimeoutを受理しました。")
            } catch { XCTAssertTrue(error is AIShellError) }
        }
        do {
            _ = try await process.run(executable: "aishell-fixture-missing-program", environment: ["PATH": ""])
            XCTFail("存在しないprogramが成功しました。")
        } catch { XCTAssertEqual(error as? AIShellError, .executableNotFound("aishell-fixture-missing-program")) }
    }
}
