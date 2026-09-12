import XCTest
@testable import AIShellMCP

final class MCPTypesTests: XCTestCase {
    func testDevelopmentProfileListsHighDensitySurfaceAndRecoveryControls() {
        let tools = try! ToolCatalog.listedTools(profile: nil)
        XCTAssertEqual(
            Set(tools.map(\.name)),
            [
                "run_check", "artifact_read", "workspace_snapshot", "read_context", "search_context",
                "runtime_status", "runtime_open_manager"
            ]
        )
        XCTAssertEqual(tools.prefix(5).map(\.name), [
            "run_check", "artifact_read", "workspace_snapshot", "read_context", "search_context"
        ])
        XCTAssertTrue(tools.prefix(5).allSatisfy { $0.outputSchema != nil })
        XCTAssertTrue(tools.prefix(5).allSatisfy {
            guard $0.outputSchema?.objectValue?["type"] == .string("object") else { return false }
            let variantCount = $0.outputSchema?.objectValue?["oneOf"]?.arrayValue?.count
            return ["workspace_snapshot", "search_context"].contains($0.name)
                ? variantCount == 3
                : variantCount == 2
        })
        XCTAssertEqual(tools.suffix(2).map(\.name), ["runtime_status", "runtime_open_manager"])
        XCTAssertTrue(tools.suffix(2).allSatisfy { $0.outputSchema != nil })
        XCTAssertTrue(ToolCatalog.controlToolNames.isSubset(of: Set(tools.map(\.name))))
        XCTAssertEqual(tools.first { $0.name == "run_check" }?.annotations.destructiveHint, true)
        XCTAssertEqual(tools.first { $0.name == "run_check" }?.annotations.openWorldHint, true)
        let snapshot = tools.first { $0.name == "workspace_snapshot" }
        let entryLimit = snapshot?.inputSchema.objectValue?["properties"]?.objectValue?["entry_limit"]?.objectValue
        XCTAssertEqual(entryLimit?["minimum"], .number(1))
        XCTAssertEqual(entryLimit?["maximum"], .number(5_000))
        let success = snapshot?.outputSchema?.objectValue?["oneOf"]?.arrayValue?.first?.objectValue
        XCTAssertEqual(success?["properties"]?.objectValue?["schemaVersion"]?.objectValue?["const"], .string("aishell.workspace-snapshot.v1"))
        XCTAssertEqual(success?["properties"]?.objectValue?["omittedEntries"]?.objectValue?["type"], .string("integer"))
    }

    func testFullProfileRetainsLegacyDiscoveryCompatibility() {
        let names = Set(try! ToolCatalog.listedTools(profile: "full").map(\.name))
        XCTAssertEqual(names.count, 25)
        XCTAssertTrue(names.contains("process_run"))
        XCTAssertTrue(names.contains("files_read_text"))
        XCTAssertTrue(names.isSuperset(of: ToolCatalog.developmentToolNames))
        XCTAssertTrue(names.isSuperset(of: ToolCatalog.controlToolNames))
    }

    func testCapabilityGatePreservesBaselineAndAddsOnlyImplementedExpandedTools() throws {
        let baselineDefault = try ToolCatalog.listedTools(profile: nil, capabilitySet: nil)
        let baselineFull = try ToolCatalog.listedTools(profile: "full", capabilitySet: nil)
        let expandedDefault = try ToolCatalog.listedTools(profile: nil, capabilitySet: "expanded-v1")
        let expandedFull = try ToolCatalog.listedTools(profile: "full", capabilitySet: "expanded-v1")

        XCTAssertEqual(baselineDefault.map(\.name), [
            "run_check", "artifact_read", "workspace_snapshot", "read_context", "search_context",
            "runtime_status", "runtime_open_manager"
        ])
        XCTAssertEqual(baselineFull.count, 25)
        XCTAssertFalse(baselineFull.map(\.name).contains("apply_change_set"))
        XCTAssertFalse(baselineFull.map(\.name).contains("change_impact"))
        XCTAssertEqual(expandedDefault.map(\.name), [
            "run_check", "run_observe", "artifact_read", "workspace_snapshot", "workspace_wait",
            "read_context", "search_context", "change_impact", "apply_change_set",
            "runtime_status", "runtime_open_manager"
        ])
        XCTAssertEqual(expandedDefault.count, 11)
        XCTAssertEqual(expandedFull.count, 29)
        XCTAssertEqual(Array(expandedFull.prefix(11).map(\.name)), expandedDefault.map(\.name))
        XCTAssertEqual(Array(expandedDefault.prefix(9).map(\.name)), ToolCatalog.expandedDevelopmentToolOrder)
        XCTAssertEqual(expandedFull.filter { $0.name == "change_impact" }.count, 1)
        XCTAssertEqual(expandedFull.filter { $0.name == "apply_change_set" }.count, 1)
        XCTAssertEqual(expandedFull.filter { $0.name == "run_observe" }.count, 1)
        XCTAssertEqual(expandedFull.filter { $0.name == "workspace_wait" }.count, 1)
        let baselineArtifact = try XCTUnwrap(baselineDefault.first { $0.name == "artifact_read" })
        let expandedArtifact = try XCTUnwrap(expandedDefault.first { $0.name == "artifact_read" })
        XCTAssertEqual(expandedArtifact.inputSchema.objectValue?["oneOf"]?.arrayValue?.count, 4)
        XCTAssertEqual(expandedArtifact.outputSchema?.objectValue?["oneOf"]?.arrayValue?.count, 4)
        XCTAssertNotEqual(expandedArtifact.inputSchema, baselineArtifact.inputSchema)

        let first = try JSONEncoder.aishell.encode(expandedFull)
        let second = try JSONEncoder.aishell.encode(
            ToolCatalog.listedTools(profile: "full", capabilitySet: "expanded-v1")
        )
        XCTAssertEqual(first, second)
    }

