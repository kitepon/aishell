import Foundation

public struct PathResolver: Sendable {
    public let rootURL: URL
    public var namespaceRoots: [URL] { [URL(fileURLWithPath: "/", isDirectory: true)] }

    public init(baseDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
        rootURL = baseDirectory.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func resolveExisting(_ path: String?) throws -> URL {
        let candidate = rawURL(for: path)
        try ReservedNamespacePolicy.requirePublicPath(candidate, under: namespaceRoots)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw AIShellError.itemNotFound(candidate.path)
        }

        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        try ReservedNamespacePolicy.requirePublicPath(resolved, under: namespaceRoots)
        return resolved
    }

    public func resolveDestination(_ path: String) throws -> URL {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIShellError.invalidPath(path)
        }

        let candidate = rawURL(for: path)
        try ReservedNamespacePolicy.requirePublicPath(candidate, under: namespaceRoots)
        var ancestor = candidate
        var missingComponents: [String] = []

        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else {
                throw AIShellError.invalidPath(path)
            }
            missingComponents.insert(ancestor.lastPathComponent, at: 0)
            ancestor = parent
        }

        var resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
        try ReservedNamespacePolicy.requirePublicPath(resolved, under: namespaceRoots)
        for component in missingComponents {
            resolved.appendPathComponent(component)
        }
        resolved = resolved.standardizedFileURL

        try ReservedNamespacePolicy.requirePublicPath(resolved, under: namespaceRoots)
        return resolved
    }

    private func rawURL(for path: String?) -> URL {
        guard let path, !path.isEmpty else {
            return rootURL
        }

        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }

        return rootURL.appendingPathComponent(path).standardizedFileURL
    }

}
