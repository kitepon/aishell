import CryptoKit
import Darwin
import Foundation
import Security

public enum ManagedProcessRegistryError: Error, Equatable, Sendable {
    case invalidClientRunKey
    case invalidRequestDigest
    case invalidRunHandle
    case runStoreMismatch
    case runNotFound
    case runExpired
    case runNotCancellable
    case runRecoveryRequired
    case runStoreCorrupt(String)
}

public struct ManagedProcessRegistration: Equatable, Sendable {
    public let admission: ManagedRunAdmission
    public let runHandle: String
    public let snapshot: ManagedRunSnapshot

    public init(admission: ManagedRunAdmission, runHandle: String, snapshot: ManagedRunSnapshot) {
        self.admission = admission
        self.runHandle = runHandle
        self.snapshot = snapshot
    }
}

public enum ManagedProcessRecoveryState: String, Equatable, Sendable {
    case terminal
    case reconnected
    case recoveryRequired = "recovery_required"
}

public struct ManagedProcessRecoveryResult: Equatable, Sendable {
    public let runID: UUID
    public let state: ManagedProcessRecoveryState
    public let snapshot: ManagedRunSnapshot

    public init(runID: UUID, state: ManagedProcessRecoveryState, snapshot: ManagedRunSnapshot) {
        self.runID = runID
        self.state = state
        self.snapshot = snapshot
    }
}

