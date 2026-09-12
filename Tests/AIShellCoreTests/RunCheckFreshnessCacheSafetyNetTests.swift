import CryptoKit
import XCTest
@testable import AIShellCore

/// ACE-031 の固定fixture。ACE-034a では `FreshnessCacheSafetyNetOperator` を production adapter に
/// 差し替え、同じ request / oracle で runtime 統合を検証する。
final class RunCheckFreshnessCacheSafetyNetTests: XCTestCase {
    func testEveryBindingMutationHasNoFalseFreshReuseAndReportsItsReason() throws {
        for mutation in BindingMutation.allCases {
            let cacheOperator = ContractFixtureOperator()
            let initial = try cacheOperator.execute(request(.prefer, checks: [check(binding: "baseline")]))
            let changed = try cacheOperator.execute(request(.prefer, checks: [check(binding: mutation.binding)]))

            XCTAssertNil(initial.typedError, "\(mutation)")
            XCTAssertNil(changed.typedError, "\(mutation)")
            XCTAssertEqual(changed.processesStarted, 1, "\(mutation): false-fresh なら process を起動します")
            XCTAssertEqual(changed.publications, 1, "\(mutation): 新しい immutable entry を publish します")
            XCTAssertEqual(changed.results.count, 1, "\(mutation)")
            XCTAssertNotEqual(changed.results[0].sourceRunID, initial.results[0].sourceRunID, "\(mutation)")
            XCTAssertNotEqual(changed.results[0].stdoutArtifactSHA256, initial.results[0].stdoutArtifactSHA256, "\(mutation)")
            XCTAssertEqual(changed.invalidationReasons, [mutation.rawValue], "\(mutation)")
        }
    }

    func testPassedAndNormalExitFailedHitsReuseOriginalArtifactWithoutStartingProcess() throws {
        let cacheOperator = ContractFixtureOperator()
        let initial = try cacheOperator.execute(request(.refresh, checks: [
            check(id: "passed", binding: "baseline", terminal: .passed),
            check(id: "failed", binding: "baseline", terminal: .failed),
        ]))
        let hit = try cacheOperator.execute(request(.prefer, checks: [
            check(id: "passed", binding: "baseline", terminal: .passed),
            check(id: "failed", binding: "baseline", terminal: .failed),
        ]))

        XCTAssertNil(hit.typedError)
        XCTAssertEqual(hit.processesStarted, 0)
        XCTAssertEqual(hit.publications, 0)
        XCTAssertEqual(hit.results.map(\.terminal), [.passed, .failed])
        XCTAssertEqual(hit.results.map(\.sourceRunID), initial.results.map(\.sourceRunID))
        XCTAssertEqual(hit.results.map(\.stdoutArtifactSHA256), initial.results.map(\.stdoutArtifactSHA256))
    }

    func testObservedCorruptionFailsClosedWithoutProcessOrPublication() throws {
        let cacheOperator = ContractFixtureOperator()
        _ = try cacheOperator.execute(request(.refresh, checks: [check(binding: "baseline")]))
        cacheOperator.corruptObservedMaterial = true

        let result = try cacheOperator.execute(request(.prefer, checks: [check(binding: "baseline")]))

        XCTAssertEqual(result.typedError, .cacheCorrupt)
        XCTAssertEqual(result.processesStarted, 0)
        XCTAssertEqual(result.publications, 0)
        XCTAssertTrue(result.results.isEmpty)
    }

    func testArtifactIncompleteEntryNeverBecomesHit() throws {
        let cacheOperator = ContractFixtureOperator()
        let initial = try cacheOperator.execute(request(.refresh, checks: [check(binding: "baseline")]))
        cacheOperator.defect = .artifactIncomplete

        let prefer = try cacheOperator.execute(request(.prefer, checks: [check(binding: "baseline")]))
        XCTAssertNil(prefer.typedError)
        XCTAssertEqual(prefer.processesStarted, 1)
        XCTAssertEqual(prefer.publications, 1)
        XCTAssertNotEqual(prefer.results[0].stdoutArtifactSHA256, initial.results[0].stdoutArtifactSHA256)

        cacheOperator.defect = .artifactIncomplete
        let only = try cacheOperator.execute(request(.only, checks: [check(binding: "baseline")]))
        XCTAssertEqual(only.typedError, .cacheMiss)
        XCTAssertEqual(only.processesStarted, 0)
        XCTAssertEqual(only.publications, 0)
        XCTAssertTrue(only.results.isEmpty)
    }

