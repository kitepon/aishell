import XCTest
@testable import AIShellCore

final class UsageLogTests: XCTestCase, @unchecked Sendable {
    func testConcurrentWritersAppendCompleteUsageRecords() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let first = UsageLog(directory: fixture.base)
        let second = UsageLog(directory: fixture.base)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    try await (index.isMultiple(of: 2) ? first : second).append(
                        OperationRecord(operation: "files_read_text", target: "file-\(index)", success: true, message: "完了"))
                }
            }
            try await group.waitForAll()
        }
        let data = try String(contentsOf: fixture.base.appendingPathComponent("activity.jsonl"), encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try data.split(separator: "\n").map { try decoder.decode(OperationRecord.self, from: Data($0.utf8)) }
        XCTAssertEqual(records.count, 40)
        XCTAssertEqual(Set(records.map(\.target)).count, 40)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.base.path)), ["activity.jsonl"])
    }
}