    func testEveryDefaultProfileToolHasTopLevelObjectSchemas() throws {
        let catalogs: [[MCPTool]] = [
            try ToolCatalog.listedTools(profile: nil, capabilitySet: nil),
            try ToolCatalog.listedTools(profile: nil, capabilitySet: "expanded-v1"),
            try ToolCatalog.listedTools(profile: "factory", capabilitySet: nil)
        ]

        for catalog in catalogs {
            for tool in catalog {
                XCTAssertEqual(
                    tool.inputSchema.objectValue?["type"],
                    .string("object"),
                    "\(tool.name) must expose a top-level object input schema"
                )
                XCTAssertEqual(
                    tool.outputSchema?.objectValue?["type"],
                    .string("object"),
                    "\(tool.name) must expose a top-level object output schema"
                )
            }
        }
    }

    func testInvalidCapabilitySetIsTypedStartupFailureWithoutFallback() async throws {
        XCTAssertThrowsError(try ToolCatalog.listedTools(profile: nil, capabilitySet: "future")) { error in
            XCTAssertEqual(error as? MCPStartupError, .invalidCapabilitySet("future"))
            XCTAssertTrue(error.localizedDescription.contains("INVALID_CAPABILITY_SET"))
        }
        XCTAssertThrowsError(try ToolCatalog.listedTools(profile: nil, capabilitySet: "")) { error in
            XCTAssertEqual(error as? MCPStartupError, .invalidCapabilitySet(""))
        }
        let server = MCPServer(capabilitySet: "future")
        XCTAssertThrowsError(try server.validateStartup()) { error in
            XCTAssertEqual(error as? MCPStartupError, .invalidCapabilitySet("future"))
        }
        let response = await server.callTool(id: .number(1), params: .object([
            "name": .string("runtime_status"), "arguments": .object([:])
        ]))
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, -32000)
        XCTAssertTrue(response.error?.message.contains("INVALID_CAPABILITY_SET") == true)
    }

    func testInvalidToolProfileIsTypedStartupFailureWithoutFallback() async throws {
        for profile in ["future", ""] {
            XCTAssertThrowsError(try ToolCatalog.listedTools(profile: profile)) { error in
                XCTAssertEqual(error as? MCPStartupError, .invalidToolProfile(profile))
                XCTAssertTrue(error.localizedDescription.contains("INVALID_TOOL_PROFILE"))
            }
        }
        let server = MCPServer(toolProfile: "future")
        XCTAssertThrowsError(try server.validateStartup()) { error in
            XCTAssertEqual(error as? MCPStartupError, .invalidToolProfile("future"))
        }
        let response = await server.callTool(id: .number(2), params: .object([
            "name": .string("runtime_status"), "arguments": .object([:])
        ]))
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, -32000)
        XCTAssertTrue(response.error?.message.contains("INVALID_TOOL_PROFILE") == true)
    }

    func testDefaultServerCannotCallExpandedTool() async {
        let response = await MCPServer(capabilitySet: nil).callTool(
            id: .number(2),
            params: .object(["name": .string("apply_change_set"), "arguments": .object([:])])
        )
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, -32602)
        XCTAssertTrue(response.error?.message.contains("未定義のtool") == true)
    }

    func testArtifactStructuredProjectionDoesNotDuplicatePayload() {
        let projected = MCPServer().structuredProjection(
            name: "artifact_read",
            result: .object([
                "encoding": .string("base64"),
                "base64": .string("AP9B"),
                "text": .string("payload"),
                "returnedBytes": .number(3)
            ])
        )

        XCTAssertNil(projected.objectValue?["text"])
        XCTAssertNil(projected.objectValue?["base64"])
        XCTAssertEqual(projected.objectValue?["encoding"], .string("base64"))
    }

    func testContextStructuredProjectionsDoNotDuplicateModelFacingText() {
        let cases: [(String, String)] = [
            ("workspace_snapshot", "context"),
            ("read_context", "chunks"),
            ("search_context", "matches")
        ]
        for (name, key) in cases {
            let projected = MCPServer().structuredProjection(
                name: name,
                result: .object([
                    key: .array([.object([
                        "path": .string("Sources/App.swift"),
                        "line": .number(7),
                        "text": .string(String(repeating: "payload", count: 10_000))
                    ])])
                ])
            )
            let item = projected.objectValue?[key]?.arrayValue?.first?.objectValue
            XCTAssertNil(item?["text"], "\(name) duplicated TextContent in structuredContent")
            XCTAssertEqual(item?["path"], .string("Sources/App.swift"))
        }
    }
}
