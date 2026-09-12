import CryptoKit
import Foundation
import XCTest
@testable import AIShellCore

final class DiagnosticAdapterServiceTests: XCTestCase {
    func testXCResultAndSARIFBindDiagnosticsToCurrentFileSHA() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let xcresult = try JSONSerialization.data(withJSONObject: [
            "issues": [[
                "message": ["_value": "type mismatch"],
                "issueType": ["_value": "Error"],
                "documentLocationInCreatingWorkspace": [
                    "_value": "file://\(fixture.file.path)?StartingLineNumber=3&StartingColumnNumber=7"
                ]
            ]]
        ])
        let xcode = try DiagnosticAdapterService().parse(format: .xcresult, data: xcresult, root: fixture.root)
        XCTAssertEqual(xcode.diagnostics.first?.path, "Source.swift")
        XCTAssertEqual(xcode.diagnostics.first?.line, 3)
        XCTAssertEqual(xcode.diagnostics.first?.contentSHA256, fixture.sha)

        let sarif = try JSONSerialization.data(withJSONObject: ["runs": [["results": [[
            "level": "warning", "ruleId": "R1", "message": ["text": "unsafe call"],
            "locations": [["physicalLocation": [
                "artifactLocation": ["uri": "Source.swift"],
                "region": ["startLine": 4, "startColumn": 2]
            ]]]
        ]]]]])
        let result = try DiagnosticAdapterService().parse(format: .sarif, data: sarif, root: fixture.root)
        XCTAssertEqual(result.diagnostics.first?.severity, .warning)
        XCTAssertEqual(result.diagnostics.first?.ruleID, "R1")
        XCTAssertEqual(result.diagnostics.first?.contentSHA256, fixture.sha)
    }

    func testCargoAndBazelJSONLinesUseTheSameSchemaAndMalformedFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let cargo = """
        {"reason":"compiler-message","message":{"message":"borrow moved","level":"error","code":{"code":"E0382"},"spans":[{"file_name":"Source.swift","line_start":2,"column_start":5,"is_primary":true}]}}
        """
        let cargoResult = try DiagnosticAdapterService().parse(
            format: .cargoJSON, data: Data(cargo.utf8), root: fixture.root
        )
        XCTAssertEqual(cargoResult.schemaVersion, "aishell.diagnostics.v1")
        XCTAssertEqual(cargoResult.diagnostics.first?.ruleID, "E0382")
        XCTAssertEqual(cargoResult.diagnostics.first?.contentSHA256, fixture.sha)

        let bazel = "{" + "\"actionCompleted\":{\"failureDetail\":{\"message\":\"compile failed\"}}}"
        let bazelResult = try DiagnosticAdapterService().parse(
            format: .bazelBEP, data: Data(bazel.utf8), root: fixture.root
        )
        XCTAssertEqual(bazelResult.diagnostics.first?.message, "compile failed")
        XCTAssertThrowsError(try DiagnosticAdapterService().parse(
            format: .sarif, data: Data("{}".utf8), root: fixture.root
        )) { XCTAssertEqual($0 as? DiagnosticAdapterError, .malformed(.sarif)) }
    }
}

private struct Fixture {
    let root: URL
    let file: URL
    let sha: String

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        file = root.appendingPathComponent("Source.swift")
        let data = Data("let value = 1\n".utf8)
        try data.write(to: file)
        sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
