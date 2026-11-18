import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ScreenshotAnnotationRenderer {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    public static func load(_ url: URL) async throws -> CGImage {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1, let type = CGImageSourceGetType(source),
              UTType(type as String)?.conforms(to: .image) == true else {
            throw ToolError.invalid("Choose a local single-frame image.")
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              validImageSize(width: width, height: height),
              let image = CGImageSourceCreateThumbnailAtIndex(source, index, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(width, height)
              ] as CFDictionary) else {
            throw ToolError.invalid("The image could not be read within the supported dimensions.")
        }
        return image
    }

    public static func flatten(_ source: CGImage, layers: [ScreenshotAnnotation]) async throws -> CGImage {
        try Task.checkCancellation()
        guard validImageSize(width: source.width, height: source.height),
              let context = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ToolError.invalid("Could not create the annotation canvas.")
        }
        let size = CGSize(width: source.width, height: source.height)
        context.draw(source, in: CGRect(origin: .zero, size: size))
        draw(layers, in: context, size: size, displayScale: 1)
        try Task.checkCancellation()
        guard let result = context.makeImage() else { throw ToolError.invalid("Could not flatten the annotations.") }
        return result
    }

    /// Draws onto a bottom-left coordinate system. The displayScale converts source pixels to view points.
    public static func draw(
        _ layers: [ScreenshotAnnotation], in context: CGContext, size: CGSize, displayScale: Double
    ) {
        for layer in layers where valid(layer) {
            context.saveGState()
            let color = makeColor(layer.color)
            context.setFillColor(color)
            context.setStrokeColor(color)
            context.setLineWidth(max(0.5 * displayScale, layer.stroke * displayScale))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            let start = bottomLeft(layer.start, size: size)
            let end = bottomLeft(layer.end, size: size)
            switch layer.kind {
            case .arrow:
                drawArrow(from: start, to: end, stroke: layer.stroke * displayScale,
                          minimumHead: 8 * displayScale, context: context)
            case .line:
                context.move(to: start)
                context.addLine(to: end)
                context.strokePath()
            case .box:
                context.stroke(rect(between: start, and: end))
            case .oval:
                context.strokeEllipse(in: rect(between: start, and: end))
            case .text:
                drawText(layer, in: context, size: size, scale: displayScale)
            case .number:
                drawNumber(layer, in: context, size: size, scale: displayScale)
            }
            context.restoreGState()
        }
    }

    public static func bounds(
        for layer: ScreenshotAnnotation, size: CGSize, displayScale: Double
    ) -> CGRect {
        guard valid(layer) else { return .zero }
        if layer.kind == .text {
            let rectangle = textLayout(layer, size: size, scale: displayScale).rect
            return CGRect(x: rectangle.minX, y: size.height - rectangle.maxY,
                          width: rectangle.width, height: rectangle.height)
        }
        if layer.kind == .number {
            let rectangle = numberRect(layer, size: size, scale: displayScale)
            return CGRect(x: rectangle.minX, y: size.height - rectangle.maxY,
                          width: rectangle.width, height: rectangle.height)
        }
        let start = CGPoint(x: layer.start.x * size.width, y: layer.start.y * size.height)
        let end = CGPoint(x: layer.end.x * size.width, y: layer.end.y * size.height)
        let stroke = layer.stroke * displayScale * 0.5
        let arrowHead = layer.kind == .arrow ? stroke * 2.25 : stroke
        return rect(between: start, and: end).insetBy(dx: -arrowHead, dy: -arrowHead)
    }

    public static func hits(_ layer: ScreenshotAnnotation, point: CGPoint, size: CGSize, displayScale: Double) -> Bool {
        if layer.kind == .line || layer.kind == .arrow {
            let start = CGPoint(x: layer.start.x * size.width, y: layer.start.y * size.height)
            let end = CGPoint(x: layer.end.x * size.width, y: layer.end.y * size.height)
            let dx = end.x - start.x
            let dy = end.y - start.y
            let squared = dx * dx + dy * dy
            let projected = squared > 0 ? min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / squared)) : 0
            return hypot(point.x - (start.x + projected * dx), point.y - (start.y + projected * dy)) <=
                max(8, layer.stroke * displayScale * 0.6)
        }
        return bounds(for: layer, size: size, displayScale: displayScale).insetBy(dx: -5, dy: -5).contains(point)
    }

    private static func drawArrow(
        from start: CGPoint, to end: CGPoint, stroke: Double, minimumHead: Double, context: CGContext
    ) {
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 0 else { return }
        let head = min(length * 0.55, max(minimumHead, stroke * 3.2))
        let x = (end.x - start.x) / length
        let y = (end.y - start.y) / length
        let base = CGPoint(x: end.x - head * x, y: end.y - head * y)
        let half = head * 0.43
        context.move(to: start)
        context.addLine(to: CGPoint(x: base.x + stroke * 0.25 * x, y: base.y + stroke * 0.25 * y))
        context.strokePath()
        context.move(to: end)
        context.addLine(to: CGPoint(x: base.x + half * y, y: base.y - half * x))
        context.addLine(to: CGPoint(x: base.x - half * y, y: base.y + half * x))
        context.closePath()
        context.fillPath()
    }

    private static func drawText(_ layer: ScreenshotAnnotation, in context: CGContext, size: CGSize, scale: Double) {
        let layout = textLayout(layer, size: size, scale: scale)
        context.textMatrix = .identity
        let frame = CTFramesetterCreateFrame(layout.framesetter, CFRange(), CGPath(rect: layout.rect, transform: nil), nil)
        CTFrameDraw(frame, context)
    }

    private static func textLayout(
        _ layer: ScreenshotAnnotation, size: CGSize, scale: Double
    ) -> (framesetter: CTFramesetter, rect: CGRect) {
        let point = bottomLeft(layer.start, size: size)
        let fontSize = max(1.0, layer.fontSize * scale)
        let text = String(layer.text.prefix(2048)).trimmingCharacters(in: .whitespacesAndNewlines)
        let rich = attributed(text, color: makeColor(layer.color), fontSize: fontSize, bold: false)
        let framesetter = CTFramesetterCreateWithAttributedString(rich)
        let available = max(1, min(size.width, max(fontSize * 7, size.width - point.x)))
        let ideal = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(), nil, CGSize(width: available, height: CGFloat.greatestFiniteMagnitude), nil
        )
        let width = min(size.width, max(fontSize, ceil(ideal.width) + fontSize * 0.08))
        let height = min(size.height, max(fontSize * 1.25, ceil(ideal.height) + fontSize * 0.2))
        return (framesetter, CGRect(x: max(0, min(point.x, size.width - width)), y: max(0, point.y - height),
                                     width: width, height: height))
    }

    private static func drawNumber(_ layer: ScreenshotAnnotation, in context: CGContext, size: CGSize, scale: Double) {
        let bounds = numberRect(layer, size: size, scale: scale)
        context.fillEllipse(in: bounds)
        let rgb = layer.color
        let brightness = Double((rgb >> 16) & 255) * 0.299 +
            Double((rgb >> 8) & 255) * 0.587 + Double(rgb & 255) * 0.114
        let foreground = brightness > 145 ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)
        let label = String(layer.number)
        let text = attributed(label, color: foreground, fontSize: bounds.width * (label.count > 2 ? 0.42 : 0.54), bold: true)
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: bounds.midX - width / 2, y: bounds.midY - (ascent - descent) / 2)
        CTLineDraw(line, context)
    }

    private static func numberRect(_ layer: ScreenshotAnnotation, size: CGSize, scale: Double) -> CGRect {
        let diameter = min(size.width, size.height, layer.fontSize * 1.55 * scale)
        let point = bottomLeft(layer.start, size: size)
        return CGRect(x: max(0, min(point.x - diameter / 2, size.width - diameter)),
                      y: max(0, min(point.y - diameter / 2, size.height - diameter)), width: diameter, height: diameter)
    }

    private static func attributed(_ text: String, color: CGColor, fontSize: Double, bold: Bool) -> CFAttributedString {
        let name = bold ? "HelveticaNeue-Bold" : "HelveticaNeue-Medium"
        let font = CTFontCreateWithName(name as CFString, fontSize, nil)
        return NSAttributedString(string: text, attributes: [
            .init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): color
        ])
    }

    private static func bottomLeft(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
    }

    private static func rect(between a: CGPoint, and b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private static func makeColor(_ color: UInt32) -> CGColor {
        CGColor(srgbRed: Double((color >> 16) & 255) / 255, green: Double((color >> 8) & 255) / 255,
                blue: Double(color & 255) / 255, alpha: 1)
    }

    private static func valid(_ layer: ScreenshotAnnotation) -> Bool {
        [layer.start.x, layer.start.y, layer.end.x, layer.end.y].allSatisfy { (0...1).contains($0) } &&
            (1...256).contains(layer.fontSize) && (0.5...128).contains(layer.stroke) &&
            layer.color <= 0xFFFFFF && (1...999).contains(layer.number)
    }

    private static func validImageSize(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= 16_000 && height <= 24_000 && width * height <= 64_000_000
    }
}
