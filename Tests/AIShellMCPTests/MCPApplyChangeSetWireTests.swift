import CryptoKit
import XCTest
@testable import AIShellCore
@testable import AIShellMCP

final class MCPApplyChangeSetWireTests: XCTestCase {
    func testLocalKeyFailureReportsOnlyThisRequestAsAbortedBeforeSideEffect() throws {
        let store = RuntimeStore()
        let server = MCPServer(runtimeStore: store)
        let error = ApplyChangeSetError(.changeSetSecretStoreUnavailable, "ローカル鍵の読取りに失敗")
        let result = server.structuredError(error, stable: server.stableError(error)).objectValue
        XCTAssertEqual(result?["request_status"], .string("aborted_before_side_effect"))
        XCTAssertEqual(result?["changed_paths"], .array([]))
        XCTAssertEqual(result?["next_action"], .string("check_local_state_key_then_retry"))
        XCTAssertNil(result?["recovery_state"])
        XCTAssertNil(result?["transaction_id"])
    }

    func testPublicWorkspaceCursorAppliesManagedTransactionWithoutClientPlumbingOrRescan() async throws {
        try await assertManagedTransactionSurvivesRestart(parent: URL(fileURLWithPath: "/private/tmp", isDirectory: true))
    }

    func testPublicManagedTransactionSurvivesRestartWithoutPathAlias() async throws {
        try await assertManagedTransactionSurvivesRestart(parent: FileManager.default.temporaryDirectory)
    }

    private func assertManagedTransactionSurvivesRestart(parent: URL) async throws {
        // macOSの別名パスでも、状態ファイルの世代交代を同じ保存先として扱う。
        let temporary = parent
            .appendingPathComponent("aishell-mcp-managed-change-set-\(UUID().uuidString)", isDirectory: true)
        let root = temporary.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("one.txt")
        try Data("before".utf8).write(to: source)
        let stateBase = temporary.appendingPathComponent("state", isDirectory: true)
        let store = RuntimeStore(baseDirectory: stateBase)
        let workspaceRuntime = WorkspaceStateRuntime(runtimeStore: store, startsFSEvents: false)
        let development = DevelopmentRuntimeService(runtimeStore: store, workspaceRuntime: workspaceRuntime)
        let server = MCPServer(
            runtimeStore: store,
            capabilitySet: "expanded-v1",
            developmentRuntime: development
        )
        let rootDigest = SHA256.hash(data: Data(root.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let changeSetState = stateBase.appendingPathComponent("apply-change-set-local-v1", isDirectory: true)
            .appendingPathComponent(rootDigest, isDirectory: true)
        defer {
            ApplyChangeSetSecretStore.removeKeyForTesting(stateDirectory: changeSetState)
            try? FileManager.default.removeItem(at: temporary)
        }

        let snapshot = await server.callTool(id: .number(1), params: .object([
            "name": .string("workspace_snapshot"),
            "arguments": .object(["path": .string(root.path), "context_budget": .number(0)])
        ]))
        let workspaceCursor = try XCTUnwrap(
            snapshot.result?.objectValue?["structuredContent"]?.objectValue?["cursor"]?.stringValue
        )
        let initialScanCount = await workspaceRuntime.scanInvocationCountForTests()
        let beforeSHA = SHA256.hash(data: Data("before".utf8))
            .map { String(format: "%02x", $0) }.joined()

        let response = await server.callTool(id: .number(2), params: .object([
            "name": .string("apply_change_set"),
            "arguments": .object([
                "path": .string(root.path),
                "workspace_cursor": .string(workspaceCursor),
                "changes": .array([
                    .object([
                        "change_id": .string("write-one"), "operation": .string("write"),
                        "path": .string("one.txt"),
                        "expected": .object(["state": .string("file"), "sha256": .string(beforeSHA)]),
                        "content": .object(["encoding": .string("utf8"), "data": .string("after")])
                    ]),
                    .object([
                        "change_id": .string("create-two"), "operation": .string("create"),
                        "path": .string("two.txt"),
                        "expected": .object(["state": .string("absent")]),
                        "content": .object(["encoding": .string("utf8"), "data": .string("two")])
                    ])
                ])
            ])
        ]))
        let result = try XCTUnwrap(response.result?.objectValue)
        let structured = try XCTUnwrap(result["structuredContent"]?.objectValue)
        XCTAssertEqual(result["isError"], .bool(false), "\(structured)")
        let updatedWorkspaceCursor = try XCTUnwrap(structured["workspace_cursor"]?.stringValue)
        XCTAssertEqual(structured["status"], .string("committed"))
        XCTAssertEqual(structured["workspace_from_cursor"], .string(workspaceCursor))
        XCTAssertNotEqual(updatedWorkspaceCursor, workspaceCursor)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "after")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("two.txt"), encoding: .utf8), "two")

