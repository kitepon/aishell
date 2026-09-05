import XCTest
@testable import AIShellCore

final class RuntimeStoreTests: XCTestCase {
    func testPersistsConfigurationAndNewestActivityFirst() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.base.appendingPathComponent("runtime", isDirectory: true)
        let allowed = fixture.base.appendingPathComponent("allowed", isDirectory: true)
        let second = fixture.base.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let store = RuntimeStore(baseDirectory: runtime)

        await store.setWorkingDirectoryForTesting(allowed)
        try await store.setPaused(true)
        try await store.appendActivity(OperationRecord(
            operation: "first",
            target: "a",
            success: true,
            message: "完了"
        ))
        try await store.appendActivity(OperationRecord(
            operation: "second",
            target: "b",
            success: false,
            message: "失敗"
        ))

        let configuration = try await store.loadConfiguration()
        XCTAssertTrue(configuration.isPaused)

        let activities = try await store.loadRecentActivities(limit: 10)
        XCTAssertEqual(activities.map(\.operation), ["second", "first"])
    }

    func testIgnoresLegacyRootsAndDropsThemOnSave() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let store = RuntimeStore(baseDirectory: fixture.base)
        for legacy in [
            "{\"allowedRootPath\":\"/missing\",\"isPaused\":true}",
            "{\"allowedRootPaths\":[\"/missing\"],\"isPaused\":true}"
        ] {
            try Data(legacy.utf8).write(to: store.configurationURL)
            let configuration = try await store.loadConfiguration()
            XCTAssertTrue(configuration.isPaused)
            try await store.saveConfiguration(configuration)
            let saved = try String(contentsOf: store.configurationURL, encoding: .utf8)
            XCTAssertFalse(saved.contains("allowedRoot"))
        }
    }
}
