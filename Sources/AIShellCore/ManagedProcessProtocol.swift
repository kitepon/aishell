import Foundation

/// Managed processのproduction実装と決定的fixtureが共有する、閉じた公開lifecycle。
public enum ManagedProcessState: String, Codable, Equatable, Sendable {
    case starting
    case running
    case cancelling
    case timingOut = "timing_out"
    case finalizing
    case recoveryRequired = "recovery_required"
    case passed
    case failed
    case timedOut = "timed_out"
    case cancelled
    case interrupted

    public var isTerminal: Bool {
        switch self {
        case .passed, .failed, .timedOut, .cancelled, .interrupted: true
        default: false
        }
    }
}

public struct ManagedProcessIdentity: Codable, Equatable, Sendable {
    public let processIdentifier: Int32
    public let processStartIdentity: String
    public let processGroupIdentifier: Int32
    public let bootSessionIdentity: String
    public let supervisorNonce: String

    public init(
        processIdentifier: Int32,
        processStartIdentity: String,
        processGroupIdentifier: Int32,
        bootSessionIdentity: String,
        supervisorNonce: String
    ) {
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        self.processGroupIdentifier = processGroupIdentifier
        self.bootSessionIdentity = bootSessionIdentity
        self.supervisorNonce = supervisorNonce
    }
}

/// SupervisorがOSから再照合して発行するproof。外部callerは生成できない。
public struct ManagedProcessIdentityProof: Equatable, Sendable {
    public let runID: UUID
    public let expected: ManagedProcessIdentity
    public let observed: ManagedProcessIdentity

    init(runID: UUID, expected: ManagedProcessIdentity, observed: ManagedProcessIdentity) {
        self.runID = runID
        self.expected = expected
        self.observed = observed
    }
}

public struct ManagedSupervisorLaunchRequest: Equatable, Sendable {
    public let runID: UUID
    public let spawnReservationID: UUID?
    public let requestDigest: String
    public let executableURL: URL
    public let arguments: [String]
    public let workingDirectoryURL: URL
    public let environment: [String: String]
    public let timeoutDeadline: Date?
    public let admittedAt: Date
    public let retentionSeconds: TimeInterval

    public init(
        runID: UUID,
        spawnReservationID: UUID? = nil,
        requestDigest: String = "",
        executableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL,
        environment: [String: String] = [:],
        timeoutDeadline: Date? = nil,
        admittedAt: Date = Date(timeIntervalSince1970: 0),
        retentionSeconds: TimeInterval = 3_600
    ) {
        self.runID = runID
        self.spawnReservationID = spawnReservationID
        self.requestDigest = requestDigest
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectoryURL = workingDirectoryURL
        self.environment = environment
        self.timeoutDeadline = timeoutDeadline
        self.admittedAt = admittedAt
        self.retentionSeconds = retentionSeconds
    }
}

public enum ManagedSupervisorLaunchBindingState: Codable, Equatable, Sendable {
    case boundBeforeSpawn
    case spawned(ManagedProcessIdentity)
    case recoveryRequired
}

public struct ManagedSupervisorLaunchBinding: Codable, Equatable, Sendable {
    public let runID: UUID
    public let reservationID: UUID
    public let requestDigest: String
    public let state: ManagedSupervisorLaunchBindingState
    public let spawnCount: UInt64

    public init(
        runID: UUID,
        reservationID: UUID,
        requestDigest: String,
        state: ManagedSupervisorLaunchBindingState,
        spawnCount: UInt64
    ) {
        self.runID = runID
        self.reservationID = reservationID
        self.requestDigest = requestDigest
        self.state = state
        self.spawnCount = spawnCount
    }
}

public protocol ManagedReservationBoundSupervisorSeam: Sendable {
    func launchOrReconnect(
        _ request: ManagedSupervisorLaunchRequest,
        requestDigest: String
    ) async throws -> ManagedProcessIdentity
    func binding(reservationID: UUID) async throws -> ManagedSupervisorLaunchBinding?
}

public struct ManagedSupervisorStopReport: Equatable, Sendable {
    public let termWasSent: Bool
    public let killWasSent: Bool
    public let processGroupIsGone: Bool

    public init(termWasSent: Bool, killWasSent: Bool, processGroupIsGone: Bool) {
        self.termWasSent = termWasSent
        self.killWasSent = killWasSent
        self.processGroupIsGone = processGroupIsGone
    }
}