        // apply_change_set inlines the resulting content of small text files so the caller can report
        // exactly what was written (e.g. [path, content]) without a follow-up read.
        let appliedChanges = try XCTUnwrap(structured["changes"]?.arrayValue)
        let afterContentByID = Dictionary(uniqueKeysWithValues: appliedChanges.compactMap { change -> (String, JSONValue)? in
            guard let id = change.objectValue?["change_id"]?.stringValue else { return nil }
            return (id, change.objectValue?["after_content"] ?? .null)
        })
        XCTAssertEqual(afterContentByID["write-one"], .string("after"))
        XCTAssertEqual(afterContentByID["create-two"], .string("two"))

        let delta = await server.callTool(id: .number(3), params: .object([
            "name": .string("workspace_snapshot"),
            "arguments": .object([
                "path": .string(root.path), "since_cursor": .string(workspaceCursor),
                "context_budget": .number(0)
            ])
        ]))
        let changes = try XCTUnwrap(
            delta.result?.objectValue?["structuredContent"]?.objectValue?["changes"]?.arrayValue
        )
        XCTAssertEqual(Set(changes.compactMap { $0.objectValue?["path"]?.stringValue }), Set(["one.txt", "two.txt"]))
        let finalScanCount = await workspaceRuntime.scanInvocationCountForTests()
        XCTAssertEqual(finalScanCount, initialScanCount)

