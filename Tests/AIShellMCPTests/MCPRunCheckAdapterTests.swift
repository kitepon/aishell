import AIShellCore
import Foundation
import XCTest
@testable import AIShellMCP

final class MCPRunCheckAdapterTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    func testLegacyPreservesDefaultsAndV2MapsEveryInvocationVariant() throws {
        let legacy = try MCPRunCheckAdapter.runCheck(arguments: ["executable": .string("swift")])
        guard case let .legacy(value) = legacy else { return XCTFail("v1 requestではない") }
        XCTAssertEqual(value.timeoutSeconds, 120)
        XCTAssertEqual(value.retentionSeconds, 86_400)
        let fractional = try MCPRunCheckAdapter.runCheck(arguments: [
            "executable": .string("swift"), "timeout_seconds": .number(0.1005), "retention_seconds": .number(1.5)
        ])
        guard case let .legacy(fractionalValue) = fractional else { return XCTFail("v1 requestではない") }
        XCTAssertEqual(fractionalValue.timeoutSeconds, 0.1005)
        XCTAssertEqual(fractionalValue.retentionSeconds, 1.5)

        let direct = try runCheck(invocation: ["mode": .string("direct"), "executable": .string("swift")], cache: "off", selection: ["binding": .string("prepare")])
        guard case let .v2(directV2) = direct, case .direct = directV2.invocation, case .prepare = directV2.selection else { return XCTFail("directの変換に失敗") }
        let profile = try runCheck(invocation: ["mode": .string("profile_check"), "project_id": .string("p"), "profile_digest": .string(digest), "check_id": .string("unit")], cache: "prefer", selection: ["binding": .string("prepare")])
        guard case let .v2(profileV2) = profile, case .profileCheck = profileV2.invocation, case .prepare = profileV2.selection else { return XCTFail("profile prepare intentを保持していない") }
        let focused = try runCheck(invocation: ["mode": .string("focused_set"), "focused_set_id": .string("set"), "ordered_check_ids": .array([.string("a"), .string("b")])], cache: "only", selection: ["binding": .string("verify_focused_set"), "focused_set_digest": .string(digest), "selection_digest": .string(digest)])
        guard case let .v2(focusedV2) = focused, case let .focusedSet(set, selection) = focusedV2.selection else { return XCTFail("focusedのdigestを保持していない") }
        XCTAssertEqual(set, digest); XCTAssertEqual(selection, digest)
        let preparedFocused = try runCheck(invocation: ["mode": .string("focused_set"), "focused_set_id": .string("set"), "ordered_check_ids": .array([.string("a")])], cache: "refresh", selection: ["binding": .string("prepare_focused_set"), "focused_set_digest": .string(digest)])
        guard case let .v2(preparedFocusedV2) = preparedFocused, case let .prepareFocusedSet(set) = preparedFocusedV2.selection else { return XCTFail("focused preparation intentを保持していない") }
        XCTAssertEqual(set, digest)
    }

    func testRunCheckRejectsClosedWireViolationsAtRuntime() throws {
        XCTAssertThrowsError(try MCPRunCheckAdapter.runCheck(arguments: ["schema": .string("aishell.run-check.v2"), "executable": .string("swift")]))
        var request = v2(invocation: ["mode": .string("focused_set"), "focused_set_id": .string("set"), "ordered_check_ids": .array([.string("x"), .string("x")])], cache: "only", selection: ["binding": .string("verify_focused_set"), "focused_set_digest": .string(digest), "selection_digest": .string(digest)])
        XCTAssertThrowsError(try MCPRunCheckAdapter.runCheck(arguments: request))
        request = v2(invocation: ["mode": .string("direct"), "executable": .string("swift"), "unknown": .bool(true)], cache: "off", selection: ["binding": .string("prepare")])
        XCTAssertThrowsError(try MCPRunCheckAdapter.runCheck(arguments: request))
        request = v2(invocation: ["mode": .string("direct"), "executable": .string("swift")], cache: "prefer", selection: ["binding": .string("prepare")])
        XCTAssertThrowsError(try MCPRunCheckAdapter.runCheck(arguments: request))
        request = v2(invocation: ["mode": .string("focused_set"), "focused_set_id": .string("set"), "ordered_check_ids": .array([.string("x")])], cache: "refresh", selection: ["binding": .string("prepare_focused_set"), "focused_set_digest": .string(digest), "selection_digest": .string(digest)])
        XCTAssertThrowsError(try MCPRunCheckAdapter.runCheck(arguments: request))
        request = v2(invocation: ["mode": .string("profile_check"), "project_id": .string("p"), "profile_digest": .string(String(repeating: "١", count: 32)), "check_id": .string("unit")], cache: "off", selection: ["binding": .string("prepare")])
        XCTAssertThrowsError(try MCPRunCheckAdapter.runCheck(arguments: request))
        request = v2(invocation: ["mode": .string("direct"), "executable": .string(String(repeating: "x", count: 4_097))], cache: "off", selection: ["binding": .string("prepare")])
        XCTAssertThrowsError(try MCPRunCheckAdapter.runCheck(arguments: request))
    }

    func testChangeImpactMapsAnalyzeRecommendAndContinuationWithoutServiceCall() throws {
        let path: JSONValue = .object(["path": .string("Sources/A.swift"), "content_sha256": .string(digest)])
        let analyze = try MCPRunCheckAdapter.changeImpact(arguments: ["operation": .string("analyze"), "workspace_cursor": .string("cursor"), "changed_paths": .array([path])])
        guard case let .analyze(request) = analyze else { return XCTFail("analyzeではない") }
        XCTAssertEqual(request.workspaceCursor, "cursor")
        let recommend = try MCPRunCheckAdapter.changeImpact(arguments: ["operation": .string("recommend"), "workspace_cursor": .string("cursor"), "changed_paths": .array([path]), "project_id": .string("p"), "profile_digest": .string(digest)])
        guard case let .recommend(request) = recommend else { return XCTFail("recommendではない") }
        XCTAssertEqual(request.projectID, "p")
        let continuation = try MCPRunCheckAdapter.changeImpact(arguments: ["continuation": .string("opaque"), "byte_budget": .number(65_536)])
        guard case let .continuation(value) = continuation else { return XCTFail("continuationではない") }
        XCTAssertEqual(value.token, "opaque")
        XCTAssertEqual(value.byteBudget, 65_536)
    }

    func testChangeImpactRejectsUnknownMixedBadBindingAndRanges() throws {
        let base: [String: JSONValue] = ["operation": .string("analyze"), "workspace_cursor": .string("cursor"), "changed_paths": .array([.object(["path": .string("A"), "content_sha256": .string(digest)])])]
        XCTAssertThrowsError(try MCPRunCheckAdapter.changeImpact(arguments: base.merging(["future": .bool(true)]) { _, new in new }))
        XCTAssertThrowsError(try MCPRunCheckAdapter.changeImpact(arguments: base.merging(["project_id": .string("p"), "profile_digest": .string(digest)]) { _, new in new }))
        XCTAssertThrowsError(try MCPRunCheckAdapter.changeImpact(arguments: ["continuation": .string("opaque"), "operation": .string("analyze")]))
        XCTAssertThrowsError(try MCPRunCheckAdapter.changeImpact(arguments: ["operation": .string("analyze"), "workspace_cursor": .string("cursor"), "changed_paths": .array([.object(["path": .string("A"), "content_sha256": .string("BAD")])])]))
        XCTAssertThrowsError(try MCPRunCheckAdapter.changeImpact(arguments: ["operation": .string("analyze"), "workspace_cursor": .string("cursor"), "changed_symbols": .array([.object(["path": .string("A"), "content_sha256": .string(digest), "name": .string("A"), "start_offset": .number(2), "end_offset": .number(2)])])]))
        XCTAssertThrowsError(try MCPRunCheckAdapter.runCheck(arguments: ["executable": .string("swift"), "retention_seconds": .number(604_801)]))
    }

    private func runCheck(invocation: [String: JSONValue], cache: String, selection: [String: JSONValue]) throws -> MCPRunCheckAdapter.RunCheckRequest {
        try MCPRunCheckAdapter.runCheck(arguments: v2(invocation: invocation, cache: cache, selection: selection))
    }
    private func v2(invocation: [String: JSONValue], cache: String, selection: [String: JSONValue]) -> [String: JSONValue] {
        ["schema": .string("aishell.run-check.v2"), "invocation": .object(invocation), "dispatch": .object(["mode": .string("sync")]), "cache": .string(cache), "execution_policy": .object(["timeout_ms": .number(120_000), "retention_seconds": .number(86_400)]), "selection": .object(selection)]
    }
}