    func testQuotaAndPublicationFailureDoNotPretendInspectionWasCached() throws {
        for failure in [PublicationFailure.quota, .store] {
            let cacheOperator = ContractFixtureOperator()
            cacheOperator.publicationFailure = failure

            let failedPublication = try cacheOperator.execute(request(.refresh, checks: [check(binding: "baseline")]))
            XCTAssertEqual(failedPublication.typedError, failure.typedError)
            XCTAssertEqual(failedPublication.processesStarted, 1)
            XCTAssertEqual(failedPublication.publications, 0)
            XCTAssertEqual(failedPublication.results.count, 1)
            XCTAssertEqual(failedPublication.results[0].stdoutArtifactSHA256.count, 64)

            cacheOperator.publicationFailure = nil
            let retry = try cacheOperator.execute(request(.only, checks: [check(binding: "baseline")]))
            XCTAssertEqual(retry.typedError, .cacheMiss, "\(failure): publication失敗をhitへ偽装してはいけません")
            XCTAssertEqual(retry.processesStarted, 0)
            XCTAssertEqual(retry.publications, 0)
            XCTAssertTrue(retry.results.isEmpty)
        }
    }

    func testFocusedPartialHitIsAllOrNoneForPreferAndOnly() throws {
        let cacheOperator = ContractFixtureOperator()
        let first = check(id: "first", binding: "baseline")
        let second = check(id: "second", binding: "baseline")
        _ = try cacheOperator.execute(request(.refresh, checks: [first]))

        let prefer = try cacheOperator.execute(request(.prefer, checks: [first, second]))
        XCTAssertNil(prefer.typedError)
        XCTAssertEqual(prefer.processesStarted, 2)
        XCTAssertEqual(prefer.publications, 2)
        XCTAssertEqual(prefer.results.map(\.checkID), ["first", "second"])
        XCTAssertNotEqual(prefer.results[0].sourceRunID, "run-1", "partial hit を成功resultへ混ぜません")
        XCTAssertTrue(prefer.results.allSatisfy { $0.stdoutArtifactSHA256.count == 64 })

        let onlyOperator = ContractFixtureOperator()
        _ = try onlyOperator.execute(request(.refresh, checks: [first]))
        let only = try onlyOperator.execute(request(.only, checks: [first, second]))
        XCTAssertEqual(only.typedError, .cacheMiss)
        XCTAssertEqual(only.processesStarted, 0)
        XCTAssertEqual(only.publications, 0)
        XCTAssertTrue(only.results.isEmpty)
    }

    func testOffDoesNotObserveCorruptionOrCacheMaterialAndExecutesEveryStep() throws {
        let cacheOperator = ContractFixtureOperator()
        cacheOperator.corruptObservedMaterial = true
        let result = try cacheOperator.execute(request(.off, checks: [
            check(id: "first", binding: "baseline"),
            check(id: "second", binding: "baseline"),
        ]))

        XCTAssertNil(result.typedError)
        XCTAssertEqual(result.processesStarted, 2)
        XCTAssertEqual(result.publications, 0)
        XCTAssertEqual(result.cacheMaterialObservations, 0)
        XCTAssertEqual(result.results.map(\.stdoutArtifactSHA256).map(\.count), [64, 64])
    }

