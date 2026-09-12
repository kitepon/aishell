import Foundation
import XCTest
@testable import AIShellCore

final class WorkspaceCheckpointStoreTests: XCTestCase {
    func testJournalSemanticChangeMustBindToRetainedEventSequence() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let store = WorkspaceCheckpointStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        let change = WorkspaceChange(
            kind: .modified, path: "State.swift", previousPath: nil,
            entry: WorkspaceEntry(
                path: "State.swift", identity: "1:2", isDirectory: false,
                sizeBytes: 1, modifiedAt: nil, sha256: String(repeating: "a", count: 64)
            )
        )
        let checkpoint = makeCheckpoint(
            journalSequence: 2,
            journalEvents: [ObservationJournalEvent(sequence: 1, path: "/fixture/workspace/State.swift", eventID: 42)],
            journalChanges: [WorkspaceCheckpointJournalChange(sequence: 2, change: change)]
        )

        do {
            _ = try await store.save(checkpoint)
            XCTFail("retained eventへ束縛されないsemantic changeを保存しました。")
        } catch {
            guard case AIShellError.checkpointCorrupt = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }
    }

    func testSaveAndWarmLoadRoundTripUsesDeterministicEntryOrder() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let store = WorkspaceCheckpointStore(baseDirectory: fixture.base.appendingPathComponent("runtime"))
        let checkpoint = makeCheckpoint(entries: [
            makeFile(path: "Z.swift", digest: String(repeating: "f", count: 64)),
            makeFile(path: "A.swift", digest: String(repeating: "a", count: 64)),
        ])

        let url = try await store.save(checkpoint)
        let loaded = try await store.load(rootDigest: checkpoint.rootDigest)
        let restored = try XCTUnwrap(loaded)

        XCTAssertEqual(restored.entries.map(\.path), ["A.swift", "Z.swift"])
        XCTAssertEqual(restored.generation, checkpoint.generation)
        XCTAssertEqual(restored.lastEventID, 42)
        XCTAssertEqual(restored.eventStoreUUID, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(restored.payloadSHA256?.count, 64)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testCorruptPayloadFailsClosedAndIsPreserved() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.base.appendingPathComponent("runtime")
        let store = WorkspaceCheckpointStore(baseDirectory: runtime)
        let checkpoint = makeCheckpoint()
        let url = try await store.save(checkpoint)
        var data = try Data(contentsOf: url)
        data[data.index(before: data.endIndex)] = 0x20
        try data.write(to: url)

        do {
            _ = try await store.load(rootDigest: checkpoint.rootDigest)
            XCTFail("corrupt checkpointを復元できました。")
        } catch {
            guard case AIShellError.checkpointCorrupt = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testUnsupportedSchemaIsTypedAndPreserved() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.base.appendingPathComponent("runtime")
        let digest = String(repeating: "a", count: 64)
        let directory = runtime.appendingPathComponent("workspaces/\(digest)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("checkpoint.json")
        let data = Data(#"{"schema":"aishell.workspace-checkpoint.v999"}"#.utf8)
        try data.write(to: url)
        let store = WorkspaceCheckpointStore(baseDirectory: runtime)

        do {
            _ = try await store.load(rootDigest: digest)
            XCTFail("未知schemaを復元できました。")
        } catch {
            XCTAssertEqual(error as? AIShellError, .checkpointUnsupported("aishell.workspace-checkpoint.v999"))
        }
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testQuotaPreflightDoesNotReplacePreviousCheckpoint() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.base.appendingPathComponent("runtime")
        let checkpoint = makeCheckpoint()
        let normalStore = WorkspaceCheckpointStore(baseDirectory: runtime)
        let url = try await normalStore.save(checkpoint)
        let original = try Data(contentsOf: url)
        let limitedStore = WorkspaceCheckpointStore(
            baseDirectory: runtime,
            quota: WorkspaceCheckpointQuota(
                maximumRoots: 8,
                maximumEntriesPerRoot: 500_000,
                maximumBytesPerRoot: 1,
                maximumTotalBytes: 512 * 1_024 * 1_024
            )
        )

        do {
            _ = try await limitedStore.save(makeCheckpoint(generation: "replacement"))
            XCTFail("quota超過checkpointを保存できました。")
        } catch {
            guard case AIShellError.checkpointQuotaExceeded = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
        let restored = try await normalStore.load(rootDigest: checkpoint.rootDigest)
        XCTAssertEqual(restored?.generation, checkpoint.generation)
    }

    func testCommitFailureDoesNotReplacePreviousCheckpoint() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.base.appendingPathComponent("runtime")
        let checkpoint = makeCheckpoint()
        let normalStore = WorkspaceCheckpointStore(baseDirectory: runtime)
        let url = try await normalStore.save(checkpoint)
        let original = try Data(contentsOf: url)
        let failingStore = WorkspaceCheckpointStore(baseDirectory: runtime) {
            throw AIShellError.checkpointWriteFailed("injected before atomic replace")
        }

        do {
            _ = try await failingStore.save(makeCheckpoint(generation: "replacement"))
            XCTFail("commit失敗を成功扱いしました。")
        } catch {
            guard case AIShellError.checkpointWriteFailed = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
        let restored = try await normalStore.load(rootDigest: checkpoint.rootDigest)
        XCTAssertEqual(restored?.generation, checkpoint.generation)
    }

    func testRootQuotaEvictsOnlyInactiveLeastRecentlyUsedCheckpoint() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let store = WorkspaceCheckpointStore(
            baseDirectory: fixture.base.appendingPathComponent("runtime"),
            quota: WorkspaceCheckpointQuota(
                maximumRoots: 1,
                maximumEntriesPerRoot: 500_000,
                maximumBytesPerRoot: 128 * 1_024 * 1_024,
                maximumTotalBytes: 512 * 1_024 * 1_024
            )
        )
        let first = makeCheckpoint(rootDigest: String(repeating: "a", count: 64))
        let second = makeCheckpoint(rootDigest: String(repeating: "b", count: 64))
        _ = try await store.save(first)

        _ = try await store.save(second)

        let evicted = try await store.load(rootDigest: first.rootDigest)
        let retained = try await store.load(rootDigest: second.rootDigest)
        XCTAssertNil(evicted)
        XCTAssertEqual(retained?.rootDigest, second.rootDigest)
    }

    func testRootQuotaDoesNotEvictActiveCheckpoint() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let store = WorkspaceCheckpointStore(
            baseDirectory: fixture.base.appendingPathComponent("runtime"),
            quota: WorkspaceCheckpointQuota(
                maximumRoots: 1,
                maximumEntriesPerRoot: 500_000,
                maximumBytesPerRoot: 128 * 1_024 * 1_024,
                maximumTotalBytes: 512 * 1_024 * 1_024
            )
        )
        let first = makeCheckpoint(rootDigest: String(repeating: "a", count: 64))
        let second = makeCheckpoint(rootDigest: String(repeating: "b", count: 64))
        _ = try await store.save(first)

        do {
            _ = try await store.save(second, activeRootDigests: [first.rootDigest])
            XCTFail("active checkpointをevictしてquota超過保存を成功扱いしました。")
        } catch {
            guard case AIShellError.checkpointQuotaExceeded = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }
        let retained = try await store.load(rootDigest: first.rootDigest)
        let absent = try await store.load(rootDigest: second.rootDigest)
        XCTAssertEqual(retained?.rootDigest, first.rootDigest)
        XCTAssertNil(absent)
    }

    func testCommitFailureRollsBackStagedQuotaEviction() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.base.appendingPathComponent("runtime")
        let quota = WorkspaceCheckpointQuota(
            maximumRoots: 1,
            maximumEntriesPerRoot: 500_000,
            maximumBytesPerRoot: 128 * 1_024 * 1_024,
            maximumTotalBytes: 512 * 1_024 * 1_024
        )
        let first = makeCheckpoint(rootDigest: String(repeating: "a", count: 64))
        let second = makeCheckpoint(rootDigest: String(repeating: "b", count: 64))
        let normalStore = WorkspaceCheckpointStore(baseDirectory: runtime, quota: quota)
        _ = try await normalStore.save(first)
        let failingStore = WorkspaceCheckpointStore(baseDirectory: runtime, quota: quota) {
            throw AIShellError.checkpointWriteFailed("injected after eviction staging")
        }

        do {
            _ = try await failingStore.save(second)
            XCTFail("commit失敗後にevictionだけを残しました。")
        } catch {
            guard case AIShellError.checkpointWriteFailed = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        }
        let restored = try await normalStore.load(rootDigest: first.rootDigest)
        let absent = try await normalStore.load(rootDigest: second.rootDigest)
        XCTAssertNotNil(restored)
        XCTAssertNil(absent)
        let workspaceDirectory = runtime.appendingPathComponent("workspaces", isDirectory: true)
        let retainedDirectories = try FileManager.default.contentsOfDirectory(
            at: workspaceDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).map(\.lastPathComponent)
        XCTAssertEqual(retainedDirectories, [first.rootDigest])
    }

    func testSafetyNetFixtureKeepsAllRequiredFailClosedCases() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "workspace-checkpoint-cases.v1",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
        let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 13)
        let stopped = cases.filter {
            ($0["expected"] as? [String: Any])?["decision"] as? String == "stop"
        }
        XCTAssertEqual(stopped.count, 8)
        XCTAssertTrue(stopped.allSatisfy {
            let expected = $0["expected"] as? [String: Any]
            return expected?["typed_error"] as? String != nil
                && expected?["reuse_entries"] as? Bool == false
        })
    }

    private func makeCheckpoint(
        generation: String = "generation-1",
        rootDigest: String = String(repeating: "a", count: 64),
        journalSequence: UInt64 = 0,
        journalEvents: [ObservationJournalEvent] = [],
        journalChanges: [WorkspaceCheckpointJournalChange]? = nil,
        entries: [WorkspaceCheckpointEntry] = []
    ) -> WorkspaceCheckpoint {
        WorkspaceCheckpoint(
            rootPath: "/fixture/workspace",
            rootIdentity: "1:2",
            rootDigest: rootDigest,
            exclusionDigest: String(repeating: "b", count: 64),
            eventStoreUUID: "11111111-1111-1111-1111-111111111111",
            generation: generation,
            lastEventID: 42,
            journalSequence: journalSequence,
            journalEvents: journalEvents,
            journalChanges: journalChanges,
            entries: entries,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastAccessedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    private func makeFile(path: String, digest: String) -> WorkspaceCheckpointEntry {
        WorkspaceCheckpointEntry(
            path: path,
            identity: "1:\(path.hashValue)",
            kind: .file,
            sizeBytes: 12,
            modifiedAtNanoseconds: 1_700_000_000_000_000_000,
            sha256: digest,
            hashState: .hashed
        )
    }
}
