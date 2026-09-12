import Foundation

struct ObservationJournalEvent: Codable, Equatable, Sendable {
    let sequence: UInt64
    let path: String
    let eventID: UInt64?

    enum CodingKeys: String, CodingKey {
        case sequence, path
        case eventID = "event_id"
    }
}

struct ObservationJournalCheckpoint: Codable, Equatable, Sendable {
    static let currentSchema = "aishell.observation-journal.v1"

    let schema: String
    let generation: String
    let sequence: UInt64
    let lastEventID: UInt64?
    let events: [ObservationJournalEvent]
    let rescanReason: String?

    init(
        schema: String = Self.currentSchema,
        generation: String,
        sequence: UInt64,
        lastEventID: UInt64?,
        events: [ObservationJournalEvent],
        rescanReason: String?
    ) {
        self.schema = schema
        self.generation = generation
        self.sequence = sequence
        self.lastEventID = lastEventID
        self.events = events
        self.rescanReason = rescanReason
    }

    enum CodingKeys: String, CodingKey {
        case schema, generation, sequence, events
        case lastEventID = "last_event_id"
        case rescanReason = "rescan_reason"
    }
}

/// root-scoped retained delta log。readはheadや他consumerのcursorを進めない。
struct WorkspaceDeltaJournal: Sendable {
    private(set) var generation: String
    private(set) var sequence: UInt64
    private(set) var lastEventID: UInt64?
    private(set) var rescanReason: String?
    private(set) var events: [ObservationJournalEvent]
    let retentionLimit: Int

    init(
        generation: String,
        sequence: UInt64 = 0,
        lastEventID: UInt64? = nil,
        events: [ObservationJournalEvent] = [],
        retentionLimit: Int = 10_000
    ) {
        self.generation = generation
        self.sequence = sequence
        self.lastEventID = lastEventID
        rescanReason = nil
        self.events = Array(events.suffix(max(1, retentionLimit)))
        self.retentionLimit = max(1, retentionLimit)
    }

    init(checkpoint: ObservationJournalCheckpoint, retentionLimit: Int = 10_000) throws {
        guard checkpoint.schema == ObservationJournalCheckpoint.currentSchema else {
            throw AIShellError.checkpointUnsupported(checkpoint.schema)
        }
        guard !checkpoint.generation.isEmpty,
              checkpoint.events.map(\.sequence) == checkpoint.events.map(\.sequence).sorted(),
              Set(checkpoint.events.map(\.sequence)).count == checkpoint.events.count,
              checkpoint.events.allSatisfy({ $0.sequence <= checkpoint.sequence }),
              checkpoint.lastEventID.map({ last in
                  checkpoint.events.compactMap(\.eventID).allSatisfy { $0 <= last }
              }) ?? checkpoint.events.allSatisfy({ $0.eventID == nil }) else {
            throw AIShellError.checkpointCorrupt("observation journal invariant違反")
        }
        self.generation = checkpoint.generation
        sequence = checkpoint.sequence
        lastEventID = checkpoint.lastEventID
        rescanReason = checkpoint.rescanReason
        self.retentionLimit = max(1, retentionLimit)
        events = Array(checkpoint.events.suffix(self.retentionLimit))
    }

    mutating func record(
        _ observed: [ObservedFileEvent],
        includePath: (String) -> Bool = { _ in true }
    ) {
        for event in observed {
            if event.requiresRescan {
                rescanReason = "FSEvents gap/root change (flags=\(event.flags), id=\(event.eventID))"
            }
            if event.eventID > 0 {
                lastEventID = max(lastEventID ?? 0, event.eventID)
            }
            guard includePath(event.path) else { continue }
            sequence &+= 1
            events.append(ObservationJournalEvent(
                sequence: sequence,
                path: event.path,
                eventID: event.eventID > 0 ? event.eventID : nil
            ))
        }
        if events.count > retentionLimit {
            events.removeFirst(events.count - retentionLimit)
        }
    }

    func changes(after cursorSequence: UInt64) throws -> [ObservationJournalEvent] {
        if let rescanReason { throw AIShellError.rescanRequired(rescanReason) }
        guard cursorSequence <= sequence else {
            throw AIShellError.cursorExpired("observation:\(generation):\(cursorSequence)")
        }
        if events.isEmpty, cursorSequence < sequence {
            throw AIShellError.cursorExpired("observation:\(generation):\(cursorSequence)")
        }
        if let first = events.first, cursorSequence + 1 < first.sequence {
            throw AIShellError.cursorExpired("observation:\(generation):\(cursorSequence)")
        }
        return events.filter { $0.sequence > cursorSequence }
    }

    func checkpoint() -> ObservationJournalCheckpoint {
        ObservationJournalCheckpoint(
            generation: generation,
            sequence: sequence,
            lastEventID: lastEventID,
            events: events,
            rescanReason: rescanReason
        )
    }

    mutating func startNewGeneration(_ generation: String) {
        self.generation = generation
        sequence = 0
        lastEventID = nil
        rescanReason = nil
        events.removeAll(keepingCapacity: true)
    }

    mutating func markRescanRequired(_ reason: String) {
        rescanReason = reason
    }

    mutating func advanceEventWatermark(to eventID: UInt64) {
        guard eventID > 0 else { return }
        lastEventID = max(lastEventID ?? 0, eventID)
    }

    mutating func discardEvents(through appliedSequence: UInt64) {
        events.removeAll { $0.sequence <= appliedSequence }
    }
}

/// v1 checkpoint fixtureと既存内部testのsource互換名。
typealias ObservationJournal = WorkspaceDeltaJournal
