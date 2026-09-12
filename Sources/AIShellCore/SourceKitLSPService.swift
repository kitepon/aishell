import CryptoKit
import Foundation

public enum SourceKitLSPOperation: String, Codable, Sendable {
    case definition, references, workspaceSymbols = "workspace_symbols", diagnostics
}

public enum SourceKitLSPStatus: String, Codable, Sendable {
    case fresh, stale, indexing, unavailable
}

public struct SourceKitLSPRequest: Sendable {
    public let root: URL
    public let workspaceCursor: String
    public let path: String
    public let contentSHA256: String
    public let operation: SourceKitLSPOperation
    public let symbol: String?
    public let line: Int?
    public let character: Int?

    public init(root: URL, workspaceCursor: String, path: String, contentSHA256: String,
                operation: SourceKitLSPOperation, symbol: String? = nil,
                line: Int? = nil, character: Int? = nil) {
        self.root = root; self.workspaceCursor = workspaceCursor; self.path = path
        self.contentSHA256 = contentSHA256; self.operation = operation; self.symbol = symbol
        self.line = line; self.character = character
    }
}

public struct SourceKitLSPLocation: Codable, Equatable, Sendable {
    public let path: String
    public let line: Int
    public let character: Int
    public let contentSHA256: String
}

public struct SourceKitLSPResult: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let status: SourceKitLSPStatus
    public let operation: SourceKitLSPOperation
    public let observedCursor: String
    public let locations: [SourceKitLSPLocation]
    public let reason: String?

    public init(status: SourceKitLSPStatus, operation: SourceKitLSPOperation,
                observedCursor: String, locations: [SourceKitLSPLocation], reason: String? = nil) {
        schemaVersion = "aishell.sourcekit-lsp.v1"
        self.status = status; self.operation = operation; self.observedCursor = observedCursor
        self.locations = locations; self.reason = reason
    }
}

public struct SourceKitLSPWorkerLocation: Equatable, Sendable {
    public let path: String
    public let line: Int
    public let character: Int

    public init(path: String, line: Int, character: Int) {
        self.path = path; self.line = line; self.character = character
    }
}

public enum SourceKitLSPWorkerResult: Equatable, Sendable {
    case success([SourceKitLSPWorkerLocation])
    case successWithEngine([SourceKitLSPWorkerLocation], String)
    case indexing(String)
    case unavailable(String)
}

public protocol SourceKitLSPWorker: Sendable {
    func query(_ request: SourceKitLSPRequest, document: Data) async throws -> SourceKitLSPWorkerResult
}

public struct UnavailableSourceKitLSPWorker: SourceKitLSPWorker {
    public init() {}
    public func query(_ request: SourceKitLSPRequest, document: Data) async throws -> SourceKitLSPWorkerResult {
        .unavailable("sourcekit-lsp worker is not configured")
    }
}

public final class SourceKitLSPProcessWorker: SourceKitLSPWorker, @unchecked Sendable {
    private let executableURL: URL
    private let arguments: [String]
    private let requestTimeout: Duration

    public init() {
        executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        arguments = ["sourcekit-lsp"]
        requestTimeout = .seconds(10)
    }

