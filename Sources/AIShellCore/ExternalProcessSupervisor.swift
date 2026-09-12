import Darwin
import Foundation

public struct ManagedRunSpoolPaths: Equatable, Sendable {
    public let directory: URL
    public let stdout: URL
    public let stderr: URL
    public let diagnostics: URL
    public let request: URL
    public let acknowledgement: URL
    public let terminal: URL
}

/// MCP adapterとは別processの`aishell-run-supervisor`を起動し、durable fileとOS identityで再接続するclient。
public actor ExternalProcessSupervisor: ProcessSupervisorSeam {
    private let runsRootURL: URL
    private let executableURL: URL

    public init(
        runtimeStore: RuntimeStore = RuntimeStore(),
        supervisorExecutableURL: URL
    ) throws {
        runsRootURL = runtimeStore.baseDirectory
            .appendingPathComponent("managed-runs", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
        executableURL = supervisorExecutableURL.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AIShellError.executableNotAllowed(executableURL.path)
        }
    }

    public func launch(_ request: ManagedSupervisorLaunchRequest) async throws -> ManagedProcessIdentity {
        let paths = paths(runID: request.runID)
        try Self.requirePrivateDirectory(paths.directory)
        try Self.createPrivateSpool(paths.stdout)
        try Self.createPrivateSpool(paths.stderr)
        try Self.createPrivateSpool(paths.diagnostics)
        let wire = ManagedRunSupervisorRequest(
            runID: request.runID,
            requestDigest: request.requestDigest,
            supervisorNonce: UUID().uuidString.lowercased(),
            executablePath: request.executableURL.path,
            arguments: request.arguments,
            workingDirectoryPath: request.workingDirectoryURL.path,
            environment: request.environment,
            timeoutDeadline: request.timeoutDeadline,
            admittedAt: request.admittedAt,
            retentionSeconds: request.retentionSeconds,
            stdoutPath: paths.stdout.path,
            stderrPath: paths.stderr.path,
            acknowledgementPath: paths.acknowledgement.path,
            terminalPath: paths.terminal.path
        )
        try Self.atomicWrite(try Self.encoder.encode(wire), to: paths.request)
        try Self.spawnSupervisor(executableURL: executableURL, requestURL: paths.request)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: paths.acknowledgement.path) {
                let acknowledgement = try Self.loadAcknowledgement(paths.acknowledgement)
                guard acknowledgement.runID == request.runID,
                      acknowledgement.identity.supervisorNonce == wire.supervisorNonce else {
                    throw ManagedRunSupervisorError.identityMismatch
                }
                return acknowledgement.identity
            }
            try await clock.sleep(for: .milliseconds(10))
        }
        throw ManagedRunSupervisorError.acknowledgementTimedOut
    }

    public func reconnect(
        runID: UUID,
        expectedIdentity: ManagedProcessIdentity
    ) throws -> ManagedProcessIdentityProof {
        let acknowledgement = try Self.loadAcknowledgement(paths(runID: runID).acknowledgement)
        guard acknowledgement.runID == runID, acknowledgement.identity == expectedIdentity,
              expectedIdentity.bootSessionIdentity == ManagedRunSupervisorWorker.bootSessionIdentity(),
              ManagedRunSupervisorWorker.processStartIdentity(
                pid: expectedIdentity.processIdentifier,
                expectedProcessGroup: expectedIdentity.processGroupIdentifier
              ) == expectedIdentity.processStartIdentity else {
            throw ManagedRunSupervisorError.identityMismatch
        }
        return ManagedProcessIdentityProof(
            runID: runID, expected: expectedIdentity, observed: acknowledgement.identity
        )
    }

    public func stop(
        runID: UUID,
        proof: ManagedProcessIdentityProof
    ) async throws -> ManagedSupervisorStopReport {
        let verified = try reconnect(runID: runID, expectedIdentity: proof.expected)
        guard verified == proof else { throw ManagedRunSupervisorError.identityMismatch }
        let group = proof.expected.processGroupIdentifier
        let termResult = Darwin.kill(-group, SIGTERM)
        let termWasSent = termResult == 0
        if termResult != 0, errno != ESRCH {
            throw ManagedRunSupervisorError.processGroupStopFailed(errno)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline, Darwin.kill(-group, 0) == 0 {
            try await clock.sleep(for: .milliseconds(20))
        }
        var killWasSent = false
        if Darwin.kill(-group, 0) == 0 {
            let result = Darwin.kill(-group, SIGKILL)
            killWasSent = result == 0
            if result != 0, errno != ESRCH {
                throw ManagedRunSupervisorError.processGroupStopFailed(errno)
            }
        }
        let killDeadline = clock.now.advanced(by: .seconds(2))
        while clock.now < killDeadline, Darwin.kill(-group, 0) == 0 {
            try await clock.sleep(for: .milliseconds(20))
        }
        return ManagedSupervisorStopReport(
            termWasSent: termWasSent,
            killWasSent: killWasSent,
            processGroupIsGone: Darwin.kill(-group, 0) != 0 && errno == ESRCH
        )
    }

    public func terminal(runID: UUID) throws -> ManagedRunSupervisorTerminal? {
        let url = paths(runID: runID).terminal
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let terminal = try Self.decoder.decode(
            ManagedRunSupervisorTerminal.self, from: Data(contentsOf: url)
        )
        guard terminal.schema == "aishell.run-supervisor-terminal.v1", terminal.runID == runID else {
            throw ManagedRunSupervisorError.invalidRequest
        }
        return terminal
    }

    public nonisolated func request(runID: UUID) throws -> ManagedRunSupervisorRequest {
        let value = try Self.decoder.decode(
            ManagedRunSupervisorRequest.self,
            from: Data(contentsOf: paths(runID: runID).request)
        )
        guard value.schema == "aishell.run-supervisor-request.v1", value.runID == runID else {
            throw ManagedRunSupervisorError.invalidRequest
        }
        return value
    }

    public nonisolated func paths(runID: UUID) -> ManagedRunSpoolPaths {
        let directory = runsRootURL.appendingPathComponent(runID.uuidString.lowercased(), isDirectory: true)
        return ManagedRunSpoolPaths(
            directory: directory,
            stdout: directory.appendingPathComponent("stdout.spool"),
            stderr: directory.appendingPathComponent("stderr.spool"),
            diagnostics: directory.appendingPathComponent("diagnostics.spool"),
            request: directory.appendingPathComponent("supervisor-request.json"),
            acknowledgement: directory.appendingPathComponent("supervisor-ack.json"),
            terminal: directory.appendingPathComponent("supervisor-terminal.json")
        )
    }

    private static func spawnSupervisor(executableURL: URL, requestURL: URL) throws {
        let values = [executableURL.path, "--request", requestURL.path]
        var argv = values.map { strdup($0) } + [nil]
        defer { argv.dropLast().forEach { free($0) } }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        let null = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
        guard null >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(null) }
        posix_spawn_file_actions_adddup2(&actions, null, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, null, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, null, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, null)
        var processIdentifier: pid_t = 0
        let result = executableURL.path.withCString { executable in
            argv.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(&processIdentifier, executable, &actions, nil, buffer.baseAddress, environ)
            }
        }
        guard result == 0 else { throw ManagedRunSupervisorError.launchFailed(result) }
        let sidecarProcessIdentifier = processIdentifier
        _ = Task.detached {
            var status: Int32 = 0
            while waitpid(sidecarProcessIdentifier, &status, 0) == -1, errno == EINTR {}
        }
    }

    private static func loadAcknowledgement(_ url: URL) throws -> ManagedRunSupervisorAcknowledgement {
        let value = try decoder.decode(
            ManagedRunSupervisorAcknowledgement.self, from: Data(contentsOf: url)
        )
        guard value.schema == "aishell.run-supervisor-ack.v1" else {
            throw ManagedRunSupervisorError.invalidRequest
        }
        return value
    }

    private static func createPrivateSpool(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path),
              FileManager.default.createFile(
                atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]
              ) else { throw ManagedRunSupervisorError.unsafePath(url.path) }
    }

    private static func requirePrivateDirectory(_ url: URL) throws {
        var information = stat()
        guard lstat(url.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR,
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