/// Managed runのhandle、state journal、supervisor再接続を一つの永続所有面に束縛するregistry。
/// live spoolとartifact publicationは別serviceが所有し、registryはoffsetとlifecycleだけを記録する。
public actor ManagedProcessRegistry {
    public static let storageSchema = "aishell.managed-process-registry.v1"

    private let supervisor: any ProcessSupervisorSeam
    private let rootURL: URL
    private let runsURL: URL
    private let storeIdentity: UUID
    private let handleKey: SymmetricKey
    private var runs: [UUID: RunEntry]
    private var runIDByClientKey: [String: UUID]

    public init(
        store: RuntimeStore = RuntimeStore(),
        supervisor: any ProcessSupervisorSeam
    ) throws {
        self.supervisor = supervisor
        rootURL = store.baseDirectory.appendingPathComponent("managed-runs", isDirectory: true)
        runsURL = rootURL.appendingPathComponent("runs", isDirectory: true)

        try Self.ensurePrivateDirectory(rootURL)
        try Self.ensurePrivateDirectory(runsURL)
        let credentials = try Self.loadOrCreateCredentials(in: rootURL)
        storeIdentity = credentials.storeIdentity
        handleKey = SymmetricKey(data: credentials.secret)

        let loaded = try Self.loadRuns(from: runsURL)
        runs = loaded.runs
        runIDByClientKey = loaded.runIDByClientKey
    }

    // 旧artifact索引が省略した期限を、run所有の保存済みretentionから復元する。
    static func retainedArtifactExpiry(store: RuntimeStore, runID: UUID, requestDigest: String, finalizedAt: Date) throws -> Date {
        let manifestURL = store.baseDirectory.appendingPathComponent("managed-runs/runs", isDirectory: true)
            .appendingPathComponent(runID.uuidString.lowercased(), isDirectory: true).appendingPathComponent("manifest.json")
        try requirePrivateRegularFile(manifestURL)
        let manifest = try decoder.decode(RunManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.schema == storageSchema, manifest.runID == runID,
              manifest.requestDigest == requestDigest, manifest.retentionSeconds.isFinite,
              manifest.retentionSeconds >= 0 else { throw ManagedProcessRegistryError.runStoreCorrupt("manifest binding") }
        return finalizedAt.addingTimeInterval(manifest.retentionSeconds)
    }

    /// 同じclient key + digestは既存runへ合流し、別digestではprocessを増やさず競合にする。
    public func start(
        clientRunKey: String,
        requestDigest: String,
        executableURL: URL,
        arguments: [String] = [],
        workingDirectoryURL: URL,
        environment: [String: String] = [:],
        timeoutDeadline: Date? = nil,
        admittedAt: Date = Date(),
        retentionSeconds: TimeInterval = 3_600,
        runID requestedRunID: UUID = UUID()
    ) async throws -> ManagedProcessRegistration {
        guard (1 ... 128).contains(clientRunKey.utf8.count) else {
            throw ManagedProcessRegistryError.invalidClientRunKey
        }
        guard !requestDigest.isEmpty else { throw ManagedProcessRegistryError.invalidRequestDigest }
        guard retentionSeconds >= 0 else { throw ManagedProcessRegistryError.runStoreCorrupt("negative retention") }

        if let runID = runIDByClientKey[clientRunKey], let entry = runs[runID] {
            guard entry.manifest.requestDigest == requestDigest else {
                throw ManagedProcessProtocolError.runKeyConflict
            }
            if let expiresAt = entry.machine.snapshot.expiresAt,
               entry.machine.snapshot.state.isTerminal,
               Date() >= expiresAt {
                throw ManagedProcessRegistryError.runExpired
            }
            return ManagedProcessRegistration(
                admission: .existing(runID: runID),
                runHandle: entry.manifest.runHandle,
                snapshot: entry.machine.snapshot
            )
        }
        guard runs[requestedRunID] == nil else {
            throw ManagedProcessRegistryError.runStoreCorrupt("duplicate run id")
        }

        let handle = try makeHandle(runID: requestedRunID)
        let manifest = RunManifest(
            schema: Self.storageSchema,
            runID: requestedRunID,
            clientRunKey: clientRunKey,
            requestDigest: requestDigest,
            runHandle: handle,
            retentionSeconds: retentionSeconds
        )
        let directory = runsURL.appendingPathComponent(requestedRunID.uuidString.lowercased(), isDirectory: true)
        try Self.createRunDirectory(directory, manifest: manifest)
        let entry = RunEntry(
            manifest: manifest,
            directory: directory,
            machine: ManagedProcessStateMachine(runID: requestedRunID, retentionSeconds: retentionSeconds),
            nextSequence: 0,
            previousDigest: try Self.genesisDigest(for: manifest)
        )
        runs[requestedRunID] = entry
        runIDByClientKey[clientRunKey] = requestedRunID

        let request = ManagedSupervisorLaunchRequest(
            runID: requestedRunID,
            requestDigest: requestDigest,
            executableURL: executableURL,
            arguments: arguments,
            workingDirectoryURL: workingDirectoryURL,
            environment: environment,
            timeoutDeadline: timeoutDeadline,
            admittedAt: admittedAt,
            retentionSeconds: retentionSeconds
        )
        do {
            let identity = try await supervisor.launch(request)
            let snapshot = try commit(.process(.launchSucceeded(identity)), to: requestedRunID)
            return ManagedProcessRegistration(admission: .created(runID: requestedRunID), runHandle: handle, snapshot: snapshot)
        } catch {
            _ = try commit(
                .process(.launchFailed(stage: .spawn, osErrorCategory: Self.errorCategory(error))),
                to: requestedRunID
            )
            throw error
        }
    }

    public func observe(runHandle: String) throws -> ManagedRunSnapshot {
        let runID = try resolve(runHandle)
        return runs[runID]!.machine.snapshot
    }

    /// Supervisor又はfinalizerが観測したeventを、disk commit後にだけ公開する。
    @discardableResult
    public func record(runHandle: String, event: ManagedProcessEvent) throws -> ManagedRunSnapshot {
        let runID = try resolve(runHandle)
        return try commit(.process(event), to: runID)
    }

    @discardableResult
    public func recordEvidence(
        runHandle: String,
        stdoutBytes: Int = 0,
        stderrBytes: Int = 0,
        diagnosticBytes: Int = 0
    ) throws -> ManagedEvidenceCursor {
        let runID = try resolve(runHandle)
        return try commit(
            .evidence(stdout: stdoutBytes, stderr: stderrBytes, diagnostics: diagnosticBytes),
            to: runID
        ).cursor
    }

    /// cancel causeを先に永続化し、identity proofが取れたprocess groupだけを停止する。
    @discardableResult
    public func cancel(runHandle: String, acceptedAt: Date = Date()) async throws -> ManagedRunSnapshot {
        let runID = try resolve(runHandle)
        guard let entry = runs[runID] else { throw ManagedProcessRegistryError.runNotFound }
        let before = entry.machine.snapshot

        if before.state.isTerminal { return before }
        if before.state == .finalizing { throw ManagedProcessRegistryError.runNotCancellable }
        if before.state == .timingOut || before.state == .cancelling { return before }

        if before.state == .recoveryRequired {
            guard let identity = before.identity else { throw ManagedProcessRegistryError.runRecoveryRequired }
            let proof: ManagedProcessIdentityProof
            do {
                proof = try await supervisor.reconnect(runID: runID, expectedIdentity: identity)
            } catch {
                throw ManagedProcessRegistryError.runRecoveryRequired
            }
            guard proof.runID == runID, proof.expected == identity, proof.observed == identity else {
                throw ManagedProcessRegistryError.runRecoveryRequired
            }
            let snapshot = try commit(.verifiedRecoveryCancel(acceptedAt: acceptedAt, proof: proof), to: runID)
            _ = try await supervisor.stop(runID: runID, proof: proof)
            return snapshot
        }

        let cancelling = try commit(.process(.cancel(acceptedAt: acceptedAt)), to: runID)
        guard let identity = cancelling.identity else { return cancelling }
        do {
            let proof = try await supervisor.reconnect(runID: runID, expectedIdentity: identity)
            guard proof.runID == runID, proof.expected == identity, proof.observed == identity else {
                _ = try commit(.process(.supervisorUnavailable), to: runID)
                throw ManagedProcessRegistryError.runRecoveryRequired
            }
            _ = try await supervisor.stop(runID: runID, proof: proof)
            return cancelling
        } catch let error as ManagedProcessRegistryError {
            throw error
        } catch {
            _ = try commit(.process(.supervisorUnavailable), to: runID)
            throw ManagedProcessRegistryError.runRecoveryRequired
        }
    }

    /// 新adapter instanceが呼び、全active runを同じhandle/revision/cursorのまま再照合する。
    /// 一件の再接続失敗を他runの成功へ混ぜず、runごとのclosed outcomeを返す。
    public func recoverAfterServerRestart() async throws -> [ManagedProcessRecoveryResult] {
        var results: [ManagedProcessRecoveryResult] = []
        for runID in runs.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let current = runs[runID]?.machine.snapshot else { continue }
            if current.state.isTerminal {
                results.append(.init(runID: runID, state: .terminal, snapshot: current))
                continue
            }

            var recoverySnapshot = current
            if current.state != .recoveryRequired {
                recoverySnapshot = try commit(.process(.supervisorUnavailable), to: runID)
            }
            guard let identity = recoverySnapshot.identity else {
                results.append(.init(runID: runID, state: .recoveryRequired, snapshot: recoverySnapshot))
                continue
            }

            let proof: ManagedProcessIdentityProof
            do {
                proof = try await supervisor.reconnect(runID: runID, expectedIdentity: identity)
            } catch {
                results.append(.init(runID: runID, state: .recoveryRequired, snapshot: recoverySnapshot))
                continue
            }
            guard proof.runID == runID, proof.expected == identity, proof.observed == identity else {
                results.append(.init(runID: runID, state: .recoveryRequired, snapshot: recoverySnapshot))
                continue
            }
            let restored = try commit(.process(.recover(identity: identity)), to: runID)
            if restored.state == .cancelling {
                do {
                    _ = try await supervisor.stop(runID: runID, proof: proof)
                } catch {
                    let failed = try commit(.process(.supervisorUnavailable), to: runID)
                    results.append(.init(runID: runID, state: .recoveryRequired, snapshot: failed))
                    continue
                }
            }
            results.append(.init(runID: runID, state: .reconnected, snapshot: restored))
        }
        return results
    }

    private func resolve(_ runHandle: String) throws -> UUID {
        let components = runHandle.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2,
              let payloadData = Data(base64URL: String(components[0])),
              let signature = Data(base64URL: String(components[1]))
        else { throw ManagedProcessRegistryError.invalidRunHandle }
        let payload: HandlePayload
        do { payload = try Self.decoder.decode(HandlePayload.self, from: payloadData) }
        catch { throw ManagedProcessRegistryError.invalidRunHandle }
        guard payload.schema == Self.storageSchema else { throw ManagedProcessRegistryError.invalidRunHandle }
        guard payload.storeIdentity == storeIdentity else { throw ManagedProcessRegistryError.runStoreMismatch }
        guard HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: payloadData, using: handleKey) else {
            throw ManagedProcessRegistryError.invalidRunHandle
        }
        guard let entry = runs[payload.runID] else { throw ManagedProcessRegistryError.runNotFound }
        guard entry.manifest.runHandle == runHandle else { throw ManagedProcessRegistryError.invalidRunHandle }
        if let expiresAt = entry.machine.snapshot.expiresAt, entry.machine.snapshot.state.isTerminal, Date() >= expiresAt {
            throw ManagedProcessRegistryError.runExpired
        }
        return payload.runID
    }

    private func makeHandle(runID: UUID) throws -> String {
        let payload = HandlePayload(schema: Self.storageSchema, runID: runID, storeIdentity: storeIdentity)
        let data = try Self.encoder.encode(payload)
        let signature = Data(HMAC<SHA256>.authenticationCode(for: data, using: handleKey))
        return data.base64URLEncodedString() + "." + signature.base64URLEncodedString()
    }

    @discardableResult
    private func commit(_ event: DurableEvent, to runID: UUID) throws -> ManagedRunSnapshot {
        guard var entry = runs[runID] else { throw ManagedProcessRegistryError.runNotFound }
        var candidate = entry.machine
        try event.apply(to: &candidate)

        let envelope = try JournalEnvelope.make(
            sequence: entry.nextSequence,
            previousDigest: entry.previousDigest,
            event: event
        )
        try Self.append(envelope, to: entry.directory.appendingPathComponent("journal.jsonl"))
        entry.machine = candidate
        entry.nextSequence += 1
        entry.previousDigest = envelope.digest
        runs[runID] = entry
        return candidate.snapshot
    }
}

