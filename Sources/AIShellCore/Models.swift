import Foundation

public struct RuntimeConfiguration: Codable, Equatable, Sendable {
    public var isPaused: Bool
    public var updatedAt: Date

    public init(isPaused: Bool = false, updatedAt: Date = Date()) {
        self.isPaused = isPaused
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case isPaused, updatedAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

public struct OperationRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let operation: String
    public let target: String
    public let success: Bool
    public let message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        operation: String,
        target: String,
        success: Bool,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.operation = operation
        self.target = target
        self.success = success
        self.message = message
    }
}

public struct FileEntry: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int64?
    public let modifiedAt: Date?

    public init(
        name: String,
        path: String,
        isDirectory: Bool,
        size: Int64?,
        modifiedAt: Date?
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

public struct FileStat: Codable, Equatable, Sendable {
    public let entry: FileEntry
    public let sha256: String?
    public let posixPermissions: Int?

    public init(entry: FileEntry, sha256: String?, posixPermissions: Int?) {
        self.entry = entry
        self.sha256 = sha256
        self.posixPermissions = posixPermissions
    }
}

public struct FileTreeEntry: Codable, Equatable, Sendable {
    public let depth: Int
    public let entry: FileEntry

    public init(depth: Int, entry: FileEntry) {
        self.depth = depth
        self.entry = entry
    }
}

public struct ProcessExecutionResult: Codable, Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String
    public let exitCode: Int32
    public let terminationReason: String
    public let timedOut: Bool
    public let durationMilliseconds: Int
    public let stdout: String
    public let stderr: String
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool

    public init(
        executable: String,
        arguments: [String],
        workingDirectory: String,
        exitCode: Int32,
        terminationReason: String,
        timedOut: Bool,
        durationMilliseconds: Int,
        stdout: String,
        stderr: String,
        stdoutTruncated: Bool,
        stderrTruncated: Bool
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.exitCode = exitCode
        self.terminationReason = terminationReason
        self.timedOut = timedOut
        self.durationMilliseconds = durationMilliseconds
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }
}

public struct PreparedProcessInvocation: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let workingDirectoryURL: URL
    public let environment: [String: String]

    public init(
        executableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL,
        environment: [String: String]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectoryURL = workingDirectoryURL
        self.environment = environment
    }
}

public struct ArtifactMetadata: Codable, Equatable, Sendable {
    public let handle: String
    public let kind: String
    public let sizeBytes: Int
    public let lineCount: Int
    public let sha256: String
    public let createdAt: Date
    public let expiresAt: Date
    public let producer: String

    public init(
        handle: String,
        kind: String,
        sizeBytes: Int,
        lineCount: Int,
        sha256: String,
        createdAt: Date,
        expiresAt: Date,
        producer: String
    ) {
        self.handle = handle
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.lineCount = lineCount
        self.sha256 = sha256
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.producer = producer
    }
}

public enum ArtifactReadMode: Equatable, Sendable {
    case range(offset: Int, length: Int)
    case tail(lines: Int)
    case around(pattern: String, contextLines: Int)
}

public struct ArtifactSlice: Codable, Equatable, Sendable {
    public let handle: String
    public let encoding: String
    public let text: String?
    public let base64: String?
    public let offset: Int
    public let returnedBytes: Int
    public let totalBytes: Int
    public let omittedBytes: Int
    public let eof: Bool
    public let sha256: String
    public let expiresAt: Date
    public let matchLine: Int?

    public init(
        handle: String,
        encoding: String,
        text: String?,
        base64: String?,
        offset: Int,
        returnedBytes: Int,
        totalBytes: Int,
        omittedBytes: Int,
        eof: Bool,
        sha256: String,
        expiresAt: Date,
        matchLine: Int?
    ) {
        self.handle = handle
        self.encoding = encoding
        self.text = text
        self.base64 = base64
        self.offset = offset
        self.returnedBytes = returnedBytes
        self.totalBytes = totalBytes
        self.omittedBytes = omittedBytes
        self.eof = eof
        self.sha256 = sha256
        self.expiresAt = expiresAt
        self.matchLine = matchLine
    }
}

public enum RunCheckStatus: String, Codable, Equatable, Sendable {
    case passed
    case failed
    case timedOut = "timed_out"
}

public struct RetainedProcessExecution: Codable, Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String
    public let processIdentifier: Int32
    public let exitCode: Int32
    public let terminationReason: String
    public let timedOut: Bool
    public let durationMilliseconds: Int
    public let stdoutArtifact: ArtifactMetadata
    public let stderrArtifact: ArtifactMetadata
}

public struct RunCheckResult: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let requestID: String
    public let status: RunCheckStatus
    public let summary: String
    public let primaryDiagnostic: String?
    public let exitCode: Int32
    public let timedOut: Bool
    public let durationMilliseconds: Int
    public let stdoutArtifact: ArtifactMetadata
    public let stderrArtifact: ArtifactMetadata
}

public struct WorkspaceEntry: Codable, Equatable, Sendable {
    public let path: String
    public let identity: String
    public let isDirectory: Bool
    public let sizeBytes: Int64
    public let modifiedAt: Date?
    public let sha256: String?
}

public enum WorkspaceChangeKind: String, Codable, Equatable, Sendable {
    case created
    case modified
    case deleted
    case renamed
}

public struct WorkspaceChange: Codable, Equatable, Sendable {
    public let kind: WorkspaceChangeKind
    public let path: String
    public let previousPath: String?
    public let entry: WorkspaceEntry?
}

