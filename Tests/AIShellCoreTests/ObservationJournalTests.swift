import CoreServices
import XCTest
@testable import AIShellCore

final class ObservationJournalTests: XCTestCase {
    func testObserverRejectsCheckpointWatermarkNewerThanCurrentEventDatabase() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }

        XCTAssertThrowsError(
            try FSEventsObserver(path: fixture.base.path, sinceEventID: UInt64.max)
        ) { error in
            guard case AIShellError.rescanRequired = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }
    }

    func testObserverUsesPerDeviceStreamForPersistentEventIDs() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        var info = stat()
        XCTAssertEqual(lstat(fixture.base.path, &info), 0)

        let observer = try FSEventsObserver(path: fixture.base.path)

        XCTAssertEqual(observer.watchedDeviceForTests(), info.st_dev)
    }

    func testObserverInitialWatermarkUsesDeviceHistoryBoundary() throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        var info = stat()
        XCTAssertEqual(lstat(fixture.base.path, &info), 0)
        let before = FSEventsGetLastEventIdForDeviceBeforeTime(
            info.st_dev,
            Date().timeIntervalSince1970
        )

        let observer = try FSEventsObserver(path: fixture.base.path)
        let after = FSEventsGetLastEventIdForDeviceBeforeTime(
            info.st_dev,
            Date().timeIntervalSince1970
        )
        let watermark = try XCTUnwrap(observer.initialWatermarkForTests())

        XCTAssertGreaterThanOrEqual(watermark, before)
        XCTAssertLessThanOrEqual(watermark, after)
    }

    func testRecordsEventIDAndRestoresCheckpointWithoutChangingGeneration() throws {
        var journal = ObservationJournal(generation: "generation-a", retentionLimit: 10)
        journal.record([
            event("/root/A.swift", id: 40),
            event("/root/B.swift", id: 42),
        ])

        let restored = try ObservationJournal(checkpoint: journal.checkpoint(), retentionLimit: 10)

        XCTAssertEqual(restored.generation, "generation-a")
        XCTAssertEqual(restored.sequence, 2)
        XCTAssertEqual(restored.lastEventID, 42)
        XCTAssertEqual(try restored.changes(after: 0).map(\.path), ["/root/A.swift", "/root/B.swift"])
    }

    func testRetentionExpiresOldSequenceWithoutReturningPartialHistory() throws {
        var journal = ObservationJournal(generation: "generation-a", retentionLimit: 2)
        journal.record([event("A", id: 1), event("B", id: 2), event("C", id: 3)])

        do {
            _ = try journal.changes(after: 0)
            XCTFail("retention外cursorへ部分履歴を返しました。")
        } catch {
            guard case AIShellError.cursorExpired = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }
        XCTAssertEqual(try journal.changes(after: 1).map(\.path), ["B", "C"])
    }

    func testUnsafeFlagRequiresRescanEvenWhenPathIsExcluded() {
        var journal = ObservationJournal(generation: "generation-a")
        journal.record([
            event(
                "/root/.build/cache",
                id: 42,
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
            ),
        ]) { _ in false }

        XCTAssertEqual(journal.sequence, 0)
        XCTAssertEqual(journal.lastEventID, 42)
        XCTAssertThrowsError(try journal.changes(after: 0)) { error in
            guard case AIShellError.rescanRequired = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }
    }

    func testEventIDWatermarkDoesNotRegressOnLowerDeliveredID() throws {
        var journal = ObservationJournal(generation: "generation-a")
        journal.record([event("A", id: 50), event("B", id: 49)])

        XCTAssertEqual(journal.lastEventID, 50)
        XCTAssertEqual(try journal.changes(after: 0).count, 2)
    }

    func testExcludedNormalEventDoesNotAdvanceSequenceButKeepsEventWatermark() throws {
        var journal = ObservationJournal(generation: "generation-a")
        journal.record([event("ignored", id: 10)]) { _ in false }

        XCTAssertEqual(journal.sequence, 0)
        XCTAssertEqual(journal.lastEventID, 10)
        XCTAssertTrue(try journal.changes(after: 0).isEmpty)
    }

    func testCorruptCheckpointIsRejectedAndNewGenerationClearsHistory() throws {
        let corrupt = ObservationJournalCheckpoint(
            generation: "generation-a",
            sequence: 1,
            lastEventID: 1,
            events: [ObservationJournalEvent(sequence: 2, path: "A", eventID: 1)],
            rescanReason: nil
        )
        XCTAssertThrowsError(try ObservationJournal(checkpoint: corrupt)) { error in
            guard case AIShellError.checkpointCorrupt = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }

        var journal = ObservationJournal(generation: "generation-a")
        journal.record([event("A", id: 1)])
        journal.startNewGeneration("generation-b")
        XCTAssertEqual(journal.generation, "generation-b")
        XCTAssertEqual(journal.sequence, 0)
        XCTAssertNil(journal.lastEventID)
        XCTAssertTrue(journal.events.isEmpty)
    }

    private func event(
        _ path: String,
        id: UInt64,
        flags: FSEventStreamEventFlags = 0
    ) -> ObservedFileEvent {
        ObservedFileEvent(path: path, eventID: id, flags: flags)
    }
}
