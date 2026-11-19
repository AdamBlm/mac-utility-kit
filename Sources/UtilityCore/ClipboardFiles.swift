import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
package enum ClipboardFiles {
    package static func read(from board: NSPasteboard, allowedTypes: [UTType]) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: allowedTypes.map(\.identifier)
        ]
        return (board.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? [])
            .filter { file in
                let host = file.host()?.lowercased() ?? ""
                guard file.isFileURL, host.isEmpty || host == "localhost",
                      file.user() == nil, file.password() == nil, file.port == nil,
                      file.query() == nil, file.fragment() == nil else { return false }
                return (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
    }

    package static func readImage(from board: NSPasteboard) throws -> CGImage? {
        var foundOversizedImage = false
        for item in board.pasteboardItems ?? [] {
            let imageTypes = item.types.filter { UTType($0.rawValue)?.conforms(to: .image) == true }
            let preferred = [NSPasteboard.PasteboardType.png, .tiff].filter(imageTypes.contains)
            for type in preferred + imageTypes.filter({ !preferred.contains($0) }) {
                guard let data = item.data(forType: type),
                      let source = CGImageSourceCreateWithData(data as CFData, nil) else { continue }
                let index = CGImageSourceGetPrimaryImageIndex(source)
                guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0 else { continue }
                guard width <= 80_000_000 / height else {
                    foundOversizedImage = true
                    continue
                }
                if let image = CGImageSourceCreateThumbnailAtIndex(source, index, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(width, height)
                ] as CFDictionary) { return image }
            }
        }
        if foundOversizedImage {
            throw ToolError.invalid("The clipboard image exceeds 80 megapixels.")
        }
        return nil
    }
}
