import CryptoKit
import Darwin
import Foundation

public enum ChangeSetClientAllocationState: String, Codable, Sendable {
    case free
    case active
}

public enum ChangeSetReplayState: String, Codable, Sendable {
    case pending
    case recoveryRequired = "recovery_required"
    case committed
    case rolledBack = "rolled_back"
    case abortedBeforeSideEffect = "aborted_before_side_effect"

    public var isTerminal: Bool {
        switch self {
        case .pending, .recoveryRequired: false
        case .committed, .rolledBack, .abortedBeforeSideEffect: true
        }
    }
}

public struct ChangeSetReplayArtifact: Codable, Equatable, Sendable {
    public let handle: String
    public let expiresAt: Date

    public init(handle: String, expiresAt: Date) {
        self.handle = handle
        self.expiresAt = expiresAt
    }
}

/// Full apply resultを保持しない、固定ring用のcompact replay envelope。
public struct ChangeSetReplayEnvelope: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let requestDigest: String
    public let transactionID: String
    public var state: ChangeSetReplayState
    public var terminalResponseDigest: String?
    public var artifact: ChangeSetReplayArtifact?
    public var retentionExpiresAt: Date?

    public init(
        sequence: UInt64,
        requestDigest: String,
        transactionID: String,
        state: ChangeSetReplayState = .pending,
        terminalResponseDigest: String? = nil,
        artifact: ChangeSetReplayArtifact? = nil,
        retentionExpiresAt: Date? = nil
    ) {
        self.sequence = sequence
        self.requestDigest = requestDigest
        self.transactionID = transactionID
        self.state = state
        self.terminalResponseDigest = terminalResponseDigest
        self.artifact = artifact
        self.retentionExpiresAt = retentionExpiresAt
    }
}

public struct ChangeSetClientSlotSnapshot: Codable, Equatable, Sendable {
    public let number: Int
    public let clientID: String
    public let slotGeneration: UInt64
    public let allocationState: ChangeSetClientAllocationState
    public let currentEpoch: UInt64
    public let highWater: UInt64
}

public enum ChangeSetClientControlAction: String, Codable, Sendable {
    case allocate
    case rotateEpoch = "rotate_epoch"
    case retire
    case reinitializeRegistry = "reinitialize_registry"
}

public struct ChangeSetClientControlReceipt: Codable, Equatable, Sendable {
    public let controlRequestID: String
    public let proofIDDigest: String
    public let action: ChangeSetClientControlAction
    public let resultDigest: String
    public let registryGeneration: UInt64
    public let clientID: String?
    public let slotIndex: Int?
    public let slotGeneration: UInt64?
    public let currentEpoch: UInt64?
    public let expiresAt: Date

    public init(
        controlRequestID: String,
        proofIDDigest: String,
        action: ChangeSetClientControlAction,
        resultDigest: String,
        registryGeneration: UInt64,
        clientID: String?,
        slotIndex: Int?,
        slotGeneration: UInt64?,
        currentEpoch: UInt64?,
        expiresAt: Date
    ) {
        self.controlRequestID = controlRequestID
        self.proofIDDigest = proofIDDigest
        self.action = action
        self.resultDigest = resultDigest
        self.registryGeneration = registryGeneration
        self.clientID = clientID
        self.slotIndex = slotIndex
        self.slotGeneration = slotGeneration
        self.currentEpoch = currentEpoch
        self.expiresAt = expiresAt
    }
}

public struct ChangeSetClientRegistrySnapshot: Equatable, Sendable {
    public let generation: UInt64
    public let slots: [ChangeSetClientSlotSnapshot]
    public let controlReceiptCount: Int
}

public enum ChangeSetClientLookup: Equatable, Sendable {
    case new(nextSequence: UInt64)
    case pending(ChangeSetReplayEnvelope)
    case replay(ChangeSetReplayEnvelope)
}

/// startup照合用のbounded read model。full apply resultやrequest payloadは含めない。
public struct ChangeSetReplayReference: Equatable, Sendable {
    public let clientID: String
    public let epoch: UInt64
    public let slotIndex: Int
    public let sequence: UInt64
    public let requestDigest: String
    public let transactionID: String
    public let state: ChangeSetReplayState
    public let terminalResponseDigest: String?
    public let artifactHandle: String?
    public let artifactExpiresAt: Date?
    public let retentionExpiresAt: Date?
}

public struct ChangeSetLegacyClientSlot: Codable, Equatable, Sendable {
    public let number: Int
    public let clientID: String
    public let slotGeneration: UInt64
    public let allocationState: ChangeSetClientAllocationState
    public let currentEpoch: UInt64
    public let highWater: UInt64
    public let replay: [ChangeSetReplayEnvelope?]

    public init(
        number: Int,
        clientID: String,
        slotGeneration: UInt64,
        allocationState: ChangeSetClientAllocationState,
        currentEpoch: UInt64,
        highWater: UInt64,
        replay: [ChangeSetReplayEnvelope?]
    ) {
        self.number = number
        self.clientID = clientID
        self.slotGeneration = slotGeneration
        self.allocationState = allocationState
        self.currentEpoch = currentEpoch
        self.highWater = highWater
        self.replay = replay
    }
}

