import CryptoKit
import Foundation

/// SwiftPMが生成したbuild descriptionを読み、module/source/testの宣言edgeを返す。
public struct BuildManifestChangeImpactProvider: ChangeImpactProvider {
    public let descriptor = ChangeImpactProviderDescriptor(
        providerID: "swiftpm-build-manifest", kind: .buildGraph, version: "1"
    )

    public init() {}

    public func analyze(_ input: ChangeImpactProviderInput) async throws -> ChangeImpactProviderOutput {
        let root = input.root.standardizedFileURL.resolvingSymlinksInPath()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let manifest = discoverManifest(root: root) else {
            return .init(report: .init(
                descriptor: descriptor, status: .unavailable,
                inputDigest: digest(try encoder.encode(input.changedPaths)),
                observedAtCursor: input.workspaceCursor,
                reasonCode: "build_manifest_not_found",
                nextAction: "SwiftPM buildを実行して.build内のdescription.jsonを生成してください"
            ))
        }
        let data = try Data(contentsOf: manifest.url, options: .mappedIfSafe)
        guard data.count <= 32 * 1_024 * 1_024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commands = object["swiftCommands"] as? [String: Any] else {
            return .init(report: .init(
                descriptor: descriptor, status: .unavailable,
                inputDigest: digest(data), observedAtCursor: input.workspaceCursor,
                reasonCode: "build_manifest_invalid",
                nextAction: "SwiftPM build manifestを再生成してください"
            ))
        }

        var modules: [String: Module] = [:]
        for value in commands.values {
            guard let command = value as? [String: Any],
                  let name = command["moduleName"] as? String,
                  let inputs = command["inputs"] as? [[String: Any]] else { continue }
            var sources: [String] = [], dependencies: [String] = []
            for inputValue in inputs.compactMap({ $0["name"] as? String }) {
                if let relative = relativeWorkspacePath(inputValue, root: root),
                   relative.hasSuffix(".swift"), !relative.hasPrefix(".build/") {
                    sources.append(relative)
                } else if inputValue.contains("/Modules/"), inputValue.hasSuffix(".swiftmodule") {
                    dependencies.append(URL(fileURLWithPath: inputValue).deletingPathExtension().lastPathComponent)
                }
            }
            modules[name] = Module(name: name, sources: unique(sources), dependencies: unique(dependencies))
        }

        var reverse: [String: Set<String>] = [:]
        for module in modules.values {
            for dependency in module.dependencies where modules[dependency] != nil {
                reverse[dependency, default: []].insert(module.name)
            }
        }
        var evidence: [ChangeImpactEvidenceSeed] = []
        var bindings: [ChangeImpactFreshnessBinding] = [
            .init(role: .analysis, path: manifest.path, contentSHA256: digest(data))
        ]
        var gaps: [ChangeImpactCoverageGap] = []

        for changed in input.changedPaths.sorted(by: { $0.path < $1.path }) {
            let owners = modules.values.filter { $0.sources.contains(changed.path) }.map(\.name).sorted()
            if owners.isEmpty {
                gaps.append(.init(category: .buildTargets, reasonCode: "build_manifest_source_unmapped",
                    providerID: descriptor.providerID, subject: .path(changed.path),
                    nextAction: "buildを再実行してmanifestを現在のsource集合へ更新してください"))
                continue
            }
            for owner in owners {
                var queue = [owner], seen: Set<String> = [owner]
                while !queue.isEmpty {
                    let moduleName = queue.removeFirst()
                    guard let module = modules[moduleName] else { continue }
                    let target = ChangeImpactSubject.target(
                        ecosystemID: "swift-package-manager", profileIdentity: digest(data),
                        manifestPath: manifest.path, declaredID: moduleName
                    )
                    evidence.append(.init(
                        inputIdentity: pathIdentity(changed),
                        candidate: .init(category: .buildTargets, subject: target),
                        relation: moduleName == owner
                            ? (changed.path.hasPrefix("Tests/") ? .containsTest : .containsSource)
                            : .declaredDependency,
                        locator: .init(path: manifest.path, contentSHA256: digest(data),
                            edgeID: "swiftpm:\(owner)->\(moduleName)"),
                        strength: .declaredEdge,
                        summary: moduleName == owner
                            ? "build manifestは\(changed.path)を\(moduleName)へ所属付ける"
                            : "build manifestのmodule dependency \(moduleName) -> \(owner)"
                    ))
                    if moduleName != owner {
                        for source in module.sources {
                            guard let sha = fileDigest(source, root: root) else { continue }
                            let isTest = source.hasPrefix("Tests/") || source.contains("/Tests/")
                            evidence.append(.init(
                                inputIdentity: pathIdentity(changed),
                                candidate: .init(category: isTest ? .relatedTests : .dependencies,
                                    subject: isTest ? .test(path: source) : .path(source)),
                                relation: .declaredDependency,
                                locator: .init(path: manifest.path, contentSHA256: digest(data),
                                    edgeID: "swiftpm-source:\(moduleName):\(source)"),
                                strength: .declaredEdge,
                                summary: "build manifestの影響module \(moduleName)に\(source)が所属する"
                            ))
                            bindings.append(.init(role: .analysis, path: source, contentSHA256: sha))
                        }
                    }
                    for dependent in (reverse[moduleName] ?? []).sorted() where seen.insert(dependent).inserted {
                        queue.append(dependent)
                    }
                }
            }
        }
        bindings = uniqueBindings(bindings)
        let material = try encoder.encode(input.changedPaths) + encoder.encode(input.changedSymbols)
            + encoder.encode(bindings)
        return .init(report: .init(
            descriptor: descriptor, status: .fresh, inputDigest: digest(material),
            observedAtCursor: input.workspaceCursor
        ), evidence: evidence, freshnessBindings: bindings, coverageGaps: gaps)
    }

