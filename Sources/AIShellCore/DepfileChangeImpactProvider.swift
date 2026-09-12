import CryptoKit
import Foundation

/// Make形式のdepfileを現在のworkspace bytesから読み、宣言済みdependency edgeを返すprovider。
public struct DepfileChangeImpactProvider: ChangeImpactProvider {
    public let descriptor = ChangeImpactProviderDescriptor(
        providerID: "depfile",
        kind: .depfile,
        version: "1"
    )

    private static let maximumFileBytes = 4 * 1_024 * 1_024
    private static let sourceExtensions: Set<String> = [
        "c", "cc", "cpp", "cxx", "m", "mm", "s", "asm", "swift", "rs", "go",
        "java", "kt", "kts", "scala", "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts"
    ]

    public init() {}

    public func analyze(_ input: ChangeImpactProviderInput) async throws -> ChangeImpactProviderOutput {
        let root = input.root.standardizedFileURL.resolvingSymlinksInPath()
        let discovery = try discover(in: root)
        var bindings: [ChangeImpactFreshnessBinding] = []
        var gaps = discovery.gaps
        var records: [Record] = []
        let absentDepfiles = input.changedPaths.filter { $0.expectedAbsent && isDepfile($0.path) }

        if !discovery.sawDepfile && absentDepfiles.isEmpty {
            gaps.append(gap(
                reasonCode: "depfile_not_found",
                subject: nil,
                nextAction: "buildからMake形式の.dep fileを生成して再解析してください"
            ))
        }

        for file in discovery.depfiles {
            guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) else {
                gaps.append(fileGap(file.path, "depfile_unreadable"))
                continue
            }
            guard data.count <= Self.maximumFileBytes else {
                gaps.append(fileGap(file.path, "depfile_too_large"))
                continue
            }
            let digest = sha256(data)
            bindings.append(.init(role: .analysis, path: file.path, contentSHA256: digest))
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
                gaps.append(fileGap(file.path, "depfile_not_utf8_text"))
                continue
            }
            switch parse(text, depfilePath: file.path, depfileSHA256: digest, root: root) {
            case let .success(parsed):
                records.append(contentsOf: parsed.records)
                gaps.append(contentsOf: parsed.gaps)
            case .failure:
                gaps.append(fileGap(file.path, "depfile_syntax_invalid"))
            }
        }

        for changed in absentDepfiles {
            gaps.append(gap(
                reasonCode: "changed_depfile_absent",
                subject: .path(changed.path),
                nextAction: "depfileを再生成してからimpactを再解析してください"
            ))
        }
        for changed in input.changedPaths where !changed.expectedAbsent && isDepfile(changed.path) {
            gaps.append(gap(
                reasonCode: "changed_depfile_requires_rebuild",
                subject: .path(changed.path),
                nextAction: "buildを再実行してdepfileを更新した後にimpactを再解析してください"
            ))
        }

        let testFiles = discovery.regularFiles.filter { isTestPath($0.path) }
        var evidence: [ChangeImpactEvidenceSeed] = []
        var confirmed: [String: String] = [:]
        for changed in input.changedPaths.sorted(by: { utf8Less($0.path, $1.path) }) where !isDepfile(changed.path) {
            let matching = records.filter { $0.prerequisites.contains(changed.path) }
            if matching.isEmpty {
                if !records.isEmpty {
                    gaps.append(gap(
                        reasonCode: "depfile_reference_missing",
                        subject: .path(changed.path),
                        nextAction: "変更pathをprerequisiteに含むdepfileを生成して再解析してください"
                    ))
                }
                continue
            }

            for record in matching {
                for dependency in record.prerequisites where dependency != changed.path && isSourcePath(dependency) {
                    guard let dependencySHA = confirmCandidate(dependency, root: root, cache: &confirmed) else {
                        gaps.append(gap(
                            reasonCode: "depfile_source_unusable",
                            subject: .path(dependency),
                            nextAction: "depfile参照先をworkspace内の4 MiB以下のUTF-8 regular fileとして復元してください"
                        ))
                        continue
                    }
                    evidence.append(edgeEvidence(
                        changed: changed,
                        candidate: .init(category: .dependencies, subject: .path(dependency)),
                        record: record,
                        edgeTarget: dependency,
                        summary: "depfile prerequisite \(dependency) shares a target with \(changed.path)"
                    ))
                    bindings.append(.init(role: .analysis, path: dependency, contentSHA256: dependencySHA))

                    let stem = sourceStem(dependency)
                    for test in testFiles where testStem(test.path) == stem {
                        guard let testSHA = confirmCandidate(test.path, root: root, cache: &confirmed) else {
                            gaps.append(gap(
                                reasonCode: "depfile_test_unusable",
                                subject: .test(path: test.path),
                                nextAction: "test候補をworkspace内の4 MiB以下のUTF-8 regular fileとして復元してください"
                            ))
                            continue
                        }
                        evidence.append(.init(
                            inputIdentity: pathIdentity(changed),
                            candidate: .init(category: .relatedTests, subject: .test(path: test.path)),
                            relation: .namingHeuristic,
                            locator: .init(
                                path: test.path,
                                contentSHA256: testSHA,
                                edgeID: tuple(["depfile_test_basename", dependency, test.path])
                            ),
                            strength: .heuristic,
                            summary: "test basename matches depfile source prerequisite \(dependency)"
                        ))
                        bindings.append(.init(role: .analysis, path: test.path, contentSHA256: testSHA))
                    }
                }
            }
        }

        bindings = deduplicatedBindings(bindings)
        evidence = deduplicatedEvidence(evidence)
        gaps = deduplicatedGaps(gaps)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let changedPaths = input.changedPaths.sorted { pathIdentity($0) < pathIdentity($1) }
        let changedSymbols = input.changedSymbols.sorted { symbolIdentity($0) < symbolIdentity($1) }
        let material = sha256(try encoder.encode(changedPaths))
            + sha256(try encoder.encode(changedSymbols))
            + sha256(try encoder.encode(bindings))

        return .init(
            report: .init(
                descriptor: descriptor,
                status: .fresh,
                inputDigest: sha256(Data(material.utf8)),
                observedAtCursor: input.workspaceCursor
            ),
            evidence: evidence,
            freshnessBindings: bindings,
            coverageGaps: gaps
        )
    }

    private struct FileEntry {
        let url: URL
        let path: String
    }

    private struct Discovery {
        var depfiles: [FileEntry]
        var regularFiles: [FileEntry]
        var gaps: [ChangeImpactCoverageGap]
        var sawDepfile: Bool
    }

    private struct Record {
        let depfilePath: String
        let depfileSHA256: String
        let targets: [String]
        let prerequisites: [String]
        let ordinal: Int
    }

    private struct ParseResult {
        var records: [Record]
        var gaps: [ChangeImpactCoverageGap]
    }

    private func discover(in root: URL) throws -> Discovery {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else { throw AIShellError.invalidPath(root.path) }
        var result = Discovery(depfiles: [], regularFiles: [], gaps: [], sawDepfile: false)
        while let url = enumerator.nextObject() as? URL {
            let path = relativePath(url, root: root)
            if ReservedNamespacePolicy.shouldExclude(relativePath: path) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ])
            if isDepfile(path) { result.sawDepfile = true }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                if isDepfile(path) { result.gaps.append(fileGap(path, "depfile_symlink_unsupported")) }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let file = FileEntry(url: url, path: path)
            result.regularFiles.append(file)
            if isDepfile(path) {
                if (values.fileSize ?? 0) > Self.maximumFileBytes {
                    result.gaps.append(fileGap(path, "depfile_too_large"))
                } else {
                    result.depfiles.append(file)
                }
            }
        }
        result.depfiles.sort { utf8Less($0.path, $1.path) }
        result.regularFiles.sort { utf8Less($0.path, $1.path) }
        return result
    }

    private func parse(
        _ text: String,
        depfilePath: String,
        depfileSHA256: String,
        root: URL
    ) -> Result<ParseResult, ParseError> {
        guard let logical = logicalLines(text) else { return .failure(.invalid) }
        var result = ParseResult(records: [], gaps: [])
        for line in logical where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let colon = firstUnescapedColon(in: line) else { return .failure(.invalid) }
            guard let targets = tokens(String(line[..<colon])), !targets.isEmpty,
                  let rawPrerequisites = tokens(String(line[line.index(after: colon)...])),
                  !rawPrerequisites.isEmpty else { return .failure(.invalid) }
            var prerequisites: [String] = []
            for raw in rawPrerequisites {
                guard let path = workspacePath(raw, root: root) else {
                    result.gaps.append(gap(
                        reasonCode: "depfile_reference_outside_workspace",
                        subject: .path(depfilePath),
                        nextAction: "workspace外参照を除いたdepfileを生成してください"
                    ))
                    continue
                }
                prerequisites.append(path)
            }
            guard !prerequisites.isEmpty else {
                result.gaps.append(fileGap(depfilePath, "depfile_prerequisites_unusable"))
                continue
            }
            result.records.append(.init(
                depfilePath: depfilePath,
                depfileSHA256: depfileSHA256,
                targets: targets,
                prerequisites: Array(Set(prerequisites)).sorted(by: utf8Less),
                ordinal: result.records.count
            ))
        }
        guard !result.records.isEmpty else { return .failure(.invalid) }
        return .success(result)
    }

    private enum ParseError: Error { case invalid }

    private func logicalLines(_ text: String) -> [String]? {
        let bytes = Array(text.utf8)
        var lines: [String] = []
        var current: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x5C, index + 1 < bytes.count,
               bytes[index + 1] == 0x0A || bytes[index + 1] == 0x0D {
                index += 2
                if index <= bytes.count, bytes[index - 1] == 0x0D, index < bytes.count, bytes[index] == 0x0A {
                    index += 1
                }
                if current.last != 0x20 { current.append(0x20) }
                while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 { index += 1 }
                continue
            }
            if bytes[index] == 0x0A || bytes[index] == 0x0D {
                lines.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
                if bytes[index] == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 1 }
                index += 1
                continue
            }
            current.append(bytes[index])
            index += 1
        }
        if current.last == 0x5C { return nil }
        if !current.isEmpty { lines.append(String(decoding: current, as: UTF8.self)) }
        return lines
    }

    private func firstUnescapedColon(in line: String) -> String.Index? {
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == ":" { return index }
        }
        return nil
    }

    private func tokens(_ input: String) -> [String]? {
        var result: [String] = []
        var current = ""
        var escaped = false
        for character in input {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == " " || character == "\t" {
                if !current.isEmpty { result.append(current); current = "" }
            } else if character == "#" {
                break
            } else {
                current.append(character)
            }
        }
        guard !escaped else { return nil }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func workspacePath(_ raw: String, root: URL) -> String? {
        let url = URL(fileURLWithPath: raw, relativeTo: root).standardizedFileURL
        guard isWithinRoot(url, root: root) else { return nil }
        return relativePath(url, root: root)
    }

    private func confirmCandidate(_ path: String, root: URL, cache: inout [String: String]) -> String? {
        if let cached = cache[path] { return cached }
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard isWithinRoot(url, root: root),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Self.maximumFileBytes + 1) <= Self.maximumFileBytes,
              isWithinRoot(url.resolvingSymlinksInPath(), root: root),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= Self.maximumFileBytes, !data.contains(0), String(data: data, encoding: .utf8) != nil else {
            return nil
        }
        let digest = sha256(data)
        cache[path] = digest
        return digest
    }

    private func edgeEvidence(
        changed: ChangeImpactChangedPath,
        candidate: ChangeImpactCandidateSeed,
        record: Record,
        edgeTarget: String,
        summary: String
    ) -> ChangeImpactEvidenceSeed {
        .init(
            inputIdentity: pathIdentity(changed),
            candidate: candidate,
            relation: .declaredDependency,
            locator: .init(
                path: record.depfilePath,
                contentSHA256: record.depfileSHA256,
                edgeID: tuple(record.targets + [String(record.ordinal), changed.path, edgeTarget])
            ),
            strength: .declaredEdge,
            summary: summary
        )
    }

    private func isDepfile(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.lowercased() == "dep"
    }

    private func isSourcePath(_ path: String) -> Bool {
        Self.sourceExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private func isTestPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasPrefix("test/") || lower.contains("/test/")
            || lower.hasPrefix("tests/") || lower.contains("/tests/")
            || lower.contains(".test")
    }

    private func sourceStem(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()
    }

    private func testStem(_ path: String) -> String {
        var name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()
        if name.hasSuffix(".test") { name.removeLast(5) }
        return name
    }

    private func isWithinRoot(_ url: URL, root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path == root.path || url.path.hasPrefix(rootPath)
    }

    private func relativePath(_ url: URL, root: URL) -> String {
        url.standardizedFileURL.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
    }

    private func fileGap(_ path: String, _ reasonCode: String) -> ChangeImpactCoverageGap {
        gap(
            reasonCode: reasonCode,
            subject: .path(path),
            nextAction: "UTF-8 textの有効なMake depfileを再生成してください"
        )
    }

    private func gap(
        reasonCode: String,
        subject: ChangeImpactSubject?,
        nextAction: String
    ) -> ChangeImpactCoverageGap {
        .init(
            category: .dependencies,
            reasonCode: reasonCode,
            providerID: descriptor.providerID,
            subject: subject,
            nextAction: nextAction
        )
    }

    private func deduplicatedBindings(_ values: [ChangeImpactFreshnessBinding]) -> [ChangeImpactFreshnessBinding] {
        var seen: Set<String> = []
        return values.sorted {
            if $0.path != $1.path { return utf8Less($0.path, $1.path) }
            return bindingKey($0) < bindingKey($1)
        }.filter { seen.insert(bindingKey($0)).inserted }
    }

    private func deduplicatedEvidence(_ values: [ChangeImpactEvidenceSeed]) -> [ChangeImpactEvidenceSeed] {
        var seen: Set<String> = []
        return values.sorted { evidenceKey($0) < evidenceKey($1) }.filter { seen.insert(evidenceKey($0)).inserted }
    }

    private func deduplicatedGaps(_ values: [ChangeImpactCoverageGap]) -> [ChangeImpactCoverageGap] {
        var seen: Set<String> = []
        return values.sorted { gapKey($0) < gapKey($1) }.filter { seen.insert(gapKey($0)).inserted }
    }

    private func bindingKey(_ value: ChangeImpactFreshnessBinding) -> String {
        tuple([value.role.rawValue, value.path, value.contentSHA256 ?? "", value.expectedAbsent ? "1" : "0"])
    }

    private func evidenceKey(_ value: ChangeImpactEvidenceSeed) -> String {
        tuple([
            value.inputIdentity, value.candidate.category.rawValue, value.candidate.subject.kind.rawValue,
            value.candidate.subject.path ?? "", value.locator.path, value.locator.edgeID ?? ""
        ])
    }

    private func gapKey(_ value: ChangeImpactCoverageGap) -> String {
        tuple([value.category.rawValue, value.reasonCode, value.subject?.path ?? ""])
    }

    private func pathIdentity(_ value: ChangeImpactChangedPath) -> String {
        tuple(["input_path", value.path, value.expectedAbsent ? "1" : "0", value.contentSHA256 ?? ""])
    }

    private func symbolIdentity(_ value: ChangeImpactChangedSymbol) -> String {
        tuple([value.path, value.name, String(value.startOffset), String(value.endOffset), value.stableID ?? ""])
    }

    private func tuple(_ values: [String]) -> String {
        values.map { "\(Data($0.utf8).count):\($0)" }.joined()
    }

    private func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
