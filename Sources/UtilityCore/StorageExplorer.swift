import Darwin
import Foundation

public struct StorageScanIssue: Identifiable, Sendable {
    public let url: URL
    public let reason: String
    public var id: URL { url }
}

public struct StorageScanProgress: Sendable {
    public let itemCount: Int
    public let current: URL
}

public struct StorageScanItem: Identifiable, Sendable {
    public enum Kind: Sendable { case folder, file, link, other }
    public let id: Int
    public let url: URL
    public let kind: Kind
    public let parent: Int?
    public internal(set) var children: [Int] = []
    public internal(set) var allocatedBytes: Int64 = 0
    public internal(set) var apparentBytes: Int64 = 0
    public internal(set) var estimatedReclaimableBytes: Int64 = 0
    public internal(set) var isPartial = false
    public var modified: Date? { stamp?.modified }
    public var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
    public var isHardLink: Bool { kind == .file && (stamp?.links ?? 0) > 1 }
    public var canTrash: Bool { parent != nil && stamp != nil && !isPartial && (kind == .file || kind == .folder) }
    let stamp: DuplicateFileStamp?
}

public struct StorageScanReport: Sendable {
    public let items: [StorageScanItem]
    public let issues: [StorageScanIssue]
    public let omittedIssueCount: Int

    public var root: StorageScanItem { items[0] }

    // Descendants are contiguous in the pre-order scan.
    public func descendants(of id: Int) -> Range<Int> {
        guard subtreeEnds.indices.contains(id) else { return 0..<0 }
        return (id + 1)..<subtreeEnds[id]
    }

    let subtreeEnds: [Int]
}

public enum StorageExplorer {
    public enum Measurement: String, CaseIterable, Identifiable, Sendable {
        case allocated = "On disk"
        case apparent = "File size"

        public var id: Self { self }

        public func bytes(_ item: StorageScanItem) -> Int64 {
            self == .allocated ? item.allocatedBytes : item.apparentBytes
        }
    }

    public enum BrowserOrder: String, CaseIterable, Identifiable, Sendable {
        case largest = "Largest First"
        case name = "Name"
        case newest = "Newest First"
        case oldest = "Oldest First"

        public var id: Self { self }
    }

    public static func minimumBytes(megabytes text: String) -> Int64? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.allSatisfy({ (48...57).contains($0) }),
              let megabytes = Int64(value), megabytes > 0 else { return nil }
        let bytes = megabytes.multipliedReportingOverflow(by: 1_000_000)
        return bytes.overflow ? nil : bytes.partialValue
    }

    public static func browserItems(
        in report: StorageScanReport, directory: Int, minimumBytes: Int64?, measurement: Measurement,
        order: BrowserOrder = .largest
    ) throws -> [Int] {
        guard report.items.indices.contains(directory) else { return [] }
        let candidates: [Int]
        if let minimumBytes {
            candidates = try report.descendants(of: directory).filter { id in
                try Task.checkCancellation()
                let item = report.items[id]
                return item.kind == .file && measurement.bytes(item) >= minimumBytes
            }
        } else {
            candidates = report.items[directory].children
        }
        return try candidates.sorted { first, second in
            try Task.checkCancellation()
            let a = report.items[first]
            let b = report.items[second]
            switch order {
            case .largest:
                let aBytes = measurement.bytes(a)
                let bBytes = measurement.bytes(b)
                if aBytes != bBytes { return aBytes > bBytes }
            case .newest, .oldest:
                switch (a.modified, b.modified) {
                case let (first?, second?) where first != second:
                    return order == .newest ? first > second : first < second
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            case .name:
                break
            }
            let nameOrder = a.name.localizedStandardCompare(b.name)
            return nameOrder == .orderedSame ? a.url.path < b.url.path : nameOrder == .orderedAscending
        }
    }

    public static func displayedPath(for item: StorageScanItem, under directory: StorageScanItem) -> String {
        let folder = directory.url.pathComponents
        let path = item.url.pathComponents
        guard path.starts(with: folder), path.count > folder.count else { return item.name }
        return path.dropFirst(folder.count).joined(separator: "/")
    }

    public static func scan(
        _ folder: URL, progress: @Sendable (StorageScanProgress) async -> Void = { _ in }
    ) async throws -> StorageScanReport {
        try await StorageTreeScan.run(folder, progress: progress)
    }

    public static func selectedItems(_ ids: Set<Int>, in report: StorageScanReport) -> [StorageScanItem] {
        var afterSelectedFolder = 0
        return ids.sorted().compactMap { id in
            guard id >= afterSelectedFolder, report.items.indices.contains(id), report.items[id].canTrash else { return nil }
            let item = report.items[id]
            afterSelectedFolder = report.subtreeEnds[id]
            return item
        }
    }

    static func sum(_ a: Int64, _ b: Int64) -> Int64 {
        let result = a.addingReportingOverflow(b)
        return result.overflow ? Int64.max : result.partialValue
    }
}
