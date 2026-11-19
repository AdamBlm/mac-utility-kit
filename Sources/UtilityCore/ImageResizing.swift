import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageResizing {
    static func resize(_ input: URL, output: URL, imageSize: Int, options: ToolOptions) async throws {
        let (source, width, height) = try orientedSource(input)
        let size = try imageDimensions(width: width, height: height, longestEdge: imageSize, options: options)
        if let executable = options.imageMagickExecutable {
            try await ImageMagickResizing.resize(
                input, source: source, output: output, size: size,
                format: options.imageFormat, quality: options.imageQuality,
                fill: options.imageSizing == .dimensions && options.imageFit == .fill,
                executable: executable
            )
            return
        }
        let scale = options.imageSizing == .dimensions && options.imageFit == .fill
            ? max(Double(size.width) / Double(width), Double(size.height) / Double(height))
            : 0
        let decodeLimit = max(size.width, size.height, Int(min(16_384, ceil(Double(max(width, height)) * scale))))
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: decodeLimit
        ] as CFDictionary),
              let writer = CGImageDestinationCreateWithURL(output as CFURL, options.imageFormat.type.identifier as CFString, 1, nil)
        else { throw ToolError.invalid("Could not prepare the selected image output.") }

        let fallback = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let sourceRGB = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        func canvas(in colorSpace: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                      bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let context = sourceRGB.flatMap({ canvas(in: $0) }) ?? canvas(in: fallback) else {
            throw ToolError.invalid("Could not prepare the selected image output.")
        }

        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        if options.imageFormat == .jpg {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
        }
        var drawing = bounds
        if options.imageSizing == .dimensions, options.imageFit == .fill {
            let factor = max(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
            let drawWidth = CGFloat(image.width) * factor
            let drawHeight = CGFloat(image.height) * factor
            drawing = CGRect(x: (bounds.width - drawWidth) / 2, y: (bounds.height - drawHeight) / 2,
                             width: drawWidth, height: drawHeight)
        }
        context.interpolationQuality = .high
        context.draw(image, in: drawing)
        guard let resized = context.makeImage() else { throw ToolError.invalid("Could not resize the image.") }
        CGImageDestinationAddImage(writer, resized, [
            kCGImageDestinationLossyCompressionQuality: options.imageQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else {
            throw ToolError.invalid("Could not write the selected image format.")
        }
    }

    static func preview(_ input: URL, longestEdge: Int, options: ToolOptions) throws -> String {
        let (_, width, height) = try orientedSource(input)
        let size = try imageDimensions(width: width, height: height, longestEdge: longestEdge, options: options)
        return "\(size.width) × \(size.height)"
    }

    private static func orientedSource(_ input: URL) throws -> (CGImageSource, Int, Int) {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { throw ToolError.invalid("Could not read the image dimensions.") }
        let rotated = (5...8).contains(props[kCGImagePropertyOrientation] as? Int ?? 1)
        return (source, rotated ? height : width, rotated ? width : height)
    }

    private static func imageDimensions(width: Int, height: Int, longestEdge: Int, options: ToolOptions)
        throws -> (width: Int, height: Int) {
        let limit = 16_384
        guard width > 0, height > 0 else { throw ToolError.invalid("Invalid image dimensions.") }
        let factor: Double
        switch options.imageSizing {
        case .longestEdge:
            guard (1...limit).contains(longestEdge) else { throw ToolError.invalid("Enter an edge from 1 to 16,384 pixels.") }
            factor = Double(longestEdge) / Double(max(width, height))
        case .percentage:
            guard (1...1000).contains(options.imagePercentage) else { throw ToolError.invalid("Enter a percentage from 1 to 1,000.") }
            factor = Double(options.imagePercentage) / 100
        case .dimensions:
            guard (1...limit).contains(options.imageWidth), (1...limit).contains(options.imageHeight)
            else { throw ToolError.invalid("Enter dimensions from 1 to 16,384 pixels.") }
            let x = Double(options.imageWidth) / Double(width)
            let y = Double(options.imageHeight) / Double(height)
            if options.imageFit != .fit {
                let required = max(x, y)
                guard options.upscale || required <= 1 else {
                    throw ToolError.invalid("Enable upscaling or choose smaller dimensions.")
                }
                return try boundedSize(Double(options.imageWidth), Double(options.imageHeight))
            }
            factor = min(x, y)
        }
        let scale = options.upscale ? factor : min(factor, 1)
        return try boundedSize(Double(width) * scale, Double(height) * scale)
    }

    private static func boundedSize(_ scaledWidth: Double, _ scaledHeight: Double) throws -> (width: Int, height: Int) {
        let width = max(1, scaledWidth.rounded())
        let height = max(1, scaledHeight.rounded())
        guard width <= 16_384, height <= 16_384, width * height <= 64_000_000
        else { throw ToolError.invalid("Output exceeds 16,384 pixels per edge or 64 megapixels.") }
        return (Int(width), Int(height))
    }
}
