import Foundation

public actor RuntimeStore {
    public static let productDirectoryName = "AIShell"

    public nonisolated let baseDirectory: URL
    public nonisolated let configurationURL: URL
    public nonisolated let activityURL: URL

    var workingDirectory: URL

    public func pathResolver() -> PathResolver {
        PathResolver(baseDirectory: workingDirectory)
    }

    public init(baseDirectory: URL? = nil, workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
        self.workingDirectory = workingDirectory

        let resolvedBase: URL
        if let baseDirectory {
            resolvedBase = baseDirectory
        } else if let isolatedPath = ProcessInfo.processInfo.environment["AISHELL_STATE_DIRECTORY"],
                  !isolatedPath.isEmpty {
            resolvedBase = URL(fileURLWithPath: isolatedPath, isDirectory: true).standardizedFileURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            resolvedBase = applicationSupport.appendingPathComponent(Self.productDirectoryName, isDirectory: true)
        }

        self.baseDirectory = resolvedBase
        configurationURL = resolvedBase.appendingPathComponent("runtime.json")
        activityURL = resolvedBase.appendingPathComponent("activity.jsonl")
    }

    public func loadConfiguration() throws -> RuntimeConfiguration {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            return RuntimeConfiguration()
        }

        let data = try Data(contentsOf: configurationURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RuntimeConfiguration.self, from: data)
    }

    public func saveConfiguration(_ configuration: RuntimeConfiguration) throws {
        try ensureBaseDirectory()
        var updated = configuration
        updated.updatedAt = Date()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(updated)
        try data.write(to: configurationURL, options: .atomic)
    }

    @discardableResult
    public func setPaused(_ isPaused: Bool) throws -> RuntimeConfiguration {
        var configuration = try loadConfiguration()
        configuration.isPaused = isPaused
        try saveConfiguration(configuration)
        return configuration
    }

    public func appendActivity(_ record: OperationRecord) throws {
        try ensureBaseDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(record)
        data.append(0x0A)

        if !FileManager.default.fileExists(atPath: activityURL.path) {
            FileManager.default.createFile(atPath: activityURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: activityURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    public func loadRecentActivities(limit: Int = 100) throws -> [OperationRecord] {
        guard FileManager.default.fileExists(atPath: activityURL.path) else {
            return []
        }

        let data = try Data(contentsOf: activityURL)
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = text
            .split(separator: "\n")
            .compactMap { line in
                try? decoder.decode(OperationRecord.self, from: Data(line.utf8))
            }

        return Array(records.suffix(max(0, limit))).reversed()
    }

    private func ensureBaseDirectory() throws {
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
    }

}
