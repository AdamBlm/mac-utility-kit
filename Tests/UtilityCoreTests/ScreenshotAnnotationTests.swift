import CoreGraphics
import Foundation
import ImageIO
import Testing
import UtilityCore

@Suite struct ScreenshotAnnotationTests {
    @Test func movesReordersAndRestoresLayersWithoutLosingStyle() {
        var history = ScreenshotAnnotationHistory()
        let line = ScreenshotAnnotation(kind: .line, start: CGPoint(x: 0.2, y: 0.2), end: CGPoint(x: 0.4, y: 0.4))
        let label = ScreenshotAnnotation(kind: .text, start: CGPoint(x: 0.4, y: 0.5),
                                         end: CGPoint(x: 0.4, y: 0.5), text: "A label")
        history.add(line)
        history.add(label)
        history.move(line.id, by: 1)
        #expect(history.layers.map(\.id) == [label.id, line.id])
        let moved = line.moved(by: CGPoint(x: -1, y: 0.25))
        history.replace(moved)
        #expect(history.layers.last?.start == CGPoint(x: 0, y: 0.45))
        #expect(history.layers.last?.end == CGPoint(x: 0.2, y: 0.65))
        history.undo()
        #expect(history.layers.last == line)
        history.undo()
        #expect(history.layers == [line, label])
        history.redo()
        #expect(history.layers == [label, line])
        history.remove(label.id)
        #expect(history.layers == [line])
        #expect(!history.canRedo)
    }

    @Test func flattensOrderedLayersInSourcePixelCoordinates() async throws {
        let source = try whiteImage()
        let start = CGPoint(x: 0.1, y: 0.2)
        let end = CGPoint(x: 0.8, y: 0.2)
        let lower = ScreenshotAnnotation(kind: .line, start: start, end: end, color: 0xFF0000, stroke: 13)
        let upper = ScreenshotAnnotation(kind: .line, start: start, end: end, color: 0x0000FF, stroke: 7)
        let image = try await ScreenshotAnnotationRenderer.flatten(source, layers: [lower, upper])
        #expect(image.width == 400 && image.height == 300)
        let center = try pixel(image, x: 180, y: 60)
        #expect(center[2] > 225 && center[0] < 20)
        let lowerEdge = try pixel(image, x: 180, y: 65)
        #expect(lowerEdge[0] > 225 && lowerEdge[2] < 20)
        let original = try pixel(source, x: 180, y: 60)
        #expect(original[0] == 255 && original[1] == 255 && original[2] == 255)

        for format in ScreenshotOutputFormat.allCases {
            let encoded = try ScreenshotImageOutput.encode(image, format: format)
            let decoder = try #require(CGImageSourceCreateWithData(encoded as CFData, nil))
            let decoded = try #require(CGImageSourceCreateImageAtIndex(decoder, 0, nil))
            #expect(decoded.width == 400 && decoded.height == 300)
        }
    }

    @Test func rendersTextCalloutAndShowsMatchingHitAreas() async throws {
        let source = try whiteImage()
        let textPoint = CGPoint(x: 0.12, y: 0.12)
        let numberPoint = CGPoint(x: 0.75, y: 0.7)
        let text = ScreenshotAnnotation(kind: .text, start: textPoint, end: textPoint,
                                        color: 0x000000, fontSize: 32, text: "Visible callout")
        let number = ScreenshotAnnotation(kind: .number, start: numberPoint, end: numberPoint,
                                          color: 0x0020D0, fontSize: 38, number: 12)
        let image = try await ScreenshotAnnotationRenderer.flatten(source, layers: [text, number])
        let size = CGSize(width: image.width, height: image.height)
        let textBounds = ScreenshotAnnotationRenderer.bounds(for: text, size: size, displayScale: 1)
        var hasDarkPixel = false
        for y in Int(textBounds.minY)..<Int(textBounds.maxY) where !hasDarkPixel {
            for x in stride(from: Int(textBounds.minX), to: Int(textBounds.maxX), by: 2) {
                if try pixel(image, x: x, y: y)[0] < 50 {
                    hasDarkPixel = true
                    break
                }
            }
        }
        #expect(hasDarkPixel)
        let center = CGPoint(x: numberPoint.x * size.width, y: numberPoint.y * size.height)
        let badge = try pixel(image, x: Int(center.x) - 20, y: Int(center.y))
        #expect(badge[2] > 100 && badge[0] < 40)
        #expect(ScreenshotAnnotationRenderer.hits(number, point: center, size: size, displayScale: 1))
        #expect(!ScreenshotAnnotationRenderer.hits(number, point: .zero, size: size, displayScale: 1))
    }

    private func whiteImage() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        return try #require(context.makeImage())
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let crop = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}
