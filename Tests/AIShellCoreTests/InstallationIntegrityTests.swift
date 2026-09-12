import XCTest
@testable import AIShellCore

final class InstallationIntegrityTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("aishell-integrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testUnchangedExecutableIsIntact() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("AIShell")
        try Data("build-a".utf8).write(to: executable)

        let integrity = InstallationIntegrity(executableURL: executable)

        XCTAssertEqual(integrity.currentStatus(), .intact)
        XCTAssertFalse(InstallationIntegrity.Status.intact.requiresRestart)
    }

    func testRemovedExecutableIsDetectedAsRemovedAndCannotRelaunchInPlace() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("AIShell")
        try Data("build-a".utf8).write(to: executable)
        let integrity = InstallationIntegrity(executableURL: executable)

        // npm global upgradeが旧packageを退避してから削除する経路の再現。
        try FileManager.default.removeItem(at: executable)

        XCTAssertEqual(integrity.currentStatus(), .executableRemoved)
        XCTAssertTrue(integrity.currentStatus().requiresRestart)
        XCTAssertFalse(integrity.currentStatus().canRelaunchInPlace)
    }

    func testReplacedExecutableAtSamePathIsDetectedAsReplaced() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("AIShell")
        try Data("build-a".utf8).write(to: executable)
        let integrity = InstallationIntegrity(executableURL: executable)

        // 同じpathへ別buildが入るin-place置換の再現。pathの存在確認だけでは検知できない。
        try FileManager.default.removeItem(at: executable)
        try Data("build-b-with-different-length".utf8).write(to: executable)

        XCTAssertEqual(integrity.currentStatus(), .executableReplaced)
        XCTAssertTrue(integrity.currentStatus().requiresRestart)
        XCTAssertTrue(integrity.currentStatus().canRelaunchInPlace)
    }

    func testSameSizeOverwriteIsStillDetectedThroughIdentity() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("AIShell")
        try Data("build-a".utf8).write(to: executable)
        let integrity = InstallationIntegrity(executableURL: executable)

        // 長さの等しい別buildで上書きしても、inodeまたはmtimeの差で検知できることを確かめる。
        try Data("build-b".utf8).write(to: executable)

        XCTAssertEqual(integrity.currentStatus(), .executableReplaced)
    }

    func testMissingExecutableAtLaunchReportsUnknownRatherThanIntact() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let absent = directory.appendingPathComponent("AIShell")

        let integrity = InstallationIntegrity(executableURL: absent)

        // 判定不能を「異常なし」へ丸めない。
        XCTAssertEqual(integrity.currentStatus(), .unknown)
        XCTAssertFalse(integrity.currentStatus().requiresRestart)
    }
}