        let stale = await server.callTool(id: .number(4), params: .object([
            "name": .string("apply_change_set"),
            "arguments": .object([
                "path": .string(root.path),
                "workspace_cursor": .string(workspaceCursor),
                "changes": .array([.object([
                    "change_id": .string("stale-create"), "operation": .string("create"),
                    "path": .string("must-not-exist.txt"),
                    "expected": .object(["state": .string("absent")]),
                    "content": .object(["encoding": .string("utf8"), "data": .string("no")])
                ])])
            ])
        ]))
        XCTAssertEqual(
            stale.result?.objectValue?["structuredContent"]?.objectValue?["error"]?
                .objectValue?["code"],
            .string("WORKSPACE_CHANGED")
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("must-not-exist.txt").path
        ))

        // 別のserviceで保存済み状態と鍵を開き直し、次の取引まで完了させる。
        let reopenedStore = RuntimeStore(baseDirectory: stateBase)
        let reopenedWorkspace = WorkspaceStateRuntime(runtimeStore: reopenedStore, startsFSEvents: false)
        let reopened = MCPServer(runtimeStore: reopenedStore, capabilitySet: "expanded-v1",
            developmentRuntime: DevelopmentRuntimeService(runtimeStore: reopenedStore, workspaceRuntime: reopenedWorkspace))
        let reopenedSnapshot = await reopened.callTool(id: .number(5), params: .object([
            "name": .string("workspace_snapshot"),
            "arguments": .object(["path": .string(root.path), "context_budget": .number(0)])
        ]))
        let reopenedCursor = try XCTUnwrap(reopenedSnapshot.result?.objectValue?["structuredContent"]?.objectValue?["cursor"]?.stringValue)
        let afterSHA = SHA256.hash(data: Data("after".utf8)).map { String(format: "%02x", $0) }.joined()
        let second = await reopened.callTool(id: .number(6), params: .object([
            "name": .string("apply_change_set"),
            "arguments": .object([
                "path": .string(root.path), "workspace_cursor": .string(reopenedCursor),
                "changes": .array([.object([
                    "change_id": .string("write-after-restart"), "operation": .string("write"),
                    "path": .string("one.txt"),
                    "expected": .object(["state": .string("file"), "sha256": .string(afterSHA)]),
                    "content": .object(["encoding": .string("utf8"), "data": .string("after restart")])
                ])])
            ])
        ]))
        XCTAssertEqual(second.result?.objectValue?["isError"], .bool(false), "\(String(describing: second.result))")
        XCTAssertEqual(second.result?.objectValue?["structuredContent"]?.objectValue?["status"], .string("committed"))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "after restart")
    }

    func testApplyChangeSetSchemaIsClosedDestructiveAndIdempotent() throws {
        let tools = try ToolCatalog.listedTools(profile: nil, capabilitySet: "expanded-v1")
        let tool = try XCTUnwrap(tools.first { $0.name == "apply_change_set" })
        XCTAssertTrue(tool.annotations.destructiveHint)
        XCTAssertTrue(tool.annotations.idempotentHint)
        XCTAssertFalse(tool.annotations.readOnlyHint)

        let input = try XCTUnwrap(tool.inputSchema.objectValue)
        XCTAssertEqual(input["additionalProperties"], .bool(false))
        let properties = try XCTUnwrap(input["properties"]?.objectValue)
        XCTAssertNil(properties["client_id"])
        XCTAssertNil(properties["client_epoch"])
        XCTAssertNil(properties["request_sequence"])
        XCTAssertNotNil(properties["path"])
        XCTAssertNotNil(properties["workspace_cursor"])
        XCTAssertEqual(
            Set(input["required"]?.arrayValue?.compactMap(\.stringValue) ?? []),
            Set(["path", "workspace_cursor", "changes"])
        )
        XCTAssertEqual(properties["changes"]?.objectValue?["minItems"], .number(1))
        XCTAssertEqual(properties["changes"]?.objectValue?["maxItems"], .number(128))
        let variants = properties["changes"]?.objectValue?["items"]?.objectValue?["oneOf"]?.arrayValue
        XCTAssertEqual(variants?.count, 4)
        XCTAssertTrue(variants?.allSatisfy { $0.objectValue?["additionalProperties"] == .bool(false) } == true)
        let rename = variants?.last?.objectValue?["properties"]?.objectValue
        XCTAssertNotNil(rename?["source_expected"])
        XCTAssertNotNil(rename?["destination_expected"])

        let success = tool.outputSchema?.objectValue?["oneOf"]?.arrayValue?.first?.objectValue
        XCTAssertEqual(
            success?["properties"]?.objectValue?["schemaVersion"]?.objectValue?["const"],
            .string("aishell.apply-change-set.v1")
        )
    }

    func testInvalidOperationFailsBeforeFilesystemOrServiceFallback() async throws {
        let server = MCPServer(capabilitySet: "expanded-v1")
        let response = await server.callTool(id: .number(1), params: .object([
            "name": .string("apply_change_set"),
            "arguments": .object([
                "client_id": .string("00000000-0000-4000-8000-000000000001"),
                "client_epoch": .number(1),
                "request_sequence": .number(1),
                "cursor": .object([
                    "root": .string("/tmp/not-consulted"),
                    "generation": .string("generation"),
                    "sequence": .number(0)
                ]),
                "changes": .array([.object([
                    "change_id": .string("c1"),
                    "operation": .string("patch"),
                    "path": .string("one.txt"),
                    "expected": .object(["state": .string("absent")]),
                    "content": .object(["encoding": .string("utf8"), "data": .string("one")])
                ])])
            ])
        ]))
        let result = try XCTUnwrap(response.result?.objectValue)
        XCTAssertEqual(result["isError"], .bool(true))
        XCTAssertEqual(
            result["structuredContent"]?.objectValue?["error"]?.objectValue?["code"],
            .string("INVALID_ARGUMENT")
        )
    }

    func testOperationSpecificFieldsAreNotSilentlyIgnored() async throws {
        let server = MCPServer(capabilitySet: "expanded-v1")
        let response = await server.callTool(id: .number(2), params: .object([
            "name": .string("apply_change_set"),
            "arguments": .object([
                "client_id": .string("00000000-0000-4000-8000-000000000001"),
                "client_epoch": .number(1),
                "request_sequence": .number(1),
                "cursor": .object([
                    "root": .string("/tmp/not-consulted"),
                    "generation": .string("generation"),
                    "sequence": .number(0)
                ]),
                "changes": .array([.object([
                    "change_id": .string("c1"),
                    "operation": .string("delete"),
                    "path": .string("one.txt"),
                    "expected": .object([
                        "state": .string("file"),
                        "sha256": .string(String(repeating: "0", count: 64))
                    ]),
                    "content": .object(["encoding": .string("utf8"), "data": .string("ignored")])
                ])])
            ])
        ]))
        XCTAssertEqual(
            response.result?.objectValue?["structuredContent"]?.objectValue?["error"]?
                .objectValue?["code"],
            .string("INVALID_ARGUMENT")
        )
    }

    func testApplyChangeSetErrorsKeepStableCodes() {
        let server = MCPServer()
        XCTAssertEqual(
            server.stableError(ApplyChangeSetError(.contentChanged)).code,
            "STALE_CONTENT"
        )
        XCTAssertEqual(
            server.stableError(ApplyChangeSetError(.changeSetRecoveryRequired)).code,
            "CHANGE_SET_RECOVERY_REQUIRED"
        )
        XCTAssertEqual(
            server.stableError(ApplyChangeSetError(.externalConflictDuringCommit)).code,
            "EXTERNAL_CONFLICT_DURING_COMMIT"
        )
        XCTAssertEqual(
            server.stableError(ApplyChangeSetError(.changeSetReservationCorrupt)).code,
            "CHANGE_SET_RESERVATION_CORRUPT"
        )
        XCTAssertEqual(
            server.stableError(ApplyChangeSetError(.changeSetPreviousPending)).code,
            "CHANGE_SET_PREVIOUS_PENDING"
        )
        XCTAssertEqual(
            server.stableError(ApplyChangeSetError(.clientEpochExhausted)).code,
            "CLIENT_EPOCH_EXHAUSTED"
        )

        let error = ApplyChangeSetError(
            .changeSetRecoveryRequired,
            "回復が必要です。",
            context: ApplyChangeSetFailureContext(
                transactionID: "tx-1",
                clientID: "00000000-0000-4000-8000-000000000001",
                clientEpoch: 2,
                requestSequence: 7,
                changedPaths: ["one.txt"],
                rollbackState: "not_proven",
                recoveryState: "recovery_required",
                evidenceHandle: "art_1",
                nextAction: "retry_apply_change_set"
            )
        )
        let stable = server.stableError(error)
        let structured = server.structuredError(error, stable: stable).objectValue
        XCTAssertEqual(structured?["transaction_id"], .string("tx-1"))
        XCTAssertEqual(structured?["changed_paths"], .array([.string("one.txt")]))
        XCTAssertEqual(structured?["next_action"], .string("retry_apply_change_set"))
    }

    func testSuccessProjectionUsesADR0017WireNamesWithoutDroppingEvidence() throws {
        let cursor = ApplyChangeSetCursor(root: "/workspace", generation: "g1", sequence: 4)
        let result = ApplyChangeSetResult(
            transactionID: "tx-1",
            clientID: "00000000-0000-4000-8000-000000000001",
            clientEpoch: 2,
            root: "/workspace",
            status: .committed,
            visibility: .aishellSerializedRecoverable,
            requestSequence: 7,
            fromCursor: cursor,
            cursor: ApplyChangeSetCursor(root: "/workspace", generation: "g1", sequence: 5),
            changes: [ApplyChangeSetChangeResult(
                changeID: "c1", afterSHA256: String(repeating: "a", count: 64),
                kind: "write", beforePath: "one.txt", afterPath: "one.txt",
                beforeIdentity: "dev:1", afterIdentity: "dev:2",
                beforeSHA256: String(repeating: "b", count: 64),
                beforeSizeBytes: 3, afterSizeBytes: 4,
                beforeMetadata: ApplyChangeSetMetadata(mode: 0o644),
                afterMetadata: ApplyChangeSetMetadata(mode: 0o644)
            )],
            changedPaths: ["one.txt"],
            transactionCursorAdvanced: true,
            diffArtifact: ApplyChangeSetArtifact(
                handle: "art_1", sha256: String(repeating: "c", count: 64), sizeBytes: 123,
                expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            summary: ApplyChangeSetSummary(
                createCount: 0, writeCount: 1, deleteCount: 0, renameCount: 0,
                beforeBytes: 3, afterBytes: 4
            ),
            diffPreview: "preview", hasMore: true, returnedDiffBytes: 7, omittedDiffBytes: 116
        )
        let wire = try XCTUnwrap(MCPServer().applyChangeSetJSON(result).objectValue)
        XCTAssertEqual(wire["schemaVersion"], .string("aishell.apply-change-set.v1"))
        XCTAssertEqual(wire["transaction_id"], .string("tx-1"))
        XCTAssertNil(wire["transactionID"])
        XCTAssertEqual(wire["returned_diff_bytes"], .number(7))
        XCTAssertEqual(wire["diff_artifact"]?.objectValue?["handle"], .string("art_1"))
        XCTAssertEqual(wire["changes"]?.arrayValue?.first?.objectValue?["before_path"], .string("one.txt"))
    }
}