/// Registry/MCP adapterから独立したprocess supervisorのproduction共有seam。
public protocol ProcessSupervisorSeam: Sendable {
    func launch(_ request: ManagedSupervisorLaunchRequest) async throws -> ManagedProcessIdentity
    func reconnect(runID: UUID, expectedIdentity: ManagedProcessIdentity) async throws -> ManagedProcessIdentityProof
    func stop(runID: UUID, proof: ManagedProcessIdentityProof) async throws -> ManagedSupervisorStopReport
}

public enum ManagedTerminalCandidate: Equatable, Sendable {
    case cancellation(acceptedAt: Date)
    case timeout(deadline: Date)
    case naturalExit(exitCode: Int32, signal: Int32?, observedAt: Date)
}

public enum ManagedDurableTerminalCause: Codable, Equatable, Sendable {
    case cancellation
    case timeout
    case naturalExit(exitCode: Int32, signal: Int32?)

    private enum CodingKeys: String, CodingKey { case kind, exitCode, signal }
    private enum Kind: String, Codable { case cancellation, timeout, naturalExit }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .cancellation: self = .cancellation
        case .timeout: self = .timeout
        case .naturalExit:
            self = .naturalExit(
                exitCode: try values.decode(Int32.self, forKey: .exitCode),
                signal: try values.decodeIfPresent(Int32.self, forKey: .signal)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cancellation:
            try values.encode(Kind.cancellation, forKey: .kind)
        case .timeout:
            try values.encode(Kind.timeout, forKey: .kind)
        case let .naturalExit(exitCode, signal):
            try values.encode(Kind.naturalExit, forKey: .kind)
            try values.encode(exitCode, forKey: .exitCode)
            try values.encodeIfPresent(signal, forKey: .signal)
        }
    }
}

public enum ManagedTerminationWorkflowState: String, Codable, Equatable, Sendable {
    case causePersisted = "cause_persisted"
    case outboxPending = "outbox_pending"
    case processGroupGoneObserved = "process_group_gone_observed"
    case spawnAbortObserved = "spawn_abort_observed"
    case acknowledged
}

public enum ManagedTerminationProcessPhase: Codable, Equatable, Sendable {
    case preSpawn
    case spawned(ManagedProcessIdentity)
}

public struct ManagedTerminationWorkflowRecord: Codable, Equatable, Sendable {
    public let runID: UUID
    public let cause: ManagedDurableTerminalCause
    public let acceptedAt: Date
    public let processPhase: ManagedTerminationProcessPhase
    public let signal: Int32
    public let state: ManagedTerminationWorkflowState

    public init(
        runID: UUID,
        cause: ManagedDurableTerminalCause,
        acceptedAt: Date,
        processPhase: ManagedTerminationProcessPhase,
        signal: Int32,
        state: ManagedTerminationWorkflowState
    ) {
        self.runID = runID
        self.cause = cause
        self.acceptedAt = acceptedAt
        self.processPhase = processPhase
        self.signal = signal
        self.state = state
    }

    public init(
        runID: UUID,
        cause: ManagedDurableTerminalCause,
        acceptedAt: Date,
        identity: ManagedProcessIdentity,
        signal: Int32,
        state: ManagedTerminationWorkflowState
    ) {
        self.init(
            runID: runID,
            cause: cause,
            acceptedAt: acceptedAt,
            processPhase: .spawned(identity),
            signal: signal,
            state: state
        )
    }

    public var identity: ManagedProcessIdentity? {
        guard case let .spawned(identity) = processPhase else { return nil }
        return identity
    }
}

/// v1 journal読取専用。`signalDispatched`を実signal証拠としては扱わずoutbox再照合へ移す。
public struct ManagedLegacyTerminalCauseRecordV1: Codable, Equatable, Sendable {
    public let runID: UUID
    public let cause: ManagedDurableTerminalCause
    public let acceptedAt: Date
    public let signalDispatched: Bool

    public init(runID: UUID, cause: ManagedDurableTerminalCause, acceptedAt: Date, signalDispatched: Bool) {
        self.runID = runID
        self.cause = cause
        self.acceptedAt = acceptedAt
        self.signalDispatched = signalDispatched
    }
}

