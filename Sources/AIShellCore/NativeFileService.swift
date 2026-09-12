import CryptoKit
import Foundation

public actor NativeFileService {
    public static let maximumTextBytes = 1_048_576

    private let store: RuntimeStore

    public init(store: RuntimeStore = RuntimeStore()) {
        self.store = store
    }

    public func list(path: String? = nil) async throws -> [FileEntry] {
        try await audited(operation: "files.list", target: path ?? ".") {
            let resolver = try await activeResolver()
            let directory = try resolver.resolveExisting(path)
            try ReservedNamespacePolicy.requirePublicPath(directory, under: resolver.namespaceRoots)
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )

            return try urls
                .filter { !ReservedNamespacePolicy.contains(url: $0, under: resolver.namespaceRoots) }
                .map { try fileEntry(for: $0, keys: keys) }
                .sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
        }
    }

    public func search(
        query: String,
        path: String? = nil,
        limit: Int = 100
    ) async throws -> [FileEntry] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIShellError.invalidArgument("queryは空にできません。")
        }

        return try await audited(operation: "files.search", target: path ?? ".") {
            let resolver = try await activeResolver()
            let directory = try resolver.resolveExisting(path)
            try ReservedNamespacePolicy.requirePublicPath(directory, under: resolver.namespaceRoots)
            let cappedLimit = min(max(limit, 1), 500)
            return try searchSynchronously(query: query, directory: directory, limit: cappedLimit)
        }
    }

    public func readText(path: String) async throws -> String {
        try await audited(operation: "files.readText", target: path) {
            let resolver = try await activeResolver()
            let url = try resolver.resolveExisting(path)
            try ReservedNamespacePolicy.requirePublicPath(url, under: resolver.namespaceRoots)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            guard values.isDirectory != true else {
                throw AIShellError.invalidPath(path)
            }
            if let fileSize = values.fileSize, fileSize > Self.maximumTextBytes {
                throw AIShellError.textFileTooLarge(Self.maximumTextBytes)
            }

            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard let text = String(data: data, encoding: .utf8) else {
                throw AIShellError.notTextFile(path)
            }
            return text
        }
    }

    public func stat(path: String, includeHash: Bool = true) async throws -> FileStat {
        try await audited(operation: "files.stat", target: path) {
            let resolver = try await activeResolver()
            let url = try resolver.resolveExisting(path)
            try ReservedNamespacePolicy.requirePublicPath(url, under: resolver.namespaceRoots)
            return try fileStat(for: url, includeHash: includeHash)
        }
    }

    public func tree(
        path: String? = nil,
        maxDepth: Int = 4,
        limit: Int = 500
    ) async throws -> [FileTreeEntry] {
        try await audited(operation: "files.tree", target: path ?? ".") {
            let resolver = try await activeResolver()
            let directory = try resolver.resolveExisting(path)
            try ReservedNamespacePolicy.requirePublicPath(directory, under: resolver.namespaceRoots)
            let cappedDepth = min(max(maxDepth, 1), 20)
            let cappedLimit = min(max(limit, 1), 2_000)
            return try treeSynchronously(
                directory: directory,
                maxDepth: cappedDepth,
                limit: cappedLimit
            )
        }
    }

    public func writeText(
        path: String,
        content: String,
        expectedSHA256: String? = nil
    ) async throws -> FileStat {
        try await audited(operation: "files.writeText", target: path) {
            let resolver = try await activeResolver()
            let url = try resolver.resolveDestination(path)
            try ReservedNamespacePolicy.requirePublicPath(url, under: resolver.namespaceRoots)
            let exists = FileManager.default.fileExists(atPath: url.path)

            if exists {
                guard let expectedSHA256, !expectedSHA256.isEmpty else {
                    throw AIShellError.invalidArgument(
                        "既存ファイルの更新にはexpected_sha256が必要です。files_statで取得してください。"
                    )
                }
                let currentHash = try sha256(for: url)
                guard currentHash.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
                    throw AIShellError.contentChanged(url.path)
                }
                try coordinatedWrite(Data(content.utf8), to: url)
            } else {
                guard expectedSHA256 == nil else {
                    throw AIShellError.itemNotFound(url.path)
                }
                try Data(content.utf8).write(to: url, options: .withoutOverwriting)
            }

            return try fileStat(for: url, includeHash: true)
        }
    }

    public func replaceText(
        path: String,
        oldText: String,
        newText: String,
        replaceAll: Bool = false
    ) async throws -> FileStat {
        guard !oldText.isEmpty else {
            throw AIShellError.invalidArgument("old_textは空にできません。")
        }

        return try await audited(operation: "files.replaceText", target: path) {
            let resolver = try await activeResolver()
            let url = try resolver.resolveExisting(path)
            try ReservedNamespacePolicy.requirePublicPath(url, under: resolver.namespaceRoots)
            let original = try readTextSynchronously(url: url)
            let occurrenceCount = original.components(separatedBy: oldText).count - 1

            guard occurrenceCount > 0 else {
                throw AIShellError.invalidArgument("old_textが対象ファイルに見つかりません。")
            }
            guard replaceAll || occurrenceCount == 1 else {
                throw AIShellError.invalidArgument(
                    "old_textが\(occurrenceCount)箇所にあります。replace_allを指定するか、より長い文字列で特定してください。"
                )
            }

            let updated: String
            if replaceAll {
                updated = original.replacingOccurrences(of: oldText, with: newText)
            } else if let range = original.range(of: oldText) {
                var copy = original
                copy.replaceSubrange(range, with: newText)
                updated = copy
            } else {
                throw AIShellError.invalidArgument("old_textが対象ファイルに見つかりません。")
            }

            try coordinatedWrite(Data(updated.utf8), to: url)
            return try fileStat(for: url, includeHash: true)
        }
    }

    public func createDirectory(path: String) async throws -> FileEntry {
        try await audited(operation: "files.createDirectory", target: path) {
            let resolver = try await activeResolver()
            let url = try resolver.resolveDestination(path)
            try ReservedNamespacePolicy.requirePublicPath(url, under: resolver.namespaceRoots)
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw AIShellError.itemAlreadyExists(url.path)
            }

            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return try fileEntry(for: url)
        }
    }

    public func createTextFile(path: String, content: String) async throws -> FileEntry {
        try await audited(operation: "files.createText", target: path) {
            let resolver = try await activeResolver()
            let url = try resolver.resolveDestination(path)
            try ReservedNamespacePolicy.requirePublicPath(url, under: resolver.namespaceRoots)
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw AIShellError.itemAlreadyExists(url.path)
            }

            let data = Data(content.utf8)
            try data.write(to: url, options: .withoutOverwriting)
            return try fileEntry(for: url)
        }
    }

    public func copy(source: String, destination: String) async throws -> FileEntry {
        try await audited(operation: "files.copy", target: "\(source) → \(destination)") {
            let resolver = try await activeResolver()
            let sourceURL = try resolver.resolveExisting(source)
            let destinationURL = try resolver.resolveDestination(destination)
            try ReservedNamespacePolicy.requirePublicPath(sourceURL, under: resolver.namespaceRoots)
            try ReservedNamespacePolicy.requirePublicPath(destinationURL, under: resolver.namespaceRoots)
            guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                throw AIShellError.itemAlreadyExists(destinationURL.path)
            }

            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return try fileEntry(for: destinationURL)
        }
    }

    public func move(source: String, destination: String) async throws -> FileEntry {
        try await audited(operation: "files.move", target: "\(source) → \(destination)") {
            let resolver = try await activeResolver()
            let sourceURL = try resolver.resolveExisting(source)
            let destinationURL = try resolver.resolveDestination(destination)
            try ReservedNamespacePolicy.requirePublicPath(sourceURL, under: resolver.namespaceRoots)
            try ReservedNamespacePolicy.requirePublicPath(destinationURL, under: resolver.namespaceRoots)
            guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                throw AIShellError.itemAlreadyExists(destinationURL.path)
            }

            try coordinatedMove(from: sourceURL, to: destinationURL)
            return try fileEntry(for: destinationURL)
        }
    }

    public func rename(path: String, newName: String) async throws -> FileEntry {
        guard !newName.isEmpty,
              newName != ".",
              newName != "..",
              !newName.contains("/") else {
            throw AIShellError.invalidArgument("newNameにはファイル名だけを指定してください。")
        }

        return try await audited(operation: "files.rename", target: "\(path) → \(newName)") {
            let resolver = try await activeResolver()
            let sourceURL = try resolver.resolveExisting(path)
            let destinationURL = try resolver.resolveDestination(
                sourceURL.deletingLastPathComponent().appendingPathComponent(newName).path
            )
            try ReservedNamespacePolicy.requirePublicPath(sourceURL, under: resolver.namespaceRoots)
            try ReservedNamespacePolicy.requirePublicPath(destinationURL, under: resolver.namespaceRoots)
            guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                throw AIShellError.itemAlreadyExists(destinationURL.path)
            }

            try coordinatedMove(from: sourceURL, to: destinationURL)
            return try fileEntry(for: destinationURL)
        }
    }

    public func trash(path: String) async throws -> String {
        try await audited(operation: "files.trash", target: path) {
            let resolver = try await activeResolver()
            let url = try resolver.resolveExisting(path)
            try ReservedNamespacePolicy.requirePublicPath(url, under: resolver.namespaceRoots)

            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            return (resultingURL as URL?)?.path ?? url.path
        }
    }

    private func activeResolver() async throws -> PathResolver {
        let configuration = try await store.loadConfiguration()
        guard !configuration.isPaused else { throw AIShellError.paused }
        return await store.pathResolver()
    }

    private func fileEntry(
        for url: URL,
        keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
    ) throws -> FileEntry {
        let values = try url.resourceValues(forKeys: keys)
        let isDirectory = values.isDirectory ?? false
        return FileEntry(
            name: url.lastPathComponent,
            path: url.path,
            isDirectory: isDirectory,
            size: isDirectory ? nil : values.fileSize.map(Int64.init),
            modifiedAt: values.contentModificationDate
        )
    }

    private func fileStat(for url: URL, includeHash: Bool) throws -> FileStat {
        let entry = try fileEntry(for: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        return FileStat(
            entry: entry,
            sha256: includeHash && !entry.isDirectory ? try sha256(for: url) : nil,
            posixPermissions: permissions
        )
    }

    private func readTextSynchronously(url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        guard values.isDirectory != true else {
            throw AIShellError.invalidPath(url.path)
        }
        if let fileSize = values.fileSize, fileSize > Self.maximumTextBytes {
            throw AIShellError.textFileTooLarge(Self.maximumTextBytes)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AIShellError.notTextFile(url.path)
        }
        return text
    }

    private func sha256(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()

        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func searchSynchronously(query: String, directory: URL, limit: Int) throws -> [FileEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var matches: [FileEntry] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent.localizedCaseInsensitiveContains(query) {
                matches.append(try fileEntry(for: url, keys: keys))
                if matches.count >= limit { break }
            }
        }
        return matches
    }

    private func treeSynchronously(
        directory: URL,
        maxDepth: Int,
        limit: Int
    ) throws -> [FileTreeEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var entries: [FileTreeEntry] = []
        for case let url as URL in enumerator {
            let depth = enumerator.level
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            entries.append(FileTreeEntry(depth: depth, entry: try fileEntry(for: url, keys: keys)))
            if entries.count >= limit { break }
        }
        return entries
    }

    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: Error?

        coordinator.coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                writeError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    private func coordinatedMove(from sourceURL: URL, to destinationURL: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var moveError: Error?

        coordinator.coordinate(
            writingItemAt: sourceURL,
            options: .forMoving,
            writingItemAt: destinationURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedSource, coordinatedDestination in
            do {
                try FileManager.default.moveItem(at: coordinatedSource, to: coordinatedDestination)
            } catch {
                moveError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let moveError { throw moveError }
    }

    private func audited<T: Sendable>(
        operation: String,
        target: String,
        body: () async throws -> T
    ) async throws -> T {
        do {
            let result = try await body()
            try? await store.appendActivity(OperationRecord(
                operation: operation,
                target: target,
                success: true,
                message: "完了"
            ))
            return result
        } catch {
            try? await store.appendActivity(OperationRecord(
                operation: operation,
                target: target,
                success: false,
                message: error.localizedDescription
            ))
            throw error
        }
    }
}
