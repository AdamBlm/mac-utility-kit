import Foundation
import Photos

public enum DownloadPhotoAlbums {
    struct PreparedImage: Sendable {
        let url: URL
        let source: DownloadImage
    }

    public static func importSelected(_ entries: [DownloadImage]) async throws -> DownloadsResult {
        if Task.isCancelled { return DownloadsResult(wasCancelled: true) }
        guard let description = Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") as? String,
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.invalid("This build cannot request Photos access. You can still copy the files to a folder.")
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if Task.isCancelled { return DownloadsResult(wasCancelled: true) }
        guard status == .authorized || status == .limited else {
            throw ToolError.invalid("Photos access was denied or is unavailable. You can still copy the files to a folder.")
        }
        return try await importSelected(entries, writeAlbum: writeAlbum)
    }

    static func importSelected(
        _ entries: [DownloadImage], writeAlbum: @Sendable (String, [PreparedImage]) async throws -> Void
    ) async throws -> DownloadsResult {
        if Task.isCancelled { return DownloadsResult(wasCancelled: true) }
        let stage = FileManager.default.temporaryDirectory.appending(path: ".muk-photos-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        var outcome = DownloadsResult()
        var seen = Set<URL>()
        let unique = entries.filter { entry in
            if seen.insert(entry.file).inserted { return true }
            outcome.skipped.append(entry.relativePath)
            return false
        }
        let groups = Dictionary(grouping: unique) { $0.origin ?? "Unknown Source" }
        for (origin, group) in groups.sorted(by: { $0.key < $1.key }) {
            var ready: [PreparedImage] = []
            defer {
                for entry in ready { try? FileManager.default.removeItem(at: entry.url) }
            }
            for entry in group {
                if Task.isCancelled { break }
                do {
                    ready.append(PreparedImage(url: try OrganizeDownloads.copyForPhotos(entry, into: stage), source: entry))
                } catch is CancellationError {
                    outcome.wasCancelled = true
                    return outcome
                } catch {
                    outcome.failures.append(entry.relativePath + " · " + error.localizedDescription)
                }
            }
            if Task.isCancelled { break }
            guard !ready.isEmpty else { continue }
            do {
                try await writeAlbum(origin, ready)
                outcome.completed.append(contentsOf: ready.map { $0.source.relativePath + " → " + origin })
            } catch is CancellationError {
                outcome.wasCancelled = true
                return outcome
            } catch {
                outcome.failures.append(contentsOf: ready.map { $0.source.relativePath + " · " + error.localizedDescription })
            }
        }
        outcome.wasCancelled = Task.isCancelled
        return outcome
    }

    private static func writeAlbum(_ origin: String, _ images: [PreparedImage]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let album = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: origin)
            let assets = images.compactMap { entry in
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = entry.source.typeIdentifier
                options.originalFilename = entry.source.file.lastPathComponent
                request.addResource(with: .photo, fileURL: entry.url, options: options)
                return request.placeholderForCreatedAsset
            }
            album.addAssets(assets as NSArray)
        }
    }

}
