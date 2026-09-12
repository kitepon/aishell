import CryptoKit
import Darwin
import Foundation

public enum ManagedRunArtifactStoreError: Error, Equatable, Sendable {
    case bindingMismatch
    case runNotFinalized
    case artifactNotFound
    case runExpired
    case scopeMismatch
    case legacyArtifactUnbound
    case storeCorrupt(String)
}

public struct ManagedRunArtifactRecord: Codable, Equatable, Sendable {
    public let schema: String
    public let runID: UUID
    public let requestDigest: String
    public let projectID: String?
    public let storeIdentityDigest: String?
    public let executablePath: String?
    public let arguments: [String]?
    public let workingDirectoryPath: String?
    public let environmentDigest: String?
    public let toolchainBinding: String?
    public let inputBinding: String?
    public let stdout: ManagedArtifactIdentity
    public let stderr: ManagedArtifactIdentity
    public let diagnostics: ManagedArtifactIdentity
    public let finalizedAt: Date
    public let expiresAt: Date?

    public init(
        runID: UUID,
        requestDigest: String,
        projectID: String? = nil,
        storeIdentityDigest: String? = nil,
        executablePath: String? = nil,
        arguments: [String]? = nil,
        workingDirectoryPath: String? = nil,
        environmentDigest: String? = nil,
        toolchainBinding: String? = nil,
        inputBinding: String? = nil,
        stdout: ManagedArtifactIdentity,
        stderr: ManagedArtifactIdentity,
        diagnostics: ManagedArtifactIdentity,
        finalizedAt: Date,
        expiresAt: Date? = nil
    ) {
        schema = "aishell.managed-run-index.v1"
        self.runID = runID
        self.requestDigest = requestDigest
        self.projectID = projectID
        self.storeIdentityDigest = storeIdentityDigest
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectoryPath = workingDirectoryPath
        self.environmentDigest = environmentDigest
        self.toolchainBinding = toolchainBinding
        self.inputBinding = inputBinding
        self.stdout = stdout
        self.stderr = stderr
        self.diagnostics = diagnostics
        self.finalizedAt = finalizedAt
        self.expiresAt = expiresAt
    }
}

