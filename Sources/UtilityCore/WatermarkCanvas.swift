import CoreGraphics
import CoreText
import Foundation
import ImageIO

struct WatermarkArtwork {
    private enum Content {
        case text(CTLine, CGRect)
        case logo(CGImage)
    }

    private let content: Content
    let size: CGSize

    init(options: WatermarkOptions) throws {
        guard (0.05...0.8).contains(options.scale), (0.01...1).contains(options.opacity),
              (0...0.25).contains(options.margin), (-180...180).contains(options.rotation),
              options.textColor <= 0xFFFFFF else {
            throw ToolError.invalid("Choose valid watermark size, opacity, rotation, and color.")
        }
        switch options.content {
        case .text:
            let text = options.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 180, text.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw ToolError.invalid("Enter one line of watermark text, up to 180 characters.")
            }
            let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, 96, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, 96, nil)
            let rgb = options.textColor
            let color = CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                                green: CGFloat((rgb >> 8) & 255) / 255,
                                blue: CGFloat(rgb & 255) / 255, alpha: 1)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            guard bounds.width > 0, bounds.height > 0 else { throw ToolError.invalid("The watermark text has no visible glyphs.") }
            content = .text(line, bounds)
            size = bounds.size
        case .logo:
            guard let url = options.logo else { throw ToolError.invalid("Choose a logo image.") }
            let source = try ImageConversion.loadSource(url)
            _ = try ImageConversion.validatedDimensions(ImageConversion.imageProperties(source))
            guard CGImageSourceGetCount(source) == 1,
                  let logo = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceShouldCacheImmediately: true,
                      kCGImageSourceThumbnailMaxPixelSize: 2048
                  ] as CFDictionary) else {
                throw ToolError.invalid("Choose a readable, single-frame logo image.")
            }
            content = .logo(logo)
            size = CGSize(width: logo.width, height: logo.height)
        }
    }

    func draw(at center: CGPoint, scale: Double, angle: Double, opacity: Double, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: angle)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -size.width / 2, y: -size.height / 2)
        context.setAlpha(opacity)
        switch content {
        case .text(let line, let bounds):
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: -bounds.minX, y: -bounds.minY)
            CTLineDraw(line, context)
        case .logo(let logo):
            context.interpolationQuality = .high
            context.draw(logo, in: CGRect(origin: .zero, size: size))
        }
    }
}

enum WatermarkCanvas {
    static func bitmap(size: CGSize, colorSpace: CGColorSpace? = nil, depth: Int = 8) throws -> CGContext {
        let colorSpace = colorSpace?.model == .rgb ? colorSpace : CGColorSpace(name: CGColorSpace.sRGB)
        guard size.width.isFinite, size.height.isFinite, (1...16_384).contains(size.width), (1...16_384).contains(size.height),
              size.width * size.height <= 64_000_000,
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: depth, bytesPerRow: 0, space: colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ToolError.invalid("Could not allocate a watermark canvas.")
        }
        return context
    }

    static func composite(_ image: CGImage, mark: WatermarkArtwork?, options: WatermarkOptions, maxEdge: Double? = nil) throws -> CGImage {
        let scale = maxEdge.map { min(1, $0 / Double(max(image.width, image.height))) } ?? 1
        let size = CGSize(width: max(1, (Double(image.width) * scale).rounded()),
                          height: max(1, (Double(image.height) * scale).rounded()))
        let context = try bitmap(size: size, colorSpace: image.colorSpace, depth: maxEdge == nil && image.bitsPerComponent > 8 ? 16 : 8)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        if let mark { try place(mark, on: size, options: options, context: context) }
        guard let result = context.makeImage() else { throw ToolError.invalid("Could not create the watermarked image.") }
        return result
    }

    static func place(_ mark: WatermarkArtwork, on size: CGSize, options: WatermarkOptions, context: CGContext) throws {
        let edge = min(size.width, size.height)
        guard edge.isFinite, edge > 0 else { throw ToolError.invalid("The watermark canvas has no area.") }
        let inset = edge * options.margin
        let area = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        let angle = -options.rotation * .pi / 180
        let rotated = CGRect(origin: .zero, size: mark.size).applying(CGAffineTransform(rotationAngle: angle)).size
        let scale = min(edge * options.scale / max(mark.size.width, mark.size.height),
                        area.width / rotated.width, area.height / rotated.height)
        let width = rotated.width * scale
        let height = rotated.height * scale
        let centers: [CGPoint]
        if options.placement == .tile {
            let gap = max(1, inset, edge * 0.035)
            let columns = min(32, max(1, Int((area.width + gap) / (width + gap))))
            let rows = min(32, max(1, Int((area.height + gap) / (height + gap))))
            centers = (0..<rows).flatMap { row in
                (0..<columns).map { column in
                    CGPoint(x: area.minX + (Double(column) + 0.5) * area.width / Double(columns),
                            y: area.minY + (Double(row) + 0.5) * area.height / Double(rows))
                }
            }
        } else {
            let x: Double
            let y: Double
            switch options.placement {
            case .topLeft, .left, .bottomLeft: x = area.minX + width / 2
            case .topRight, .right, .bottomRight: x = area.maxX - width / 2
            default: x = area.midX
            }
            switch options.placement {
            case .topLeft, .top, .topRight: y = area.maxY - height / 2
            case .bottomLeft, .bottom, .bottomRight: y = area.minY + height / 2
            default: y = area.midY
            }
            centers = [CGPoint(x: x, y: y)]
        }
        for center in centers {
            try Task.checkCancellation()
            mark.draw(at: center, scale: scale, angle: angle, opacity: options.opacity, context: context)
        }
    }
}
