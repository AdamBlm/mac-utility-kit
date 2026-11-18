import Foundation
import ImageIO
import UniformTypeIdentifiers

struct MarkdownLocalImages {
    private let folder: URL?
    private var embeddedBytes = 0
    private var resourceCount = 0
    var issues: [String] = []

    init(folder: URL?) {
        self.folder = folder?.standardizedFileURL.resolvingSymlinksInPath()
    }

    mutating func resolve(_ raw: String) -> Result<String, ToolError> {
        let displayName = String(raw.prefix(200))
        guard let parts = URLComponents(string: raw), parts.scheme == nil, parts.host == nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let decoded = parts.percentEncodedPath.removingPercentEncoding,
              !decoded.isEmpty, !decoded.hasPrefix("/"), !decoded.hasPrefix("~"), !decoded.contains("\\"),
              !decoded.unicodeScalars.contains(where: { $0.value < 32 }) else {
            return .failure(.invalid("Blocked image source: \(displayName)"))
        }
        guard let folder, folder.isFileURL else {
            return .failure(.invalid("Choose an image folder to resolve \(displayName)."))
        }
        let file = folder.appendingPathComponent(decoded).standardizedFileURL.resolvingSymlinksInPath()
        let folderComponents = folder.pathComponents
        guard file.pathComponents.count > folderComponents.count,
              file.pathComponents.starts(with: folderComponents) else {
            return .failure(.invalid("Image is outside the chosen folder: \(displayName)"))
        }
        guard resourceCount < 48, embeddedBytes < 18_000_000 else {
            return .failure(.invalid("The document has reached its embedded image limit: \(displayName)"))
        }
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let fileSize = values.fileSize, fileSize <= 16_000_000,
              let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              Self.rasterTypes.contains(identifier),
              let image = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 1800
              ] as CFDictionary) else {
            return .failure(.invalid("Could not read a supported raster image: \(displayName)"))
        }
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            return .failure(.invalid("Could not prepare image: \(displayName)"))
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer), data.length <= 18_000_000 - embeddedBytes else {
            return .failure(.invalid("Image is too large to embed: \(displayName)"))
        }
        embeddedBytes += data.length
        resourceCount += 1
        return .success("data:image/png;base64," + (data as Data).base64EncodedString())
    }

    private static let rasterTypes: Set<String> = [
        UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier, UTType.tiff.identifier,
        UTType.bmp.identifier, UTType.heic.identifier, UTType.webP.identifier
    ]
}
