import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
package enum ClipboardFiles {
    package static func read(from board: NSPasteboard, allowedTypes: [UTType]) -> [URL] {
        // Check content types after resolving local symlinks, as file drops do.
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (board.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? [])
            .filter { LocalInputFile.matches($0, allowedTypes: allowedTypes) }
    }

    package enum Content {
        case file(URL)
        case pdf(Data)
        case image(CGImage)
    }

    package static func content(from item: NSPasteboardItem, allowedTypes: [UTType],
                                acceptsPDF: Bool, acceptsImage: Bool) throws -> Content? {
        if let url = file(from: item, allowedTypes: allowedTypes) { return .file(url) }
        if acceptsPDF, let data = item.data(forType: .pdf) { return .pdf(data) }
        if acceptsImage, let image = try readImage(from: item) { return .image(image) }
        return nil
    }

    private static func file(from item: NSPasteboardItem, allowedTypes: [UTType]) -> URL? {
        guard let value = item.string(forType: .fileURL), let url = URL(string: value),
              LocalInputFile.matches(url, allowedTypes: allowedTypes) else { return nil }
        return url
    }

    package static func readImage(from board: NSPasteboard) throws -> CGImage? {
        var oversizedError: (any Error)?
        for item in board.pasteboardItems ?? [] {
            do {
                if let image = try readImage(from: item) { return image }
            } catch {
                oversizedError = error
            }
        }
        if let oversizedError { throw oversizedError }
        return nil
    }

    private static func readImage(from item: NSPasteboardItem) throws -> CGImage? {
        var foundOversizedImage = false
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
        if foundOversizedImage {
            throw ToolError.invalid("The clipboard image exceeds 80 megapixels.")
        }
        return nil
    }
}
