import CryptoKit
import Darwin
import Foundation
import Security

public enum ManagedRunServiceError: Error, Equatable, Sendable {
    case invalidCursor
    case cursorRunMismatch
    case cursorAhead
    case spoolCorrupt
}

public struct ManagedRunStatusResult: Codable, Equatable, Sendable {
    public let schema: String
    public let runHandle: String
    public let runID: UUID
    public let state: String
    public let stateRevision: UInt64
    public let evidenceCursor: String
    public let stdoutBytes: UInt64
    public let stderrBytes: UInt64
    public let diagnosticBytes: UInt64
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String
    public let environmentDigest: String
    public let startedAt: Date
    public let timeoutDeadline: Date?
    public let retentionSeconds: TimeInterval
    public let terminationCause: String?
    /// Terminal exit code for natural_exit runs. The caller confirms and restates the outcome from
    /// this result state instead of reconstructing it from artifacts; nil while the run is live or
    /// when the run never reached a natural exit.
    public let exitCode: Int32?
    /// Terminating signal for natural_exit runs, when the process died by signal.
    public let signal: Int32?
    /// Whether a cancellation was accepted as this run's terminal cause. False on other terminal
    /// causes, nil while the run is still live.
    public let cancelAcknowledged: Bool?
    public let stdoutArtifact: ManagedArtifactIdentity?
    public let stderrArtifact: ManagedArtifactIdentity?
    public let diagnosticArtifact: ManagedArtifactIdentity?
    public let expiresAt: Date?
}

public struct ManagedRunStartResult: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let dispatch: String
    public let planDigest: String
    public let runHandle: String
    public let runID: UUID
    public let state: String
    public let stateRevision: UInt64
    public let evidenceCursor: String
    public let stdoutBytes: UInt64
    public let stderrBytes: UInt64
    public let diagnosticBytes: UInt64
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String
    public let environmentDigest: String
    public let startedAt: Date
    public let timeoutDeadline: Date?
    public let retentionSeconds: TimeInterval
    public let terminationCause: String?
    public let stdoutArtifact: ManagedArtifactIdentity?
    public let stderrArtifact: ManagedArtifactIdentity?
    public let diagnosticArtifact: ManagedArtifactIdentity?
    public let expiresAt: Date?
}

public struct ManagedRunEvidenceChunk: Codable, Equatable, Sendable {
    public let channel: String
    public let offset: UInt64
    public let returnedBytes: Int
    public let encoding: String
    public let text: String?
    public let base64: String?
}

public struct ManagedRunReadResult: Codable, Equatable, Sendable {
    public let schema: String
    public let status: ManagedRunStatusResult
    public let chunks: [ManagedRunEvidenceChunk]
    public let cursor: String
    public let hasMore: Bool
    public let omittedBytes: UInt64
}

public enum ManagedRunWaitOutcome: String, Codable, Equatable, Sendable {
    case changed
    case timedOut = "timed_out"
}

public struct ManagedRunWaitResult: Codable, Equatable, Sendable {
    public let schema: String
    public let outcome: ManagedRunWaitOutcome
    public let status: ManagedRunStatusResult
}