    func testOnlyPassedAndNormalExitFailedArePublicationEligible() throws {
        for terminal in CacheTerminal.allCases {
            let cacheOperator = ContractFixtureOperator()
            let check = check(id: terminal.rawValue, binding: "baseline", terminal: terminal)
            let executed = try cacheOperator.execute(request(.refresh, checks: [check]))
            let only = try cacheOperator.execute(request(.only, checks: [check]))

            XCTAssertNil(executed.typedError, "\(terminal)")
            XCTAssertEqual(executed.processesStarted, 1, "\(terminal)")
            XCTAssertEqual(executed.results[0].stdoutArtifactSHA256.count, 64, "\(terminal)")
            if terminal.isCacheable {
                XCTAssertEqual(executed.publications, 1, "\(terminal)")
                XCTAssertNil(only.typedError, "\(terminal)")
                XCTAssertEqual(only.processesStarted, 0, "\(terminal)")
                XCTAssertEqual(only.publications, 0, "\(terminal)")
                XCTAssertEqual(only.results[0].stdoutArtifactSHA256, executed.results[0].stdoutArtifactSHA256, "\(terminal)")
            } else {
                XCTAssertEqual(executed.publications, 0, "\(terminal)")
                XCTAssertEqual(only.typedError, .cacheMiss, "\(terminal)")
                XCTAssertEqual(only.processesStarted, 0, "\(terminal)")
                XCTAssertEqual(only.publications, 0, "\(terminal)")
                XCTAssertTrue(only.results.isEmpty, "\(terminal)")
            }
        }
    }

    func testTTLBoundaryIsExclusiveAndHitDoesNotExtendExpiry() throws {
        let cacheOperator = ContractFixtureOperator(now: 100)
        let check = check(binding: "baseline")
        let stored = try cacheOperator.execute(request(.refresh, checks: [check]))
        cacheOperator.now = 109
        let beforeExpiry = try cacheOperator.execute(request(.prefer, checks: [check]))
        cacheOperator.now = 110
        let atExpiry = try cacheOperator.execute(request(.only, checks: [check]))

        XCTAssertEqual(stored.publications, 1)
        XCTAssertEqual(beforeExpiry.processesStarted, 0)
        XCTAssertEqual(beforeExpiry.publications, 0)
        XCTAssertNil(beforeExpiry.typedError)
        XCTAssertEqual(beforeExpiry.entryExpiries, [110])
        XCTAssertEqual(beforeExpiry.results[0].stdoutArtifactSHA256, stored.results[0].stdoutArtifactSHA256)
        XCTAssertEqual(atExpiry.typedError, .cacheMiss)
        XCTAssertEqual(atExpiry.processesStarted, 0)
        XCTAssertEqual(atExpiry.publications, 0)
        XCTAssertTrue(atExpiry.results.isEmpty)
    }

    func testQuotaEvictionIsPerEntryAndNeverReusesPartialFocusedResult() throws {
        let first = check(id: "first", binding: "baseline")
        let second = check(id: "second", binding: "baseline")
        let preferOperator = ContractFixtureOperator()
        let original = try preferOperator.execute(request(.refresh, checks: [first, second]))
        preferOperator.evict(first)
        let prefer = try preferOperator.execute(request(.prefer, checks: [first, second]))

        XCTAssertNil(prefer.typedError)
        XCTAssertEqual(prefer.processesStarted, 2)
        XCTAssertEqual(prefer.publications, 2)
        XCTAssertNotEqual(prefer.results[1].sourceRunID, original.results[1].sourceRunID)
        XCTAssertEqual(prefer.results.map(\.stdoutArtifactSHA256).map(\.count), [64, 64])

        let onlyOperator = ContractFixtureOperator()
        _ = try onlyOperator.execute(request(.refresh, checks: [first, second]))
        onlyOperator.evict(first)
        let only = try onlyOperator.execute(request(.only, checks: [first, second]))
        XCTAssertEqual(only.typedError, .cacheMiss)
        XCTAssertEqual(only.processesStarted, 0)
        XCTAssertEqual(only.publications, 0)
        XCTAssertTrue(only.results.isEmpty)
    }

