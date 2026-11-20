import AVFoundation
import CoreText
import Foundation
import ImageIO
import PDFKit
import Testing
import UtilityCore

struct WatermarkTests {
    @Test func placesLogoWithOpacityAndTilesTextOnStillImages() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = directory.appending(path: "base.png")
        let logo = directory.appending(path: "logo.png")
        try Self.writeImage(base, width: 200, height: 120, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        try Self.writeImage(logo, width: 24, height: 18, color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        var options = WatermarkOptions()
        options.content = .logo
        options.logo = logo
        options.placement = .topLeft
        options.opacity = 0.5
        options.scale = 0.25
        options.margin = 0.05
        let preview = try await Watermark.preview(base, options: options)
        let output = directory.appending(path: "marked.png")
        _ = try await Watermark.export(base, to: output, options: options) { _ in }
        let exported = try Self.image(output)
        for image in [try Self.pixels(preview), try Self.pixels(exported)] {
            let mark = image.at(17, 13)
            #expect(mark[2] == 255 && (110...150).contains(mark[0]))
            #expect(image.at(180, 100) == [255, 255, 255, 255])
        }

        options.content = .text
        options.text = "Test"
        options.textColor = 0x000000
        options.placement = .tile
        options.rotation = -31
        options.opacity = 1
        let tiled = try Self.pixels(await Watermark.preview(base, options: options))
        for area in [(0..<100, 0..<60), (100..<200, 0..<60), (0..<100, 60..<120), (100..<200, 60..<120)] {
            #expect(area.0.contains { x in area.1.contains { y in tiled.at(x, y)[0] < 120 } })
        }
    }

    @Test func stampsSelectedRotatedPDFPageAndKeepsBothPagesSearchable() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try Self.pdf(directory)
        let logo = directory.appending(path: "logo.png")
        try Self.writeImage(logo, width: 24, height: 18, color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        var options = WatermarkOptions()
        options.content = .logo
        options.logo = logo
        options.pdfPages = "2"
        options.opacity = 1
        options.scale = 0.35
        options.margin = 0.04
        let before = try Self.pixels(await Watermark.preview(source, page: 1, options: options))
        let marked = try Self.pixels(await Watermark.preview(source, page: 2, options: options))
        #expect(!before.at(before.width - 14, before.height - 14).isBlue)
        #expect(marked.at(marked.width - 17, marked.height - 16).isBlue)
        let output = directory.appending(path: "marked.pdf")
        _ = try await Watermark.export(source, to: output, options: options) { _ in }
        let read = try #require(PDFDocument(url: output))
        #expect(read.pageCount == 2)
        #expect(read.page(at: 0)?.string?.contains("First searchable") == true)
        #expect(read.page(at: 1)?.string?.contains("Second searchable") == true)
        let page = try #require(read.page(at: 1))
        #expect(page.bounds(for: .cropBox).size == CGSize(width: 110, height: 180))
        let bitmap = try #require(CGContext(data: nil, width: 110, height: 180, bitsPerComponent: 8, bytesPerRow: 440,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        page.draw(with: .cropBox, to: bitmap)
        let raster = try #require(bitmap.makeImage())
        #expect(try Self.pixels(raster).at(100, 169).isBlue)
    }

    @Test(arguments: [false, true])
    func keepsURLLinkInItsVisiblePositionOnStampedRotatedPage(cropped: Bool) async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try Self.pdf(directory)
        let document = try #require(PDFDocument(url: source))
        let page = try #require(document.page(at: 1))
        if cropped {
            page.setBounds(CGRect(x: 10, y: 8, width: 160, height: 90), for: .cropBox)
        }
        let destination = try #require(URL(string: "https://example.com/guide"))
        let link = PDFAnnotation(bounds: CGRect(x: 24, y: 16, width: 36, height: 12), forType: .link, withProperties: nil)
        link.action = PDFActionURL(url: destination)
        page.addAnnotation(link)
        let linkSource = directory.appending(path: "link-source.pdf")
        try #require(document.write(to: linkSource))
        let original = try Data(contentsOf: linkSource)
        var options = WatermarkOptions()
        options.content = .text
        options.text = "Draft"
        options.pdfPages = "2"
        let output = directory.appending(path: "linked-mark.pdf")
        _ = try await Watermark.export(linkSource, to: output, options: options) { _ in }

        let reopened = try #require(PDFDocument(url: output))
        let stamped = try #require(reopened.page(at: 1))
        let kept = try #require(stamped.annotations.first { $0.type == "Link" })
        #expect((kept.action as? PDFActionURL)?.url == destination)
        #expect(kept.bounds == (cropped ? CGRect(x: 8, y: 110, width: 12, height: 36)
                                       : CGRect(x: 16, y: 120, width: 12, height: 36)))
        #expect(kept.border?.lineWidth == 0)
        #expect(stamped.string?.contains("Second searchable") == true)
        #expect(try Data(contentsOf: linkSource) == original)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
    func videoNativePreviewAndFFmpegExportHonorTimingAndPortraitOrientation() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try await VideoResizeTests.makePortraitVideo(in: directory)
        let logo = directory.appending(path: "logo.png")
        try Self.writeImage(logo, width: 24, height: 18, color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        var options = WatermarkOptions()
        options.content = .logo
        options.logo = logo
        options.placement = .center
        options.opacity = 1
        options.scale = 0.5
        options.videoStart = 0.3
        options.videoEnd = 0.75
        options.ffmpegExecutable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"]))
        let previewEarly = try Self.pixels(await Watermark.preview(input, seconds: 0.125, options: options))
        let previewWithin = try Self.pixels(await Watermark.preview(input, seconds: 0.5, options: options))
        #expect(!previewEarly.at(32, 64).isBlue)
        #expect(previewWithin.at(32, 64).isBlue)

        let output = directory.appending(path: "marked.mp4")
        _ = try await Watermark.export(input, to: output, options: options) { _ in }
        let asset = AVURLAsset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 64, height: 128))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for (time, expected) in [(0.125, false), (0.5, true), (0.875, false)] {
            let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            #expect(try Self.pixels(image).at(32, 64).isBlue == expected)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil),
          arguments: [false, true])
    func watermarksTheSameSourceFramesWhenVideoStartsLate(hasLeadingAudio: Bool) async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"]))
        let input = directory.appending(path: "late.mov")
        var arguments = ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "color=red:s=48x32:r=20:d=1.6"]
        if hasLeadingAudio {
            arguments += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2.55"]
        }
        arguments += ["-vf", "setpts=PTS+1/TB", "-map", "0:v", "-c:v", "libx264", "-pix_fmt", "yuv420p"]
        if hasLeadingAudio { arguments += ["-map", "1:a", "-c:a", "aac"] }
        let writer = Process()
        writer.executableURL = ffmpeg
        writer.arguments = arguments + [input.path]
        try writer.run()
        writer.waitUntilExit()
        try #require(writer.terminationStatus == 0)

        let logo = directory.appending(path: "blue.png")
        try Self.writeImage(logo, width: 24, height: 18, color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        var options = WatermarkOptions()
        options.content = .logo
        options.logo = logo
        options.placement = .center
        options.opacity = 1
        options.scale = 0.5
        options.videoStart = 1.15
        options.videoEnd = 1.7
        options.ffmpegExecutable = ffmpeg
        let output = directory.appending(path: "marked.mp4")
        _ = try await Watermark.export(input, to: output, options: options) { _ in }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for (time, expected) in [(1.05, false), (1.4, true), (2.0, false)] {
            let preview = try await Watermark.preview(input, seconds: time, options: options)
            let rendered = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
            #expect(try Self.pixels(preview).at(24, 16).isBlue == expected)
            #expect(try Self.pixels(rendered.image).at(24, 16).isBlue == expected)
        }
        let bounds = try await FrameExtraction.timeBounds(of: output)
        #expect(abs(bounds.lowerBound - 1) < 0.01)
        let audio = try await generator.asset.loadTracks(withMediaType: .audio)
        #expect(audio.count == (hasLeadingAudio ? 1 : 0))
        if let track = audio.first {
            let timing = try await track.load(.timeRange)
            #expect(abs(timing.start.seconds) < 0.05)
            #expect(abs(timing.duration.seconds - 2.55) < 0.05)
        }
    }

    private static func pdf(_ directory: URL) throws -> URL {
        let raw = directory.appending(path: "raw.pdf")
        var media = CGRect(x: 0, y: 0, width: 180, height: 110)
        let context = try #require(CGContext(raw as CFURL, mediaBox: &media, nil))
        for value in ["First searchable", "Second searchable"] {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil)
            ]))
            context.textPosition = CGPoint(x: 18, y: 60)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        let result = try #require(PDFDocument(url: raw))
        let page = try #require(result.page(at: 1))
        page.rotation = 90
        let oriented = directory.appending(path: "source.pdf")
        try #require(result.write(to: oriented))
        return oriented
    }

    private struct PixelMap {
        let width: Int
        let height: Int
        let bytes: Data

        func at(_ x: Int, _ y: Int) -> [UInt8] {
            let index = (y * width + x) * 4
            return Array(bytes[index..<(index + 4)])
        }
    }

    private static func pixels(_ image: CGImage) throws -> PixelMap {
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: 4 * image.width, space: srgb,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data)
        return PixelMap(width: image.width, height: image.height, bytes: Data(bytes: bytes, count: image.width * image.height * 4))
    }

    private static func image(_ url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private static func writeImage(_ url: URL, width: Int, height: Int, color: CGColor) throws {
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: srgb,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        try ImageRedaction.writePNG(try #require(context.makeImage()), to: url)
    }

    private static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}

private extension Array where Element == UInt8 {
    var isBlue: Bool { count >= 3 && self[2] > 165 && Int(self[2]) - Int(Swift.max(self[0], self[1])) > 100 }
}
