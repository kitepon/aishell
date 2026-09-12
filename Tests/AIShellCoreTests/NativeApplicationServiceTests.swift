import XCTest
@testable import AIShellCore

final class NativeApplicationServiceTests: XCTestCase {
    @MainActor
    func testApplicationQueriesAndMissingTargets() async throws {
        let service = NativeApplicationService()
        let running = try await service.listRunningApplications()
        XCTAssertTrue(running.allSatisfy { $0.processIdentifier > 0 })
        let installed = try await service.listInstalledApplications()
        XCTAssertTrue(installed.allSatisfy { $0.path.hasSuffix(".app") })
        let missing = "dev.aishell.fixture.\(UUID().uuidString)"
        do { _ = try await service.openApplication(bundleIdentifier: missing); XCTFail("存在しないアプリを起動しました。") }
        catch { XCTAssertEqual(error as? AIShellError, .applicationNotFound(missing)) }
        do { _ = try await service.activateApplication(bundleIdentifier: missing); XCTFail("存在しないアプリを前面化しました。") }
        catch { XCTAssertEqual(error as? AIShellError, .applicationNotFound(missing)) }
    }
}