    func testRefreshNeverOverwritesExistingGenerationAndConflictsOnDifferentPayload() throws {
        let cacheOperator = ContractFixtureOperator()
        let originalCheck = check(binding: "baseline", payload: "old")
        let original = try cacheOperator.execute(request(.refresh, checks: [originalCheck]))
        let conflict = try cacheOperator.execute(request(.refresh, checks: [check(binding: "baseline", payload: "new")]))
        let hit = try cacheOperator.execute(request(.only, checks: [originalCheck]))

        XCTAssertEqual(conflict.typedError, .cacheConflict)
        XCTAssertEqual(conflict.processesStarted, 1)
        XCTAssertEqual(conflict.publications, 0)
        XCTAssertEqual(conflict.results[0].stdoutArtifactSHA256.count, 64)
        XCTAssertNil(hit.typedError)
        XCTAssertEqual(hit.processesStarted, 0)
        XCTAssertEqual(hit.publications, 0)
        XCTAssertEqual(hit.results[0].stdoutArtifactSHA256, original.results[0].stdoutArtifactSHA256)
    }
}

// MARK: - ACE-034a adapter seam

private protocol FreshnessCacheSafetyNetOperator: AnyObject {
    func execute(_ request: CacheRequest) throws -> CacheObservation
}

private final class ContractFixtureOperator: FreshnessCacheSafetyNetOperator {
    var corruptObservedMaterial = false
    var defect: CacheDefect?
    var publicationFailure: PublicationFailure?
    var now: Int

    private var entries: [String: StoredCacheResult] = [:]
    private var nextRun = 0

    init(now: Int = 0) {
        self.now = now
    }

    func evict(_ check: CacheCheck) {
        entries.removeValue(forKey: check.cacheKey)
    }

    func execute(_ request: CacheRequest) throws -> CacheObservation {
        if request.policy == .off {
            return executeUncached(request.checks, publish: false)
        }
        if corruptObservedMaterial {
            return .failure(.cacheCorrupt, cacheMaterialObservations: request.checks.count)
        }

        let lookup = request.checks.map { check in entries[check.cacheKey] }
        let completeHit = lookup.allSatisfy { entry in
            guard let entry else { return false }
            return entry.expiresAt > now && defect != .artifactIncomplete
        }
        switch request.policy {
        case .only:
            guard completeHit else { return .failure(.cacheMiss, cacheMaterialObservations: request.checks.count) }
            return CacheObservation(
                results: lookup.compactMap { $0?.result },
                cacheMaterialObservations: request.checks.count,
                entryExpiries: lookup.compactMap { $0?.expiresAt }
            )
        case .prefer where completeHit:
            return CacheObservation(
                results: lookup.compactMap { $0?.result },
                cacheMaterialObservations: request.checks.count,
                entryExpiries: lookup.compactMap { $0?.expiresAt }
            )
        case .prefer, .refresh:
            let reasons = request.policy == .prefer
                ? request.checks.compactMap { check in
                    entries.values.contains(where: { $0.checkID == check.id }) ? check.invalidationReason : nil
                }
                : []
            if request.policy == .prefer {
                // miss/incomplete はaggregate transactionとして新generationを作る。
                // refreshの既存generation非上書きとは別の契約である。
                for check in request.checks { entries.removeValue(forKey: check.cacheKey) }
            }
            return executeUncached(
                request.checks,
                invalidationReasons: reasons,
                cacheMaterialObservations: request.checks.count
            )
        case .off:
            fatalError("offはcache観測前に処理済みです")
        }
    }

