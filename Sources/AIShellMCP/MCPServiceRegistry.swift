import AIShellCore
import CryptoKit
import Foundation

/// 遅延生成する共有serviceの所有者。
///
/// `MCPServer`自身はhandlerを並列に走らせうるため、生成済みinstanceを`MCPServer`の
/// 可変propertyへ置くと同時アクセスがdata raceになる。生成と保持をこのactorへ閉じ込め、
/// 生成中のTaskをkeyに保持することで、同時要求を同じinstanceへ合流させる。
/// とくに`ApplyChangeSetService`は同一rootのstate directoryを所有するため、
/// 二重生成は資源の無駄ではなく整合性の破壊になる。
actor MCPServiceRegistry {
    private let store: RuntimeStore
    private let workspaceRuntime: WorkspaceStateRuntime
    private let injectedManagedRuns: ManagedRunService?
    private var changeSetTasks: [String: Task<ApplyChangeSetService, any Error>] = [:]
    private var managedRuns: ManagedRunService?

    init(
        store: RuntimeStore,
        workspaceRuntime: WorkspaceStateRuntime,
        managedRunService: ManagedRunService?
    ) {
        self.store = store
        self.workspaceRuntime = workspaceRuntime
        injectedManagedRuns = managedRunService
    }

    /// 対象フォルダごとに1つの`ApplyChangeSetService`を返す。
    /// rootは存在確認済みの、解決済み絶対pathであること。
    func changeSetService(root: URL) async throws -> ApplyChangeSetService {
        if let task = changeSetTasks[root.path] {
            return try await task.value
        }
        let store = self.store
        let workspaceRuntime = self.workspaceRuntime
        let stateDirectory = Self.stateDirectory(baseDirectory: store.baseDirectory, root: root)
        let task = Task {
            try await ApplyChangeSetService.production(
                runtimeStore: store,
                root: root,
                stateDirectory: stateDirectory,
                workspaceRuntime: workspaceRuntime
            )
        }
        changeSetTasks[root.path] = task
        do {
            return try await task.value
        } catch {
            // 生成失敗をcacheすると以後同じerrorを返し続ける。後から別のTaskへ
            // 差し替えられていない場合だけ捨て、次の要求で再生成できるようにする。
            if changeSetTasks[root.path] == task {
                changeSetTasks[root.path] = nil
            }
            throw error
        }
    }

    /// process全体で1つの`ManagedRunService`を返す。初期化はthrowsだが同期であり、
    /// actor内でawaitを挟まないため、この関数の本体は不可分に実行される。
    func managedRunService() throws -> ManagedRunService {
        if let injectedManagedRuns { return injectedManagedRuns }
        if let managedRuns { return managedRuns }
        let service = try ManagedRunService(
            runtimeStore: store,
            supervisorExecutableURL: Self.supervisorExecutableURL()
        )
        managedRuns = service
        return service
    }

    private static func stateDirectory(baseDirectory: URL, root: URL) -> URL {
        let digest = SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return baseDirectory
            .appendingPathComponent("apply-change-set", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
    }

    private static func supervisorExecutableURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["AISHELL_RUN_SUPERVISOR_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("aishell-run-supervisor")
    }
}
