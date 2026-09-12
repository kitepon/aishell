import XCTest
@testable import AIShellCore

final class FocusedCheckServiceTests: XCTestCase {
    func testCompileDeduplicatesReasonsAndProducesStableContentAddressedIdentity() async throws {
        let clock = Clock()
        let service = FocusedCheckService(now: { clock.now })
        let first = candidate(evidence: [evidence("one")])
        let duplicate = candidate(evidence: [evidence("two")])
        let set = try await service.compile(request(candidates: [duplicate, first]))
        XCTAssertEqual(set.candidates.count, 1)
        XCTAssertEqual(set.candidates[0].source.evidence.map(\.id), ["one", "two"])
        let again = try await service.compile(request(candidates: [first, duplicate]))
        XCTAssertEqual(set.digest, again.digest)
        XCTAssertEqual(set.id, again.id)
    }

    func testResolvePreservesCallerOrderAndUsesDeterministicTopologicalSteps() async throws {
        let service = FocusedCheckService()
        let first = candidate(check: "one", steps: [step("b", dependsOn: ["a"]), step("a", ordinal: 2), step("c", ordinal: 1)])
        let second = candidate(check: "two", steps: [step("z")])
        let set = try await service.compile(request(candidates: [first, second]))
        let ids = set.candidates.map(\.focusedCheckID)
        let selection = try await service.resolve(focusedSetID: set.id, focusedSetDigest: set.digest, requestedCheckIDs: [ids[1], ids[0]], admission: admission())
        XCTAssertEqual(selection.requestedCheckIDs, [ids[1], ids[0]])
        XCTAssertEqual(selection.plannedCheckIDs, [ids[1], ids[0]])
        XCTAssertEqual(selection.steps.map(\.id), ["z", "c", "a", "b"])
    }

    func testMalformedDAGUnknownAndDuplicateSelectionFailClosed() async throws {
        let service = FocusedCheckService()
        await XCTAssertThrowsErrorAsync({
            try await service.compile(self.request(candidates: [self.candidate(steps: [self.step("a", dependsOn: ["missing"])])]))
        }, { XCTAssertEqual($0 as? FocusedCheckService.Error, .invocationInvalid) })
        let set = try await service.compile(request(candidates: [candidate()]))
        let id = set.candidates[0].focusedCheckID
        await XCTAssertThrowsErrorAsync({
            try await service.resolve(focusedSetID: set.id, focusedSetDigest: set.digest, requestedCheckIDs: [id, id], admission: self.admission())
        }, { XCTAssertEqual($0 as? FocusedCheckService.Error, .invocationInvalid) })
        await XCTAssertThrowsErrorAsync({
            try await service.resolve(focusedSetID: set.id, focusedSetDigest: set.digest, requestedCheckIDs: ["unknown"], admission: self.admission())
        }, { XCTAssertEqual($0 as? FocusedCheckService.Error, .invocationInvalid) })
        await XCTAssertThrowsErrorAsync({
            try await service.compile(self.request(candidates: [self.candidate(steps: [self.step("a", dependsOn: ["b"]), self.step("b", dependsOn: ["a"])])]))
        }, { XCTAssertEqual($0 as? FocusedCheckService.Error, .invocationInvalid) })
        await XCTAssertThrowsErrorAsync({
            try await service.compile(self.request(candidates: [self.candidate(steps: [self.step("a", dependsOn: ["b", "b"]), self.step("b")])]))
        }, { XCTAssertEqual($0 as? FocusedCheckService.Error, .invocationInvalid) })
    }

    func testExpiryAndProvenanceMismatchAreStale() async throws {
        let clock = Clock()
        let service = FocusedCheckService(now: { clock.now })
        let set = try await service.compile(request(candidates: [candidate()], expiry: Date(timeIntervalSince1970: 10)))
        let id = set.candidates[0].focusedCheckID
        clock.now = Date(timeIntervalSince1970: 10)
        await XCTAssertThrowsErrorAsync({
            try await service.resolve(focusedSetID: set.id, focusedSetDigest: set.digest, requestedCheckIDs: [id], admission: self.admission())
        }, { XCTAssertEqual($0 as? FocusedCheckService.Error, .selectionStale) })
        clock.now = .distantPast
        await XCTAssertThrowsErrorAsync({
            try await service.resolve(focusedSetID: set.id, focusedSetDigest: set.digest, requestedCheckIDs: [id], admission: self.admission(cursor: "other"))
        }, { XCTAssertEqual($0 as? FocusedCheckService.Error, .selectionStale) })
    }

