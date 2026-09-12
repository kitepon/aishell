import Darwin
import Foundation

public struct PathResolver: Sendable {
    public let rootURL: URL

    public init(baseDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)) {
        rootURL = baseDirectory
    }

    public func resolveExisting(_ path: String?) throws -> URL {
        let url = try resolve(path)
        var status = stat()
        // リンク自身を移動・改名できるよう、リンク先へ置き換えない。
        guard lstat(url.path, &status) == 0 else {
            if errno == ENOENT { throw AIShellError.itemNotFound(url.path) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return url
    }

    public func resolveDestination(_ path: String) throws -> URL {
        try resolve(path)
    }

    private func resolve(_ path: String?) throws -> URL {
        guard let path else { return rootURL }
        guard !path.isEmpty, !path.contains("\0") else { throw AIShellError.invalidPath(path) }
        return URL(fileURLWithPath: path, relativeTo: rootURL).absoluteURL
    }
}