private extension ManagedProcessRegistry {
    struct RunEntry {
        let manifest: RunManifest
        let directory: URL
        var machine: ManagedProcessStateMachine
        var nextSequence: UInt64
        var previousDigest: String
    }

    struct RunManifest: Codable {
        let schema: String
        let runID: UUID
        let clientRunKey: String
        let requestDigest: String
        let runHandle: String
        let retentionSeconds: TimeInterval
    }

    struct Credentials: Codable {
        let schema: String
        let storeIdentity: UUID
        let secret: Data
    }

    struct HandlePayload: Codable {
        let schema: String
        let runID: UUID
        let storeIdentity: UUID
    }

    struct JournalEnvelope: Codable {
        let schema: String
        let sequence: UInt64
        let previousDigest: String
        let event: DurableEvent
        let digest: String

        static func make(sequence: UInt64, previousDigest: String, event: DurableEvent) throws -> Self {
            let unsigned = UnsignedJournalEnvelope(
                schema: ManagedProcessRegistry.storageSchema,
                sequence: sequence,
                previousDigest: previousDigest,
                event: event
            )
            let digest = ManagedProcessRegistry.sha256(try ManagedProcessRegistry.encoder.encode(unsigned))
            return Self(
                schema: unsigned.schema,
                sequence: sequence,
                previousDigest: previousDigest,
                event: event,
                digest: digest
            )
        }

