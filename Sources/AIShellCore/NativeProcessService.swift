import Darwin
import Foundation

public actor NativeProcessService {
    public static let maximumOutputBytes = 1_048_576
    public static let maximumTimeoutSeconds = 3_600.0

    private let store: RuntimeStore

    public init(store: RuntimeStore = RuntimeStore()) {
        self.store = store
    }

    public func prepareManagedInvocation(
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String] = [:]
    ) async throws -> PreparedProcessInvocation {
        let resolver = try await activeResolver()
        let directory = try resolver.resolveExisting(workingDirectory)
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw AIShellError.invalidPath(directory.path)
        }
        return PreparedProcessInvocation(
            executableURL: try validateExecutable(
                executable, environment: environment, workingDirectory: directory
            ),
            arguments: arguments,
            workingDirectoryURL: directory,
            environment: environment
        )
    }

    public func run(
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        timeoutSeconds: Double = 120
    ) async throws -> ProcessExecutionResult {
        try await audited(operation: "process.run", target: executable) {
            let resolver = try await activeResolver()
            let directory = try resolver.resolveExisting(workingDirectory)
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw AIShellError.invalidPath(directory.path)
            }

            let executableURL = try validateExecutable(
                executable,
                environment: environment,
                workingDirectory: directory
            )
            let timeout = min(max(timeoutSeconds, 0.1), Self.maximumTimeoutSeconds)
            return try Self.runSynchronously(
                executableURL: executableURL,
                arguments: arguments,
                workingDirectory: directory,
                environment: environment,
                timeoutSeconds: timeout
            )
        }
    }

    public func runRetained(
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        timeoutSeconds: Double = 120,
        evidenceStore: EvidenceStore,
        retentionSeconds: TimeInterval = EvidenceStore.defaultRetentionSeconds
    ) async throws -> RetainedProcessExecution {
        try await audited(operation: "process.runRetained", target: executable) {
            let resolver = try await activeResolver()
            let directory = try resolver.resolveExisting(workingDirectory)
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw AIShellError.invalidPath(directory.path)
            }

            let executableURL = try validateExecutable(
                executable,
                environment: environment,
                workingDirectory: directory
            )
            let timeout = min(max(timeoutSeconds, 0.1), Self.maximumTimeoutSeconds)
            let capture = try Self.captureSynchronously(
                executableURL: executableURL,
                arguments: arguments,
                workingDirectory: directory,
                environment: environment,
                timeoutSeconds: timeout
            )
            defer { try? FileManager.default.removeItem(at: capture.scratchURL) }

            let stdoutArtifact = try await evidenceStore.store(
                fileAt: capture.stdoutURL,
                kind: "stdout",
                producer: "run_check:\(capture.processIdentifier)",
                retentionSeconds: retentionSeconds
            )
            let stderrArtifact: ArtifactMetadata
            do {
                stderrArtifact = try await evidenceStore.store(
                    fileAt: capture.stderrURL,
                    kind: "stderr",
                    producer: "run_check:\(capture.processIdentifier)",
                    retentionSeconds: retentionSeconds
                )
            } catch {
                await evidenceStore.discard(handle: stdoutArtifact.handle)
                throw error
            }

            return RetainedProcessExecution(
                executable: executableURL.path,
                arguments: arguments,
                workingDirectory: directory.path,
                processIdentifier: capture.processIdentifier,
                exitCode: capture.exitCode,
                terminationReason: capture.terminationReason,
                timedOut: capture.timedOut,
                durationMilliseconds: capture.durationMilliseconds,
                stdoutArtifact: stdoutArtifact,
                stderrArtifact: stderrArtifact
            )
        }
    }

    private func activeResolver() async throws -> PathResolver {
        let configuration = try await store.loadConfiguration()
        guard !configuration.isPaused else { throw AIShellError.paused }
        return await store.pathResolver()
    }

    private func validateExecutable(
        _ executable: String,
        environment: [String: String],
        workingDirectory: URL
    ) throws -> URL {
        let candidate: String
        if executable.hasPrefix("/") {
            candidate = executable
        } else {
            guard !executable.isEmpty, !executable.contains("/") else {
                throw AIShellError.executableNotAllowed(executable)
            }
            let path = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
            guard let resolved = path.split(separator: ":", omittingEmptySubsequences: false)
                .map(String.init)
                .map({ component -> String in
                    let directory = component.hasPrefix("/")
                        ? URL(fileURLWithPath: component, isDirectory: true)
                        : workingDirectory.appendingPathComponent(component, isDirectory: true)
                    return directory.appendingPathComponent(executable).path
                })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            else {
                throw AIShellError.executableNotAllowed("PATH上に見つかりません: \(executable)")
            }
            candidate = resolved
        }

        let url = URL(fileURLWithPath: candidate).standardizedFileURL.resolvingSymlinksInPath()
        let blockedNames: Set<String> = [
            "sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish", "env", "osascript"
        ]
        guard !blockedNames.contains(url.lastPathComponent),
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw AIShellError.executableNotAllowed(url.path)
        }
        return url
    }

    private nonisolated static func runSynchronously(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        timeoutSeconds: Double
    ) throws -> ProcessExecutionResult {
        let capture = try captureSynchronously(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            timeoutSeconds: timeoutSeconds
        )
        defer { try? FileManager.default.removeItem(at: capture.scratchURL) }
        let stdoutRead = try readOutput(from: capture.stdoutURL)
        let stderrRead = try readOutput(from: capture.stderrURL)

        return ProcessExecutionResult(
            executable: executableURL.path,
            arguments: arguments,
            workingDirectory: workingDirectory.path,
            exitCode: capture.exitCode,
            terminationReason: capture.terminationReason,
            timedOut: capture.timedOut,
            durationMilliseconds: capture.durationMilliseconds,
            stdout: stdoutRead.text,
            stderr: stderrRead.text,
            stdoutTruncated: stdoutRead.truncated,
            stderrTruncated: stderrRead.truncated
        )
    }

    private struct ProcessCapture: Sendable {
        let scratchURL: URL
        let stdoutURL: URL
        let stderrURL: URL
        let processIdentifier: Int32
        let exitCode: Int32
        let terminationReason: String
        let timedOut: Bool
        let durationMilliseconds: Int
    }

    private nonisolated static func captureSynchronously(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        timeoutSeconds: Double
    ) throws -> ProcessCapture {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIShellProcess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var shouldRemoveScratch = true
        defer {
            if shouldRemoveScratch { try? FileManager.default.removeItem(at: scratch) }
        }

        let stdoutURL = scratch.appendingPathComponent("stdout")
        let stderrURL = scratch.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        let startedAt = Date()
        do {
            try process.run()
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            throw AIShellError.processLaunchFailed(error.localizedDescription)
        }

        let deadline = startedAt.addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        var timedOut = false
        if process.isRunning {
            timedOut = true
            let processTree = freezeProcessTree(root: process.processIdentifier)
            if processTree.isEmpty {
                process.terminate()
            } else {
                for identity in processTree.reversed() { signalIfSameProcess(identity, signal: SIGTERM) }
                for identity in processTree.reversed() { signalIfSameProcess(identity, signal: SIGCONT) }
            }
            let gracefulDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < gracefulDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                if let rootIdentity = processIdentity(process.processIdentifier) {
                    signalIfSameProcess(rootIdentity, signal: SIGKILL)
                } else {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
            for identity in processTree.reversed() { signalIfSameProcess(identity, signal: SIGKILL) }
        }
        process.waitUntilExit()
        try stdoutHandle.close()
        try stderrHandle.close()

        let duration = Int(Date().timeIntervalSince(startedAt) * 1_000)
        shouldRemoveScratch = false
        return ProcessCapture(
            scratchURL: scratch,
            stdoutURL: stdoutURL,
            stderrURL: stderrURL,
            processIdentifier: process.processIdentifier,
            exitCode: process.terminationStatus,
            terminationReason: process.terminationReason == .exit ? "exit" : "signal",
            timedOut: timedOut,
            durationMilliseconds: duration
        )
    }

    private nonisolated static func readOutput(from url: URL) throws -> (text: String, truncated: Bool) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumOutputBytes + 1) ?? Data()
        let truncated = data.count > maximumOutputBytes
        return (
            String(decoding: data.prefix(maximumOutputBytes), as: UTF8.self),
            truncated
        )
    }

    private struct ProcessIdentity: Hashable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    private nonisolated static func freezeProcessTree(root: pid_t) -> [ProcessIdentity] {
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

    private nonisolated static func childProcessIdentifiers(of parent: pid_t) -> [pid_t] {
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

    private nonisolated static func processIdentity(_ pid: pid_t) -> ProcessIdentity? {
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

    private nonisolated static func signalIfSameProcess(_ identity: ProcessIdentity, signal: Int32) {
        guard processIdentity(identity.pid) == identity else { return }
        _ = Darwin.kill(identity.pid, signal)
    }

    private func audited<T: Sendable>(
        operation: String,
        target: String,
        body: () async throws -> T
    ) async throws -> T {
        do {
            let result = try await body()
            try? await store.appendActivity(OperationRecord(
                operation: operation,
                target: target,
                success: true,
                message: "完了"
            ))
            return result
        } catch {
            try? await store.appendActivity(OperationRecord(
                operation: operation,
                target: target,
                success: false,
                message: error.localizedDescription
            ))
            throw error
        }
    }
}
