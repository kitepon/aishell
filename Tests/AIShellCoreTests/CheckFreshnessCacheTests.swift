import CryptoKit
import XCTest
@testable import AIShellCore

final class CheckFreshnessCacheTests: XCTestCase {
    func testExecutionBatchReportsObservedProcessCountRatherThanStepCount() async throws {
        let cache = CheckFreshnessCache.inMemory()
        let outcome = try await cache.execute(request(.off, ["first", "second"]), executeUncached: { steps in
            .init(results: steps.map { result(step: $0, run: "off") }, processesStarted: 1)
        })
        XCTAssertEqual(outcome.processesStarted, 1)
        XCTAssertEqual(outcome.publications, 0)
        XCTAssertEqual(outcome.state, .disabled)
    }

    func testOffDoesNotCallBindingOrArtifactVerifierAndDoesNotLoadCorruptStore() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not-json".utf8).write(to: directory.appendingPathComponent("freshness-cache-manifest.json"))
        let cache = CheckFreshnessCache(storeDirectory: directory)
        let bindingCalls = LockedCounter()
        let artifactCalls = LockedCounter()
        let outcome = try await cache.execute(request(.off, ["check"]), executeUncached: { steps in
            .init(results: [result(step: steps[0], run: "off", terminal: .timedOut)], processesStarted: 1)
        }, validateBindingAfterExecution: { _ in bindingCalls.increment(); return false }, verifyArtifact: { _ in artifactCalls.increment(); return .corrupt })
        XCTAssertEqual(outcome.state, .disabled)
        XCTAssertEqual(bindingCalls.value, 0)
        XCTAssertEqual(artifactCalls.value, 0)
    }

    func testPreferIneligibleExecutesWholePlanWithoutPublishingAndRecordsReasons() async throws {
        let cache = CheckFreshnessCache.inMemory()
        let request = request(.prefer, ["eligible", "unavailable"], bindings: [.eligible(digest: digest("a")), .ineligible(reason: .bindingIncomplete)])
        let outcome = try await cache.execute(request, executeUncached: { steps in
            .init(results: steps.map { result(step: $0, run: "rerun") }, processesStarted: 1)
        }, verifyArtifact: verified)
        XCTAssertEqual(outcome.state, .ineligible)
        XCTAssertEqual(outcome.processesStarted, 1)
        XCTAssertEqual(outcome.publications, 0)
        XCTAssertEqual(outcome.lookupEvidence, [.init(stepID: "unavailable", status: .ineligible, ineligibilityReason: .bindingIncomplete)])
    }

    func testOnlyIneligibleIsTypedMissWithoutProcess() async throws {
        let cache = CheckFreshnessCache.inMemory()
        let unavailable = request(.only, ["check"], bindings: [.ineligible(reason: .bindingUnavailable)])
        do {
            _ = try await cache.execute(unavailable, executeUncached: { _ in XCTFail("only miss must not execute"); return .init(results: [], processesStarted: 1) }, verifyArtifact: verified)
            XCTFail()
        } catch let error as CheckFreshnessCache.Error {
            XCTAssertEqual(error, .cacheMissWithEvidence([.init(stepID: "check", status: .ineligible, ineligibilityReason: .bindingUnavailable)]))
        }
    }

    func testRefreshExecutesAllAndPublishesOnlyEligibleTerminals() async throws {
        let cache = CheckFreshnessCache.inMemory()
        let outcome = try await cache.execute(request(.refresh, ["passed", "timeout"]), executeUncached: { steps in
            .init(results: [result(step: steps[0], run: "run"), result(step: steps[1], run: "run", terminal: .timedOut)], processesStarted: 2)
        }, verifyArtifact: verified)
        XCTAssertEqual(outcome.state, .refreshExecuted)
        XCTAssertEqual(outcome.processesStarted, 2)
        XCTAssertEqual(outcome.publications, 1)
        do { _ = try await cache.execute(request(.only, ["timeout"]), executeUncached: { _ in .init(results: [], processesStarted: 0) }, verifyArtifact: verified); XCTFail() }
        catch let error as CheckFreshnessCache.Error { XCTAssertEqual(error, .cacheMissWithEvidence([.init(stepID: "timeout", status: .miss)])) }
    }

    func testCacheableResultRequiresVerifiedEvidenceStoreReceipt() async throws {
        let cache = CheckFreshnessCache.inMemory()
        do {
            _ = try await cache.execute(request(.refresh, ["check"]), executeUncached: { steps in .init(results: [result(step: steps[0], run: "bad")], processesStarted: 1) }, verifyArtifact: { _ in .corrupt })
            XCTFail()
        } catch let error as CheckFreshnessCache.Error { XCTAssertEqual(error, .cacheStoreFailed) }
        let timeout = try await cache.execute(request(.refresh, ["timeout"]), executeUncached: { steps in .init(results: [result(step: steps[0], run: "timeout", terminal: .timedOut, artifacts: [])], processesStarted: 1) }, verifyArtifact: { _ in .corrupt })
        XCTAssertEqual(timeout.publications, 0)
    }

    func testLookupEvidenceKeepsStepOrderAndCorruptionFailsClosed() async throws {
        let cache = CheckFreshnessCache.inMemory()
        let seeded = request(.refresh, ["first", "second"])
        _ = try await cache.execute(seeded, executeUncached: batch("seed"), verifyArtifact: verified)
        let changedSecond = request(.prefer, ["first", "second"], bindings: [.eligible(digest: digest("binding-first")), .eligible(digest: digest("changed-second"))])
        let prefer = try await cache.execute(changedSecond, executeUncached: { steps in
            .init(results: [result(step: steps[0], run: "seed"), result(step: steps[1], run: "rerun")], processesStarted: 2)
        }, verifyArtifact: verified)
        XCTAssertEqual(prefer.lookupEvidence.map(\.stepID), ["first", "second"])
        XCTAssertEqual(prefer.lookupEvidence.map(\.status), [.hit, .miss])
        try await cache.markEntryCorrupt(for: seeded, stepID: "first")
        let onlySeeded = CheckFreshnessCache.Request(policy: .only, plan: seeded.plan, orderedSteps: seeded.orderedSteps)
        do { _ = try await cache.execute(onlySeeded, executeUncached: { _ in .init(results: [], processesStarted: 0) }, verifyArtifact: verified); XCTFail() }
        catch let error as CheckFreshnessCache.Error { XCTAssertEqual(error, .cacheCorrupt) }
    }

    func testTTLQuotaAndRestartRetainExistingGuarantees() async throws {
        let clock = TestClock()
        let cache = CheckFreshnessCache.inMemory(ttl: 1, maximumEntryCount: 1, now: { clock.now })
        _ = try await cache.execute(request(.refresh, ["old"]), executeUncached: batch("old"), verifyArtifact: verified)
        clock.now = Date(timeIntervalSince1970: 1)
        let renewed = try await cache.execute(request(.refresh, ["new"]), executeUncached: batch("new"), verifyArtifact: verified)
        XCTAssertEqual(renewed.publications, 1)

        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let first = CheckFreshnessCache(storeDirectory: directory)
        _ = try await first.execute(request(.refresh, ["check"]), executeUncached: batch("disk"), verifyArtifact: verified)
        let restarted = CheckFreshnessCache(storeDirectory: directory)
        let hit = try await restarted.execute(request(.only, ["check"]), executeUncached: { _ in .init(results: [], processesStarted: 0) }, verifyArtifact: verified)
        XCTAssertEqual(hit.state, .hit)
        let manifest = directory.appendingPathComponent("freshness-cache-manifest.json")
        let data = try Data(contentsOf: manifest)
        try Data("{}".utf8).write(to: manifest)
        let corrupt = CheckFreshnessCache(storeDirectory: directory)
        do { _ = try await corrupt.execute(request(.only, ["check"]), executeUncached: { _ in .init(results: [], processesStarted: 0) }, verifyArtifact: verified); XCTFail() }
        catch let error as CheckFreshnessCache.Error { XCTAssertEqual(error, .cacheCorrupt) }
        XCTAssertFalse(data.isEmpty)
    }

    // ACE-034a から継続する個別 safety-net。path ではなく EvidenceStore receipt verifier を欠損・破損へ対応付ける。
    func testRefreshReusesSamePayloadWithoutTTLChangeAndRejectsConflict() async throws {
        let clock = TestClock(); let cache = CheckFreshnessCache.inMemory(ttl: 10, now: { clock.now }); let refresh = request(.refresh, ["check"])
        _ = try await cache.execute(refresh, executeUncached: batch("same"), verifyArtifact: verified)
        clock.now = Date(timeIntervalSince1970: 9)
        let reused = try await cache.execute(refresh, executeUncached: batch("same"), verifyArtifact: verified)
        XCTAssertEqual(reused.publications, 0)
        do { _ = try await cache.execute(refresh, executeUncached: batch("different"), verifyArtifact: verified); XCTFail() } catch let error as CheckFreshnessCache.Error { XCTAssertEqual(error, .cacheConflict) }
    }

    func testExpiredGenerationIsEvictedBeforeQuotaAdmission() async throws {
        let clock = TestClock(); let cache = CheckFreshnessCache.inMemory(ttl: 1, maximumEntryCount: 1, now: { clock.now })
        _ = try await cache.execute(request(.refresh, ["old"]), executeUncached: batch("old"), verifyArtifact: verified)
        clock.now = Date(timeIntervalSince1970: 1)
        let renewed = try await cache.execute(request(.refresh, ["new"]), executeUncached: batch("new"), verifyArtifact: verified)
        XCTAssertEqual(renewed.publications, 1)
    }

    func testFileBackedStoreFailsClosedOnUnknownSchema() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CheckFreshnessCache(storeDirectory: directory); _ = try await cache.execute(request(.refresh, ["check"]), executeUncached: batch("seed"), verifyArtifact: verified)
        let manifest = directory.appendingPathComponent("freshness-cache-manifest.json")
        try String(contentsOf: manifest).replacingOccurrences(of: "aishell.check-freshness-cache-manifest.v1", with: "unknown.schema").write(to: manifest, atomically: true, encoding: .utf8)
        do { _ = try await CheckFreshnessCache(storeDirectory: directory).execute(request(.only, ["check"]), executeUncached: { _ in .init(results: [], processesStarted: 0) }, verifyArtifact: verified); XCTFail() } catch let error as CheckFreshnessCache.Error { XCTAssertEqual(error, .cacheCorrupt) }
    }

    func testMissingArtifactIsPreferMissExecutedAndOnlyCacheExpired() async throws {
        let cache = CheckFreshnessCache.inMemory(); let refresh = request(.refresh, ["check"])
        _ = try await cache.execute(refresh, executeUncached: batch("seed"), verifyArtifact: verified)
        let missing: @Sendable (ArtifactMetadata) async -> CheckFreshnessCache.ArtifactVerification = { $0.handle.contains("seed") ? .expired : .valid }
        do { _ = try await cache.execute(request(.only, ["check"]), executeUncached: { _ in .init(results: [], processesStarted: 0) }, verifyArtifact: missing); XCTFail() } catch let error as CheckFreshnessCache.Error { XCTAssertEqual(error, .cacheExpiredWithEvidence([.init(stepID: "check", status: .expired)])) }
        let prefer = try await cache.execute(request(.prefer, ["check"]), executeUncached: batch("rerun"), verifyArtifact: missing)
        XCTAssertEqual(prefer.state, .missExecuted)
        XCTAssertEqual(prefer.publications, 1)
        let hit = try await cache.execute(request(.only, ["check"]), executeUncached: { _ in .init(results: [], processesStarted: 0) }, verifyArtifact: verified)
        XCTAssertEqual(hit.results.map(\.sourceRunID), ["rerun-check"])
    }

    func testFileBackedPublicationRejectsUnboundStdoutOrStderrArtifactHash() async throws {
        let cache = CheckFreshnessCache.inMemory()
        do { _ = try await cache.execute(request(.refresh, ["check"]), executeUncached: { steps in var value = result(step: steps[0], run: "bad"); value = .init(stepID: value.stepID, terminalState: value.terminalState, sourceRunID: value.sourceRunID, stdoutArtifactSHA256: digest("unbound"), stderrArtifactSHA256: value.stderrArtifactSHA256, payloadDigest: value.payloadDigest, artifacts: value.artifacts); return .init(results: [value], processesStarted: 1) }, verifyArtifact: verified); XCTFail() } catch let error as CheckFreshnessCache.Error { XCTAssertEqual(error, .cacheStoreFailed) }
    }

    func testFileStoreFailurePreservesOldManifestAcrossRestart() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }; let cache = CheckFreshnessCache(storeDirectory: directory)
        _ = try await cache.execute(request(.refresh, ["old"]), executeUncached: batch("old"), verifyArtifact: verified); await cache.injectPublicationFailure(.store)
        do { _ = try await cache.execute(request(.refresh, ["new"]), executeUncached: batch("new"), verifyArtifact: verified); XCTFail() } catch let error as CheckFreshnessCache.Error { XCTAssertEqual(error, .cacheStoreFailed) }
        let oldHit = try await CheckFreshnessCache(storeDirectory: directory).execute(request(.only, ["old"]), executeUncached: { _ in .init(results: [], processesStarted: 0) }, verifyArtifact: verified)
        XCTAssertEqual(oldHit.state, .hit)
        do {
            _ = try await CheckFreshnessCache(storeDirectory: directory).execute(request(.only, ["new"]), executeUncached: { _ in .init(results: [], processesStarted: 0) }, verifyArtifact: verified)
            XCTFail()
        } catch let error as CheckFreshnessCache.Error {
            if case .cacheMissWithEvidence = error {} else { XCTFail("expected miss evidence") }
        }
    }

    func testOffDoesNotObserveCorruptEntry() async throws {
        let cache = CheckFreshnessCache.inMemory(); let cached = request(.refresh, ["check"])
        _ = try await cache.execute(cached, executeUncached: batch("seed"), verifyArtifact: verified); try await cache.markEntryCorrupt(for: cached, stepID: "check")
        let off = try await cache.execute(request(.off, ["check"]), executeUncached: batch("off")); XCTAssertEqual(off.state, .disabled)
    }

    func testPreferAndOnlyAreAggregateHitOrMissAndPreservePlan() async throws {
        let cache = CheckFreshnessCache.inMemory(); _ = try await cache.execute(request(.refresh, ["first"]), executeUncached: batch("seed"), verifyArtifact: verified)
        let all = request(.prefer, ["first", "second"]); let prefer = try await cache.execute(all, executeUncached: batch("prefer"), verifyArtifact: verified)
        XCTAssertEqual(prefer.state, .missExecuted); XCTAssertEqual(prefer.plan, all.plan); XCTAssertEqual(prefer.results.map(\.stepID), ["first", "second"])
        do { _ = try await cache.execute(request(.only, ["first", "third"]), executeUncached: { _ in .init(results: [], processesStarted: 0) }, verifyArtifact: verified); XCTFail() } catch let error as CheckFreshnessCache.Error { if case let .cacheMissWithEvidence(evidence) = error { XCTAssertEqual(evidence.map(\.stepID), ["first", "third"]) } else { XCTFail("expected evidence-bearing miss") } }
    }

    func testDifferentInvocationIdentityReusesSameFreshnessBinding() async throws {
        let cache = CheckFreshnessCache.inMemory(); _ = try await cache.execute(request(.refresh, ["check"]), executeUncached: batch("seed"), verifyArtifact: verified)
        let plan = CheckFreshnessCache.Plan(invocationID: "another", orderedStepIDs: ["check"], selectionDigest: digest("check"))
        let hit = try await cache.execute(.init(policy: .only, plan: plan, orderedSteps: request(.only, ["check"]).orderedSteps), executeUncached: { _ in .init(results: [], processesStarted: 0) }, verifyArtifact: verified)
        XCTAssertEqual(hit.state, .hit)
    }

    func testBindingMutationIsMissAndExecutionTimeMutationPreventsPublication() async throws {
        let cache = CheckFreshnessCache.inMemory(); _ = try await cache.execute(request(.refresh, ["check"]), executeUncached: batch("old"), verifyArtifact: verified)
        let miss = try await cache.execute(request(.prefer, ["check"], bindings: [.eligible(digest: digest("new"))]), executeUncached: batch("new"), verifyArtifact: verified); XCTAssertEqual(miss.state, .missExecuted)
        do { _ = try await cache.execute(request(.refresh, ["moving"]), executeUncached: batch("moving"), validateBindingAfterExecution: { _ in false }, verifyArtifact: verified); XCTFail() } catch let error as CheckFreshnessCache.Error { XCTAssertEqual(error, .contentChanged) }
    }

    func testTTLBoundaryAndIncompleteEntryAreMissWithoutExtension() async throws {
        let clock = TestClock(); let cache = CheckFreshnessCache.inMemory(ttl: 1, now: { clock.now }); let seeded = request(.refresh, ["check"])
        _ = try await cache.execute(seeded, executeUncached: batch("seed"), verifyArtifact: verified); clock.now = Date(timeIntervalSince1970: 1)
        do { _ = try await cache.execute(request(.only, ["check"]), executeUncached: { _ in .init(results: [], processesStarted: 0) }, verifyArtifact: verified); XCTFail() } catch let error as CheckFreshnessCache.Error { if case .cacheExpiredWithEvidence = error {} else { XCTFail("expected evidence-bearing expiry") } }
        let fresh = request(.refresh, ["fresh"])
        _ = try await cache.execute(fresh, executeUncached: batch("fresh"), verifyArtifact: verified)
        try await cache.markEntryIncomplete(for: fresh, stepID: "fresh")
        let onlyFresh = CheckFreshnessCache.Request(policy: .only, plan: fresh.plan, orderedSteps: fresh.orderedSteps)
        do {
            _ = try await cache.execute(onlyFresh, executeUncached: { _ in .init(results: [], processesStarted: 0) }, verifyArtifact: verified)
            XCTFail()
        } catch let error as CheckFreshnessCache.Error {
            XCTAssertEqual(error, .cacheMissWithEvidence([.init(stepID: "fresh", status: .incomplete)]))
        }
    }

    func testCorruptEntryFailsClosedForWholeLookup() async throws {
        let cache = CheckFreshnessCache.inMemory(); let request = request(.refresh, ["first", "second"]); _ = try await cache.execute(request, executeUncached: batch("seed"), verifyArtifact: verified); try await cache.markEntryCorrupt(for: request, stepID: "second")
        let only = CheckFreshnessCache.Request(policy: .only, plan: request.plan, orderedSteps: request.orderedSteps)
        do { _ = try await cache.execute(only, executeUncached: { _ in .init(results: [], processesStarted: 0) }, verifyArtifact: verified); XCTFail() } catch let error as CheckFreshnessCache.Error { XCTAssertEqual(error, .cacheCorrupt) }
    }

    func testNonCacheableTerminalIsNotPublished() async throws {
        let cache = CheckFreshnessCache.inMemory(); let outcome = try await cache.execute(request(.refresh, ["timeout"]), executeUncached: { steps in .init(results: [result(step: steps[0], run: "timeout", terminal: .timedOut, artifacts: [])], processesStarted: 1) }, verifyArtifact: verified); XCTAssertEqual(outcome.publications, 0)
    }

    func testNonCacheableResultDoesNotObservePublicationFailure() async throws {
        let cache = CheckFreshnessCache.inMemory(maximumEntryCount: 0); await cache.injectPublicationFailure(.store)
        let outcome = try await cache.execute(request(.refresh, ["timeout"]), executeUncached: { steps in .init(results: [result(step: steps[0], run: "timeout", terminal: .timedOut, artifacts: [])], processesStarted: 1) }, verifyArtifact: verified); XCTAssertEqual(outcome.publications, 0)
    }

    func testQuotaAndStoreFailureAreAtomic() async throws {
        let quota = CheckFreshnessCache.inMemory(maximumEntryCount: 1)
        do { _ = try await quota.execute(request(.refresh, ["one", "two"]), executeUncached: batch("quota"), verifyArtifact: verified); XCTFail() } catch let error as CheckFreshnessCache.Error { XCTAssertEqual(error, .cacheQuotaExceeded) }
        do {
            _ = try await quota.execute(request(.only, ["one", "two"]), executeUncached: { _ in .init(results: [], processesStarted: 0) }, verifyArtifact: verified)
            XCTFail()
        } catch let error as CheckFreshnessCache.Error {
            XCTAssertEqual(error, .cacheMissWithEvidence([.init(stepID: "one", status: .miss), .init(stepID: "two", status: .miss)]))
        }
        let store = CheckFreshnessCache.inMemory(); await store.injectPublicationFailure(.store)
        do { _ = try await store.execute(request(.refresh, ["one", "two"]), executeUncached: batch("store"), verifyArtifact: verified); XCTFail() } catch let error as CheckFreshnessCache.Error { XCTAssertEqual(error, .cacheStoreFailed) }
        await store.injectPublicationFailure(nil)
        do {
            _ = try await store.execute(request(.only, ["one", "two"]), executeUncached: { _ in .init(results: [], processesStarted: 0) }, verifyArtifact: verified)
            XCTFail()
        } catch let error as CheckFreshnessCache.Error {
            XCTAssertEqual(error, .cacheMissWithEvidence([.init(stepID: "one", status: .miss), .init(stepID: "two", status: .miss)]))
        }
    }

    func testFileBackedStoreReloadsAtomicallyAndFailsClosedOnArtifactCorruption() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }; let cache = CheckFreshnessCache(storeDirectory: directory)
        _ = try await cache.execute(request(.refresh, ["check"]), executeUncached: batch("disk"), verifyArtifact: verified)
        let corrupt: @Sendable (ArtifactMetadata) async -> CheckFreshnessCache.ArtifactVerification = { _ in .corrupt }
        do { _ = try await CheckFreshnessCache(storeDirectory: directory).execute(request(.only, ["check"]), executeUncached: { _ in .init(results: [], processesStarted: 0) }, verifyArtifact: corrupt); XCTFail() } catch let error as CheckFreshnessCache.Error { XCTAssertEqual(error, .cacheCorrupt) }
    }

    func testOffNeverLoadsCorruptStoreAndCorruptionRemainsFailClosedOnRetry() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }; try Data("not-json".utf8).write(to: directory.appendingPathComponent("freshness-cache-manifest.json")); let cache = CheckFreshnessCache(storeDirectory: directory)
        let off = try await cache.execute(request(.off, ["check"]), executeUncached: batch("off")); XCTAssertEqual(off.state, .disabled)
        do { _ = try await cache.execute(request(.only, ["check"]), executeUncached: { _ in .init(results: [], processesStarted: 0) }, verifyArtifact: verified); XCTFail() } catch let error as CheckFreshnessCache.Error { XCTAssertEqual(error, .cacheCorrupt) }
    }

    func testManifestEntryExpiryTamperingFailsClosedOnEveryAttempt() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CheckFreshnessCache(storeDirectory: directory)
        _ = try await cache.execute(request(.refresh, ["check"]), executeUncached: batch("seed"), verifyArtifact: verified)
        let manifest = directory.appendingPathComponent("freshness-cache-manifest.json")
        let original = try String(contentsOf: manifest, encoding: .utf8)
        let marker = "\"expiresAt\":"; let start = original.range(of: marker)!.upperBound; let end = original[start...].firstIndex(of: ",")!
        try (String(original[..<start]) + "0" + String(original[end...])).write(to: manifest, atomically: true, encoding: .utf8)
        let restarted = CheckFreshnessCache(storeDirectory: directory)
        for _ in 0 ..< 2 {
            do { _ = try await restarted.execute(request(.only, ["check"]), executeUncached: { _ in .init(results: [], processesStarted: 0) }, verifyArtifact: verified); XCTFail() } catch let error as CheckFreshnessCache.Error { XCTAssertEqual(error, .cacheCorrupt) }
        }
    }

    func testCorruptUnrelatedArtifactBlocksPublicationAndSurvivesRestart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CheckFreshnessCache(storeDirectory: directory)
        _ = try await cache.execute(request(.refresh, ["old"]), executeUncached: batch("old"), verifyArtifact: verified)
        let corrupt: @Sendable (ArtifactMetadata) async -> CheckFreshnessCache.ArtifactVerification = { $0.handle.contains("old") ? .corrupt : .valid }
        do { _ = try await cache.execute(request(.refresh, ["new"]), executeUncached: batch("new"), verifyArtifact: corrupt); XCTFail() } catch let error as CheckFreshnessCache.Error { XCTAssertEqual(error, .cacheCorrupt) }
        let restarted = CheckFreshnessCache(storeDirectory: directory)
        do {
            _ = try await restarted.execute(request(.only, ["old"]), executeUncached: { _ in .init(results: [], processesStarted: 0) }, verifyArtifact: corrupt)
            XCTFail()
        } catch let error as CheckFreshnessCache.Error {
            XCTAssertEqual(error, .cacheCorrupt)
        }
    }

    func testExpiredSamePayloadPublishesNewGenerationAndInvalidInputIsRejected() async throws {
        let clock = TestClock(); let cache = CheckFreshnessCache.inMemory(ttl: 1, now: { clock.now }); let refresh = request(.refresh, ["check"])
        _ = try await cache.execute(refresh, executeUncached: batch("same"), verifyArtifact: verified)
        clock.now = Date(timeIntervalSince1970: 1)
        let renewed = try await cache.execute(refresh, executeUncached: batch("same"), verifyArtifact: verified)
        XCTAssertEqual(renewed.publications, 1)
        let verifierExpired: @Sendable (ArtifactMetadata) async -> CheckFreshnessCache.ArtifactVerification = { $0.handle.contains("art_same_") ? .expired : .valid }
        let artifactRenewed = try await cache.execute(refresh, executeUncached: { steps in
            let fresh = result(step: steps[0], run: "new-artifact")
            let samePayload = CheckFreshnessCache.Result(stepID: fresh.stepID, terminalState: fresh.terminalState, sourceRunID: fresh.sourceRunID, stdoutArtifactSHA256: fresh.stdoutArtifactSHA256, stderrArtifactSHA256: fresh.stderrArtifactSHA256, payloadDigest: digest("payload-same-check"), artifacts: fresh.artifacts)
            return .init(results: [samePayload], processesStarted: 1)
        }, verifyArtifact: verifierExpired)
        XCTAssertEqual(artifactRenewed.publications, 1)
        let invalid = CheckFreshnessCache.Request(policy: .prefer, plan: refresh.plan, orderedSteps: [.init(id: "check", binding: .eligible(digest: String(repeating: "１", count: 64)))])
        do { _ = try await cache.execute(invalid, executeUncached: { _ in .init(results: [], processesStarted: 0) }, verifyArtifact: verified); XCTFail() } catch let error as CheckFreshnessCache.Error { XCTAssertEqual(error, .invalidRequest) }
        do { _ = try await cache.execute(request(.refresh, ["empty"]), executeUncached: { steps in .init(results: [result(step: steps[0], run: "", artifacts: [])], processesStarted: 1) }, verifyArtifact: verified); XCTFail() } catch let error as CheckFreshnessCache.Error { XCTAssertEqual(error, .cacheStoreFailed) }
    }

    func testRefreshIneligibleIsVisibleAndOnlyMissCarriesOrderedEvidence() async throws {
        let steps: [CheckFreshnessCache.Binding] = [.eligible(digest: digest("first")), .ineligible(reason: .bindingIncomplete)]
        let refresh = request(.refresh, ["first", "second"], bindings: steps)
        let cache = CheckFreshnessCache.inMemory()
        let outcome = try await cache.execute(refresh, executeUncached: batch("ineligible"), verifyArtifact: verified)
        XCTAssertEqual(outcome.state, .ineligible)
        XCTAssertEqual(outcome.publications, 0)
        let only = CheckFreshnessCache.Request(policy: .only, plan: refresh.plan, orderedSteps: refresh.orderedSteps)
        do { _ = try await cache.execute(only, executeUncached: { _ in .init(results: [], processesStarted: 0) }, verifyArtifact: verified); XCTFail() }
        catch let error as CheckFreshnessCache.Error {
            XCTAssertEqual(error, .cacheMissWithEvidence([.init(stepID: "second", status: .ineligible, ineligibilityReason: .bindingIncomplete)]))
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock(); private var storage = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
    func increment() { lock.lock(); storage += 1; lock.unlock() }
}
private let verified: @Sendable (ArtifactMetadata) async -> CheckFreshnessCache.ArtifactVerification = { _ in .valid }
private final class TestClock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 0) }
private func temporaryDirectory() throws -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent("CheckFreshnessCacheTests-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url }
private func request(_ policy: CheckFreshnessCache.Policy, _ ids: [String], bindings: [CheckFreshnessCache.Binding]? = nil) -> CheckFreshnessCache.Request {
    let supplied = bindings ?? ids.map { .eligible(digest: digest("binding-\($0)")) }
    return .init(policy: policy, plan: .init(invocationID: "profile_check", orderedStepIDs: ids, selectionDigest: digest(ids.joined(separator: "\u{0}"))), orderedSteps: zip(ids, supplied).map { .init(id: $0.0, binding: $0.1) })
}
private func batch(_ run: String) -> @Sendable ([CheckFreshnessCache.Step]) async throws -> CheckFreshnessCache.ExecutionBatch { { steps in .init(results: steps.map { result(step: $0, run: run) }, processesStarted: steps.count) } }
private func result(step: CheckFreshnessCache.Step, run: String, terminal: CheckFreshnessCache.TerminalState = .passed, artifacts: [ArtifactMetadata]? = nil) -> CheckFreshnessCache.Result {
    let stdout = digest("out-\(run)-\(step.id)")
    let stderr = digest("err-\(run)-\(step.id)")
    let receipts = artifacts ?? [metadata(handle: "art_\(run)_\(step.id)_stdout", sha256: stdout), metadata(handle: "art_\(run)_\(step.id)_stderr", sha256: stderr)]
    return .init(stepID: step.id, terminalState: terminal, sourceRunID: "\(run)-\(step.id)", stdoutArtifactSHA256: stdout, stderrArtifactSHA256: stderr, payloadDigest: digest("payload-\(run)-\(step.id)"), artifacts: receipts)
}
private func metadata(handle: String, sha256: String) -> ArtifactMetadata { .init(handle: handle, kind: "run_check", sizeBytes: 1, lineCount: 1, sha256: sha256, createdAt: .distantPast, expiresAt: .distantFuture, producer: "test") }
private func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
