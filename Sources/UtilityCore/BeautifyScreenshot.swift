import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ScreenshotBackground: String, CaseIterable, Identifiable, Sendable {
    case solid = "Solid"
    case gradient = "Gradient"
    case transparent = "Transparent"

    public var id: Self { self }
}

public enum ScreenshotAspect: String, CaseIterable, Identifiable, Sendable {
    case source = "Source aspect"
    case landscape = "16:9"
    case classic = "4:3"
    case square = "1:1"
    case portrait = "4:5"
    case vertical = "9:16"

    public var id: Self { self }

    var ratio: Double? {
        switch self {
        case .source: nil
        case .landscape: 16.0 / 9
        case .classic: 4.0 / 3
        case .square: 1
        case .portrait: 4.0 / 5
        case .vertical: 9.0 / 16
        }
    }
}

public enum ScreenshotOutputFormat: String, CaseIterable, Identifiable, Sendable {
    case png = "PNG"
    case jpeg = "JPEG"

    public var id: Self { self }
    public var fileExtension: String { self == .png ? "png" : "jpg" }
    var contentType: UTType { self == .png ? .png : .jpeg }
}

public struct BeautifyScreenshotOptions: Equatable, Sendable {
    public var background = ScreenshotBackground.gradient
    public var firstColor: UInt32 = 0x34486F
    public var secondColor: UInt32 = 0x82678C
    public var gradientAngle = 35.0
    public var padding = 84
    public var radius = 24
    public var shadowOpacity = 0.36
    public var shadowBlur = 26
    public var aspect = ScreenshotAspect.source
    public var longestEdge = 1600
    public var format = ScreenshotOutputFormat.png
    public var jpegQuality = 0.88

    public init() {}
}

public struct ScreenshotLayout: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let fittedContent: CGRect
}

public enum BeautifyScreenshot {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    public static func layout(sourceSize: CGSize, options: BeautifyScreenshotOptions) throws -> ScreenshotLayout {
        guard sourceSize.width.isFinite, sourceSize.height.isFinite, sourceSize.width >= 1, sourceSize.height >= 1,
              (160...4096).contains(options.longestEdge), (0...1024).contains(options.padding),
              (0...512).contains(options.radius), (0...1).contains(options.shadowOpacity),
              options.shadowOpacity == 0 || (0...128).contains(options.shadowBlur),
              options.format != .jpeg || (0...1).contains(options.jpegQuality),
              (0...360).contains(options.gradientAngle), options.firstColor <= 0xFFFFFF, options.secondColor <= 0xFFFFFF else {
            throw ToolError.invalid("Choose a canvas edge from 160 to 4,096 pixels and valid framing settings.")
        }
        guard options.background != .transparent || options.format == .png else {
            throw ToolError.invalid("Choose PNG for a transparent background.")
        }
        let ratio = options.aspect.ratio ?? sourceSize.width / sourceSize.height
        let longestEdge = Double(options.longestEdge)
        let width = ratio >= 1 ? options.longestEdge : max(1, Int((longestEdge * ratio).rounded()))
        let height = ratio <= 1 ? options.longestEdge : max(1, Int((longestEdge / ratio).rounded()))
        let availableWidth = width - options.padding * 2
        let availableHeight = height - options.padding * 2
        guard availableWidth > 0, availableHeight > 0 else {
            throw ToolError.invalid("Reduce padding or choose a larger canvas.")
        }
        let scale = min(CGFloat(availableWidth) / sourceSize.width, CGFloat(availableHeight) / sourceSize.height)
        let content = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return ScreenshotLayout(width: width, height: height, fittedContent: CGRect(
            x: (CGFloat(width) - content.width) * 0.5, y: (CGFloat(height) - content.height) * 0.5,
            width: content.width, height: content.height
        ))
    }