    func testDigestBindsEvidenceCoverageLimitationsAndNormalizesInputOrder() async throws {
        let service = FocusedCheckService()
        let one = candidate(evidence: [evidence("two"), evidence("one")])
        let expiry = Date(timeIntervalSince1970: 3_000_000_000)
        let canonical = try await service.compile(request(candidates: [one], coverage: ["b", "a"], limitations: ["z", "x"], expiry: expiry))
        let reordered = try await service.compile(request(candidates: [candidate(evidence: [evidence("one"), evidence("two")])], coverage: ["a", "b"], limitations: ["x", "z"], expiry: expiry))
        XCTAssertEqual(canonical.digest, reordered.digest)
        let changedEvidence = try await service.compile(request(candidates: [candidate(evidence: [evidence("three")])], coverage: ["a", "b"], limitations: ["x", "z"], expiry: expiry))
        let changedCoverage = try await service.compile(request(candidates: [candidate(evidence: [evidence("one"), evidence("two")])], coverage: ["a", "c"], limitations: ["x", "z"], expiry: expiry))
        let changedExpiry = try await service.compile(request(candidates: [candidate(evidence: [evidence("one"), evidence("two")])], coverage: ["a", "b"], limitations: ["x", "z"], expiry: Date(timeIntervalSince1970: 3_000_000_001)))
        XCTAssertNotEqual(canonical.digest, changedEvidence.digest)
        XCTAssertNotEqual(canonical.digest, changedCoverage.digest)
        XCTAssertEqual(canonical.digest, changedExpiry.digest)
        XCTAssertEqual(canonical.id, changedExpiry.id)
        XCTAssertEqual(changedExpiry.expiresAt, canonical.expiresAt)
        let oldID = canonical.candidates[0].focusedCheckID
        _ = try await service.resolve(focusedSetID: canonical.id, focusedSetDigest: canonical.digest, requestedCheckIDs: [oldID], admission: admission())
    }

    func testFirstReceiptExpiryIsImmutableForSameCanonicalIdentity() async throws {
        let shortExpiry = Date(timeIntervalSince1970: 100)
        let longExpiry = Date(timeIntervalSince1970: 200)

        let longFirst = FocusedCheckService(now: { .distantPast })
        let longReceipt = try await longFirst.compile(request(candidates: [candidate()], expiry: longExpiry))
        let shortenedRequest = try await longFirst.compile(request(candidates: [candidate()], expiry: shortExpiry))
        XCTAssertEqual(shortenedRequest.id, longReceipt.id)
        XCTAssertEqual(shortenedRequest.digest, longReceipt.digest)
        XCTAssertEqual(shortenedRequest.expiresAt, longExpiry)

        let shortFirst = FocusedCheckService(now: { .distantPast })
        let shortReceipt = try await shortFirst.compile(request(candidates: [candidate()], expiry: shortExpiry))
        let extendedRequest = try await shortFirst.compile(request(candidates: [candidate()], expiry: longExpiry))
        XCTAssertEqual(extendedRequest.id, shortReceipt.id)
        XCTAssertEqual(extendedRequest.digest, shortReceipt.digest)
        XCTAssertEqual(extendedRequest.expiresAt, shortExpiry)
    }

    func testUnicodeHexAndExpandedStepDuplicatesAreInvalidBeforeExecution() async throws {
        let service = FocusedCheckService()
        let unicode = String(repeating: "１", count: 64)
        let invalid = FocusedCheckService.Candidate(profileCheckID: "bad", profileDigest: unicode, selector: .profileCheck(id: "bad"), steps: [step("bad")], evidence: [evidence("bad")])
        await XCTAssertThrowsErrorAsync({ try await service.compile(self.request(candidates: [invalid])) }, { XCTAssertEqual($0 as? FocusedCheckService.Error, .invocationInvalid) })
        let first = candidate(check: "first", steps: [step("shared")])
        let second = candidate(check: "second", steps: [step("shared")])
        let set = try await service.compile(request(candidates: [first, second]))
        await XCTAssertThrowsErrorAsync({
            try await service.resolve(focusedSetID: set.id, focusedSetDigest: set.digest, requestedCheckIDs: set.candidates.map(\.focusedCheckID), admission: self.admission())
        }, { XCTAssertEqual($0 as? FocusedCheckService.Error, .invocationInvalid) })
    }

