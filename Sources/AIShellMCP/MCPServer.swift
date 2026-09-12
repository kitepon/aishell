import AIShellCore
import Foundation

final class MCPServer: Sendable {
    private let files: NativeFileService
    private let processes: NativeProcessService
    private let log: UsageLog

    init(workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
         usageLog: UsageLog = UsageLog()) {
        files = NativeFileService(workingDirectory: workingDirectory)
        processes = NativeProcessService(workingDirectory: workingDirectory)
        log = usageLog
    }

    func run(writer: MCPResponseWriter = MCPResponseWriter()) async -> Int32 {
        let scheduler = MCPRequestScheduler(writer: writer) { [self] request in await handle(request) }
        do {
            while let line = readLine() {
                let request: JSONRPCRequest
                do { request = try JSONDecoder.aishell.decode(JSONRPCRequest.self, from: Data(line.utf8)) }
                catch {
                    try await writer.write(.failure(id: .null, code: -32700, message: "JSON-RPCを解析できません。"))
                    continue
                }
                await scheduler.submit(request)
            }
            try await scheduler.waitUntilIdle()
            return 0
        } catch {
            FileHandle.standardError.write(Data("aishell-mcp: \(error.localizedDescription)\n".utf8))
            return 74
        }
    }

    func handle(_ request: JSONRPCRequest) async -> JSONRPCResponse? {
        guard request.jsonrpc == "2.0" else {
            return .failure(id: request.id ?? .null, code: -32600, message: "jsonrpcは2.0である必要があります。")
        }
        guard let id = request.id else { return nil }
        switch id {
        case .string, .number, .null: break
        default: return .failure(id: .null, code: -32600, message: "request idの形式が不正です。")
        }
        switch request.method {
        case "initialize":
            return .success(id: id, result: .object([
                "protocolVersion": .string("2025-11-25"),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string("aishell-macos"), "version": .string(AIShellProduct.version)]),
                "instructions": .string("macOSのファイル、process、アプリを直接操作します。絶対パスは指定した場所、相対パスと省略時は起動ディレクトリを使います。shell展開は行いません。")
            ]))
        case "ping":
            return .success(id: id, result: .object([:]))
        case "tools/list":
            do { return .success(id: id, result: .object(["tools": try .from(ToolCatalog.tools)])) }
            catch { return .failure(id: id, code: -32603, message: error.localizedDescription) }
        case "tools/call":
            return await callTool(id: id, params: request.params)
        default:
            return .failure(id: id, code: -32601, message: "未対応のmethodです: \(request.method)")
        }
    }

    func callTool(id: JSONValue, params: JSONValue?) async -> JSONRPCResponse {
        guard let params = params?.objectValue, let name = params["name"]?.stringValue,
              let tool = ToolCatalog.tools.first(where: { $0.name == name }) else {
            return .failure(id: id, code: -32602, message: "tools/callには定義済みのtool名が必要です。")
        }
        let arguments: [String: JSONValue]
        if let value = params["arguments"] {
            guard let object = value.objectValue else {
                return .failure(id: id, code: -32602, message: "argumentsはobjectです。")
            }
            arguments = object
        } else { arguments = [:] }
        var result: JSONValue
        var failed = false
        var message = "完了"
        do {
            try Task.checkCancellation()
            let allowed = Set(tool.inputSchema.objectValue?["properties"]?.objectValue?.keys.map { $0 } ?? [])
            let unknown = Set(arguments.keys).subtracting(allowed)
            guard unknown.isEmpty else { throw AIShellError.invalidArgument("未定義の引数: \(unknown.sorted().joined(separator: ", "))") }
            result = try await invoke(name: name, arguments: arguments)
            if name == "process_run", let object = result.objectValue {
                failed = object["exitCode"]?.intValue != 0 || object["timedOut"]?.boolValue == true
                message = "終了コード: \(object["exitCode"]?.intValue ?? -1)"
            }
        } catch {
            failed = true
            message = error.localizedDescription
            let code = error is CancellationError ? "CANCELLED" : (error as? AIShellError)?.code ?? "OS_ERROR"
            result = .object(["error": .object(["code": .string(code), "message": .string(message)])])
        }
        let target = ["path", "source", "executable", "bundle_identifier"].compactMap { arguments[$0]?.stringValue }.first ?? "."
        do {
            try await log.append(OperationRecord(operation: name, target: target, success: !failed, message: message))
        } catch {
            // 操作の実結果を残し、ログの保存失敗を別項目で返す。
            var object = result.objectValue ?? [:]
            object["logging_error"] = .string(error.localizedDescription)
            result = .object(object)
            failed = true
        }
        do {
            let text = String(decoding: try JSONEncoder.aishell.encode(result), as: UTF8.self)
            return .success(id: id, result: .object([
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                "structuredContent": result, "isError": .bool(failed)
            ]))
        } catch {
            return .failure(id: id, code: -32603, message: error.localizedDescription)
        }
    }

    private func invoke(name: String, arguments a: [String: JSONValue]) async throws -> JSONValue {
        switch name {
        case "files_list":
            return .object(["entries": try .from(files.list(path: string("path", in: a)))])
        case "files_search":
            return try .from(files.search(query: required("query", in: a), path: string("path", in: a), limit: integer("limit", in: a)))
        case "files_read_text":
            return .object(["text": .string(try files.readText(path: required("path", in: a)))])
        case "files_stat":
            return try .from(files.stat(path: required("path", in: a), includeHash: boolean("include_hash", in: a)))
        case "files_tree":
            return try .from(files.tree(path: string("path", in: a), maxDepth: integer("max_depth", in: a), limit: integer("limit", in: a)))
        case "files_create_directory":
            return try .from(files.createDirectory(path: required("path", in: a)))
        case "files_create_text":
            return try .from(files.createTextFile(path: required("path", in: a), content: required("content", in: a, allowEmpty: true)))
        case "files_write_text":
            return try .from(files.writeText(path: required("path", in: a), content: required("content", in: a, allowEmpty: true),
                expectedSHA256: string("expected_sha256", in: a)))
        case "files_replace_text":
            return try .from(files.replaceText(path: required("path", in: a), oldText: required("old_text", in: a),
                newText: required("new_text", in: a, allowEmpty: true), replaceAll: boolean("replace_all", in: a)))
        case "files_copy":
            return try .from(files.copy(source: required("source", in: a), destination: required("destination", in: a)))
        case "files_move":
            return try .from(files.move(source: required("source", in: a), destination: required("destination", in: a)))
        case "files_rename":
            return try .from(files.rename(path: required("path", in: a), newName: required("new_name", in: a)))
        case "files_trash":
            return .object(["trashed_path": .string(try files.trash(path: required("path", in: a)))])
        case "apps_list_running":
            return .object(["applications": try await .from(NativeApplicationService().listRunningApplications())])
        case "apps_list_installed":
            return .object(["applications": try await .from(NativeApplicationService().listInstalledApplications())])
        case "apps_open":
            return try await .from(NativeApplicationService().openApplication(bundleIdentifier: required("bundle_identifier", in: a)))
        case "apps_activate":
            return try await .from(NativeApplicationService().activateApplication(bundleIdentifier: required("bundle_identifier", in: a)))
        case "process_run":
            return try await .from(processes.run(executable: required("executable", in: a),
                arguments: strings("arguments", in: a), workingDirectory: string("working_directory", in: a),
                environment: stringMap("environment", in: a), input: string("stdin", in: a),
                timeoutSeconds: number("timeout_seconds", in: a)))
        default:
            throw AIShellError.invalidArgument("未定義のtoolです: \(name)")
        }
    }

    private func required(_ key: String, in a: [String: JSONValue], allowEmpty: Bool = false) throws -> String {
        guard let value = try string(key, in: a), allowEmpty || !value.isEmpty else {
            throw AIShellError.invalidArgument("\(key)には\(allowEmpty ? "" : "空でない")文字列が必要です。")
        }
        return value
    }

    private func string(_ key: String, in a: [String: JSONValue]) throws -> String? {
        guard let value = a[key] else { return nil }
        guard let string = value.stringValue else { throw AIShellError.invalidArgument("\(key)は文字列です。") }
        return string
    }

    private func boolean(_ key: String, in a: [String: JSONValue]) throws -> Bool {
        guard let value = a[key] else { return false }
        guard let boolean = value.boolValue else { throw AIShellError.invalidArgument("\(key)は真偽値です。") }
        return boolean
    }

    private func integer(_ key: String, in a: [String: JSONValue]) throws -> Int? {
        guard let value = a[key] else { return nil }
        guard let integer = value.intValue, integer > 0 else { throw AIShellError.invalidArgument("\(key)は正の整数です。") }
        return integer
    }

    private func number(_ key: String, in a: [String: JSONValue]) throws -> Double? {
        guard let value = a[key] else { return nil }
        guard let number = value.doubleValue, number.isFinite, number > 0 else { throw AIShellError.invalidArgument("\(key)は正の数値です。") }
        return number
    }

    private func strings(_ key: String, in a: [String: JSONValue]) throws -> [String] {
        guard let value = a[key] else { return [] }
        guard let array = value.arrayValue, array.allSatisfy({ $0.stringValue != nil }) else {
            throw AIShellError.invalidArgument("\(key)は文字列の配列です。")
        }
        return array.compactMap(\.stringValue)
    }

    private func stringMap(_ key: String, in a: [String: JSONValue]) throws -> [String: String] {
        guard let value = a[key] else { return [:] }
        guard let object = value.objectValue, object.values.allSatisfy({ $0.stringValue != nil }) else {
            throw AIShellError.invalidArgument("\(key)は文字列を値に持つobjectです。")
        }
        return object.compactMapValues(\.stringValue)
    }
}