public struct ChangeSetLegacyRegistrySnapshot: Codable, Equatable, Sendable {
    public let rootIdentityDigest: String
    public let registryGeneration: UInt64
    public let slots: [ChangeSetLegacyClientSlot]
    public let controlReceipts: [ChangeSetClientControlReceipt?]

    public init(
        rootIdentityDigest: String,
        registryGeneration: UInt64,
        slots: [ChangeSetLegacyClientSlot],
        controlReceipts: [ChangeSetClientControlReceipt?]
    ) {
        self.rootIdentityDigest = rootIdentityDigest
        self.registryGeneration = registryGeneration
        self.slots = slots
        self.controlReceipts = controlReceipts
    }
}

public struct ChangeSetLegacyImportReceipt: Codable, Equatable, Sendable {
    public let snapshotDigest: String
    public let registryGeneration: UInt64

    public init(snapshotDigest: String, registryGeneration: UInt64) {
        self.snapshotDigest = snapshotDigest
        self.registryGeneration = registryGeneration
    }
}

public struct ChangeSetClientRegistryError: Error, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case storeCorrupt = "CHANGE_SET_STORE_CORRUPT"
        case storeCapacityExceeded = "CHANGE_SET_STORE_CAPACITY_EXCEEDED"
        case generationChanged = "CLIENT_REGISTRY_GENERATION_CHANGED"
        case clientNotRegistered = "CHANGE_SET_CLIENT_NOT_REGISTERED"
        case clientCapacityExceeded = "CHANGE_SET_CLIENT_CAPACITY_EXCEEDED"
        case clientExpired = "CHANGE_SET_EXPIRED"
        case clientEpochAhead = "CHANGE_SET_CLIENT_EPOCH_AHEAD"
        case clientEpochExhausted = "CLIENT_EPOCH_EXHAUSTED"
        case sequenceGap = "CHANGE_SET_SEQUENCE_GAP"
        case sequenceConflict = "CHANGE_SET_SEQUENCE_CONFLICT"
        case previousPending = "CHANGE_SET_PREVIOUS_PENDING"
        case rotationBlocked = "CLIENT_ROTATION_BLOCKED"
        case retireBlocked = "CLIENT_RETIRE_BLOCKED"
        case reinitializeBlocked = "CLIENT_REGISTRY_REINITIALIZE_BLOCKED"
        case ownerProofInvalid = "CLIENT_OWNER_PROOF_INVALID"
        case ownerProofConsumed = "CLIENT_OWNER_PROOF_CONSUMED"
        case controlCapacityExceeded = "CLIENT_CONTROL_CAPACITY_EXCEEDED"
        case controlExpired = "CLIENT_CONTROL_EXPIRED"
        case controlRequestConflict = "CLIENT_CONTROL_REQUEST_CONFLICT"
        case invalidEnvelope = "INVALID_ARGUMENT"
        case legacyImportNotPristine = "CLIENT_REGISTRY_IMPORT_NOT_PRISTINE"
        case legacyImportConflict = "CLIENT_REGISTRY_IMPORT_CONFLICT"
    }

    public let code: Code
    public let message: String

    public init(_ code: Code, _ message: String = "") {
        self.code = code
        self.message = message
    }
}