    func testPlanFacingResolverUsesStoredSetDigestAndRejectsSelectionDigestMismatch() async throws {
        let service = FocusedCheckService()
        let set = try await service.compile(request(candidates: [candidate()]))
        let id = set.candidates[0].focusedCheckID
        let prepared = try await service.prepare(focusedSetID: set.id, focusedSetDigest: set.digest)
        XCTAssertEqual(prepared.focusedSetID, set.id)
        XCTAssertEqual(prepared.profileDigest, hash("profile"))
        let baseline = try await service.resolve(
            focusedSetID: set.id, focusedSetDigest: set.digest,
            requestedCheckIDs: [id], admission: admission()
        )
        let exact = try await service.resolve(
            focusedSetID: set.id, requestedCheckIDs: [id],
            expectedSelectionDigest: baseline.selectionDigest, admission: admission()
        )
        XCTAssertEqual(exact, baseline)
        let exactWithSetDigest = try await service.resolve(
            focusedSetID: set.id, focusedSetDigest: set.digest,
            requestedCheckIDs: [id], expectedSelectionDigest: baseline.selectionDigest, admission: admission()
        )
        XCTAssertEqual(exactWithSetDigest.admissionReceipt.focusedSetID, set.id)
        XCTAssertEqual(exactWithSetDigest.admissionReceipt.focusedSetDigest, set.digest)
        XCTAssertEqual(exactWithSetDigest.admissionReceipt.requestedCheckIDs, [id])
        XCTAssertEqual(exactWithSetDigest.admissionReceipt.plannedCheckIDs, [id])
        await XCTAssertThrowsErrorAsync({
            try await service.resolve(
                focusedSetID: set.id, requestedCheckIDs: [id],
                expectedSelectionDigest: self.hash("wrong"), admission: self.admission()
            )
        }, { XCTAssertEqual($0 as? FocusedCheckService.Error, .selectionStale) })
        await XCTAssertThrowsErrorAsync({
            try await service.prepare(focusedSetID: set.id, focusedSetDigest: self.hash("wrong-set"))
        }, { XCTAssertEqual($0 as? FocusedCheckService.Error, .selectionStale) })
        await XCTAssertThrowsErrorAsync({
            try await service.resolve(
                focusedSetID: set.id, focusedSetDigest: self.hash("other-set"),
                requestedCheckIDs: [id], expectedSelectionDigest: baseline.selectionDigest, admission: self.admission()
            )
        }, { XCTAssertEqual($0 as? FocusedCheckService.Error, .selectionStale) })
    }

    private func request(candidates: [FocusedCheckService.Candidate], coverage: [String] = ["covered"], limitations: [String] = ["none"], expiry: Date = Date.distantFuture) -> FocusedCheckService.CompileRequest { .init(rootIdentity: "root", generation: "g", cursor: "cursor", profileDigest: hash("profile"), manifestIdentity: "manifest", impactArtifactDigest: hash("impact"), coverage: coverage, limitations: limitations, candidates: candidates, expiresAt: expiry) }
    private func admission(cursor: String = "cursor") -> FocusedCheckService.Admission { .init(rootIdentity: "root", generation: "g", cursor: cursor, profileDigest: hash("profile"), manifestIdentity: "manifest", impactArtifactDigest: hash("impact")) }
    private func candidate(check: String = "check", steps: [FocusedCheckService.Step]? = nil, evidence: [FocusedCheckService.Evidence]? = nil) -> FocusedCheckService.Candidate { .init(profileCheckID: check, profileDigest: hash("profile"), selector: .testPath(path: "Tests/\(check).swift"), steps: steps ?? [step("\(check)-step")], evidence: evidence ?? [self.evidence("one")]) }
    private func step(_ id: String, dependsOn: [String] = [], ordinal: Int? = nil) -> FocusedCheckService.Step { .init(id: id, descriptorDigest: hash(id), dependsOn: dependsOn, ordinal: ordinal) }
    private func evidence(_ id: String) -> FocusedCheckService.Evidence { .init(id: id, provenance: .init(providerID: "impact", providerVersion: "1", artifactDigest: hash("artifact-\(id)"), freshness: "fresh")) }
    private func hash(_ string: String) -> String {
        let total = string.utf8.reduce(0) { ($0 + Int($1)) % 6 }
        return String(repeating: Character(String(UnicodeScalar(97 + total)!)), count: 64)
    }
}

private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 0) }

private func XCTAssertThrowsErrorAsync<T>(_ expression: @escaping () async throws -> T, _ handler: @escaping (Swift.Error) -> Void) async {
    do { _ = try await expression(); XCTFail("error expected") } catch { handler(error) }
}
