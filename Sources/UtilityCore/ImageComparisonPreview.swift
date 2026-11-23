import CoreGraphics
import Foundation
import ImageIO

package struct ImageComparisonPreview: Sendable {
    package let image: CGImage
    package let isFullResolution: Bool
    package let pixelsPerSample: CGFloat

    package static func load(_ url: URL, detail: Bool, expected: LocalInputFile.Version? = nil) -> Self? {
        if let expected, (try? LocalInputFile.Version.read(url)) != expected { return nil }
        let file = expected?.resolved ?? url
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let full = detail && width > 0 && height > 0 && width <= 24_000_000 / height && max(width, height) <= 8_192
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: full ? max(width, height) : 2_400
        ] as CFDictionary) else { return nil }
        if let expected, (try? LocalInputFile.Version.read(url)) != expected { return nil }
        let originalEdge = max(width, height)
        let sampleEdge = max(image.width, image.height)
        return Self(image: image, isFullResolution: full && sampleEdge == originalEdge &&
                    min(image.width, image.height) == min(width, height),
                    pixelsPerSample: max(1, CGFloat(originalEdge) / CGFloat(sampleEdge)))
    }

    package func region(center: CGPoint, viewport: CGSize) -> CGImage? {
        guard viewport.width.isFinite, viewport.height.isFinite, viewport.width >= 1, viewport.height >= 1,
              (0...1).contains(center.x), (0...1).contains(center.y) else { return nil }
        let width = Int(min(CGFloat(image.width), viewport.width))
        let height = Int(min(CGFloat(image.height), viewport.height))
        let x = min(image.width - width, max(0, Int(center.x * CGFloat(image.width)) - width / 2))
        let y = min(image.height - height, max(0, Int(center.y * CGFloat(image.height)) - height / 2))
        return image.cropping(to: CGRect(x: x, y: y, width: width, height: height))
    }
}
