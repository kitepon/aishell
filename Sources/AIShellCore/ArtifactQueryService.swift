import CryptoKit
import Foundation

/// ACE-044b のquery compiler/immutable result stream seam。
/// productionのrun index、EvidenceStore、MCP protocolとは意図的に接続しない。
public actor ArtifactQueryService {
    public static let maximumPageBytes = 1_048_576

    public struct Artifact: Sendable, Equatable {
        public let id: String
        public let kind: String
        public let data: Data
        public let sha256: String
        public let historyBinding: HistoryBinding?

        public init(id: String, kind: String, data: Data, historyBinding: HistoryBinding? = nil) {
            self.id = id
            self.kind = kind
            self.data = data
            sha256 = Self.digest(data)
            self.historyBinding = historyBinding
        }

        private static func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    public struct HistoryBinding: Sendable, Equatable, Codable {
        public let request: String?
        public let toolchain: String?
        public let input: String?

        public init(request: String?, toolchain: String?, input: String?) {
            self.request = request
            self.toolchain = toolchain
            self.input = input
        }
    }

    public enum Mode: Sendable, Equatable { case sensitive, insensitive }
    public enum Pattern: Sendable, Equatable { case literal(String, mode: Mode), regex(String, flags: String = "") }

    public struct Request: Sendable, Equatable {
        public let pattern: Pattern
        public let pageByteLimit: Int

        public init(pattern: Pattern, pageByteLimit: Int = ArtifactQueryService.maximumPageBytes) {
            self.pattern = pattern
            self.pageByteLimit = min(max(1, pageByteLimit), ArtifactQueryService.maximumPageBytes)
        }
    }

    public struct OversizeDescriptor: Sendable, Equatable, Codable {
        public let sourceID: String
        public let offset: Int
        public let fullByteCount: Int
        public let contentSHA256: String
        /// 後続のartifact range readに渡す不透明でないrange descriptor。
        public let artifactRange: String
    }

    public enum Item: Sendable, Equatable {
        case match(sourceID: String, kind: String, offset: Int, line: Int, text: String)
        case oversizeDescriptor(OversizeDescriptor)
    }

    public struct Page: Sendable, Equatable {
        public let streamHandle: String
        public let items: [Item]
        public let nextCursor: String?
        public let hasMore: Bool
    }

    public struct Stream: Sendable, Equatable {
        public let handle: String
        public let items: [Item]
    }

    public struct HistoryArtifact: Sendable, Equatable {
        public let sha256: String
        public let sizeBytes: Int

        public init(sha256: String, sizeBytes: Int) {
            self.sha256 = sha256
            self.sizeBytes = sizeBytes
        }
    }

    public struct HistoryResult: Sendable, Equatable {
        public let baseline: HistoryArtifact
        public let candidate: HistoryArtifact
        public let artifactsEqual: Bool
        public let binding: HistoryComparison
    }

    public enum HistoryComparison: Sendable, Equatable {
        case equal
        case different(missingOnLeft: [String], missingOnRight: [String], changed: [String])
    }

    public enum Error: Swift.Error, Equatable, LocalizedError {
        case binaryCaseModeUnsupported
        case binaryRegexUnsupported
        case invalidRegex(String)
        case unsupportedRegexFlag(Character)
        case duplicateRegexFlag(Character)
        case resultStreamNotFound
        case invalidCursor

        public var errorDescription: String? {
            switch self {
            case .binaryCaseModeUnsupported: return "BINARY_CASE_MODE_UNSUPPORTED"
            case .binaryRegexUnsupported: return "BINARY_REGEX_UNSUPPORTED"
            case let .invalidRegex(reason): return "INVALID_REGEX: \(reason)"
            case let .unsupportedRegexFlag(flag): return "REGEX_FLAG_UNSUPPORTED: \(flag)"
            case let .duplicateRegexFlag(flag): return "REGEX_FLAG_DUPLICATE: \(flag)"
            case .resultStreamNotFound: return "RESULT_STREAM_NOT_FOUND"
            case .invalidCursor: return "RESULT_CURSOR_INVALID"
            }
        }
    }

    private struct StoredStream: Sendable {
        let requestDigest: String
        let cursorSecret: String
        let sources: [Artifact]
        let items: [Item]
    }
    private struct Cursor: Codable { let stream: String; let requestDigest: String; let ordinal: Int; let signature: String }
    private var streams: [String: StoredStream] = [:]

    public init() {}

    /// 全結果を先に確定するため、pageの連結は常にstream全体と一致する。
    public func start(_ request: Request, sources: [Artifact]) throws -> Page {
        let requestDigest = digest(request, sources: sources)
        let items = try compile(request, sources: sources).map {
            encodedSize($0) > request.pageByteLimit ? .oversizeDescriptor(descriptor(for: $0, sources: sources)) : $0
        }
        let handle = "rstream_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let secret = UUID().uuidString
        streams[handle] = StoredStream(requestDigest: requestDigest, cursorSecret: secret, sources: sources, items: items)
        return try page(handle: handle, ordinal: 0, limit: request.pageByteLimit)
    }

    public func next(streamHandle: String, cursor: String, pageByteLimit: Int = ArtifactQueryService.maximumPageBytes) throws -> Page {
        guard let stream = streams[streamHandle] else { throw Error.resultStreamNotFound }
        let decoded = try decode(cursor)
        guard decoded.stream == streamHandle, decoded.requestDigest == stream.requestDigest,
              decoded.ordinal >= 0, decoded.ordinal <= stream.items.count,
              decoded.signature == signature(stream: streamHandle, digest: stream.requestDigest, ordinal: decoded.ordinal, secret: stream.cursorSecret)
        else { throw Error.invalidCursor }
        return try page(handle: streamHandle, ordinal: decoded.ordinal, limit: min(max(1, pageByteLimit), Self.maximumPageBytes))
    }

    public func stream(handle: String) throws -> Stream {
        guard let stream = streams[handle] else { throw Error.resultStreamNotFound }
        return Stream(handle: handle, items: stream.items)
    }

    public func compareHistory(_ left: HistoryBinding?, _ right: HistoryBinding?) -> HistoryComparison {
        let keys = [("request", left?.request, right?.request), ("toolchain", left?.toolchain, right?.toolchain), ("input", left?.input, right?.input)]
        var missingLeft: [String] = [], missingRight: [String] = [], changed: [String] = []
        for (key, l, r) in keys {
            if l == nil { missingLeft.append(key) }
            if r == nil { missingRight.append(key) }
            if let l, let r, l != r { changed.append(key) }
        }
        return missingLeft.isEmpty && missingRight.isEmpty && changed.isEmpty ? .equal : .different(missingOnLeft: missingLeft, missingOnRight: missingRight, changed: changed)
    }

    public func compareHistory(baseline: Artifact, candidate: Artifact) -> HistoryResult {
        let baselineIdentity = HistoryArtifact(sha256: baseline.sha256, sizeBytes: baseline.data.count)
        let candidateIdentity = HistoryArtifact(sha256: candidate.sha256, sizeBytes: candidate.data.count)
        return HistoryResult(
            baseline: baselineIdentity,
            candidate: candidateIdentity,
            artifactsEqual: baselineIdentity == candidateIdentity,
            binding: compareHistory(baseline.historyBinding, candidate.historyBinding)
        )
    }

    private func compile(_ request: Request, sources: [Artifact]) throws -> [Item] {
        try validate(pattern: request.pattern)
        var result: [Item] = []
        // source順はrequest順。source内のitemはoffset昇順なのでstable tie-breakも保つ。
        for source in sources {
            guard let text = String(data: source.data, encoding: .utf8) else {
                switch request.pattern {
                case .literal(_, mode: .sensitive): result.append(contentsOf: rawLiteralItems(source, request: request))
                case .literal(_, mode: .insensitive): throw Error.binaryCaseModeUnsupported
                case .regex: throw Error.binaryRegexUnsupported
                }
                continue
            }
            result.append(contentsOf: try textItems(source, text: text, pattern: request.pattern))
        }
        return result
    }

    private func rawLiteralItems(_ source: Artifact, request: Request) -> [Item] {
        guard case let .literal(needle, mode: .sensitive) = request.pattern, !needle.isEmpty else { return [] }
        let bytes = Array(needle.utf8)
        guard !bytes.isEmpty, source.data.count >= bytes.count else { return [] }
        var result: [Item] = []
        let data = Array(source.data)
        for offset in 0...(data.count - bytes.count) where Array(data[offset..<(offset + bytes.count)]) == bytes {
            result.append(.match(sourceID: source.id, kind: source.kind, offset: offset, line: 0, text: ""))
        }
        return result
    }

    private func textItems(_ source: Artifact, text: String, pattern: Pattern) throws -> [Item] {
        let regex: NSRegularExpression?
        switch pattern {
        case .literal: regex = nil
        case let .regex(expression, flags):
            var options: NSRegularExpression.Options = []
            if flags.contains("i") { options.insert(.caseInsensitive) }
            do { regex = try NSRegularExpression(pattern: expression, options: options) }
            catch { throw Error.invalidRegex(error.localizedDescription) }
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var items: [Item] = []
        var byteOffset = 0
        for (index, part) in lines.enumerated() {
            let line = String(part)
            switch pattern {
            case let .literal(needle, mode):
                guard !needle.isEmpty else { continue }
                let options: String.CompareOptions = mode == .insensitive ? [.caseInsensitive] : []
                var searchStart = line.startIndex
                while searchStart < line.endIndex,
                      let range = line.range(of: needle, options: options, range: searchStart..<line.endIndex) {
                    let matchOffset = byteOffset + line[..<range.lowerBound].lengthOfBytes(using: .utf8)
                    items.append(.match(sourceID: source.id, kind: source.kind, offset: matchOffset, line: index + 1, text: line))
                    searchStart = range.upperBound
                }
            case .regex:
                for match in regex!.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    guard let range = Range(match.range, in: line) else { continue }
                    let matchOffset = byteOffset + line[..<range.lowerBound].lengthOfBytes(using: .utf8)
                    items.append(.match(sourceID: source.id, kind: source.kind, offset: matchOffset, line: index + 1, text: line))
                }
            }
            byteOffset += line.lengthOfBytes(using: .utf8)
            if index < lines.count - 1 { byteOffset += 1 }
        }
        return items
    }

    private func page(handle: String, ordinal: Int, limit: Int) throws -> Page {
        guard let stored = streams[handle] else { throw Error.resultStreamNotFound }
        var result: [Item] = [], used = 0, next = ordinal
        while next < stored.items.count {
            let item = stored.items[next]
            let encoded = encodedSize(item)
            if encoded > limit {
                // itemを消費するので、巨大item単独のpageもcursor停滞しない。
                result.append(.oversizeDescriptor(descriptor(for: item, sources: stored.sources)))
                next += 1
                break
            }
            if used + encoded > limit && !result.isEmpty { break }
            result.append(item); used += encoded; next += 1
        }
        let hasMore = next < stored.items.count
        let cursor = hasMore ? try encode(Cursor(stream: handle, requestDigest: stored.requestDigest, ordinal: next,
            signature: signature(stream: handle, digest: stored.requestDigest, ordinal: next, secret: stored.cursorSecret))) : nil
        return Page(streamHandle: handle, items: result, nextCursor: cursor, hasMore: hasMore)
    }

    private func descriptor(for item: Item) -> OversizeDescriptor {
        switch item {
        case let .match(sourceID, _, offset, _, text):
            let data = Data(text.utf8)
            return OversizeDescriptor(sourceID: sourceID, offset: offset, fullByteCount: data.count, contentSHA256: digest(data), artifactRange: "\(sourceID):\(offset):\(data.count)")
        case let .oversizeDescriptor(value): return value
        }
    }

    private func descriptor(for item: Item, sources: [Artifact]) -> OversizeDescriptor {
        guard case let .match(sourceID, _, matchOffset, _, text) = item,
              let source = sources.first(where: { $0.id == sourceID }) else {
            return descriptor(for: item)
        }
        let bytes = [UInt8](source.data)
        var lineStart = 0
        if matchOffset > 0 {
            for index in stride(from: min(matchOffset, bytes.count) - 1, through: 0, by: -1) where bytes[index] == 0x0A {
                lineStart = index + 1
                break
            }
        }
        let lineEnd = bytes[lineStart...].firstIndex(of: 0x0A) ?? bytes.count
        let lineData = Data(bytes[lineStart..<lineEnd])
        // textはUTF-8 lineと一致することをコンパイル時に保証する。rangeは行全体へ到達する。
        precondition(lineData == Data(text.utf8))
        return OversizeDescriptor(
            sourceID: sourceID,
            offset: lineStart,
            fullByteCount: lineData.count,
            contentSHA256: digest(lineData),
            artifactRange: "\(sourceID):\(lineStart):\(lineData.count)"
        )
    }

    private func validate(pattern: Pattern) throws {
        guard case let .regex(_, flags) = pattern else { return }
        var seen = Set<Character>()
        for flag in flags {
            guard flag == "i" else { throw Error.unsupportedRegexFlag(flag) }
            guard seen.insert(flag).inserted else { throw Error.duplicateRegexFlag(flag) }
        }
    }

    private func encodedSize(_ item: Item) -> Int {
        switch item {
        case let .match(sourceID, kind, offset, line, text): return Data("\(sourceID)\u{0}\(kind)\u{0}\(offset)\u{0}\(line)\u{0}\(text)".utf8).count
        case let .oversizeDescriptor(value): return Data("\(value.sourceID)\u{0}\(value.artifactRange)".utf8).count
        }
    }

    private func digest(_ request: Request, sources: [Artifact]) -> String {
        var bytes = Data("artifact-query-request-v1".utf8)
        appendCanonical(request.pageByteLimit, to: &bytes)
        switch request.pattern {
        case let .literal(value, mode):
            appendCanonical("literal", to: &bytes)
            appendCanonical(mode == .sensitive ? "sensitive" : "insensitive", to: &bytes)
            appendCanonical(value, to: &bytes)
        case let .regex(expression, flags):
            appendCanonical("regex", to: &bytes)
            appendCanonical(flags, to: &bytes)
            appendCanonical(expression, to: &bytes)
        }
        appendCanonical(sources.count, to: &bytes)
        for source in sources {
            appendCanonical(source.id, to: &bytes)
            appendCanonical(source.kind, to: &bytes)
            appendCanonical(source.sha256, to: &bytes)
        }
        return digest(bytes)
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func signature(stream: String, digest: String, ordinal: Int, secret: String) -> String { self.digest(Data("\(stream)\u{0}\(digest)\u{0}\(ordinal)\u{0}\(secret)".utf8)) }
    private func appendCanonical(_ value: String, to bytes: inout Data) {
        let valueBytes = Data(value.utf8)
        appendCanonical(valueBytes.count, to: &bytes)
        bytes.append(valueBytes)
    }
    private func appendCanonical(_ value: Int, to bytes: inout Data) {
        var bigEndian = UInt64(value).bigEndian
        withUnsafeBytes(of: &bigEndian) { bytes.append(contentsOf: $0) }
    }
    private func encode(_ cursor: Cursor) throws -> String {
        do { return try JSONEncoder().encode(cursor).base64EncodedString() }
        catch { throw Error.invalidCursor }
    }
    private func decode(_ cursor: String) throws -> Cursor {
        guard let data = Data(base64Encoded: cursor), let value = try? JSONDecoder().decode(Cursor.self, from: data) else { throw Error.invalidCursor }
        return value
    }
}
