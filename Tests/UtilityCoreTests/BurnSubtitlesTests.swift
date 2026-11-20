import AVFoundation
import CoreGraphics
import Foundation
import Testing
import UtilityCore

@Suite struct BurnSubtitlesTests {
    @Test func importsUnicodeAndLegacySubRipWithoutChangingCueText() throws {
        let subtitle = "1\r\n00:00:00,000 --> 00:00:01,000\r\nCafé €\r\n"
        for encoding in [String.Encoding.utf8, .utf16, .windowsCP1252] {
            let data = try #require(subtitle.data(using: encoding))
            let loaded = try SubRip.decode(data)
            #expect(loaded == subtitle)
            #expect(try SubRip.parse(loaded).first?.text == "Café €")
        }
    }

    @Test func rejectsAnInvalidEncoderBeforeReadingTheVideo() async {
        let folder = FileManager.default.temporaryDirectory
        var options = BurnSubtitlesOptions()
        options.srt = " \n"
        options.ffmpegExecutable = folder
        #expect(!options.hasSubtitles)
        let error = await #expect(throws: ToolError.self) {
            try await BurnSubtitles.preview(folder, at: 0, options: options)
        }
        #expect(error?.localizedDescription == "Choose an FFmpeg executable with libass.")
    }

    @Test func validatesAndCanonicalizesSubRipCues() throws {
        let source = "\u{FEFF}5\r\n00:00:00,100 --> 00:00:01,200\r\nHello\r\n世界\r\n\r\n7\r\n00:00:01.200 --> 00:00:02.000\r\nThe end."
        var options = BurnSubtitlesOptions()
        options.srt = "invalid cue"
        #expect(options.subtitleIssue?.contains("line 1") == true)
        options.srt = source
        #expect(options.subtitleIssue == nil)
        let parsed = try SubRip.parse(source)
        #expect(parsed.map(\.startMilliseconds) == [100, 1200])
        #expect(parsed.first?.text == "Hello\n世界")
        #expect(try SubRip.parse(SubRip.render(parsed)) == parsed)
        #expect(throws: ToolError.self) { try SubRip.parse("1\n00:00:01,200 --> 00:00:01,100\nInverted") }
        #expect(throws: ToolError.self) { try SubRip.parse("1\n00:60:00,000 --> 01:00:03,000\nMalformed") }
        #expect(throws: ToolError.self) {
            try SubRip.parse("1\n00:00:01,000 --> 00:00:02,000\nA\n\n2\n00:00:01,500 --> 00:00:02,100\nB")
        }
    }

    @Test func shiftsAndClipsAtBothEdges() throws {
        var options = BurnSubtitlesOptions()
        options.srt = """
        1
        00:00:00,000 --> 00:00:01,000
        Start edge

        2
        00:00:02,000 --> 00:00:03,000
        End edge

        3
        00:00:04,000 --> 00:00:05,000
        Outside
        """
        options.offset = -0.4
        let plan = try BurnSubtitles.plan(duration: 2.1, options: options)
        #expect(plan.cues.map(\.startMilliseconds) == [0, 1_600])
        #expect(plan.cues.map(\.endMilliseconds) == [600, 2_100])
        #expect(plan.removed == 1)
        #expect(plan.clipped == 2)
        let parsed = try SubRip.parse(options.srt)
        let short = try BurnSubtitles.plan(duration: 2.1, options: options, parsedCues: parsed)
        let long = try BurnSubtitles.plan(duration: 5, options: options, parsedCues: parsed)
        #expect(short.cues == plan.cues && short.clipped == plan.clipped)
        #expect(long.cues.count == 3 && long.clipped == 1 && long.removed == 0)
        options.offset = 10
        #expect(throws: ToolError.self) { try BurnSubtitles.plan(duration: 2.1, options: options) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
    func burnsVisibleOffsetCueIntoFrameAndKeepsAudio() async throws {
        let ffmpeg = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"]))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("black.mp4")
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-v", "error", "-nostdin",
            "-f", "lavfi", "-i", "color=c=black:size=320x180:rate=24:duration=3",
            "-f", "lavfi", "-i", "sine=frequency=400:duration=3",
            "-c:v", "libx264", "-c:a", "aac", "-shortest", source.path
        ]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)

        var options = BurnSubtitlesOptions()
        options.srt = "1\n00:00:00,200 --> 00:00:00,800\nVisible cue"
        options.offset = 0.5
        options.ffmpegExecutable = ffmpeg
        options.fontSize = 36
        options.background = .solid
        options.position = .top
        options.textRGB = 0xFF2020
        let preview = try await BurnSubtitles.preview(source, at: 1, options: options)
        #expect(try redPixels(in: preview) > 30)
        let emptyPreview = try await BurnSubtitles.preview(source, at: 0.4, options: options)
        #expect(try redPixels(in: emptyPreview) == 0)
        let afterLastVisibleFrame = try await BurnSubtitles.preview(source, at: 1.299, options: options)
        #expect(try redPixels(in: afterLastVisibleFrame) == 0)

        let result = folder.appendingPathComponent("result.mp4")
        _ = try await BurnSubtitles.export(source, to: result, options: options) { _ in }
        let before = try await FrameExtraction.preview(result, at: 0.4)
        let active = try await FrameExtraction.preview(result, at: 1)
        let after = try await FrameExtraction.preview(result, at: 1.6)
        #expect(try redPixels(in: before) == 0)
        #expect(try redPixels(in: active) > 30)
        #expect(try redPixels(in: after) == 0)
        let asset = AVURLAsset(url: result)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    private func redPixels(in image: CGImage) throws -> Int {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        return try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return stride(from: 0, to: buffer.count, by: 4).filter { index in
                buffer[index] > 100 && Int(buffer[index]) > Int(buffer[index + 1]) + 25
            }.count
        }
    }
}