    private func executeUncached(
        _ checks: [CacheCheck],
        publish: Bool = true,
        invalidationReasons: [String] = [],
        cacheMaterialObservations: Int = 0
    ) -> CacheObservation {
        let results = checks.map { check -> CacheResult in
            nextRun += 1
            let runID = "run-\(nextRun)"
            return CacheResult(
                checkID: check.id,
                terminal: check.terminal,
                sourceRunID: runID,
                stdoutArtifactSHA256: digest("\(check.cacheKey)\u{0}\(check.payload)\u{0}\(runID)"),
                stderrArtifactSHA256: digest("stderr\u{0}\(check.cacheKey)\u{0}\(check.payload)\u{0}\(runID)")
            )
        }
        guard publish else {
            return CacheObservation(
                processesStarted: checks.count,
                results: results,
                cacheMaterialObservations: cacheMaterialObservations
            )
        }
        let eligible = zip(checks, results).filter { $0.0.terminal.isCacheable }
        if let publicationFailure, !eligible.isEmpty {
            return CacheObservation(
                processesStarted: checks.count,
                results: results,
                typedError: publicationFailure.typedError,
                cacheMaterialObservations: cacheMaterialObservations
            )
        }
        if eligible.contains(where: { check, _ in
            guard let existing = entries[check.cacheKey] else { return false }
            return existing.payload != check.payload
        }) {
            return CacheObservation(
                processesStarted: checks.count,
                results: results,
                typedError: .cacheConflict,
                cacheMaterialObservations: cacheMaterialObservations
            )
        }
        var publications = 0
        for (check, result) in eligible where entries[check.cacheKey] == nil {
            entries[check.cacheKey] = StoredCacheResult(
                checkID: check.id,
                payload: check.payload,
                expiresAt: now + 10,
                result: result
            )
            publications += 1
        }
        defect = nil
        return CacheObservation(
            processesStarted: checks.count,
            publications: publications,
            results: results,
            invalidationReasons: invalidationReasons,
            cacheMaterialObservations: cacheMaterialObservations
        )
    }
}

private enum CachePolicy: Equatable { case off, prefer, only, refresh }
private enum CacheTerminal: String, CaseIterable, Equatable {
    case passed, failed, timedOut, cancelled, signaled, launchFailure, artifactFailure

    var isCacheable: Bool { self == .passed || self == .failed }
}
private enum CacheTypedError: Equatable { case cacheMiss, cacheCorrupt, quotaExceeded, storeFailed, cacheConflict }
private enum CacheDefect: Equatable { case artifactIncomplete }
private enum PublicationFailure: CaseIterable {
    case quota, store

    var typedError: CacheTypedError { self == .quota ? .quotaExceeded : .storeFailed }
}

private enum BindingMutation: String, CaseIterable {
    case executableBytes = "executable_bytes_changed"
    case executableSymlink = "executable_symlink_changed"
    case arguments = "arguments_changed"
    case workingDirectoryIdentity = "working_directory_identity_changed"
    case environment = "effective_environment_changed"
    case toolchain = "toolchain_probe_changed"
    case manifest = "manifest_changed"
    case lockfile = "lockfile_changed"
    case inputContent = "relevant_input_content_changed"
    case directoryMembership = "directory_membership_changed"
    case restoredMTimeAndSize = "mtime_size_restored_but_content_changed"
    case replacedInodeAtSamePath = "same_path_inode_replaced"

    var binding: String { rawValue }
}

private struct CacheCheck {
    let id: String
    let binding: String
    let payload: String
    let terminal: CacheTerminal
    let invalidationReason: String?
    var cacheKey: String { digest("\(id)\u{0}\(binding)") }
}

private struct StoredCacheResult {
    let checkID: String
    let payload: String
    let expiresAt: Int
    let result: CacheResult
}

private struct CacheRequest {
    let policy: CachePolicy
    let checks: [CacheCheck]
}

private struct CacheResult: Equatable {
    let checkID: String
    let terminal: CacheTerminal
    let sourceRunID: String
    let stdoutArtifactSHA256: String
    let stderrArtifactSHA256: String
}

private struct CacheObservation {
    var processesStarted = 0
    var publications = 0
    var results: [CacheResult] = []
    var typedError: CacheTypedError?
    var invalidationReasons: [String] = []
    var cacheMaterialObservations = 0
    var entryExpiries: [Int] = []

    static func failure(_ error: CacheTypedError, cacheMaterialObservations: Int = 0) -> CacheObservation {
        CacheObservation(typedError: error, cacheMaterialObservations: cacheMaterialObservations)
    }
}

private func request(_ policy: CachePolicy, checks: [CacheCheck]) -> CacheRequest {
    CacheRequest(policy: policy, checks: checks)
}

private func check(
    id: String = "check",
    binding: String,
    payload: String? = nil,
    terminal: CacheTerminal = .passed
) -> CacheCheck {
    CacheCheck(
        id: id,
        binding: binding,
        payload: payload ?? "output-\(binding)",
        terminal: terminal,
        invalidationReason: binding == "baseline" ? nil : binding
    )
}

private func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}