    private struct Manifest { let url: URL; let path: String }
    private struct Module { let name: String; let sources: [String]; let dependencies: [String] }

    private func discoverManifest(root: URL) -> Manifest? {
        let build = root.appendingPathComponent(".build", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: build,
            includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return nil }
        var values: [Manifest] = []
        while values.count < 64, let url = enumerator.nextObject() as? URL {
            guard url.lastPathComponent == "description.json",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            values.append(.init(url: url, path: relative(url, root: root)))
        }
        return values.sorted { $0.path < $1.path }.first
    }

    private func relativeWorkspacePath(_ path: String, root: URL) -> String? {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.path + "/"
        guard url.path.hasPrefix(prefix) else { return nil }
        return String(url.path.dropFirst(prefix.count))
    }
    private func relative(_ url: URL, root: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
    }
    private func fileDigest(_ path: String, root: URL) -> String? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(path), options: .mappedIfSafe) else { return nil }
        return digest(data)
    }
    private func unique(_ values: [String]) -> [String] { Array(Set(values)).sorted() }
    private func uniqueBindings(_ values: [ChangeImpactFreshnessBinding]) -> [ChangeImpactFreshnessBinding] {
        var result: [ChangeImpactFreshnessBinding] = []
        for value in values where !result.contains(value) { result.append(value) }
        return result.sorted { $0.path < $1.path }
    }
    private func pathIdentity(_ value: ChangeImpactChangedPath) -> String {
        tuple(["input_path", value.path, value.expectedAbsent ? "1" : "0", value.contentSHA256 ?? ""])
    }
    private func tuple(_ values: [String]) -> String { values.map { "\(Data($0.utf8).count):\($0)" }.joined() }
    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// SourceKit-LSPのsemantic referenceをchange-impact evidenceへ投影するprovider。
public struct SourceKitChangeImpactProvider: ChangeImpactProvider {
    public let descriptor = ChangeImpactProviderDescriptor(providerID: "sourcekit", kind: .sourceKit, version: "1")
    private let service: SourceKitLSPService

    public init(service: SourceKitLSPService) { self.service = service }

