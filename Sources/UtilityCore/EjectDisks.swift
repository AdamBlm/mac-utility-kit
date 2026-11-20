import Foundation

public struct EjectVolume: Identifiable, Hashable, Sendable {
    public let id: EjectTarget
    public let name: String
    public let mount: URL
}

public struct EjectDevice: Identifiable, Hashable, Sendable {
    public let id: EjectTarget
    public let name: String
    public let isDiskImage: Bool
    public let volumes: [EjectVolume]
}

public struct EjectTarget: Hashable, Sendable {
    public let name: String
    public let isWholeDevice: Bool
    let device: String
    let registryID: UInt64

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.registryID == rhs.registryID && lhs.device == rhs.device && lhs.isWholeDevice == rhs.isWholeDevice
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(registryID)
        hasher.combine(device)
        hasher.combine(isWholeDevice)
    }
}

public struct EjectOutcome: Identifiable, Sendable {
    public enum Status: Equatable, Sendable {
        case ejected
        case unmounted
        case alreadyRemoved
        case busy(String?)
        case failed(String)
    }

    public let id: EjectTarget
    public let status: Status
}

public enum EjectDisks {
    enum TargetPresence: Sendable {
        case absent, unmounted, present, unverified
    }

    public static func inventory() async throws -> [EjectDevice] {
        try await EjectDiskInventory().scan()
    }

    public static func perform(_ targets: [EjectTarget]) async -> [EjectOutcome] {
        guard !targets.isEmpty else { return [] }
        do {
            let current = try await inventory()
            let eligible = Set(current.flatMap { device in
                [device.id] + device.volumes.map(\.id)
            })
            return await perform(targets, eligible: eligible, presence: EjectDiskArbitration.presence,
                                 action: EjectDiskArbitration.perform)
        } catch {
            return await perform(targets) { _ in
                .failed("Could not recheck device eligibility. " + error.localizedDescription)
            }
        }
    }

    static func perform(
        _ targets: [EjectTarget], eligible: Set<EjectTarget>, presence: (EjectTarget) -> TargetPresence,
        action: (EjectTarget) async -> EjectOutcome.Status
    ) async -> [EjectOutcome] {
        await perform(targets) { target in
            if eligible.contains(target) { return await action(target) }
            switch presence(target) {
            case .absent: return .alreadyRemoved
            case .unmounted: return .unmounted
            case .present: return .failed("This device is no longer eligible for eject.")
            case .unverified: return .failed("Could not verify whether the device is still available.")
            }
        }
    }

    static func perform(
        _ targets: [EjectTarget], action: (EjectTarget) async -> EjectOutcome.Status
    ) async -> [EjectOutcome] {
        var outcomes: [EjectOutcome] = []
        var seen = Set<EjectTarget>()
        for target in targets {
            if Task.isCancelled { break }
            guard seen.insert(target).inserted else { continue }
            let status = await action(target)
            outcomes.append(EjectOutcome(id: target, status: status))
        }
        return outcomes
    }
}
