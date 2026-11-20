import Foundation
import Testing
@testable import UtilityCore

struct EjectDisksTests {
    @Test func groupUsesExternalPhysicalDevicesAndUserImagesButProtectsStartupAndSharedStorage() {
        let startupStore = disk("disk1s1")
        let internalDisk = disk("disk0", partitions: [disk("disk0s1", mount: "/Volumes/internal")])
        let startupDisk = disk("disk1", partitions: [startupStore])
        let externalStore = disk("disk2s1")
        let external = disk("disk2", partitions: [externalStore, disk("disk2s2", mount: "/Volumes/Transfer")])
        let attachedImage = disk("disk3", partitions: [disk("disk3s1")])
        let systemImage = disk("disk4", partitions: [disk("disk4s1", mount: "/System/Mounted")])
        let sharedStore = disk("disk5s1")
        let sharedA = disk("disk5", partitions: [sharedStore, disk("disk5s2", mount: "/Volumes/Shared")])
        let sharedB = disk("disk6", partitions: [disk("disk6s1")])
        let all = [internalDisk, startupDisk, external, attachedImage, systemImage, sharedA, sharedB,
                   disk("disk7", stores: [startupStore], volumes: [disk("disk7s1", mount: "/")]),
                   disk("disk8", stores: [externalStore], volumes: [disk("disk8s1", mount: "/Volumes/Archive")]),
                   disk("disk9", stores: [disk("disk3s1")], volumes: [disk("disk9s1", mount: "/Volumes/Image")]),
                   disk("disk10", stores: [sharedStore, disk("disk6s1")], volumes: [disk("disk10s1", mount: "/Volumes/Pool")])]
        let groups = EjectDiskInventory.group(
            all: .init(disks: all, whole: all.map(\.device)),
            external: .init(disks: [], whole: ["disk1", "disk2", "disk5", "disk6"]),
            startup: .init(device: "disk7s1s1", whole: "disk7", stores: [.init(disk: "disk1s1")]),
            images: .init(images: [
                .init(path: "/Users/example/Test.dmg", owner: 501,
                      devices: ["/dev/disk3", "/dev/disk9"].map { .init(entry: $0) }),
                .init(path: "/System/Toolchain.dmg", owner: 0, devices: [.init(entry: "/dev/disk4")])
            ]),
            owner: 501
        )
        #expect(groups.map { $0.disk.device } == ["disk2", "disk3"])
        #expect(groups.first?.volumes.map(\.device) == ["disk2s2", "disk8s1"])
        #expect(groups.last?.volumes.map(\.device) == ["disk9s1"])
    }

    @Test func mixedBatchAndRetryKeepPerTargetOutcomes() async {
        let safe = EjectTarget(name: "USB", isWholeDevice: true, device: "disk20", registryID: 1)
        let busy = EjectTarget(name: "Card", isWholeDevice: true, device: "disk21", registryID: 2)
        let removed = EjectTarget(name: "Old image", isWholeDevice: true, device: "disk22", registryID: 3)
        let batch = await EjectDisks.perform([safe, busy, busy, removed]) { target in
            if target == busy { return .busy(nil) }
            return target == safe ? .ejected : .alreadyRemoved
        }
        #expect(batch.map(\.id) == [safe, busy, removed])
        #expect(batch.map(\.status) == [.ejected, .busy(nil), .alreadyRemoved])
        let retry = await EjectDisks.perform(batch.filter { $0.status == .busy(nil) }.map(\.id)) { _ in .ejected }
        #expect(retry.map(\.id) == [busy])
        #expect(retry.map(\.status) == [.ejected])
    }

    @Test func omittedTargetsGetAccurateOutcomesWithoutAttemptingAnAction() async throws {
        let targets = (1...5).map {
            EjectTarget(name: "Fixture \($0)", isWholeDevice: false, device: "disk20s\($0)", registryID: UInt64($0))
        }
        let outcome = await EjectDisks.perform(targets, eligible: [targets[0]], presence: { target in
            switch target.registryID {
            case 2: .absent
            case 3: .unmounted
            case 4: .present
            default: .unverified
            }
        }) { target in
            #expect(target == targets[0])
            return .busy(nil)
        }
        #expect(outcome.map(\.status) == [
            .busy(nil), .alreadyRemoved, .unmounted, .failed("This device is no longer eligible for eject."),
            .failed("Could not verify whether the device is still available.")
        ])
    }

    @Test func nativeAppleInventoryExcludesTheStartupVolume() async throws {
        let groups = try await EjectDisks.inventory()
        #expect(groups.flatMap(\.volumes).allSatisfy { $0.mount.path != "/" })
    }

    @Test func nativeProbeTreatsMissingMediaAsAbsent() {
        let target = EjectTarget(name: "Unavailable fixture", isWholeDevice: true, device: "disk999999999", registryID: 1)
        guard !FileManager.default.fileExists(atPath: "/dev/" + target.device) else { return }
        #expect(EjectDiskArbitration.presence(target) == .absent)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_EJECT_TEST_DISK"] != nil))
    func ejectsDisposableDiskImage() async throws {
        let identifier = try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_EJECT_TEST_DISK"])
        let groups = try await EjectDisks.inventory()
        let group = try #require(groups.first {
            $0.id.device == identifier && $0.isDiskImage && $0.name == "fixture.dmg"
                && $0.volumes.count == 1 && $0.volumes.first?.name == "MUK Eject Fixture"
        })
        let volume = try #require(group.volumes.first)
        let unmount = await EjectDisks.perform([volume.id])
        #expect(unmount.map(\.status) == [.unmounted])
        let remaining = try await EjectDisks.inventory()
        #expect(remaining.first(where: { $0.id == group.id })?.volumes.isEmpty == true)
        let result = await EjectDisks.perform([group.id])
        #expect(result.map(\.status) == [.ejected])
        let repeated = await EjectDisks.perform([group.id])
        #expect(repeated.map(\.status) == [.alreadyRemoved])
        let refreshed = try await EjectDisks.inventory()
        #expect(!refreshed.contains { $0.id == group.id })
    }

    private func disk(
        _ device: String, mount: String? = nil, partitions: [EjectDiskInventory.Disk]? = nil,
        stores: [EjectDiskInventory.Disk]? = nil, volumes: [EjectDiskInventory.Disk]? = nil
    ) -> EjectDiskInventory.Disk {
        .init(device: device, content: nil, volumeName: nil, mountPoint: mount, isSystem: nil,
              partitions: partitions, stores: stores, volumes: volumes)
    }
}