    init(executableURL: URL, arguments: [String], requestTimeout: Duration) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.requestTimeout = requestTimeout
    }

    public func query(_ request: SourceKitLSPRequest, document: Data) async throws -> SourceKitLSPWorkerResult {
        guard let text = String(data: document, encoding: .utf8) else {
            return .unavailable("source document is not UTF-8")
        }
        if request.operation == .references,
           !FileManager.default.fileExists(atPath: request.root.appendingPathComponent("Package.swift").path),
           let locations = try semanticBatchReferences(request: request, primaryText: text) {
            return .successWithEngine(locations, "swift-frontend-semantic-batch")
        }
        do {
            let process = Process()
            let input = Pipe(), output = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            // Processはpipe descriptorを子へ複製済み。親が未使用端を保持すると、timeoutで子を
            // terminateしてもstdout readerへEOFが届かず、task groupが永久に閉じない。
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            let connection = LSPConnection(input: input.fileHandleForWriting, output: output.fileHandleForReading)
            defer {
                connection.close()
                if process.isRunning { process.terminate() }
                // timeout側とFoundationのtermination監視が同時に終了を観測した後に
                // waitUntilExit()を重ねると、全test suite内でまれに永久待機する。
                // Process自身が子をreapするため、cleanupではdescriptor closeと停止要求までに留める。
            }
            let rootURI = request.root.standardizedFileURL.absoluteString
            _ = try await Self.request(
                connection, process: process, timeout: requestTimeout,
                id: 1, method: "initialize", params: [
                "processId": ProcessInfo.processInfo.processIdentifier,
                "rootUri": rootURI,
                "capabilities": [:],
            ])
            try connection.notify(method: "initialized", params: [:])
            let documentURL = request.root.appendingPathComponent(request.path).standardizedFileURL
            for (url, contents) in try Self.workspaceDocuments(request: request, primaryText: text) {
                try connection.notify(method: "textDocument/didOpen", params: [
                    "textDocument": [
                        "uri": url.absoluteString, "languageId": "swift", "version": 1, "text": contents,
                    ],
                ])
            }
            let method: String
            let params: [String: Any]
            switch request.operation {
            case .definition:
                method = "textDocument/definition"
                params = Self.positionParams(request, uri: documentURL.absoluteString)
            case .references:
                method = "textDocument/references"
                var value = Self.positionParams(request, uri: documentURL.absoluteString)
                value["context"] = ["includeDeclaration": true]
                params = value
            case .workspaceSymbols:
                method = "workspace/symbol"
                params = ["query": request.symbol ?? ""]
            case .diagnostics:
                return .unavailable("sourcekit-lsp push diagnostics require a retained session")
            }
            let response = try await Self.request(
                connection, process: process, timeout: requestTimeout,
                id: 2, method: method, params: params
            )
            guard response["error"] == nil else {
                let message = ((response["error"] as? [String: Any])?["message"] as? String) ?? "LSP request failed"
                return message.localizedCaseInsensitiveContains("index") ? .indexing(message) : .unavailable(message)
            }
            return .success(Self.locations(response["result"], root: request.root))
        } catch {
            return .unavailable("sourcekit-lsp unavailable: \(error.localizedDescription)")
        }
    }

    private static func positionParams(_ request: SourceKitLSPRequest, uri: String) -> [String: Any] {
        ["textDocument": ["uri": uri],
         "position": ["line": request.line ?? 0, "character": request.character ?? 0]]
    }

    private static func workspaceDocuments(
        request: SourceKitLSPRequest,
        primaryText: String
    ) throws -> [(URL, String)] {
        let root = request.root.standardizedFileURL
        let primary = root.appendingPathComponent(request.path).standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return [(primary, primaryText)]
        }
        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            guard !relative.hasPrefix(".build/"), !relative.hasPrefix(".git/") else { continue }
            urls.append(url.standardizedFileURL)
            if urls.count > 2_048 {
                throw NSError(
                    domain: "AIShell.SourceKitLSP",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "sourcekit-lsp workspace document limit exceeded"]
                )
            }
        }
        if !urls.contains(primary) { urls.append(primary) }
        var totalBytes = 0
        return try urls.sorted(by: { $0.path < $1.path }).map { url in
            let contents: String
            if url == primary {
                contents = primaryText
            } else {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard let decoded = String(data: data, encoding: .utf8) else {
                    throw NSError(
                        domain: "AIShell.SourceKitLSP",
                        code: 8,
                        userInfo: [NSLocalizedDescriptionKey: "sourcekit-lsp workspace document is not UTF-8"]
                    )
                }
                contents = decoded
            }
            totalBytes += contents.utf8.count
            guard totalBytes <= 16 * 1_024 * 1_024 else {
                throw NSError(
                    domain: "AIShell.SourceKitLSP",
                    code: 9,
                    userInfo: [NSLocalizedDescriptionKey: "sourcekit-lsp workspace document byte limit exceeded"]
                )
            }
            return (url, contents)
        }
    }

    private func semanticBatchReferences(
        request: SourceKitLSPRequest,
        primaryText: String
    ) throws -> [SourceKitLSPWorkerLocation]? {
        guard let symbol = request.symbol, !symbol.isEmpty else { return nil }
        let documents = try Self.workspaceDocuments(request: request, primaryText: primaryText)
        guard !documents.isEmpty else { return nil }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIShellSemantic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let outputURL = scratch.appendingPathComponent("ast.txt")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", "-typecheck", "-dump-ast"] + documents.map { $0.0.path }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = try Data(contentsOf: outputURL, options: .mappedIfSafe)
        guard data.count <= 64 * 1_024 * 1_024,
              let ast = String(data: data, encoding: .utf8) else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: symbol)
        let expression = try NSRegularExpression(
            pattern: #"\(declref_expr[^\n]*location=([^\s]+):(\d+):(\d+)[^\n]*decl=\"[^\"]*\."#
                + escaped + #"(?:\(|@)"#
        )
        let range = NSRange(ast.startIndex..<ast.endIndex, in: ast)
        return expression.matches(in: ast, range: range).compactMap { match in
            guard let pathRange = Range(match.range(at: 1), in: ast),
                  let lineRange = Range(match.range(at: 2), in: ast),
                  let characterRange = Range(match.range(at: 3), in: ast),
                  let line = Int(ast[lineRange]), let character = Int(ast[characterRange]) else { return nil }
            let url = URL(fileURLWithPath: String(ast[pathRange])).standardizedFileURL
            let root = request.root.standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else { return nil }
            return .init(
                path: String(url.path.dropFirst(root.path.count + 1)),
                line: max(0, line - 1),
                character: max(0, character - 1)
            )
        }
    }

    private static func request(
        _ connection: LSPConnection,
        process: Process,
        timeout: Duration,
        id: Int,
        method: String,
        params: [String: Any]
    ) async throws -> [String: Any] {
        let request = LSPJSON(params)
        let timeoutState = LSPRequestTimeoutState()
        return try await withThrowingTaskGroup(of: LSPJSON.self) { group in
            group.addTask {
                do {
                    return LSPJSON(try connection.request(id: id, method: method, params: request.value))
                } catch {
                    if timeoutState.hasTimedOut { throw Self.timeoutError() }
                    throw error
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                timeoutState.markTimedOut()
                connection.close()
                if process.isRunning { process.terminate() }
                throw Self.timeoutError()
            }
            guard let first = try await group.next() else {
                throw NSError(domain: "AIShell.SourceKitLSP", code: 6)
            }
            group.cancelAll()
            return first.value
        }
    }

    private static func timeoutError() -> NSError {
        NSError(domain: "AIShell.SourceKitLSP", code: 5,
            userInfo: [NSLocalizedDescriptionKey: "sourcekit-lsp request timed out"])
    }

    private static func locations(_ value: Any?, root: URL) -> [SourceKitLSPWorkerLocation] {
        let values: [[String: Any]]
        if let array = value as? [[String: Any]] { values = array }
        else if let object = value as? [String: Any] { values = [object] }
        else { values = [] }
        return values.compactMap { object in
            let location = (object["location"] as? [String: Any]) ?? object
            guard let uri = location["uri"] as? String, let url = URL(string: uri),
                  let range = location["range"] as? [String: Any],
                  let start = range["start"] as? [String: Any],
                  let line = start["line"] as? Int, let character = start["character"] as? Int else { return nil }
            let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard canonical.path.hasPrefix(canonicalRoot.path + "/") else { return nil }
            return .init(path: String(canonical.path.dropFirst(canonicalRoot.path.count + 1)),
                line: line, character: character)
        }
    }
}

