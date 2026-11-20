import AppKit
import Darwin
import Foundation

public enum UninstallApp {
    public enum Kind: String, Sendable {
        case app = "Application"
        case cache = "Cache"
        case preferences = "Preferences"
        case support = "Application Support"
        case container = "App Container"
        case savedState = "Saved State"
        case scripts = "Application Scripts"

        var isDirectory: Bool { self != .preferences }

        public var rationale: String {
            switch self {
            case .app: "The selected application bundle."
            case .cache: "Cache directory named exactly for this bundle identifier."
            case .preferences: "Preferences domain matching this bundle identifier."
            case .support: "Support directory named exactly for this bundle identifier."
            case .container: "App Sandbox container matching this bundle identifier."
            case .savedState: "Saved window and session state matching this bundle identifier."
            case .scripts: "App Sandbox scripts directory matching this bundle identifier."
            }
        }
    }

    public struct Item: Identifiable, Sendable {
        public var id: URL { url }
        public let url: URL
        public let kind: Kind
        public let estimatedBytes: Int64?
        public let issue: String?
        public var canTrash: Bool { snapshot != nil && issue == nil }
        let snapshot: Snapshot?
    }

    public struct Report: Sendable {
        public let application: URL
        public let name: String
        public let bundleIdentifier: String
        public let items: [Item]
        public let associatedItemsShared: Bool
        public var defaultSelection: Set<URL> {
            Set(items.filter { $0.kind == .app && $0.canTrash }.map(\.id))
        }
        let original: UninstallInventory.BundleWitness
    }

    public struct Progress: Sendable {
        public let completed: Int
        public let total: Int
        public let current: URL
    }

    public struct Result: Sendable {
        public let moved: [URL]
        public let issues: [StorageScanIssue]
        public let wasCancelled: Bool
    }

    enum Snapshot: Sendable {
        case file(DuplicateFileStamp)
        case directory(StorageScanReport)
    }

    public static func review(
        _ application: URL, progress: @Sendable (Progress) async -> Void = { _ in }
    ) async throws -> Report {
        try await review(application, environment: .system, progress: progress)
    }

    static func review(
        _ application: URL, environment: UninstallInventory.Environment,
        progress: @Sendable (Progress) async -> Void = { _ in }
    ) async throws -> Report {
        try Task.checkCancellation()
        let witness = try UninstallInventory.application(application, environment: environment)
        let shared = await UninstallInventory.hasOtherOwner(witness, environment: environment)
        var candidates = [(Kind.app, witness.url)]
        if !shared { candidates += UninstallInventory.exactLeaves(witness.identifier, home: environment.home) }
        var items: [Item] = []
        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            let (kind, url) = candidate
            await progress(Progress(completed: index, total: candidates.count, current: url))
            if let item = try await inspect(url, kind: kind, owner: environment.owner) { items.append(item) }
        }
        guard try UninstallInventory.application(application, environment: environment) == witness else {
            throw ToolError.invalid("The application changed during review. Choose it again.")
        }
        await progress(Progress(completed: candidates.count, total: candidates.count, current: witness.url))
        return Report(application: witness.url, name: witness.name, bundleIdentifier: witness.identifier,
                      items: items, associatedItemsShared: shared, original: witness)
    }

    public static func trash(_ selected: Set<URL>, from report: Report) async -> Result {
        await trash(selected, from: report, environment: .system) { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    static func trash(
        _ selected: Set<URL>, from report: Report, environment: UninstallInventory.Environment,
        move: (URL) throws -> Void
    ) async -> Result {
        var moved: [URL] = []
        var issues: [StorageScanIssue] = []
        // The bundle remains available as ownership evidence until associated
        // paths have been processed.
        let chosenPaths = Set(selected.filter(\.isFileURL).map { $0.standardizedFileURL.path })
        let requested = report.items.filter { chosenPaths.contains($0.url.standardizedFileURL.path) }
        let ordered = requested.filter { $0.kind != .app } + requested.filter { $0.kind == .app }
        for item in ordered {
            do {
                try Task.checkCancellation()
                try await recheck(item, from: report, environment: environment)
                try Task.checkCancellation()
                try move(item.url)
                moved.append(item.url)
            } catch is CancellationError {
                return Result(moved: moved, issues: issues, wasCancelled: true)
            } catch {
                issues.append(StorageScanIssue(url: item.url, reason: error.localizedDescription))
            }
        }
        return Result(moved: moved, issues: issues, wasCancelled: false)
    }

    private static func recheck(
        _ item: Item, from report: Report, environment: UninstallInventory.Environment
    ) async throws {
        guard item.canTrash, let snapshot = item.snapshot else {
            throw ToolError.invalid("This item was unavailable for removal during review.")
        }
        if await environment.isRunning(report.bundleIdentifier) {
            throw ToolError.invalid("The application is running. Quit it and review the items again.")
        }
        guard let current = try UninstallInventory.exactItem(item.url, kind: item.kind, owner: environment.owner) else {
            throw ToolError.invalid("This item no longer exists.")
        }
        try validateApplication(report, environment: environment)
        switch snapshot {
        case .file(let original):
            guard current == original else { throw ToolError.invalid("This file changed after review.") }
        case .directory(let scan):
            try await StorageExplorer.verifyTrashCandidate(scan.root, in: scan)
        }
        // The directory scan may take time. Recheck ownership and the app after it completes.
        if item.kind != .app, await UninstallInventory.hasOtherOwner(report.original, environment: environment) {
            throw ToolError.invalid("The associated files are now shared or their ownership could not be confirmed.")
        }
        if await environment.isRunning(report.bundleIdentifier) {
            throw ToolError.invalid("The application started again. Quit it before moving files to Trash.")
        }
        try validateApplication(report, environment: environment)
        guard try UninstallInventory.exactItem(item.url, kind: item.kind, owner: environment.owner) == current else {
            throw ToolError.invalid("This item changed after review.")
        }
    }

    private static func validateApplication(_ report: Report, environment: UninstallInventory.Environment) throws {
        guard (try? UninstallInventory.application(report.application, environment: environment)) == report.original else {
            throw ToolError.invalid("The selected application changed or is no longer available. Review it again.")
        }
    }

    private static func inspect(_ url: URL, kind: Kind, owner: uid_t) async throws -> Item? {
        do {
            guard let stamp = try UninstallInventory.exactItem(url, kind: kind, owner: owner) else { return nil }
            if kind.isDirectory {
                let scan = try await StorageExplorer.scan(url)
                guard !scan.root.isPartial, scan.root.stamp == stamp else {
                    return Item(url: url, kind: kind, estimatedBytes: scan.root.allocatedBytes,
                                issue: "Some contents could not be reviewed.", snapshot: nil)
                }
                return Item(url: url, kind: kind, estimatedBytes: scan.root.allocatedBytes,
                            issue: nil, snapshot: .directory(scan))
            }
            return Item(url: url, kind: kind, estimatedBytes: stamp.allocatedBytes,
                        issue: nil, snapshot: .file(stamp))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Item(url: url, kind: kind, estimatedBytes: nil, issue: error.localizedDescription, snapshot: nil)
        }
    }
}
