import CryptoKit
import Foundation
import Synchronization

public struct DuplicateScanOptions: Equatable, Sendable {
    public var includesSubfolders = true
    public var includesHiddenFiles = false
    public var minimumFileBytes: Int64 = 0

    public init() {}
}

public struct DuplicateFile: Identifiable, Sendable {
    public var id: URL { url }
    public let url: URL
    let stamp: DuplicateFileStamp

    public var bytes: Int64 { stamp.bytes }
    public var modified: Date { stamp.modified }
    public var estimatedReclaimableBytes: Int64 { stamp.links == 1 ? stamp.allocatedBytes : 0 }
}

public struct DuplicateGroup: Identifiable, Sendable {
    public let id: UUID
    public let files: [DuplicateFile]
    public var fileSize: Int64 { files.first?.bytes ?? 0 }
}

public struct DuplicateIssue: Identifiable, Sendable {
    public let id = UUID()
    public let url: URL
    public let message: String
}

public enum DuplicateScanProgress: Sendable {
    case enumerating(files: Int)
    case matching(completed: Int, total: Int)
    case verifying
}

public struct DuplicateScanResult: Sendable {
    public let groups: [DuplicateGroup]
    public let issues: [DuplicateIssue]
    public let fileCount: Int

    public func groups(matchingPath query: String) -> [DuplicateGroup] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return groups }
        return groups.filter { group in
            group.files.contains { $0.url.path.localizedStandardContains(search) }
        }
    }

    public func removing(_ moved: Set<URL>) -> Self {
        let updated = groups.compactMap { group -> DuplicateGroup? in
            let remaining = group.files.filter { !moved.contains($0.url) }
            return remaining.count > 1 ? DuplicateGroup(id: group.id, files: remaining) : nil
        }
        return Self(groups: updated, issues: issues, fileCount: max(0, fileCount - moved.count))
    }
}

public struct DuplicateTrashResult: Sendable {
    public let moved: Set<URL>
    public let failures: [DuplicateIssue]
    public let wasCancelled: Bool
}

public enum FindDuplicates {
    private static let trashActive = Mutex(false)

    public static func scan(
        _ roots: [URL], options: DuplicateScanOptions,
        progress: @escaping @Sendable (DuplicateScanProgress) async -> Void = { _ in }
    ) async throws -> DuplicateScanResult {
        guard !roots.isEmpty else { throw ToolError.invalid("Choose at least one folder to scan.") }
        guard options.minimumFileBytes >= 0 else { throw ToolError.invalid("The minimum file size must be nonnegative.") }
        let collected = try await enumerate(roots, options: options, progress: progress)
        let candidates = Dictionary(grouping: collected.files, by: \.bytes).values.filter { $0.count > 1 }
        let total = candidates.reduce(0) { $0 + $1.count }
        var completed = 0
        var issues = collected.issues
        var prefixCandidates: [[DuplicateFile]] = []
        var groupFiles: [[DuplicateFile]] = []
        await progress(.matching(completed: 0, total: total))
        for sizeGroup in candidates {
            var prefixes: [SHA256.Digest: [DuplicateFile]] = [:]
            for file in sizeGroup {
                try Task.checkCancellation()
                do {
                    let hash = try DuplicateFileIO.hash(file, prefixOnly: true)
                    prefixes[hash, default: []].append(file)
                } catch {
                    try Task.checkCancellation()
                    issues.append(issue(for: error, fallback: file.url))
                }
                completed += 1
                if completed.isMultiple(of: 16) { await progress(.matching(completed: completed, total: total)) }
            }

            prefixCandidates += prefixes.values.filter { $0.count > 1 }
        }
        await progress(.verifying)
        for partialGroup in prefixCandidates {
            let exactCandidates: [[DuplicateFile]]
            if (partialGroup.first?.bytes ?? 0) <= DuplicateFileIO.prefixSize {
                exactCandidates = [partialGroup]
            } else {
                var digests: [SHA256.Digest: [DuplicateFile]] = [:]
                for file in partialGroup {
                    do {
                        let digest = try DuplicateFileIO.hash(file, prefixOnly: false)
                        digests[digest, default: []].append(file)
                    } catch {
                        try Task.checkCancellation()
                        issues.append(issue(for: error, fallback: file.url))
                    }
                }
                exactCandidates = digests.values.filter { $0.count > 1 }
            }
            for potential in exactCandidates {
                groupFiles += try partition(potential, issues: &issues)
            }
        }
        try Task.checkCancellation()
        let groups = groupFiles.map { DuplicateGroup(id: UUID(), files: $0.sorted(by: byPath)) }
            .sorted {
                if $0.fileSize != $1.fileSize { return $0.fileSize > $1.fileSize }
                return ($0.files.first?.url.path ?? "") < ($1.files.first?.url.path ?? "")
            }
        return DuplicateScanResult(groups: groups, issues: issues, fileCount: collected.files.count)
    }

