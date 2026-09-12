import CryptoKit
import Darwin
import Foundation

/// 内部データの鍵は同じOSユーザーだけが読める通常ファイルへ置く。本人認証は行わない。
enum LocalChangeSetKey {
    static let filename = "state-key"

    static func loadOrCreate(in directory: URL, encryptedStateExists: Bool) throws -> Data {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(filename)
        if encryptedStateExists && !FileManager.default.fileExists(atPath: url.path) {
            throw ApplyChangeSetError(.changeSetSecretStoreUnavailable, "保存済みの編集状態に対応するローカル鍵がありません。既存データは変更していません。")
        }
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        // 同時に起動したMCPが別々の鍵を保存しないよう、ファイル境界で直列化する。
        guard flock(fd, LOCK_EX) == 0 else { throw failure() }
        defer { flock(fd, LOCK_UN) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), fchmod(fd, 0o600) == 0 else { throw failure() }
        if info.st_size > 0 {
            guard info.st_size == 32 else { throw failure() }
            var bytes = Data(count: 32)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, 32) }
            guard count == 32 else { throw failure() }
            return bytes
        }
        guard !encryptedStateExists else { throw failure() }
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        guard count == 32, fsync(fd) == 0 else { throw failure() }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw failure() }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw failure() }
        return bytes
    }

    private static func failure() -> ApplyChangeSetError {
        ApplyChangeSetError(.changeSetSecretStoreUnavailable, "編集状態のローカル鍵を読み書きできません。")
    }
}
