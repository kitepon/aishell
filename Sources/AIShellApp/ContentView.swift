import AIShellCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            installationBanner
            header
            Divider()
            configurationPanel
            Divider()
            activityPanel

        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.poll() }
        .alert("AIShellでエラーが発生しました", isPresented: errorBinding) {
            Button("閉じる") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "不明なエラー")
        }
    }

    /// 実体を差し替えられた窓はUIも操作も受け付けるのにファイル選択だけが無反応になる。
    /// 黙って壊れたままにせず、状態と復帰手段を最上段で明示する。
    @ViewBuilder
    private var installationBanner: some View {
        if model.installationStatus.requiresRestart {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20, weight: .semibold))

                VStack(alignment: .leading, spacing: 3) {
                    Text("新しい版がインストールされ、この窓は古い実体で動いています")
                        .font(.callout.bold())
                    Text(installationBannerDetail)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                if canOfferRelaunch {
                    Button("再起動") { model.relaunchForReplacedInstallation() }
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                } else {
                    Button("終了") { model.quitForRemovedInstallation() }
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                }
            }
            .foregroundStyle(.white)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange)
        }
    }

    /// 一度失敗した再起動を勧め続けない。失敗後は手動での開き直しへ切り替える。
    private var canOfferRelaunch: Bool {
        model.installationStatus.canRelaunchInPlace && model.relaunchFailure == nil
    }

    private var installationBannerDetail: String {
        if let failure = model.relaunchFailure {
            return "新版の起動に失敗しました（\(failure)）。"
                + "終了して aishell-open で開き直してください。"
        }
        if model.installationStatus.canRelaunchInPlace {
            return "この窓は更新前の版です。再起動すると新版へ移ります。"
        }
        return "この窓の実行ファイルは削除済みです。"
            + "終了して aishell-open で開き直してください。"
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "macwindow")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 3) {
                Text("AIShell")
                    .font(.title2.bold())
                Text("AIからmacOS APIへ、shellを介さない直接操作")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            statusBadge
        }
        .padding(20)
    }

    private var statusBadge: some View {
        Label(
            model.isReady ? "操作可能" : "停止中",
            systemImage: model.isReady ? "checkmark.circle.fill" : "pause.circle.fill"
        )
        .font(.callout.weight(.semibold))
        .foregroundStyle(model.isReady ? .green : .orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary, in: Capsule())
    }

    private var configurationPanel: some View {
        HStack {
            Text("フォルダの事前登録は不要です。")
                .foregroundStyle(.secondary)
            Spacer()
            Button(model.configuration.isPaused ? "AI操作を再開" : "AI操作を停止") {
                model.togglePaused()
            }
            .buttonStyle(.borderedProminent)
            .tint(model.configuration.isPaused ? .green : .red)
        }
        .padding(20)
    }

    private var activityPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("操作履歴")
                    .font(.headline)
                Spacer()
                Text("直近100件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.activities.isEmpty {
                ContentUnavailableView(
                    "まだ操作はありません",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("AIからmacOSを操作すると、ここに記録されます。")
                )
            } else {
                List(model.activities) { record in
                    ActivityRow(record: record)
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}

private struct ActivityRow: View {
    let record: OperationRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: record.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(record.success ? .green : .red)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(record.operation)
                        .font(.body.weight(.medium))
                    Spacer()
                    Text(record.timestamp, format: .dateTime.hour().minute().second())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(record.target)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !record.success {
                    Text(record.message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