    public func analyze(_ input: ChangeImpactProviderInput) async throws -> ChangeImpactProviderOutput {
        let symbols = input.changedSymbols.filter { $0.path.hasSuffix(".swift") }
        guard !symbols.isEmpty else {
            return .init(report: .init(descriptor: descriptor, status: .unsupported,
                inputDigest: digest(Data()), observedAtCursor: input.workspaceCursor,
                reasonCode: "sourcekit_symbol_input_required",
                nextAction: "Swift changed_symbolをpath、SHA、byte range付きで指定してください"))
        }
        var evidence: [ChangeImpactEvidenceSeed] = []
        var bindings: [ChangeImpactFreshnessBinding] = []
        for symbol in symbols {
            let url = input.root.appendingPathComponent(symbol.path)
            guard let data = try? Data(contentsOf: url), digest(data) == symbol.contentSHA256,
                  let position = position(byteOffset: symbol.startOffset, data: data) else {
                return unavailable(input, status: .stale, code: "sourcekit_input_stale",
                    action: "workspace snapshotとchanged symbol SHAを更新してください")
            }
            let result = try await service.query(.init(root: input.root, workspaceCursor: input.workspaceCursor,
                path: symbol.path, contentSHA256: symbol.contentSHA256, operation: .references,
                symbol: symbol.name, line: position.line, character: position.character))
            guard result.status == .fresh else {
                let status: ChangeImpactProviderStatus = result.status == .stale ? .stale : .unavailable
                return unavailable(input, status: status, code: "sourcekit_\(result.status.rawValue)",
                    action: result.reason ?? "SourceKit-LSPを再試行してください")
            }
            bindings.append(.init(role: .analysis, path: symbol.path, contentSHA256: symbol.contentSHA256))
            for location in result.locations where location.path != symbol.path {
                let isTest = location.path.hasPrefix("Tests/") || location.path.contains("/Tests/")
                evidence.append(.init(
                    inputIdentity: symbolIdentity(symbol),
                    candidate: .init(category: isTest ? .relatedTests : .dependencies,
                        subject: isTest ? .test(path: location.path) : .path(location.path)),
                    relation: .semanticReference,
                    locator: .init(path: location.path, contentSHA256: location.contentSHA256,
                        edgeID: "sourcekit:\(symbol.name):\(location.line):\(location.character)"),
                    strength: .semanticMatch,
                    summary: "SourceKit-LSP semantic reference to \(symbol.name)"
                ))
                bindings.append(.init(role: .analysis, path: location.path,
                    contentSHA256: location.contentSHA256))
            }
        }
        bindings = Array(Set(bindings.map { "\($0.path)\u{0}\($0.contentSHA256 ?? "")" }))
            .sorted().compactMap { key in
                let parts = key.split(separator: "\u{0}", omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                return .init(role: .analysis, path: String(parts[0]), contentSHA256: String(parts[1]))
            }
        let encoded = try JSONEncoder().encode(bindings)
        return .init(report: .init(descriptor: descriptor, status: .fresh,
            inputDigest: digest(encoded), observedAtCursor: input.workspaceCursor),
            evidence: evidence, freshnessBindings: bindings)
    }

    private func unavailable(_ input: ChangeImpactProviderInput, status: ChangeImpactProviderStatus,
                             code: String, action: String) -> ChangeImpactProviderOutput {
        .init(report: .init(descriptor: descriptor, status: status, inputDigest: digest(Data()),
            observedAtCursor: input.workspaceCursor, reasonCode: code, nextAction: action))
    }
    private func position(byteOffset: Int, data: Data) -> (line: Int, character: Int)? {
        guard byteOffset >= 0, byteOffset <= data.count,
              let prefix = String(data: data.prefix(byteOffset), encoding: .utf8) else { return nil }
        let lines = prefix.split(separator: "\n", omittingEmptySubsequences: false)
        return (max(0, lines.count - 1), lines.last.map { $0.utf16.count } ?? 0)
    }
    private func symbolIdentity(_ value: ChangeImpactChangedSymbol) -> String {
        tuple(["input_symbol", value.path, String(value.startOffset), String(value.endOffset),
            value.name, value.stableID ?? "", value.contentSHA256])
    }
    private func tuple(_ values: [String]) -> String { values.map { "\(Data($0.utf8).count):\($0)" }.joined() }
    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
