import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImageRotateOptions: Equatable, Sendable {
    public enum Turn: String, CaseIterable, Identifiable, Sendable {
        case none = "None"
        case clockwise = "90° right"
        case half = "180°"
        case counterclockwise = "90° left"
        public var id: Self { self }

        var orientation: CGImagePropertyOrientation {
            switch self {
            case .none: .up
            case .clockwise: .right
            case .half: .down
            case .counterclockwise: .left
            }
        }

        public var swapsAxes: Bool { self == .clockwise || self == .counterclockwise }
    }

    public enum Output: String, CaseIterable, Identifiable, Sendable {
        case original = "Same as input"
        case png = "PNG"
        public var id: Self { self }
    }

    public var turn = Turn.none
    public var flipHorizontally = false
    public var flipVertically = false
    public var output = Output.original
    public var preserveMetadata = true
    public var quality = 0.95

    public init() {}
}

public enum ImageRotate {
    public struct Preview: Sendable {
        public let before: CGImage
        public let after: CGImage
        public let sourceWidth: Int
        public let sourceHeight: Int

        public let outputWidth: Int
        public let outputHeight: Int
        public let format: ImageConversionFormat
    }

    public static func outputExtension(_ input: URL, options: ImageRotateOptions) throws -> String {
        try outputFormat(input, options: options).rawValue
    }

    package static func outputFormat(_ input: URL, options: ImageRotateOptions) throws -> ImageConversionFormat {
        let source = try ImageConversion.loadSource(input)
        try validateStill(source)
        return try encodingOptions(for: source, options: options).format
    }

