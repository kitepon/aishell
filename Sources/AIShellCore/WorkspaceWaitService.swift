import Foundation

public enum WorkspaceWaitStatus: String, Codable, Equatable, Sendable {
    case changed
    case timedOut = "timed_out"
}

public struct WorkspaceWaitResult: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let status: WorkspaceWaitStatus
    public let observedFrom: String
    public let observedThrough: String
    public let observationViewID: String
    public let retentionFloorSequence: UInt64
    public let headSequence: UInt64
    public let changedPaths: [String]
}

extension WorkspaceStateRuntime {
    /// retained journalを消費せず、cursor以後の観測またはtimeoutまで待つ。
    /// cancellationは結果へ丸めず、呼出側へ`CancellationError`として伝播する。
    public func workspaceWait(
        path: String? = nil,
        fromCursor: String,
        timeoutSeconds: Double,
        pollInterval: Duration = .milliseconds(50)
    ) async throws -> WorkspaceWaitResult {
        guard timeoutSeconds.isFinite, timeoutSeconds >= 0 else {
            throw AIShellError.invalidArgument("timeout_secondsは0以上の有限値である必要があります。")
        }
        guard pollInterval > .zero else {
            throw AIShellError.invalidArgument("poll intervalは0より大きい必要があります。")
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        while true {
            try Task.checkCancellation()
            let observation = try await workspaceDeltaObservation(
                path: path,
                fromCursor: fromCursor,
                deliveryGrace: .zero
            )
            if observation.observedThrough != fromCursor {
                return Self.waitResult(status: .changed, observation: observation)
            }
            let now = clock.now
            guard now < deadline else {
                return Self.waitResult(status: .timedOut, observation: observation)
            }
            let remaining = now.duration(to: deadline)
            try await clock.sleep(for: min(pollInterval, remaining))
        }
    }

    private static func waitResult(
        status: WorkspaceWaitStatus,
        observation: WorkspaceDeltaObservation
    ) -> WorkspaceWaitResult {
        WorkspaceWaitResult(
            schemaVersion: "aishell.workspace-wait.v1",
            status: status,
            observedFrom: observation.observedFrom,
            observedThrough: observation.observedThrough,
            observationViewID: observation.observationViewID,
            retentionFloorSequence: observation.retentionFloorSequence,
            headSequence: observation.headSequence,
            changedPaths: observation.changedPaths.sorted {
                Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8))
            }
        )
    }
}
