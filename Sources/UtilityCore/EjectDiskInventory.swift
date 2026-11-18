import Darwin
import Foundation

struct EjectDiskInventory {
    struct Disk: Decodable, Sendable {
        let device: String
        let content: String?
        let volumeName: String?
        let mountPoint: String?
        let isSystem: Bool?
        let partitions: [Disk]?
        let stores: [Disk]?
        let volumes: [Disk]?

        enum CodingKeys: String, CodingKey {
            case device = "DeviceIdentifier"
            case content = "Content"
            case volumeName = "VolumeName"
            case mountPoint = "MountPoint"
            case isSystem = "OSInternal"
            case partitions = "Partitions"
            case stores = "APFSPhysicalStores"
            case volumes = "APFSVolumes"
        }
    }

    struct DiskList: Decodable, Sendable {
        let disks: [Disk]
        let whole: [String]

        enum CodingKeys: String, CodingKey {
            case disks = "AllDisksAndPartitions"
            case whole = "WholeDisks"
        }
    }

    struct Startup: Decodable, Sendable {
        let device: String
        let whole: String?
        let stores: [StartupStore]?

        enum CodingKeys: String, CodingKey {
            case device = "DeviceIdentifier"
            case whole = "ParentWholeDisk"
            case stores = "APFSPhysicalStores"
        }
    }

    struct StartupStore: Decodable, Sendable {
        let disk: String
        enum CodingKeys: String, CodingKey { case disk = "APFSPhysicalStore" }
    }

    struct Images: Decodable, Sendable {
        let images: [Image]
    }

    struct Image: Decodable, Sendable {
        let path: String?
        let owner: UInt32?
        let devices: [ImageDisk]?

        enum CodingKeys: String, CodingKey {
            case path = "image-path"
            case owner = "owner-uid"
            case devices = "system-entities"
        }
    }

    struct ImageDisk: Decodable, Sendable {
        let entry: String?
        enum CodingKeys: String, CodingKey { case entry = "dev-entry" }
    }

    struct DeviceGroup: Sendable {
        let disk: Disk
        let image: String?
        let volumes: [Disk]
    }

    func scan() async throws -> [EjectDevice] {
        let temporary = FileManager.default.temporaryDirectory.appending(path: "eject-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let diskutil = "/usr/sbin/diskutil"
        async let all = read(DiskList.self, diskutil, ["list", "-plist"], in: temporary)
        async let external = read(DiskList.self, diskutil, ["list", "-plist", "external", "physical"], in: temporary)
        async let startup = read(Startup.self, diskutil, ["info", "-plist", "/"], in: temporary)
        async let images = read(Images.self, "/usr/bin/hdiutil", ["info", "-plist"], in: temporary)
        let groups = try await Self.group(all: all, external: external, startup: startup, images: images, owner: getuid())
        try Task.checkCancellation()
        return EjectDiskArbitration.attachIdentities(to: groups)
    }

    static func group(
        all: DiskList, external: DiskList, startup: Startup, images: Images, owner: UInt32
    ) -> [DeviceGroup] {
        var rootByPartition: [String: String] = [:]
        var volumes: [String: [Disk]] = [:]
        for disk in all.disks {
            rootByPartition[disk.device] = disk.device
            for partition in disk.partitions ?? [] {
                rootByPartition[partition.device] = disk.device
            }
            volumes[disk.device] = [disk] + (disk.partitions ?? [])
        }
        var excluded = Set([startup.device, startup.whole].compactMap { $0 })
        excluded.formUnion((startup.stores ?? []).compactMap { rootByPartition[$0.disk] })
        let diskImages = imageRoots(images, all: all, owner: owner)
        let candidates = Set(external.whole).union(diskImages.keys)
        for container in all.disks {
            guard let stores = container.stores, !stores.isEmpty else { continue }
            let roots = Set(stores.compactMap { rootByPartition[$0.device] })
            if container.device == startup.whole || container.volumes?.contains(where: { $0.mountPoint == "/" }) == true {
                excluded.formUnion(roots)
            }
            if roots.count != 1 || stores.contains(where: { rootByPartition[$0.device] == nil }) {
                excluded.formUnion(roots)
                continue
            }
            if let root = roots.first { volumes[root, default: []] += container.volumes ?? [] }
        }
        return all.disks.compactMap { disk in
            guard candidates.contains(disk.device), !excluded.contains(disk.device), disk.isSystem != true,
                  !hasSharedStorage(disk) else { return nil }
            let parts = volumes[disk.device, default: []]
            guard !parts.contains(where: { item in
                item.device == startup.device || item.mountPoint.map { path in
                    path == "/" || item.isSystem == true || isSystemLocation(path)
                } == true
            }) else { return nil }
            let mounted = parts.filter { disk in
                guard let path = disk.mountPoint, path.hasPrefix("/"), !path.isEmpty else { return false }
                return disk.isSystem != true && !isSystemLocation(path)
            }
            return DeviceGroup(disk: disk, image: diskImages[disk.device], volumes: mounted)
        }
    }

    private static func imageRoots(_ images: Images, all: DiskList, owner: UInt32) -> [String: String] {
        let possible = Set(all.disks.filter { $0.stores?.isEmpty != false }.map(\.device))
        var roots: [String: String] = [:]
        for image in images.images {
            guard image.owner == owner, let path = image.path, path.hasPrefix("/"),
                  !isSystemLocation(URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path) else { continue }
            let devices = Set((image.devices ?? []).compactMap { entry -> String? in
                guard let path = entry.entry, path.hasPrefix("/dev/") else { return nil }
                return String(path.dropFirst(5))
            }).intersection(possible)
            if devices.count == 1, let root = devices.first { roots[root] = path }
        }
        return roots
    }

    static func isSystemLocation(_ path: String) -> Bool {
        let roots = ["/System", "/private/var/run", "/var/run", "/Library/Developer", "/Library/Apple"]
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static func hasSharedStorage(_ disk: Disk) -> Bool {
        ([disk] + (disk.partitions ?? [])).contains { item in
            let content = item.content?.lowercased() ?? ""
            return content.contains("apple_raid") || content.contains("apple_corestorage")
        }
    }

    private func read<T: Decodable & Sendable>(
        _ type: T.Type, _ command: String, _ arguments: [String], in temporary: URL
    ) async throws -> T {
        let output = temporary.appending(path: UUID().uuidString)
        try Data().write(to: output)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        try await ExternalTool.run(URL(filePath: command), name: URL(filePath: command).lastPathComponent,
                                   arguments: arguments, directory: temporary, standardOutput: handle)
        return try PropertyListDecoder().decode(type, from: Data(contentsOf: output))
    }
}
