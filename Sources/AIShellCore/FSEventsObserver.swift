import CoreServices
import Darwin
import Foundation

struct ObservedFileEvent: Sendable {
    let path: String
    let eventID: UInt64
    let flags: FSEventStreamEventFlags

    var requiresRescan: Bool {
        let unsafeFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged
        )
        return flags & unsafeFlags != 0
    }
}

final class FSEventsObserver: @unchecked Sendable {
    private final class CallbackBox: @unchecked Sendable {
        private let lock = NSLock()
        private let volumeRootPath: String
        private var events: [ObservedFileEvent] = []

        init(volumeRootPath: String) {
            self.volumeRootPath = volumeRootPath
        }

        func absolutePath(_ deviceRelativePath: String) -> String {
            let relative = deviceRelativePath.drop(while: { $0 == "/" })
            guard !relative.isEmpty else { return volumeRootPath }
            return volumeRootPath == "/" ? "/\(relative)" : "\(volumeRootPath)/\(relative)"
        }

        func append(_ incoming: [ObservedFileEvent]) {
            lock.lock()
            events.append(contentsOf: incoming)
            lock.unlock()
        }

        func drain() -> [ObservedFileEvent] {
            lock.lock()
            defer { lock.unlock() }
            let drained = events
            events.removeAll(keepingCapacity: true)
            return drained
        }
    }

    private let box: CallbackBox
    private let queue: DispatchQueue
    private let device: dev_t
    private var stream: FSEventStreamRef?
    private var safeWatermark: UInt64?
    private let initialWatermark: UInt64?

    init(
        path: String,
        sinceEventID: UInt64? = nil
    ) throws {
        let root = URL(fileURLWithPath: path).standardizedFileURL
        var info = stat()
        guard lstat(root.path, &info) == 0 else { throw AIShellError.invalidPath(path) }
        let device = info.st_dev
        self.device = device
        var filesystem = statfs()
        guard statfs(root.path, &filesystem) == 0 else { throw AIShellError.invalidPath(path) }
        let volumeRootPath = withUnsafePointer(to: &filesystem.f_mntonname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) {
                String(cString: $0)
            }
        }
        guard let resolved = realpath(root.path, nil) else { throw AIShellError.invalidPath(path) }
        let physicalRootPath = String(cString: resolved)
        free(resolved)
        let deviceRelativePath: String
        if physicalRootPath == volumeRootPath {
            deviceRelativePath = ""
        } else if physicalRootPath.hasPrefix(volumeRootPath + "/") {
            deviceRelativePath = String(physicalRootPath.dropFirst(volumeRootPath.count + 1))
        } else {
            // macOS firmlink（例: /var -> Data volumeの/private/var）はvisible mount point配下に展開されない。
            deviceRelativePath = String(physicalRootPath.drop(while: { $0 == "/" }))
        }
        box = CallbackBox(volumeRootPath: volumeRootPath)
        queue = DispatchQueue(label: "jp.quolu.aishell.fsevents.\(UUID().uuidString)")
        let systemCurrentEventID = FSEventsGetCurrentEventId()
        let deviceBoundary = FSEventsGetLastEventIdForDeviceBeforeTime(
            device,
            Date().timeIntervalSince1970
        )
        if let sinceEventID, sinceEventID > systemCurrentEventID {
            throw AIShellError.rescanRequired(
                "checkpoint FSEvents watermark is newer than the system event database "
                    + "(checkpoint=\(sinceEventID), system=\(systemCurrentEventID))"
            )
        }
        initialWatermark = sinceEventID ?? (deviceBoundary == 0 ? nil : deviceBoundary)
        safeWatermark = initialWatermark
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, flags, eventIDs in
            guard let info else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            var events: [ObservedFileEvent] = []
            events.reserveCapacity(count)
            for index in 0..<count {
                guard let rawPath = paths[index] else { continue }
                if flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 {
                    continue
                }
                events.append(ObservedFileEvent(
                    path: box.absolutePath(String(cString: rawPath)),
                    eventID: eventIDs[index],
                    flags: flags[index]
                ))
            }
            if !events.isEmpty { box.append(events) }
        }
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreateRelativeToDevice(
            kCFAllocatorDefault,
            callback,
            &context,
            device,
            [deviceRelativePath] as CFArray,
            initialWatermark ?? (deviceBoundary == 0
                ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
                : deviceBoundary),
            0.1,
            createFlags
        ) else {
            throw AIShellError.invalidPath("FSEvents streamを作成できません: \(path)")
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            throw AIShellError.invalidPath("FSEvents streamを開始できません: \(path)")
        }
    }

    func drainThroughCurrent() -> (events: [ObservedFileEvent], watermark: UInt64?) {
        guard let stream else { return ([], safeWatermark) }
        FSEventStreamFlushSync(stream)
        let events = box.drain()
        if let processed = events.map(\.eventID).max() {
            safeWatermark = max(safeWatermark ?? 0, processed)
        }
        return (events, safeWatermark)
    }

    func watchedDeviceForTests() -> dev_t? {
        guard let stream else { return nil }
        return FSEventStreamGetDeviceBeingWatched(stream)
    }

    func initialWatermarkForTests() -> UInt64? { initialWatermark }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
