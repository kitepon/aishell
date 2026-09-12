import Foundation
import XCTest
@testable import AIShellMCP

final class MCPRunCheckV2SchemaTests: XCTestCase {
    func testBaselineCatalogAndLegacySchemaRemainExact() throws {
        let baseline = try ToolCatalog.listedTools(profile: nil)
        XCTAssertEqual(baseline.map(\.name), [
            "run_check", "artifact_read", "workspace_snapshot", "read_context", "search_context",
            "runtime_status", "runtime_open_manager"
        ])
        let full = try ToolCatalog.listedTools(profile: "full")
        XCTAssertEqual(full.count, 25)
        let schema = try wireSchema(tool("run_check", in: baseline).inputSchema)
        XCTAssertNil(schema.objectValue?["oneOf"])
        XCTAssertEqual(propertyKeys(schema), [
            "arguments", "environment", "executable", "retention_seconds", "timeout_seconds", "working_directory"
        ])
        XCTAssertTrue(SchemaProbe.matches(schema, value: ["executable": "swift"]))

        let expanded = try ToolCatalog.listedTools(profile: nil, capabilitySet: "expanded-v1")
        let expandedInput = try wireSchema(tool("run_check", in: expanded).inputSchema)
        XCTAssertEqual(expandedInput.objectValue?["oneOf"]?.arrayValue?.first, schema)
        let baselineOutput = try wireSchema(try XCTUnwrap(tool("run_check", in: baseline).outputSchema))
        let baselineOutputVariants = try XCTUnwrap(baselineOutput.objectValue?["oneOf"]?.arrayValue)
        let expandedOutput = try wireSchema(try XCTUnwrap(tool("run_check", in: expanded).outputSchema))
        XCTAssertEqual(Array(try XCTUnwrap(expandedOutput.objectValue?["oneOf"]?.arrayValue).prefix(2)), baselineOutputVariants)
    }

    func testExpandedCatalogAddsImplementedCapabilityToolsInContractOrder() throws {
        let expanded = try ToolCatalog.listedTools(profile: nil, capabilitySet: "expanded-v1")
        XCTAssertEqual(expanded.map(\.name), [
            "run_check", "run_observe", "artifact_read", "workspace_snapshot", "workspace_wait",
            "read_context", "search_context", "change_impact", "apply_change_set",
            "runtime_status", "runtime_open_manager"
        ])
        let full = try ToolCatalog.listedTools(profile: "full", capabilitySet: "expanded-v1")
        XCTAssertEqual(full.count, 29)
        XCTAssertEqual(Array(full.prefix(11).map(\.name)), expanded.map(\.name))
        let observe = tool("run_observe", in: expanded)
        XCTAssertFalse(observe.annotations.readOnlyHint)
        XCTAssertTrue(observe.annotations.destructiveHint)
        XCTAssertTrue(observe.annotations.idempotentHint)
        let wait = tool("workspace_wait", in: expanded)
        XCTAssertTrue(wait.annotations.readOnlyHint)
        XCTAssertTrue(wait.annotations.idempotentHint)
        XCTAssertFalse(wait.annotations.destructiveHint)
        let impact = tool("change_impact", in: expanded)
        XCTAssertTrue(impact.annotations.readOnlyHint)
        XCTAssertTrue(impact.annotations.idempotentHint)
        XCTAssertTrue(expanded.prefix(9).allSatisfy { $0.description.contains(".") })
        XCTAssertFalse(impact.annotations.destructiveHint)
    }

