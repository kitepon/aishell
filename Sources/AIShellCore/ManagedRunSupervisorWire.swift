import Darwin
import Foundation

public struct ManagedRunSupervisorRequest: Codable, Equatable, Sendable {
    public let schema: String
    public let runID: UUID
    public let requestDigest: String
    public let supervisorNonce: String
    public let executablePath: String
    public let arguments: [String]
    public let workingDirectoryPath: String
    public let environment: [String: String]
    public let timeoutDeadline: Date?
    public let admittedAt: Date
    public let retentionSeconds: TimeInterval
    public let stdoutPath: String
    public let stderrPath: String
    public let acknowledgementPath: String
    public let terminalPath: String

    public init(
        runID: UUID,
        requestDigest: String,
        supervisorNonce: String,
        executablePath: String,
        arguments: [String],
        workingDirectoryPath: String,
        environment: [String: String],
        timeoutDeadline: Date?,
        admittedAt: Date,
        retentionSeconds: TimeInterval,
        stdoutPath: String,
        stderrPath: String,
        acknowledgementPath: String,
        terminalPath: String
    ) {
        schema = "aishell.run-supervisor-request.v1"
        self.runID = runID
        self.requestDigest = requestDigest
        self.supervisorNonce = supervisorNonce
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectoryPath = workingDirectoryPath
        self.environment = environment
        self.timeoutDeadline = timeoutDeadline
        self.admittedAt = admittedAt
        self.retentionSeconds = retentionSeconds
        self.stdoutPath = stdoutPath
        self.stderrPath = stderrPath
        self.acknowledgementPath = acknowledgementPath
        self.terminalPath = terminalPath
    }
}

public struct ManagedRunSupervisorAcknowledgement: Codable, Equatable, Sendable {
    public let schema: String
    public let runID: UUID
    public let supervisorProcessIdentifier: Int32
    public let identity: ManagedProcessIdentity

    public init(runID: UUID, supervisorProcessIdentifier: Int32, identity: ManagedProcessIdentity) {
        schema = "aishell.run-supervisor-ack.v1"
        self.runID = runID
        self.supervisorProcessIdentifier = supervisorProcessIdentifier
        self.identity = identity
    }
}

public struct ManagedRunSupervisorTerminal: Codable, Equatable, Sendable {
    public let schema: String
    public let runID: UUID
    public let exitCode: Int32
    public let signal: Int32?
    public let timedOut: Bool
    public let observedAt: Date

    public init(runID: UUID, exitCode: Int32, signal: Int32?, timedOut: Bool, observedAt: Date) {
        schema = "aishell.run-supervisor-terminal.v1"
        self.runID = runID
        self.exitCode = exitCode
        self.signal = signal
        self.timedOut = timedOut
        self.observedAt = observedAt
    }
}

public enum ManagedRunSupervisorError: Error, Equatable, Sendable {
    case invalidRequest
    case unsafePath(String)
    case launchFailed(Int32)
    case identityUnavailable
    case acknowledgementTimedOut
    case identityMismatch
    case processGroupStopFailed(Int32)
}

