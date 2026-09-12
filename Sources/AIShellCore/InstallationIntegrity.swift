import Foundation

/// 起動中processが掴んでいる実行ファイルが、install置換で足元から差し替えられていないかを判定するseam。
///
/// npm global upgradeは旧packageを`.name-XXXX`へ退避してから削除するため、窓を開いたままのprocessは
/// 実体の無いbundleを掴み続ける。UIは描画も操作も受け付けるのに、bundle resourceを要求するAPI
/// （`NSOpenPanel`など）だけが無反応になり、errorも出ないまま「ボタンが効かない」と見える。
/// 静かに壊れる代わりに、置換を検知してユーザーへ再起動を促すための判定だけをここが所有する。
public struct InstallationIntegrity: Sendable {
    public enum Status: Equatable, Sendable {
        /// 起動時と同じ実体がそのpathに在る。
        case intact
        /// pathごと消えた（退避後に削除された旧install）。同じpathは開き直せない。
        case executableRemoved
        /// 同じpathに別の実体が入った（in-place置換）。そのpathを開き直せば新版へ移れる。
        case executableReplaced
        /// 起動時のidentityを取れず判定できない。intactと同一視しない。
        case unknown
    }

    /// path文字列ではなく実体で同一性を見る。同じpathへ別buildが入る置換を検知するため、
    /// device/inodeに加えてsizeとmtimeまで比較する。
    public struct FileIdentity: Equatable, Sendable {
        public let deviceID: Int
        public let fileID: Int
        public let size: Int
        public let modifiedAt: Date

        public init?(path: String) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let deviceID = attributes[.systemNumber] as? Int,
                  let fileID = attributes[.systemFileNumber] as? Int,
                  let size = attributes[.size] as? Int,
                  let modifiedAt = attributes[.modificationDate] as? Date else { return nil }
            self.deviceID = deviceID
            self.fileID = fileID
            self.size = size
            self.modifiedAt = modifiedAt
        }
    }

    public let executableURL: URL
    private let launchIdentity: FileIdentity?

    /// 起動直後に生成し、その時点のidentityを基準として保持する。
    public init(executableURL: URL) {
        self.executableURL = executableURL
        launchIdentity = FileIdentity(path: executableURL.path)
    }

    public static func forRunningProcess() -> InstallationIntegrity {
        InstallationIntegrity(
            executableURL: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        )
    }

    public func currentStatus() -> Status {
        guard let launchIdentity else { return .unknown }
        guard let current = FileIdentity(path: executableURL.path) else { return .executableRemoved }
        return current == launchIdentity ? .intact : .executableReplaced
    }
}

extension InstallationIntegrity.Status {
    /// 窓を開き直すまで、bundle resourceを要求する操作が無反応になり得る状態。
    public var requiresRestart: Bool {
        self == .executableRemoved || self == .executableReplaced
    }

    /// 同じbundle pathを開き直すことで新版へ移れるか。消えたpathは開き直せない。
    public var canRelaunchInPlace: Bool {
        self == .executableReplaced
    }
}