    func testRunCheckV1AndThreeV2InvocationVariantsAreAnExactOneOf() throws {
        let schema = try expandedRunCheckInput()
        let digest = String(repeating: "a", count: 64)
        let values: [[String: Any]] = [
            ["executable": "swift", "arguments": ["test"]],
            v2(invocation: ["mode": "direct", "executable": "swift"], cache: "off", selection: ["binding": "prepare"]),
            v2(invocation: ["mode": "profile_check", "project_id": "p", "profile_digest": digest, "check_id": "c"], cache: "prefer", selection: ["binding": "prepare"]),
            v2(invocation: ["mode": "focused_set", "focused_set_id": "set", "ordered_check_ids": ["a"]], cache: "refresh", selection: ["binding": "prepare_focused_set", "focused_set_digest": digest]),
            v2(invocation: ["mode": "focused_set", "focused_set_id": "set", "ordered_check_ids": ["a", "b"]], cache: "only", selection: ["binding": "verify_focused_set", "focused_set_digest": digest, "selection_digest": digest])
        ]
        for value in values { XCTAssertTrue(SchemaProbe.matches(schema, value: value), "\(value)") }

        var mixed = values[1]
        mixed["executable"] = "swift"
        XCTAssertFalse(SchemaProbe.matches(schema, value: mixed))
        var directCacheMismatch = values[1]
        directCacheMismatch["cache"] = "prefer"
        XCTAssertFalse(SchemaProbe.matches(schema, value: directCacheMismatch))
        var unknown = values[2]
        unknown["future"] = true
        XCTAssertFalse(SchemaProbe.matches(schema, value: unknown))
    }

    func testRunCheckNestedUnionsAreClosedAndRejectUnknownOrDuplicateSelection() throws {
        let schema = try expandedRunCheckInput()
        assertClosedVariants(schema)
        let digest = String(repeating: "b", count: 64)
        let duplicate = v2(
            invocation: ["mode": "focused_set", "focused_set_id": "set", "ordered_check_ids": ["same", "same"]],
            cache: "off",
            selection: ["binding": "verify_focused_set", "focused_set_digest": digest, "selection_digest": digest]
        )
        XCTAssertFalse(SchemaProbe.matches(schema, value: duplicate))
        var badDispatch = v2(invocation: ["mode": "direct", "executable": "swift"], cache: "off", selection: ["binding": "prepare"])
        badDispatch["dispatch"] = ["mode": "sync", "client_run_key": "not-allowed"]
        XCTAssertFalse(SchemaProbe.matches(schema, value: badDispatch))
        let mixedFocusedSelection = v2(
            invocation: ["mode": "focused_set", "focused_set_id": "set", "ordered_check_ids": ["one"]],
            cache: "refresh",
            selection: ["binding": "prepare_focused_set", "focused_set_digest": digest, "selection_digest": digest]
        )
        XCTAssertFalse(SchemaProbe.matches(schema, value: mixedFocusedSelection))
        XCTAssertFalse(SchemaProbe.matches(schema, value: v2(
            invocation: ["mode": "focused_set", "focused_set_id": "set", "ordered_check_ids": ["one"]],
            cache: "refresh",
            selection: ["binding": "prepare_focused_set"]
        )))
    }

    func testProfileSelectionRequiresCorePreparationRatherThanCallerDigest() throws {
        let schema = try expandedRunCheckInput()
        let digest = String(repeating: "c", count: 64)
        let invocation: [String: Any] = [
            "mode": "profile_check", "project_id": "project", "profile_digest": digest, "check_id": "unit"
        ]
        XCTAssertTrue(SchemaProbe.matches(schema, value: v2(invocation: invocation, cache: "refresh", selection: ["binding": "prepare"])))
        XCTAssertFalse(SchemaProbe.matches(schema, value: v2(
            invocation: invocation, cache: "refresh",
            selection: ["binding": "prepare", "selection_digest": digest]
        )))
        XCTAssertFalse(SchemaProbe.matches(schema, value: v2(
            invocation: invocation, cache: "refresh",
            selection: ["binding": "verify_focused_set", "focused_set_digest": digest, "selection_digest": digest]
        )))
    }

