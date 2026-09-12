import AppKit
import Foundation

@MainActor
public final class NativeApplicationService {
    private let store: RuntimeStore

    public init(store: RuntimeStore = RuntimeStore()) {
        self.store = store
    }

    public func listRunningApplications() async throws -> [RunningApplicationInfo] {
        try await ensureActive()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map {
                RunningApplicationInfo(
                    name: $0.localizedName ?? $0.bundleIdentifier ?? "不明なアプリ",
                    bundleIdentifier: $0.bundleIdentifier,
                    processIdentifier: $0.processIdentifier,
                    isActive: $0.isActive
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func listInstalledApplications() async throws -> [InstalledApplicationInfo] {
        try await ensureActive()
        return discoverInstalledApplications()
    }

    private func discoverInstalledApplications() -> [InstalledApplicationInfo] {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        var applications: [InstalledApplicationInfo] = []
        var seenPaths: Set<String> = []

        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension == "app" {
                guard seenPaths.insert(url.path).inserted else { continue }
                let bundle = Bundle(url: url)
                applications.append(InstalledApplicationInfo(
                    name: bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                        ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                        ?? url.deletingPathExtension().lastPathComponent,
                    bundleIdentifier: bundle?.bundleIdentifier,
                    path: url.path
                ))
            }
        }

        return applications.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func openApplication(bundleIdentifier: String) async throws -> RunningApplicationInfo {
        try await audited(operation: "apps.open", target: bundleIdentifier) {
            try await ensureActive()
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                throw AIShellError.applicationNotFound(bundleIdentifier)
            }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let application = try await NSWorkspace.shared.openApplication(
                at: url,
                configuration: configuration
            )
            return RunningApplicationInfo(
                name: application.localizedName ?? bundleIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                processIdentifier: application.processIdentifier,
                isActive: application.isActive
            )
        }
    }

    public func activateApplication(bundleIdentifier: String) async throws -> RunningApplicationInfo {
        try await audited(operation: "apps.activate", target: bundleIdentifier) {
            try await ensureActive()
            guard let application = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .first else {
                throw AIShellError.applicationNotFound(bundleIdentifier)
            }

            guard application.activate(options: [.activateAllWindows]) else {
                throw AIShellError.applicationActivationFailed(bundleIdentifier)
            }

            return RunningApplicationInfo(
                name: application.localizedName ?? bundleIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                processIdentifier: application.processIdentifier,
                isActive: application.isActive
            )
        }
    }

    private func ensureActive() async throws {
        let configuration = try await store.loadConfiguration()
        guard !configuration.isPaused else { throw AIShellError.paused }
    }

    private func audited<T: Sendable>(
        operation: String,
        target: String,
        body: () async throws -> T
    ) async throws -> T {
        do {
            let result = try await body()
            try? await store.appendActivity(OperationRecord(
                operation: operation,
                target: target,
                success: true,
                message: "完了"
            ))
            return result
        } catch {
            try? await store.appendActivity(OperationRecord(
                operation: operation,
                target: target,
                success: false,
                message: error.localizedDescription
            ))
            throw error
        }
    }
}
