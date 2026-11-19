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
          arguments: [false, true])
    func seeksBySourceTimestampWhenVideoStartsLate(hasLeadingAudio: Bool) async throws {
        let ffmpeg = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"]))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("late.mov")
        var inputs = ["-f", "lavfi", "-i", "color=red:s=48x32:r=20:d=0.8",
                      "-f", "lavfi", "-i", "color=blue:s=48x32:r=20:d=0.8"]
        if hasLeadingAudio {
            inputs += ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono:d=2.55"]
        }
        var streams = ["-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0,setpts=PTS+1/TB[v]",
                       "-map", "[v]", "-c:v", "libx264", "-pix_fmt", "yuv420p"]
        if hasLeadingAudio { streams += ["-map", "2:a", "-c:a", "aac"] }
        try Self.run(ffmpeg, inputs + streams + [input.path])

        let bounds = try await FrameExtraction.timeBounds(of: input)
        #expect(bounds.lowerBound == 1)
        var options = VideoGIFOptions()
        options.ffmpegExecutable = ffmpeg
        options.width = 48
        options.fps = 10
        #expect(try VideoGIF.plan(in: bounds, options: options).range.start == 1)
        let fromFirstFrame = try await VideoGIF.preview(input, options: options)
        options.start = 1.1
        options.end = 1.7
        let preview = try await VideoGIF.preview(input, options: options)
        let output = folder.appendingPathComponent("red.gif")
        _ = try await VideoGIF.export(input, to: output, options: options) { _ in }
        #expect(try Data(contentsOf: output) == preview.data)
        let gif = try #require(CGImageSourceCreateWithData(preview.data as CFData, nil))
        #expect(CGImageSourceGetCount(gif) == 6)
        try Self.expectRedFirstFrame(preview.data)
        try Self.expectRedFirstFrame(fromFirstFrame.data)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil),
          arguments: GIFLoop.allCases)
    func exportsAnimatedGifAndMatchingPreview(_ loop: GIFLoop) async throws {
        let ffmpeg = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"]))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("source.mp4")
        try Self.run(ffmpeg, [
            "-f", "lavfi", "-i", "testsrc2=size=144x96:rate=24:duration=2",
            "-c:v", "libx264", input.path
        ])

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

    private static func expectRedFirstFrame(_ data: Data) throws {
        let gif = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let first = try #require(CGImageSourceCreateImageAtIndex(gif, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { storage in
            let context = try #require(CGContext(
                data: storage.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            context.draw(first, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        #expect(pixel[0] > 200 && pixel[2] < 30)
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-v", "error", "-nostdin"] + arguments
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }
}
