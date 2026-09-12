import CryptoKit
import XCTest
@testable import AIShellCore

final class RunCheckInvocationPlanTests: XCTestCase {
    func testLegalityMatrixAllows18AndRejectsOnlyCachedDirectCombinations() throws {
        let selection = digest("selection")
        let invocations: [RunCheckInvocationPlan.Invocation] = [
            .direct(.init(executable: "/usr/bin/swift", arguments: ["test"], workingDirectory: "/repo", effectiveEnvironment: [:])),
            .profileCheck(.init(projectID: "project", profileDigest: digest("profile"), checkID: "test")),
            .focusedSet(.init(setID: "set", orderedCheckIDs: ["unit", "lint"])),
        ]
        let dispatches: [RunCheckInvocationPlan.Dispatch] = [.sync, .start(clientRunKey: "client-key")]
        var accepted = 0
        var rejected = 0

        for invocation in invocations {
            for dispatch in dispatches {
                for cachePolicy in RunCheckInvocationPlan.CachePolicy.allCases {
                    let request = RunCheckInvocationPlan.V2Request(
                        invocation: invocation, dispatch: dispatch, cachePolicy: cachePolicy, selectionDigest: selection
                    )
                    if case .direct = invocation, cachePolicy != .off {
                        XCTAssertThrowsError(try RunCheckInvocationPlan.compile(.v2(request))) { error in
                            XCTAssertEqual(error as? RunCheckInvocationPlan.Error, .cacheNotAllowed)
                            XCTAssertEqual((error as? RunCheckInvocationPlan.Error)?.code, "RUN_CHECK_CACHE_NOT_ALLOWED")
                        }
                        rejected += 1
                    } else {
                        _ = try RunCheckInvocationPlan.compile(.v2(request))
                        accepted += 1
                    }
                }
            }
        }

        XCTAssertEqual(accepted, 18)
        XCTAssertEqual(rejected, 6)
    }

    func testLegacyDirectNormalizesOnlyToDirectSyncOffAndIsDeterministic() throws {
        let first = RunCheckInvocationPlan.LegacyDirectRequest(
            executable: "/usr/bin/swift", arguments: ["test", "--filter", "A:B"], workingDirectory: "/repo",
            effectiveEnvironment: ["Z": "last", "A": "first"]
        )
        let reorderedEnvironment = RunCheckInvocationPlan.LegacyDirectRequest(
            executable: "/usr/bin/swift", arguments: ["test", "--filter", "A:B"], workingDirectory: "/repo",
            effectiveEnvironment: ["A": "first", "Z": "last"]
        )
        let plan = try RunCheckInvocationPlan.compile(.legacyDirect(first))
        let equivalent = try RunCheckInvocationPlan.compile(.legacyDirect(reorderedEnvironment))

        XCTAssertEqual(plan.dispatch, .sync)
        XCTAssertEqual(plan.cachePolicy, .off)
        guard case let .direct(direct) = plan.invocation else { return XCTFail("v1 を別 invocation へ推測変換してはいけません") }
        XCTAssertEqual(direct.arguments, ["test", "--filter", "A:B"])
        XCTAssertEqual(plan.digest, equivalent.digest)
        XCTAssertEqual(plan.requestDigest, equivalent.requestDigest)
        XCTAssertEqual(plan.selectionDigest.count, 64)
    }