    public static func preview(_ input: URL, options: ImageRotateOptions) throws -> Preview {
        let source = try ImageConversion.loadSource(input)
        try validateStill(source)
        let outputFormat = try encodingOptions(for: source, options: options).format
        let properties = try ImageConversion.imageProperties(source)
        let (width, height) = try ImageConversion.validatedDimensions(properties)
        let orientation = sourceOrientation(properties)
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let before = CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 720
        ] as CFDictionary) else {
            throw ToolError.invalid("Could not load the image preview.")
        }
        let after = try render(before, orientations: edits(options))
        let swapsAxes = orientation.rawValue >= 5
        let displayedWidth = swapsAxes ? height : width
        let displayedHeight = swapsAxes ? width : height
        return Preview(before: before, after: after, sourceWidth: displayedWidth, sourceHeight: displayedHeight,
                       outputWidth: options.turn.swapsAxes ? displayedHeight : displayedWidth,
                       outputHeight: options.turn.swapsAxes ? displayedWidth : displayedHeight,
                       format: outputFormat)
    }

    public static func export(_ input: URL, to output: URL, options: ImageRotateOptions) throws -> String {
        guard output.isFileURL, output.standardizedFileURL != input.standardizedFileURL,
              !FileManager.default.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a new local output file.")
        }
        try Task.checkCancellation()
        let source = try ImageConversion.loadSource(input)
        try validateStill(source)
        let properties = try ImageConversion.imageProperties(source)
        _ = try ImageConversion.validatedDimensions(properties)
        let encoding = try encodingOptions(for: source, options: options)
        let outputFormat = encoding.format
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let image = CGImageSourceCreateImageAtIndex(source, index, [
            kCGImageSourceShouldAllowFloat: true
        ] as CFDictionary) else {
            throw ToolError.invalid("Could not decode the source image.")
        }
        let orientation = sourceOrientation(properties)
        let rendered = try render(image, orientations: [orientation] + edits(options))

        let manager = FileManager.default
        let staging = output.deletingLastPathComponent().appending(path: ".rotate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let candidate = staging.appending(path: "Rotated." + outputFormat.rawValue)
        try ImageConversion.encode(rendered, to: candidate, format: outputFormat, source: source, options: encoding)
        try Task.checkCancellation()
        guard let written = CGImageSourceCreateWithURL(candidate as CFURL, nil),
              CGImageSourceGetType(written) as String? == outputFormat.type.identifier else {
            throw ToolError.invalid("The encoder did not produce the selected image format.")
        }
        let verified = try ImageConversion.imageProperties(written)
        let (width, height) = try ImageConversion.validatedDimensions(verified)
        guard width == rendered.width, height == rendered.height, sourceOrientation(verified) == .up else {
            throw ToolError.invalid("The encoded pixels or orientation do not match the rotated image.")
        }
        if outputFormat == .png || outputFormat == .tiff || ImageConversion.imageContainsAlpha(image) {
            guard let decoded = CGImageSourceCreateImageAtIndex(written, CGImageSourceGetPrimaryImageIndex(written), nil),
                  !ImageConversion.imageContainsAlpha(image) || ImageConversion.imageContainsAlpha(decoded),
                  !(outputFormat == .png || outputFormat == .tiff) || decoded.bitsPerComponent >= image.bitsPerComponent else {
                throw ToolError.invalid("The output did not retain source transparency or precision.")
            }
        }
        try Task.checkCancellation()
        try manager.moveItem(at: candidate, to: output)
        return "\(input.lastPathComponent) · \(width) × \(height) · \(outputFormat.title)"
    }

    private static func validateStill(_ source: CGImageSource) throws {
        guard CGImageSourceGetCount(source) == 1 else {
            throw ToolError.invalid("Rotate Images accepts still images with a single frame or page.")
        }
    }

    private static func encodingOptions(
        for source: CGImageSource, options: ImageRotateOptions
    ) throws -> ImageConversionOptions {
        var encoding = ImageConversionOptions()
        encoding.format = try format(source, options: options)
        encoding.preserveMetadata = options.preserveMetadata
        encoding.quality = options.quality
        if let issue = ImageConversion.optionIssue(encoding) { throw ToolError.invalid(issue) }
        return encoding
    }

    private static func format(_ source: CGImageSource, options: ImageRotateOptions) throws -> ImageConversionFormat {
        if options.output == .png { return .png }
        let type = CGImageSourceGetType(source) as String?
        guard let format = [ImageConversionFormat.jpg, .png, .heic, .tiff].first(where: { $0.type.identifier == type }) else {
            throw ToolError.invalid("Preserving the format is available for JPEG, PNG, HEIC, and TIFF. Choose PNG for this image.")
        }
        return format
    }

    private static func sourceOrientation(_ properties: [CFString: Any]) -> CGImagePropertyOrientation {
        guard let value = properties[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: value) else { return .up }
        return orientation
    }

    private static func edits(_ options: ImageRotateOptions) -> [CGImagePropertyOrientation] {
        var edits = [options.turn.orientation]
        if options.flipHorizontally { edits.append(.upMirrored) }
        if options.flipVertically { edits.append(.downMirrored) }
        return edits
    }

    private static func render(_ image: CGImage, orientations: [CGImagePropertyOrientation]) throws -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var orientedImage = CIImage(cgImage: image)
        var transform = CGAffineTransform.identity
        for orientation in orientations where orientation != .up {
            let step = orientedImage.orientationTransform(for: orientation)
            orientedImage = orientedImage.transformed(by: step)
            transform = transform.concatenating(step)
        }
        if transform.isIdentity { return image }
        guard !image.bitmapInfo.contains(.floatComponents), image.bitsPerComponent <= 16 else {
            throw ToolError.invalid("This floating-point or high-precision image cannot be rotated by the current renderer.")
        }
        let rectangle = bounds.applying(transform).integral
        let alpha = ImageConversion.imageContainsAlpha(image)
        let colorSpace: CGColorSpace
        if let original = image.colorSpace, original.model == .rgb || (original.model == .monochrome && !alpha) {
            colorSpace = original
        } else {
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
        let flags: CGImageAlphaInfo = if colorSpace.model == .monochrome {
            .none
        } else {
            alpha ? .premultipliedLast : .noneSkipLast
        }
        let depth = image.bitsPerComponent > 8 ? 16 : 8
        guard let context = CGContext(data: nil, width: Int(rectangle.width), height: Int(rectangle.height),
                                      bitsPerComponent: depth, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: flags.rawValue) else {
            throw ToolError.invalid("Could not allocate the rotated image.")
        }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.translateBy(x: -rectangle.minX, y: -rectangle.minY)
        context.concatenate(transform)
        context.draw(image, in: bounds)
        guard let result = context.makeImage() else { throw ToolError.invalid("Could not render the rotated image.") }
        return result
    }
}
