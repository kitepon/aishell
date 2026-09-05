import CryptoKit
import Darwin
import Foundation

/// 観測対象workspaceから、要求に対応するrootとidentityを解決する。
public struct EffectiveRootProjectCatalog: Sendable {
    public struct Owner: Equatable, Sendable {
        public let root: URL
        public let rootIdentity: String
        public let policyDigest: String
    }

    private let roots: [URL]
    private let policyDigest: String

    public init(rootURLs: [URL]) {
        roots = rootURLs.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        let ordered = Set(roots.map(\.path)).sorted { Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8)) }
        policyDigest = Self.sha256(Data(ordered.joined(separator: "\0").utf8))
    }

    public func resolveOwner(for requestedURL: URL) throws -> Owner {
        let requested = requestedURL.standardizedFileURL.resolvingSymlinksInPath()
        guard let root = roots.filter({ candidate in
            requested.path == candidate.path || requested.path.hasPrefix(candidate.path + "/")
        }).sorted(by: { left, right in
            if left.pathComponents.count != right.pathComponents.count {
                return left.pathComponents.count > right.pathComponents.count
            }
            return Data(left.path.utf8).lexicographicallyPrecedes(Data(right.path.utf8))
        }).first else {
            throw AIShellError.outsideWorkspace(requested.path)
        }
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw AIShellError.invalidPath(root.path)
        }
        return Owner(root: root, rootIdentity: "\(info.st_dev):\(info.st_ino)", policyDigest: policyDigest)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// search、snapshot、waitが同じcursor区間を非破壊に読むためのimmutable retained view。
public struct WorkspaceDeltaObservation: Equatable, Sendable {
    public let effectiveRootIdentity: String
    public let effectiveRootPolicyDigest: String
    public let observedFrom: String
    public let observedThrough: String
    public let observationViewID: String
    public let retentionFloorSequence: UInt64
    public let headSequence: UInt64
    public let changedPaths: Set<String>
    public let indexedFiles: [SearchContextIndexedFile]
}
