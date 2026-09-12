import CryptoKit
import Darwin
import Foundation

public struct WorkspaceRelevantInputObservation: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let providerVersion: String
    public let projectRoot: String
    public let projectRootIdentity: String
    public let workspaceCursor: String
    public let leafCount: Int
    public let completeness: String
    public let merkleDigest: String
}

public enum WorkspaceRelevantInputObservationError: Error, Equatable, Sendable {
    case contractIneligible(String)
    case invalidContractPath(String)
    case projectRootIdentityChanged
    case workspaceCursorChanged
    case symlinkEncountered(String)
    case observationChanged
}

public actor WorkspaceStateRuntime {
    public struct KnownMutation: Equatable, Sendable {
        public let kind: WorkspaceChangeKind
        public let path: String
        public let previousPath: String?

        public init(kind: WorkspaceChangeKind, path: String, previousPath: String? = nil) {
            self.kind = kind
            self.path = path
            self.previousPath = previousPath
        }
    }

    private struct RootState {
        let root: URL
        let rootIdentity: String
        let rootDigest: String
        let exclusionDigest: String
        let eventStoreUUID: String?
        var entries: [String: WorkspaceEntry]
        var prefetchedPaths: Set<String>
        var prefetchedEntries: [String: WorkspaceEntry]
        var journal: ObservationJournal
        var knownTransactionIDs: Set<String>
        var knownChangesBySequence: [UInt64: WorkspaceChange]
        var knownEchoes: [String: WorkspaceEntry?]
        var checkpointState: String
        var observer: FSEventsObserver?
        var lastAccessedAt: Date
    }

    private let runtimeStore: RuntimeStore
    private let checkpointStore: WorkspaceCheckpointStore
    private let startsFSEvents: Bool
    private let initializationEventsForTests: [ObservedFileEvent]
    private let rebuildHookForTests: (@Sendable () throws -> [ObservedFileEvent])?
    private let eventStoreUUIDProvider: @Sendable (URL) throws -> String?
    private let relevantInputObservationHookForTests: (@Sendable () throws -> Void)?
    private var states: [String: RootState] = [:]
    private let journalLimit: Int
    private let stateLimit = 8
    private var scanInvocationCount = 0
    private var contentReadCount = 0

    public init(
        runtimeStore: RuntimeStore = RuntimeStore(),
        startsFSEvents: Bool = true,
        journalLimit: Int = 10_000
    ) {
        self.runtimeStore = runtimeStore
        checkpointStore = WorkspaceCheckpointStore(baseDirectory: runtimeStore.baseDirectory)
        self.startsFSEvents = startsFSEvents
        initializationEventsForTests = []
        rebuildHookForTests = nil
        relevantInputObservationHookForTests = nil
        eventStoreUUIDProvider = Self.eventStoreUUID
        self.journalLimit = max(1, journalLimit)
    }

    init(
        runtimeStore: RuntimeStore,
        startsFSEvents: Bool = true,
        journalLimit: Int = 10_000,
        initializationEventsForTests: [ObservedFileEvent],
        rebuildHookForTests: (@Sendable () throws -> [ObservedFileEvent])? = nil,
        eventStoreUUIDProviderForTests: (@Sendable (URL) throws -> String?)? = nil,
        relevantInputObservationHookForTests: (@Sendable () throws -> Void)? = nil
    ) {
        self.runtimeStore = runtimeStore
        checkpointStore = WorkspaceCheckpointStore(baseDirectory: runtimeStore.baseDirectory)
        self.startsFSEvents = startsFSEvents
        self.initializationEventsForTests = initializationEventsForTests
        self.rebuildHookForTests = rebuildHookForTests
        self.relevantInputObservationHookForTests = relevantInputObservationHookForTests
        eventStoreUUIDProvider = eventStoreUUIDProviderForTests ?? Self.eventStoreUUID
        self.journalLimit = max(1, journalLimit)
    }

    public func snapshot(
        path: String? = nil,
        sinceCursor: String? = nil,
        entryLimit: Int = 500,
        contextBudget: Int = 16_384,
        contextPaths: [String]? = nil
    ) async throws -> WorkspaceSnapshot {
        let resolver = try await activeResolver()
        let root = try resolver.resolveExisting(path)
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw AIShellError.invalidPath(root.path)
        }
        let key = root.path
        let currentRootIdentity = try Self.fileIdentity(root)
        if let existing = states[key], existing.rootIdentity != currentRootIdentity {
            _ = existing.observer?.drainThroughCurrent()
            states.removeValue(forKey: key)
            if sinceCursor != nil {
                throw AIShellError.rescanRequired("workspace root identity changed")
            }
        }
        let newlyInitialized = states[key] == nil
        if newlyInitialized {
            try await initialize(root: root, key: key, requestedCursor: sinceCursor)
        }
        guard var state = states[key] else { throw AIShellError.invalidPath(root.path) }
        state.lastAccessedAt = Date()
        states[key] = state
        let limit = min(max(1, entryLimit), 5_000)

        if let sinceCursor {
            let initialCursor = try parseCursor(sinceCursor)
            if state.observer != nil {
                try await Task.sleep(for: .milliseconds(500))
            }
            drainObserver(for: key)
            guard let refreshed = states[key] else { throw AIShellError.invalidPath(root.path) }
            state = refreshed
            if let reason = state.journal.rescanReason { throw AIShellError.rescanRequired(reason) }
            let parsed = initialCursor
            guard parsed.rootDigest == state.rootDigest,
                  parsed.exclusionDigest == state.exclusionDigest,
                  parsed.generation == state.journal.generation,
                  parsed.sequence <= state.journal.sequence else {
                throw AIShellError.cursorExpired(sinceCursor)
            }
            if state.journal.events.isEmpty, parsed.sequence < state.journal.sequence {
                throw AIShellError.cursorExpired(sinceCursor)
            }
            if let first = state.journal.events.first, parsed.sequence + 1 < first.sequence {
                throw AIShellError.cursorExpired(sinceCursor)
            }
            let pendingEvents = state.journal.events.filter { $0.sequence > parsed.sequence }
            var uniqueEvents: [(path: String, sequence: UInt64)] = []
            for event in pendingEvents where !uniqueEvents.contains(where: { $0.path == event.path }) {
                uniqueEvents.append((event.path, event.sequence))
            }
            var observedPaths = uniqueEvents.prefix(limit).map(\.path)
            var expanded = true
            while expanded, observedPaths.count < uniqueEvents.count {
                expanded = false
                for selectedPath in observedPaths {
                    let remainder = uniqueEvents.dropFirst(observedPaths.count)
                    if let pairIndex = try remainder.firstIndex(where: {
                        try formsRenamePair(selectedPath, $0.path, state: state)
                    }) {
                        observedPaths = uniqueEvents.prefix(pairIndex + 1).map(\.path)
                        expanded = true
                        break
                    }
                }
            }
            let selected = Set(observedPaths)
            var processedSequence = parsed.sequence
            for event in pendingEvents {
                guard selected.contains(event.path) else { break }
                processedSequence = event.sequence
            }
            var changes: [WorkspaceChange] = []
            var externalPaths: [String] = []
            for event in uniqueEvents where selected.contains(event.path) {
                if let known = state.knownChangesBySequence[event.sequence] {
                    changes.append(known)
                } else {
                    externalPaths.append(event.path)
                }
            }
            let reconciledChanges = try reconcile(paths: externalPaths, state: &state)
            for change in reconciledChanges {
                if let event = uniqueEvents.first(where: {
                    Self.relativePath($0.path, root: root.path) == change.path
                        || Self.relativePath($0.path, root: root.path) == change.previousPath
                }) {
                    state.knownChangesBySequence[event.sequence] = change
                }
            }
            changes.append(contentsOf: reconciledChanges)
            changes.sort {
                if $0.path != $1.path { return $0.path < $1.path }
                return Self.changeOrder($0.kind) < Self.changeOrder($1.kind)
            }
            for path in observedPaths {
                let relative = Self.relativePath(path, root: state.root.path)
                state.prefetchedPaths.remove(relative)
                state.prefetchedEntries.removeValue(forKey: relative)
            }
            states[key] = state
            // delta consumerの進捗はretained journalのackではない。restart後のfan-out用に全区間を保持する。
            try await persistCheckpoint(state)
            let changedEntries = changes.compactMap(\.entry)
            let remainingPaths = Set(pendingEvents.filter { $0.sequence > processedSequence }.map(\.path))
            let git = try gitStatus(root: root)
            return WorkspaceSnapshot(
                schemaVersion: "aishell.workspace-snapshot.v1",
                root: root.path,
                cursor: cursor(for: state, sequence: processedSequence),
                isFull: false,
                freshness: "fresh",
                checkpointState: state.checkpointState,
                entries: [],
                changes: changes,
                omittedEntries: remainingPaths.count,
                manifests: Array(manifestPaths(in: state.entries).prefix(100)),
                guidanceFiles: Array(guidancePaths(in: state.entries).prefix(100)),
                testCandidates: testPaths(in: state.entries),
                gitStatusState: git.state,
                gitStatus: git.lines,
                context: try contextChunks(
                    root: root,
                    candidates: try contextCandidates(entries: state.entries, root: root, paths: contextPaths, defaults: changedEntries),
                    budget: contextBudget
                )
            )
        }

        if !newlyInitialized || state.journal.rescanReason != nil {
            state.journal.startNewGeneration(UUID().uuidString.lowercased())
            state.knownChangesBySequence.removeAll(keepingCapacity: true)
            state.checkpointState = "rebuilt"
            state.prefetchedPaths.removeAll(keepingCapacity: true)
            state.prefetchedEntries.removeAll(keepingCapacity: true)
            state.entries = try scan(root: root)
            states[key] = state
            if let rebuildHookForTests {
                ingest(try rebuildHookForTests())
            }
            drainObserver(for: key)
            guard let refreshed = states[key] else { throw AIShellError.invalidPath(root.path) }
            state = refreshed
            if let reason = state.journal.rescanReason {
                throw AIShellError.rescanRequired("full rebuild observation failed: \(reason)")
            }
        }
        if !state.journal.events.isEmpty {
            let appliedSequence = state.journal.sequence
            _ = try reconcile(paths: state.journal.events.map(\.path), state: &state)
            // full snapshotはそのcursor自体が新しいconsumer基点になるcheckpoint圧縮点。
            // delta snapshotだけが既存consumerのretained intervalを保持する。
            state.journal.discardEvents(through: appliedSequence)
            state.knownChangesBySequence.removeAll(keepingCapacity: true)
        }
        state.prefetchedPaths.removeAll(keepingCapacity: true)
        state.prefetchedEntries.removeAll(keepingCapacity: true)
        states[key] = state
        try await persistCheckpoint(state)
        let sorted = state.entries.values.sorted { $0.path < $1.path }
        let visible = Array(sorted.prefix(limit))
        let git = try gitStatus(root: root)
        return WorkspaceSnapshot(
            schemaVersion: "aishell.workspace-snapshot.v1",
            root: root.path,
            cursor: cursor(for: state),
            isFull: true,
            freshness: "fresh",
            checkpointState: state.checkpointState,
            entries: visible,
            changes: [],
            omittedEntries: sorted.count - visible.count,
            manifests: Array(manifestPaths(in: state.entries).prefix(100)),
            guidanceFiles: Array(guidancePaths(in: state.entries).prefix(100)),
            testCandidates: testPaths(in: state.entries),
            gitStatusState: git.state,
            gitStatus: git.lines,
            context: contextBudget > 0 ? try contextChunks(
                root: root,
                candidates: try contextCandidates(entries: state.entries, root: root, paths: contextPaths, defaults: Self.prioritizedContextEntries(in: state.entries)),
                budget: contextBudget
            ) : []
        )
    }

    /// Cursorだけを必要とする検索開始時に、presentation用の全entry sortやcontext生成を行わず
    /// checkpointとFSEvents差分を現在状態へ収束させる。
    func currentSearchCursor(path: String? = nil) async throws -> String {
        let resolver = try await activeResolver()
        let requested = try resolver.resolveExisting(path)
        guard try requested.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw AIShellError.invalidPath(requested.path)
        }
        let owner = try EffectiveRootProjectCatalog(rootURLs: [requested]).resolveOwner(for: requested)
        let root = owner.root
        let key = root.path
        if let existing = states[key], existing.rootIdentity != owner.rootIdentity {
            _ = existing.observer?.drainThroughCurrent()
            states.removeValue(forKey: key)
        }
        if states[key] == nil {
            try await initialize(
                root: root,
                key: key,
                requestedCursor: nil,
                reconcileFilesystem: false
            )
        }
        if states[key]?.observer != nil {
            try await Task.sleep(for: .milliseconds(500))
        }
        drainObserver(for: key)
        guard var state = states[key] else { throw AIShellError.invalidPath(root.path) }
        var needsPersistence = false

        if state.journal.rescanReason != nil {
            state.journal.startNewGeneration(UUID().uuidString.lowercased())
            state.knownChangesBySequence.removeAll(keepingCapacity: true)
            state.checkpointState = "rebuilt"
            state.prefetchedPaths.removeAll(keepingCapacity: true)
            state.prefetchedEntries.removeAll(keepingCapacity: true)
            state.entries = try scan(root: root)
            states[key] = state
            if let rebuildHookForTests {
                ingest(try rebuildHookForTests())
            }
            drainObserver(for: key)
            guard let refreshed = states[key] else { throw AIShellError.invalidPath(root.path) }
            state = refreshed
            if let reason = state.journal.rescanReason {
                throw AIShellError.rescanRequired("search baseline rebuild failed: \(reason)")
            }
            needsPersistence = true
        }
        if !state.journal.events.isEmpty {
            let retained = state.journal.events
            let changes = try reconcile(paths: retained.map(\.path), state: &state)
            // 検索開始は他consumerのackではない。照合済み差分もcursorの保持区間に残す。
            for change in changes {
                for event in retained where
                    Self.relativePath(event.path, root: root.path) == change.path
                        || Self.relativePath(event.path, root: root.path) == change.previousPath {
                    state.knownChangesBySequence[event.sequence] = change
                }
            }
            needsPersistence = true
        }
        state.prefetchedPaths.removeAll(keepingCapacity: true)
        state.prefetchedEntries.removeAll(keepingCapacity: true)
        state.lastAccessedAt = Date()
        states[key] = state
        if needsPersistence {
            try await persistCheckpoint(state)
        }
        return cursor(for: state)
    }

    func ingestObservedPaths(_ paths: [String]) {
        ingest(paths.map { ObservedFileEvent(path: $0, eventID: 0, flags: 0) })
    }

    func ingestObservedEventsForTests(_ events: [ObservedFileEvent]) {
        ingest(events)
    }

    func markRescanRequired(reason: String) {
        for key in states.keys {
            states[key]?.journal.markRescanRequired(reason)
        }
    }

    public func recentChangedPaths() -> [String] {
        var result: [String] = []
        for state in states.values {
            for event in state.journal.events.suffix(500) where !result.contains(event.path) {
                result.append(event.path)
            }
        }
        return result
    }

    /// bounded snapshotとは別に、contractが宣言したclosureをDirect OSから完全再観測する。
    /// 同じleaf集合を二度測り、root identity / retained cursorを含めて一致した時だけ返す。
    public func observeRelevantInputs(
        ownerRootPath: String,
        projectRootPath: String,
        expectedProjectRootIdentity: String,
        expectedCursor: String,
        contract: ProjectProfileCheckInputContract
    ) async throws -> WorkspaceRelevantInputObservation {
        guard contract.schemaVersion == "aishell.project-profile-check-input.v1",
              contract.completeness == .complete,
              contract.effectCompleteness == .projectRootClosed else {
            throw WorkspaceRelevantInputObservationError.contractIneligible(
                contract.reason ?? "input/effect completenessが証明されていません"
            )
        }
        let resolver = try await activeResolver()
        let ownerRoot = try resolver.resolveExisting(ownerRootPath)
        let projectRoot = try resolver.resolveExisting(projectRootPath)
        guard Self.contains(projectRoot.path, in: ownerRoot.path) else {
            throw AIShellError.outsideWorkspace(projectRoot.path)
        }
        guard try Self.fileIdentity(projectRoot) == expectedProjectRootIdentity else {
            throw WorkspaceRelevantInputObservationError.projectRootIdentityChanged
        }
        try attestRelevantInputCursor(ownerRoot: ownerRoot, expectedCursor: expectedCursor)

        let first = try Self.measureRelevantInputs(projectRoot: projectRoot, contract: contract)
        try relevantInputObservationHookForTests?()
        drainObserver(for: ownerRoot.path)
        guard try Self.fileIdentity(projectRoot) == expectedProjectRootIdentity else {
            throw WorkspaceRelevantInputObservationError.projectRootIdentityChanged
        }
        try attestRelevantInputCursor(ownerRoot: ownerRoot, expectedCursor: expectedCursor)
        let second = try Self.measureRelevantInputs(projectRoot: projectRoot, contract: contract)
        guard first == second else {
            throw WorkspaceRelevantInputObservationError.observationChanged
        }
        return WorkspaceRelevantInputObservation(
            schemaVersion: "aishell.relevant-input-observation.v1",
            providerVersion: "direct-os-merkle-v1",
            projectRoot: projectRoot.path,
            projectRootIdentity: expectedProjectRootIdentity,
            workspaceCursor: expectedCursor,
            leafCount: first.leafCount,
            completeness: "complete",
            merkleDigest: first.digest
        )
    }

    private func attestRelevantInputCursor(ownerRoot: URL, expectedCursor: String) throws {
        guard let state = states[ownerRoot.path] else {
            throw AIShellError.rescanRequired("workspace observation stateがありません")
        }
        if let reason = state.journal.rescanReason { throw AIShellError.rescanRequired(reason) }
        guard cursor(for: state) == expectedCursor else {
            throw WorkspaceRelevantInputObservationError.workspaceCursorChanged
        }
    }

    private struct RelevantInputMeasurement: Equatable {
        let leafCount: Int
        let digest: String
    }

    private static func measureRelevantInputs(
        projectRoot: URL,
        contract: ProjectProfileCheckInputContract
    ) throws -> RelevantInputMeasurement {
        var leaves: [String: Data] = [:]
        for path in contract.includedRoots + contract.trackedPaths {
            let relative = try validatedContractPath(path)
            let candidate = relative.isEmpty ? projectRoot : projectRoot.appendingPathComponent(relative)
            guard contains(candidate.standardizedFileURL.path, in: projectRoot.path) else {
                throw WorkspaceRelevantInputObservationError.invalidContractPath(path)
            }
            try measureRelevantNode(candidate, relative: relative, projectRoot: projectRoot, leaves: &leaves)
        }
        let ordered = leaves.keys.sorted(by: canonicalLess).compactMap { leaves[$0] }
        var aggregate = Data("aishell.relevant-input-merkle.v1".utf8)
        for leaf in ordered { appendLengthPrefixed(leaf, to: &aggregate) }
        return RelevantInputMeasurement(leafCount: ordered.count, digest: sha256(aggregate))
    }

    private static func measureRelevantNode(
        _ url: URL,
        relative: String,
        projectRoot: URL,
        leaves: inout [String: Data]
    ) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            leaves["missing:\(relative)"] = canonicalLeaf("missing", [relative])
            return
        }
        let kind = info.st_mode & S_IFMT
        guard kind != S_IFLNK else {
            throw WorkspaceRelevantInputObservationError.symlinkEncountered(relative)
        }
        guard contains(url.standardizedFileURL.path, in: projectRoot.path) else {
            throw AIShellError.outsideWorkspace(url.path)
        }
        let identity = "\(info.st_dev):\(info.st_ino)"
        let mode = String(info.st_mode, radix: 8)
        if kind == S_IFDIR {
            let children = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            ).sorted { canonicalLess($0.lastPathComponent, $1.lastPathComponent) }
            var members: [String] = []
            for child in children {
                var childInfo = stat()
                guard lstat(child.path, &childInfo) == 0 else {
                    throw WorkspaceRelevantInputObservationError.observationChanged
                }
                let childKind = childInfo.st_mode & S_IFMT
                guard childKind != S_IFLNK else {
                    let childRelative = relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent
                    throw WorkspaceRelevantInputObservationError.symlinkEncountered(childRelative)
                }
                members.append("\(child.lastPathComponent)\u{0}\(childKind)\u{0}\(childInfo.st_dev):\(childInfo.st_ino)")
            }
            leaves["directory:\(relative)"] = canonicalLeaf("directory", [relative, identity, mode] + members)
            for child in children {
                let childRelative = relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent
                try measureRelevantNode(child, relative: childRelative, projectRoot: projectRoot, leaves: &leaves)
            }
        } else if kind == S_IFREG {
            let hash = try hashCompleteFile(url)
            var after = stat()
            guard lstat(url.path, &after) == 0,
                  after.st_dev == info.st_dev,
                  after.st_ino == info.st_ino,
                  after.st_mode == info.st_mode,
                  after.st_size == info.st_size,
                  after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else {
                throw WorkspaceRelevantInputObservationError.observationChanged
            }
            leaves["file:\(relative)"] = canonicalLeaf("file", [relative, identity, mode, hash])
        } else {
            throw WorkspaceRelevantInputObservationError.invalidContractPath(relative)
        }
    }

    private static func validatedContractPath(_ path: String) throws -> String {
        if path.isEmpty || path == "." { return "" }
        guard !path.hasPrefix("/") else {
            throw WorkspaceRelevantInputObservationError.invalidContractPath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(".."), !components.contains("."),
              !components.contains(where: \.isEmpty), !path.contains("\u{0}") else {
            throw WorkspaceRelevantInputObservationError.invalidContractPath(path)
        }
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func canonicalLeaf(_ domain: String, _ fields: [String]) -> Data {
        var data = Data("aishell.relevant-input-leaf.v1".utf8)
        appendLengthPrefixed(Data(domain.utf8), to: &data)
        for field in fields { appendLengthPrefixed(Data(field.utf8), to: &data) }
        return Data(SHA256.hash(data: data))
    }

    private static func appendLengthPrefixed(_ value: Data, to data: inout Data) {
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }

    private static func hashCompleteFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// search、snapshot、wait共通のretained observation view。同じ区間のreadはjournalを消費しない。
    public func workspaceDeltaObservation(
        path: String? = nil,
        fromCursor: String
    ) async throws -> WorkspaceDeltaObservation {
        try await workspaceDeltaObservation(
            path: path,
            fromCursor: fromCursor,
            deliveryGrace: .milliseconds(500)
        )
    }

    func workspaceDeltaObservation(
        path: String? = nil,
        fromCursor: String,
        deliveryGrace: Duration,
        includeIndexedFiles: Bool = true
    ) async throws -> WorkspaceDeltaObservation {
        let resolver = try await activeResolver()
        let requested = try resolver.resolveExisting(path)
        guard try requested.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw AIShellError.invalidPath(requested.path)
        }
        let owner = try EffectiveRootProjectCatalog(rootURLs: [requested]).resolveOwner(for: requested)
        let root = owner.root
        let key = root.path
        if states[key] == nil {
            try await initialize(root: root, key: key, requestedCursor: fromCursor)
        }
        if states[key]?.observer != nil, deliveryGrace > .zero {
            try await Task.sleep(for: deliveryGrace)
        }
        drainObserver(for: key)
        guard var state = states[key] else { throw AIShellError.invalidPath(root.path) }
        guard state.rootIdentity == owner.rootIdentity else {
            throw AIShellError.rescanRequired("workspace root identity changed")
        }
        if let reason = state.journal.rescanReason { throw AIShellError.rescanRequired(reason) }

        let parsed = try parseCursor(fromCursor)
        guard parsed.rootDigest == state.rootDigest,
              parsed.exclusionDigest == state.exclusionDigest,
              parsed.generation == state.journal.generation,
              parsed.sequence <= state.journal.sequence else {
            throw AIShellError.cursorExpired(fromCursor)
        }
        if state.journal.events.isEmpty, parsed.sequence < state.journal.sequence {
            throw AIShellError.cursorExpired(fromCursor)
        }
        if let first = state.journal.events.first, parsed.sequence + 1 < first.sequence {
            throw AIShellError.cursorExpired(fromCursor)
        }

        let retained = state.journal.events.filter { $0.sequence > parsed.sequence }
        let reconciled = try reconcile(paths: retained.map(\.path), state: &state)
        for change in reconciled {
            if let event = retained.first(where: {
                Self.relativePath($0.path, root: root.path) == change.path
                    || Self.relativePath($0.path, root: root.path) == change.previousPath
            }) {
                state.knownChangesBySequence[event.sequence] = change
            }
        }
        states[key] = state
        var changedPaths = Set(retained.map { Self.relativePath($0.path, root: root.path) })
        for change in state.knownChangesBySequence
            .filter({ $0.key > parsed.sequence })
            .map(\.value) {
            changedPaths.insert(change.path)
            if let previous = change.previousPath { changedPaths.insert(previous) }
        }
        let indexedFiles: [SearchContextIndexedFile]
        if includeIndexedFiles {
            indexedFiles = state.entries.values.compactMap { entry -> SearchContextIndexedFile? in
                guard !entry.isDirectory, let sha256 = entry.sha256 else { return nil }
                return SearchContextIndexedFile(path: entry.path, fileIdentity: entry.identity, contentSHA256: sha256)
            }.sorted { Self.canonicalLess($0.path, $1.path) }
        } else {
            indexedFiles = []
        }
        let throughCursor = cursor(for: state)
        let changedDigest = SHA256.hash(data: Data(changedPaths.sorted().joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }.joined()
        let viewID = SHA256.hash(data: Data("\(state.rootIdentity)\u{0}\(fromCursor)\u{0}\(throughCursor)\u{0}\(changedDigest)".utf8))
            .map { String(format: "%02x", $0) }.joined()

        if !retained.isEmpty {
            try await persistCheckpoint(state)
        }
        return WorkspaceDeltaObservation(
            effectiveRootIdentity: state.rootIdentity,
            effectiveRootPolicyDigest: owner.policyDigest,
            observedFrom: fromCursor,
            observedThrough: throughCursor,
            observationViewID: viewID,
            retentionFloorSequence: state.journal.events.first?.sequence ?? state.journal.sequence,
            headSequence: state.journal.sequence,
            changedPaths: changedPaths,
            indexedFiles: indexedFiles
        )
    }

    public func searchContextObservation(
        path: String? = nil,
        fromCursor: String,
        testPaths: Set<String> = [],
        testClassification: String = "unavailable",
        projectProfileDigest: String? = nil,
        includeIndexedFiles: Bool = true
    ) async throws -> SearchContextEnvironment {
        let view = try await workspaceDeltaObservation(
            path: path,
            fromCursor: fromCursor,
            deliveryGrace: .milliseconds(500),
            includeIndexedFiles: includeIndexedFiles
        )
        return SearchContextEnvironment(
            effectiveRootIdentity: view.effectiveRootIdentity,
            effectiveRootPolicyDigest: view.effectiveRootPolicyDigest,
            workspaceCursor: view.observedThrough,
            observedFrom: view.observedFrom,
            observedThrough: view.observedThrough,
            observationViewID: view.observationViewID,
            changedPaths: view.changedPaths,
            testPaths: testPaths,
            testClassification: testClassification,
            projectProfileDigest: projectProfileDigest,
            indexedFiles: includeIndexedFiles ? view.indexedFiles : nil,
            isFresh: true
        )
    }

    /// Filesystem commit時に実測した状態を、再scanせずentry indexとdelta journalへ反映する。
    /// transactionIDは同一runtime内のrecovery再送を冪等にし、後着FSEvents echoは実測一致時だけ吸収する。
    @discardableResult
    public func appendKnownMutation(
        transactionID: String,
        rootPath: String? = nil,
        changes: [KnownMutation]
    ) async throws -> String {
        guard !transactionID.isEmpty else {
            throw AIShellError.invalidArgument("transactionIDは空にできません。")
        }
        let resolver = try await activeResolver()
        let root = try resolver.resolveExisting(rootPath)
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw AIShellError.invalidPath(root.path)
        }
        let key = root.path
        if states[key] == nil { try await initialize(root: root, key: key, requestedCursor: nil) }
        guard var state = states[key] else { throw AIShellError.invalidPath(root.path) }
        if state.knownTransactionIDs.contains(transactionID) { return cursor(for: state) }

        for mutation in changes {
            guard !mutation.path.isEmpty,
                  !mutation.path.hasPrefix("/"),
                  !ReservedNamespacePolicy.contains(relativePath: mutation.path),
                  mutation.previousPath.map({ !ReservedNamespacePolicy.contains(relativePath: $0) }) ?? true
            else { throw AIShellError.reservedPath(mutation.path) }
            let absolute = root.appendingPathComponent(mutation.path).standardizedFileURL
            try ReservedNamespacePolicy.requirePublicPath(absolute, under: resolver.namespaceRoots)
            let oldPath = mutation.previousPath
            let measured = try currentEntry(url: absolute, root: root)
            let change: WorkspaceChange
            switch mutation.kind {
            case .created, .modified:
                guard let measured else { throw AIShellError.itemNotFound(absolute.path) }
                state.entries[mutation.path] = measured
                state.knownEchoes[mutation.path] = .some(measured)
                change = WorkspaceChange(kind: mutation.kind, path: mutation.path, previousPath: nil, entry: measured)
            case .deleted:
                guard measured == nil else { throw AIShellError.contentChanged(absolute.path) }
                state.entries.removeValue(forKey: mutation.path)
                state.knownEchoes[mutation.path] = .some(nil)
                change = WorkspaceChange(kind: .deleted, path: mutation.path, previousPath: nil, entry: nil)
            case .renamed:
                guard let oldPath, let measured else {
                    throw AIShellError.invalidArgument("renameにはpreviousPathと存在するdestinationが必要です。")
                }
                state.entries.removeValue(forKey: oldPath)
                state.entries[mutation.path] = measured
                state.knownEchoes[oldPath] = .some(nil)
                state.knownEchoes[mutation.path] = .some(measured)
                change = WorkspaceChange(kind: .renamed, path: mutation.path, previousPath: oldPath, entry: measured)
            }
            let before = state.journal.sequence
            state.journal.record([ObservedFileEvent(path: absolute.path, eventID: 0, flags: 0)])
            state.knownChangesBySequence[before + 1] = change
            pruneKnownChanges(to: &state)
        }
        state.knownTransactionIDs.insert(transactionID)
        states[key] = state
        try await persistCheckpoint(state)
        return cursor(for: state)
    }

    func scanInvocationCountForTests() -> Int { scanInvocationCount }
    func contentReadCountForTests() -> Int { contentReadCount }

    private func initialize(
        root: URL,
        key: String,
        requestedCursor: String?,
        reconcileFilesystem: Bool = true
    ) async throws {
        if states.count >= stateLimit,
           let oldest = states.min(by: { $0.value.lastAccessedAt < $1.value.lastAccessedAt })?.key {
            states.removeValue(forKey: oldest)
        }
        let rootIdentity = try Self.fileIdentity(root)
        let rootDigest = try Self.rootDigest(root)
        let currentEventStoreUUID = try eventStoreUUIDProvider(root)
        var restored = try await checkpointStore.load(rootDigest: rootDigest)
        var checkpointRejectedForRebuild = false
        if let checkpoint = restored,
           checkpoint.eventStoreUUID == nil
            || currentEventStoreUUID == nil
            || checkpoint.eventStoreUUID != currentEventStoreUUID {
            if requestedCursor != nil {
                throw AIShellError.rescanRequired("FSEvents volume UUID continuity is unavailable or changed")
            }
            restored = nil
            checkpointRejectedForRebuild = true
        }
        if restored?.lastEventID == nil, restored != nil {
            if requestedCursor != nil {
                throw AIShellError.rescanRequired("checkpoint has no FSEvents watermark")
            }
            restored = nil
            checkpointRejectedForRebuild = true
        }
        if restored != nil, !startsFSEvents {
            if requestedCursor != nil {
                throw AIShellError.rescanRequired("FSEvents continuity is unavailable")
            }
            restored = nil
            checkpointRejectedForRebuild = true
        }
        if restored == nil, let requestedCursor {
            let parsed = try parseCursor(requestedCursor)
            if parsed.rootDigest != rootDigest,
               let previous = try await checkpointStore.load(rootDigest: parsed.rootDigest),
               previous.rootPath == Self.canonicalPath(root.path).path {
                throw AIShellError.rescanRequired("workspace root identity changed")
            }
            throw AIShellError.cursorExpired(requestedCursor)
        }
        if let restored {
            guard restored.rootIdentity == rootIdentity,
                  restored.rootPath == Self.canonicalPath(root.path).path else {
                throw AIShellError.rescanRequired("workspace root identity changed")
            }
            guard restored.exclusionDigest == Self.exclusionDigest else {
                throw AIShellError.rescanRequired("workspace exclusion contract changed")
            }
        }
        states[key] = RootState(
            root: root,
            rootIdentity: rootIdentity,
            rootDigest: rootDigest,
            exclusionDigest: Self.exclusionDigest,
            eventStoreUUID: currentEventStoreUUID,
            entries: restored.map(Self.workspaceEntries) ?? [:],
            prefetchedPaths: [],
            prefetchedEntries: [:],
            journal: ObservationJournal(
                generation: restored?.generation ?? UUID().uuidString.lowercased(),
                sequence: restored?.journalSequence ?? 0,
                lastEventID: restored?.lastEventID,
                events: restored?.journalEvents ?? [],
                retentionLimit: journalLimit
            ),
            knownTransactionIDs: [],
            knownChangesBySequence: Dictionary(uniqueKeysWithValues:
                (restored?.journalChanges ?? []).map { ($0.sequence, $0.change) }
            ),
            knownEchoes: [:],
            checkpointState: checkpointRejectedForRebuild ? "rebuilt" : (restored == nil ? "missing" : "restored"),
            observer: nil,
            lastAccessedAt: Date()
        )
        if startsFSEvents {
            let observer = try FSEventsObserver(path: root.path, sinceEventID: restored?.lastEventID)
            states[key]?.observer = observer
            drainObserver(for: key)
            if !initializationEventsForTests.isEmpty {
                ingest(initializationEventsForTests)
            }
            guard var warmed = states[key] else { throw AIShellError.invalidPath(root.path) }
            if restored == nil {
                warmed.journal.startNewGeneration(warmed.journal.generation)
            }
            states[key] = warmed
        }
        // Cursorなしの検索は実ファイルをworkerで直接読むため、正常なcheckpoint復元時に
        // 全entryを再列挙する必要はない。FSEvents差分は呼出元でdrain/reconcileし、
        // continuity喪失はrescanReason経由で明示的な全scanへ昇格する。
        if !reconcileFilesystem, restored != nil {
            return
        }
        let dirtyPaths = Set(states[key]?.journal.events.map(\.path) ?? [])
        let scannedEntries = try scan(
            root: root,
            reusableEntries: restored.map(Self.workspaceEntries) ?? [:],
            dirtyPaths: dirtyPaths
        )
        if startsFSEvents {
            try await Task.sleep(for: .milliseconds(500))
            drainObserver(for: key)
        }
        guard var scanned = states[key] else { throw AIShellError.invalidPath(root.path) }
        if let restored {
            let previousEntries = Self.workspaceEntries(restored)
            let allPaths = Set(previousEntries.keys).union(scannedEntries.keys)
            let changedRelativePaths = allPaths.filter {
                !Self.entriesMetadataEqual(previousEntries[$0], scannedEntries[$0])
            }
            let metadataChanged = changedRelativePaths
                .map { root.appendingPathComponent($0).path }
            let alreadyObserved = Set(scanned.journal.events.map(\.path))
            let synthetic = metadataChanged.filter { !alreadyObserved.contains($0) }
                .map { ObservedFileEvent(path: $0, eventID: 0, flags: 0) }
            scanned.journal.record(synthetic)
            scanned.prefetchedPaths = Set(changedRelativePaths)
            scanned.prefetchedEntries = scannedEntries.filter { changedRelativePaths.contains($0.key) }
        } else {
            scanned.entries = scannedEntries
            let observedRelativePaths = Set(scanned.journal.events.compactMap { event -> String? in
                let relative = Self.relativePath(event.path, root: root.path)
                return relative.isEmpty ? nil : relative
            })
            scanned.prefetchedPaths = observedRelativePaths
            scanned.prefetchedEntries = scannedEntries.filter { observedRelativePaths.contains($0.key) }
        }
        states[key] = scanned
    }

    private func ingest(_ events: [ObservedFileEvent]) {
        for key in Array(states.keys) {
            guard var state = states[key] else { continue }
            let rootPath = state.root.path
            let normalizedEvents = events.map {
                ObservedFileEvent(
                    path: Self.canonicalPath($0.path).path,
                    eventID: $0.eventID,
                    flags: $0.flags
                )
            }
            let admitted = normalizedEvents.filter { event in
                let relative = Self.relativePath(event.path, root: rootPath)
                return !Self.isExcluded(relative) && !consumeKnownEcho(event.path, state: &state)
            }
            state.journal.record(admitted) { path in
                guard Self.contains(path, in: rootPath) else { return false }
                let relative = Self.relativePath(path, root: rootPath)
                return !relative.isEmpty && !Self.isExcluded(relative)
            }
            pruneKnownChanges(to: &state)
            states[key] = state
        }
    }

    /// 既知の変更はjournalに残っているeventと同じ寿命だけ保持する。
    /// snapshot consumerの進捗では破棄せず、journalのretention上限だけを失効境界にする。
    private func pruneKnownChanges(to state: inout RootState) {
        let retainedSequences = Set(state.journal.events.map(\.sequence))
        state.knownChangesBySequence = state.knownChangesBySequence.filter {
            retainedSequences.contains($0.key)
        }
    }

    private func drainObserver(for key: String) {
        guard var state = states[key], let observer = state.observer else { return }
        let drained = observer.drainThroughCurrent()
        let rootPath = state.root.path
        let normalizedEvents = drained.events.map {
            ObservedFileEvent(
                path: Self.canonicalPath($0.path).path,
                eventID: $0.eventID,
                flags: $0.flags
            )
        }
        let admitted = normalizedEvents.filter { event in
            let relative = Self.relativePath(event.path, root: rootPath)
            return !Self.isExcluded(relative) && !consumeKnownEcho(event.path, state: &state)
        }
        state.journal.record(admitted) { path in
            guard Self.contains(path, in: rootPath) else { return false }
            let relative = Self.relativePath(path, root: rootPath)
            return !relative.isEmpty && !Self.isExcluded(relative)
        }
        pruneKnownChanges(to: &state)
        if let watermark = drained.watermark {
            state.journal.advanceEventWatermark(to: watermark)
        }
        states[key] = state
    }

    private func reconcile(paths: [String], state: inout RootState) throws -> [WorkspaceChange] {
        let reconciliationPaths = try expandedObservedPaths(paths, state: state)
        guard reconciliationPaths.count <= 5_000 else {
            throw AIShellError.rescanRequired("directory subtree change exceeds 5000 entries")
        }
        var changes: [WorkspaceChange] = []
        var deletedByIdentity: [String: (String, WorkspaceEntry)] = [:]
        for absolutePath in reconciliationPaths {
            let url = URL(fileURLWithPath: absolutePath).standardizedFileURL
            let relative = Self.relativePath(url.path, root: state.root.path)
            guard !relative.isEmpty, !Self.isExcluded(relative) else { continue }
            let previous = state.entries[relative]
            let current: WorkspaceEntry?
            if state.prefetchedPaths.contains(relative) {
                current = state.prefetchedEntries[relative]
            } else {
                current = try currentEntry(url: url, root: state.root)
            }
            switch (previous, current) {
            case let (old?, nil):
                state.entries.removeValue(forKey: relative)
                deletedByIdentity[old.identity] = (relative, old)
                changes.append(WorkspaceChange(kind: .deleted, path: relative, previousPath: nil, entry: nil))
            case let (nil, new?):
                state.entries[relative] = new
                changes.append(WorkspaceChange(kind: .created, path: relative, previousPath: nil, entry: new))
            case let (old?, new?) where old.identity != new.identity:
                state.entries[relative] = new
                deletedByIdentity[old.identity] = (relative, old)
                changes.append(WorkspaceChange(
                    kind: .deleted, path: relative, previousPath: nil, entry: nil
                ))
                changes.append(WorkspaceChange(
                    kind: .created, path: relative, previousPath: nil, entry: new
                ))
            case let (old?, new?) where old != new:
                state.entries[relative] = new
                changes.append(WorkspaceChange(kind: .modified, path: relative, previousPath: nil, entry: new))
            default:
                break
            }
        }

        var consumedDeletedPaths = Set<String>()
        let transformed = changes.map { change -> WorkspaceChange in
            guard change.kind == .created,
                  let entry = change.entry,
                  let deleted = deletedByIdentity[entry.identity] else { return change }
            consumedDeletedPaths.insert(deleted.0)
            return WorkspaceChange(
                kind: .renamed,
                path: change.path,
                previousPath: deleted.0,
                entry: entry
            )
        }
        return transformed.filter {
            !($0.kind == .deleted && consumedDeletedPaths.contains($0.path))
        }.sorted {
            if $0.path != $1.path { return $0.path < $1.path }
            return Self.changeOrder($0.kind) < Self.changeOrder($1.kind)
        }
    }

    private func consumeKnownEcho(_ absolutePath: String, state: inout RootState) -> Bool {
        let relative = Self.relativePath(absolutePath, root: state.root.path)
        guard let expectedBox = state.knownEchoes[relative] else { return false }
        let expected = expectedBox
        guard let actual = try? currentEntry(url: URL(fileURLWithPath: absolutePath), root: state.root),
              actual == expected else {
            if expected == nil, !FileManager.default.fileExists(atPath: absolutePath) {
                state.knownEchoes.removeValue(forKey: relative)
                return true
            }
            return false
        }
        state.knownEchoes.removeValue(forKey: relative)
        return true
    }

    private func expandedObservedPaths(_ paths: [String], state: RootState) throws -> [String] {
        var expanded: [String] = []
        func append(_ path: String) {
            if !expanded.contains(path) { expanded.append(path) }
        }
        for path in paths { append(path) }
        var index = 0
        while index < expanded.count {
            let absolutePath = expanded[index]
            index += 1
            let url = URL(fileURLWithPath: absolutePath).standardizedFileURL
            let relative = Self.relativePath(url.path, root: state.root.path)
            let prefetched = state.prefetchedPaths.contains(relative)
                ? state.prefetchedEntries[relative]
                : try currentEntry(url: url, root: state.root)
            if let current = prefetched {
                for (oldPath, oldEntry) in state.entries
                    where oldPath != relative && oldEntry.identity == current.identity {
                    append(state.root.appendingPathComponent(oldPath).path)
                }
            }
            for oldPath in state.entries.keys where oldPath.hasPrefix(relative + "/") {
                append(state.root.appendingPathComponent(oldPath).path)
            }
            guard FileManager.default.fileExists(atPath: url.path),
                  try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            var traversalError: Error?
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [],
                errorHandler: { _, error in traversalError = error; return false }
            ) else { continue }
            for case let child as URL in enumerator {
                let childRelative = Self.relativePath(child.path, root: state.root.path)
                if Self.isExcluded(childRelative) {
                    enumerator.skipDescendants()
                    continue
                }
                append(child.path)
            }
            if let traversalError { throw traversalError }
        }
        return expanded
    }

    private func formsRenamePair(_ firstPath: String, _ secondPath: String, state: RootState) throws -> Bool {
        func transition(_ absolutePath: String) throws -> (old: String?, new: String?) {
            let url = URL(fileURLWithPath: absolutePath).standardizedFileURL
            let relative = Self.relativePath(url.path, root: state.root.path)
            let current = state.prefetchedPaths.contains(relative)
                ? state.prefetchedEntries[relative]
                : try currentEntry(url: url, root: state.root)
            return (state.entries[relative]?.identity, current?.identity)
        }
        let first = try transition(firstPath)
        let second = try transition(secondPath)
        return (first.old != nil && first.new == nil && second.old == nil && second.new == first.old)
            || (second.old != nil && second.new == nil && first.old == nil && first.new == second.old)
    }

    private func scan(
        root: URL,
        reusableEntries: [String: WorkspaceEntry] = [:],
        dirtyPaths: Set<String> = []
    ) throws -> [String: WorkspaceEntry] {
        scanInvocationCount += 1
        var entries: [String: WorkspaceEntry] = [:]
        var traversalError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [],
            errorHandler: { _, error in
                traversalError = error
                return false
            }
        ) else { return entries }
        for case let url as URL in enumerator {
            let relative = Self.relativePath(url.path, root: root.path)
            if Self.isExcluded(relative) {
                enumerator.skipDescendants()
                continue
            }
            let reusable = reusableEntries[relative]
            if let entry = try currentEntry(
                url: url,
                root: root,
                reusable: dirtyPaths.contains(url.path) ? nil : reusable
            ) {
                entries[relative] = entry
            }
        }
        if let traversalError { throw traversalError }
        return entries
    }

    private func currentEntry(
        url: URL,
        root: URL,
        reusable: WorkspaceEntry? = nil
    ) throws -> WorkspaceEntry? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard Self.contains(url.resolvingSymlinksInPath().path, in: root.resolvingSymlinksInPath().path) else {
            return nil
        }
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey
        ])
        guard values.isSymbolicLink != true else { return nil }
        let isDirectory = values.isDirectory == true
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        // socket・FIFO・device等はworkspaceの内容ではなく、開いても中身を持たない。
        // symbolic linkと同じくentryにしない。除外しないと下のcontent readが例外を投げ、
        // 1個の特殊fileでsnapshot全体が失敗する（`.lattice/sensor/daemon.sock`が実例）。
        let isRegularFile = (info.st_mode & S_IFMT) == S_IFREG
        guard isDirectory || isRegularFile else { return nil }
        let size = Int64(values.fileSize ?? 0)
        let identity = "\(info.st_dev):\(info.st_ino)"
        let hash: String?
        if !isDirectory,
           let reusable,
           reusable.identity == identity,
           reusable.sizeBytes == size,
           Self.datesEquivalent(reusable.modifiedAt, values.contentModificationDate),
           reusable.sha256 != nil {
            hash = reusable.sha256
        } else if isRegularFile, size <= 4 * 1_024 * 1_024 {
            contentReadCount += 1
            // 1個のfileが読めないだけでsnapshot全体を落とさない。entryはpath・size・
            // mtimeを保ったまま残し、hashだけnilにする（4MiB超のfileと同じ扱い）。
            // 読めなかった事実はsha256の欠落として観測でき、握り潰しにはならない。
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            } else {
                hash = nil
            }
        } else {
            hash = nil
        }
        return WorkspaceEntry(
            path: Self.relativePath(url.path, root: root.path),
            identity: identity,
            isDirectory: isDirectory,
            sizeBytes: size,
            modifiedAt: values.contentModificationDate,
            sha256: hash
        )
    }

    private func activeResolver() async throws -> PathResolver {
        return await runtimeStore.pathResolver()
    }

    private func cursor(for state: RootState, sequence: UInt64? = nil) -> String {
        "ws2:\(state.rootDigest):\(state.exclusionDigest):\(state.journal.generation):\(sequence ?? state.journal.sequence)"
    }

    private func persistCheckpoint(_ state: RootState) async throws {
        let now = Date()
        let checkpoint = WorkspaceCheckpoint(
            rootPath: Self.canonicalPath(state.root.path).path,
            rootIdentity: state.rootIdentity,
            rootDigest: state.rootDigest,
            exclusionDigest: state.exclusionDigest,
            eventStoreUUID: state.eventStoreUUID,
            generation: state.journal.generation,
            lastEventID: state.journal.lastEventID,
            journalSequence: state.journal.sequence,
            journalEvents: state.journal.events,
            journalChanges: state.knownChangesBySequence
                .filter { sequence, _ in state.journal.events.contains { $0.sequence == sequence } }
                .map { WorkspaceCheckpointJournalChange(sequence: $0.key, change: $0.value) }
                .sorted { $0.sequence < $1.sequence },
            entries: state.entries.values.map(Self.checkpointEntry),
            createdAt: now,
            lastAccessedAt: now
        )
        _ = try await checkpointStore.save(checkpoint, activeRootDigests: Set(states.values.map(\.rootDigest)))
        for evicted in await checkpointStore.takeRecentEvictions() {
            try await runtimeStore.appendActivity(OperationRecord(
                operation: "workspace_checkpoint_evict",
                target: evicted,
                success: true,
                message: "checkpoint quota LRU eviction"
            ))
        }
    }

    private static func checkpointEntry(_ entry: WorkspaceEntry) -> WorkspaceCheckpointEntry {
        let hashState: WorkspaceCheckpointHashState
        if entry.isDirectory { hashState = .notApplicable }
        else if entry.sha256 == nil { hashState = .deferred }
        else { hashState = .hashed }
        return WorkspaceCheckpointEntry(
            path: entry.path,
            identity: entry.identity,
            kind: entry.isDirectory ? .directory : .file,
            sizeBytes: entry.sizeBytes,
            modifiedAtNanoseconds: entry.modifiedAt.map {
                Int64(($0.timeIntervalSince1970 * 1_000_000_000).rounded())
            },
            sha256: entry.sha256,
            hashState: hashState
        )
    }

    private static func workspaceEntries(_ checkpoint: WorkspaceCheckpoint) -> [String: WorkspaceEntry] {
        Dictionary(uniqueKeysWithValues: checkpoint.entries.map { entry in
            let modifiedAt = entry.modifiedAtNanoseconds.map {
                Date(timeIntervalSince1970: Double($0) / 1_000_000_000)
            }
            return (entry.path, WorkspaceEntry(
                path: entry.path,
                identity: entry.identity,
                isDirectory: entry.kind == .directory,
                sizeBytes: entry.sizeBytes,
                modifiedAt: modifiedAt,
                sha256: entry.sha256
            ))
        })
    }

    private func parseCursor(_ cursor: String) throws -> (
        rootDigest: String, exclusionDigest: String, generation: String, sequence: UInt64
    ) {
        let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "ws2", let sequence = UInt64(parts[4]) else {
            throw AIShellError.cursorExpired(cursor)
        }
        return (String(parts[1]), String(parts[2]), String(parts[3]), sequence)
    }

    private func manifestPaths(in entries: [String: WorkspaceEntry]) -> [String] {
        let names: Set<Substring> = ["Package.swift", "package.json", "Cargo.toml", "pyproject.toml", "go.mod"]
        return entries.values.filter { names.contains(Self.lastPathComponent(of: $0.path)) }
            .map(\.path).sorted()
    }

    private func guidancePaths(in entries: [String: WorkspaceEntry]) -> [String] {
        entries.values.filter {
            let name = Self.lastPathComponent(of: $0.path)
            return name == "AGENTS.md" || name == "CLAUDE.md" || $0.path == "rag/INDEX.md"
        }.map(\.path).sorted()
    }

    private func testPaths(in entries: [String: WorkspaceEntry]) -> [String] {
        entries.values.filter {
            !$0.isDirectory && ($0.path.contains("/Tests/") || $0.path.hasPrefix("Tests/") || $0.path.contains(".test."))
        }.map(\.path).sorted().prefix(100).map { $0 }
    }

    static func prioritizedContextEntries(
        in entries: [String: WorkspaceEntry],
        priority: (String) -> Int = WorkspaceStateRuntime.contextPriority
    ) -> [WorkspaceEntry] {
        entries.values.filter { !$0.isDirectory && !$0.path.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0 == "archive" }) }
            .map { (entry: $0, priority: priority($0.path)) }
            .sorted {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return $0.entry.path < $1.entry.path
            }
            .map(\.entry)
    }

    private static func contextPriority(_ path: String) -> Int {
        let name = lastPathComponent(of: path)
        if path.split(separator: "/").contains(where: { ["Tests", "tests", "test", "fixtures", "benchmarks"].contains(String($0)) }) || path.contains(".test.") { return 4 }
        if name == "AGENTS.md" || name == "CLAUDE.md" || path == "rag/INDEX.md" { return 0 }
        if ["Package.swift", "package.json", "Cargo.toml", "pyproject.toml", "go.mod"].contains(name) { return 1 }
        return 2
    }

    private static func lastPathComponent(of path: String) -> Substring {
        guard let separator = path.lastIndex(of: "/") else { return path[...] }
        return path[path.index(after: separator)...]
    }

    private func contextCandidates(
        entries: [String: WorkspaceEntry], root: URL, paths: [String]?, defaults: [WorkspaceEntry]
    ) throws -> [WorkspaceEntry] {
        guard let paths else { return Array(defaults.filter { !$0.isDirectory && $0.sha256 != nil }.prefix(8)) }
        var result: [WorkspaceEntry] = []
        for path in paths {
            let url = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else { throw AIShellError.invalidPath(path) }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            guard let entry = entries[relative], !entry.isDirectory else { throw AIShellError.invalidPath(path) }
            if !result.contains(where: { $0.path == entry.path }) { result.append(entry) }
        }
        return result
    }

    private func contextChunks(root: URL, candidates: [WorkspaceEntry], budget: Int) throws -> [ContextChunk] {
        let limit = min(max(0, budget), 65_536)
        guard limit > 0 else { return [] }
        var remaining = limit
        var chunks: [ContextChunk] = []
        for (index, entry) in candidates.enumerated() where remaining > 0 {
            let url = root.appendingPathComponent(entry.path)
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard String(data: data, encoding: .utf8) != nil else { continue }
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if let expected = entry.sha256, expected != sha { throw AIShellError.contentChanged(url.path) }
            var count = min(data.count, max(1, remaining / (candidates.count - index)))
            while count > 0 && String(data: data.prefix(count), encoding: .utf8) == nil { count -= 1 }
            let selected = data.prefix(count)
            chunks.append(ContextChunk(
                path: entry.path, text: String(decoding: selected, as: UTF8.self), sha256: sha,
                sizeBytes: data.count, returnedBytes: count, omittedBytes: data.count - count,
                startLine: 1, endLine: 1 + selected.dropLast().filter { $0 == 10 }.count, offsetBytes: 0
            ))
            remaining -= count
        }
        return chunks
    }

    private func gitStatus(root: URL) throws -> (state: String, lines: [String]) {
        let git = URL(fileURLWithPath: "/usr/bin/git")
        guard FileManager.default.isExecutableFile(atPath: git.path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
        else { return ("not_repository", []) }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIShellGit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let outputURL = scratch.appendingPathComponent("stdout")
        let errorURL = scratch.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        let process = Process()
        process.executableURL = git
        process.arguments = [
            "--no-optional-locks", "-C", root.path, "status", "--short", "--untracked-files=normal",
            "--", ".", ReservedNamespacePolicy.gitExclusionPathspec
        ]
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_OPTIONAL_LOCKS": "0"]) { _, value in value }
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        try output.close()
        try error.close()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
            throw AIShellError.processLaunchFailed("git status exit \(process.terminationStatus): \(message)")
        }
        let data = try Data(contentsOf: outputURL, options: .mappedIfSafe)
        let lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0.isNewline }).prefix(500).map(String.init)
        return (lines.isEmpty ? "clean" : "dirty", lines)
    }

    private static func isExcluded(_ relative: String) -> Bool {
        return ReservedNamespacePolicy.shouldExclude(relativePath: relative)
    }

    private static let exclusionDigest = ReservedNamespacePolicy.exclusionDigest

    private static func changeOrder(_ kind: WorkspaceChangeKind) -> Int {
        switch kind {
        case .deleted: 0
        case .renamed: 1
        case .created: 2
        case .modified: 3
        }
    }

    private static func entriesMetadataEqual(_ lhs: WorkspaceEntry?, _ rhs: WorkspaceEntry?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?):
            lhs.path == rhs.path
                && lhs.identity == rhs.identity
                && lhs.isDirectory == rhs.isDirectory
                && lhs.sizeBytes == rhs.sizeBytes
                && datesEquivalent(lhs.modifiedAt, rhs.modifiedAt)
                && lhs.sha256 == rhs.sha256
        default: false
        }
    }

    private static func datesEquivalent(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): abs(lhs.timeIntervalSince(rhs)) < 0.000_001
        default: false
        }
    }

    private static func fileIdentity(_ url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw AIShellError.invalidPath(url.path) }
        return "\(info.st_dev):\(info.st_ino)"
    }

    private static func rootDigest(_ root: URL) throws -> String {
        let binding = "\(canonicalPath(root.path).path)\u{0}\(try fileIdentity(root))"
        return SHA256.hash(data: Data(binding.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func eventStoreUUID(_ root: URL) throws -> String? {
        var info = stat()
        guard lstat(root.path, &info) == 0 else { throw AIShellError.invalidPath(root.path) }
        guard let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return nil }
        return (CFUUIDCreateString(nil, uuid) as String).lowercased()
    }

    private static func relativePath(_ path: String, root: String) -> String {
        let targetComponents = canonicalPath(path).pathComponents
        let rootComponents = canonicalPath(root).pathComponents
        guard targetComponents.count >= rootComponents.count,
              Array(targetComponents.prefix(rootComponents.count)) == rootComponents else {
            return path
        }
        return targetComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static func contains(_ path: String, in root: String) -> Bool {
        let target = canonicalPath(path).path
        let boundary = canonicalPath(root).path
        return target == boundary || target.hasPrefix(boundary + "/")
    }

    private static func canonicalPath(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }
}
