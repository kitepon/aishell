import CryptoKit
import AIShellCore
import Foundation
import XCTest
@testable import AIShellMCP

final class MCPRunCheckV2WireTests: XCTestCase {
    func testDirectDiagnosticAdapterReturnsStructuredSARIFAndFailsClosedOnMalformedInput() async throws {
        let fixture = try await MCPRunCheckWireFixture.make()
        defer { fixture.cleanup() }
        let server = MCPServer(runtimeStore: fixture.store, capabilitySet: "expanded-v1")
        let valid = fixture.root.appendingPathComponent("result.sarif")
        try Data(#"{"runs":[{"results":[{"level":"error","message":{"text":"boom"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"src/a.swift"},"region":{"startLine":3}}}]}]}]}"#.utf8)
            .write(to: valid)

        let success = await server.callTool(id: .number(1), params: .object([
            "name": .string("run_check"),
            "arguments": .object(v2Direct(
                executable: "/bin/cat",
                workingDirectory: fixture.root.path,
                dispatch: ["mode": .string("sync")],
                arguments: [valid.lastPathComponent],
                diagnosticAdapter: "sarif"
            ))
        ]))
        let successResult = try XCTUnwrap(success.result?.objectValue)
        let diagnostics = try XCTUnwrap(
            successResult["structuredContent"]?.objectValue?["diagnostics"]?.objectValue
        )
        XCTAssertEqual(successResult["isError"], .bool(false))
        XCTAssertEqual(diagnostics["format"], .string("sarif"))
        XCTAssertEqual(diagnostics["diagnostics"]?.arrayValue?.first?.objectValue?["message"], .string("boom"))

        try Data("{broken\n".utf8).write(to: valid, options: .atomic)
        let malformed = await server.callTool(id: .number(2), params: .object([
            "name": .string("run_check"),
            "arguments": .object(v2Direct(
                executable: "/bin/cat",
                workingDirectory: fixture.root.path,
                dispatch: ["mode": .string("sync")],
                arguments: [valid.lastPathComponent],
                diagnosticAdapter: "sarif"
            ))
        ]))
        let malformedResult = try XCTUnwrap(malformed.result?.objectValue)
        XCTAssertEqual(malformedResult["isError"], .bool(true))
        XCTAssertEqual(
            malformedResult["structuredContent"]?.objectValue?["error"]?.objectValue?["code"],
            .string("DIAGNOSTIC_PARSE_FAILED")
        )
    }

    func testLegacyAndV2DirectReachRuntimeWithoutChangingV1Shape() async throws {
        let fixture = try await MCPRunCheckWireFixture.make()
        defer { fixture.cleanup() }
        let server = MCPServer(runtimeStore: fixture.store, capabilitySet: "expanded-v1")

        let legacy = await server.callTool(id: .number(1), params: .object([
            "name": .string("run_check"),
            "arguments": .object([
                "executable": .string("/usr/bin/true"),
                "working_directory": .string(fixture.root.path),
                "timeout_seconds": .number(0.1005),
                "retention_seconds": .number(1.5)
            ])
        ]))
        let legacyResult = try XCTUnwrap(legacy.result?.objectValue)
        XCTAssertEqual(legacyResult["isError"], .bool(false))
        XCTAssertEqual(
            legacyResult["structuredContent"]?.objectValue?["schemaVersion"],
            .string("aishell.run-check.v1")
        )

        let v2 = await server.callTool(id: .number(2), params: .object([
            "name": .string("run_check"),
            "arguments": .object(v2Direct(
                executable: "/usr/bin/true",
                workingDirectory: fixture.root.path,
                dispatch: ["mode": .string("sync")]
            ))
        ]))
        let v2Result = try XCTUnwrap(v2.result?.objectValue)
        let structured = try XCTUnwrap(v2Result["structuredContent"]?.objectValue)
        XCTAssertEqual(v2Result["isError"], .bool(false))
        XCTAssertEqual(structured["schemaVersion"], .string("aishell.run-check.v2"))
        XCTAssertEqual(structured["processesStarted"], .number(1))
        XCTAssertEqual(structured["cacheState"], .string("disabled"))
        XCTAssertEqual(structured["steps"]?.arrayValue?.first?.objectValue?["terminalState"], .string("passed"))
        let summary = try XCTUnwrap(v2Result["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        XCTAssertTrue(summary.contains("passed=1 failed=0 complete_diagnostics_retained=true"))
        XCTAssertTrue(summary.contains("artifact_read is unnecessary"))
    }

    func testDirectStartAndRunObserveReachManagedSidecarThroughPublicWire() async throws {
        let fixture = try await MCPRunCheckWireFixture.make()
        defer { fixture.cleanup() }
        let managed = try ManagedRunService(
            runtimeStore: fixture.store,
            supervisorExecutableURL: try fixture.supervisorBinary()
        )
        let server = MCPServer(
            runtimeStore: fixture.store,
            capabilitySet: "expanded-v1",
            managedRunService: managed
        )
        let response = await server.callTool(id: .number(1), params: .object([
            "name": .string("run_check"),
            "arguments": .object(v2Direct(
                executable: "/usr/bin/python3",
                workingDirectory: fixture.root.path,
                dispatch: ["mode": .string("start"), "client_run_key": .string("wire-start")],
                arguments: ["-c", "import time; print('wire one',flush=True); print('wire two',flush=True); time.sleep(.2)"]
            ))
        ]))
        let result = try XCTUnwrap(response.result?.objectValue)
        let structured = try XCTUnwrap(result["structuredContent"]?.objectValue)
        XCTAssertEqual(result["isError"], .bool(false))
        XCTAssertEqual(structured["schemaVersion"], .string("aishell.run-check.v2"))
        XCTAssertEqual(structured["dispatch"], .string("start"))
        XCTAssertEqual(structured["planDigest"]?.stringValue?.count, 64)
        XCTAssertEqual(structured["environmentDigest"]?.stringValue?.count, 64)
        XCTAssertEqual(structured["executable"], .string("/usr/bin/python3"))
        XCTAssertEqual(structured["workingDirectory"], .string(fixture.root.path))
        XCTAssertNotNil(structured["startedAt"])
        XCTAssertNotNil(structured["timeoutDeadline"])
        XCTAssertEqual(structured["retentionSeconds"], .number(3_600))
        XCTAssertEqual(structured["state"], .string("running"))
        let handle = try XCTUnwrap(structured["runHandle"]?.stringValue)

        let read = await server.callTool(id: .number(2), params: .object([
            "name": .string("run_observe"),
            "arguments": .object([
                "action": .string("wait"), "run_handle": .string(handle),
                "after_state_revision": structured["stateRevision"]!, "timeout_ms": .number(5_000)
            ])
        ]))
        let waited = try XCTUnwrap(read.result?.objectValue?["structuredContent"]?.objectValue)
        XCTAssertEqual(read.result?.objectValue?["isError"], .bool(false))
        XCTAssertEqual(waited["schema"], .string("aishell.run-observe-wait.v1"))
        XCTAssertEqual(waited["outcome"], .string("changed"))

        let evidence = await server.callTool(id: .number(3), params: .object([
            "name": .string("run_observe"),
            "arguments": .object([
                "action": .string("read"), "run_handle": .string(handle),
                "byte_budget": .number(65_536)
            ])
        ]))
        let evidenceResult = try XCTUnwrap(evidence.result?.objectValue?["structuredContent"]?.objectValue)
        XCTAssertEqual(evidenceResult["schema"], .string("aishell.run-observe-read.v1"))
        XCTAssertTrue(evidenceResult["chunks"]?.arrayValue?.contains {
            $0.objectValue?["text"]?.stringValue?.contains("wire") == true
        } == true)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            let status = try await managed.status(runHandle: handle)
            if ["passed", "failed", "timed_out", "cancelled", "interrupted"].contains(status.state) {
                break
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        let terminal = try await managed.status(runHandle: handle)
        XCTAssertEqual(terminal.state, "passed")

        let restartedServer = MCPServer(runtimeStore: fixture.store, capabilitySet: "expanded-v1")
        for (identity, text) in [(try XCTUnwrap(terminal.stdoutArtifact), "wire one\nwire two\n"),
                                  (try XCTUnwrap(terminal.stderrArtifact), "")] {
            let read = await restartedServer.callTool(id: .number(40), params: .object([
                "name": .string("artifact_read"),
                "arguments": .object(["handle": .string(identity.handle), "byte_budget": .number(128)])
            ]))
            let result = try XCTUnwrap(read.result?.objectValue)
            XCTAssertEqual(result["isError"], .bool(false), "\(result)")
            let slice = try XCTUnwrap(result["structuredContent"]?.objectValue)
            XCTAssertEqual(result["content"]?.arrayValue?.first?.objectValue?["text"], .string(text))
            XCTAssertEqual(slice["totalBytes"], .number(Double(identity.sizeBytes)))
            XCTAssertEqual(slice["sha256"], .string(identity.sha256))
        }

        // 旧版はartifact索引の期限を省略していた。runの保持契約から同じ期限で読める。
        let index = fixture.store.baseDirectory.appendingPathComponent("managed-runs/artifacts/published")
            .appendingPathComponent(terminal.runID.uuidString.lowercased()).appendingPathComponent("registry-index.json")
        var oldIndex = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        XCTAssertNotNil(oldIndex.removeValue(forKey: "expiresAt"))
        try JSONSerialization.data(withJSONObject: oldIndex, options: [.sortedKeys]).write(to: index)
        let legacyRead = await restartedServer.callTool(id: .number(41), params: .object([
            "name": .string("artifact_read"), "arguments": .object([
                "handle": .string(try XCTUnwrap(terminal.stdoutArtifact).handle), "mode": .string("tail"),
                "tail_lines": .number(1), "byte_budget": .number(128)
            ])
        ]))
        XCTAssertEqual(legacyRead.result?.objectValue?["isError"], .bool(false))
        XCTAssertEqual(legacyRead.result?.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"], .string("wire two\n"))

        let search = await server.callTool(id: .number(4), params: .object([
            "name": .string("artifact_read"),
            "arguments": .object([
                "action": .string("search"),
                "project_path": .string(fixture.root.path),
                "sources": .array([.object([
                    "type": .string("run"),
                    "run_id": .string(terminal.runID.uuidString),
                    "channels": .array([.string("stdout")])
                ])]),
                "pattern_kind": .string("literal"),
                "pattern": .string("wire"),
                "case": .string("sensitive"),
                "page_byte_limit": .number(1)
            ])
        ]))
        let searchResult = try XCTUnwrap(search.result?.objectValue)
        let searchStructured = try XCTUnwrap(searchResult["structuredContent"]?.objectValue)
        XCTAssertEqual(searchResult["isError"], .bool(false))
        XCTAssertEqual(searchStructured["schema"], .string("aishell.artifact-read.v2"))
        XCTAssertEqual(searchStructured["action"], .string("search"))
        XCTAssertEqual(searchStructured["items"]?.arrayValue?.count, 1)
        XCTAssertEqual(searchStructured["hasMore"], .bool(true))
        let next = await server.callTool(id: .number(5), params: .object([
            "name": .string("artifact_read"),
            "arguments": .object([
                "action": .string("next"),
                "stream_handle": searchStructured["streamHandle"]!,
                "cursor": searchStructured["nextCursor"]!,
                "page_byte_limit": .number(1)
            ])
        ]))
        let nextStructured = try XCTUnwrap(next.result?.objectValue?["structuredContent"]?.objectValue)
        XCTAssertEqual(next.result?.objectValue?["isError"], .bool(false))
        XCTAssertEqual(nextStructured["items"]?.arrayValue?.count, 1)
        XCTAssertEqual(nextStructured["hasMore"], .bool(false))

        let compare = await server.callTool(id: .number(6), params: .object([
            "name": .string("artifact_read"),
            "arguments": .object([
                "action": .string("compare"),
                "project_path": .string(fixture.root.path),
                "baseline_run_id": .string(terminal.runID.uuidString),
                "candidate_run_id": .string(terminal.runID.uuidString),
                "channels": .array([.string("stdout"), .string("stderr")])
            ])
        ]))
        let compareStructured = try XCTUnwrap(
            compare.result?.objectValue?["structuredContent"]?.objectValue
        )
        XCTAssertEqual(compare.result?.objectValue?["isError"], .bool(false))
        XCTAssertEqual(compareStructured["action"], .string("compare"))
        XCTAssertEqual(compareStructured["comparisons"]?.arrayValue?.count, 2)
    }

    func testChangeImpactAnalyzeRunsThroughExpandedPublicWire() async throws {
        let fixture = try await MCPRunCheckWireFixture.make()
        defer { fixture.cleanup() }
        let sourceDirectory = fixture.root.appendingPathComponent("src", isDirectory: true)
        let testDirectory = fixture.root.appendingPathComponent("test", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("a.mjs")
        let bytes = Data("export const a = 2\n".utf8)
        try bytes.write(to: source)
        try Data("import { a } from './a.mjs'\nexport const b = a\n".utf8)
            .write(to: sourceDirectory.appendingPathComponent("b.mjs"))
        try Data("import { b } from '../src/b.mjs'\n".utf8)
            .write(to: testDirectory.appendingPathComponent("b.test.mjs"))
        let server = MCPServer(runtimeStore: fixture.store, capabilitySet: "expanded-v1")
        let snapshot = await server.callTool(id: .number(1), params: .object([
            "name": .string("workspace_snapshot"),
            "arguments": .object(["path": .string(fixture.root.path)])
        ]))
        let cursor = try XCTUnwrap(
            snapshot.result?.objectValue?["structuredContent"]?.objectValue?["cursor"]?.stringValue
        )
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let response = await server.callTool(id: .number(2), params: .object([
            "name": .string("change_impact"),
            "arguments": .object([
                "operation": .string("analyze"),
                "root": .string(fixture.root.path),
                "workspace_cursor": .string(cursor),
                "changed_paths": .array([.object([
                    "path": .string("src/a.mjs"),
                    "content_sha256": .string(digest)
                ])]),
                "required_providers": .array([.string("static-import")])
            ])
        ]))
        let result = try XCTUnwrap(response.result?.objectValue)
        XCTAssertEqual(result["isError"], .bool(false))
        XCTAssertEqual(
            result["structuredContent"]?.objectValue?["schemaVersion"],
            .string("aishell.change-impact.v2")
        )
        XCTAssertEqual(result["structuredContent"]?.objectValue?["operation"], .string("analyze"))
        XCTAssertEqual(result["structuredContent"]?.objectValue?["continuation"], .null)
        let structured = try XCTUnwrap(result["structuredContent"])
        let artifact = try XCTUnwrap(structured.objectValue?["artifact"]?.objectValue)
        let handle = try XCTUnwrap(artifact["handle"]?.stringValue)
        let size = try XCTUnwrap(artifact["sizeBytes"]?.intValue)
        let evidence = EvidenceStore(
            baseDirectory: fixture.store.baseDirectory.appendingPathComponent("evidence", isDirectory: true)
        )
        let slice = try await evidence.read(
            handle: handle,
            mode: .range(offset: 0, length: size),
            byteBudget: size
        )
        let artifactBytes = try XCTUnwrap(slice.text).data(using: .utf8)!
        try assertBenchmarkAdapterAcceptsProductionResult(
            structured,
            frozenRequest: .object([
                "action": .string("analyze"),
                "changed_paths": .array([.string("src/a.mjs")]),
                "providers": .array([.string("static-import")]),
            ]),
            artifactBytes: artifactBytes
        )
    }

    func testRecommendationFocusedSetRunsThroughSameRuntimeWithoutCallerSelectionHash() async throws {
        let fixture = try await MCPRunCheckWireFixture.make()
        defer { fixture.cleanup() }
        let otherRoot = fixture.base.appendingPathComponent("OtherProject", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        try Data("{\"name\":\"other-project\",\"version\":\"1.0.0\"}\n".utf8)
            .write(to: otherRoot.appendingPathComponent("package.json"))
        await fixture.store.setWorkingDirectoryForTesting(fixture.root)
        let sourceDirectory = fixture.root.appendingPathComponent("Sources/WireFocused", isDirectory: true)
        let testDirectory = fixture.root.appendingPathComponent("Tests/WireFocusedTests", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        try Data("public struct Changed {}\n".utf8)
            .write(to: sourceDirectory.appendingPathComponent("Changed.swift"))
        try Data("import XCTest\n@testable import WireFocused\nfinal class ChangedTests: XCTestCase {}\n".utf8)
            .write(to: testDirectory.appendingPathComponent("ChangedTests.swift"))
        try Data("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "WireFocused",
            targets: [
                .target(name: "WireFocused"),
                .testTarget(name: "WireFocusedTests", dependencies: ["WireFocused"])
            ]
        )
        """.utf8).write(to: fixture.root.appendingPathComponent("Package.swift"))

        let workspace = WorkspaceStateRuntime(runtimeStore: fixture.store, startsFSEvents: false)
        let evidence = EvidenceStore(baseDirectory: fixture.base.appendingPathComponent("evidence"))
        let focused = FocusedCheckService()
        let profiles = ProjectProfileService(
            runtimeStore: fixture.store,
            workspaceRuntime: workspace,
            evidenceStore: evidence
        )
        let development = DevelopmentRuntimeService(
            runtimeStore: fixture.store,
            evidenceStore: evidence,
            workspaceRuntime: workspace,
            focusedChecks: focused,
            projectProfiles: profiles
        )
        let otherSnapshot = try await workspace.snapshot(path: otherRoot.path, contextBudget: 0)
        _ = try await profiles.catalog(for: otherSnapshot)
        let snapshot = try await workspace.snapshot(path: fixture.root.path, contextBudget: 0)
        let catalog = try await profiles.catalog(for: snapshot)
        let profile = try XCTUnwrap(catalog.profiles.first)
        let changedBytes = try Data(contentsOf: sourceDirectory.appendingPathComponent("Changed.swift"))
        let changedDigest = SHA256.hash(data: changedBytes).map { String(format: "%02x", $0) }.joined()
        let server = MCPServer(
            runtimeStore: fixture.store,
            capabilitySet: "expanded-v1",
            developmentRuntime: development
        )

        let recommendation = await server.callTool(id: .number(1), params: .object([
            "name": .string("change_impact"),
            "arguments": .object([
                "operation": .string("recommend"),
                "root": .string(fixture.root.path),
                "workspace_cursor": .string(catalog.observedCursor),
                "changed_paths": .array([.object([
                    "path": .string("Sources/WireFocused/Changed.swift"),
                    "content_sha256": .string(changedDigest)
                ])]),
                "project_id": .string(profile.projectId),
                "profile_digest": .string(profile.profileDigest),
                "byte_budget": .number(1_048_576)
            ])
        ]))
        let recommendationResult = try XCTUnwrap(recommendation.result?.objectValue)
        let recommended = try XCTUnwrap(recommendationResult["structuredContent"]?.objectValue)
        guard recommendationResult["isError"] == .bool(false) else {
            return XCTFail("recommend failed: \(recommended)")
        }
        let focusedSetID = try XCTUnwrap(recommended["focusedSetID"]?.stringValue)
        let focusedSetDigest = try XCTUnwrap(recommended["focusedSetDigest"]?.stringValue)
        XCTAssertEqual(recommended["continuation"], .null)
        let items = try XCTUnwrap(recommended["items"]?.arrayValue)
        let recommendationArtifact = try XCTUnwrap(recommended["artifact"]?.objectValue)
        let recommendationHandle = try XCTUnwrap(recommendationArtifact["handle"]?.stringValue)
        let recommendationSize = try XCTUnwrap(recommendationArtifact["sizeBytes"]?.intValue)
        let recommendationSlice = try await evidence.read(
            handle: recommendationHandle,
            mode: .range(offset: 0, length: recommendationSize),
            byteBudget: recommendationSize
        )
        let recommendationBytes = try XCTUnwrap(recommendationSlice.text).data(using: .utf8)!
        try assertBenchmarkAdapterAcceptsProductionResult(
            .object(recommended),
            frozenRequest: .object([
                "action": .string("recommend"),
                "changed_paths": .array([.string("Sources/WireFocused/Changed.swift")]),
                "providers": .array([.string("static-import")]),
            ]),
            artifactBytes: recommendationBytes
        )
        let candidateID: String = try XCTUnwrap(items.compactMap { item -> String? in
            guard item.objectValue?["kind"] == .string("focused_candidate") else { return nil }
            return item.objectValue?["focusedCheckID"]?.stringValue
        }.first)

        let run = await server.callTool(id: .number(2), params: .object([
            "name": .string("run_check"),
            "arguments": .object([
                "schema": .string("aishell.run-check.v2"),
                "invocation": .object([
                    "mode": .string("focused_set"),
                    "focused_set_id": .string(focusedSetID),
                    "ordered_check_ids": .array([.string(candidateID)])
                ]),
                "dispatch": .object(["mode": .string("sync")]),
                "cache": .string("off"),
                "execution_policy": .object([
                    "timeout_ms": .number(5_000),
                    "retention_seconds": .number(3_600)
                ]),
                "selection": .object([
                    "binding": .string("prepare_focused_set"),
                    "focused_set_digest": .string(focusedSetDigest)
                ])
            ])
        ]))
        let runResult = try XCTUnwrap(run.result?.objectValue)
        let runStructured = try XCTUnwrap(runResult["structuredContent"]?.objectValue)
        XCTAssertEqual(runResult["isError"], .bool(false))
        XCTAssertEqual(runStructured["schemaVersion"], .string("aishell.run-check.v2"))
        XCTAssertEqual(runStructured["requestedCheckIDs"], .array([.string(candidateID)]))
        XCTAssertEqual(runStructured["processesStarted"], .number(1))
        let selectionDigest = try XCTUnwrap(runStructured["selectionDigest"]?.stringValue)

        let verified = await server.callTool(id: .number(3), params: .object([
            "name": .string("run_check"),
            "arguments": .object([
                "schema": .string("aishell.run-check.v2"),
                "invocation": .object([
                    "mode": .string("focused_set"),
                    "focused_set_id": .string(focusedSetID),
                    "ordered_check_ids": .array([.string(candidateID)])
                ]),
                "dispatch": .object(["mode": .string("sync")]),
                "cache": .string("off"),
                "execution_policy": .object([
                    "timeout_ms": .number(5_000),
                    "retention_seconds": .number(3_600)
                ]),
                "selection": .object([
                    "binding": .string("verify_focused_set"),
                    "focused_set_digest": .string(focusedSetDigest),
                    "selection_digest": .string(selectionDigest)
                ])
            ])
        ]))
        let verifiedResult = try XCTUnwrap(verified.result?.objectValue)
        XCTAssertEqual(verifiedResult["isError"], .bool(false))
        XCTAssertEqual(
            verifiedResult["structuredContent"]?.objectValue?["selectionDigest"],
            .string(selectionDigest)
        )

        try await profiles.invalidateAll()
        let stale = await server.callTool(id: .number(4), params: .object([
            "name": .string("run_check"),
            "arguments": .object([
                "schema": .string("aishell.run-check.v2"),
                "invocation": .object([
                    "mode": .string("focused_set"),
                    "focused_set_id": .string(focusedSetID),
                    "ordered_check_ids": .array([.string(candidateID)])
                ]),
                "dispatch": .object(["mode": .string("sync")]),
                "cache": .string("off"),
                "execution_policy": .object([
                    "timeout_ms": .number(5_000),
                    "retention_seconds": .number(3_600)
                ]),
                "selection": .object([
                    "binding": .string("verify_focused_set"),
                    "focused_set_digest": .string(focusedSetDigest),
                    "selection_digest": .string(selectionDigest)
                ])
            ])
        ]))
        let staleResult = try XCTUnwrap(stale.result?.objectValue)
        let staleStructured = try XCTUnwrap(staleResult["structuredContent"]?.objectValue)
        XCTAssertEqual(staleResult["isError"], .bool(true))
        XCTAssertEqual(staleStructured["error"]?.objectValue?["code"], .string("RUN_CHECK_SELECTION_STALE"))
        XCTAssertEqual(staleStructured["error"]?.objectValue?["processesStarted"], .number(0))
    }

    private func v2Direct(
        executable: String,
        workingDirectory: String,
        dispatch: [String: JSONValue],
        arguments: [String] = [],
        diagnosticAdapter: String? = nil
    ) -> [String: JSONValue] {
        var invocation: [String: JSONValue] = [
            "mode": .string("direct"),
            "executable": .string(executable),
            "arguments": .array(arguments.map(JSONValue.string)),
            "working_directory": .string(workingDirectory)
        ]
        if let diagnosticAdapter { invocation["diagnostic_adapter"] = .string(diagnosticAdapter) }
        return [
            "schema": .string("aishell.run-check.v2"),
            "invocation": .object(invocation),
            "dispatch": .object(dispatch),
            "cache": .string("off"),
            "execution_policy": .object([
                "timeout_ms": .number(5_000),
                "retention_seconds": .number(3_600)
            ]),
            "selection": .object(["binding": .string("prepare")])
        ]
    }

    private func assertBenchmarkAdapterAcceptsProductionResult(
        _ result: JSONValue,
        frozenRequest: JSONValue,
        artifactBytes: Data
    ) throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let module = repository.appendingPathComponent("benchmarks/production-v2-benchmark-adapter.mjs")
        let payload = JSONValue.object([
            "frozenRequest": frozenRequest,
            "rawV2Pages": .array([.object(["result": result])]),
            "artifactBase64": .string(artifactBytes.base64EncodedString()),
        ])
        let payloadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aishell-benchmark-adapter-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: payloadURL) }
        try JSONEncoder.aishell.encode(payload).write(to: payloadURL, options: .atomic)

        let script = """
        import { readFileSync } from 'node:fs';
        import { pathToFileURL } from 'node:url';
        const adapter = await import(pathToFileURL(process.argv[1]));
        const payload = JSON.parse(readFileSync(process.argv[2], 'utf8'));
        const projected = adapter.projectProductionV2Result({
          tool: 'change_impact',
          frozenRequest: payload.frozenRequest,
          rawV2Pages: payload.rawV2Pages,
          completeArtifactBytes: Buffer.from(payload.artifactBase64, 'base64'),
        });
        if (projected.schemaVersion !== 'aishell.change-impact.v1') process.exit(3);
        if (payload.frozenRequest.action === 'analyze') {
          const expected = ['src/b.mjs', 'test/b.test.mjs'];
          if (JSON.stringify(projected.impactedPaths) !== JSON.stringify(expected)) process.exit(4);
        }
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--input-type=module", "--eval", script, module.path, payloadURL.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let errorText = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, errorText)
    }
}

private final class MCPRunCheckWireFixture {
    let base: URL
    let root: URL
    let store: RuntimeStore

    private init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("aishell-run-check-wire-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = RuntimeStore(baseDirectory: base.appendingPathComponent("runtime", isDirectory: true))
    }

    static func make() async throws -> MCPRunCheckWireFixture {
        let fixture = try MCPRunCheckWireFixture()
        await fixture.store.setWorkingDirectoryForTesting(fixture.root)
        return fixture
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }

    func supervisorBinary() throws -> URL {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            projectRoot.appendingPathComponent(".build/debug/aishell-run-supervisor"),
            projectRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/aishell-run-supervisor")
        ]
        guard let binary = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else { throw XCTSkip("aishell-run-supervisor productを先にbuildしてください。") }
        return binary
    }
}
