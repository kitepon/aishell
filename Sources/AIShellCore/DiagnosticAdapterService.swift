import CryptoKit
import Foundation

public enum DiagnosticFormat: String, Codable, Sendable {
    case xcresult
    case sarif
    case cargoJSON = "cargo_json"
    case bazelBEP = "bazel_bep"
}

public enum DiagnosticSeverity: String, Codable, Sendable {
    case error, warning, note
}

public struct StructuredDiagnostic: Codable, Equatable, Sendable {
    public let adapter: DiagnosticFormat
    public let severity: DiagnosticSeverity
    public let message: String
    public let ruleID: String?
    public let path: String?
    public let line: Int?
    public let column: Int?
    public let contentSHA256: String?

    public init(adapter: DiagnosticFormat, severity: DiagnosticSeverity, message: String,
                ruleID: String? = nil, path: String? = nil, line: Int? = nil,
                column: Int? = nil, contentSHA256: String? = nil) {
        self.adapter = adapter; self.severity = severity; self.message = message
        self.ruleID = ruleID; self.path = path; self.line = line; self.column = column
        self.contentSHA256 = contentSHA256
    }
}

public struct DiagnosticAdapterResult: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let format: DiagnosticFormat
    public let diagnostics: [StructuredDiagnostic]

    public init(format: DiagnosticFormat, diagnostics: [StructuredDiagnostic]) {
        schemaVersion = "aishell.diagnostics.v1"
        self.format = format
        self.diagnostics = diagnostics
    }
}

public enum DiagnosticAdapterError: Error, Equatable, LocalizedError {
    case malformed(DiagnosticFormat)

    public var errorDescription: String? {
        switch self { case let .malformed(format): "DIAGNOSTIC_PARSE_FAILED: \(format.rawValue)" }
    }
}

public struct DiagnosticAdapterService: Sendable {
    public init() {}

    public func parse(format: DiagnosticFormat, data: Data, root: URL) throws -> DiagnosticAdapterResult {
        let drafts: [Draft]
        do {
            switch format {
            case .sarif: drafts = try parseSARIF(data)
            case .cargoJSON: drafts = try parseCargo(data)
            case .xcresult: drafts = try parseXCResult(data)
            case .bazelBEP: drafts = try parseBazel(data)
            }
        } catch is DiagnosticAdapterError {
            throw DiagnosticAdapterError.malformed(format)
        } catch {
            throw DiagnosticAdapterError.malformed(format)
        }
        guard !drafts.isEmpty else { throw DiagnosticAdapterError.malformed(format) }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        return DiagnosticAdapterResult(format: format, diagnostics: drafts.map { draft in
            let bound = bind(draft.path, root: canonicalRoot)
            return StructuredDiagnostic(adapter: format, severity: draft.severity,
                message: draft.message, ruleID: draft.ruleID, path: bound?.path ?? draft.path,
                line: draft.line, column: draft.column, contentSHA256: bound?.sha256)
        })
    }

    private struct Draft {
        let severity: DiagnosticSeverity
        let message: String
        let ruleID: String?
        let path: String?
        let line: Int?
        let column: Int?
    }

    private func parseSARIF(_ data: Data) throws -> [Draft] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runs = root["runs"] as? [[String: Any]] else { throw DiagnosticAdapterError.malformed(.sarif) }
        return runs.flatMap { run in
            (run["results"] as? [[String: Any]] ?? []).compactMap { result in
                guard let message = (result["message"] as? [String: Any])?["text"] as? String else { return nil }
                let location = ((result["locations"] as? [[String: Any]])?.first?["physicalLocation"] as? [String: Any])
                let artifact = location?["artifactLocation"] as? [String: Any]
                let region = location?["region"] as? [String: Any]
                return Draft(severity: severity(result["level"] as? String), message: message,
                    ruleID: result["ruleId"] as? String, path: artifact?["uri"] as? String,
                    line: region?["startLine"] as? Int, column: region?["startColumn"] as? Int)
            }
        }
    }

    private func parseCargo(_ data: Data) throws -> [Draft] {
        guard let text = String(data: data, encoding: .utf8) else { throw DiagnosticAdapterError.malformed(.cargoJSON) }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["reason"] as? String == "compiler-message",
                  let message = object["message"] as? [String: Any],
                  let rendered = message["message"] as? String else { return nil }
            let span = (message["spans"] as? [[String: Any]])?.first(where: { $0["is_primary"] as? Bool == true })
            let code = (message["code"] as? [String: Any])?["code"] as? String
            return Draft(severity: severity(message["level"] as? String), message: rendered,
                ruleID: code, path: span?["file_name"] as? String,
                line: span?["line_start"] as? Int, column: span?["column_start"] as? Int)
        }
    }

    private func parseXCResult(_ data: Data) throws -> [Draft] {
        let root = try JSONSerialization.jsonObject(with: data)
        var results: [Draft] = []
        walk(root) { object in
            guard let message = stringValue(object["message"]) else { return }
            let location = stringValue(object["documentLocationInCreatingWorkspace"])
                ?? stringValue(object["url"])
            let parsed = location.flatMap(parseLocation)
            results.append(Draft(severity: severity(stringValue(object["issueType"])
                ?? stringValue(object["severity"])), message: message,
                ruleID: stringValue(object["issueType"]), path: parsed?.path,
                line: parsed?.line, column: parsed?.column))
        }
        return results
    }

    private func parseBazel(_ data: Data) throws -> [Draft] {
        guard let text = String(data: data, encoding: .utf8) else { throw DiagnosticAdapterError.malformed(.bazelBEP) }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            if let aborted = object["aborted"] as? [String: Any], let message = aborted["description"] as? String {
                return Draft(severity: .error, message: message, ruleID: "aborted", path: nil, line: nil, column: nil)
            }
            guard let action = object["actionCompleted"] as? [String: Any],
                  let failure = action["failureDetail"] as? [String: Any],
                  let message = failure["message"] as? String else { return nil }
            return Draft(severity: .error, message: message, ruleID: "actionCompleted", path: nil, line: nil, column: nil)
        }
    }

    private func walk(_ value: Any, visit: ([String: Any]) -> Void) {
        if let object = value as? [String: Any] {
            visit(object)
            for child in object.values { walk(child, visit: visit) }
        } else if let array = value as? [Any] {
            for child in array { walk(child, visit: visit) }
        }
    }

    private func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let object = value as? [String: Any] { return object["_value"] as? String }
        return nil
    }

    private func severity(_ value: String?) -> DiagnosticSeverity {
        switch value?.lowercased() {
        case "warning": .warning
        case "note", "remark", "info": .note
        default: .error
        }
    }

    private func parseLocation(_ value: String) -> (path: String, line: Int?, column: Int?)? {
        guard let components = URLComponents(string: value) else { return nil }
        let urlPath = components.url?.path ?? value
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        return (urlPath, query["StartingLineNumber"].flatMap { $0 }.flatMap(Int.init),
            query["StartingColumnNumber"].flatMap { $0 }.flatMap(Int.init))
    }

    private func bind(_ path: String?, root: URL) -> (path: String, sha256: String)? {
        guard let path else { return nil }
        let candidate = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        let canonical = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical.path == root.path || canonical.path.hasPrefix(root.path + "/"),
              let data = try? Data(contentsOf: canonical) else { return nil }
        return (String(canonical.path.dropFirst(root.path.count + 1)),
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}
