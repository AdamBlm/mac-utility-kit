import CoreGraphics
import Foundation

public struct ScrollingScreenshot: Sendable {
    public let image: CGImage
    public let seamRows: [Int]
    private let previousFrame: CGImage

    public init(_ frame: CGImage) throws {
        try Self.validateCanvas(width: frame.width, height: frame.height)
        guard frame.height >= 64 else { throw ToolError.invalid("Choose a taller scrolling area.") }
        self.image = frame
        self.seamRows = []
        self.previousFrame = frame
    }

    private init(image: CGImage, seamRows: [Int], previousFrame: CGImage) {
        self.image = image
        self.seamRows = seamRows
        self.previousFrame = previousFrame
    }

    public static func trim(_ frame: CGImage, top: Int, bottom: Int) throws -> CGImage {
        guard top >= 0, bottom >= 0, top <= frame.height, bottom <= frame.height - top,
              frame.height - top - bottom >= 64,
              let cropped = frame.cropping(to: CGRect(x: 0, y: top, width: frame.width, height: frame.height - top - bottom)) else {
            throw ToolError.invalid("Leave at least 64 pixels after removing the fixed top and bottom margins.")
        }
        return cropped
    }

    public func adding(_ frame: CGImage) throws -> ScrollingScreenshot {
        try Task.checkCancellation()
        guard frame.width == previousFrame.width, frame.height == previousFrame.height else {
            throw ToolError.invalid("The window size changed. Restore its previous size or finish this capture.")
        }
        guard seamRows.count < 15 else {
            throw ToolError.invalid("This scrolling capture already has 16 frames. Finish and start another capture.")
        }
        let overlap = try Self.match(previousFrame, frame)
        let added = frame.height - overlap
        let height = image.height + added
        try Self.validateCanvas(width: image.width, height: height)
        guard let tail = frame.cropping(to: CGRect(x: 0, y: overlap, width: frame.width, height: added)),
              let context = Self.context(width: image.width, height: height) else {
            throw ToolError.invalid("Could not assemble the scrolling screenshot.")
        }
        context.draw(image, in: CGRect(x: 0, y: added, width: image.width, height: image.height))
        context.draw(tail, in: CGRect(x: 0, y: 0, width: frame.width, height: added))
        guard let stitched = context.makeImage() else {
            throw ToolError.invalid("Could not assemble the scrolling screenshot.")
        }
        return ScrollingScreenshot(image: stitched, seamRows: seamRows + [image.height], previousFrame: frame)
    }

    private static func match(_ previous: CGImage, _ next: CGImage) throws -> Int {
        let sampleWidth = min(48, previous.width)
        let height = previous.height
        let a = try sampledRows(previous, width: sampleWidth)
        let b = try sampledRows(next, width: sampleWidth)
        let channelsPerRow = sampleWidth * 4
        let minimum = max(24, height / 7)
        let maximum = height - 8
        guard minimum <= maximum else { throw ToolError.invalid("Choose a taller scrolling area.") }

        func difference(overlap: Int, rows: Int) -> Double {
            let samples = min(rows, overlap)
            let bottom = (height - overlap) * channelsPerRow
            var sum = 0
            for index in 0..<samples {
                let row = index * (overlap - 1) / max(1, samples - 1) * channelsPerRow
                for offset in stride(from: 0, to: channelsPerRow, by: 4) {
                    for color in 0..<3 {
                        sum += abs(Int(a[bottom + row + offset + color]) - Int(b[row + offset + color]))
                    }
                }
            }
            return Double(sum) / Double(samples * sampleWidth * 3)
        }

        if difference(overlap: height, rows: 96) < 0.35 {
            throw ToolError.invalid("The window has barely moved. Scroll down before adding another frame.")
        }
        // Compare bottom-to-top overlap candidates, then validate the candidates with denser sampling.
        var candidates: [(overlap: Int, score: Double)] = []
        for overlap in minimum...maximum {
            if overlap.isMultiple(of: 64) { try Task.checkCancellation() }
            candidates.append((overlap, difference(overlap: overlap, rows: 20)))
        }
        let refined = candidates.sorted { $0.score < $1.score }.prefix(24)
            .map { ($0.overlap, difference(overlap: $0.overlap, rows: 180)) }
            .sorted { $0.1 < $1.1 }
        guard let best = refined.first, best.1 < 4.0,
              !refined.dropFirst().contains(where: { abs($0.0 - best.0) > 3 && $0.1 < best.1 + 0.65 }) else {
            throw ToolError.invalid("A reliable overlap could not be found. Scroll a shorter distance and remove fixed margins if needed.")
        }
        return best.0
    }

    private static func sampledRows(_ image: CGImage, width: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = context(width: width, height: image.height, bytes: buffer.baseAddress) else {
                throw ToolError.invalid("Could not analyze this screenshot.")
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
        }
        return bytes
    }

    private static func context(width: Int, height: Int, bytes: UnsafeMutableRawPointer? = nil) -> CGContext? {
        CGContext(data: bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    }

    private static func validateCanvas(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 12_000, height <= 24_000, width * height <= 48_000_000 else {
            throw ToolError.invalid("This scrolling capture reached the maximum canvas size. Finish and start another capture.")
        }
    }
}
