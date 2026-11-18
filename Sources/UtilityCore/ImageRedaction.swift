import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageRedactionEffect: String, CaseIterable, Identifiable, Sendable {
    case solid = "Solid cover"
    case blur = "Blur"
    case pixelate = "Pixelate"

    public var id: Self { self }
}

public struct ImageMaskRegion: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Normalized bounds measured from the top-left of the upright image.
    public var rect: CGRect

    public init(id: UUID = UUID(), rect: CGRect) {
        self.id = id
        self.rect = rect
    }
}

public enum ImageRedaction {
    public struct Metadata: Sendable {
        fileprivate let title: String?
        fileprivate let author: String?
        fileprivate let copyright: String?

        fileprivate var PNGProperties: [CFString: String] {
            [
                kCGImagePropertyPNGTitle: title,
                kCGImagePropertyPNGAuthor: author,
                kCGImagePropertyPNGCopyright: copyright
            ].compactMapValues { $0 }
        }
    }

    public struct Source: Sendable {
        public let image: CGImage
        public let digest: String
        public let metadata: Metadata
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    public static func load(_ url: URL) throws -> Source {
        let input = url.resolvingSymlinksInPath()
        guard input.isFileURL,
              try input.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              let length = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              length <= 256 * 1024 * 1024 else {
            throw ToolError.invalid("Choose a local still image up to 256 MB.")
        }
        try Task.checkCancellation()
        let data = try Data(contentsOf: input)
        guard data.count <= 256 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1 else {
            throw ToolError.invalid("Choose a readable image with one frame or page.")
        }
        let properties = try ImageConversion.imageProperties(source)
        let (width, height) = try ImageConversion.validatedDimensions(properties)
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let raster: CGImage?
        if orientation == 1 {
            raster = CGImageSourceCreateImageAtIndex(source, index, nil)
        } else {
            raster = CGImageSourceCreateThumbnailAtIndex(source, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height)
            ] as CFDictionary)
        }
        guard let raster else { throw ToolError.invalid("Could not decode the upright image.") }
        try Task.checkCancellation()
        let digest = SHA256.hash(data: data).description
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        func text(_ first: CFString, _ second: CFString) -> String? {
            for candidate in [png[first], tiff[second]] {
                if let string = candidate as? String, !string.isEmpty, string.utf8.count <= 512,
                   string.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                    return string
                }
            }
            return nil
        }
        let metadata = Metadata(title: text(kCGImagePropertyPNGTitle, kCGImagePropertyTIFFImageDescription),
                                author: text(kCGImagePropertyPNGAuthor, kCGImagePropertyTIFFArtist),
                                copyright: text(kCGImagePropertyPNGCopyright, kCGImagePropertyTIFFCopyright))
        return Source(image: raster, digest: digest, metadata: metadata)
    }

    public static func pixelBounds(_ region: CGRect, width: Int, height: Int) throws -> CGRect {
        guard width > 0, height > 0, region.minX.isFinite, region.minY.isFinite,
              region.size.width.isFinite, region.size.height.isFinite, region.size.width > 0, region.size.height > 0,
              region.minX >= 0, region.minY >= 0, region.maxX <= 1 + 1e-12, region.maxY <= 1 + 1e-12 else {
            throw ToolError.invalid("A mask is empty or extends outside the image.")
        }
        let left = floor(region.minX * CGFloat(width))
        let right = min(CGFloat(width), ceil(region.maxX * CGFloat(width)))
        let top = floor(region.minY * CGFloat(height))
        let bottom = min(CGFloat(height), ceil(region.maxY * CGFloat(height)))
        guard right > left, bottom > top else { throw ToolError.invalid("A mask is empty or outside the image.") }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    public static func render(
        _ image: CGImage, regions: [ImageMaskRegion], effect: ImageRedactionEffect, strength: Double
    ) throws -> CGImage {
        guard (0...1).contains(strength), regions.count <= 256 else {
            throw ToolError.invalid("Choose a valid strength and use up to 256 masks per image.")
        }
        guard !regions.isEmpty else { return image }
        let original = CIImage(cgImage: image)
        var result = original
        for mask in regions {
            try Task.checkCancellation()
            let pixels = try pixelBounds(mask.rect, width: image.width, height: image.height)
            let rect = CGRect(x: pixels.minX, y: CGFloat(image.height) - pixels.maxY,
                              width: pixels.width, height: pixels.height)
            let patch: CIImage
            if effect == .solid {
                patch = CIImage(color: .black).cropped(to: rect)
            } else {
                let local = original.cropped(to: rect).clampedToExtent()
                let edge = min(rect.width, rect.height)
                if effect == .blur {
                    let filter = CIFilter.gaussianBlur()
                    filter.inputImage = local
                    filter.radius = Float(min(320, max(2, edge * (0.08 + 0.42 * strength))))
                    guard let image = filter.outputImage else { throw ToolError.invalid("Could not blur the selected mask.") }
                    patch = image.cropped(to: rect)
                } else {
                    let filter = CIFilter.pixellate()
                    filter.inputImage = local
                    filter.center = CGPoint(x: rect.midX, y: rect.midY)
                    filter.scale = Float(min(512, max(2, edge * (0.12 + 0.78 * strength))))
                    guard let image = filter.outputImage else { throw ToolError.invalid("Could not pixelate the selected mask.") }
                    patch = image.cropped(to: rect)
                }
            }
            result = patch.composited(over: result)
        }
        try Task.checkCancellation()
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let colorSpace = image.colorSpace?.model == .rgb ? image.colorSpace ?? srgb : srgb
        guard let rendered = context.createCGImage(result, from: original.extent,
                                                   format: image.bitsPerComponent > 8 ? .RGBA16 : .RGBA8,
                                                   colorSpace: colorSpace) else {
            throw ToolError.invalid("Could not flatten the masked image.")
        }
        return rendered
    }

    public static func writePNG(_ raster: CGImage, to output: URL, preserving metadata: Metadata? = nil) throws {
        guard output.isFileURL, !FileManager.default.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a new local PNG file.")
        }
        let manager = FileManager.default
        let staging = output.deletingLastPathComponent()
            .appendingPathComponent(".masked-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let candidate = staging.appendingPathComponent("Masked.png")
        guard let writer = CGImageDestinationCreateWithURL(candidate as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ToolError.invalid("Could not create the PNG output.")
        }
        let tags = metadata.map { [kCGImagePropertyPNGDictionary: $0.PNGProperties] as CFDictionary }
        CGImageDestinationAddImage(writer, raster, tags)
        guard CGImageDestinationFinalize(writer),
              let outputSource = CGImageSourceCreateWithURL(candidate as CFURL, nil),
              CGImageSourceGetCount(outputSource) == 1,
              let decoded = CGImageSourceCreateImageAtIndex(outputSource, 0, nil),
              decoded.width == raster.width, decoded.height == raster.height else {
            throw ToolError.invalid("Could not verify the flattened PNG.")
        }
        try Task.checkCancellation()
        try manager.moveItem(at: candidate, to: output)
    }
}
