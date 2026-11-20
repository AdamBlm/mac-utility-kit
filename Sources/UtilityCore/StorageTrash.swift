import Darwin
import Foundation

public struct StorageTrashPreview: Sendable {
    public let items: [StorageScanItem]
    public let estimatedBytes: Int64
}

public struct StorageTrashResult: Sendable {
    public let moved: [URL]
    public let issues: [StorageScanIssue]
}

extension StorageExplorer {
    public static func trashPreview(_ ids: Set<Int>, in report: StorageScanReport) -> StorageTrashPreview {
        let items = selectedItems(ids, in: report)
        var bytes = items.reduce(Int64(0)) { sum($0, $1.estimatedReclaimableBytes) }
        let selectedRanges = items.map { $0.id..<report.subtreeEnds[$0.id] }
        let groups = report.completeHardLinkGroups
        if !groups.isEmpty {
            for range in selectedRanges {
                var index = lowerBound(count: groups.count) { groups[$0].ids[0] < range.lowerBound }
                while index < groups.count, groups[index].ids[0] < range.upperBound {
                    let group = groups[index]
                    if group.ids.dropFirst().allSatisfy({ isSelected($0, in: selectedRanges) }) {
                        bytes = sum(bytes, group.bytes)
                    }
                    index += 1
                }
            }
        }
        return StorageTrashPreview(items: items, estimatedBytes: bytes)
    }

    private static func isSelected(_ id: Int, in ranges: [Range<Int>]) -> Bool {
        let index = lowerBound(count: ranges.count) { ranges[$0].upperBound <= id }
        return index < ranges.count && ranges[index].contains(id)
    }

    private static func lowerBound(count: Int, precedesTarget: (Int) -> Bool) -> Int {
        var lower = 0
        var upper = count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if precedesTarget(middle) { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }

    public static func trash(_ ids: Set<Int>, in report: StorageScanReport) async -> StorageTrashResult {
        await trash(ids, in: report) { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    static func trash(
        _ ids: Set<Int>, in report: StorageScanReport, move: (URL) throws -> Void
    ) async -> StorageTrashResult {
        var moved: [URL] = []
        var issues: [StorageScanIssue] = []
        var hardLinks: [DuplicateFileIdentity: HardLinkUpdate] = [:]
        for item in selectedItems(ids, in: report) {
            do {
                try Task.checkCancellation()
                try await verifyTrashCandidate(item, in: report, hardLinks: hardLinks)
                try Task.checkCancellation()
                if item.isHardLink, let original = item.stamp {
                    let expected = updatedStamp(original, hardLinks: hardLinks)
                    if let current = try moveHardLink(item.url, expected: expected, move: move) {
                        hardLinks[original.identity] = HardLinkUpdate(original: original, current: current)
                    }
                } else {
                    try move(item.url)
                }
                moved.append(item.url)
            } catch is CancellationError {
                break
            } catch {
                issues.append(StorageScanIssue(url: item.url, reason: error.localizedDescription))
            }
        }
        return StorageTrashResult(moved: moved, issues: issues)
    }

    private struct HardLinkUpdate {
        let original: DuplicateFileStamp
        let current: DuplicateFileStamp
    }

    private static var changed: ToolError {
        .invalid("This item changed after the scan. Scan again before moving it to Trash.")
    }

    private static func updatedStamp(
        _ original: DuplicateFileStamp, hardLinks: [DuplicateFileIdentity: HardLinkUpdate]
    ) -> DuplicateFileStamp {
        guard let update = hardLinks[original.identity], update.original == original else { return original }
        return update.current
    }

    private static func moveHardLink(
        _ url: URL, expected: DuplicateFileStamp, move: (URL) throws -> Void
    ) throws -> DuplicateFileStamp? {
        let descriptor = open(url.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw changed }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              DuplicateFileStamp(before) == expected else { throw changed }
        try move(url)
        // A same-volume rename can advance ctime for all names of the inode.
        // Refresh from the opened inode only if its other observed state is intact.
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_mode == after.st_mode,
              before.st_uid == after.st_uid, before.st_gid == after.st_gid,
              before.st_flags == after.st_flags else { return nil }
        let current = DuplicateFileStamp(after)
        return current.matchesExceptChangeTime(expected) ? current : nil
    }

    static func verifyTrashCandidate(_ item: StorageScanItem, in report: StorageScanReport) async throws {
        try await verifyTrashCandidate(item, in: report, hardLinks: [:])
    }

    private static func verifyTrashCandidate(
        _ item: StorageScanItem, in report: StorageScanReport, hardLinks: [DuplicateFileIdentity: HardLinkUpdate]
    ) async throws {
        guard item.url.resolvingSymlinksInPath().standardizedFileURL.path == item.url.path,
              let expected = item.stamp else { throw changed }

        if item.kind == .file {
            guard try DuplicateFileIO.inspect(item.url) == updatedStamp(expected, hardLinks: hardLinks) else { throw changed }
            return
        }

        let fresh = try await scan(item.url)
        let descendants = report.descendants(of: item.id)
        guard !fresh.root.isPartial, fresh.items.count == descendants.count + 1,
              fresh.root.stamp == expected else { throw changed }
        let stamps = Dictionary(uniqueKeysWithValues: descendants.map { index in
            let node = report.items[index]
            return (Data(node.url.path.utf8), node.stamp)
        })
        for node in fresh.items.dropFirst() {
            try Task.checkCancellation()
            guard let stamp = node.stamp, let old = stamps[Data(node.url.path.utf8)] ?? nil,
                  updatedStamp(old, hardLinks: hardLinks) == stamp else { throw changed }
        }
        var current = stat()
        guard lstat(item.url.path, &current) == 0, current.st_mode & S_IFMT == S_IFDIR,
              DuplicateFileStamp(current) == expected,
              item.url.resolvingSymlinksInPath().standardizedFileURL.path == item.url.path else { throw changed }
    }
}