/// root単位の固定client registry。A/B bankは常に同一byte長で、古いvalid bankを
/// 上書きせずinactive bankをfsyncしてからpointerとdirectoryをdurable化する。
public actor ChangeSetClientRegistry {
    public static let slotCount = 64
    public static let replayCapacity = 256
    public static let controlReceiptCapacity = 128
    public static let bankByteCount = 16 * 1_024 * 1_024
    public static let maximumEpoch: UInt64 = 9_007_199_254_740_991

    private static let bankHeaderByteCount = 128
    private static let magic = Data("AISHELL-CSR-A/B\0".utf8)

    private let directory: URL
    private let hmacKey: SymmetricKey
    private let now: @Sendable () -> Date
    private var image: RegistryImage
    private var activeBank: Bank

    public init(
        directory: URL,
        rootIdentityDigest: String,
        hmacKey: Data,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard hmacKey.count >= 32, Self.isSHA256(rootIdentityDigest) else {
            throw ChangeSetClientRegistryError(.ownerProofInvalid, "registry HMAC key must be at least 256 bits")
        }
        self.directory = directory.standardizedFileURL
        self.hmacKey = SymmetricKey(data: hmacKey)
        self.now = now
        try Self.prepareDirectory(self.directory)

        let a = try Self.loadBank(.a, directory: self.directory, key: self.hmacKey)
        let b = try Self.loadBank(.b, directory: self.directory, key: self.hmacKey)
        switch (a, b) {
        case let (.valid(left), .valid(right)):
            if left.generation >= right.generation {
                image = left
                activeBank = .a
            } else {
                image = right
                activeBank = .b
            }
        case let (.valid(value), _):
            image = value
            activeBank = .a
        case let (_, .valid(value)):
            image = value
            activeBank = .b
        case (.absent, .absent):
            let slots = (0..<Self.slotCount).map {
                ClientSlot(number: $0, clientID: UUID().uuidString.lowercased(), slotGeneration: 0, allocationState: .free, currentEpoch: 0, highWater: 0, replay: Array(repeating: nil, count: Self.replayCapacity))
            }
            image = RegistryImage(schema: "aishell.change-set-client-registry.v1", rootIdentityDigest: rootIdentityDigest, generation: 0, slots: slots, receipts: Array(repeating: nil, count: Self.controlReceiptCapacity), legacyImportReceipt: nil)
            activeBank = .a
            try Self.writeBank(image, bank: .a, directory: self.directory, key: self.hmacKey)
            try Self.writeBank(image, bank: .b, directory: self.directory, key: self.hmacKey)
            try Self.writePointer(.a, generation: image.generation, directory: self.directory)
        default:
            throw ChangeSetClientRegistryError(.storeCorrupt, "both registry banks are invalid")
        }
        try Self.validate(image)
        guard image.rootIdentityDigest == rootIdentityDigest else {
            throw ChangeSetClientRegistryError(.storeCorrupt, "registry root identity binding mismatch")
        }
    }

    public func snapshot() -> ChangeSetClientRegistrySnapshot {
        ChangeSetClientRegistrySnapshot(
            generation: image.generation,
            slots: image.slots.map { $0.snapshot },
            controlReceiptCount: image.receipts.compactMap { $0 }.count
        )
    }

    /// snapshotの総receipt数は変えず、指定時刻にcapacityを占有するreceiptだけを数える。
    public func unexpiredControlReceiptCount(at referenceDate: Date) -> Int {
        image.receipts.compactMap { $0 }.filter { $0.expiresAt > referenceDate }.count
    }

    /// legacy cutoverのfrozen provenance。通常のregistry generation進行では変更しない。
    public func legacyImportReceipt() -> ChangeSetLegacyImportReceipt? {
        image.legacyImportReceipt
    }

    /// active slotだけをslot index、sequenceの順に返す。最大64×256件で固定bounded。
    public func replayReferences() -> [ChangeSetReplayReference] {
        image.slots
            .filter { $0.allocationState == .active }
            .sorted { $0.number < $1.number }
            .flatMap { slot in
                slot.replay.compactMap { $0 }
                    .sorted { $0.sequence < $1.sequence }
                    .map { envelope in
                        ChangeSetReplayReference(
                            clientID: slot.clientID,
                            epoch: slot.currentEpoch,
                            slotIndex: slot.number,
                            sequence: envelope.sequence,
                            requestDigest: envelope.requestDigest,
                            transactionID: envelope.transactionID,
                            state: envelope.state,
                            terminalResponseDigest: envelope.terminalResponseDigest,
                            artifactHandle: envelope.artifact?.handle,
                            artifactExpiresAt: envelope.artifact?.expiresAt,
                            retentionExpiresAt: envelope.retentionExpiresAt
                        )
                    }
            }
    }

    /// 旧encrypted snapshotをpristine A/B bankへ一度だけlossless cutoverする。
    /// import receiptも同じbank imageへ含めるため、response喪失後は同digestだけをreplayできる。
    public func initializeFromLegacy(
        expectedPristineGeneration: UInt64 = 0,
        legacySnapshot: ChangeSetLegacyRegistrySnapshot
    ) throws -> ChangeSetLegacyImportReceipt {
        let digest = try Self.legacySnapshotDigest(legacySnapshot)
        if let receipt = image.legacyImportReceipt {
            guard receipt.snapshotDigest == digest else {
                throw ChangeSetClientRegistryError(.legacyImportConflict, "a different legacy snapshot was already imported")
            }
            return receipt
        }
        guard image.generation == expectedPristineGeneration, Self.isPristine(image),
              legacySnapshot.rootIdentityDigest == image.rootIdentityDigest,
              legacySnapshot.registryGeneration > expectedPristineGeneration else {
            throw ChangeSetClientRegistryError(.legacyImportNotPristine)
        }
        let importedSlots = legacySnapshot.slots.map {
            ClientSlot(
                number: $0.number,
                clientID: $0.clientID,
                slotGeneration: $0.slotGeneration,
                allocationState: $0.allocationState,
                currentEpoch: $0.currentEpoch,
                highWater: $0.highWater,
                replay: $0.replay
            )
        }
        let receipt = ChangeSetLegacyImportReceipt(snapshotDigest: digest, registryGeneration: legacySnapshot.registryGeneration)
        let next = RegistryImage(
            schema: image.schema,
            rootIdentityDigest: image.rootIdentityDigest,
            generation: legacySnapshot.registryGeneration,
            slots: importedSlots,
            receipts: legacySnapshot.controlReceipts,
            legacyImportReceipt: receipt
        )
        try persist(next)
        return receipt
    }

    public func lookup(clientID: String, epoch: UInt64, sequence: UInt64, requestDigest: String) throws -> ChangeSetClientLookup {
        let slot = try activeSlot(clientID: clientID, epoch: epoch)
        guard sequence > 0, sequence <= Self.maximumEpoch else {
            throw ChangeSetClientRegistryError(.sequenceGap)
        }
        if sequence == slot.highWater + 1 {
            if slot.highWater > 0,
               let previous = envelope(in: slot, sequence: slot.highWater),
               !previous.state.isTerminal {
                throw ChangeSetClientRegistryError(.previousPending)
            }
            return .new(nextSequence: sequence)
        }
        if sequence > slot.highWater + 1 {
            throw ChangeSetClientRegistryError(.sequenceGap)
        }
        let floor = max(1, slot.highWater > 255 ? slot.highWater - 255 : 1)
        guard sequence >= floor else { throw ChangeSetClientRegistryError(.clientExpired) }
        guard let record = envelope(in: slot, sequence: sequence) else {
            throw ChangeSetClientRegistryError(.storeCorrupt, "replay slot is missing inside replay floor")
        }
        guard record.requestDigest == requestDigest else {
            throw ChangeSetClientRegistryError(.sequenceConflict)
        }
        if record.state.isTerminal {
            guard let expiry = record.retentionExpiresAt, expiry > now() else {
                throw ChangeSetClientRegistryError(.clientExpired)
            }
            if let artifact = record.artifact, artifact.expiresAt <= now() {
                throw ChangeSetClientRegistryError(.clientExpired)
            }
            return .replay(record)
        }
        return .pending(record)
    }

    @discardableResult
    public func admit(
        clientID: String,
        epoch: UInt64,
        sequence: UInt64,
        requestDigest: String,
        transactionID: String,
        expectedRegistryGeneration: UInt64
    ) throws -> UInt64 {
        try requireGeneration(expectedRegistryGeneration)
        guard Self.isSHA256(requestDigest), !transactionID.isEmpty, transactionID.utf8.count <= 128 else {
            throw ChangeSetClientRegistryError(.invalidEnvelope)
        }
        let index = try activeSlotIndex(clientID: clientID, epoch: epoch)
        let lookup = try lookup(clientID: clientID, epoch: epoch, sequence: sequence, requestDigest: requestDigest)
        guard case .new = lookup else { return image.generation }
        var next = image
        next.generation += 1
        next.slots[index].highWater = sequence
        next.slots[index].replay[ringIndex(sequence)] = ChangeSetReplayEnvelope(
            sequence: sequence,
            requestDigest: requestDigest,
            transactionID: transactionID
        )
        next.slots[index].slotGeneration += 1
        try persist(next)
        return image.generation
    }

    @discardableResult
    public func markTerminal(
        clientID: String,
        epoch: UInt64,
        sequence: UInt64,
        state: ChangeSetReplayState,
        terminalResponseDigest: String,
        artifact: ChangeSetReplayArtifact?,
        retentionExpiresAt: Date,
        expectedRegistryGeneration: UInt64
    ) throws -> UInt64 {
        guard state.isTerminal else {
            throw ChangeSetClientRegistryError(.storeCorrupt, "terminal update requires terminal state")
        }
        guard Self.isSHA256(terminalResponseDigest), retentionExpiresAt > now(),
              artifact.map({ !$0.handle.isEmpty && $0.handle.utf8.count <= 512 && $0.expiresAt >= retentionExpiresAt }) ?? true else {
            throw ChangeSetClientRegistryError(.invalidEnvelope)
        }
        try requireGeneration(expectedRegistryGeneration)
        let index = try activeSlotIndex(clientID: clientID, epoch: epoch)
        let replayIndex = ringIndex(sequence)
        guard var record = image.slots[index].replay[replayIndex], record.sequence == sequence else {
            throw ChangeSetClientRegistryError(.storeCorrupt, "terminal update replay slot is missing")
        }
        record.state = state
        record.terminalResponseDigest = terminalResponseDigest
        record.artifact = artifact
        record.retentionExpiresAt = retentionExpiresAt
        var next = image
        next.generation += 1
        next.slots[index].replay[replayIndex] = record
        next.slots[index].slotGeneration += 1
        try persist(next)
        return image.generation
    }

    /// Durable cross-store intentの再生専用。process停止中にretention期限を越えても、pendingを
    /// exact terminal tombstoneへ収束させる。通常の新規terminal化は`markTerminal`を使う。
    @discardableResult
    public func reconcileTerminalIntent(
        clientID: String,
        epoch: UInt64,
        sequence: UInt64,
        state: ChangeSetReplayState,
        terminalResponseDigest: String,
        artifact: ChangeSetReplayArtifact?,
        retentionExpiresAt: Date,
        expectedRegistryGeneration: UInt64
    ) throws -> UInt64 {
        guard state.isTerminal, Self.isSHA256(terminalResponseDigest),
              artifact.map({ !$0.handle.isEmpty && $0.handle.utf8.count <= 512
                  && $0.expiresAt >= retentionExpiresAt }) ?? true else {
            throw ChangeSetClientRegistryError(.invalidEnvelope)
        }
        try requireGeneration(expectedRegistryGeneration)
        let index = try activeSlotIndex(clientID: clientID, epoch: epoch)
        let replayIndex = ringIndex(sequence)
        guard var record = image.slots[index].replay[replayIndex],
              record.sequence == sequence else {
            throw ChangeSetClientRegistryError(.storeCorrupt,
                "terminal intent replay slot is missing")
        }
        if record.state.isTerminal {
            guard record.state == state,
                  record.terminalResponseDigest == terminalResponseDigest,
                  record.artifact == artifact,
                  record.retentionExpiresAt == retentionExpiresAt else {
                throw ChangeSetClientRegistryError(.storeCorrupt,
                    "terminal intent conflicts with terminal replay")
            }
            return image.generation
        }
        guard record.state == .pending else {
            throw ChangeSetClientRegistryError(.storeCorrupt,
                "terminal intent requires an exact pending replay")
        }
        record.state = state
        record.terminalResponseDigest = terminalResponseDigest
        record.artifact = artifact
        record.retentionExpiresAt = retentionExpiresAt
        var next = image
        next.generation += 1
        next.slots[index].replay[replayIndex] = record
        next.slots[index].slotGeneration += 1
        try persist(next)
        return image.generation
    }

    public func allocate(
        controlRequestID: String,
        proofIDDigest: String,
        proofExpiresAt: Date,
        expectedRegistryGeneration: UInt64
    ) throws -> ChangeSetClientControlReceipt {
        if let replay = try replayControl(controlRequestID, proofDigest: proofIDDigest, action: .allocate) { return replay }
        try validateControl(controlRequestID: controlRequestID, proofIDDigest: proofIDDigest, proofExpiresAt: proofExpiresAt, expectedGeneration: expectedRegistryGeneration)
        guard let index = image.slots.firstIndex(where: { $0.allocationState == .free && $0.currentEpoch < Self.maximumEpoch }) else {
            throw ChangeSetClientRegistryError(.clientCapacityExceeded)
        }
        var next = image
        next.generation += 1
        next.slots[index].allocationState = .active
        next.slots[index].currentEpoch += 1
        next.slots[index].highWater = 0
        next.slots[index].replay = Array(repeating: nil, count: Self.replayCapacity)
        next.slots[index].slotGeneration += 1
        let receipt = makeReceipt(requestID: controlRequestID, proofDigest: proofIDDigest, action: .allocate, next: next, slot: next.slots[index], expiry: proofExpiresAt)
        try append(receipt, to: &next)
        try persist(next)
        return receipt
    }

    public func rotateEpoch(
        controlRequestID: String,
        proofIDDigest: String,
        proofExpiresAt: Date,
        clientID: String,
        expectedEpoch: UInt64,
        nextEpoch: UInt64,
        expectedRegistryGeneration: UInt64
    ) throws -> ChangeSetClientControlReceipt {
        if let replay = try replayControl(controlRequestID, proofDigest: proofIDDigest, action: .rotateEpoch) { return replay }
        try validateControl(controlRequestID: controlRequestID, proofIDDigest: proofIDDigest, proofExpiresAt: proofExpiresAt, expectedGeneration: expectedRegistryGeneration)
        let index = try activeSlotIndex(clientID: clientID, epoch: expectedEpoch)
        guard nextEpoch == expectedEpoch + 1, nextEpoch <= Self.maximumEpoch else {
            throw ChangeSetClientRegistryError(.clientEpochExhausted)
        }
        guard !image.slots[index].replay.compactMap({ $0 }).contains(where: { !$0.state.isTerminal }) else {
            throw ChangeSetClientRegistryError(.rotationBlocked)
        }
        var next = image
        next.generation += 1
        next.slots[index].currentEpoch = nextEpoch
        next.slots[index].highWater = 0
        next.slots[index].replay = Array(repeating: nil, count: Self.replayCapacity)
        next.slots[index].slotGeneration += 1
        let receipt = makeReceipt(requestID: controlRequestID, proofDigest: proofIDDigest, action: .rotateEpoch, next: next, slot: next.slots[index], expiry: proofExpiresAt)
        try append(receipt, to: &next)
        try persist(next)
        return receipt
    }

    public func retire(
        controlRequestID: String,
        proofIDDigest: String,
        proofExpiresAt: Date,
        clientID: String,
        expectedEpoch: UInt64,
        expectedRegistryGeneration: UInt64
    ) throws -> ChangeSetClientControlReceipt {
        if let replay = try replayControl(controlRequestID, proofDigest: proofIDDigest, action: .retire) { return replay }
        try validateControl(controlRequestID: controlRequestID, proofIDDigest: proofIDDigest, proofExpiresAt: proofExpiresAt, expectedGeneration: expectedRegistryGeneration)
        let index = try activeSlotIndex(clientID: clientID, epoch: expectedEpoch)
        guard !image.slots[index].replay.compactMap({ $0 }).contains(where: { !$0.state.isTerminal }) else {
            throw ChangeSetClientRegistryError(.retireBlocked)
        }
        var next = image
        next.generation += 1
        next.slots[index].allocationState = .free
        next.slots[index].highWater = 0
        next.slots[index].replay = Array(repeating: nil, count: Self.replayCapacity)
        next.slots[index].slotGeneration += 1
        let receipt = makeReceipt(requestID: controlRequestID, proofDigest: proofIDDigest, action: .retire, next: next, slot: next.slots[index], expiry: proofExpiresAt)
        try append(receipt, to: &next)
        try persist(next)
        return receipt
    }

    public func reinitialize(
        controlRequestID: String,
        proofIDDigest: String,
        proofExpiresAt: Date,
        expectedRegistryGeneration: UInt64
    ) throws -> ChangeSetClientControlReceipt {
        if let replay = try replayControl(controlRequestID, proofDigest: proofIDDigest, action: .reinitializeRegistry) { return replay }
        try validateControl(controlRequestID: controlRequestID, proofIDDigest: proofIDDigest, proofExpiresAt: proofExpiresAt, expectedGeneration: expectedRegistryGeneration)
        guard image.slots.allSatisfy({ $0.allocationState == .free }) else {
            throw ChangeSetClientRegistryError(.reinitializeBlocked)
        }
        var next = image
        next.generation += 1
        next.slots = (0..<Self.slotCount).map {
            ClientSlot(number: $0, clientID: UUID().uuidString.lowercased(), slotGeneration: 0, allocationState: .free, currentEpoch: 0, highWater: 0, replay: Array(repeating: nil, count: Self.replayCapacity))
        }
        let receipt = makeReceipt(requestID: controlRequestID, proofDigest: proofIDDigest, action: .reinitializeRegistry, next: next, slot: nil, expiry: proofExpiresAt)
        try append(receipt, to: &next)
        try persist(next)
        return receipt
    }

    private func activeSlot(clientID: String, epoch: UInt64) throws -> ClientSlot {
        image.slots[try activeSlotIndex(clientID: clientID, epoch: epoch)]
    }

    private func activeSlotIndex(clientID: String, epoch: UInt64) throws -> Int {
        guard let index = image.slots.firstIndex(where: { $0.clientID == clientID }) else {
            throw ChangeSetClientRegistryError(.clientNotRegistered)
        }
        let slot = image.slots[index]
        if epoch < slot.currentEpoch || slot.allocationState == .free { throw ChangeSetClientRegistryError(.clientExpired) }
        if epoch > slot.currentEpoch { throw ChangeSetClientRegistryError(.clientEpochAhead) }
        return index
    }

    private func envelope(in slot: ClientSlot, sequence: UInt64) -> ChangeSetReplayEnvelope? {
        let value = slot.replay[ringIndex(sequence)]
        return value?.sequence == sequence ? value : nil
    }

    private func ringIndex(_ sequence: UInt64) -> Int {
        Int((sequence - 1) % UInt64(Self.replayCapacity))
    }

    private func requireGeneration(_ expected: UInt64) throws {
        guard expected == image.generation else { throw ChangeSetClientRegistryError(.generationChanged) }
    }

    private func replayControl(_ requestID: String, proofDigest: String, action: ChangeSetClientControlAction) throws -> ChangeSetClientControlReceipt? {
        guard let receipt = image.receipts.compactMap({ $0 }).first(where: { $0.controlRequestID == requestID }) else { return nil }
        guard receipt.action == action, receipt.proofIDDigest == proofDigest else { throw ChangeSetClientRegistryError(.controlRequestConflict) }
        guard receipt.expiresAt > now() else { throw ChangeSetClientRegistryError(.controlExpired) }
        return receipt
    }

    private func validateControl(controlRequestID: String, proofIDDigest: String, proofExpiresAt: Date, expectedGeneration: UInt64) throws {
        try requireGeneration(expectedGeneration)
        guard Self.isCanonicalUUID(controlRequestID), Self.isSHA256(proofIDDigest), proofExpiresAt > now(), proofExpiresAt.timeIntervalSince(now()) <= 300 else {
            throw ChangeSetClientRegistryError(.ownerProofInvalid)
        }
        if image.receipts.compactMap({ $0 }).contains(where: { $0.proofIDDigest == proofIDDigest && $0.expiresAt > now() }) {
            throw ChangeSetClientRegistryError(.ownerProofConsumed)
        }
    }

    private func makeReceipt(
        requestID: String,
        proofDigest: String,
        action: ChangeSetClientControlAction,
        next: RegistryImage,
        slot: ClientSlot?,
        expiry: Date
    ) -> ChangeSetClientControlReceipt {
        let result = "\(action.rawValue)\u{0}\(next.generation)\u{0}\(slot?.slotGeneration ?? 0)\u{0}\(slot?.currentEpoch ?? 0)"
        return ChangeSetClientControlReceipt(
            controlRequestID: requestID,
            proofIDDigest: proofDigest,
            action: action,
            resultDigest: Self.sha256(Data(result.utf8)),
            registryGeneration: next.generation,
            clientID: slot?.clientID,
            slotIndex: slot?.number,
            slotGeneration: slot?.slotGeneration,
            currentEpoch: slot?.currentEpoch,
            expiresAt: expiry
        )
    }

    private func append(_ receipt: ChangeSetClientControlReceipt, to next: inout RegistryImage) throws {
        if let slot = next.receipts.firstIndex(where: { $0 == nil || $0!.expiresAt <= now() }) {
            next.receipts[slot] = receipt
            return
        }
        throw ChangeSetClientRegistryError(.controlCapacityExceeded)
    }

    private func persist(_ next: RegistryImage) throws {
        try Self.validate(next)
        let destination: Bank = activeBank == .a ? .b : .a
        try Self.writeBank(next, bank: destination, directory: directory, key: hmacKey)
        try Self.writePointer(destination, generation: next.generation, directory: directory)
        image = next
        activeBank = destination
    }
}

