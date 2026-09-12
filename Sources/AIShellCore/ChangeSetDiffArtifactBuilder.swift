import CryptoKit
import Foundation

/// ADR 0017の完全diff artifactを、filesystemやEvidenceStoreに依存せず構築する。
public enum ChangeSetDiffArtifactBuilder {
    public static let schema = "aishell.apply-change-set-diff.v1"
    private static let magic = Data("AISHELL-CSDIFF-V1\n".utf8)

    public struct Binding: Codable, Equatable, Sendable {
        public let transactionID: String
        public let requestDigest: String
        public let manifestDigest: String
        public let root: String
        public let fromCursor: ApplyChangeSetCursor
        public let toCursor: ApplyChangeSetCursor
        public let clientID: String
        public let clientEpoch: Int
        public let requestSequence: Int

        public init(
            transactionID: String,
            requestDigest: String,
            manifestDigest: String,
            root: String,
            fromCursor: ApplyChangeSetCursor,
            toCursor: ApplyChangeSetCursor,
            clientID: String,
            clientEpoch: Int,
            requestSequence: Int
        ) {
            self.transactionID = transactionID
            self.requestDigest = requestDigest
            self.manifestDigest = manifestDigest
            self.root = root
            self.fromCursor = fromCursor
            self.toCursor = toCursor
            self.clientID = clientID
            self.clientEpoch = clientEpoch
            self.requestSequence = requestSequence
        }
    }

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case create, write, delete, rename
    }

    public struct Snapshot: Equatable, Sendable {
        public let path: String
        public let identity: String?
        public let mode: UInt16?
        public let bytes: Data

        public init(path: String, identity: String? = nil, mode: UInt16? = nil, bytes: Data) {
            self.path = path
            self.identity = identity
            self.mode = mode
            self.bytes = bytes
        }
    }

    public struct Change: Equatable, Sendable {
        public let changeID: String
        public let kind: Kind
        public let before: Snapshot?
        public let after: Snapshot?

        public init(changeID: String, kind: Kind, before: Snapshot?, after: Snapshot?) {
            self.changeID = changeID
            self.kind = kind
            self.before = before
            self.after = after
        }
    }

    public enum Representation: String, Codable, Sendable {
        case rawUnifiedDiff
        case binaryMetadata
    }

    public struct SnapshotHeader: Codable, Equatable, Sendable {
        public let path: String
        public let identity: String?
        public let mode: UInt16?
        public let sizeBytes: Int
        public let sha256: String
        public let lineCount: Int?
        public let endsWithNewline: Bool?
    }

    public struct ChangeHeader: Codable, Equatable, Sendable {
        public let changeID: String
        public let kind: Kind
        public let before: SnapshotHeader?
        public let after: SnapshotHeader?
        public let representation: Representation
        public let sectionSHA256: String
        public let sectionSizeBytes: Int
    }

    public struct Header: Codable, Equatable, Sendable {
        public let schema: String
        public let binding: Binding
        public let changes: [ChangeHeader]
    }

    public struct Preview: Equatable, Sendable {
        /// artifact先頭から、headerと完全なsectionだけを含むlossless prefix。
        public let bytes: Data
        public let returnedBytes: Int
        public let omittedBytes: Int
        public let hasMore: Bool
    }

    public struct Output: Equatable, Sendable {
        public let artifact: Data
        public let sha256: String
        public let header: Header
        public let preview: Preview
    }

    public struct DecodedSection: Equatable, Sendable {
        public let header: ChangeHeader
        public let bytes: Data

        /// text sectionだけを元のbefore/after bytesへ戻す。binaryはADR 0017どおりmetadataのみを保持する。
        public func reconstructText() throws -> (before: Data?, after: Data?) {
            guard header.representation == .rawUnifiedDiff else {
                throw Error.wrongRepresentation
            }
            return try ChangeSetDiffArtifactBuilder.reconstructText(section: bytes, header: header)
        }
    }

    public struct DecodedArtifact: Equatable, Sendable {
        public let header: Header
        public let sections: [DecodedSection]
    }

    public enum Error: Swift.Error, Equatable {
        case invalidBinding(String)
        case invalidChange(String)
        case invalidBudget
        case malformedArtifact
        case corruptArtifact(String)
        case wrongRepresentation
    }

    public static func build(binding: Binding, changes: [Change], previewBudget: Int) throws -> Output {
        guard previewBudget >= 0 else { throw Error.invalidBudget }
        try validate(binding: binding)
        guard !changes.isEmpty else { throw Error.invalidChange("changes must not be empty") }
        guard Set(changes.map(\.changeID)).count == changes.count else {
            throw Error.invalidChange("change IDs must be unique")
        }

        let ordered = try changes.map { change -> (sortKey: Data, header: ChangeHeader, section: Data) in
            try validate(change: change)
            let representation: Representation = isText(change.before?.bytes) && isText(change.after?.bytes)
                ? .rawUnifiedDiff : .binaryMetadata
            let section: Data
            switch representation {
            case .rawUnifiedDiff:
                section = makeUnifiedDiff(change)
            case .binaryMetadata:
                section = try canonicalEncode(BinaryMetadata(
                    schema: "aishell.apply-change-set-binary-diff.v1",
                    changeID: change.changeID,
                    kind: change.kind,
                    before: makeSnapshotHeader(change.before, text: false),
                    after: makeSnapshotHeader(change.after, text: false)
                ))
            }
            let header = ChangeHeader(
                changeID: change.changeID,
                kind: change.kind,
                before: makeSnapshotHeader(change.before, text: representation == .rawUnifiedDiff),
                after: makeSnapshotHeader(change.after, text: representation == .rawUnifiedDiff),
                representation: representation,
                sectionSHA256: digest(section),
                sectionSizeBytes: section.count
            )
            return (canonicalSortKey(change), header, section)
        }.sorted { lhs, rhs in
            if lhs.sortKey != rhs.sortKey { return lhs.sortKey.lexicographicallyPrecedes(rhs.sortKey) }
            return Data(lhs.header.changeID.utf8).lexicographicallyPrecedes(Data(rhs.header.changeID.utf8))
        }

        let header = Header(schema: schema, binding: binding, changes: ordered.map(\.header))
        let headerBytes = try canonicalEncode(header)
        var artifact = magic
        appendUInt64(UInt64(headerBytes.count), to: &artifact)
        artifact.append(headerBytes)
        appendUInt32(UInt32(ordered.count), to: &artifact)
        let headerEnd = artifact.count

        var recordEnds: [Int] = []
        for item in ordered {
            let recordHeader = try canonicalEncode(item.header)
            appendUInt64(UInt64(recordHeader.count), to: &artifact)
            artifact.append(recordHeader)
            appendUInt64(UInt64(item.section.count), to: &artifact)
            artifact.append(item.section)
            recordEnds.append(artifact.count)
        }

        let returnedEnd: Int
        if headerEnd > previewBudget {
            returnedEnd = 0
        } else {
            returnedEnd = recordEnds.last(where: { $0 <= previewBudget }) ?? headerEnd
        }
        let previewBytes = artifact.prefix(returnedEnd)
        let preview = Preview(
            bytes: Data(previewBytes),
            returnedBytes: previewBytes.count,
            omittedBytes: artifact.count - previewBytes.count,
            hasMore: previewBytes.count != artifact.count
        )
        return Output(artifact: artifact, sha256: digest(artifact), header: header, preview: preview)
    }

    public static func decode(_ artifact: Data) throws -> DecodedArtifact {
        var reader = Reader(artifact)
        guard try reader.read(count: magic.count) == magic else { throw Error.malformedArtifact }
        let headerLength = try reader.readLength()
        let headerBytes = try reader.read(count: headerLength)
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: headerBytes) }
        catch { throw Error.malformedArtifact }
        guard header.schema == schema, try canonicalEncode(header) == headerBytes else {
            throw Error.corruptArtifact("non-canonical or unknown header")
        }
        try validate(binding: header.binding)
        let count = Int(try reader.readUInt32())
        guard count == header.changes.count else { throw Error.corruptArtifact("section count mismatch") }
        var sections: [DecodedSection] = []
        for expected in header.changes {
            let recordHeaderBytes = try reader.read(count: try reader.readLength())
            let recordHeader: ChangeHeader
            do { recordHeader = try JSONDecoder().decode(ChangeHeader.self, from: recordHeaderBytes) }
            catch { throw Error.malformedArtifact }
            guard recordHeader == expected, try canonicalEncode(recordHeader) == recordHeaderBytes else {
                throw Error.corruptArtifact("record header mismatch")
            }
            let section = try reader.read(count: try reader.readLength())
            guard section.count == recordHeader.sectionSizeBytes, digest(section) == recordHeader.sectionSHA256 else {
                throw Error.corruptArtifact("section digest mismatch")
            }
            let decoded = DecodedSection(header: recordHeader, bytes: section)
            if recordHeader.representation == .rawUnifiedDiff {
                let reconstructed = try decoded.reconstructText()
                try verify(reconstructed.before, against: recordHeader.before)
                try verify(reconstructed.after, against: recordHeader.after)
            } else {
                let metadata: BinaryMetadata
                do { metadata = try JSONDecoder().decode(BinaryMetadata.self, from: section) }
                catch { throw Error.corruptArtifact("invalid binary metadata") }
                guard try canonicalEncode(metadata) == section,
                      metadata.changeID == recordHeader.changeID,
                      metadata.kind == recordHeader.kind,
                      metadata.before == recordHeader.before,
                      metadata.after == recordHeader.after else {
                    throw Error.corruptArtifact("binary metadata mismatch")
                }
            }
            sections.append(decoded)
        }
        guard reader.isAtEnd else { throw Error.corruptArtifact("trailing bytes") }
        return DecodedArtifact(header: header, sections: sections)
    }

    private struct BinaryMetadata: Codable, Equatable {
        let schema: String
        let changeID: String
        let kind: Kind
        let before: SnapshotHeader?
        let after: SnapshotHeader?
    }

    private static func validate(binding: Binding) throws {
        guard !binding.transactionID.isEmpty, !binding.root.isEmpty,
              binding.fromCursor.root == binding.root, binding.toCursor.root == binding.root,
              binding.fromCursor.generation == binding.toCursor.generation,
              binding.toCursor.sequence >= binding.fromCursor.sequence,
              binding.clientEpoch > 0, binding.requestSequence > 0 else {
            throw Error.invalidBinding("inconsistent transaction, root, cursor, or request binding")
        }
        for (name, value) in [("request", binding.requestDigest), ("manifest", binding.manifestDigest)] {
            guard value.count == 64, value.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw Error.invalidBinding("\(name) digest must be canonical lowercase SHA-256")
            }
        }
    }

    private static func validate(change: Change) throws {
        guard !change.changeID.isEmpty else { throw Error.invalidChange("change ID must not be empty") }
        let valid: Bool
        switch change.kind {
        case .create: valid = change.before == nil && change.after != nil
        case .write: valid = change.before != nil && change.after != nil && change.before?.path == change.after?.path
        case .delete: valid = change.before != nil && change.after == nil
        case .rename: valid = change.before != nil && change.after != nil && change.before?.path != change.after?.path
        }
        guard valid else { throw Error.invalidChange("\(change.changeID) does not match \(change.kind.rawValue) shape") }
    }

    private static func canonicalSortKey(_ change: Change) -> Data {
        let path = change.after?.path ?? change.before?.path ?? ""
        return Data(path.utf8)
    }

    private static func makeSnapshotHeader(_ snapshot: Snapshot?, text: Bool) -> SnapshotHeader? {
        snapshot.map {
            let lines = text ? splitLines($0.bytes) : []
            return SnapshotHeader(
                path: $0.path,
                identity: $0.identity,
                mode: $0.mode,
                sizeBytes: $0.bytes.count,
                sha256: digest($0.bytes),
                lineCount: text ? lines.count : nil,
                endsWithNewline: text ? $0.bytes.last == 0x0A : nil
            )
        }
    }

    private static func isText(_ data: Data?) -> Bool {
        guard let data else { return true }
        return !data.contains(0) && String(data: data, encoding: .utf8) != nil
    }

    private static func makeUnifiedDiff(_ change: Change) -> Data {
        let before = change.before?.bytes ?? Data()
        let after = change.after?.bytes ?? Data()
        let beforeLines = splitLines(before)
        let afterLines = splitLines(after)
        let beforePath = change.before.map { Data($0.path.utf8).base64EncodedString() } ?? "/dev/null"
        let afterPath = change.after.map { Data($0.path.utf8).base64EncodedString() } ?? "/dev/null"
        var output = Data("--- path-base64:\(beforePath)\n+++ path-base64:\(afterPath)\n@@ -1,\(beforeLines.count) +1,\(afterLines.count) @@\n".utf8)
        appendDiffLines(beforeLines, prefix: 0x2D, to: &output)
        appendDiffLines(afterLines, prefix: 0x2B, to: &output)
        return output
    }

    private static func appendDiffLines(_ lines: [Data], prefix: UInt8, to output: inout Data) {
        for line in lines {
            output.append(prefix)
            output.append(line)
            if line.last != 0x0A {
                output.append(0x0A)
                output.append(Data("\\ No newline at end of file\n".utf8))
            }
        }
    }

    private static func splitLines(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        var result: [Data] = []
        var start = data.startIndex
        var index = start
        while index < data.endIndex {
            if data[index] == 0x0A {
                let end = data.index(after: index)
                result.append(Data(data[start..<end]))
                start = end
            }
            index = data.index(after: index)
        }
        if start < data.endIndex { result.append(Data(data[start..<data.endIndex])) }
        return result
    }

    private static func reconstructText(section: Data, header: ChangeHeader) throws -> (before: Data?, after: Data?) {
        var cursor = section.startIndex
        for _ in 0..<3 { _ = try consumePhysicalLine(section, cursor: &cursor) }
        let before = try consumeDiffSide(section, cursor: &cursor, prefix: 0x2D, header: header.before)
        let after = try consumeDiffSide(section, cursor: &cursor, prefix: 0x2B, header: header.after)
        guard cursor == section.endIndex else { throw Error.corruptArtifact("unexpected unified diff bytes") }
        return (header.before == nil ? nil : before, header.after == nil ? nil : after)
    }

    private static func consumeDiffSide(_ data: Data, cursor: inout Data.Index, prefix: UInt8, header: SnapshotHeader?) throws -> Data {
        let count = header?.lineCount ?? 0
        var result = Data()
        for lineIndex in 0..<count {
            let physical = try consumePhysicalLine(data, cursor: &cursor)
            guard physical.first == prefix else { throw Error.corruptArtifact("invalid unified diff prefix") }
            var raw = Data(physical.dropFirst())
            let isLastWithoutNewline = lineIndex == count - 1 && header?.endsWithNewline == false
            if isLastWithoutNewline {
                guard raw.last == 0x0A else { throw Error.corruptArtifact("missing synthetic newline") }
                raw.removeLast()
                let marker = try consumePhysicalLine(data, cursor: &cursor)
                guard marker == Data("\\ No newline at end of file\n".utf8) else {
                    throw Error.corruptArtifact("missing no-newline marker")
                }
            }
            result.append(raw)
        }
        return result
    }

    private static func consumePhysicalLine(_ data: Data, cursor: inout Data.Index) throws -> Data {
        guard cursor < data.endIndex, let newline = data[cursor...].firstIndex(of: 0x0A) else {
            throw Error.corruptArtifact("truncated unified diff line")
        }
        let end = data.index(after: newline)
        defer { cursor = end }
        return Data(data[cursor..<end])
    }

    private static func verify(_ bytes: Data?, against header: SnapshotHeader?) throws {
        guard (bytes == nil) == (header == nil) else { throw Error.corruptArtifact("snapshot presence mismatch") }
        guard let bytes, let header else { return }
        guard bytes.count == header.sizeBytes, digest(bytes) == header.sha256 else {
            throw Error.corruptArtifact("snapshot digest mismatch")
        }
    }

    private static func canonicalEncode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private struct Reader {
        let data: Data
        var offset = 0
        init(_ data: Data) { self.data = data }
        var isAtEnd: Bool { offset == data.count }

        mutating func read(count: Int) throws -> Data {
            guard count >= 0, offset <= data.count, count <= data.count - offset else { throw Error.malformedArtifact }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }

        mutating func readUInt32() throws -> UInt32 {
            let bytes = try read(count: 4)
            return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }

        mutating func readLength() throws -> Int {
            let bytes = try read(count: 8)
            let value = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard value <= UInt64(Int.max), value <= UInt64(data.count) else { throw Error.malformedArtifact }
            return Int(value)
        }
    }
}