    func testRunCheckDTORejectsMixedFieldsAndPreservesPreparationBoundary() throws {
        let digest = String(repeating: "f", count: 64)
        let profile = v2(
            invocation: ["mode": "profile_check", "project_id": "project", "profile_digest": digest, "check_id": "unit"],
            cache: "prefer", selection: ["binding": "prepare"]
        )
        let data = try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys])
        let decoded = try JSONDecoder.aishell.decode(MCPRunCheckRequestDTO.self, from: data)
        guard case .v2(let request) = decoded, case .preparedByCore = request.selection else {
            return XCTFail("profile selectionがCore prepare境界になっていない")
        }

        var mixed = profile
        mixed["executable"] = "swift"
        XCTAssertThrowsError(try JSONDecoder.aishell.decode(
            MCPRunCheckRequestDTO.self,
            from: JSONSerialization.data(withJSONObject: mixed, options: [.sortedKeys])
        ))
        var blindDigest = profile
        blindDigest["selection"] = ["binding": "prepare", "selection_digest": digest]
        XCTAssertThrowsError(try JSONDecoder.aishell.decode(
            MCPRunCheckRequestDTO.self,
            from: JSONSerialization.data(withJSONObject: blindDigest, options: [.sortedKeys])
        ))
    }

    func testRunCheckOutputHasClosedLegacySuccessV2SuccessAndErrorVariants() throws {
        let expanded = try ToolCatalog.listedTools(profile: nil, capabilitySet: "expanded-v1")
        let schema = try wireSchema(try XCTUnwrap(tool("run_check", in: expanded).outputSchema))
        let variants = try XCTUnwrap(schema.objectValue?["oneOf"]?.arrayValue)
        XCTAssertEqual(variants.count, 5)
        XCTAssertEqual(variants[2].objectValue?["additionalProperties"], .bool(false))
        XCTAssertEqual(variants[3].objectValue?["additionalProperties"], .bool(false))
        XCTAssertEqual(variants[4].objectValue?["additionalProperties"], .bool(false))
        XCTAssertEqual(propertyKeys(variants[2]), [
            "cacheState", "diagnostics", "lookupEvidence", "planDigest", "plannedCheckIDs", "processesStarted",
            "publications", "requestedCheckIDs", "schemaVersion", "selectionDigest", "steps"
        ])
        XCTAssertEqual(propertyKeys(variants[3]), [
            "arguments", "diagnosticArtifact", "diagnosticBytes", "dispatch", "environmentDigest",
            "evidenceCursor", "executable", "expiresAt", "planDigest", "retentionSeconds",
            "runHandle", "runID", "schemaVersion", "startedAt", "state", "stateRevision",
            "stderrArtifact", "stderrBytes", "stdoutArtifact", "stdoutBytes", "terminationCause",
            "timeoutDeadline", "workingDirectory"
        ])
        XCTAssertEqual(variants[3].objectValue?["properties"]?.objectValue?["dispatch"]?.objectValue?["const"], .string("start"))
        XCTAssertEqual(
            variants[3].objectValue?["properties"]?.objectValue?["environmentDigest"]?.objectValue?["pattern"],
            .string("^[0-9a-f]{64}$")
        )
        XCTAssertEqual(propertyKeys(variants[4]), ["error", "schemaVersion"])
        let error = try XCTUnwrap(variants[4].objectValue?["properties"]?.objectValue?["error"])
        XCTAssertEqual(propertyKeys(error), ["code", "lookupEvidence", "message", "processesStarted"])
    }

    func testChangeImpactInputSeparatesAnalyzeRecommendAndContinuation() throws {
        let schema = try changeImpactInput()
        let digest = String(repeating: "d", count: 64)
        let analyze: [String: Any] = [
            "operation": "analyze", "workspace_cursor": "cursor",
            "changed_paths": [["path": "Sources/A.swift", "content_sha256": digest]]
        ]
        let recommend: [String: Any] = [
            "operation": "recommend", "workspace_cursor": "cursor", "project_id": "p", "profile_digest": digest,
            "changed_symbols": [["path": "Sources/A.swift", "content_sha256": digest, "name": "A", "start_offset": 0, "end_offset": 1]]
        ]
        XCTAssertTrue(SchemaProbe.matches(schema, value: analyze))
        XCTAssertTrue(SchemaProbe.matches(schema, value: recommend))
        XCTAssertTrue(SchemaProbe.matches(schema, value: analyze.merging([
            "changed_symbols": [["path": "Sources/A.swift", "content_sha256": digest, "name": "A", "start_offset": 0, "end_offset": 1]]
        ]) { _, new in new }))
        XCTAssertTrue(SchemaProbe.matches(schema, value: ["continuation": "opaque", "byte_budget": 65_536]))
        XCTAssertFalse(SchemaProbe.matches(schema, value: ["operation": "analyze", "workspace_cursor": "cursor"]))
        XCTAssertFalse(SchemaProbe.matches(schema, value: ["continuation": "opaque", "root": "/tmp"]))
        XCTAssertFalse(SchemaProbe.matches(schema, value: ["operation": "recommend", "workspace_cursor": "cursor", "changed_paths": [["path": "A", "expected_absent": true]]]))
        XCTAssertFalse(SchemaProbe.matches(schema, value: analyze.merging(["unknown": 1]) { _, new in new }))
    }

    func testChangedPathRequiresExactlyOneSHAOrTrueAbsenceBinding() throws {
        let schema = try changeImpactInput()
        let digest = String(repeating: "e", count: 64)
        func request(_ path: [String: Any]) -> [String: Any] {
            ["operation": "analyze", "workspace_cursor": "cursor", "changed_paths": [path]]
        }
        XCTAssertTrue(SchemaProbe.matches(schema, value: request(["path": "A", "content_sha256": digest])))
        XCTAssertTrue(SchemaProbe.matches(schema, value: request(["path": "A", "expected_absent": true])))
        XCTAssertFalse(SchemaProbe.matches(schema, value: request(["path": "A"])))
        XCTAssertFalse(SchemaProbe.matches(schema, value: request(["path": "A", "content_sha256": digest, "expected_absent": true])))
        XCTAssertFalse(SchemaProbe.matches(schema, value: request(["path": "A", "expected_absent": false])))
    }

    func testChangeImpactOutputClosesTopLevelAndEveryItemKind() throws {
        let expanded = try ToolCatalog.listedTools(profile: nil, capabilitySet: "expanded-v1")
        let schema = try wireSchema(try XCTUnwrap(tool("change_impact", in: expanded).outputSchema))
        let variants = try XCTUnwrap(schema.objectValue?["oneOf"]?.arrayValue)
        XCTAssertEqual(variants.count, 3)
        variants.forEach { XCTAssertEqual($0.objectValue?["additionalProperties"], .bool(false)) }
        XCTAssertEqual(propertyKeys(variants[0]), [
            "artifact", "continuation", "counts", "coverage", "freshness", "hasMore", "items",
            "omittedBytes", "operation", "returnedBytes", "schemaVersion"
        ])
        XCTAssertEqual(propertyKeys(variants[1]), [
            "artifact", "byteBudget", "candidateCount", "continuation", "coverage", "executionPolicy",
            "expiresAt", "focusedSetDigest", "focusedSetID", "freshness", "hasMore", "items",
            "limitationCount", "operation", "schema", "stepCount"
        ])
        let recommendItems = try XCTUnwrap(variants[1].objectValue?["properties"]?.objectValue?["items"]?.objectValue?["items"]?.objectValue?["oneOf"]?.arrayValue)
        XCTAssertEqual(recommendItems.count, 6)
        XCTAssertEqual(Set(recommendItems.compactMap(kind)), Set([
            "focused_candidate", "focused_step", "dependency_edge", "manifest_binding", "impact_evidence", "coverage_gap"
        ]))
        recommendItems.forEach { XCTAssertEqual($0.objectValue?["additionalProperties"], .bool(false)) }
    }

    func testToolDefinitionEncodingIsDeterministic() throws {
        let first = try JSONEncoder.aishell.encode(ToolCatalog.listedTools(profile: "full", capabilitySet: "expanded-v1"))
        let second = try JSONEncoder.aishell.encode(ToolCatalog.listedTools(profile: "full", capabilitySet: "expanded-v1"))
        XCTAssertEqual(first, second)
        XCTAssertEqual(try JSONDecoder.aishell.decode(JSONValue.self, from: first), try JSONDecoder.aishell.decode(JSONValue.self, from: second))
    }

    private func expandedRunCheckInput() throws -> JSONValue {
        try wireSchema(tool("run_check", in: ToolCatalog.listedTools(profile: nil, capabilitySet: "expanded-v1")).inputSchema)
    }

    private func changeImpactInput() throws -> JSONValue {
        try wireSchema(tool("change_impact", in: ToolCatalog.listedTools(profile: nil, capabilitySet: "expanded-v1")).inputSchema)
    }

    private func tool(_ name: String, in tools: [MCPTool]) -> MCPTool {
        tools.first { $0.name == name }!
    }

    private func wireSchema(_ schema: JSONValue) throws -> JSONValue {
        let data = try JSONEncoder.aishell.encode(schema)
        return try JSONDecoder.aishell.decode(JSONValue.self, from: data)
    }

    private func propertyKeys(_ schema: JSONValue) -> [String] {
        schema.objectValue?["properties"]?.objectValue?.keys.sorted() ?? []
    }

    private func kind(_ schema: JSONValue) -> String? {
        schema.objectValue?["properties"]?.objectValue?["kind"]?.objectValue?["const"]?.stringValue
    }

    private func assertClosedVariants(_ schema: JSONValue, file: StaticString = #filePath, line: UInt = #line) {
        guard let object = schema.objectValue else { return }
        if let variants = object["oneOf"]?.arrayValue {
            for variant in variants {
                if variant.objectValue?["type"] == .string("object") {
                    XCTAssertEqual(variant.objectValue?["additionalProperties"], .bool(false), file: file, line: line)
                }
                assertClosedVariants(variant, file: file, line: line)
            }
        }
        object.values.forEach { value in
            if case .array(let values) = value { values.forEach { assertClosedVariants($0, file: file, line: line) } }
            else { assertClosedVariants(value, file: file, line: line) }
        }
    }

    private func v2(invocation: [String: Any], cache: String, selection: [String: Any]) -> [String: Any] {
        [
            "schema": "aishell.run-check.v2", "invocation": invocation,
            "dispatch": ["mode": "sync"], "cache": cache,
            "execution_policy": ["timeout_ms": 120_000, "retention_seconds": 86_400],
            "selection": selection
        ]
    }
}