    public static func preview(_ input: URL, options: BeautifyScreenshotOptions) async throws -> CGImage {
        let image = try render(input, options: options)
        if options.format != .jpeg { return image }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                        UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ToolError.invalid("Could not prepare the JPEG preview.")
        }
        try encode(image, with: destination, options: options)
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let preview = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ToolError.invalid("Could not read the JPEG preview.")
        }
        return preview
    }

    public static func export(
        _ input: URL, to output: URL, options: BeautifyScreenshotOptions,
        progress: @Sendable (Double) async -> Void
    ) async throws -> String {
        let manager = FileManager.default
        guard input.isFileURL, output.isFileURL, input.standardizedFileURL != output.standardizedFileURL,
              !manager.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a new local image file.")
        }
        let image = try render(input, options: options)
        await progress(0.55)
        let staging = output.deletingLastPathComponent().appending(path: ".beautify-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let candidate = staging.appendingPathComponent("Composition.\(options.format.fileExtension)")
        guard let destination = CGImageDestinationCreateWithURL(candidate as CFURL,
                  options.format.contentType.identifier as CFString, 1, nil) else {
            throw ToolError.invalid("Could not open the selected image writer.")
        }
        try encode(image, with: destination, options: options)
        guard let verified = CGImageSourceCreateWithURL(candidate as CFURL, nil),
              CGImageSourceGetType(verified) as String? == options.format.contentType.identifier,
              CGImageSourceGetStatusAtIndex(verified, 0) == .statusComplete else {
            throw ToolError.invalid("Could not verify the composed image.")
        }
        try Task.checkCancellation()
        try manager.moveItem(at: candidate, to: output)
        await progress(1)
        return "\(input.lastPathComponent) · \(image.width) × \(image.height) · \(options.format.rawValue)"
    }

    private static func encode(
        _ image: CGImage, with destination: CGImageDestination, options: BeautifyScreenshotOptions
    ) throws {
        let properties: CFDictionary? = options.format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: options.jpegQuality] as CFDictionary
            : nil
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw ToolError.invalid("Could not encode the composed image.")
        }
    }

    private static func render(_ input: URL, options: BeautifyScreenshotOptions) throws -> CGImage {
        try Task.checkCancellation()
        guard (160...4096).contains(options.longestEdge), input.isFileURL,
              try input.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true else {
            throw ToolError.invalid("Could not open the screenshot or prepare the selected resolution.")
        }
        guard CGImageSourceGetCount(source) == 1 else {
            throw ToolError.invalid("Choose a single-frame image. Animated and multipage images cannot be composed.")
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ToolError.invalid("Could not read the screenshot dimensions.")
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let orientedSize = (5...8).contains(orientation)
            ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        let layout = try layout(sourceSize: orientedSize, options: options)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: options.longestEdge
        ] as CFDictionary) else {
            throw ToolError.invalid("Could not decode the screenshot.")
        }
        let bounds = CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
        guard let context = CGContext(data: nil, width: layout.width, height: layout.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ToolError.invalid("Could not create the screenshot canvas.")
        }
        try drawBackground(context, bounds: bounds, options: options)
        let rect = layout.fittedContent
        let radius = min(CGFloat(options.radius), min(rect.width, rect.height) * 0.5)
        let outline = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        if options.shadowOpacity > 0 {
            context.setShadow(offset: CGSize(width: 0, height: -CGFloat(options.shadowBlur) * 0.45),
                              blur: CGFloat(options.shadowBlur), color: CGColor(gray: 0, alpha: options.shadowOpacity))
        }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.addPath(outline)
        context.clip()
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        context.endTransparencyLayer()
        context.restoreGState()
        try Task.checkCancellation()
        guard let result = context.makeImage() else { throw ToolError.invalid("Could not compose the screenshot.") }
        return result
    }

    private static func drawBackground(_ context: CGContext, bounds: CGRect, options: BeautifyScreenshotOptions) throws {
        switch options.background {
        case .transparent:
            context.clear(bounds)
        case .solid:
            context.setFillColor(color(options.firstColor))
            context.fill(bounds)
        case .gradient:
            guard let gradient = CGGradient(colorsSpace: colorSpace,
                        colors: [color(options.firstColor), color(options.secondColor)] as CFArray, locations: [0, 1]) else {
                throw ToolError.invalid("Could not create the screenshot gradient.")
            }
            let angle = options.gradientAngle * .pi / 180
            let x = cos(angle), y = sin(angle)
            let reach = abs(x) * bounds.midX + abs(y) * bounds.midY
            let start = CGPoint(x: bounds.midX - x * reach, y: bounds.midY - y * reach)
            let end = CGPoint(x: bounds.midX + x * reach, y: bounds.midY + y * reach)
            context.drawLinearGradient(gradient, start: start, end: end,
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    private static func color(_ rgb: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}