public extension ManagedTerminationWorkflowRecord {
    init(
        migrating legacy: ManagedLegacyTerminalCauseRecordV1,
        identity: ManagedProcessIdentity,
        signal: Int32
    ) {
        self.init(
            runID: legacy.runID,
            cause: legacy.cause,
            acceptedAt: legacy.acceptedAt,
            processPhase: .spawned(identity),
            signal: signal,
            state: legacy.signalDispatched ? .outboxPending : .causePersisted
        )
    }
}

/// cause選択から実signal/reap/ackまでを一つのdurable recordで所有するworkflow seam。
public protocol ManagedTerminationWorkflowSeam: Sendable {
    func persistCause(_ record: ManagedTerminationWorkflowRecord) throws -> ManagedTerminationWorkflowRecord
    func persistOutboxPending(runID: UUID) throws
    func recover(runID: UUID) throws -> ManagedTerminationWorkflowRecord?
    func persistGroupGoneObservation(runID: UUID) throws
    func persistSpawnAbortObservation(runID: UUID) throws
    func acknowledge(runID: UUID) throws
}

/// 同じtermination workflow recordへ3種のcauseをfirst-writer-winsでlinearizeするseam。
public protocol ManagedTerminationCauseAdmissionSeam: Sendable {
    func acceptTerminalCandidate(
        _ candidate: ManagedTerminalCandidate
    ) async throws -> ManagedTerminationWorkflowRecord
}

public enum ManagedProcessGroupProbeResult: Equatable, Sendable {
    case exists
    case absentESRCH
    case permissionDenied
    case failed(errno: Int32)
}

public protocol ManagedProcessGroupProbeSeam: Sendable {
    func probe(processGroupIdentifier: Int32) -> ManagedProcessGroupProbeResult
}

public enum ManagedSignalDeliveryResult: Equatable, Sendable {
    case delivered
    case processGroupAbsentESRCH
    case permissionDenied
    case failed(errno: Int32)
}

public protocol ManagedSignalDeliverySeam: Sendable {
    func deliver(signal: Int32, to identity: ManagedProcessIdentity) -> ManagedSignalDeliveryResult
}

public enum ManagedSpawnReservationState: Codable, Equatable, Sendable {
    case preSpawn
    case spawnReserved(reservationID: UUID)
    case spawned(reservationID: UUID, identity: ManagedProcessIdentity)
    case spawnAborted
}

public struct ManagedSpawnReservationRecord: Codable, Equatable, Sendable {
    public let runID: UUID
    public let revision: UInt64
    public let state: ManagedSpawnReservationState
    public let terminationCause: ManagedDurableTerminalCause?
    public let causeAcceptedAt: Date?

    public init(
        runID: UUID,
        revision: UInt64,
        state: ManagedSpawnReservationState,
        terminationCause: ManagedDurableTerminalCause?,
        causeAcceptedAt: Date?
    ) {
        self.runID = runID
        self.revision = revision
        self.state = state
        self.terminationCause = terminationCause
        self.causeAcceptedAt = causeAcceptedAt
    }
}

public enum ManagedSpawnReservationDecision: Equatable, Sendable {
    case reserved(reservationID: UUID)
    case deniedByPreSpawnCause(ManagedDurableTerminalCause)
}

/// spawn reservation/cause admission/identity publicationを同じdurable actor transactionへlinearizeするseam。
public protocol ManagedSpawnReservationWorkflowSeam: Sendable {
    func reserveSpawn(runID: UUID) async throws -> ManagedSpawnReservationDecision
    func admitPreSpawnCause(
        runID: UUID,
        cause: ManagedDurableTerminalCause,
        acceptedAt: Date
    ) async throws -> ManagedSpawnReservationRecord
    func publishSpawnIdentity(
        runID: UUID,
        reservationID: UUID,
        identity: ManagedProcessIdentity
    ) async throws -> ManagedSpawnReservationRecord
    func snapshot(runID: UUID) async throws -> ManagedSpawnReservationRecord
}

public struct ManagedAdapterRecoveryRecord: Codable, Equatable, Sendable {
    public let runID: UUID
    public let runHandle: String
    public let stateRevision: UInt64
    public let cursor: ManagedEvidenceCursor
    public let processIdentity: ManagedProcessIdentity
    public let supervisorEndpoint: String

