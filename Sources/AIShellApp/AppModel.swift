import AIShellCore
import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var configuration = RuntimeConfiguration()
    @Published private(set) var activities: [OperationRecord] = []
    @Published private(set) var installationStatus: InstallationIntegrity.Status = .intact
    /// 再起動の失敗はbanner上に残す。1秒ごとのrefreshが消すerrorMessageへ載せると、
    /// 失敗が黙って流れてユーザーには「押しても何も起きない」と見える。
    @Published private(set) var relaunchFailure: String?
    @Published var errorMessage: String?

    private let store = RuntimeStore()
    private let integrity = InstallationIntegrity.forRunningProcess()

    var isReady: Bool {
        !configuration.isPaused
    }

    func togglePaused() {
        Task {
            do {
                configuration = try await store.setPaused(!configuration.isPaused)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 新版installで実体を差し替えられた窓は、同じpathの新bundleを開いてから自分を終了する。
    /// pathごと消えている場合は開き直せないため、この経路は呼ばない。
    func relaunchForReplacedInstallation() {
        guard installationStatus.canRelaunchInPlace else { return }
        relaunchFailure = nil
        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { [weak self] launched, error in
            Task { @MainActor in
                guard let self else { return }
                // 置換された窓はbundle identityを失っており、LaunchServices経由の起動も失敗し得る。
                // その時は黙って諦めず、失敗を残して手動での開き直しへ誘導する。
                if let error {
                    self.reportRelaunchFailure(error.localizedDescription)
                    return
                }
                guard launched != nil else {
                    self.reportRelaunchFailure("新版のprocessが起動しませんでした。")
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    private func reportRelaunchFailure(_ reason: String) {
        relaunchFailure = reason
        FileHandle.standardError.write(Data("AIShell: relaunch failed: \(reason)\n".utf8))
    }

    func quitForRemovedInstallation() {
        NSApp.terminate(nil)
    }

    func refresh() async {
        installationStatus = integrity.currentStatus()
        do {
            configuration = try await store.loadConfiguration()
            activities = try await store.loadRecentActivities(limit: 100)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