        func validate() throws {
            guard schema == ManagedProcessRegistry.storageSchema else {
                throw ManagedProcessRegistryError.runStoreCorrupt("journal schema")
            }
            let unsigned = UnsignedJournalEnvelope(
                schema: schema,
                sequence: sequence,
                previousDigest: previousDigest,
                event: event
            )
            guard digest == ManagedProcessRegistry.sha256(try ManagedProcessRegistry.encoder.encode(unsigned)) else {
                throw ManagedProcessRegistryError.runStoreCorrupt("journal digest")
            }
        }
    }

    struct UnsignedJournalEnvelope: Codable {
        let schema: String
        let sequence: UInt64
        let previousDigest: String
        let event: DurableEvent
    }

    enum DurableEvent: Codable {
        case process(ManagedProcessEvent)
        case verifiedRecoveryCancel(acceptedAt: Date, proof: ManagedProcessIdentityProof)
        case evidence(stdout: Int, stderr: Int, diagnostics: Int)

        private enum CodingKeys: String, CodingKey {
            case kind, identity, stage, category, exitCode, signal, date, proofRunID, proofExpected, proofObserved
            case stdout, stderr, diagnostics, finalization
        }

        private enum Kind: String, Codable {
            case launchSucceeded, launchFailed, naturalExit, cancel, verifiedRecoveryCancel, timeout
            case evidenceQuotaExceeded, supervisorUnavailable, recover, recoveredProcessStopped
            case beginFinalization, commitFinalization, evidence
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            switch try values.decode(Kind.self, forKey: .kind) {
            case .launchSucceeded:
                self = .process(.launchSucceeded(try values.decode(ManagedProcessIdentity.self, forKey: .identity)))
            case .launchFailed:
                self = .process(.launchFailed(
                    stage: try values.decode(ManagedLaunchFailureStage.self, forKey: .stage),
                    osErrorCategory: try values.decode(String.self, forKey: .category)
                ))
            case .naturalExit:
                self = .process(.naturalExit(
                    exitCode: try values.decode(Int32.self, forKey: .exitCode),
                    signal: try values.decodeIfPresent(Int32.self, forKey: .signal)
                ))
            case .cancel:
                self = .process(.cancel(acceptedAt: try values.decode(Date.self, forKey: .date)))
            case .verifiedRecoveryCancel:
                let expected = try values.decode(ManagedProcessIdentity.self, forKey: .proofExpected)
                let observed = try values.decode(ManagedProcessIdentity.self, forKey: .proofObserved)
                self = .verifiedRecoveryCancel(
                    acceptedAt: try values.decode(Date.self, forKey: .date),
                    proof: ManagedProcessIdentityProof(
                        runID: try values.decode(UUID.self, forKey: .proofRunID),
                        expected: expected,
                        observed: observed
                    )
                )
            case .timeout:
                self = .process(.timeout(deadline: try values.decode(Date.self, forKey: .date)))
            case .evidenceQuotaExceeded: self = .process(.evidenceQuotaExceeded)
            case .supervisorUnavailable: self = .process(.supervisorUnavailable)
            case .recover: self = .process(.recover(identity: try values.decode(ManagedProcessIdentity.self, forKey: .identity)))
            case .recoveredProcessStopped: self = .process(.recoveredProcessStopped)
            case .beginFinalization: self = .process(.beginFinalization)
            case .commitFinalization:
                self = .process(.commitFinalization(try values.decode(DurableFinalization.self, forKey: .finalization).value))
            case .evidence:
                self = .evidence(
                    stdout: try values.decode(Int.self, forKey: .stdout),
                    stderr: try values.decode(Int.self, forKey: .stderr),
                    diagnostics: try values.decode(Int.self, forKey: .diagnostics)
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .process(event):
                switch event {
                case let .launchSucceeded(identity):
                    try values.encode(Kind.launchSucceeded, forKey: .kind)
                    try values.encode(identity, forKey: .identity)
                case let .launchFailed(stage, category):
                    try values.encode(Kind.launchFailed, forKey: .kind)
                    try values.encode(stage, forKey: .stage)
                    try values.encode(category, forKey: .category)
                case let .naturalExit(exitCode, signal):
                    try values.encode(Kind.naturalExit, forKey: .kind)
                    try values.encode(exitCode, forKey: .exitCode)
                    try values.encodeIfPresent(signal, forKey: .signal)
                case let .cancel(acceptedAt):
                    try values.encode(Kind.cancel, forKey: .kind)
                    try values.encode(acceptedAt, forKey: .date)
                case let .cancelAfterRecoveryVerification(acceptedAt, proof):
                    try values.encode(Kind.verifiedRecoveryCancel, forKey: .kind)
                    try values.encode(acceptedAt, forKey: .date)
                    try values.encode(proof.runID, forKey: .proofRunID)
                    try values.encode(proof.expected, forKey: .proofExpected)
                    try values.encode(proof.observed, forKey: .proofObserved)
                case let .timeout(deadline):
                    try values.encode(Kind.timeout, forKey: .kind)
                    try values.encode(deadline, forKey: .date)
                case .evidenceQuotaExceeded: try values.encode(Kind.evidenceQuotaExceeded, forKey: .kind)
                case .supervisorUnavailable: try values.encode(Kind.supervisorUnavailable, forKey: .kind)
                case let .recover(identity):
                    try values.encode(Kind.recover, forKey: .kind)
                    try values.encode(identity, forKey: .identity)
                case .recoveredProcessStopped: try values.encode(Kind.recoveredProcessStopped, forKey: .kind)
                case .beginFinalization: try values.encode(Kind.beginFinalization, forKey: .kind)
                case let .commitFinalization(bundle):
                    try values.encode(Kind.commitFinalization, forKey: .kind)
                    try values.encode(DurableFinalization(bundle), forKey: .finalization)
                }
            case let .verifiedRecoveryCancel(acceptedAt, proof):
                try values.encode(Kind.verifiedRecoveryCancel, forKey: .kind)
                try values.encode(acceptedAt, forKey: .date)
                try values.encode(proof.runID, forKey: .proofRunID)
                try values.encode(proof.expected, forKey: .proofExpected)
                try values.encode(proof.observed, forKey: .proofObserved)
            case let .evidence(stdout, stderr, diagnostics):
                try values.encode(Kind.evidence, forKey: .kind)
                try values.encode(stdout, forKey: .stdout)
                try values.encode(stderr, forKey: .stderr)
                try values.encode(diagnostics, forKey: .diagnostics)
            }
        }