private enum SchemaProbe {
    static func matches(_ schema: JSONValue, value: Any) -> Bool {
        guard let object = schema.objectValue else { return true }
        if let oneOf = object["oneOf"]?.arrayValue,
           oneOf.filter({ matches($0, value: value) }).count != 1 { return false }
        if let anyOf = object["anyOf"]?.arrayValue,
           !anyOf.contains(where: { matches($0, value: value) }) { return false }
        if let required = object["required"]?.arrayValue?.compactMap(\.stringValue) {
            guard let candidate = value as? [String: Any], required.allSatisfy({ candidate[$0] != nil }) else { return false }
        }
        if let constant = object["const"]?.stringValue, value as? String != constant { return false }
        if let constant = object["const"]?.boolValue, value as? Bool != constant { return false }
        if let allowed = object["enum"]?.arrayValue?.compactMap(\.stringValue),
           !allowed.contains(value as? String ?? "") { return false }
        guard let type = object["type"]?.stringValue else { return true }
        switch type {
        case "object":
            guard let candidate = value as? [String: Any] else { return false }
            let properties = object["properties"]?.objectValue ?? [:]
            if object["additionalProperties"] == .bool(false), !Set(candidate.keys).isSubset(of: Set(properties.keys)) { return false }
            return candidate.allSatisfy { key, child in properties[key].map { matches($0, value: child) } ?? true }
        case "array":
            guard let candidate = value as? [Any] else { return false }
            if let minimum = object["minItems"]?.intValue, candidate.count < minimum { return false }
            if let maximum = object["maxItems"]?.intValue, candidate.count > maximum { return false }
            if object["uniqueItems"] == .bool(true) {
                let encoded = candidate.map { String(describing: $0) }
                guard Set(encoded).count == encoded.count else { return false }
            }
            return object["items"].map { item in candidate.allSatisfy { matches(item, value: $0) } } ?? true
        case "string":
            guard let candidate = value as? String else { return false }
            if let minimum = object["minLength"]?.intValue, candidate.utf8.count < minimum { return false }
            if let maximum = object["maxLength"]?.intValue, candidate.utf8.count > maximum { return false }
            if object["pattern"]?.stringValue == "^[0-9a-f]{64}$" {
                return candidate.utf8.count == 64 && candidate.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) }
            }
            return true
        case "integer": return value is Int
        case "number": return value is Int || value is Double
        case "boolean": return value is Bool
        case "null": return value is NSNull
        default: return true
        }
    }
}
