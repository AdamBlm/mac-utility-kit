import Darwin
import Foundation

struct StorageTreeScan {
    private let root: URL
    private let device: dev_t
    private var items: [StorageScanItem] = []
    private var branches: [Int] = []
    private var issues: [StorageScanIssue] = []
    private var omittedIssues = 0
    private var limitReached = false
    private var hardLinks: [DuplicateFileIdentity: Int] = [:]
    private static let itemLimit = 500_000

    static func run(
        _ folder: URL, progress: @Sendable (StorageScanProgress) async -> Void
    ) async throws -> StorageScanReport {
        try Task.checkCancellation()
        guard folder.isFileURL else { throw ToolError.invalid("Choose a local folder or volume.") }
        let canonical = folder.resolvingSymlinksInPath().standardizedFileURL
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw ToolError.invalid("Choose a readable folder or volume.")
        }
        let scanner = try openTree(canonical)
        defer { fts_close(scanner) }
        var scan = StorageTreeScan(root: canonical, device: info.st_dev)
        var lastUpdate = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let pointer = fts_read(scanner) else {
                if errno != 0 { scan.interrupt(reason: message(errno)) }
                break
            }
            let entry = pointer.pointee
            let code = Int32(entry.fts_info)
            if code == FTS_DP {
                let level = Int(entry.fts_level)
                if level >= 0, level < scan.branches.count { scan.branches.removeSubrange(level...) }
                continue
            }
            if scan.items.count >= itemLimit {
                scan.interrupt(reason: "Scan stopped at \(itemLimit.formatted()) items.")
                break
            }
            try scan.add(entry, code: code)
            if lastUpdate.duration(to: .now) > .milliseconds(150), let latest = scan.items.last {
                lastUpdate = .now
                await progress(StorageScanProgress(itemCount: scan.items.count, current: latest.url))
            }
        }
        try Task.checkCancellation()
        guard !scan.items.isEmpty, scan.items[0].kind == .folder,
              scan.items[0].stamp?.identity == DuplicateFileStamp(info).identity else {
            throw ToolError.invalid("Could not read the selected folder.")
        }
        let report = try scan.finish()
        await progress(StorageScanProgress(itemCount: report.items.count, current: report.root.url))
        try Task.checkCancellation()
        return report
    }

    private static func openTree(_ root: URL) throws -> UnsafeMutablePointer<FTS> {
        guard let cPath = strdup(root.path) else { throw ToolError.invalid("Could not open the scan path.") }
        defer { free(cPath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let scanner = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            throw ToolError.invalid(message(errno))
        }
        return scanner
    }

    private mutating func add(_ entry: FTSENT, code: Int32) throws {
        let level = Int(entry.fts_level)
        guard level >= 0, level <= branches.count else {
            interrupt(reason: "An item could not be placed in the scan tree.")
            return
        }
        let parent = level > 0 ? branches[level - 1] : nil
        let path = String(validatingCString: entry.fts_path)
        guard let path else {
            if let parent { items[parent].isPartial = true }
            addIssue(root, "A filename is not valid UTF-8.")
            return
        }
        let itemURL = URL(filePath: path)
        if (code == FTS_ERR || code == FTS_DNR), branches.indices.contains(level), items[branches[level]].url == itemURL {
            items[branches[level]].isPartial = true
            branches.removeSubrange(level...)

            addIssue(itemURL, Self.message(entry.fts_errno))
            return
        }
        if branches.count > level { branches.removeSubrange(level...) }
        let info = (code == FTS_NS || code == FTS_ERR) ? nil : entry.fts_statp?.pointee
        let kind = Self.kind(code, mode: info?.st_mode)
        if level == 0, kind != .folder {
            throw ToolError.invalid("Could not read the selected folder.")
        }
        var item = StorageScanItem(id: items.count, url: itemURL, kind: kind, parent: parent,
                                   stamp: info.map(DuplicateFileStamp.init))
        if code == FTS_DNR || code == FTS_ERR || code == FTS_NS || code == FTS_DC {
            item.isPartial = true
            addIssue(itemURL, Self.message(entry.fts_errno))
        } else if info?.st_dev != device {
            item.isPartial = true
            addIssue(itemURL, "On a different volume. Contents were skipped.")
        }
        if let parent { items[parent].children.append(item.id) }
        if code == FTS_D { branches.append(item.id) }
        if kind == .file, !item.isPartial, let stamp = item.stamp, stamp.links > 1 {
            let previous = hardLinks[stamp.identity]
            if previous.map({ items[$0].url.path.utf8.lexicographicallyPrecedes(item.url.path.utf8) }) != true {
                hardLinks[stamp.identity] = item.id
            }
        }
        items.append(item)
    }

    private static func kind(_ code: Int32, mode: mode_t?) -> StorageScanItem.Kind {
        if code == FTS_D || code == FTS_DNR || code == FTS_DC || mode.map({ $0 & S_IFMT == S_IFDIR }) == true {
            return .folder
        }
        if code == FTS_SL || code == FTS_SLNONE { return .link }
        if mode.map({ $0 & S_IFMT == S_IFREG }) == true { return .file }
        return .other
    }

    private mutating func finish() throws -> StorageScanReport {
        var ends = Array(repeating: 0, count: items.count)
        let unfinishedBranches = limitReached ? Set(branches) : []
        for index in items.indices.reversed() {
            try Task.checkCancellation()
            var item = items[index]
            ends[index] = item.children.last.map { ends[$0] } ?? index + 1
            if item.kind == .file, !item.isPartial, let stamp = item.stamp {
                let counted = stamp.links <= 1 || hardLinks[stamp.identity] == index
                item.allocatedBytes = counted ? stamp.allocatedBytes : 0
                item.apparentBytes = counted ? max(0, stamp.bytes) : 0
                item.estimatedReclaimableBytes = stamp.links == 1 ? stamp.allocatedBytes : 0
            } else if item.kind == .folder {
                for child in item.children {
                    let entry = items[child]
                    item.allocatedBytes = StorageExplorer.sum(item.allocatedBytes, entry.allocatedBytes)
                    item.apparentBytes = StorageExplorer.sum(item.apparentBytes, entry.apparentBytes)
                    item.estimatedReclaimableBytes = StorageExplorer.sum(item.estimatedReclaimableBytes,
                                                                        entry.estimatedReclaimableBytes)
                    item.isPartial = item.isPartial || entry.isPartial
                }
            }
            if unfinishedBranches.contains(index) { item.isPartial = true }
            items[index] = item
        }
        return StorageScanReport(items: items, issues: issues, omittedIssueCount: omittedIssues, subtreeEnds: ends)
    }

    private mutating func interrupt(reason: String) {
        addIssue(root, reason)
        limitReached = true
    }

    private mutating func addIssue(_ path: URL, _ reason: String) {
        if issues.count < 1000 {
            if !issues.contains(where: { $0.url == path }) { issues.append(StorageScanIssue(url: path, reason: reason)) }
        } else {
            omittedIssues += 1
        }
    }

    private static func message(_ code: Int32) -> String {
        code == 0 ? "Could not read this item." : String(cString: strerror(code))
    }
}
