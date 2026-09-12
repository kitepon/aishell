import Foundation

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


public struct FileSearchResult: Codable, Equatable, Sendable {
    public let entries: [FileEntry]
    public let hasMore: Bool
}
public struct FileTreeResult: Codable, Equatable, Sendable {
    public let entries: [FileTreeEntry]
    public let hasMore: Bool
}
public struct ProcessOutput: Codable, Equatable, Sendable {
    public let encoding: String
    public let data: String

    init(_ bytes: Data) {
        if let text = String(data: bytes, encoding: .utf8) {
            encoding = "utf8"
            data = text
        } else {
            encoding = "base64"
            data = bytes.base64EncodedString()
        }
    }
}
public struct ProcessExecutionResult: Codable, Equatable, Sendable {
    public let exitCode: Int32
    public let terminationReason: String
    public let timedOut: Bool
    public let stdout: ProcessOutput
    public let stderr: ProcessOutput
}
public enum AIShellError: LocalizedError, Equatable, Sendable {
    case invalidPath(String)
    case itemAlreadyExists(String)
    case itemNotFound(String)
    case notTextFile(String)
    case applicationNotFound(String)
    case applicationActivationFailed(String)
    case contentChanged(String)
    case executableNotFound(String)
    case processLaunchFailed(String)
    case invalidArgument(String)

    public var code: String {
        switch self {
        case .invalidPath: "INVALID_PATH"
        case .itemAlreadyExists: "ITEM_ALREADY_EXISTS"
        case .itemNotFound: "ITEM_NOT_FOUND"
        case .notTextFile: "NOT_TEXT_FILE"
        case .applicationNotFound: "APPLICATION_NOT_FOUND"
        case .applicationActivationFailed: "APPLICATION_ACTIVATION_FAILED"
        case .contentChanged: "CONTENT_CHANGED"
        case .executableNotFound: "EXECUTABLE_NOT_FOUND"
        case .processLaunchFailed: "PROCESS_LAUNCH_FAILED"
        case .invalidArgument: "INVALID_ARGUMENT"
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .invalidPath(path): "パスが不正です: \(path)"
        case let .itemAlreadyExists(path): "既に項目が存在します: \(path)"
        case let .itemNotFound(path): "項目が見つかりません: \(path)"
        case let .notTextFile(path): "UTF-8テキストとして読み取れません: \(path)"
        case let .applicationNotFound(identifier): "アプリが見つかりません: \(identifier)"
        case let .applicationActivationFailed(identifier): "アプリを前面化できません: \(identifier)"
        case let .contentChanged(path): "指定したSHA-256と内容が一致しません: \(path)"
        case let .executableNotFound(path): "実行ファイルが見つかりません: \(path)"
        case let .processLaunchFailed(message): "プログラムを起動できません: \(message)"
        case let .invalidArgument(message): "引数が不正です: \(message)"
        }
    }
}