private extension ChangeSetClientRegistry {
    enum Bank: String { case a, b }
    enum BankLoad { case absent, invalid, valid(RegistryImage) }

    struct ClientSlot: Codable, Sendable {
        var number: Int
        var clientID: String
        var slotGeneration: UInt64
        var allocationState: ChangeSetClientAllocationState
        var currentEpoch: UInt64
        var highWater: UInt64
        var replay: [ChangeSetReplayEnvelope?]

        var snapshot: ChangeSetClientSlotSnapshot {
            ChangeSetClientSlotSnapshot(number: number, clientID: clientID, slotGeneration: slotGeneration, allocationState: allocationState, currentEpoch: currentEpoch, highWater: highWater)
        }
    }

    struct RegistryImage: Codable, Sendable {
        var schema: String
        var rootIdentityDigest: String
        var generation: UInt64
        var slots: [ClientSlot]
        var receipts: [ChangeSetClientControlReceipt?]
        var legacyImportReceipt: ChangeSetLegacyImportReceipt?
    }

    static func validate(_ image: RegistryImage) throws {
        guard image.schema == "aishell.change-set-client-registry.v1",
              isSHA256(image.rootIdentityDigest), image.generation <= maximumEpoch,
              image.slots.count == slotCount,
              image.receipts.count == controlReceiptCapacity,
              image.slots.enumerated().allSatisfy({ offset, slot in
                  slot.number == offset && isCanonicalUUID(slot.clientID) && slot.replay.count == replayCapacity &&
                      slot.slotGeneration <= maximumEpoch && slot.currentEpoch <= maximumEpoch && slot.highWater <= maximumEpoch
              }),
              Set(image.slots.map(\.clientID)).count == slotCount else {
            throw ChangeSetClientRegistryError(.storeCorrupt, "registry shape is invalid")
        }
        for slot in image.slots {
            if slot.allocationState == .free && (slot.highWater != 0 || slot.replay.contains(where: { $0 != nil })) {
                throw ChangeSetClientRegistryError(.storeCorrupt, "free client slot contains replay state")
            }
            if slot.allocationState == .active {
                let floor = max(1, slot.highWater > 255 ? slot.highWater - 255 : 1)
                if slot.highWater > 0 {
                    for sequence in floor...slot.highWater {
                        guard slot.replay[Int((sequence - 1) % UInt64(replayCapacity))]?.sequence == sequence else {
                            throw ChangeSetClientRegistryError(.storeCorrupt, "replay floor contains a missing slot")
                        }
                    }
                }
            }
            for record in slot.replay.compactMap({ $0 }) {
                guard record.sequence > 0, record.sequence <= slot.highWater,
                      isSHA256(record.requestDigest), !record.transactionID.isEmpty, record.transactionID.utf8.count <= 128,
                      isValidReplayEnvelope(record) else {
                    throw ChangeSetClientRegistryError(.storeCorrupt, "replay envelope is invalid")
                }
            }
        }
        for receipt in image.receipts.compactMap({ $0 }) {
            guard isCanonicalUUID(receipt.controlRequestID), isSHA256(receipt.proofIDDigest), isSHA256(receipt.resultDigest),
                  receipt.registryGeneration <= image.generation,
                  receipt.clientID.map(isCanonicalUUID) ?? true,
                  receipt.slotIndex.map({ (0..<slotCount).contains($0) }) ?? true,
                  receipt.slotGeneration.map({ $0 <= maximumEpoch }) ?? true,
                  receipt.currentEpoch.map({ $0 <= maximumEpoch }) ?? true,
                  (receipt.clientID == nil) == (receipt.slotIndex == nil),
                  (receipt.action == .reinitializeRegistry) == (receipt.clientID == nil) else {
                throw ChangeSetClientRegistryError(.storeCorrupt, "control receipt is invalid")
            }
        }
        if let receipt = image.legacyImportReceipt {
            guard isSHA256(receipt.snapshotDigest), receipt.registryGeneration > 0,
                  receipt.registryGeneration <= image.generation else {
                throw ChangeSetClientRegistryError(.storeCorrupt, "legacy import receipt is invalid")
            }
        }
    }

