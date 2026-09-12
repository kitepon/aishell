import Foundation

public enum AIShellProduct {
    public static let identifier = "aishell"
    public static let version = "0.6.2"
    public static let diagnosticsSchemaVersion = "aishell.native_factory_diagnostics.v1"
    public static let runtimeSchemaVersion = "aishell.runtime_configuration.v3"
    public static let mcpProtocolVersion = "2025-11-25"
}

public struct FactoryDiagnostics: Codable, Equatable, Sendable {
    public struct Product: Codable, Equatable, Sendable {
        public let identifier: String
        public let version: String
    }

    public struct Platform: Codable, Equatable, Sendable {
        public let operatingSystem: String
        public let architecture: String
        public let minimumOperatingSystem: String
        public let supported: Bool
    }

    public struct Runtime: Codable, Equatable, Sendable {
        public let schemaVersion: String
        public let configurationState: String
        public let migrationStatus: String
        public let operationReadiness: String
        public let isPaused: Bool?
        public let configuredRootCount: Int?
        public let automaticGitWorktreeCount: Int?
        public let effectiveRootCount: Int?
    }

    public struct MCP: Codable, Equatable, Sendable {
        public let transport: String
        public let protocolVersion: String
        public let ready: Bool
    }

    public struct Manager: Codable, Equatable, Sendable {
        public let applicationBundleState: String
        public let ready: Bool
    }

    public struct Privacy: Codable, Equatable, Sendable {
        public let exposesAllowedRootPaths: Bool
        public let exposesOperationHistory: Bool
        public let exposesFileContents: Bool
        public let exposesProcessArguments: Bool
    }

    public let schemaVersion: String
    public let product: Product
    public let platform: Platform
    public let runtime: Runtime
    public let mcp: MCP
    public let manager: Manager
    public let privacy: Privacy
    public let ready: Bool
    public let issues: [String]
}

public struct FactoryDiagnosticsService {
    private let store: RuntimeStore
    private let fileManager: FileManager

    public init(store: RuntimeStore = RuntimeStore(), fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
    }

    public func diagnose(managerApplicationURL: URL?, mcpReady: Bool) async -> FactoryDiagnostics {
        let platform = currentPlatform()
        let managerReady = managerApplicationURL.map {
            $0.pathExtension == "app" && fileManager.fileExists(atPath: $0.path)
        } ?? false

        let runtime: FactoryDiagnostics.Runtime
        var issues: [String] = []
        do {
            let configuration = try await store.loadConfiguration()
            let operationReadiness = configuration.isPaused ? "paused" : "ready"

            runtime = FactoryDiagnostics.Runtime(
                schemaVersion: AIShellProduct.runtimeSchemaVersion,
                configurationState: fileManager.fileExists(atPath: store.configurationURL.path)
                    ? "valid"
                    : "uninitialized",
                migrationStatus: "compatible_on_read",
                operationReadiness: operationReadiness,
                isPaused: configuration.isPaused,
                configuredRootCount: 0,
                automaticGitWorktreeCount: 0,
                effectiveRootCount: 0
            )
        } catch {
            runtime = FactoryDiagnostics.Runtime(
                schemaVersion: AIShellProduct.runtimeSchemaVersion,
                configurationState: "invalid",
                migrationStatus: "blocked",
                operationReadiness: "invalid_configuration",
                isPaused: nil,
                configuredRootCount: nil,
                automaticGitWorktreeCount: nil,
                effectiveRootCount: nil
            )
            issues.append("runtime.invalid_configuration")
        }

        if !platform.supported {
            issues.append("platform.unsupported")
        }
        if !managerReady {
            issues.append("manager.application_bundle_unavailable")
        }

        return FactoryDiagnostics(
            schemaVersion: AIShellProduct.diagnosticsSchemaVersion,
            product: .init(identifier: AIShellProduct.identifier, version: AIShellProduct.version),
            platform: platform,
            runtime: runtime,
            mcp: .init(
                transport: "stdio",
                protocolVersion: AIShellProduct.mcpProtocolVersion,
                ready: mcpReady
            ),
            manager: .init(
                applicationBundleState: managerReady ? "available" : "unavailable",
                ready: managerReady
            ),
            privacy: .init(
                exposesAllowedRootPaths: false,
                exposesOperationHistory: false,
                exposesFileContents: false,
                exposesProcessArguments: false
            ),
            ready: mcpReady
                && platform.supported
                && runtime.configurationState != "invalid"
                && managerReady,
            issues: issues
        )
    }

    private func currentPlatform() -> FactoryDiagnostics.Platform {
        #if arch(arm64)
        let architecture = "arm64"
        let architectureSupported = true
        #else
        let architecture = "unsupported"
        let architectureSupported = false
        #endif

        let version = ProcessInfo.processInfo.operatingSystemVersion
        let operatingSystemSupported = version.majorVersion >= 15
        return FactoryDiagnostics.Platform(
            operatingSystem: "macos",
            architecture: architecture,
            minimumOperatingSystem: "15.0",
            supported: architectureSupported && operatingSystemSupported
        )
    }
}