        func apply(to machine: inout ManagedProcessStateMachine) throws {
            switch self {
            case let .process(event): _ = try machine.accept(event)
            case let .verifiedRecoveryCancel(acceptedAt, proof):
                _ = try machine.accept(.cancelAfterRecoveryVerification(acceptedAt: acceptedAt, proof: proof))
            case let .evidence(stdout, stderr, diagnostics):
                try machine.appendEvidence(stdoutBytes: stdout, stderrBytes: stderr, diagnosticBytes: diagnostics)
            }
        }

    }

    struct DurableFinalization: Codable {
        let stdout: ManagedArtifactIdentity
        let stderr: ManagedArtifactIdentity
        let diagnostics: ManagedArtifactIdentity
        let runIndexDigest: String
        let finalizedAt: Date

        init(_ value: ManagedFinalizationBundle) {
            stdout = value.stdout
            stderr = value.stderr
            diagnostics = value.diagnostics
            runIndexDigest = value.runIndexDigest
            finalizedAt = value.finalizedAt
        }

        var value: ManagedFinalizationBundle {
            ManagedFinalizationBundle(
                stdout: stdout,
                stderr: stderr,
                diagnostics: diagnostics,
                runIndexDigest: runIndexDigest,
                finalizedAt: finalizedAt
            )
        }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    static func loadOrCreateCredentials(in rootURL: URL) throws -> Credentials {
        let url = rootURL.appendingPathComponent("credentials.json")
        if FileManager.default.fileExists(atPath: url.path) {
            try requirePrivateRegularFile(url)
            let credentials = try decoder.decode(Credentials.self, from: Data(contentsOf: url))
            guard credentials.schema == storageSchema, credentials.secret.count == 32 else {
                throw ManagedProcessRegistryError.runStoreCorrupt("credentials")
            }
            return credentials
        }
        var secret = Data(count: 32)
        let status = secret.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw ManagedProcessRegistryError.runStoreCorrupt("random source") }
        let credentials = Credentials(schema: storageSchema, storeIdentity: UUID(), secret: secret)
        try writeAtomically(try encoder.encode(credentials), to: url, permissions: 0o600)
        return credentials
    }