    public init(
        runID: UUID,
        runHandle: String,
        stateRevision: UInt64,
        cursor: ManagedEvidenceCursor,
        processIdentity: ManagedProcessIdentity,
        supervisorEndpoint: String
    ) {
        self.runID = runID
        self.runHandle = runHandle
        self.stateRevision = stateRevision
        self.cursor = cursor
        self.processIdentity = processIdentity
        self.supervisorEndpoint = supervisorEndpoint
    }
}

public struct ManagedAdapterReconnectResult: Equatable, Sendable {
    public let record: ManagedAdapterRecoveryRecord
    public let transportSessionNonce: String

    public init(record: ManagedAdapterRecoveryRecord, transportSessionNonce: String) {
        self.record = record
        self.transportSessionNonce = transportSessionNonce
    }
}

/// 新adapter instanceがdurable recordからsupervisorへ再接続するproduction共有seam。
public protocol ManagedAdapterRecoverySeam: Sendable {
    func reconnect(runID: UUID) async throws -> ManagedAdapterReconnectResult
}

public struct ManagedSupervisorHandshakeRequest: Codable, Equatable, Sendable {
    public let runID: UUID
    public let transportSessionNonce: String
    public let clientChallenge: String
    public let adapterProcessIdentifier: Int32
    public let credentialExpiresAtUnixMilliseconds: Int64

    public init(
        runID: UUID,
        transportSessionNonce: String,
        clientChallenge: String,
        adapterProcessIdentifier: Int32,
        credentialExpiresAtUnixMilliseconds: Int64
    ) {
        self.runID = runID
        self.transportSessionNonce = transportSessionNonce
        self.clientChallenge = clientChallenge
        self.adapterProcessIdentifier = adapterProcessIdentifier
        self.credentialExpiresAtUnixMilliseconds = credentialExpiresAtUnixMilliseconds
    }
}

public struct ManagedSupervisorChallenge: Codable, Equatable, Sendable {
    public let supervisorChallenge: String
    public let supervisorProof: String

    public init(supervisorChallenge: String, supervisorProof: String) {
        self.supervisorChallenge = supervisorChallenge
        self.supervisorProof = supervisorProof
    }
}

public struct ManagedSupervisorChallengeResponse: Codable, Equatable, Sendable {
    public let clientProof: String

    public init(clientProof: String) { self.clientProof = clientProof }
}

/// owner-only durable fileへ保存し、wireへは出さないAF_UNIX相互認証material。
public struct ManagedSupervisorAuthenticationMaterial: Codable, Equatable, Sendable {
    public let runID: UUID
    public let supervisorNonce: String
    public let secret: Data
    public let allowedEffectiveUserIdentifier: UInt32
    public let allowedEffectiveGroupIdentifier: UInt32

    public init(
        runID: UUID,
        supervisorNonce: String,
        secret: Data,
        allowedEffectiveUserIdentifier: UInt32,
        allowedEffectiveGroupIdentifier: UInt32
    ) {
        self.runID = runID
        self.supervisorNonce = supervisorNonce
        self.secret = secret
        self.allowedEffectiveUserIdentifier = allowedEffectiveUserIdentifier
        self.allowedEffectiveGroupIdentifier = allowedEffectiveGroupIdentifier
    }
}

public struct ManagedSupervisorHandshakeResponse: Codable, Equatable, Sendable {
    public let supervisorNonce: String
    public let bootSessionIdentity: String
    public let processIdentifier: Int32
    public let processStartIdentity: String
    public let processGroupIdentifier: Int32

    public init(
        supervisorNonce: String,
        bootSessionIdentity: String,
        processIdentifier: Int32,
        processStartIdentity: String,
        processGroupIdentifier: Int32
    ) {
        self.supervisorNonce = supervisorNonce
        self.bootSessionIdentity = bootSessionIdentity
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        self.processGroupIdentifier = processGroupIdentifier
    }
}

public enum ManagedTerminationCause: Equatable, Sendable {
    case naturalExit(exitCode: Int32, signal: Int32?)
    case cancellation(acceptedAt: Date)
    case timeout(deadline: Date)
    case launchFailed(stage: ManagedLaunchFailureStage, osErrorCategory: String)
    case recoveryInterrupted
    case evidenceQuotaExceeded
}

public enum ManagedLaunchFailureStage: String, Codable, Equatable, Sendable {
    case spawn
    case executableIdentity
    case workingDirectory
    case fileDescriptorConnection
}