    func testPreparedDirectAndProfileDoNotRequireCallerSelectionDigest() throws {
        let direct = try RunCheckInvocationPlan.prepare(.init(
            invocation: .direct(.init(executable: "/usr/bin/swift", arguments: ["test"], workingDirectory: "/repo", effectiveEnvironment: [:])),
            dispatch: .sync,
            cachePolicy: .off
        ))
        let profileInvocation = RunCheckInvocationPlan.Invocation.profileCheck(
            .init(projectID: "project", profileDigest: digest("profile"), checkID: "test")
        )
        let profile = try RunCheckInvocationPlan.prepare(.init(
            invocation: profileInvocation,
            dispatch: .start(clientRunKey: "run"),
            cachePolicy: .prefer
        ))
        XCTAssertEqual(direct.selectionDigest, RunCheckInvocationPlan.canonicalSelectionDigest(for: direct.invocation))
        XCTAssertEqual(profile.selectionDigest, RunCheckInvocationPlan.canonicalSelectionDigest(for: profileInvocation))
        let legacyV2Profile = try RunCheckInvocationPlan.compile(.v2(.init(
            invocation: profileInvocation,
            dispatch: .start(clientRunKey: "run"),
            cachePolicy: .prefer,
            selectionDigest: digest("caller-does-not-matter")
        )))
        XCTAssertEqual(profile, legacyV2Profile)
        XCTAssertThrowsError(try RunCheckInvocationPlan.prepare(.init(
            invocation: .focusedSet(.init(setID: "set", orderedCheckIDs: ["check"])), dispatch: .sync, cachePolicy: .off
        )))
    }

    func testMixedV1AndV2AndInvalidClosedUnionMaterialFailBeforeAdmission() {
        let legacy = RunCheckInvocationPlan.LegacyDirectRequest(
            executable: "/usr/bin/swift", arguments: [], workingDirectory: "/repo", effectiveEnvironment: [:]
        )
        let v2 = RunCheckInvocationPlan.V2Request(
            invocation: .profileCheck(.init(projectID: "project", profileDigest: digest("profile"), checkID: "test")),
            dispatch: .sync, cachePolicy: .prefer, selectionDigest: digest("selection")
        )
        XCTAssertThrowsError(try RunCheckInvocationPlan.compile(.mixed(legacy: legacy, v2: v2))) { error in
            XCTAssertEqual(error as? RunCheckInvocationPlan.Error, .invocationInvalid)
            XCTAssertEqual((error as? RunCheckInvocationPlan.Error)?.code, "RUN_CHECK_INVOCATION_INVALID")
        }

        let duplicateFocused = RunCheckInvocationPlan.V2Request(
            invocation: .focusedSet(.init(setID: "set", orderedCheckIDs: ["same", "same"])),
            dispatch: .sync, cachePolicy: .off, selectionDigest: digest("selection")
        )
        XCTAssertThrowsError(try RunCheckInvocationPlan.compile(.v2(duplicateFocused))) { error in
            XCTAssertEqual(error as? RunCheckInvocationPlan.Error, .invocationInvalid)
        }

        let badStart = RunCheckInvocationPlan.V2Request(
            invocation: .focusedSet(.init(setID: "set", orderedCheckIDs: ["test"])),
            dispatch: .start(clientRunKey: ""), cachePolicy: .off, selectionDigest: digest("selection")
        )
        XCTAssertThrowsError(try RunCheckInvocationPlan.compile(.v2(badStart))) { error in
            XCTAssertEqual(error as? RunCheckInvocationPlan.Error, .invocationInvalid)
        }
    }

    func testPlanDigestUsesCanonicalDirectProfileSelectionAndBindsFocusedSelection() throws {
        let profile = RunCheckInvocationPlan.Invocation.profileCheck(
            .init(projectID: "project", profileDigest: digest("profile"), checkID: "test")
        )
        let baseline = try compile(invocation: profile, dispatch: .sync, cache: .prefer, selection: digest("selection-a"))
        let start = try compile(invocation: profile, dispatch: .start(clientRunKey: "run-1"), cache: .prefer, selection: digest("selection-a"))
        let selectionChanged = try compile(invocation: profile, dispatch: .sync, cache: .prefer, selection: digest("selection-b"))
        let policyChanged = try compile(invocation: profile, dispatch: .sync, cache: .refresh, selection: digest("selection-a"))
        let orderedFirst = try compile(
            invocation: .focusedSet(.init(setID: "set", orderedCheckIDs: ["first", "second"])), dispatch: .sync,
            cache: .prefer, selection: digest("focused")
        )
        let orderedSecond = try compile(
            invocation: .focusedSet(.init(setID: "set", orderedCheckIDs: ["second", "first"])), dispatch: .sync,
            cache: .prefer, selection: digest("focused")
        )

        XCTAssertNotEqual(baseline.digest, start.digest)
        XCTAssertEqual(baseline.digest, selectionChanged.digest)
        XCTAssertEqual(baseline.selectionDigest, RunCheckInvocationPlan.canonicalSelectionDigest(for: profile))
        XCTAssertNotEqual(baseline.digest, policyChanged.digest)
        XCTAssertNotEqual(orderedFirst.digest, orderedSecond.digest)
        XCTAssertNotEqual(baseline.requestDigest, start.requestDigest)
    }

