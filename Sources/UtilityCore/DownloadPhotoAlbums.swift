import Foundation
import Photos

public enum DownloadPhotoAlbums {
    public static func importSelected(_ entries: [DownloadImage]) async throws -> DownloadsResult {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw ToolError.invalid("Photos access was denied or is unavailable. You can still copy the files to a folder.")
        }
        let stage = FileManager.default.temporaryDirectory.appending(path: ".muk-photos-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        var outcome = DownloadsResult()
        let groups = Dictionary(grouping: entries) { $0.origin ?? "Unknown Source" }
        for (origin, group) in groups.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let ready = group.compactMap { entry -> URL? in
                do {
                    return try OrganizeDownloads.copyForPhotos(entry, into: stage)
                } catch {
                    outcome.failures.append(entry.file.lastPathComponent + " · " + error.localizedDescription)
                    return nil
                }
            }
            guard !ready.isEmpty else { continue }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let album = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: origin)
                    let assets = ready.map { url in
                        let request = PHAssetCreationRequest.forAsset()
                        request.addResource(with: .photo, fileURL: url, options: nil)
                        return request.placeholderForCreatedAsset
                    }.compactMap { $0 }
                    album.addAssets(assets as NSArray)
                }
                outcome.completed.append(contentsOf: ready.map { $0.lastPathComponent + " → " + origin })
            } catch {
                outcome.failures.append(contentsOf: ready.map { $0.lastPathComponent + " · " + error.localizedDescription })
            }
        }
        return outcome
    }
}
