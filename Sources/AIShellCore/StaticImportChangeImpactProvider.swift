import CryptoKit
import Foundation

/// 現在のJavaScript/TypeScript source bytesからrelative import graphを構築するprovider。
/// package resolverやindexへfallbackせず、実在するworkspace内fileだけをedgeにする。
public struct StaticImportChangeImpactProvider: ChangeImpactProvider {
    public let descriptor = ChangeImpactProviderDescriptor(
        providerID: "static-import",
        kind: .lexicalSearch,
        version: "1"
    )

    private static let maximumFileBytes = 4 * 1_024 * 1_024
    private static let maximumCandidates = 512
    private static let extensions = ["js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts"]

    public init() {}

    public func analyze(_ input: ChangeImpactProviderInput) async throws -> ChangeImpactProviderOutput {
        let root = input.root.standardizedFileURL.resolvingSymlinksInPath()
        let discovered = try discoverFiles(in: root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let hasJavaScriptTypeScriptInput = input.changedPaths.contains { isJavaScriptTypeScript($0.path) }
            || input.changedSymbols.contains { isJavaScriptTypeScript($0.path) }
        if !hasJavaScriptTypeScriptInput {
            let digestMaterial = sha256(try encoder.encode(input.changedPaths))
                + sha256(try encoder.encode(input.changedSymbols))
                + sha256(try encoder.encode([ChangeImpactFreshnessBinding]()))
            return .init(report: .init(
                descriptor: descriptor,
                status: .unsupported,
                inputDigest: sha256(Data(digestMaterial.utf8)),
                observedAtCursor: input.workspaceCursor,
                reasonCode: "static_import_ecosystem_unsupported",
                nextAction: "JavaScript/TypeScript workspaceで使用するか、対象言語のdependency providerを選択してください"
            ))
        }
        let paths = Set(discovered.files.map(\.path)).union(
            input.changedPaths.lazy.map(\.path).filter(isJavaScriptTypeScript)
        )
        var bindings: [ChangeImpactFreshnessBinding] = []
        var reverseEdges: [String: [ImportEdge]] = [:]
        var gaps = discovered.gaps
        let unsupportedInputPaths = Set(
            input.changedPaths.map(\.path) + input.changedSymbols.map(\.path)
        ).filter { !isJavaScriptTypeScript($0) }
        for path in unsupportedInputPaths.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            gaps.append(.init(
                category: .dependencies,
                reasonCode: "static_import_input_unsupported",
                providerID: descriptor.providerID,
                subject: .path(path),
                nextAction: "この入力pathに対応するdependency providerで補完してください"
            ))
        }
        if discovered.files.isEmpty,
           let missing = input.changedPaths
            .filter({ $0.expectedAbsent && isJavaScriptTypeScript($0.path) })
            .sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) })
            .first {
            gaps.append(.init(
                category: .dependencies,
                reasonCode: "static_import_analysis_input_missing",
                providerID: descriptor.providerID,
                subject: .path(missing.path),
                nextAction: "削除前のdependency graphを提供するproviderで補完してください"
            ))
        }

        for file in discovered.files {
            guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) else {
                gaps.append(fileGap(path: file.path, reasonCode: "static_import_file_unreadable"))
                continue
            }
            guard data.count <= Self.maximumFileBytes, String(data: data, encoding: .utf8) != nil else {
                gaps.append(fileGap(path: file.path, reasonCode: "static_import_unparseable_file"))
                continue
            }
            let digest = sha256(data)
            bindings.append(.init(role: .analysis, path: file.path, contentSHA256: digest))
            let parsed = parse(data, supportsCommonJS: isCommonJS(file.path))
            if parsed.hasNonLiteralDynamicImport {
                gaps.append(.init(
                    category: .dependencies,
                    reasonCode: "dynamic_import_non_literal",
                    providerID: descriptor.providerID,
                    subject: .path(file.path),
                    nextAction: "動的specifierをliteralへ固定するか、runtime/build graph providerで補完してください"
                ))
            }
            if parsed.hasNonLiteralCommonJSRequire {
                gaps.append(.init(
                    category: .dependencies,
                    reasonCode: "commonjs_require_non_literal",
                    providerID: descriptor.providerID,
                    subject: .path(file.path),
                    nextAction: "CommonJS require specifierをliteralへ固定するか、runtime providerで補完してください"
                ))
            }
            if parsed.hasUnresolvedCommonJSModuleKind {
                gaps.append(.init(
                    category: .dependencies,
                    reasonCode: "commonjs_module_kind_unresolved",
                    providerID: descriptor.providerID,
                    subject: .path(file.path),
                    nextAction: "package module kindを解決できるproviderでCommonJS dependencyを補完してください"
                ))
            }
            for specifier in parsed.specifiers where isRelative(specifier.value) {
                guard let target = resolve(
                    specifier.value,
                    importerPath: file.path,
                    root: root,
                    knownPaths: paths
                ) else { continue }
                reverseEdges[target, default: []].append(.init(
                    importer: file.path,
                    target: target,
                    importerSHA256: digest,
                    startOffset: specifier.startOffset,
                    endOffset: specifier.endOffset
                ))
            }
        }

        for key in reverseEdges.keys {
            reverseEdges[key]?.sort { edgeSortKey($0) < edgeSortKey($1) }
        }

        var evidence: [ChangeImpactEvidenceSeed] = []
        var candidateLimitReached = false
        changedPaths: for changed in input.changedPaths.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
            var queue = [changed.path]
            var offset = 0
            var visited: Set<String> = [changed.path]
            while offset < queue.count {
                let target = queue[offset]
                offset += 1
                for edge in reverseEdges[target] ?? [] where visited.insert(edge.importer).inserted {
                    guard evidence.count < Self.maximumCandidates else {
                        candidateLimitReached = true
                        break changedPaths
                    }
                    queue.append(edge.importer)
                    let candidate: ChangeImpactCandidateSeed
                    if isTestPath(edge.importer) {
                        candidate = .init(category: .relatedTests, subject: .test(path: edge.importer))
                    } else {
                        candidate = .init(category: .dependencies, subject: .path(edge.importer))
                    }
                    evidence.append(.init(
                        inputIdentity: pathIdentity(changed),
                        candidate: candidate,
                        relation: .declaredDependency,
                        locator: .init(
                            path: edge.importer,
                            contentSHA256: edge.importerSHA256,
                            startOffset: edge.startOffset,
                            endOffset: edge.endOffset,
                            edgeID: tuple([edge.importer, edge.target])
                        ),
                        strength: .declaredEdge,
                        summary: "relative import \(edge.importer) -> \(edge.target)"
                    ))
                }
            }
        }
        if candidateLimitReached {
            gaps.append(.init(
                category: .dependencies,
                reasonCode: "static_import_candidate_limit_reached",
                providerID: descriptor.providerID,
                nextAction: "変更範囲を分割するか、より限定的なdependency providerで補完してください"
            ))
        }

        bindings.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        evidence.sort { evidenceSortKey($0) < evidenceSortKey($1) }
        gaps = deduplicatedGaps(gaps)
        let digestMaterial = sha256(try encoder.encode(input.changedPaths))
            + sha256(try encoder.encode(input.changedSymbols))
            + sha256(try encoder.encode(bindings))

        return .init(
            report: .init(
                descriptor: descriptor,
                status: .fresh,
                inputDigest: sha256(Data(digestMaterial.utf8)),
                observedAtCursor: input.workspaceCursor
            ),
            evidence: evidence,
            freshnessBindings: bindings,
            coverageGaps: gaps
        )
    }

    private struct SourceFile {
        let url: URL
        let path: String
    }

    private struct Discovery {
        var files: [SourceFile]
        var gaps: [ChangeImpactCoverageGap]
    }

    private struct ImportEdge {
        let importer: String
        let target: String
        let importerSHA256: String
        let startOffset: Int
        let endOffset: Int
    }

    private struct Specifier {
        let value: String
        let startOffset: Int
        let endOffset: Int
    }

    private struct ParseResult {
        var specifiers: [Specifier] = []
        var hasNonLiteralDynamicImport = false
        var hasNonLiteralCommonJSRequire = false
        var hasUnresolvedCommonJSModuleKind = false
    }

    private enum TokenKind {
        case identifier(String)
        case string(String)
        case punctuation(UInt8)
    }

    private struct Token {
        let kind: TokenKind
        let start: Int
        let end: Int
    }

    private func discoverFiles(in root: URL) throws -> Discovery {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else { throw AIShellError.invalidPath(root.path) }
        var result = Discovery(files: [], gaps: [])
        while let url = enumerator.nextObject() as? URL {
            let relative = relativePath(url, root: root)
            if ReservedNamespacePolicy.shouldExclude(relativePath: relative) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ])
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, isJavaScriptTypeScript(relative) else { continue }
            if (values.fileSize ?? 0) > Self.maximumFileBytes {
                result.gaps.append(fileGap(path: relative, reasonCode: "static_import_file_too_large"))
                continue
            }
            result.files.append(.init(url: url, path: relative))
        }
        result.files.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        return result
    }

    private func parse(_ data: Data, supportsCommonJS: Bool) -> ParseResult {
        let tokens = tokenize(Array(data))
        var result = ParseResult()
        var index = 0
        while index < tokens.count {
            if case let .identifier(keyword) = tokens[index].kind,
               keyword == "require",
               punctuation(tokens, at: index - 1) != 0x2E,
               punctuation(tokens, at: index + 1) == 0x28 {
                if !supportsCommonJS {
                    result.hasUnresolvedCommonJSModuleKind = true
                } else if let specifier = token(tokens, at: index + 2), case let .string(path) = specifier.kind {
                    result.specifiers.append(.init(
                        value: path,
                        startOffset: specifier.start,
                        endOffset: specifier.end
                    ))
                } else {
                    result.hasNonLiteralCommonJSRequire = true
                }
                index += 2
                continue
            }
            guard case let .identifier(keyword) = tokens[index].kind,
                  keyword == "import" || keyword == "export",
                  punctuation(tokens, at: index - 1) != 0x2E else {
                index += 1
                continue
            }
            if keyword == "import", let requireIndex = typeScriptImportRequireIndex(tokens, importIndex: index) {
                if !supportsCommonJS {
                    result.hasUnresolvedCommonJSModuleKind = true
                } else if let specifier = token(tokens, at: requireIndex + 2), case let .string(path) = specifier.kind {
                    result.specifiers.append(.init(
                        value: path,
                        startOffset: specifier.start,
                        endOffset: specifier.end
                    ))
                } else {
                    result.hasNonLiteralCommonJSRequire = true
                }
                index = requireIndex + 2
                continue
            }
            if keyword == "import", punctuation(tokens, at: index + 1) == 0x28 {
                if let token = token(tokens, at: index + 2), case let .string(value) = token.kind {
                    result.specifiers.append(.init(value: value, startOffset: token.start, endOffset: token.end))
                } else {
                    result.hasNonLiteralDynamicImport = true
                }
                index += 2
                continue
            }
            if keyword == "import", let token = token(tokens, at: index + 1), case let .string(value) = token.kind {
                result.specifiers.append(.init(value: value, startOffset: token.start, endOffset: token.end))
                index += 2
                continue
            }
            var cursor = index + 1
            var nesting = 0
            while cursor < tokens.count {
                if punctuation(tokens, at: cursor) == 0x3B, nesting == 0 { break }
                if case let .identifier(value) = tokens[cursor].kind, value == "from",
                   let specifier = token(tokens, at: cursor + 1), case let .string(path) = specifier.kind {
                    result.specifiers.append(.init(value: path, startOffset: specifier.start, endOffset: specifier.end))
                    break
                }
                if cursor > index + 1, nesting == 0,
                   case let .identifier(value) = tokens[cursor].kind,
                   value == "import" || value == "export" { break }
                if let value = punctuation(tokens, at: cursor) {
                    if value == 0x7B || value == 0x5B || value == 0x28 { nesting += 1 }
                    if value == 0x7D || value == 0x5D || value == 0x29 { nesting = max(0, nesting - 1) }
                }
                cursor += 1
            }
            index = max(index + 1, cursor)
        }
        return result
    }

    private func tokenize(_ bytes: [UInt8]) -> [Token] {
        var result: [Token] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if isWhitespace(byte) { index += 1; continue }
            if byte == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2F {
                index += 2
                while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D { index += 1 }
                continue
            }
            if byte == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2A {
                index += 2
                while index + 1 < bytes.count, !(bytes[index] == 0x2A && bytes[index + 1] == 0x2F) { index += 1 }
                index = min(bytes.count, index + 2)
                continue
            }
            if byte == 0x2F, canStartRegularExpression(after: result.last) {
                index += 1
                var inCharacterClass = false
                while index < bytes.count {
                    if bytes[index] == 0x5C {
                        index = min(bytes.count, index + 2)
                        continue
                    }
                    if bytes[index] == 0x5B { inCharacterClass = true; index += 1; continue }
                    if bytes[index] == 0x5D, inCharacterClass { inCharacterClass = false; index += 1; continue }
                    if bytes[index] == 0x2F, !inCharacterClass {
                        index += 1
                        while index < bytes.count, isIdentifierContinuation(bytes[index]) { index += 1 }
                        break
                    }
                    if bytes[index] == 0x0A || bytes[index] == 0x0D { break }
                    index += 1
                }
                continue
            }
            if byte == 0x22 || byte == 0x27 {
                let start = index
                let quote = byte
                index += 1
                var value: [UInt8] = []
                while index < bytes.count, bytes[index] != quote {
                    if bytes[index] == 0x5C, index + 1 < bytes.count {
                        index += 1
                        value.append(bytes[index])
                    } else {
                        value.append(bytes[index])
                    }
                    index += 1
                }
                if index < bytes.count { index += 1 }
                result.append(.init(kind: .string(String(decoding: value, as: UTF8.self)), start: start, end: index))
                continue
            }
            if byte == 0x60 {
                index += 1
                while index < bytes.count {
                    if bytes[index] == 0x5C { index = min(bytes.count, index + 2); continue }
                    if bytes[index] == 0x60 { index += 1; break }
                    index += 1
                }
                continue
            }
            if isIdentifierStart(byte) {
                let start = index
                index += 1
                while index < bytes.count, isIdentifierContinuation(bytes[index]) { index += 1 }
                result.append(.init(
                    kind: .identifier(String(decoding: bytes[start..<index], as: UTF8.self)),
                    start: start,
                    end: index
                ))
                continue
            }
            result.append(.init(kind: .punctuation(byte), start: index, end: index + 1))
            index += 1
        }
        return result
    }

    private func resolve(_ specifier: String, importerPath: String, root: URL, knownPaths: Set<String>) -> String? {
        let cleanSpecifier = specifier.split(separator: "?", maxSplits: 1).first.map(String.init) ?? specifier
        let withoutFragment = cleanSpecifier.split(separator: "#", maxSplits: 1).first.map(String.init) ?? cleanSpecifier
        let importerDirectory = (importerPath as NSString).deletingLastPathComponent
        let unresolved = root.appendingPathComponent(importerDirectory, isDirectory: true)
            .appendingPathComponent(withoutFragment)
            .standardizedFileURL
        guard isWithinRoot(unresolved, root: root) else { return nil }
        let base = relativePath(unresolved, root: root)
        var candidates = [base]
        if URL(fileURLWithPath: base).pathExtension.isEmpty {
            candidates += Self.extensions.map { "\(base).\($0)" }
            candidates += Self.extensions.map { "\(base)/index.\($0)" }
        }
        return candidates.first(where: knownPaths.contains)
    }

    private func token(_ tokens: [Token], at index: Int) -> Token? {
        tokens.indices.contains(index) ? tokens[index] : nil
    }

    private func punctuation(_ tokens: [Token], at index: Int) -> UInt8? {
        guard let token = token(tokens, at: index), case let .punctuation(value) = token.kind else { return nil }
        return value
    }

    private func typeScriptImportRequireIndex(_ tokens: [Token], importIndex: Int) -> Int? {
        let searchEnd = min(tokens.count, importIndex + 5)
        guard let assignmentIndex = (importIndex + 1..<searchEnd).first(where: {
            punctuation(tokens, at: $0) == 0x3D
        }) else { return nil }
        let requireIndex = assignmentIndex + 1
        guard let requireToken = token(tokens, at: requireIndex),
              case let .identifier(value) = requireToken.kind,
              value == "require",
              punctuation(tokens, at: requireIndex + 1) == 0x28 else { return nil }
        return requireIndex
    }

    private func isRelative(_ value: String) -> Bool {
        value == "." || value == ".." || value.hasPrefix("./") || value.hasPrefix("../")
    }

    private func isJavaScriptTypeScript(_ path: String) -> Bool {
        Self.extensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private func isCommonJS(_ path: String) -> Bool {
        let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        return pathExtension == "cjs" || pathExtension == "cts"
    }

    private func isTestPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains(".test.")
            || lower.hasPrefix("test/") || lower.contains("/test/")
            || lower.hasPrefix("tests/") || lower.contains("/tests/")
    }

    private func isWithinRoot(_ url: URL, root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path == root.path || url.path.hasPrefix(rootPath)
    }

    private func relativePath(_ url: URL, root: URL) -> String {
        url.standardizedFileURL.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
    }

    private func fileGap(path: String, reasonCode: String) -> ChangeImpactCoverageGap {
        .init(
            category: .dependencies,
            reasonCode: reasonCode,
            providerID: descriptor.providerID,
            subject: .path(path),
            nextAction: "4 MiB以下のUTF-8 sourceへ変換するか、別のdependency providerで補完してください"
        )
    }

    private func deduplicatedGaps(_ gaps: [ChangeImpactCoverageGap]) -> [ChangeImpactCoverageGap] {
        var seen: Set<String> = []
        return gaps.sorted { gapSortKey($0) < gapSortKey($1) }.filter {
            seen.insert(gapSortKey($0)).inserted
        }
    }

    private func pathIdentity(_ value: ChangeImpactChangedPath) -> String {
        tuple(["input_path", value.path, value.expectedAbsent ? "1" : "0", value.contentSHA256 ?? ""])
    }

    private func edgeSortKey(_ edge: ImportEdge) -> String {
        tuple([edge.importer, edge.target, String(edge.startOffset), String(edge.endOffset)])
    }

    private func evidenceSortKey(_ seed: ChangeImpactEvidenceSeed) -> String {
        tuple([seed.inputIdentity, seed.candidate.category.rawValue, seed.candidate.subject.path ?? "", seed.locator.edgeID ?? ""])
    }

    private func gapSortKey(_ gap: ChangeImpactCoverageGap) -> String {
        tuple([gap.category.rawValue, gap.reasonCode, gap.subject?.path ?? ""])
    }

    private func tuple(_ values: [String]) -> String {
        values.map { "\(Data($0.utf8).count):\($0)" }.joined()
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }

    private func isIdentifierStart(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F || byte == 0x24
    }

    private func isIdentifierContinuation(_ byte: UInt8) -> Bool {
        isIdentifierStart(byte) || (byte >= 0x30 && byte <= 0x39) || byte >= 0x80
    }

    private func canStartRegularExpression(after token: Token?) -> Bool {
        guard let token else { return true }
        switch token.kind {
        case let .identifier(value):
            return [
                "await", "case", "delete", "do", "else", "in", "instanceof", "return", "throw",
                "typeof", "void", "yield"
            ].contains(value)
        case .string:
            return false
        case let .punctuation(value):
            return [
                0x21, 0x25, 0x26, 0x28, 0x2A, 0x2B, 0x2C, 0x2D, 0x3A, 0x3B, 0x3C, 0x3D,
                0x3E, 0x3F, 0x5B, 0x5E, 0x7B, 0x7C, 0x7E
            ].contains(value)
        }
    }
}