    static func loadRuns(from runsURL: URL) throws -> (runs: [UUID: RunEntry], runIDByClientKey: [String: UUID]) {
        var runs: [UUID: RunEntry] = [:]
        var keys: [String: UUID] = [:]
        let directories = try FileManager.default.contentsOfDirectory(
            at: runsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        for directory in directories {
            try requirePrivateDirectory(directory)
            let manifestURL = directory.appendingPathComponent("manifest.json")
            let journalURL = directory.appendingPathComponent("journal.jsonl")
            try requirePrivateRegularFile(manifestURL)
            try requirePrivateRegularFile(journalURL)
            let manifest = try decoder.decode(
                RunManifest.self,
                from: Data(contentsOf: manifestURL)
            )
            guard manifest.schema == storageSchema,
                  directory.lastPathComponent == manifest.runID.uuidString.lowercased(),
                  manifest.retentionSeconds >= 0,
                  runs[manifest.runID] == nil,
                  keys[manifest.clientRunKey] == nil
            else { throw ManagedProcessRegistryError.runStoreCorrupt("manifest binding") }

            var machine = ManagedProcessStateMachine(runID: manifest.runID, retentionSeconds: manifest.retentionSeconds)
            var expectedSequence: UInt64 = 0
            var previousDigest = try genesisDigest(for: manifest)
            let data = try Data(contentsOf: journalURL)
            if !data.isEmpty, data.last != 0x0A {
                throw ManagedProcessRegistryError.runStoreCorrupt("partial journal record")
            }
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                let envelope = try decoder.decode(JournalEnvelope.self, from: Data(line))
                try envelope.validate()
                guard envelope.sequence == expectedSequence, envelope.previousDigest == previousDigest else {
                    throw ManagedProcessRegistryError.runStoreCorrupt("journal chain")
                }
                try envelope.event.apply(to: &machine)
                expectedSequence += 1
                previousDigest = envelope.digest
            }
            runs[manifest.runID] = RunEntry(
                manifest: manifest,
                directory: directory,
                machine: machine,
                nextSequence: expectedSequence,
                previousDigest: previousDigest
            )
            keys[manifest.clientRunKey] = manifest.runID
        }
        return (runs, keys)
    }

