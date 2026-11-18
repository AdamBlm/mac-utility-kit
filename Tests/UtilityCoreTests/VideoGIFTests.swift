import Foundation
import ImageIO
import Testing
import UtilityCore

@Suite struct VideoGIFTests {
    @Test func checksClipTimingAndWarnsAboutLargeExports() throws {
        var options = VideoGIFOptions()
        options.fps = 15
        options.end = 3
        #expect(try VideoGIF.plan(duration: 4, options: options).frameCount == 45)
        options.width = 1280
        options.end = 25
        let plan = try VideoGIF.plan(duration: 30, options: options)
        #expect(plan.shouldWarnAboutSize)
        options.end = 101
        #expect(throws: ToolError.self) { try VideoGIF.plan(duration: 101, options: options) }
        options.end = 2
        options.start = 2
        #expect(throws: ToolError.self) { try VideoGIF.plan(duration: 4, options: options) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil),
          arguments: GIFLoop.allCases)
    func exportsAnimatedGifAndMatchingPreview(_ loop: GIFLoop) async throws {
        let ffmpeg = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"]))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("source.mp4")
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-v", "error", "-nostdin", "-f", "lavfi", "-i", "testsrc2=size=144x96:rate=24:duration=2",
            "-c:v", "libx264", input.path
        ]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)

        var settings = VideoGIFOptions()
        settings.ffmpegExecutable = ffmpeg
        settings.start = 0.25
        settings.end = 1.25
        settings.width = 96
        settings.fps = 10
        settings.loop = loop
        settings.palette = .compact
        let preview = try await VideoGIF.preview(input, options: settings)
        let output = folder.appendingPathComponent("clip.gif")
        _ = try await VideoGIF.export(input, to: output, options: settings) { _ in }
        let data = try Data(contentsOf: output)
        #expect(preview.showsFullClip)
        #expect(data == preview.data)
        #expect(preview.estimatedBytes == data.count)
        let image = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(image) == 10)
        let first = try #require(CGImageSourceCreateImageAtIndex(image, 0, nil))
        let last = try #require(CGImageSourceCreateImageAtIndex(image, 9, nil))
        #expect(first.width == 96)
        #expect(first.height == 64)
        #expect(first.dataProvider?.data != last.dataProvider?.data)
    }
}
