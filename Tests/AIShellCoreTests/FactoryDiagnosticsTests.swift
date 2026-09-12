import XCTest
@testable import AIShellCore

final class FactoryDiagnosticsTests: XCTestCase {
    func testReportsExactSchemaWithoutLeakingPathsOrActivity() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.base.appendingPathComponent("runtime", isDirectory: true)
        let allowed = fixture.base.appendingPathComponent("secret-project", isDirectory: true)
        let manager = fixture.base.appendingPathComponent("AIShell.app", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: manager, withIntermediateDirectories: true)
        let store = RuntimeStore(baseDirectory: runtime)
        await store.setWorkingDirectoryForTesting(allowed)
        try await store.appendActivity(OperationRecord(
            operation: "files.read", target: allowed.appendingPathComponent("private.txt").path,
            success: true, message: "秘密の操作本文"
        ))

        let diagnostics = await FactoryDiagnosticsService(store: store).diagnose(
            managerApplicationURL: manager, mcpReady: true
        )

        XCTAssertEqual(diagnostics.schemaVersion, "aishell.native_factory_diagnostics.v1")
        XCTAssertEqual(diagnostics.product.identifier, "aishell")
        XCTAssertEqual(diagnostics.product.version, AIShellProduct.version)
        XCTAssertEqual(diagnostics.runtime.configurationState, "not_required")
        XCTAssertEqual(diagnostics.runtime.operationReadiness, "ready")
        XCTAssertEqual(diagnostics.runtime.configuredRootCount, 0)
        XCTAssertTrue(diagnostics.manager.ready)
        XCTAssertTrue(diagnostics.mcp.ready)
        XCTAssertTrue(diagnostics.ready)
        XCTAssertTrue(diagnostics.issues.isEmpty)
        XCTAssertEqual(diagnostics.privacy, .init(
            exposesAllowedRootPaths: false, exposesOperationHistory: false,
            exposesFileContents: false, exposesProcessArguments: false
        ))

        let encoded = try JSONEncoder().encode(diagnostics)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), [
            "schemaVersion", "product", "platform", "runtime", "mcp", "manager", "privacy", "ready", "issues"
        ])
        XCTAssertEqual(Set((object["product"] as? [String: Any] ?? [:]).keys), ["identifier", "version"])
        XCTAssertEqual(Set((object["platform"] as? [String: Any] ?? [:]).keys), [
            "operatingSystem", "architecture", "minimumOperatingSystem", "supported"
        ])
        XCTAssertEqual(Set((object["runtime"] as? [String: Any] ?? [:]).keys), [
            "schemaVersion", "configurationState", "migrationStatus", "operationReadiness", "isPaused",
            "configuredRootCount", "automaticGitWorktreeCount", "effectiveRootCount"
        ])
        XCTAssertEqual(Set((object["mcp"] as? [String: Any] ?? [:]).keys), ["transport", "protocolVersion", "ready"])
        XCTAssertEqual(Set((object["manager"] as? [String: Any] ?? [:]).keys), ["applicationBundleState", "ready"])
        XCTAssertEqual(Set((object["privacy"] as? [String: Any] ?? [:]).keys), [
            "exposesAllowedRootPaths", "exposesOperationHistory", "exposesFileContents", "exposesProcessArguments"
        ])
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains(fixture.base.path))
        XCTAssertFalse(text.contains("secret-project"))
        XCTAssertFalse(text.contains("private.txt"))
        XCTAssertFalse(text.contains("秘密の操作本文"))
    }

    func testLegacyInvalidConfigurationDoesNotBlockOperations() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.base.appendingPathComponent("runtime", isDirectory: true)
        let manager = fixture.base.appendingPathComponent("AIShell.app", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: manager, withIntermediateDirectories: true)
        try Data("{invalid".utf8).write(to: runtime.appendingPathComponent("runtime.json"))

        let diagnostics = await FactoryDiagnosticsService(store: RuntimeStore(baseDirectory: runtime)).diagnose(
            managerApplicationURL: manager, mcpReady: true
        )

        XCTAssertEqual(diagnostics.runtime.configurationState, "not_required")
        XCTAssertEqual(diagnostics.runtime.migrationStatus, "not_required")
        XCTAssertEqual(diagnostics.runtime.operationReadiness, "ready")
        XCTAssertTrue(diagnostics.ready)
        XCTAssertTrue(diagnostics.issues.isEmpty)
    }

    func testMissingLegacyRootDoesNotBlockOperations() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.base.appendingPathComponent("runtime", isDirectory: true)
        let manager = fixture.base.appendingPathComponent("AIShell.app", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: manager, withIntermediateDirectories: true)
        try Data("{\"allowedRootPaths\":[\"/missing\"],\"isPaused\":false}".utf8)
            .write(to: runtime.appendingPathComponent("runtime.json"))

        let diagnostics = await FactoryDiagnosticsService(store: RuntimeStore(baseDirectory: runtime)).diagnose(
            managerApplicationURL: manager, mcpReady: true
        )

        XCTAssertEqual(diagnostics.runtime.configurationState, "not_required")
        XCTAssertEqual(diagnostics.runtime.operationReadiness, "ready")
        XCTAssertTrue(diagnostics.ready)
        XCTAssertTrue(diagnostics.issues.isEmpty)
    }
}