private struct LSPJSON: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

private final class LSPRequestTimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false

    var hasTimedOut: Bool {
        lock.withLock { timedOut }
    }

    func markTimedOut() {
        lock.withLock { timedOut = true }
    }
}

private final class LSPConnection: @unchecked Sendable {
    private let input: FileHandle
    private let output: FileHandle
    private var buffer = Data()

    init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.output = output
    }

    func notify(method: String, params: [String: Any]) throws {
        try write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    func request(id: Int, method: String, params: [String: Any]) throws -> [String: Any] {
        try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        for _ in 0..<128 {
            let message = try readMessage()
            if (message["id"] as? Int) == id { return message }
        }
        throw NSError(domain: "AIShell.SourceKitLSP", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "LSP response limit exceeded"])
    }

    /// `FileHandle.availableData`はTask cancellationでは中断されないため、timeout側から
    /// descriptorを閉じてblocking read/writeを確実に解放する。
    func close() {
        try? input.close()
        try? output.close()
    }

    private func write(_ object: [String: Any]) throws {
        let payload = try JSONSerialization.data(withJSONObject: object)
        var frame = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
        frame.append(payload)
        try input.write(contentsOf: frame)
    }

    private func readMessage() throws -> [String: Any] {
        while true {
            if let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buffer[..<boundary.lowerBound], as: UTF8.self)
                let length = header.split(separator: "\n").compactMap { line -> Int? in
                    let pieces = line.split(separator: ":", maxSplits: 1)
                    guard pieces.count == 2, pieces[0].lowercased() == "content-length" else { return nil }
                    return Int(pieces[1].trimmingCharacters(in: .whitespacesAndNewlines))
                }.first
                guard let length else { throw NSError(domain: "AIShell.SourceKitLSP", code: 2) }
                let payloadStart = boundary.upperBound
                if buffer.count >= payloadStart + length {
                    let payload = buffer.subdata(in: payloadStart..<(payloadStart + length))
                    buffer.removeSubrange(0..<(payloadStart + length))
                    guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                        throw NSError(domain: "AIShell.SourceKitLSP", code: 3)
                    }
                    return object
                }
            }
            let chunk = output.availableData
            guard !chunk.isEmpty else {
                throw NSError(domain: "AIShell.SourceKitLSP", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "sourcekit-lsp closed stdout"])
            }
            buffer.append(chunk)
        }
    }
}