public enum ManagedRunSupervisorWorker {
    /// sidecar processの唯一の入口。対象processを新process groupへspawnし、reapとspool fsyncまで所有する。
    public static func run(requestURL: URL) throws {
        try requirePrivateRegularFile(requestURL)
        let request = try decoder.decode(ManagedRunSupervisorRequest.self, from: Data(contentsOf: requestURL))
        guard request.schema == "aishell.run-supervisor-request.v1",
              request.executablePath.hasPrefix("/"), request.workingDirectoryPath.hasPrefix("/"),
              request.stdoutPath.hasPrefix("/"), request.stderrPath.hasPrefix("/"),
              request.acknowledgementPath.hasPrefix("/"), request.terminalPath.hasPrefix("/") else {
            throw ManagedRunSupervisorError.invalidRequest
        }
        let requestDirectory = requestURL.deletingLastPathComponent().standardizedFileURL.path
        for path in [request.stdoutPath, request.stderrPath, request.acknowledgementPath, request.terminalPath] {
            guard URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path == requestDirectory else {
                throw ManagedRunSupervisorError.unsafePath(path)
            }
        }

        let stdout = try openSpool(request.stdoutPath)
        defer { Darwin.close(stdout) }
        let stderr = try openSpool(request.stderrPath)
        defer { Darwin.close(stderr) }
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attributes)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawn_file_actions_addchdir_np(&actions, request.workingDirectoryPath)
        posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, stdout)
        posix_spawn_file_actions_addclose(&actions, stderr)

        let argumentValues = [request.executablePath] + request.arguments
        var argv = argumentValues.map { strdup($0) } + [nil]
        defer { argv.dropLast().forEach { free($0) } }
        let environmentValues = ProcessInfo.processInfo.environment
            .merging(request.environment) { _, override in override }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        var envp = environmentValues.map { strdup($0) } + [nil]
        defer { envp.dropLast().forEach { free($0) } }
        var processIdentifier: pid_t = 0
        let result = request.executablePath.withCString { executable in
            argv.withUnsafeMutableBufferPointer { argumentBuffer in
                envp.withUnsafeMutableBufferPointer { environmentBuffer in
                    posix_spawn(
                        &processIdentifier, executable, &actions, &attributes,
                        argumentBuffer.baseAddress, environmentBuffer.baseAddress
                    )
                }
            }
        }
        guard result == 0 else { throw ManagedRunSupervisorError.launchFailed(result) }
        guard let startIdentity = processStartIdentity(
            pid: processIdentifier, expectedProcessGroup: processIdentifier
        ) else {
            _ = Darwin.kill(-processIdentifier, SIGKILL)
            throw ManagedRunSupervisorError.identityUnavailable
        }
        let identity = ManagedProcessIdentity(
            processIdentifier: processIdentifier,
            processStartIdentity: startIdentity,
            processGroupIdentifier: processIdentifier,
            bootSessionIdentity: bootSessionIdentity(),
            supervisorNonce: request.supervisorNonce
        )
        try atomicWrite(
            try encoder.encode(ManagedRunSupervisorAcknowledgement(
                runID: request.runID,
                supervisorProcessIdentifier: getpid(),
                identity: identity
            )),
            to: URL(fileURLWithPath: request.acknowledgementPath)
        )

        var status: Int32 = 0
        var timedOut = false
        var termSentAt: Date?
        while true {
            let result = waitpid(processIdentifier, &status, WNOHANG)
            if result == processIdentifier { break }
            if result == -1, errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let now = Date()
            if !timedOut, let deadline = request.timeoutDeadline, now >= deadline {
                timedOut = true
                termSentAt = now
                _ = Darwin.kill(-processIdentifier, SIGTERM)
            } else if timedOut, let termSentAt, now.timeIntervalSince(termSentAt) >= 1 {
                _ = Darwin.kill(-processIdentifier, SIGKILL)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard Darwin.fsync(stdout) == 0, Darwin.fsync(stderr) == 0 else { throw POSIXError(.EIO) }
        let waitKind = status & 0x7f
        let signal: Int32? = waitKind != 0 && waitKind != 0x7f ? waitKind : nil
        let exitCode = waitKind == 0 ? (status >> 8) & 0xff : 128 + (signal ?? 0)
        try atomicWrite(
            try encoder.encode(ManagedRunSupervisorTerminal(
                runID: request.runID, exitCode: exitCode, signal: signal,
                timedOut: timedOut, observedAt: Date()
            )),
            to: URL(fileURLWithPath: request.terminalPath)
        )
    }

    public static func processStartIdentity(pid: pid_t, expectedProcessGroup: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let returned = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(size))
        }
        guard returned == size, getpgid(pid) == expectedProcessGroup else { return nil }
        return "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }

    public static func bootSessionIdentity() -> String {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return "unavailable" }
        return "\(boot.tv_sec):\(boot.tv_usec)"
    }

    private static func openSpool(_ path: String) throws -> Int32 {
        let descriptor = Darwin.open(path, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ManagedRunSupervisorError.unsafePath(path) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(), information.st_mode & 0o077 == 0 else {
            Darwin.close(descriptor)
            throw ManagedRunSupervisorError.unsafePath(path)
        }
        return descriptor
    }

    private static func requirePrivateRegularFile(_ url: URL) throws {
        var information = stat()
        guard lstat(url.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(), information.st_mode & 0o077 == 0 else {
            throw ManagedRunSupervisorError.unsafePath(url.path)
        }
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        try FileManager.default.moveItem(at: temporary, to: url)
        let directory = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(directory) }
        guard Darwin.fsync(directory) == 0 else { throw POSIXError(.EIO) }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
