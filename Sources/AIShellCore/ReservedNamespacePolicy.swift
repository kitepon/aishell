import CryptoKit
import Foundation

public enum ReservedNamespacePolicy {
    public static let name = ".aishell-transactions"
    public static let version = "v1"
    public static let exclusionContract =
        "workspace-exclusions-v2:.git,.build,node_modules,\(name)@\(version)"
    public static let exclusionDigest = SHA256.hash(data: Data(exclusionContract.utf8))
        .map { String(format: "%02x", $0) }.joined()

    public static func contains(relativePath: String) -> Bool {
        relativePath.split(separator: "/", omittingEmptySubsequences: true)
            .contains(Substring(name))
    }

    public static func contains(url: URL, under roots: [URL]) -> Bool {
        let target = url.standardizedFileURL.pathComponents
        return roots.contains { root in
            let base = root.standardizedFileURL.pathComponents
            guard target.count >= base.count,
                  Array(target.prefix(base.count)) == base else { return false }
            return target.dropFirst(base.count).contains(name)
        }
    }

    public static func requirePublicPath(_ url: URL, under roots: [URL]) throws {
        guard !contains(url: url, under: roots) else {
            throw AIShellError.reservedPath(url.path)
        }
    }

    public static func shouldExclude(relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        return components.contains { [".git", ".build", "node_modules", name].contains(String($0)) }
    }

    public static let rgGlobArguments = ["--glob", "!\(name)/**"]
    public static let gitExclusionPathspec = ":(exclude)\(name)/**"
}