/// managed runの3 artifactとrun indexを、一つのdirectory renameで同時公開する。
/// stagingは公開検索面から見えず、再試行は同じbindingだけを冪等に受理する。
public actor ManagedRunArtifactStore: ManagedSpoolFinalizationSeam {
    private let runtimeStore: RuntimeStore
    public static let storageSchema = "aishell.managed-run-index.v1"

    private let publicRootURL: URL
    private let stagingRootURL: URL
    public nonisolated let storeIdentityDigest: String
    private var pending: PendingPublication?

    public init(runtimeStore: RuntimeStore = RuntimeStore()) throws {
        self.runtimeStore = runtimeStore
        let root = runtimeStore.baseDirectory
            .appendingPathComponent("managed-runs", isDirectory: true)
            .appendingPathComponent("artifacts", isDirectory: true)
        try Self.ensurePrivateDirectory(root)
        publicRootURL = root.appendingPathComponent("published", isDirectory: true)
        stagingRootURL = root.appendingPathComponent("staging", isDirectory: true)
        storeIdentityDigest = try Self.loadOrCreateStoreIdentity(root: root)
        try Self.ensurePrivateDirectory(publicRootURL)
        try Self.ensurePrivateDirectory(stagingRootURL)
    }

    public func prepare(
        runID: UUID,
        requestDigest: String,
        projectID: String? = nil,
        executablePath: String? = nil,
        arguments: [String]? = nil,
        workingDirectoryPath: String? = nil,
        environmentDigest: String? = nil,
        toolchainBinding: String? = nil,
        inputBinding: String? = nil,
        expiresAt: Date? = nil,
        stdoutURL: URL,
        stderrURL: URL,
        diagnosticURL: URL
    ) {
        pending = PendingPublication(
            runID: runID,
            requestDigest: requestDigest,
            projectID: projectID,
            executablePath: executablePath,
            arguments: arguments,
            workingDirectoryPath: workingDirectoryPath,
            environmentDigest: environmentDigest,
            toolchainBinding: toolchainBinding,
            inputBinding: inputBinding,
            expiresAt: expiresAt,
            stdoutURL: stdoutURL,
            stderrURL: stderrURL,
            diagnosticURL: diagnosticURL
        )
    }

    public func fsyncAndInspect(stdoutURL: URL, stderrURL: URL) throws -> ManagedSpoolInspection {
        guard let pending, pending.stdoutURL == stdoutURL, pending.stderrURL == stderrURL else {
            throw ManagedRunArtifactStoreError.bindingMismatch
        }
        return ManagedSpoolInspection(
            stdout: try Self.inspect(
                stdoutURL,
                handle: Self.artifactHandle(runID: pending.runID, channel: "stdout")
            ),
            stderr: try Self.inspect(
                stderrURL,
                handle: Self.artifactHandle(runID: pending.runID, channel: "stderr")
            )
        )
    }

    public func publishAtomically(
        inspection: ManagedSpoolInspection,
        diagnostics: ManagedArtifactIdentity,
        finalizedAt: Date
    ) throws -> ManagedFinalizationBundle {
        guard let pending else { throw ManagedRunArtifactStoreError.bindingMismatch }
        let publishedURL = publicRunURL(pending.runID)
        let record = ManagedRunArtifactRecord(
            runID: pending.runID,
            requestDigest: pending.requestDigest,
            projectID: pending.projectID,
            storeIdentityDigest: pending.projectID == nil ? nil : storeIdentityDigest,
            executablePath: pending.executablePath,
            arguments: pending.arguments,
            workingDirectoryPath: pending.workingDirectoryPath,
            environmentDigest: pending.environmentDigest,
            toolchainBinding: pending.toolchainBinding,
            inputBinding: pending.inputBinding,
            stdout: inspection.stdout,
            stderr: inspection.stderr,
            diagnostics: diagnostics,
            finalizedAt: finalizedAt,
            expiresAt: pending.expiresAt
        )
        if FileManager.default.fileExists(atPath: publishedURL.path) {
            let existing = try loadRecord(runID: pending.runID)
            guard existing == record else { throw ManagedRunArtifactStoreError.bindingMismatch }
            return Self.bundle(record)
        }

        let stagingURL = stagingRootURL.appendingPathComponent(
            pending.runID.uuidString.lowercased(), isDirectory: true
        )
        if FileManager.default.fileExists(atPath: stagingURL.path) {
            try FileManager.default.removeItem(at: stagingURL)
        }
        try Self.ensurePrivateDirectory(stagingURL)
        do {
            try Self.copyAndSync(pending.stdoutURL, to: stagingURL.appendingPathComponent("stdout.artifact"))
            try Self.copyAndSync(pending.stderrURL, to: stagingURL.appendingPathComponent("stderr.artifact"))
            let diagnosticData = try Data(contentsOf: pending.diagnosticURL, options: .mappedIfSafe)
            guard UInt64(diagnosticData.count) == diagnostics.sizeBytes,
                  Self.digest(diagnosticData) == diagnostics.sha256 else {
                throw ManagedRunArtifactStoreError.bindingMismatch
            }
            try Self.writeAndSync(diagnosticData, to: stagingURL.appendingPathComponent("diagnostic.artifact"))
            try Self.writeAndSync(
                try Self.encoder.encode(record),
                to: stagingURL.appendingPathComponent("registry-index.json")
            )
            try Self.fsyncDirectory(stagingURL)
            try FileManager.default.moveItem(at: stagingURL, to: publishedURL)
            try Self.fsyncDirectory(publicRootURL)
        } catch {
            if FileManager.default.fileExists(atPath: publishedURL.path) {
                try? FileManager.default.removeItem(at: publishedURL)
                try? Self.fsyncDirectory(publicRootURL)
            }
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
        return Self.bundle(record)
    }

    public func loadRecord(runID: UUID) throws -> ManagedRunArtifactRecord {
        let runURL = publicRunURL(runID)
        guard FileManager.default.fileExists(atPath: runURL.path) else {
            throw ManagedRunArtifactStoreError.runNotFinalized
        }
        let record = try Self.decoder.decode(
            ManagedRunArtifactRecord.self,
            from: Data(contentsOf: runURL.appendingPathComponent("registry-index.json"))
        )
        guard record.schema == Self.storageSchema, record.runID == runID else {
            throw ManagedRunArtifactStoreError.storeCorrupt("run index binding")
        }
        try verify(record, in: runURL)
        return record
    }

    public func read(handle: String, mode: ArtifactReadMode, byteBudget: Int) throws -> ArtifactSlice {
        let parts = handle.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "run", parts[1].count == 32 else {
            throw ManagedRunArtifactStoreError.artifactNotFound
        }
        let hex = parts[1]
        let uuid = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.suffix(12))"
        guard let runID = UUID(uuidString: uuid), FileManager.default.fileExists(atPath: publicRunURL(runID).path) else {
            throw ManagedRunArtifactStoreError.artifactNotFound
        }
        // handleに束縛されたrunだけを検証する。他のrunの走査や別storeへの再試行はしない。
        let record = try loadRecord(runID: runID)
        guard let projectID = record.projectID else {
            throw ManagedRunArtifactStoreError.legacyArtifactUnbound
        }
        try requireScope(record, projectID: projectID)
        let expiresAt = try retainedExpiry(record)
        guard expiresAt > Date() else { throw AIShellError.handleExpired(handle) }
        let entries = [(record.stdout, "stdout.artifact"), (record.stderr, "stderr.artifact"),
                       (record.diagnostics, "diagnostic.artifact")]
        guard let (identity, name) = entries.first(where: { $0.0.handle == handle }) else {
            throw ManagedRunArtifactStoreError.artifactNotFound
        }
        return try EvidenceStore.readSlice(handle: handle, url: publicRunURL(runID).appendingPathComponent(name),
            totalBytes: Int(identity.sizeBytes), sha256: identity.sha256, expiresAt: expiresAt,
            mode: mode, byteBudget: byteBudget)
    }

    public func artifact(handle: String) throws -> ArtifactQueryService.Artifact {
        let directories = try FileManager.default.contentsOfDirectory(
            at: publicRootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for directory in directories {
            guard let runID = UUID(uuidString: directory.lastPathComponent) else { continue }
            let record = try loadRecord(runID: runID)
            for (identity, name, kind) in [
                (record.stdout, "stdout.artifact", "stdout"),
                (record.stderr, "stderr.artifact", "stderr"),
                (record.diagnostics, "diagnostic.artifact", "diagnostic")
            ] where identity.handle == handle {
                return ArtifactQueryService.Artifact(
                    id: handle,
                    kind: kind,
                    data: try Data(contentsOf: directory.appendingPathComponent(name), options: .mappedIfSafe)
                )
            }
        }
        throw ManagedRunArtifactStoreError.artifactNotFound
    }

    public func queryArtifact(handle: String, projectID: String) throws -> ArtifactQueryService.Artifact {
        let (record, artifact) = try boundArtifact(handle: handle)
        try requireScope(record, projectID: projectID)
        if try retainedExpiry(record) <= Date() {
            throw ManagedRunArtifactStoreError.artifactNotFound
        }
        return artifact
    }

    public func queryArtifacts(
        runID: UUID,
        channels: Set<String> = ["stdout", "stderr"],
        projectID: String
    ) throws -> [ArtifactQueryService.Artifact] {
        let record = try loadRecord(runID: runID)
        try requireScope(record, projectID: projectID)
        if try retainedExpiry(record) <= Date() {
            throw ManagedRunArtifactStoreError.runExpired
        }
        return try artifacts(runID: runID, channels: channels).map { artifact in
            ArtifactQueryService.Artifact(
                id: artifact.id,
                kind: artifact.kind,
                data: artifact.data,
                historyBinding: .init(
                    request: record.requestDigest,
                    toolchain: record.toolchainBinding,
                    input: record.inputBinding
                )
            )
        }
    }

    public func artifacts(runID: UUID, channels: Set<String> = ["stdout", "stderr"]) throws -> [ArtifactQueryService.Artifact] {
        let record = try loadRecord(runID: runID)
        let directory = publicRunURL(runID)
        var result: [ArtifactQueryService.Artifact] = []
        if channels.contains("stdout") {
            result.append(.init(id: record.stdout.handle, kind: "stdout", data: try Data(
                contentsOf: directory.appendingPathComponent("stdout.artifact"), options: .mappedIfSafe
            )))
        }
        if channels.contains("stderr") {
            result.append(.init(id: record.stderr.handle, kind: "stderr", data: try Data(
                contentsOf: directory.appendingPathComponent("stderr.artifact"), options: .mappedIfSafe
            )))
        }
        if channels.contains("diagnostics") {
            result.append(.init(id: record.diagnostics.handle, kind: "diagnostic", data: try Data(
                contentsOf: directory.appendingPathComponent("diagnostic.artifact"), options: .mappedIfSafe
            )))
        }
        return result
    }

    private struct PendingPublication {
        let runID: UUID
        let requestDigest: String
        let projectID: String?
        let executablePath: String?
        let arguments: [String]?
        let workingDirectoryPath: String?
        let environmentDigest: String?
        let toolchainBinding: String?
        let inputBinding: String?
        let expiresAt: Date?
        let stdoutURL: URL
        let stderrURL: URL
        let diagnosticURL: URL
    }

    private func boundArtifact(handle: String) throws -> (ManagedRunArtifactRecord, ArtifactQueryService.Artifact) {
        let directories = try FileManager.default.contentsOfDirectory(
            at: publicRootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for directory in directories {
            guard let runID = UUID(uuidString: directory.lastPathComponent) else { continue }
            let record = try loadRecord(runID: runID)
            for (identity, name, kind) in [
                (record.stdout, "stdout.artifact", "stdout"),
                (record.stderr, "stderr.artifact", "stderr"),
                (record.diagnostics, "diagnostic.artifact", "diagnostic")
            ] where identity.handle == handle {
                let artifact = ArtifactQueryService.Artifact(
                    id: handle,
                    kind: kind,
                    data: try Data(contentsOf: directory.appendingPathComponent(name), options: .mappedIfSafe),
                    historyBinding: .init(
                        request: record.requestDigest,
                        toolchain: record.toolchainBinding,
                        input: record.inputBinding
                    )
                )
                return (record, artifact)
            }
        }
        throw ManagedRunArtifactStoreError.artifactNotFound
    }

    private func retainedExpiry(_ record: ManagedRunArtifactRecord) throws -> Date {
        if let expiresAt = record.expiresAt { return expiresAt }
        return try ManagedProcessRegistry.retainedArtifactExpiry(store: runtimeStore,
            runID: record.runID, requestDigest: record.requestDigest, finalizedAt: record.finalizedAt)
    }

    private func requireScope(_ record: ManagedRunArtifactRecord, projectID: String) throws {
        guard let boundProject = record.projectID, let boundStore = record.storeIdentityDigest else {
            throw ManagedRunArtifactStoreError.legacyArtifactUnbound
        }
        guard boundProject == projectID, boundStore == storeIdentityDigest else {
            throw ManagedRunArtifactStoreError.scopeMismatch
        }
    }

    private func publicRunURL(_ runID: UUID) -> URL {
        publicRootURL.appendingPathComponent(runID.uuidString.lowercased(), isDirectory: true)
    }

    private func verify(_ record: ManagedRunArtifactRecord, in directory: URL) throws {
        for (identity, name) in [
            (record.stdout, "stdout.artifact"),
            (record.stderr, "stderr.artifact"),
            (record.diagnostics, "diagnostic.artifact")
        ] {
            let data = try Data(contentsOf: directory.appendingPathComponent(name), options: .mappedIfSafe)
            guard UInt64(data.count) == identity.sizeBytes, Self.digest(data) == identity.sha256 else {
                throw ManagedRunArtifactStoreError.storeCorrupt("artifact digest")
            }
        }
    }

    private static func bundle(_ record: ManagedRunArtifactRecord) -> ManagedFinalizationBundle {
        ManagedFinalizationBundle(
            stdout: record.stdout,
            stderr: record.stderr,
            diagnostics: record.diagnostics,
            runIndexDigest: digest((try? encoder.encode(record)) ?? Data()),
            finalizedAt: record.finalizedAt
        )
    }

    private static func artifactHandle(runID: UUID, channel: String) -> String {
        "run_\(runID.uuidString.replacingOccurrences(of: "-", with: "").lowercased())_\(channel)"
    }

    private static func inspect(_ url: URL, handle: String) throws -> ManagedArtifactIdentity {
        let file = try FileHandle(forWritingTo: url)
        try file.synchronize()
        try file.close()
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return ManagedArtifactIdentity(
            handle: handle,
            sizeBytes: UInt64(data.count),
            lineCount: UInt64(data.reduce(0) { $1 == 0x0a ? $0 + 1 : $0 }),
            sha256: digest(data)
        )
    }

    private static func copyAndSync(_ source: URL, to destination: URL) throws {
        try writeAndSync(try Data(contentsOf: source, options: .mappedIfSafe), to: destination)
    }

    private static func writeAndSync(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(
            atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]
        ) else { throw ManagedRunArtifactStoreError.storeCorrupt("artifact create") }
        let file = try FileHandle(forWritingTo: url)
        do {
            try file.write(contentsOf: data)
            try file.synchronize()
            try file.close()
        } catch {
            try? file.close()
            throw error
        }
    }

    private static func fsyncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ManagedRunArtifactStoreError.storeCorrupt("directory open") }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw ManagedRunArtifactStoreError.storeCorrupt("directory fsync")
        }
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func loadOrCreateStoreIdentity(root: URL) throws -> String {
        let url = root.appendingPathComponent("store-identity")
        let identity: String
        if FileManager.default.fileExists(atPath: url.path) {
            identity = String(decoding: try Data(contentsOf: url), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard UUID(uuidString: identity) != nil else {
                throw ManagedRunArtifactStoreError.storeCorrupt("store identity")
            }
        } else {
            identity = UUID().uuidString.lowercased()
            try Data((identity + "\n").utf8).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try fsyncDirectory(root)
        }
        return digest(Data(identity.utf8))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
