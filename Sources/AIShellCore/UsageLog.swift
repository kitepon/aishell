import Darwin
import Foundation

/// 使用日時、操作、対象、結果だけを追記する。編集内容や環境変数は保存しない。
public actor UsageLog {
    public let fileURL: URL

    public init(directory: URL? = nil) {
        let base = directory
            ?? ProcessInfo.processInfo.environment["AISHELL_STATE_DIRECTORY"].flatMap {
                $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
            }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/AIShell", isDirectory: true)
        fileURL = base.appendingPathComponent("activity.jsonl")
    }

    public func append(_ record: OperationRecord) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(record)
        data.append(0x0A)
        let descriptor = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        // 複数のAIが別processで同じログへ書いても、JSONの行を混ぜない。
        guard flock(descriptor, LOCK_EX) == 0 else { throw posixError() }
        defer { flock(descriptor, LOCK_UN) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