    func testStartKeyUsesUTF8ByteLimitAndCanonicalDigestDistinguishesEmptyArgument() throws {
        let invocation = RunCheckInvocationPlan.Invocation.profileCheck(
            .init(projectID: "project", profileDigest: digest("profile"), checkID: "test")
        )
        let valid128 = try compile(invocation: invocation, dispatch: .start(clientRunKey: String(repeating: "a", count: 128)), cache: .off, selection: digest("selection"))
        XCTAssertEqual(valid128.dispatch, .start(clientRunKey: String(repeating: "a", count: 128)))
        XCTAssertThrowsError(try compile(invocation: invocation, dispatch: .start(clientRunKey: String(repeating: "あ", count: 43)), cache: .off, selection: digest("selection")))

        let empty = try RunCheckInvocationPlan.compile(.legacyDirect(.init(
            executable: "/usr/bin/tool", arguments: [""], workingDirectory: "/repo", effectiveEnvironment: [:]
        )))
        let none = try RunCheckInvocationPlan.compile(.legacyDirect(.init(
            executable: "/usr/bin/tool", arguments: [], workingDirectory: "/repo", effectiveEnvironment: [:]
        )))
        XCTAssertNotEqual(empty.digest, none.digest)
    }

    func testDirectPreservesAbsentWorkingDirectoryAndBindsAllExecutionMaterial() throws {
        let baselineRequest = RunCheckInvocationPlan.LegacyDirectRequest(
            executable: "/usr/bin/tool", arguments: ["first", "second"], workingDirectory: nil,
            effectiveEnvironment: ["MODE": "debug"], executionPolicy: .init(timeoutMilliseconds: 1_000, retentionSeconds: 60)
        )
        let baseline = try RunCheckInvocationPlan.compile(.legacyDirect(baselineRequest))
        guard case let .direct(direct) = baseline.invocation else { return XCTFail("direct を保持します") }
        XCTAssertNil(direct.workingDirectory)

        let realDirectory = try RunCheckInvocationPlan.compile(.legacyDirect(.init(
            executable: "/usr/bin/tool", arguments: ["first", "second"], workingDirectory: "/repo",
            effectiveEnvironment: ["MODE": "debug"], executionPolicy: .init(timeoutMilliseconds: 1_000, retentionSeconds: 60)
        )))
        let reversedArguments = try RunCheckInvocationPlan.compile(.legacyDirect(.init(
            executable: "/usr/bin/tool", arguments: ["second", "first"], workingDirectory: nil,
            effectiveEnvironment: ["MODE": "debug"], executionPolicy: .init(timeoutMilliseconds: 1_000, retentionSeconds: 60)
        )))
        let environmentChanged = try RunCheckInvocationPlan.compile(.legacyDirect(.init(
            executable: "/usr/bin/tool", arguments: ["first", "second"], workingDirectory: nil,
            effectiveEnvironment: ["MODE": "release"], executionPolicy: .init(timeoutMilliseconds: 1_000, retentionSeconds: 60)
        )))
        let timeoutChanged = try RunCheckInvocationPlan.compile(.legacyDirect(.init(
            executable: "/usr/bin/tool", arguments: ["first", "second"], workingDirectory: nil,
            effectiveEnvironment: ["MODE": "debug"], executionPolicy: .init(timeoutMilliseconds: 2_000, retentionSeconds: 60)
        )))
        let retentionChanged = try RunCheckInvocationPlan.compile(.legacyDirect(.init(
            executable: "/usr/bin/tool", arguments: ["first", "second"], workingDirectory: nil,
            effectiveEnvironment: ["MODE": "debug"], executionPolicy: .init(timeoutMilliseconds: 1_000, retentionSeconds: 61)
        )))

        for changed in [realDirectory, reversedArguments, environmentChanged, timeoutChanged, retentionChanged] {
            XCTAssertNotEqual(baseline.digest, changed.digest)
            XCTAssertNotEqual(baseline.requestDigest, changed.requestDigest)
        }

        let emptyDirectory = RunCheckInvocationPlan.LegacyDirectRequest(
            executable: "/usr/bin/tool", arguments: [], workingDirectory: "", effectiveEnvironment: [:]
        )
        XCTAssertThrowsError(try RunCheckInvocationPlan.compile(.legacyDirect(emptyDirectory))) { error in
            XCTAssertEqual(error as? RunCheckInvocationPlan.Error, .invocationInvalid)
        }
    }

