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
