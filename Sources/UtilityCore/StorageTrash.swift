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
        let bytes = items.reduce(Int64(0)) { sum($0, $1.estimatedReclaimableBytes) }
        return StorageTrashPreview(items: items, estimatedBytes: bytes)
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
        for item in selectedItems(ids, in: report) {
            do {
                try Task.checkCancellation()
                try await verifyTrashCandidate(item, in: report)
                try Task.checkCancellation()
                try move(item.url)
                moved.append(item.url)
            } catch is CancellationError {
                break
            } catch {
                issues.append(StorageScanIssue(url: item.url, reason: error.localizedDescription))
            }
        }
        return StorageTrashResult(moved: moved, issues: issues)
    }

    static func verifyTrashCandidate(_ item: StorageScanItem, in report: StorageScanReport) async throws {
        let changed = ToolError.invalid("This item changed after the scan. Scan again before moving it to Trash.")
        guard item.url.resolvingSymlinksInPath().standardizedFileURL.path == item.url.path,
              let expected = item.stamp else { throw changed }

        if item.kind == .file {
            guard try DuplicateFileIO.inspect(item.url) == expected else { throw changed }
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
            guard let stamp = node.stamp, let old = stamps[Data(node.url.path.utf8)], old == stamp else { throw changed }
        }
        var current = stat()
        guard lstat(item.url.path, &current) == 0, current.st_mode & S_IFMT == S_IFDIR,
              DuplicateFileStamp(current) == expected,
              item.url.resolvingSymlinksInPath().standardizedFileURL.path == item.url.path else { throw changed }
    }
}