    static func isValidReplayEnvelope(_ record: ChangeSetReplayEnvelope) -> Bool {
        if record.state.isTerminal {
            guard let responseDigest = record.terminalResponseDigest, isSHA256(responseDigest),
                  let retentionExpiry = record.retentionExpiresAt else { return false }
            return record.artifact.map {
                !$0.handle.isEmpty && $0.handle.utf8.count <= 512 && $0.expiresAt >= retentionExpiry
            } ?? true
        }
        return record.terminalResponseDigest == nil && record.artifact == nil && record.retentionExpiresAt == nil
    }

    static func isPristine(_ image: RegistryImage) -> Bool {
        image.legacyImportReceipt == nil && image.receipts.allSatisfy { $0 == nil } && image.slots.allSatisfy {
            $0.allocationState == .free && $0.slotGeneration == 0 && $0.currentEpoch == 0 &&
                $0.highWater == 0 && $0.replay.allSatisfy { $0 == nil }
        }
    }

    static func legacySnapshotDigest(_ snapshot: ChangeSetLegacyRegistrySnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sha256(try encoder.encode(snapshot))
    }

    static func prepareDirectory(_ directory: URL) throws {
        var status = stat()
        if lstat(directory.path, &status) == 0 {
            guard (status.st_mode & S_IFMT) == S_IFDIR, status.st_uid == geteuid(), (status.st_mode & 0o077) == 0 else {
                throw ChangeSetClientRegistryError(.storeCorrupt, "registry directory must be owner-only and not a symlink")
            }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard chmod(directory.path, 0o700) == 0 else { throw ChangeSetClientRegistryError(.storeCorrupt, "registry directory chmod failed") }
    }

    static func loadBank(_ bank: Bank, directory: URL, key: SymmetricKey) throws -> BankLoad {
        let url = directory.appendingPathComponent("registry-\(bank.rawValue).bank")
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        var status = stat()
        guard lstat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(), (status.st_mode & 0o077) == 0, status.st_nlink == 1 else { return .invalid }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count == bankByteCount else { return .invalid }
        guard data.prefix(magic.count) == magic else { return .invalid }
        let generation = readUInt64(data, at: 24)
        let payloadLength = Int(readUInt64(data, at: 32))
        let crc = readUInt32(data, at: 40)
        guard payloadLength >= 0, payloadLength <= bankByteCount - bankHeaderByteCount else { return .invalid }
        let digest = data.subdata(in: 48..<80)
        let tag = data.subdata(in: 80..<112)
        let payload = data.subdata(in: bankHeaderByteCount..<(bankHeaderByteCount + payloadLength))
        guard crc32(payload) == crc, Data(SHA256.hash(data: payload)) == digest else { return .invalid }
        var authenticated = data.subdata(in: 0..<80)
        authenticated.append(payload)
        guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: authenticated, using: key) else { return .invalid }
        guard let decoded = try? JSONDecoder().decode(RegistryImage.self, from: payload), decoded.generation == generation,
              (try? validate(decoded)) != nil else { return .invalid }
        return .valid(decoded)
    }