    static func createRunDirectory(_ directory: URL, manifest: RunManifest) throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw ManagedProcessRegistryError.runStoreCorrupt("run directory exists")
        }
        try ensurePrivateDirectory(directory)
        try writeAtomically(try encoder.encode(manifest), to: directory.appendingPathComponent("manifest.json"), permissions: 0o600)
        guard FileManager.default.createFile(
            atPath: directory.appendingPathComponent("journal.jsonl").path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ) else { throw ManagedProcessRegistryError.runStoreCorrupt("journal create") }
    }

    static func append(_ envelope: JournalEnvelope, to url: URL) throws {
        var data = try encoder.encode(envelope)
        data.append(0x0A)
        try requirePrivateRegularFile(url)
        let descriptor = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ManagedProcessRegistryError.runStoreCorrupt("journal open") }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(descriptor, base.advanced(by: written), bytes.count - written)
                guard result > 0 else { throw ManagedProcessRegistryError.runStoreCorrupt("journal write") }
                written += result
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw ManagedProcessRegistryError.runStoreCorrupt("journal fsync")
        }
    }

    static func ensurePrivateDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try requirePrivateDirectory(url, allowRepairableMode: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func requirePrivateDirectory(_ url: URL, allowRepairableMode: Bool = false) throws {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == geteuid(),
              allowRepairableMode || information.st_mode & 0o077 == 0
        else { throw ManagedProcessRegistryError.runStoreCorrupt("unsafe directory") }
    }

    static func requirePrivateRegularFile(_ url: URL) throws {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              information.st_mode & 0o077 == 0
        else { throw ManagedProcessRegistryError.runStoreCorrupt("unsafe file") }
    }

    static func writeAtomically(_ data: Data, to url: URL, permissions: Int) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    static func genesisDigest(for manifest: RunManifest) throws -> String {
        sha256(try encoder.encode(manifest))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func errorCategory(_ error: Error) -> String {
        if let cocoa = error as? CocoaError { return "cocoa_\(cocoa.code.rawValue)" }
        let nsError = error as NSError
        return "\(nsError.domain)_\(nsError.code)"
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: value)
    }
}
