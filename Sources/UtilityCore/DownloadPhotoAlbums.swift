import Foundation
import Photos

public enum DownloadPhotoAlbums {
    public static func importSelected(_ entries: [DownloadImage]) async throws -> DownloadsResult {
        if Task.isCancelled { return DownloadsResult(wasCancelled: true) }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if Task.isCancelled { return DownloadsResult(wasCancelled: true) }
        guard status == .authorized || status == .limited else {
            throw ToolError.invalid("Photos access was denied or is unavailable. You can still copy the files to a folder.")
        }
        let stage = FileManager.default.temporaryDirectory.appending(path: ".muk-photos-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        var outcome = DownloadsResult()
        let groups = Dictionary(grouping: entries) { $0.origin ?? "Unknown Source" }
        for (origin, group) in groups.sorted(by: { $0.key < $1.key }) {
            var ready: [(url: URL, typeIdentifier: String)] = []
            for entry in group {
                if Task.isCancelled { break }
                do {
                    ready.append((try OrganizeDownloads.copyForPhotos(entry, into: stage), entry.typeIdentifier))
                } catch is CancellationError {
                    outcome.wasCancelled = true
                    return outcome
                } catch {
                    outcome.failures.append(entry.file.lastPathComponent + " · " + error.localizedDescription)
                }
            }
            if Task.isCancelled { break }
            guard !ready.isEmpty else { continue }
            do {
                let assetsToImport = ready
                try await PHPhotoLibrary.shared().performChanges {
                    let album = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: origin)
                    let assets = assetsToImport.map { entry in
                        let request = PHAssetCreationRequest.forAsset()
                        let options = PHAssetResourceCreationOptions()
                        options.uniformTypeIdentifier = entry.typeIdentifier
                        request.addResource(with: .photo, fileURL: entry.url, options: options)
                        return request.placeholderForCreatedAsset
                    }.compactMap { $0 }
                    album.addAssets(assets as NSArray)
                }
                outcome.completed.append(contentsOf: ready.map { $0.url.lastPathComponent + " → " + origin })
            } catch is CancellationError {
                outcome.wasCancelled = true
                return outcome
            } catch {
                outcome.failures.append(contentsOf: ready.map { $0.url.lastPathComponent + " · " + error.localizedDescription })
            }
        }
        outcome.wasCancelled = Task.isCancelled
        return outcome
    }
}
