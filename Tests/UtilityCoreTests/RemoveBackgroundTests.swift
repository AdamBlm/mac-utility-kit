import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import UtilityCore

struct RemoveBackgroundTests {
    @Test func maskAndManualRefinementsUseUprightCoordinatesAndOrderedCoverage() throws {
        let original = try Self.makeRedImage()
        let bounds = CGRect(x: 0, y: 0, width: 48, height: 32)
        let black = CIImage(color: .black).cropped(to: bounds)
        let mask = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 16, width: 24, height: 16)).composited(over: black)
        var edit = RemoveBackgroundEdit()
        edit.refinements = [
            ForegroundRefinement(region: ImageMaskRegion(rect: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)), action: .keep),
            ForegroundRefinement(region: ImageMaskRegion(rect: CGRect(x: 0, y: 0, width: 0.25, height: 0.25)), action: .remove)
        ]
        let image = try RemoveBackground.composite(original, mask: mask, edit: edit, options: RemoveBackgroundOptions())
        let pixels = try Self.pixels(image)
        #expect(pixels.pixel(x: 3, y: 4) == [0, 0, 0, 0])
        #expect(pixels.pixel(x: 14, y: 12) == [255, 0, 0, 255])
        #expect(pixels.pixel(x: 31, y: 4) == [0, 0, 0, 0])
        #expect(pixels.pixel(x: 36, y: 24) == [255, 0, 0, 255])
        #expect(pixels.pixel(x: 5, y: 28) == [0, 0, 0, 0])
    }

    @Test func manualRegionsExportTransparentPNGAndSolidJPEG() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "plain.png")
        try ImageRedaction.writePNG(Self.makeRedImage(), to: input)
        let analysis = try RemoveBackground.analyze(input)
        var edit = RemoveBackgroundEdit()
        edit.subjects = []
        var options = RemoveBackgroundOptions()
        options.apply(edit, to: input, analysis: analysis)
        let missing = directory.appending(path: "missing.png")
        await #expect(throws: ToolError.self) { try await RemoveBackground.export(input, to: missing, options: options) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))

        edit.refinements = [ForegroundRefinement(region: ImageMaskRegion(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1)), action: .keep)]
        options.apply(edit, to: input, analysis: analysis)
        let png = directory.appending(path: "result.png")
        _ = try await RemoveBackground.export(input, to: png, options: options)
        let pngPixels = try Self.pixels(Self.read(png))
        #expect(pngPixels.pixel(x: 12, y: 16) == [255, 0, 0, 255])
        #expect(pngPixels.pixel(x: 36, y: 16) == [0, 0, 0, 0])

        options.format = .jpeg
        options.background = .solid
        options.backgroundColor = 0x0058DD
        let jpeg = directory.appending(path: "result.jpg")
        _ = try await RemoveBackground.export(input, to: jpeg, options: options)
        let jpegPixels = try Self.pixels(Self.read(jpeg))
        let chosenBackground = jpegPixels.pixel(x: 36, y: 16)
        #expect(chosenBackground[0] < 20 && abs(Int(chosenBackground[1]) - 88) < 22)
        #expect(abs(Int(chosenBackground[2]) - 221) < 22 && chosenBackground[3] == 255)
    }

    @Test func brushAndRectangleCorrectionsUseTheSameOrderInPreviewAndExport() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "source.png")
        let output = directory.appending(path: "brushed.png")
        try ImageRedaction.writePNG(Self.makeRedImage(), to: input)
        let analysis = try RemoveBackground.analyze(input)
        var edit = RemoveBackgroundEdit()
        edit.subjects = []
        edit.refinements = [
            .init(stroke: .init(points: [.init(x: 0.125, y: 0.125), .init(x: 0.75, y: 0.75)], width: 0.125), action: .keep),
            .init(region: ImageMaskRegion(rect: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)), action: .keep),
            .init(stroke: .init(points: [.init(x: 0.75, y: 0.75)], width: 0.25), action: .remove),
            .init(stroke: .init(points: [.init(x: 0.75, y: 0.75)], width: 0.09375), action: .keep)
        ]
        var options = RemoveBackgroundOptions()
        options.apply(edit, to: input, analysis: analysis)
        let preview = try Self.pixels(RemoveBackground.preview(analysis, edit: edit, options: options))
        _ = try await RemoveBackground.export(input, to: output, options: options)
        let exported = try Self.pixels(Self.read(output))
        #expect(preview.bytes == exported.bytes)
        #expect(exported.pixel(x: 6, y: 4) == [255, 0, 0, 255])
        #expect(exported.pixel(x: 18, y: 12) == [255, 0, 0, 255])
        #expect(exported.pixel(x: 18, y: 4) == [0, 0, 0, 0])
        #expect(exported.pixel(x: 42, y: 24) == [255, 0, 0, 255])
        #expect(exported.pixel(x: 36, y: 24)[3] > 200)
        #expect(exported.pixel(x: 39, y: 24)[3] < 20)
    }

    @Test func rejectsInvalidBrushCoordinates() throws {
        let original = try Self.makeRedImage()
        var edit = RemoveBackgroundEdit()
        edit.refinements = [
            .init(stroke: .init(points: [.init(x: 1.25, y: 0)], width: 0.1), action: .keep)
        ]
        #expect(throws: ToolError.self) {
            try RemoveBackground.composite(original, mask: nil, edit: edit, options: .init())
        }
    }

    @Test func brushPreservesUntouchedFractionalMatteValues() throws {
        let original = try Self.makeRedImage()
        let extent = CGRect(x: 0, y: 0, width: original.width, height: original.height)
        let mask = CIImage(bitmapData: Data(repeating: 128, count: original.width * original.height),
                           bytesPerRow: original.width, size: extent.size, format: .L8, colorSpace: nil)
        let baseline = try Self.pixels(RemoveBackground.composite(original, mask: mask, edit: .init(), options: .init()))
        var edited = RemoveBackgroundEdit()
        edited.refinements = [
            .init(stroke: .init(points: [.init(x: 0.2, y: 0.2)], width: 0.1), action: .remove)
        ]
        let output = try Self.pixels(RemoveBackground.composite(original, mask: mask, edit: edited, options: .init()))
        #expect(baseline.pixel(x: 30, y: 20)[3] == 128)
        #expect(output.pixel(x: 30, y: 20) == baseline.pixel(x: 30, y: 20))
        #expect(output.pixel(x: 9, y: 6)[3] == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FOREGROUND_TEST"] != nil))
    func nativeVisionFindsAndMasksAnActualSubject() throws {
        let input = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FOREGROUND_TEST"]))
        let analysis = try RemoveBackground.analyze(input)
        try #require(!analysis.subjects.isEmpty)
        var edit = RemoveBackgroundEdit()
        edit.subjects = IndexSet(integer: try #require(analysis.subjects.first))
        let result = try RemoveBackground.preview(analysis, edit: edit, options: RemoveBackgroundOptions())
        let sampled = try Self.pixels(result)
        let coverage = stride(from: 0, to: result.height, by: 3).flatMap { y in
            stride(from: 0, to: result.width, by: 3).map { x in sampled.pixel(x: x, y: y)[3] }
        }
        #expect(coverage.contains { $0 < 10 })
        #expect(coverage.contains { $0 > 245 })
    }

    private static func read(_ url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private static func makeRedImage() throws -> CGImage {
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 48, height: 32, bitsPerComponent: 8,
                                             bytesPerRow: 48 * 4, space: srgb,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        return try #require(context.makeImage())
    }

    private struct PixelMap {
        let width: Int
        let bytes: Data

        func pixel(x: Int, y: Int) -> [UInt8] {
            let index = (y * width + x) * 4
            return Array(bytes[index..<(index + 4)])
        }
    }

    private static func pixels(_ image: CGImage) throws -> PixelMap {
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: srgb,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data)
        return PixelMap(width: image.width, bytes: Data(bytes: data, count: image.width * image.height * 4))
    }
}
