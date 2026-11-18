import AVFoundation
import Foundation
import Testing
import UtilityCore

@Suite struct TrimVideoTests {
    @Test func alignsOutwardAndValidatesTime() throws {
        let range = try VideoTrimRange.validate(start: 1.4, end: 3.2, duration: 5)
        let aligned = try VideoTrimRange.align(range, to: [0, 1, 2, 3, 4], duration: 5)
        #expect(aligned.start == 1)
        #expect(aligned.end == 4)
        #expect(throws: ToolError.self) { try VideoTrimRange.validate(start: 1, end: 1, duration: 5) }
        #expect(throws: ToolError.self) { try VideoTrimRange.validate(start: .nan, end: 1, duration: 5) }
        #expect(throws: ToolError.self) { try VideoTrimRange.align(range, to: [2, 3, 4], duration: 5) }
    }

    @Test func preciseReencodeProducesPlayableRequestedDuration() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = try await conversionFixture(in: folder)
        let length = try await TrimVideo.duration(of: input)
        var options = TrimVideoOptions()
        options.start = length / 4
        options.end = length * 3 / 4
        let output = folder.appendingPathComponent("trimmed.mp4")
        _ = try await TrimVideo.export(input, to: output, options: options) { _ in }
        let asset = AVURLAsset(url: output)
        #expect(try await asset.load(.isPlayable))
        #expect(abs(try await asset.load(.duration).seconds - length / 2) <= 0.15)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil &&
                   ProcessInfo.processInfo.environment["MAC_UTILITY_FFPROBE_TEST"] != nil))
    func losslessCopyStartsAtThePlannedKeyframe() async throws {
        let env = ProcessInfo.processInfo.environment
        let ffmpeg = URL(fileURLWithPath: try #require(env["MAC_UTILITY_FFMPEG_TEST"]))
        let ffprobe = URL(fileURLWithPath: try #require(env["MAC_UTILITY_FFPROBE_TEST"]))
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("multiple-gops.mp4")
        try run(ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-nostdin",
            "-f", "lavfi", "-i", "testsrc2=size=144x96:rate=24:duration=5",
            "-f", "lavfi", "-i", "sine=frequency=520:sample_rate=48000:duration=5",
            "-c:v", "libx264", "-g", "24", "-sc_threshold", "0", "-bf", "2", "-c:a", "aac", input.path
        ])
        let output = folder.appendingPathComponent("clip.mkv")
        var options = TrimVideoOptions()
        options.mode = .lossless
        options.start = 1.5
        options.end = 2.6
        options.ffmpegExecutable = ffmpeg
        options.ffprobeExecutable = ffprobe
        let planned = try await TrimVideo.plannedRange(input, options: options)
        #expect(planned.start == 1)
        #expect(planned.end == 3)
        _ = try await TrimVideo.export(input, to: output, options: options) { _ in }
        let before = try oneFrameHash(ffmpeg, input: input, seek: "0", report: folder.appendingPathComponent("before.txt"))
        let expected = try oneFrameHash(ffmpeg, input: input, seek: "1", report: folder.appendingPathComponent("expected.txt"))
        let exported = try oneFrameHash(ffmpeg, input: output, seek: nil, report: folder.appendingPathComponent("exported.txt"))
        #expect(before != expected)
        #expect(exported == expected)
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func run(_ tool: URL, _ args: [String]) throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    private func oneFrameHash(_ ffmpeg: URL, input: URL, seek: String?, report: URL) throws -> String {
        try run(ffmpeg, ["-v", "error", "-nostdin"] + (seek.map { ["-ss", $0] } ?? []) + [
            "-i", input.path, "-map", "0:v:0", "-frames:v", "1", "-f", "hash", report.path
        ])
        return try String(contentsOf: report, encoding: .utf8)
    }
}