public struct ManagedEvidenceCursor: Codable, Equatable, Sendable {
    public let runID: UUID
    public let eventSequence: UInt64
    public let stdoutOffset: UInt64
    public let stderrOffset: UInt64
    public let diagnosticOffset: UInt64

    public init(
        runID: UUID,
        eventSequence: UInt64 = 0,
        stdoutOffset: UInt64 = 0,
        stderrOffset: UInt64 = 0,
        diagnosticOffset: UInt64 = 0
    ) {
        self.runID = runID
        self.eventSequence = eventSequence
        self.stdoutOffset = stdoutOffset
        self.stderrOffset = stderrOffset
        self.diagnosticOffset = diagnosticOffset
    }

    public func advancing(stdoutBytes: Int = 0, stderrBytes: Int = 0, diagnosticBytes: Int = 0) throws -> Self {
        guard stdoutBytes >= 0, stderrBytes >= 0, diagnosticBytes >= 0 else {
            throw ManagedProcessProtocolError.invalidEvidenceLength
        }
        return Self(
            runID: runID,
            eventSequence: eventSequence + 1,
            stdoutOffset: try stdoutOffset.addingWithoutOverflow(UInt64(stdoutBytes)),
            stderrOffset: try stderrOffset.addingWithoutOverflow(UInt64(stderrBytes)),
            diagnosticOffset: try diagnosticOffset.addingWithoutOverflow(UInt64(diagnosticBytes))
        )
    }
}

public struct ManagedArtifactIdentity: Codable, Equatable, Sendable {
    public let handle: String
    public let sizeBytes: UInt64
    public let lineCount: UInt64
    public let sha256: String

    public init(handle: String, sizeBytes: UInt64, lineCount: UInt64 = 0, sha256: String) {
        self.handle = handle
        self.sizeBytes = sizeBytes
        self.lineCount = lineCount
        self.sha256 = sha256
    }
}

public struct ManagedSpoolInspection: Equatable, Sendable {
    public let stdout: ManagedArtifactIdentity
    public let stderr: ManagedArtifactIdentity