    public static func trash(
        _ selected: Set<URL>, from scan: DuplicateScanResult
    ) async throws -> DuplicateTrashResult {
        try await trash(selected, from: scan) { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    // Only the filesystem action is injectable. All identity and content checks
    // are shared with the normal path that uses the macOS Trash.
    static func trash(
        _ selected: Set<URL>, from scan: DuplicateScanResult, move: @escaping @Sendable (URL) throws -> Void
    ) async throws -> DuplicateTrashResult {
        let acquired = trashActive.withLock { active in
            guard !active else { return false }
            active = true
            return true
        }
        guard acquired else { throw ToolError.invalid("Wait for the other Trash action to finish.") }
        defer { trashActive.withLock { $0 = false } }
        guard !selected.isEmpty else { throw ToolError.invalid("Select files to move to Trash.") }
        guard selected.isSubset(of: Set(scan.groups.flatMap { $0.files.map(\.url) })) else {
            throw ToolError.invalid("The selected files no longer match this scan.")
        }
        for group in scan.groups where group.files.allSatisfy({ selected.contains($0.url) }) {
            throw ToolError.invalid("Keep at least one file in each duplicate group.")
        }

        var moved = Set<URL>()
        var failures: [DuplicateIssue] = []
        for group in scan.groups {
            let kept = group.files.filter { !selected.contains($0.url) }
            for candidate in group.files where selected.contains(candidate.url) {
                if Task.isCancelled { return DuplicateTrashResult(moved: moved, failures: failures, wasCancelled: true) }
                do {
                    try DuplicateFileIO.check(candidate)
                    guard let reference = try matchingReference(for: candidate, from: kept) else {
                        throw ToolError.invalid("No kept copy could be verified. Scan again and review this group.")
                    }
                    try Task.checkCancellation()
                    try DuplicateFileIO.check(reference)
                    try DuplicateFileIO.check(candidate)
                    try move(candidate.url)
                    moved.insert(candidate.url)
                } catch {
                    if Task.isCancelled { return DuplicateTrashResult(moved: moved, failures: failures, wasCancelled: true) }
                    failures.append(DuplicateIssue(url: candidate.url, message: error.localizedDescription))
                }
                await Task.yield()
            }
        }
        return DuplicateTrashResult(moved: moved, failures: failures, wasCancelled: Task.isCancelled)
    }

    private static func matchingReference(for candidate: DuplicateFile, from kept: [DuplicateFile]) throws -> DuplicateFile? {
        for reference in kept {
            do {
                if try DuplicateFileIO.equal(reference, candidate) { return reference }
            } catch let error as DuplicateReadError where error.url == reference.url {
                continue
            }
        }
        return nil
    }

    private static func enumerate(
        _ roots: [URL], options: DuplicateScanOptions,
        progress: @escaping @Sendable (DuplicateScanProgress) async -> Void
    ) async throws -> (files: [DuplicateFile], issues: [DuplicateIssue]) {
        var seen = Set<DuplicateFileIdentity>()
        var files: [DuplicateFile] = []
        var issues: [DuplicateIssue] = []
        var flags: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !options.includesSubfolders { flags.insert(.skipsSubdirectoryDescendants) }
        if !options.includesHiddenFiles { flags.insert(.skipsHiddenFiles) }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]

        for root in roots {
            try Task.checkCancellation()
            let folder = root.resolvingSymlinksInPath().standardizedFileURL
            do {
                guard folder.isFileURL, try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                    throw ToolError.invalid("Choose a local folder.")
                }
                guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: flags,
                    errorHandler: { url, error in
                        issues.append(issue(for: error, fallback: url))
                        return !Task.isCancelled
                    }) else {
                    throw ToolError.invalid("Could not open this folder.")
                }
                while let entry = walker.nextObject() as? URL {
                    try Task.checkCancellation()
                    do {
                        let info = try entry.resourceValues(forKeys: keys)
                        if info.isSymbolicLink == true { walker.skipDescendants(); continue }
                        if info.isDirectory == true { continue }
                        guard let stamp = try DuplicateFileIO.inspect(entry), stamp.bytes >= options.minimumFileBytes,
                              !seen.contains(stamp.identity) else { continue }
                        try DuplicateFileIO.requireReadable(entry)
                        seen.insert(stamp.identity)
                        files.append(DuplicateFile(url: entry.standardizedFileURL, stamp: stamp))
                        if files.count.isMultiple(of: 64) { await progress(.enumerating(files: files.count)) }
                    } catch {
                        try Task.checkCancellation()
                        issues.append(issue(for: error, fallback: entry))
                    }
                }
            } catch {
                try Task.checkCancellation()
                issues.append(issue(for: error, fallback: folder))
            }
        }
        return (files, issues)
    }

    private static func partition(_ candidates: [DuplicateFile], issues: inout [DuplicateIssue]) throws -> [[DuplicateFile]] {
        var groups: [[DuplicateFile]] = []
        var invalid = Set<URL>()
        for file in candidates {
            try Task.checkCancellation()
            var matchingGroup: Int?
            for index in groups.indices {
                for reference in groups[index] where !invalid.contains(reference.url) {
                    do {
                        if try DuplicateFileIO.equal(reference, file) { matchingGroup = index }
                        break
                    } catch let error as DuplicateReadError {
                        invalid.insert(error.url)
                        issues.append(issue(for: error, fallback: file.url))
                        if error.url == file.url { break }
                    }
                }
                if matchingGroup != nil || invalid.contains(file.url) { break }
            }
            guard !invalid.contains(file.url) else { continue }
            if let matchingGroup { groups[matchingGroup].append(file) }
            else { groups.append([file]) }
        }
        return groups.map { $0.filter { !invalid.contains($0.url) } }.filter { $0.count > 1 }
    }

    private static func byPath(_ left: DuplicateFile, _ right: DuplicateFile) -> Bool {
        left.url.path.localizedStandardCompare(right.url.path) == .orderedAscending
    }

    private static func issue(for error: any Error, fallback: URL) -> DuplicateIssue {
        DuplicateIssue(url: (error as? DuplicateReadError)?.url ?? fallback, message: error.localizedDescription)
    }
}