public actor SourceKitLSPService {
    private let runtimeStore: RuntimeStore
    private let workspaceRuntime: WorkspaceStateRuntime
    private let worker: any SourceKitLSPWorker

    public init(runtimeStore: RuntimeStore, workspaceRuntime: WorkspaceStateRuntime,
                worker: any SourceKitLSPWorker = SourceKitLSPProcessWorker()) {
        self.runtimeStore = runtimeStore; self.workspaceRuntime = workspaceRuntime; self.worker = worker
    }

    public func query(_ request: SourceKitLSPRequest) async throws -> SourceKitLSPResult {
        let resolver = await runtimeStore.pathResolver()
        let root = try resolver.resolveExisting(request.root.path)
        let documentURL = try resolver.resolveExisting(root.appendingPathComponent(request.path).path)
        let before = try Data(contentsOf: documentURL, options: .mappedIfSafe)
        let beforeSHA = Self.sha(before)
        let initial = try await workspaceRuntime.snapshot(path: root.path, sinceCursor: request.workspaceCursor)
        guard initial.changes.isEmpty, beforeSHA == request.contentSHA256 else {
            return .init(status: .stale, operation: request.operation,
                observedCursor: initial.cursor, locations: [], reason: "workspace_or_document_changed")
        }
        let workerResult = try await worker.query(request, document: before)
        switch workerResult {
        case let .indexing(reason):
            return .init(status: .indexing, operation: request.operation,
                observedCursor: initial.cursor, locations: [], reason: reason)
        case let .unavailable(reason):
            return .init(status: .unavailable, operation: request.operation,
                observedCursor: initial.cursor, locations: [], reason: reason)
        case let .success(rawLocations), let .successWithEngine(rawLocations, _):
            let after = try await workspaceRuntime.snapshot(path: root.path, sinceCursor: request.workspaceCursor)
            guard after.changes.isEmpty,
                  let afterBytes = try? Data(contentsOf: documentURL, options: .mappedIfSafe),
                  Self.sha(afterBytes) == beforeSHA else {
                return .init(status: .stale, operation: request.operation,
                    observedCursor: after.cursor, locations: [], reason: "document_changed_during_query")
            }
            var locations: [SourceKitLSPLocation] = []
            for raw in rawLocations {
                let url = try resolver.resolveExisting(root.appendingPathComponent(raw.path).path)
                guard let bytes = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                locations.append(.init(path: String(url.path.dropFirst(root.path.count + 1)),
                    line: raw.line, character: raw.character, contentSHA256: Self.sha(bytes)))
            }
            let engine: String?
            if case let .successWithEngine(_, value) = workerResult { engine = value } else { engine = nil }
            return .init(status: .fresh, operation: request.operation,
                observedCursor: after.cursor, locations: locations.sorted {
                    ($0.path, $0.line, $0.character) < ($1.path, $1.line, $1.character)
                }, reason: engine)
        }
    }

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