    public init(stdout: ManagedArtifactIdentity, stderr: ManagedArtifactIdentity) {
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// 実spoolのfsync/readbackとartifact/indexのatomic publicationを分離する共有seam。
public protocol ManagedSpoolFinalizationSeam: Sendable {
    func fsyncAndInspect(stdoutURL: URL, stderrURL: URL) async throws -> ManagedSpoolInspection
    func publishAtomically(
        inspection: ManagedSpoolInspection,
        diagnostics: ManagedArtifactIdentity,
        finalizedAt: Date
    ) async throws -> ManagedFinalizationBundle
}

public struct ManagedFinalizationReplayBinding: Codable, Equatable, Sendable {
    public let runID: UUID
    public let requestDigest: String
    public let stdout: ManagedArtifactIdentity
    public let stderr: ManagedArtifactIdentity
    public let diagnostics: ManagedArtifactIdentity
    public let finalizedAt: Date

    public init(
        runID: UUID,
        requestDigest: String,
        stdout: ManagedArtifactIdentity,
        stderr: ManagedArtifactIdentity,
        diagnostics: ManagedArtifactIdentity,
        finalizedAt: Date
    ) {
        self.runID = runID
        self.requestDigest = requestDigest
        self.stdout = stdout
        self.stderr = stderr
        self.diagnostics = diagnostics
        self.finalizedAt = finalizedAt
    }
}

/// 3 artifactとrun indexを一括で渡すことで、部分的なterminal公開を型境界で防ぐ。
public struct ManagedFinalizationBundle: Equatable, Sendable {
    public let stdout: ManagedArtifactIdentity
    public let stderr: ManagedArtifactIdentity
    public let diagnostics: ManagedArtifactIdentity
    public let runIndexDigest: String
    public let finalizedAt: Date

    public init(
        stdout: ManagedArtifactIdentity,
        stderr: ManagedArtifactIdentity,
        diagnostics: ManagedArtifactIdentity,
        runIndexDigest: String,
        finalizedAt: Date
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.diagnostics = diagnostics
        self.runIndexDigest = runIndexDigest
        self.finalizedAt = finalizedAt
    }
}

public struct ManagedRunSnapshot: Equatable, Sendable {
    public let runID: UUID
    public let state: ManagedProcessState
    public let stateRevision: UInt64
    public let identity: ManagedProcessIdentity?
    public let cursor: ManagedEvidenceCursor
    public let terminationCause: ManagedTerminationCause?
    public let finalization: ManagedFinalizationBundle?
    public let expiresAt: Date?

    public init(
        runID: UUID,
        state: ManagedProcessState,
        stateRevision: UInt64,
        identity: ManagedProcessIdentity?,
        cursor: ManagedEvidenceCursor,
        terminationCause: ManagedTerminationCause?,
        finalization: ManagedFinalizationBundle?,
        expiresAt: Date?
    ) {
        self.runID = runID
        self.state = state
        self.stateRevision = stateRevision
        self.identity = identity
        self.cursor = cursor
        self.terminationCause = terminationCause
        self.finalization = finalization
        self.expiresAt = expiresAt
    }

    public func isEligibleForGarbageCollection(at date: Date) -> Bool {
        guard state.isTerminal, finalization != nil, let expiresAt else { return false }
        return date >= expiresAt
    }
}

public enum ManagedProcessEvent: Equatable, Sendable {
    case launchSucceeded(ManagedProcessIdentity)
    case launchFailed(stage: ManagedLaunchFailureStage, osErrorCategory: String)
    case naturalExit(exitCode: Int32, signal: Int32?)
    case cancel(acceptedAt: Date)
    case cancelAfterRecoveryVerification(acceptedAt: Date, proof: ManagedProcessIdentityProof)
    case timeout(deadline: Date)
    case evidenceQuotaExceeded
    case supervisorUnavailable
    case recover(identity: ManagedProcessIdentity)
    case recoveredProcessStopped
    case beginFinalization
    case commitFinalization(ManagedFinalizationBundle)
}

public enum ManagedProcessProtocolError: Error, Equatable, Sendable {
    case illegalTransition(from: ManagedProcessState, event: String)
    case terminalCauseMissing
    case terminalCauseAlreadyAccepted
    case identityMismatch
    case invalidEvidenceLength
    case evidenceOffsetOverflow
    case finalizationIncomplete
    case runKeyConflict
    case runRecoveryRequired
}

/// Registry actor内で使う純粋なstate machine。eventの永続化は呼出側の責務である。
public struct ManagedProcessStateMachine: Sendable {
    public private(set) var snapshot: ManagedRunSnapshot
    public let retentionSeconds: TimeInterval
    private var stateBeforeRecovery: ManagedProcessState?

    public init(runID: UUID, retentionSeconds: TimeInterval) {
        precondition(retentionSeconds >= 0)
        self.retentionSeconds = retentionSeconds
        snapshot = ManagedRunSnapshot(
            runID: runID,
            state: .starting,
            stateRevision: 0,
            identity: nil,
            cursor: ManagedEvidenceCursor(runID: runID),
            terminationCause: nil,
            finalization: nil,
            expiresAt: nil
        )
    }

    public mutating func appendEvidence(stdoutBytes: Int = 0, stderrBytes: Int = 0, diagnosticBytes: Int = 0) throws {
        guard !snapshot.state.isTerminal else {
            throw ManagedProcessProtocolError.illegalTransition(from: snapshot.state, event: "appendEvidence")
        }
        let cursor = try snapshot.cursor.advancing(
            stdoutBytes: stdoutBytes,
            stderrBytes: stderrBytes,
            diagnosticBytes: diagnosticBytes
        )
        replace(cursor: cursor)
    }

    @discardableResult
    public mutating func accept(_ event: ManagedProcessEvent) throws -> ManagedRunSnapshot {
        if snapshot.state.isTerminal {
            // terminal後のcancel/status合流は上位protocolで同じsnapshotを返す。eventで状態を変えない。
            if case .cancel = event { return snapshot }
            throw ManagedProcessProtocolError.illegalTransition(from: snapshot.state, event: event.name)
        }

        switch event {
        case let .launchSucceeded(identity):
            try requireState(.starting, event)
            replace(state: .running, identity: identity)

        case let .launchFailed(stage, category):
            try requireState(.starting, event)
            try requireNoCause()
            replace(
                state: .finalizing,
                terminationCause: .launchFailed(stage: stage, osErrorCategory: category)
            )

        case let .naturalExit(exitCode, signal):
            switch snapshot.state {
            case .starting, .running:
                try requireNoCause()
                replace(state: .finalizing, terminationCause: .naturalExit(exitCode: exitCode, signal: signal))
            case .cancelling, .timingOut:
                guard snapshot.terminationCause != nil else {
                    throw ManagedProcessProtocolError.terminalCauseMissing
                }
                // cancel/timeoutが先にlinearizeした後のreap。exit情報で先行causeを上書きしない。
                replace(state: .finalizing)
            default:
                throw ManagedProcessProtocolError.illegalTransition(from: snapshot.state, event: event.name)
            }

        case let .cancel(acceptedAt):
            guard snapshot.state != .recoveryRequired else {
                throw ManagedProcessProtocolError.runRecoveryRequired
            }
            try requireOneOf([.starting, .running, .cancelling, .timingOut, .recoveryRequired], event)
            if snapshot.state == .cancelling || snapshot.state == .timingOut { return snapshot }
            if snapshot.terminationCause != nil { return snapshot }
            replace(state: .cancelling, terminationCause: .cancellation(acceptedAt: acceptedAt))

        case let .cancelAfterRecoveryVerification(acceptedAt, proof):
            try requireState(.recoveryRequired, event)
            guard let identity = snapshot.identity,
                  proof.runID == snapshot.runID,
                  proof.expected == identity,
                  proof.observed == identity
            else {
                throw ManagedProcessProtocolError.runRecoveryRequired
            }
            if snapshot.terminationCause == nil {
                replace(state: .cancelling, terminationCause: .cancellation(acceptedAt: acceptedAt))
            } else {
                replace(state: .cancelling)
            }

        case let .timeout(deadline):
            if snapshot.terminationCause != nil { return snapshot }
            try requireOneOf([.starting, .running], event)
            replace(state: .timingOut, terminationCause: .timeout(deadline: deadline))

        case .evidenceQuotaExceeded:
            if snapshot.terminationCause != nil { return snapshot }
            try requireOneOf([.starting, .running], event)
            replace(state: .finalizing, terminationCause: .evidenceQuotaExceeded)

        case .supervisorUnavailable:
            try requireOneOf([.starting, .running, .cancelling, .timingOut, .finalizing], event)
            stateBeforeRecovery = snapshot.state
            replace(state: .recoveryRequired)

        case let .recover(identity):
            try requireState(.recoveryRequired, event)
            guard identity == snapshot.identity, let restored = stateBeforeRecovery else {
                throw ManagedProcessProtocolError.identityMismatch
            }
            stateBeforeRecovery = nil
            replace(state: restored)

        case .recoveredProcessStopped:
            try requireState(.recoveryRequired, event)
            if snapshot.terminationCause == nil {
                replace(state: .finalizing, terminationCause: .recoveryInterrupted)
            } else {
                replace(state: .finalizing)
            }

        case .beginFinalization:
            try requireOneOf([.cancelling, .timingOut], event)
            guard snapshot.terminationCause != nil else {
                throw ManagedProcessProtocolError.terminalCauseMissing
            }
            replace(state: .finalizing)

        case let .commitFinalization(bundle):
            try requireState(.finalizing, event)
            guard let cause = snapshot.terminationCause else {
                throw ManagedProcessProtocolError.terminalCauseMissing
            }
            let terminal: ManagedProcessState
            switch cause {
            case let .naturalExit(exitCode, signal):
                terminal = exitCode == 0 && signal == nil ? .passed : .failed
            case .cancellation: terminal = .cancelled
            case .timeout: terminal = .timedOut
            case .launchFailed, .evidenceQuotaExceeded: terminal = .failed
            case .recoveryInterrupted: terminal = .interrupted
            }
            replace(
                state: terminal,
                finalization: bundle,
                expiresAt: bundle.finalizedAt.addingTimeInterval(retentionSeconds)
            )
        }
        return snapshot
    }

    private func requireNoCause() throws {
        guard snapshot.terminationCause == nil else {
            throw ManagedProcessProtocolError.terminalCauseAlreadyAccepted
        }
    }

    private func requireState(_ state: ManagedProcessState, _ event: ManagedProcessEvent) throws {
        guard snapshot.state == state else {
            throw ManagedProcessProtocolError.illegalTransition(from: snapshot.state, event: event.name)
        }
    }

    private func requireOneOf(_ states: Set<ManagedProcessState>, _ event: ManagedProcessEvent) throws {
        guard states.contains(snapshot.state) else {
            throw ManagedProcessProtocolError.illegalTransition(from: snapshot.state, event: event.name)
        }
    }

    private mutating func replace(
        state: ManagedProcessState? = nil,
        identity: ManagedProcessIdentity? = nil,
        cursor: ManagedEvidenceCursor? = nil,
        terminationCause: ManagedTerminationCause? = nil,
        finalization: ManagedFinalizationBundle? = nil,
        expiresAt: Date? = nil
    ) {
        snapshot = ManagedRunSnapshot(
            runID: snapshot.runID,
            state: state ?? snapshot.state,
            stateRevision: snapshot.stateRevision + 1,
            identity: identity ?? snapshot.identity,
            cursor: cursor ?? snapshot.cursor,
            terminationCause: terminationCause ?? snapshot.terminationCause,
            finalization: finalization ?? snapshot.finalization,
            expiresAt: expiresAt ?? snapshot.expiresAt
        )
    }
}

/// Production registryとfixtureが同じ呼出面を実装するための最小protocol。
public protocol ManagedProcessProtocol: Sendable {
    func snapshot() async -> ManagedRunSnapshot
    func accept(_ event: ManagedProcessEvent) async throws -> ManagedRunSnapshot
    func appendEvidence(stdoutBytes: Int, stderrBytes: Int, diagnosticBytes: Int) async throws -> ManagedEvidenceCursor
}

/// 競合eventを明示順でregistry actorへ投入する決定的race harness。
public actor DeterministicManagedProcessHarness: ManagedProcessProtocol {
    private var machine: ManagedProcessStateMachine

    public init(runID: UUID = UUID(), retentionSeconds: TimeInterval = 3_600) {
        machine = ManagedProcessStateMachine(runID: runID, retentionSeconds: retentionSeconds)
    }

    public func snapshot() -> ManagedRunSnapshot { machine.snapshot }

    public func accept(_ event: ManagedProcessEvent) throws -> ManagedRunSnapshot {
        try machine.accept(event)
    }

    public func appendEvidence(stdoutBytes: Int, stderrBytes: Int, diagnosticBytes: Int) throws -> ManagedEvidenceCursor {
        try machine.appendEvidence(
            stdoutBytes: stdoutBytes,
            stderrBytes: stderrBytes,
            diagnosticBytes: diagnosticBytes
        )
        return machine.snapshot.cursor
    }

    public func race(_ eventsInLinearizationOrder: [ManagedProcessEvent]) -> [Result<ManagedRunSnapshot, Error>] {
        eventsInLinearizationOrder.map { event in
            Result { try machine.accept(event) }
        }
    }
}

public enum ManagedRunAdmission: Equatable, Sendable {
    case created(runID: UUID)
    case existing(runID: UUID)
}

/// client_run_key冪等性をproduction registryより先に固定する純粋ledger。
public struct ManagedRunAdmissionLedger: Sendable {
    private var entries: [String: (requestDigest: String, runID: UUID)] = [:]

    public init() {}

    public mutating func admit(clientRunKey: String, requestDigest: String, makeRunID: () -> UUID) throws -> ManagedRunAdmission {
        if let existing = entries[clientRunKey] {
            guard existing.requestDigest == requestDigest else {
                throw ManagedProcessProtocolError.runKeyConflict
            }
            return .existing(runID: existing.runID)
        }
        let runID = makeRunID()
        entries[clientRunKey] = (requestDigest, runID)
        return .created(runID: runID)
    }
}

private extension ManagedProcessEvent {
    var name: String {
        switch self {
        case .launchSucceeded: "launchSucceeded"
        case .launchFailed: "launchFailed"
        case .naturalExit: "naturalExit"
        case .cancel: "cancel"
        case .cancelAfterRecoveryVerification: "cancelAfterRecoveryVerification"
        case .timeout: "timeout"
        case .evidenceQuotaExceeded: "evidenceQuotaExceeded"
        case .supervisorUnavailable: "supervisorUnavailable"
        case .recover: "recover"
        case .recoveredProcessStopped: "recoveredProcessStopped"
        case .beginFinalization: "beginFinalization"
        case .commitFinalization: "commitFinalization"
        }
    }
}

private extension UInt64 {
    func addingWithoutOverflow(_ value: UInt64) throws -> UInt64 {
        let (result, overflow) = addingReportingOverflow(value)
        guard !overflow else { throw ManagedProcessProtocolError.evidenceOffsetOverflow }
        return result
    }
}
