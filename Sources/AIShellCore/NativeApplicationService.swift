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

    /// AIShellが停止中でも、利用者が設定を直せるよう管理アプリだけは開けます。
    public func openManagerApplication(at applicationURL: URL) async throws -> RunningApplicationInfo {
        let canonicalURL = applicationURL.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalURL.pathExtension == "app",
              FileManager.default.fileExists(atPath: canonicalURL.path),
              let bundle = Bundle(url: canonicalURL) else {
            throw AIShellError.invalidPath(
                "AIShell.appを見つけられません。@quolu/aishellを再インストールしてください。"
            )
        }

        return try await audited(operation: "runtime.openManager", target: canonicalURL.path) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let application = try await NSWorkspace.shared.openApplication(
                at: canonicalURL,
                configuration: configuration
            )
            // LaunchServicesのcompletion直後はPID再検索がnilになり得る。
            // 返却されたapp自身でNSApplicationの起動完了を観測する。
            let deadline = Date().addingTimeInterval(10)
            while !application.isFinishedLaunching && !application.isTerminated {
                guard Date() < deadline else {
                    throw AIShellError.invalidArgument("AIShell管理アプリの起動完了が制限時間を超えました。")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard !application.isTerminated,
                  application.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == canonicalURL else {
                throw AIShellError.invalidArgument("導入済みAIShell管理アプリの実行を確認できません。")
            }
            return RunningApplicationInfo(
                name: application.localizedName
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? "AIShell",
                bundleIdentifier: application.bundleIdentifier ?? bundle.bundleIdentifier,
                processIdentifier: application.processIdentifier,
                isActive: application.isActive
            )
        }
    }

    /// 明示setup時は旧bundleを参照するprocessも終了し、導入済みのappを確認してから返す。
    /// npm install自体からは呼ばない。停止状態の変更もしない。
    public func prepareManagerApplication(at applicationURL: URL) async throws -> RunningApplicationInfo {
        guard let identifier = Bundle(url: applicationURL)?.bundleIdentifier else {
            throw AIShellError.invalidPath("導入済みAIShell.appのbundleを読み取れません。")
        }
        let previous = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        for application in previous {
            guard application.terminate() else {
                throw AIShellError.invalidArgument("旧AIShell管理アプリを終了できません。")
            }
        }
        let deadline = Date().addingTimeInterval(10)
        while previous.contains(where: { !$0.isTerminated }) {
            guard Date() < deadline else {
                throw AIShellError.invalidArgument("旧AIShell管理アプリの終了が制限時間を超えました。")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try await openManagerApplication(at: applicationURL)
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