    func testProfileDigestAndFocusedSelectionRequireLowercaseASCIISHA256() {
        let lowercase = digest("digest")
        let uppercaseProfile = RunCheckInvocationPlan.V2Request(
            invocation: .profileCheck(.init(projectID: "project", profileDigest: lowercase.uppercased(), checkID: "test")),
            dispatch: .sync, cachePolicy: .off, selectionDigest: lowercase
        )
        let unicodeProfile = RunCheckInvocationPlan.V2Request(
            invocation: .profileCheck(.init(projectID: "project", profileDigest: String(repeating: "ａ", count: 64), checkID: "test")),
            dispatch: .sync, cachePolicy: .off, selectionDigest: lowercase
        )
        let uppercaseFocusedSelection = RunCheckInvocationPlan.V2Request(
            invocation: .focusedSet(.init(setID: "set", orderedCheckIDs: ["check"])),
            dispatch: .sync, cachePolicy: .off, selectionDigest: lowercase.uppercased()
        )
        let unicodeFocusedSelection = RunCheckInvocationPlan.V2Request(
            invocation: .focusedSet(.init(setID: "set", orderedCheckIDs: ["check"])),
            dispatch: .sync, cachePolicy: .off, selectionDigest: String(repeating: "ａ", count: 64)
        )
        let ignoredProfileSelection = RunCheckInvocationPlan.V2Request(
            invocation: .profileCheck(.init(projectID: "project", profileDigest: lowercase, checkID: "test")),
            dispatch: .sync, cachePolicy: .off, selectionDigest: lowercase.uppercased()
        )

        for request in [uppercaseProfile, unicodeProfile, uppercaseFocusedSelection, unicodeFocusedSelection] {
            XCTAssertThrowsError(try RunCheckInvocationPlan.compile(.v2(request))) { error in
                XCTAssertEqual(error as? RunCheckInvocationPlan.Error, .invocationInvalid)
            }
        }
        XCTAssertNoThrow(try RunCheckInvocationPlan.compile(.v2(ignoredProfileSelection)))
    }

    private func compile(
        invocation: RunCheckInvocationPlan.Invocation,
        dispatch: RunCheckInvocationPlan.Dispatch,
        cache: RunCheckInvocationPlan.CachePolicy,
        selection: String
    ) throws -> RunCheckInvocationPlan {
        try RunCheckInvocationPlan.compile(.v2(.init(
            invocation: invocation, dispatch: dispatch, cachePolicy: cache, selectionDigest: selection
        )))
    }

    private func digest(_ value: String) -> String {
        importDigest(value)
    }
}

private func importDigest(_ value: String) -> String {
    let data = Data(value.utf8)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
