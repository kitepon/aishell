import Darwin
import Foundation

public struct NativeProcessService: Sendable {
    private let resolver: PathResolver

    public init(workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)) {
        resolver = PathResolver(baseDirectory: workingDirectory)
    }

    public func run(executable: String, arguments: [String] = [], workingDirectory: String? = nil,
                    environment: [String: String] = [:], input: String? = nil,
                    timeoutSeconds: Double? = nil) async throws -> ProcessExecutionResult {
        guard !executable.isEmpty, !executable.contains("\0"),
              arguments.allSatisfy({ !$0.contains("\0") }),
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }),
              timeoutSeconds.map({ $0.isFinite && $0 > 0 }) ?? true else {
            throw AIShellError.invalidArgument("実行ファイル、引数、環境変数、timeout_secondsを確認してください。")
        }
        let directory = try resolver.resolveExisting(workingDirectory)
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw AIShellError.invalidPath(directory.path)
        }
        let url = try executableURL(executable, directory: directory, environment: environment)
        let task = Task.detached {
            try Self.capture(executableURL: url, arguments: arguments, directory: directory,
                             environment: environment, input: input, timeoutSeconds: timeoutSeconds)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func executableURL(_ executable: String, directory: URL, environment: [String: String]) throws -> URL {
        if executable.contains("/") {
            let url = URL(fileURLWithPath: executable, relativeTo: directory).absoluteURL
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw AIShellError.executableNotFound(executable)
            }
            return url
        }
        let path = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        for component in path.split(separator: ":", omittingEmptySubsequences: false) {
            let base = component.isEmpty ? directory : URL(fileURLWithPath: String(component), relativeTo: directory).absoluteURL
            let candidate = base.appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw AIShellError.executableNotFound(executable)
    }

    private static func capture(executableURL: URL, arguments: [String], directory: URL,
                                environment: [String: String], input: String?,
                                timeoutSeconds: Double?) throws -> ProcessExecutionResult {
        try Task.checkCancellation()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("AIShellProcess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let stdoutURL = scratch.appendingPathComponent("stdout")
        let stderrURL = scratch.appendingPathComponent("stderr")
        let stdinURL = scratch.appendingPathComponent("stdin")
        try Data().write(to: stdoutURL)
        try Data().write(to: stderrURL)
        try Data((input ?? "").utf8).write(to: stdinURL)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        let stdin = try FileHandle(forReadingFrom: stdinURL)
        defer {
            try? stdout.close()
            try? stderr.close()
            try? stdin.close()
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, value in value }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() }
        catch { throw AIShellError.processLaunchFailed(error.localizedDescription) }
        let deadline = timeoutSeconds.map { Date().addingTimeInterval($0) }
        while process.isRunning && !Task.isCancelled && (deadline.map { Date() < $0 } ?? true) {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let timedOut = process.isRunning && !Task.isCancelled
        if process.isRunning {
            let tree = freezeProcessTree(root: process.processIdentifier)
            for identity in tree.reversed() { signalIfSameProcess(identity, signal: SIGTERM) }
            for identity in tree.reversed() { signalIfSameProcess(identity, signal: SIGCONT) }
            if tree.isEmpty { process.terminate() }
            let grace = Date().addingTimeInterval(1)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
            for identity in tree.reversed() { signalIfSameProcess(identity, signal: SIGKILL) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        return ProcessExecutionResult(exitCode: process.terminationStatus,
            terminationReason: process.terminationReason == .exit ? "exit" : "signal", timedOut: timedOut,
            stdout: ProcessOutput(try Data(contentsOf: stdoutURL)), stderr: ProcessOutput(try Data(contentsOf: stderrURL)))
    }

    private struct ProcessIdentity: Hashable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    private static func freezeProcessTree(root: pid_t) -> [ProcessIdentity] {
        guard let rootIdentity = processIdentity(root) else { return [] }
        _ = Darwin.kill(root, SIGSTOP)
        var result = [rootIdentity]
        var index = 0
        var seen: Set<pid_t> = [root]
        while index < result.count {
            let parent = result[index].pid
            index += 1
            for child in childProcessIdentifiers(of: parent) where seen.insert(child).inserted {
                guard let identity = processIdentity(child) else { continue }
                _ = Darwin.kill(child, SIGSTOP)
                result.append(identity)
            }
        }
        return result
    }

    private static func childProcessIdentifiers(of parent: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var children = [pid_t](repeating: 0, count: 256)
        let returnedCount = children.withUnsafeMutableBytes { buffer in
            proc_listchildpids(parent, buffer.baseAddress, Int32(buffer.count))
        }
        guard returnedCount > 0 else { return [] }
        let count = min(Int(returnedCount), children.count)
        result.append(contentsOf: children.prefix(count).filter { $0 > 0 })
        return result
    }

    private static func processIdentity(_ pid: pid_t) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let returned = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(size))
        }
        guard returned == size else { return nil }
        return ProcessIdentity(
            pid: pid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec
        )
    }

    private static func signalIfSameProcess(_ identity: ProcessIdentity, signal: Int32) {
        guard processIdentity(identity.pid) == identity else { return }
        _ = Darwin.kill(identity.pid, signal)
    }

}