    static func writeBank(_ image: RegistryImage, bank: Bank, directory: URL, key: SymmetricKey) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(image)
        guard payload.count <= bankByteCount - bankHeaderByteCount else {
            throw ChangeSetClientRegistryError(.storeCapacityExceeded)
        }
        var bytes = Data(repeating: 0, count: bankByteCount)
        bytes.replaceSubrange(0..<magic.count, with: magic)
        writeUInt64(image.generation, to: &bytes, at: 24)
        writeUInt64(UInt64(payload.count), to: &bytes, at: 32)
        writeUInt32(crc32(payload), to: &bytes, at: 40)
        let digest = Data(SHA256.hash(data: payload))
        bytes.replaceSubrange(48..<80, with: digest)
        var authenticated = bytes.subdata(in: 0..<80)
        authenticated.append(payload)
        let tag = Data(HMAC<SHA256>.authenticationCode(for: authenticated, using: key))
        bytes.replaceSubrange(80..<112, with: tag)
        bytes.replaceSubrange(bankHeaderByteCount..<(bankHeaderByteCount + payload.count), with: payload)
        try durableWrite(bytes, to: directory.appendingPathComponent("registry-\(bank.rawValue).bank"))
    }

    static func writePointer(_ bank: Bank, generation: UInt64, directory: URL) throws {
        let temporary = directory.appendingPathComponent("registry.pointer.tmp")
        let pointer = directory.appendingPathComponent("registry.pointer")
        let data = Data("\(bank.rawValue) \(generation)\n".utf8)
        try durableWrite(data, to: temporary)
        guard rename(temporary.path, pointer.path) == 0 else { throw ChangeSetClientRegistryError(.storeCorrupt, "registry pointer replace failed") }
        try fsyncDirectory(directory)
    }

    static func durableWrite(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ChangeSetClientRegistryError(.storeCorrupt, "registry bank open failed") }
        defer { close(fd) }
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                guard count > 0 else { throw ChangeSetClientRegistryError(.storeCorrupt, "registry bank write failed") }
                offset += count
            }
        }
        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0, fsync(fd) == 0 else {
            throw ChangeSetClientRegistryError(.storeCorrupt, "registry bank fsync failed")
        }
    }

    static func fsyncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw ChangeSetClientRegistryError(.storeCorrupt, "registry directory open failed") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw ChangeSetClientRegistryError(.storeCorrupt, "registry directory fsync failed") }
    }

    static func isCanonicalUUID(_ value: String) -> Bool {
        guard value == value.lowercased(), let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else { return false }
        return value[value.index(value.startIndex, offsetBy: 14)] == "4" && "89ab".contains(value[value.index(value.startIndex, offsetBy: 19)])
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }

    static func writeUInt64(_ value: UInt64, to data: inout Data, at offset: Int) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.replaceSubrange(offset..<(offset + 8), with: $0) }
    }

    static func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
    }

    static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        data.subdata(in: offset..<(offset + 8)).reduce(0) { ($0 << 8) | UInt64($1) }
    }

    static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
