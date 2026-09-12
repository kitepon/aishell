import XCTest
@testable import AIShellCore

@MainActor
final class NativeApplicationServiceTests: XCTestCase {
    func testOpenRejectsUnknownApplication() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let service = NativeApplicationService(store: RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime")))
        do {
            _ = try await service.openApplication(bundleIdentifier: "dev.kitepon.aishell.test.missing")
            XCTFail("存在しないアプリの起動は失敗する必要があります。")
        } catch {
            XCTAssertTrue(error is AIShellError)
        }
    }

    func testListsRunningApplicationsThroughNSWorkspace() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let store = RuntimeStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        let service = NativeApplicationService(store: store)

        let applications = try await service.listRunningApplications()

        XCTAssertFalse(applications.isEmpty)
        XCTAssertTrue(applications.allSatisfy { $0.processIdentifier > 0 })
    }
}
