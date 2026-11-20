import Darwin
import DiskArbitration
import Foundation
import IOKit

enum EjectDiskArbitration {
    private struct Reply: Sendable {
        let code: Int32
        let detail: String?

        init(_ dissenter: DADissenter?) {
            code = dissenter.map(DADissenterGetStatus) ?? 0
            detail = dissenter.flatMap(DADissenterGetStatusString).map { $0 as String }
        }

        func outcome(success: EjectOutcome.Status) -> EjectOutcome.Status {
            switch code {
            case 0: success
            case Int32(kDAReturnBusy), Int32(kDAReturnExclusiveAccess): .busy(detail)
            case Int32(kDAReturnNotFound): .alreadyRemoved
            case Int32(kDAReturnNotMounted): .unmounted
            default: .failed(detail ?? "Disk Arbitration returned \(String(UInt32(bitPattern: code), radix: 16)).")
            }
        }
    }

    private final class Pending {
        let continuation: CheckedContinuation<Reply, Never>

        init(_ continuation: CheckedContinuation<Reply, Never>) {
            self.continuation = continuation
        }
    }

    private static let complete: DADiskUnmountCallback = { _, dissenter, context in
        guard let context else { return }
        let pending = Unmanaged<Pending>.fromOpaque(context).takeRetainedValue()
        pending.continuation.resume(returning: Reply(dissenter))
    }

    static func attachIdentities(to groups: [EjectDiskInventory.DeviceGroup]) -> [EjectDevice] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
        return groups.compactMap { group in
            guard let disk = disk(group.disk.device, session: session),
                  let details = description(disk), isExternal(details),
                  details[kDADiskDescriptionMediaWholeKey] as? Bool == true,
                  let identity = registryIdentity(disk) else { return nil }
            let volumes: [EjectVolume] = group.volumes.compactMap { volume in
                guard let disk = self.disk(volume.device, session: session),
                      let metadata = description(disk), isExternal(metadata),
                      let mount = mountedPath(metadata), mount.path == volume.mountPoint,
                      let registryID = registryIdentity(disk) else { return nil }
                let name = volume.volumeName ?? mount.lastPathComponent
                return EjectVolume(id: EjectTarget(name: name, isWholeDevice: false, device: volume.device,
                                                   registryID: registryID), name: name, mount: mount)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            // An unresolved mounted volume makes the whole-device target ambiguous.
            guard volumes.count == group.volumes.count else { return nil }
            let mediaName = details[kDADiskDescriptionMediaNameKey] as? String
            let name = group.image.map { URL(filePath: $0).lastPathComponent }
                ?? mediaName.flatMap { $0.isEmpty ? nil : $0 }
                ?? volumes.first?.name
                ?? group.disk.device
            let target = EjectTarget(name: name, isWholeDevice: true, device: group.disk.device, registryID: identity)
            return EjectDevice(id: target, name: name, isDiskImage: group.image != nil, volumes: volumes)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func presence(_ target: EjectTarget) -> EjectDisks.TargetPresence {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return .unverified }
        guard let disk = disk(target.device, session: session) else { return .absent }
        guard let registryID = registryIdentity(disk) else {
            // Disk Arbitration can return a placeholder even after the media disappears.
            var details = stat()
            if lstat("/dev/" + target.device, &details) != 0, errno == ENOENT { return .absent }
            return .unverified
        }
        guard registryID == target.registryID else { return .absent }
        guard let details = description(disk) else { return .unverified }
        if !target.isWholeDevice, isExternal(details), mountedPath(details) == nil { return .unmounted }
        return .present
    }

    static func perform(_ target: EjectTarget) async -> EjectOutcome.Status {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            return .failed("Could not connect to Disk Arbitration.")
        }
        let queue = DispatchQueue(label: "MacUtilityKit.EjectDisk")
        DASessionSetDispatchQueue(session, queue)
        defer { DASessionSetDispatchQueue(session, nil) }
        guard let disk = disk(target.device, session: session), registryIdentity(disk) == target.registryID else {
            return .alreadyRemoved
        }
        guard let details = description(disk), isExternal(details) else {
            return .failed("This device is no longer eligible for eject.")
        }
        if target.isWholeDevice {
            guard details[kDADiskDescriptionMediaWholeKey] as? Bool == true else {
                return .failed("Could not verify the whole device.")
            }
        } else if mountedPath(details) == nil {
            return .unmounted
        }
        let options = target.isWholeDevice ? kDADiskUnmountOptionWhole : kDADiskUnmountOptionDefault
        let unmount = await withCheckedContinuation { continuation in
            let pending = Unmanaged.passRetained(Pending(continuation)).toOpaque()
            DADiskUnmount(disk, DADiskUnmountOptions(options), complete, pending)
        }
        guard target.isWholeDevice, unmount.code == 0 || unmount.code == Int32(kDAReturnNotMounted) else {
            return unmount.outcome(success: .unmounted)
        }
        guard registryIdentity(disk) == target.registryID else { return .alreadyRemoved }
        let eject = await withCheckedContinuation { continuation in
            let pending = Unmanaged.passRetained(Pending(continuation)).toOpaque()
            DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), complete, pending)
        }
        if eject.code != 0, registryIdentity(disk) != target.registryID { return .alreadyRemoved }
        if case .failed(let detail) = eject.outcome(success: .ejected) {
            return .failed("Volumes were unmounted. The device could not be ejected. " + detail)
        }
        return eject.outcome(success: .ejected)
    }

    private static func disk(_ identifier: String, session: DASession) -> DADisk? {
        guard identifier.wholeMatch(of: /disk[0-9]+(?:s[0-9]+)*/) != nil else { return nil }
        return ("/dev/" + identifier).withCString { DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0) }
    }

    private static func registryIdentity(_ disk: DADisk) -> UInt64? {
        let media = DADiskCopyIOMedia(disk)
        guard media != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(media) }
        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media, &registryID) == KERN_SUCCESS else { return nil }
        return registryID
    }

    private static func description(_ disk: DADisk) -> [CFString: Any]? {
        DADiskCopyDescription(disk) as? [CFString: Any]
    }

    private static func isExternal(_ details: [CFString: Any]) -> Bool {
        guard details[kDADiskDescriptionDeviceInternalKey] as? Bool != true else { return false }
        let mount = (details[kDADiskDescriptionVolumePathKey] as? URL)?.path
        return mount != "/" && mount.map(EjectDiskInventory.isSystemLocation) != true
    }

    private static func mountedPath(_ details: [CFString: Any]) -> URL? {
        details[kDADiskDescriptionVolumePathKey] as? URL
    }
}