public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let root: String
    public let cursor: String
    public let isFull: Bool
    public let freshness: String
    public let checkpointState: String?
    public let entries: [WorkspaceEntry]
    public let changes: [WorkspaceChange]
    public let omittedEntries: Int
    public let manifests: [String]
    public let guidanceFiles: [String]
    public let testCandidates: [String]
    public let gitStatusState: String
    public let gitStatus: [String]
    public let context: [ContextChunk]
}

public struct ContextChunk: Codable, Equatable, Sendable {
    public let path: String
    public let text: String
    public let sha256: String
    public let sizeBytes: Int
    public let returnedBytes: Int
    public let omittedBytes: Int
}

public struct ReadContextResult: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let chunks: [ContextChunk]
    public let returnedBytes: Int
    public let omittedBytes: Int
    public let continuation: String?
}

public struct SearchContextMatch: Codable, Equatable, Sendable {
    public let path: String
    public let line: Int
    public let text: String
    public let score: Int
}

public struct SearchContextResult: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let query: String
    public let worker: String
    public let matches: [SearchContextMatch]
    public let omittedMatches: Int
    public let returnedBytes: Int
    public let omittedBytes: Int
    public let continuation: String?
    public let freshness: String
}

public struct RunningApplicationInfo: Codable, Equatable, Sendable {
    public let name: String
    public let bundleIdentifier: String?
    public let processIdentifier: Int32
    public let isActive: Bool

    public init(
        name: String,
        bundleIdentifier: String?,
        processIdentifier: Int32,
        isActive: Bool
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.isActive = isActive
    }
}

public struct InstalledApplicationInfo: Codable, Equatable, Sendable {
    public let name: String
    public let bundleIdentifier: String?
    public let path: String

    public init(name: String, bundleIdentifier: String?, path: String) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.path = path
    }
}

public enum AIShellError: LocalizedError, Equatable, Sendable {
    case paused
    case outsideWorkspace(String)
    case invalidPath(String)
    case reservedPath(String)
    case itemAlreadyExists(String)
    case itemNotFound(String)
    case notTextFile(String)
    case textFileTooLarge(Int)
    case applicationNotFound(String)
    case applicationActivationFailed(String)
    case contentChanged(String)
    case executableNotAllowed(String)
    case processLaunchFailed(String)
    case handleNotFound(String)
    case handleExpired(String)
    case evidenceQuotaExceeded(Int)
    case checkpointCorrupt(String)
    case checkpointUnsupported(String)
    case checkpointMigrationFailed(String)
    case checkpointQuotaExceeded(String)
    case checkpointWriteFailed(String)
    case cursorExpired(String)
    case rescanRequired(String)
    case workerUnavailable(String)
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .paused:
            "AI操作は停止中です。runtime_open_managerでAIShellを開き、管理画面で再開してください。"
        case let .outsideWorkspace(path):
            "指定したworkspaceの範囲外です: \(path)"
        case let .invalidPath(path):
            "パスが不正です: \(path)"
        case let .reservedPath(path):
            "RESERVED_PATH: AIShell内部予約namespaceは公開操作の対象にできません: \(path)"
        case let .itemAlreadyExists(path):
            "既に項目が存在します: \(path)"
        case let .itemNotFound(path):
            "項目が見つかりません: \(path)"
        case let .notTextFile(path):
            "UTF-8テキストとして読み取れません: \(path)"
        case let .textFileTooLarge(limit):
            "テキストファイルが上限（\(limit) bytes）を超えています。"
        case let .applicationNotFound(identifier):
            "アプリが見つかりません: \(identifier)"
        case let .applicationActivationFailed(identifier):
            "アプリを前面化できません: \(identifier)"
        case let .contentChanged(path):
            "読み取り後に内容が変わったため更新を中止しました: \(path)"
        case let .executableNotAllowed(path):
            "直接実行できないプログラムです: \(path)"
        case let .processLaunchFailed(message):
            "プログラムを起動できません: \(message)"
        case let .handleNotFound(handle):
            "ARTIFACT_NOT_FOUND: handleが見つかりません: \(handle)"
        case let .handleExpired(handle):
            "HANDLE_EXPIRED: retention期限を過ぎています: \(handle)"
        case let .evidenceQuotaExceeded(limit):
            "EVIDENCE_QUOTA_EXCEEDED: evidence容量上限（\(limit) bytes）を超えます。"
        case let .checkpointCorrupt(reason):
            "CHECKPOINT_CORRUPT: \(reason)"
        case let .checkpointUnsupported(schema):
            "CHECKPOINT_UNSUPPORTED: schemaを読み取れません: \(schema)"
        case let .checkpointMigrationFailed(reason):
            "CHECKPOINT_MIGRATION_FAILED: \(reason)"
        case let .checkpointQuotaExceeded(detail):
            "CHECKPOINT_QUOTA_EXCEEDED: \(detail)"
        case let .checkpointWriteFailed(reason):
            "CHECKPOINT_WRITE_FAILED: \(reason)"
        case let .cursorExpired(cursor):
            "CURSOR_EXPIRED: cursorを継続できません: \(cursor)"
        case let .rescanRequired(reason):
            "RESCAN_REQUIRED: \(reason)"
        case let .workerUnavailable(worker):
            "WORKER_UNAVAILABLE: 実行可能な\(worker)が見つかりません。"
        case let .invalidArgument(message):
            "引数が不正です: \(message)"
        }
    }
}
