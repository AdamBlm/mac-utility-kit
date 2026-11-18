import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageConversionFormat: String, CaseIterable, Sendable {
    case jpg, png, heic, tiff, webp

    public var title: String { self == .jpg ? "JPEG" : self == .webp ? "WebP" : rawValue.uppercased() }
    public var requiresImageMagick: Bool { self == .webp }

    var type: UTType {
        switch self {
        case .jpg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .webp: .webP
        }
    }
}

public struct ImageConversionOptions: Sendable {
    public var format: ImageConversionFormat = .png
    public var quality = 0.85
    public var preserveMetadata = true
    public var flattenTransparency = false
    public var backgroundRGB: UInt32 = 0xFFFFFF
    public var imageMagickExecutable: URL?
    public var losslessWebP = false

    public init() {}
}

public enum ImageConversion {
    public static func hasTransparency(_ input: URL) throws -> Bool {
        let source = try loadSource(input)
        let properties = try imageProperties(source)
        if let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool { return hasAlpha }
        _ = try validatedDimensions(properties)
        guard let image = CGImageSourceCreateImageAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) else {
            throw ToolError.invalid("Could not determine whether the image has transparency.")
        }
        return imageContainsAlpha(image)
    }

    public static func convert(_ input: URL, to output: URL, options: ImageConversionOptions) async throws -> String {
        guard input.isFileURL, output.isFileURL,
              input.standardizedFileURL != output.standardizedFileURL,
              !FileManager.default.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose an output file that does not already exist.")
        }
        if options.format.requiresImageMagick, options.imageMagickExecutable == nil {
            throw ToolError.invalid("Choose ImageMagick 7 to export WebP.")
        }
        guard options.quality.isFinite, (0...1).contains(options.quality) else {
            throw ToolError.invalid("Choose a quality between 0 and 100 percent.")
        }
        try Task.checkCancellation()
        let source = try loadSource(input)
        let properties = try imageProperties(source)
        let (width, height) = try validatedDimensions(properties)
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let image: CGImage?
        if orientation == 1 {
            image = CGImageSourceCreateImageAtIndex(source, index, nil)
        } else {
            image = CGImageSourceCreateThumbnailAtIndex(source, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height)
            ] as CFDictionary)
        }
        guard let image else { throw ToolError.invalid("Could not decode the primary image.") }
        let sourceDepth = properties[kCGImagePropertyDepth] as? Int ?? image.bitsPerComponent
        if options.format == .webp, options.losslessWebP,
           max(sourceDepth, image.bitsPerComponent) > 8 || image.bitmapInfo.contains(.floatComponents) {
            throw ToolError.invalid("Lossless WebP supports up to 8 bits per channel. Choose a different output format.")
        }
        let flatten = options.flattenTransparency || options.format == .jpg
        let converted = try flatten && imageContainsAlpha(image)
            ? flattenImage(image, backgroundRGB: options.backgroundRGB) : image

        let directory = output.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(UUID().uuidString + "." + options.format.rawValue)
        defer { try? FileManager.default.removeItem(at: staging) }
        if options.format == .webp, let executable = options.imageMagickExecutable {
            let intermediate = directory.appendingPathComponent(UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: intermediate) }
            try encode(converted, to: intermediate, format: .png, source: source, options: options)
            try await ImageMagickWebPEncoding.encode(intermediate, to: staging, executable: executable,
                                                      quality: options.quality, lossless: options.losslessWebP)
        } else {
            try encode(converted, to: staging, format: options.format, source: source, options: options)
        }
        try Task.checkCancellation()
        guard let written = CGImageSourceCreateWithURL(staging as CFURL, nil),
              CGImageSourceGetType(written) as String? == options.format.type.identifier,
              let outputImage = CGImageSourceCreateImageAtIndex(written, 0, nil),
              outputImage.width == converted.width, outputImage.height == converted.height else {
            throw ToolError.invalid("The encoder did not produce the selected format and dimensions.")
        }
        let outputOrientation = try imageProperties(written)[kCGImagePropertyOrientation] as? Int ?? 1
        guard outputOrientation == 1 else {
            throw ToolError.invalid("The encoder did not preserve the intended display orientation.")
        }
        if !flatten, imageContainsAlpha(image), !imageContainsAlpha(outputImage) {
            throw ToolError.invalid("The encoder did not preserve transparency. Try PNG or enable flattening.")
        }
        try FileManager.default.moveItem(at: staging, to: output)
        let notice = CGImageSourceGetCount(source) > 1 ? " · Primary image only" : ""
        return "\(input.lastPathComponent) · \(options.format.title) · \(outputImage.width) × \(outputImage.height)\(notice)"
    }

    private static func loadSource(_ input: URL) throws -> CGImageSource {
        guard input.isFileURL,
              let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ToolError.invalid("Could not open this image.")
        }
        return source
    }

    private static func imageProperties(_ source: CGImageSource) throws -> [CFString: Any] {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source, CGImageSourceGetPrimaryImageIndex(source), nil
        ) as? [CFString: Any] else {
            throw ToolError.invalid("Could not read image properties.")
        }
        return properties
    }

    private static func validatedDimensions(_ properties: [CFString: Any]) throws -> (Int, Int) {
        guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...16_384).contains(width), (1...16_384).contains(height), width * height <= 64_000_000 else {
            throw ToolError.invalid("Image dimensions exceed 16,384 pixels per edge or 64 megapixels.")
        }
        return (width, height)
    }

    private static func imageContainsAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: true
        default: false
        }
    }

    private static func flattenImage(_ image: CGImage, backgroundRGB: UInt32) throws -> CGImage {
        let colorSpace: CGColorSpace
        if let original = image.colorSpace, original.model == .rgb {
            colorSpace = original
        } else {
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let background = CGColor(
                srgbRed: CGFloat((backgroundRGB >> 16) & 255) / 255,
                green: CGFloat((backgroundRGB >> 8) & 255) / 255,
                blue: CGFloat(backgroundRGB & 255) / 255, alpha: 1
              ).converted(to: colorSpace, intent: .defaultIntent, options: nil) else {
            throw ToolError.invalid("Could not create the background canvas.")
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(background)
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let flattened = context.makeImage() else {
            throw ToolError.invalid("Could not flatten transparency.")
        }
        return flattened
    }

    private static func encode(
        _ image: CGImage, to output: URL, format: ImageConversionFormat,
        source: CGImageSource, options: ImageConversionOptions
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw ToolError.invalid("Could not create a \(format.title) encoder.")
        }
        var properties: [CFString: Any] = [
            kCGImageDestinationOrientation: 1
        ]
        if format == .jpg || format == .heic {
            properties[kCGImageDestinationLossyCompressionQuality] = options.quality
        } else if format == .tiff {
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5]
        }
        if options.preserveMetadata,
           let metadata = CGImageSourceCopyMetadataAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil),
           let adjusted = CGImageMetadataCreateMutableCopy(metadata) {
            CGImageMetadataSetValueMatchingImageProperty(adjusted, kCGImagePropertyTIFFDictionary,
                                                        kCGImagePropertyTIFFOrientation, "1" as CFString)
            CGImageMetadataSetValueMatchingImageProperty(adjusted, kCGImagePropertyExifDictionary,
                                                        kCGImagePropertyExifPixelXDimension, String(image.width) as CFString)
            CGImageMetadataSetValueMatchingImageProperty(adjusted, kCGImagePropertyExifDictionary,
                                                        kCGImagePropertyExifPixelYDimension, String(image.height) as CFString)
            CGImageDestinationAddImageAndMetadata(destination, image, adjusted, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw ToolError.invalid("Could not write the \(format.title) image.")
        }
    }
}
