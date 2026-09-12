import CryptoKit
import Foundation

public struct NativeFileService: Sendable {
    private let resolver: PathResolver

    public init(workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)) {
        resolver = PathResolver(baseDirectory: workingDirectory)
    }

    public func list(path: String? = nil) throws -> [FileEntry] {
        let directory = try resolver.resolveExisting(path)
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map { try fileEntry(for: $0) }
            .sorted { $0.name < $1.name }
    }

    public func search(query: String, path: String? = nil, limit: Int? = nil) throws -> FileSearchResult {
        guard !query.isEmpty else { throw AIShellError.invalidArgument("queryは空にできません。") }
        let result = try walk(path: path, maxDepth: nil, limit: limit) {
            $0.lastPathComponent.localizedCaseInsensitiveContains(query)
        }
        return FileSearchResult(entries: result.entries.map(\.entry), hasMore: result.hasMore)
    }

    public func tree(path: String? = nil, maxDepth: Int? = nil, limit: Int? = nil) throws -> FileTreeResult {
        try walk(path: path, maxDepth: maxDepth, limit: limit) { _ in true }
    }

    public func readText(path: String) throws -> String {
        let url = try resolver.resolveExisting(path)
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw AIShellError.notTextFile(path) }
        return text
    }

    public func stat(path: String, includeHash: Bool = false) throws -> FileStat {
        let url = try resolver.resolveExisting(path)
        let entry = try fileEntry(for: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return FileStat(entry: entry,
            sha256: includeHash && !entry.isDirectory ? try sha256(for: url) : nil,
            posixPermissions: (attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

    public func writeText(path: String, content: String, expectedSHA256: String? = nil) throws -> FileEntry {
        let url = try resolver.resolveDestination(path)
        if let expectedSHA256 {
            guard try sha256(for: resolver.resolveExisting(path)).caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
                throw AIShellError.contentChanged(path)
            }
        }
        // OSの単一ファイル書込みだけを行い、履歴や復旧用コピーを保存しない。
        try Data(content.utf8).write(to: url)
        return try fileEntry(for: url)
    }

    public func replaceText(path: String, oldText: String, newText: String, replaceAll: Bool = false) throws -> FileEntry {
        guard !oldText.isEmpty else { throw AIShellError.invalidArgument("old_textは空にできません。") }
        let original = try readText(path: path)
        let count = original.components(separatedBy: oldText).count - 1
        guard count > 0 else { throw AIShellError.invalidArgument("old_textが見つかりません。") }
        guard replaceAll || count == 1 else {
            throw AIShellError.invalidArgument("old_textが\(count)箇所あります。すべて置換する場合はreplace_allを指定してください。")
        }
        return try writeText(path: path, content: original.replacingOccurrences(of: oldText, with: newText))
    }

    public func createDirectory(path: String) throws -> FileEntry {
        let url = try resolver.resolveDestination(path)
        try requireAbsent(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try fileEntry(for: url)
    }

    public func createTextFile(path: String, content: String) throws -> FileEntry {
        let url = try resolver.resolveDestination(path)
        try requireAbsent(url)
        try Data(content.utf8).write(to: url, options: .withoutOverwriting)
        return try fileEntry(for: url)
    }

    public func copy(source: String, destination: String) throws -> FileEntry {
        let from = try resolver.resolveExisting(source)
        let to = try resolver.resolveDestination(destination)
        try requireAbsent(to)
        try FileManager.default.copyItem(at: from, to: to)
        return try fileEntry(for: to)
    }

    public func move(source: String, destination: String) throws -> FileEntry {
        let from = try resolver.resolveExisting(source)
        let to = try resolver.resolveDestination(destination)
        try requireAbsent(to)
        try FileManager.default.moveItem(at: from, to: to)
        return try fileEntry(for: to)
    }

    public func rename(path: String, newName: String) throws -> FileEntry {
        guard !newName.isEmpty, newName != ".", newName != "..", !newName.contains("/"), !newName.contains("\0") else {
            throw AIShellError.invalidArgument("new_nameにはファイル名だけを指定してください。")
        }
        let from = try resolver.resolveExisting(path)
        return try move(source: from.path, destination: from.deletingLastPathComponent().appendingPathComponent(newName).path)
    }

    public func trash(path: String) throws -> String {
        let url = try resolver.resolveExisting(path)
        var destination: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        guard let path = destination?.path else { throw AIShellError.invalidPath("Trashへの移動先を取得できません。") }
        return path
    }

    private func requireAbsent(_ url: URL) throws {
        do { _ = try resolver.resolveExisting(url.path) }
        catch AIShellError.itemNotFound { return }
        throw AIShellError.itemAlreadyExists(url.path)
    }

    private func fileEntry(for url: URL) throws -> FileEntry {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let directory = attributes[.type] as? FileAttributeType == .typeDirectory
        return FileEntry(name: url.lastPathComponent, path: url.path, isDirectory: directory,
            size: directory ? nil : (attributes[.size] as? NSNumber)?.int64Value,
            modifiedAt: attributes[.modificationDate] as? Date)
    }

    private func sha256(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 65_536), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func walk(path: String?, maxDepth: Int?, limit: Int?, matches: (URL) -> Bool) throws -> FileTreeResult {
        guard maxDepth.map({ $0 > 0 }) ?? true, limit.map({ $0 > 0 }) ?? true else {
            throw AIShellError.invalidArgument("max_depthとlimitは正の整数です。")
        }
        let directory = try resolver.resolveExisting(path)
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw AIShellError.invalidPath(directory.path)
        }
        var failure: Error?
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
            errorHandler: { _, error in failure = error; return false }) else {
            throw AIShellError.invalidPath(directory.path)
        }
        var entries: [FileTreeEntry] = []
        for case let url as URL in enumerator {
            let depth = enumerator.level
            if let maxDepth, depth >= maxDepth { enumerator.skipDescendants() }
            guard matches(url) else { continue }
            if let limit, entries.count == limit { return FileTreeResult(entries: entries, hasMore: true) }
            entries.append(FileTreeEntry(depth: depth, entry: try fileEntry(for: url)))
        }
        if let failure { throw failure }
        return FileTreeResult(entries: entries, hasMore: false)
    }
}