/// managed registry、sidecar、live spool、atomic artifact publicationを一つのCore domain APIへ束縛する。
public actor ManagedRunService {
    private let processes: NativeProcessService
    private let supervisor: ExternalProcessSupervisor
    private let registry: ManagedProcessRegistry
    private let artifacts: ManagedRunArtifactStore
    private let artifactQueries: ManagedArtifactQueryService
    private let cursorKey: SymmetricKey

    public init(
        runtimeStore: RuntimeStore = RuntimeStore(),
        supervisorExecutableURL: URL
    ) throws {
        processes = NativeProcessService(store: runtimeStore)
        let supervisor = try ExternalProcessSupervisor(
            runtimeStore: runtimeStore,
            supervisorExecutableURL: supervisorExecutableURL
        )
        self.supervisor = supervisor
        registry = try ManagedProcessRegistry(store: runtimeStore, supervisor: supervisor)
        let artifacts = try ManagedRunArtifactStore(runtimeStore: runtimeStore)
        self.artifacts = artifacts
        artifactQueries = ManagedArtifactQueryService(store: artifacts)
        cursorKey = SymmetricKey(data: try Self.loadOrCreateCursorKey(runtimeStore: runtimeStore))
    }

    public func recoverAfterAdapterRestart() async throws -> [ManagedProcessRecoveryResult] {
        try await registry.recoverAfterServerRestart()
    }

    public func start(
        clientRunKey: String,
        requestDigest: String,
        planDigest: String? = nil,
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        timeoutSeconds: Double,
        retentionSeconds: TimeInterval
    ) async throws -> ManagedRunStartResult {
        guard timeoutSeconds.isFinite, (0.1 ... 3_600).contains(timeoutSeconds) else {
            throw AIShellError.invalidArgument("timeout_secondsは0.1〜3600の有限値である必要があります。")
        }
        let invocation = try await processes.prepareManagedInvocation(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment
        )
        let admittedAt = Date()
        let timeoutDeadline = admittedAt.addingTimeInterval(timeoutSeconds)
        let registration = try await registry.start(
            clientRunKey: clientRunKey,
            requestDigest: requestDigest,
            executableURL: invocation.executableURL,
            arguments: invocation.arguments,
            workingDirectoryURL: invocation.workingDirectoryURL,
            environment: invocation.environment,
            timeoutDeadline: timeoutDeadline,
            admittedAt: admittedAt,
            retentionSeconds: retentionSeconds
        )
        let status = try await status(runHandle: registration.runHandle)
        return ManagedRunStartResult(
            schemaVersion: "aishell.run-check.v2",
            dispatch: "start",
            planDigest: planDigest ?? requestDigest,
            runHandle: status.runHandle,
            runID: status.runID,
            state: status.state,
            stateRevision: status.stateRevision,
            evidenceCursor: status.evidenceCursor,
            stdoutBytes: status.stdoutBytes,
            stderrBytes: status.stderrBytes,
            diagnosticBytes: status.diagnosticBytes,
            executable: status.executable,
            arguments: status.arguments,
            workingDirectory: status.workingDirectory,
            environmentDigest: status.environmentDigest,
            startedAt: status.startedAt,
            timeoutDeadline: status.timeoutDeadline,
            retentionSeconds: status.retentionSeconds,
            terminationCause: status.terminationCause,
            stdoutArtifact: status.stdoutArtifact,
            stderrArtifact: status.stderrArtifact,
            diagnosticArtifact: status.diagnosticArtifact,
            expiresAt: status.expiresAt
        )
    }

    public func status(runHandle: String) async throws -> ManagedRunStatusResult {
        let snapshot = try await refresh(runHandle: runHandle)
        return try statusResult(runHandle: runHandle, snapshot: snapshot)
    }

    public func read(
        runHandle: String,
        cursor: String? = nil,
        byteBudget: Int = 65_536
    ) async throws -> ManagedRunReadResult {
        let snapshot = try await refresh(runHandle: runHandle)
        let status = try statusResult(runHandle: runHandle, snapshot: snapshot)
        let start = try cursor.map(decodeCursor) ?? CursorPayload(
            runID: snapshot.runID, stdoutOffset: 0, stderrOffset: 0, diagnosticOffset: 0
        )
        guard start.runID == snapshot.runID else { throw ManagedRunServiceError.cursorRunMismatch }
        let paths = supervisor.paths(runID: snapshot.runID)
        let sizes = try spoolSizes(paths)
        guard start.stdoutOffset <= sizes.stdout,
              start.stderrOffset <= sizes.stderr,
              start.diagnosticOffset <= sizes.diagnostics else {
            throw ManagedRunServiceError.cursorAhead
        }
        var remaining = min(max(1, byteBudget), 1_048_576)
        var chunks: [ManagedRunEvidenceChunk] = []
        var next = start
        for (channel, url, offset, size) in [
            ("stdout", paths.stdout, start.stdoutOffset, sizes.stdout),
            ("stderr", paths.stderr, start.stderrOffset, sizes.stderr),
            ("diagnostics", paths.diagnostics, start.diagnosticOffset, sizes.diagnostics)
        ] where remaining > 0 && offset < size {
            let count = min(remaining, Int(size - offset))
            let data = try Self.readRange(url, offset: offset, count: count)
            chunks.append(Self.chunk(channel: channel, offset: offset, data: data))
            remaining -= data.count
            switch channel {
            case "stdout": next.stdoutOffset += UInt64(data.count)
            case "stderr": next.stderrOffset += UInt64(data.count)
            default: next.diagnosticOffset += UInt64(data.count)
            }
        }
        let omitted = (sizes.stdout - next.stdoutOffset)
            + (sizes.stderr - next.stderrOffset)
            + (sizes.diagnostics - next.diagnosticOffset)
        return ManagedRunReadResult(
            schema: "aishell.run-observe-read.v1",
            status: status,
            chunks: chunks,
            cursor: try encodeCursor(next),
            hasMore: omitted > 0,
            omittedBytes: omitted
        )
    }

    public func wait(
        runHandle: String,
        afterStateRevision: UInt64,
        cursor: String? = nil,
        timeoutMilliseconds: Int
    ) async throws -> ManagedRunWaitResult {
        guard (1 ... 300_000).contains(timeoutMilliseconds) else {
            throw AIShellError.invalidArgument("timeout_msは1〜300000である必要があります。")
        }
        let expectedCursor = try cursor.map(decodeCursor)
        if let expectedCursor {
            let observedRunID = try await registry.observe(runHandle: runHandle).runID
            guard expectedCursor.runID == observedRunID else {
                throw ManagedRunServiceError.cursorRunMismatch
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(timeoutMilliseconds))
        while true {
            try Task.checkCancellation()
            let snapshot = try await refresh(runHandle: runHandle)
            let status = try statusResult(runHandle: runHandle, snapshot: snapshot)
            let cursorChanged = expectedCursor.map {
                $0.stdoutOffset != status.stdoutBytes
                    || $0.stderrOffset != status.stderrBytes
                    || $0.diagnosticOffset != status.diagnosticBytes
            } ?? false
            if snapshot.stateRevision > afterStateRevision || cursorChanged || snapshot.state.isTerminal {
                return ManagedRunWaitResult(
                    schema: "aishell.run-observe-wait.v1", outcome: .changed, status: status
                )
            }
            guard clock.now < deadline else {
                return ManagedRunWaitResult(
                    schema: "aishell.run-observe-wait.v1", outcome: .timedOut, status: status
                )
            }
            try await clock.sleep(for: .milliseconds(20))
        }
    }

    public func cancel(runHandle: String) async throws -> ManagedRunStatusResult {
        let current = try await refresh(runHandle: runHandle)
        if current.state.isTerminal {
            return try statusResult(runHandle: runHandle, snapshot: current)
        }
        _ = try await registry.cancel(runHandle: runHandle)
        return try await status(runHandle: runHandle)
    }

    public func searchArtifacts(
        projectPath: String,
        sources: [ManagedArtifactQuerySource],
        pattern: ArtifactQueryService.Pattern,
        pageByteLimit: Int
    ) async throws -> ManagedArtifactQueryPage {
        try await artifactQueries.search(
            projectPath: projectPath,
            sources: sources,
            pattern: pattern,
            pageByteLimit: pageByteLimit
        )
    }

    public func continueArtifactSearch(
        streamHandle: String,
        cursor: String,
        pageByteLimit: Int
    ) async throws -> ManagedArtifactQueryPage {
        try await artifactQueries.next(
            streamHandle: streamHandle, cursor: cursor, pageByteLimit: pageByteLimit
        )
    }

    public func compareArtifacts(
        projectPath: String,
        baselineRunID: UUID,
        candidateRunID: UUID,
        channels: Set<String>
    ) async throws -> ManagedArtifactCompareResult {
        try await artifactQueries.compare(
            projectPath: projectPath,
            baselineRunID: baselineRunID,
            candidateRunID: candidateRunID,
            channels: channels
        )
    }

    private func refresh(runHandle: String) async throws -> ManagedRunSnapshot {
        var snapshot = try await registry.observe(runHandle: runHandle)
        let paths = supervisor.paths(runID: snapshot.runID)
        if FileManager.default.fileExists(atPath: paths.stdout.path),
           FileManager.default.fileExists(atPath: paths.stderr.path),
           FileManager.default.fileExists(atPath: paths.diagnostics.path) {
            let sizes = try spoolSizes(paths)
            guard sizes.stdout >= snapshot.cursor.stdoutOffset,
                  sizes.stderr >= snapshot.cursor.stderrOffset,
                  sizes.diagnostics >= snapshot.cursor.diagnosticOffset else {
                throw ManagedRunServiceError.spoolCorrupt
            }
            let stdoutDelta = Int(sizes.stdout - snapshot.cursor.stdoutOffset)
            let stderrDelta = Int(sizes.stderr - snapshot.cursor.stderrOffset)
            let diagnosticDelta = Int(sizes.diagnostics - snapshot.cursor.diagnosticOffset)
            if stdoutDelta + stderrDelta + diagnosticDelta > 0 {
                _ = try await registry.recordEvidence(
                    runHandle: runHandle,
                    stdoutBytes: stdoutDelta,
                    stderrBytes: stderrDelta,
                    diagnosticBytes: diagnosticDelta
                )
                snapshot = try await registry.observe(runHandle: runHandle)
            }
        }
        if !snapshot.state.isTerminal,
           let terminal = try await supervisor.terminal(runID: snapshot.runID) {
            if terminal.timedOut, snapshot.terminationCause == nil {
                snapshot = try await registry.record(
                    runHandle: runHandle,
                    event: .timeout(deadline: terminal.observedAt)
                )
            }
            if snapshot.state != .finalizing {
                snapshot = try await registry.record(
                    runHandle: runHandle,
                    event: .naturalExit(exitCode: terminal.exitCode, signal: terminal.signal)
                )
            }
        }
        if snapshot.state == .finalizing, snapshot.finalization == nil {
            let wire = try Self.loadRequest(paths.request)
            let finalizedAt = (try await supervisor.terminal(runID: snapshot.runID))?.observedAt ?? Date()
            await artifacts.prepare(
                runID: snapshot.runID,
                requestDigest: wire.requestDigest,
                projectID: try ManagedArtifactQueryService.projectID(path: wire.workingDirectoryPath),
                executablePath: wire.executablePath,
                arguments: wire.arguments,
                workingDirectoryPath: wire.workingDirectoryPath,
                environmentDigest: try Self.environmentDigest(wire.environment),
                expiresAt: finalizedAt.addingTimeInterval(wire.retentionSeconds),
                stdoutURL: paths.stdout,
                stderrURL: paths.stderr,
                diagnosticURL: paths.diagnostics
            )
            let inspection = try await artifacts.fsyncAndInspect(
                stdoutURL: paths.stdout, stderrURL: paths.stderr
            )
            let diagnosticData = try Data(contentsOf: paths.diagnostics, options: .mappedIfSafe)
            let diagnostics = ManagedArtifactIdentity(
                handle: "run_\(snapshot.runID.uuidString.replacingOccurrences(of: "-", with: "").lowercased())_diagnostics",
                sizeBytes: UInt64(diagnosticData.count),
                lineCount: UInt64(diagnosticData.reduce(0) { $1 == 0x0a ? $0 + 1 : $0 }),
                sha256: Self.sha256(diagnosticData)
            )
            let bundle = try await artifacts.publishAtomically(
                inspection: inspection, diagnostics: diagnostics,
                finalizedAt: finalizedAt
            )
            snapshot = try await registry.record(
                runHandle: runHandle, event: .commitFinalization(bundle)
            )
        }
        return snapshot
    }

    private func statusResult(
        runHandle: String,
        snapshot: ManagedRunSnapshot
    ) throws -> ManagedRunStatusResult {
        let request = try supervisor.request(runID: snapshot.runID)
        let cursor = try encodeCursor(CursorPayload(
            runID: snapshot.runID,
            stdoutOffset: snapshot.cursor.stdoutOffset,
            stderrOffset: snapshot.cursor.stderrOffset,
            diagnosticOffset: snapshot.cursor.diagnosticOffset
        ))
        return ManagedRunStatusResult(
            schema: "aishell.run-observe-status.v1",
            runHandle: runHandle,
            runID: snapshot.runID,
            state: snapshot.state.rawValue,
            stateRevision: snapshot.stateRevision,
            evidenceCursor: cursor,
            stdoutBytes: snapshot.cursor.stdoutOffset,
            stderrBytes: snapshot.cursor.stderrOffset,
            diagnosticBytes: snapshot.cursor.diagnosticOffset,
            executable: request.executablePath,
            arguments: request.arguments,
            workingDirectory: request.workingDirectoryPath,
            environmentDigest: try Self.environmentDigest(request.environment),
            startedAt: request.admittedAt,
            timeoutDeadline: request.timeoutDeadline,
            retentionSeconds: request.retentionSeconds,
            terminationCause: Self.cause(snapshot.terminationCause),
            exitCode: Self.exitCode(snapshot.terminationCause),
            signal: Self.signal(snapshot.terminationCause),
            cancelAcknowledged: Self.cancelAcknowledged(snapshot.terminationCause),
            stdoutArtifact: snapshot.finalization?.stdout,
            stderrArtifact: snapshot.finalization?.stderr,
            diagnosticArtifact: snapshot.finalization?.diagnostics,
            expiresAt: snapshot.expiresAt
        )
    }

    private static func exitCode(_ value: ManagedTerminationCause?) -> Int32? {
        if case let .naturalExit(exitCode, _) = value { return exitCode }
        return nil
    }

    private static func signal(_ value: ManagedTerminationCause?) -> Int32? {
        if case let .naturalExit(_, signal) = value { return signal }
        return nil
    }

    private static func cancelAcknowledged(_ value: ManagedTerminationCause?) -> Bool? {
        guard let value else { return nil }
        if case .cancellation = value { return true }
        return false
    }

    private static func environmentDigest(_ environment: [String: String]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sha256(try encoder.encode(environment))
    }

    private struct CursorPayload: Codable {
        let runID: UUID
        var stdoutOffset: UInt64
        var stderrOffset: UInt64
        var diagnosticOffset: UInt64
    }

    private struct SignedCursor: Codable {
        let payload: CursorPayload
        let signature: String
    }

    private func encodeCursor(_ payload: CursorPayload) throws -> String {
        let payloadData = try Self.encoder.encode(payload)
        let signature = Data(HMAC<SHA256>.authenticationCode(for: payloadData, using: cursorKey))
            .base64EncodedString()
        return try Self.encoder.encode(SignedCursor(payload: payload, signature: signature))
            .base64EncodedString()
    }

    private func decodeCursor(_ value: String) throws -> CursorPayload {
        guard let data = Data(base64Encoded: value),
              let signed = try? Self.decoder.decode(SignedCursor.self, from: data),
              let payloadData = try? Self.encoder.encode(signed.payload),
              HMAC<SHA256>.isValidAuthenticationCode(
                Data(base64Encoded: signed.signature) ?? Data(), authenticating: payloadData,
                using: cursorKey
              ) else { throw ManagedRunServiceError.invalidCursor }
        return signed.payload
    }

    private func spoolSizes(_ paths: ManagedRunSpoolPaths) throws -> (
        stdout: UInt64, stderr: UInt64, diagnostics: UInt64
    ) {
        (
            try Self.fileSize(paths.stdout),
            try Self.fileSize(paths.stderr),
            try Self.fileSize(paths.diagnostics)
        )
    }

    private static func fileSize(_ url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
            throw ManagedRunServiceError.spoolCorrupt
        }
        return UInt64(size)
    }

    private static func readRange(_ url: URL, offset: UInt64, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? Data()
    }

    private static func chunk(channel: String, offset: UInt64, data: Data) -> ManagedRunEvidenceChunk {
        let text = String(data: data, encoding: .utf8)
        return ManagedRunEvidenceChunk(
            channel: channel, offset: offset, returnedBytes: data.count,
            encoding: text == nil ? "base64" : "utf-8",
            text: text, base64: text == nil ? data.base64EncodedString() : nil
        )
    }

    private static func cause(_ value: ManagedTerminationCause?) -> String? {
        switch value {
        case .none: nil
        case .naturalExit: "natural_exit"
        case .cancellation: "cancelled"
        case .timeout: "timed_out"
        case .launchFailed: "launch_failed"
        case .recoveryInterrupted: "interrupted"
        case .evidenceQuotaExceeded: "evidence_quota_exceeded"
        }
    }

    private static func loadRequest(_ url: URL) throws -> ManagedRunSupervisorRequest {
        let value = try decoder.decode(ManagedRunSupervisorRequest.self, from: Data(contentsOf: url))
        guard value.schema == "aishell.run-supervisor-request.v1" else {
            throw ManagedRunSupervisorError.invalidRequest
        }
        return value
    }

    private static func loadOrCreateCursorKey(runtimeStore: RuntimeStore) throws -> Data {
        let root = runtimeStore.baseDirectory.appendingPathComponent("managed-runs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let url = root.appendingPathComponent("cursor-key")
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard data.count == 32 else { throw ManagedRunServiceError.spoolCorrupt }
            return data
        }
        var data = Data(count: 32)
        let result = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard result == errSecSuccess else { throw ManagedRunServiceError.spoolCorrupt }
        try data.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return data
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
