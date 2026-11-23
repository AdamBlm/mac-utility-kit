import AVFoundation
import Foundation
import Testing
@testable import UtilityCore

struct VideoCompressionReviewTests {
    @Test func replacedOrMissingStagingCanBeDismissedWithoutPublishing() throws {
        let manager = FileManager.default
        let destination = manager.temporaryDirectory.appending(path: UUID().uuidString)
        try manager.createDirectory(at: destination, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: destination) }
        let file = destination.appending(path: "Candidate.mp4")
        try Data("encode".utf8).write(to: file)
        let review = try VideoCompressionReview(staged: file, destination: destination, summary: "Candidate")
        let names = try manager.contentsOfDirectory(atPath: destination.path)
        let folder = destination.appending(path: try #require(names.first))
        let staged = folder.appending(path: file.lastPathComponent)
        let replacement = Data("replacement".utf8)
        try replacement.write(to: staged, options: .atomic)
        #expect(throws: ToolError.self) { try review.keep() }
        try review.discard()
        #expect(try Data(contentsOf: staged) == replacement)

        try Data("second encode".utf8).write(to: file)
        let second = try VideoCompressionReview(staged: file, destination: destination, summary: "Candidate")
        try manager.removeItem(at: destination.appending(path: ".MacUtilityKit-Video-" + second.id.uuidString))
        try second.discard()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
    func sampleRejectsAReplacedSourceAndRemovesItsTemporaryFolder() async throws {
        let executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"]))
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appending(path: UUID().uuidString)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: folder) }
        let source = folder.appending(path: "source.mp4")
        try await ExternalTool.run(executable, name: "FFmpeg", arguments: [
            "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=160x96:r=24:d=1",
            "-c:v", "libx264", source.path
        ], directory: folder)
        let original = try Data(contentsOf: source)
        try original.write(to: folder.appending(path: "replacement.mp4"))
        try manager.createSymbolicLink(at: folder.appending(path: "ffmpeg"), withDestinationURL: executable)
        let wrapper = folder.appending(path: "fixture-encoder")
        let script = #"""
        #!/bin/sh
        set -eu
        root=$(/usr/bin/dirname "$0")
        "$root/ffmpeg" "$@"
        for argument in "$@"; do
            case "$argument" in
                */source.mp4) /bin/mv "$root/replacement.mp4" "$root/source.mp4"; break ;;
            esac
        done
        """#
        try Data(script.utf8).write(to: wrapper)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        var options = ToolOptions()
        options.ffmpegExecutable = wrapper

        await #expect {
            try await ToolRunner.sampleVideo(source, destination: folder, options: options)
        } throws: { error in
            error.localizedDescription == "The source video changed while creating the sample. Try again."
        }
        #expect(try manager.contentsOfDirectory(atPath: folder.path).sorted() ==
                ["ffmpeg", "fixture-encoder", "source.mp4"])
        #expect(try Data(contentsOf: source) == original)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"] != nil))
    func mixedBatchPublishesOnlySmallerResultsUntilReviewed() async throws {
        let executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_FFMPEG_TEST"]))
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appending(path: UUID().uuidString)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: folder) }
        let source = folder.appending(path: "Low bitrate.mp4")
        let generator = Process()
        generator.executableURL = executable
        generator.arguments = ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=160x96:r=24:d=1",
                               "-c:v", "libx264", "-crf", "51", source.path]
        try generator.run()
        generator.waitUntilExit()
        try #require(generator.terminationStatus == 0)

        let padded = folder.appending(path: "Padded.mp4")
        let original = try Data(contentsOf: source)
        try original.write(to: padded)
        let file = try FileHandle(forWritingTo: padded)
        try file.seekToEnd()
        // Add a 1 MiB ISO BMFF free-space box without altering the video stream.
        try file.write(contentsOf: Data([0, 16, 0, 0] + Array("free".utf8)))
        try file.truncate(atOffset: UInt64(original.count + 1_048_576))
        try file.close()
        let linked = folder.appending(path: "Linked Padded.mp4")
        try manager.createSymbolicLink(at: linked, withDestinationURL: padded)
        let destination = folder.appending(path: "Results")
        try manager.createDirectory(at: destination, withIntermediateDirectories: false)

        var options = ToolOptions()
        options.ffmpegExecutable = executable
        options.videoCompression.rateControl = .constantQuality
        options.videoCompression.quality = 12
        options.reviewLargerVideos = true
        let report = try await ToolRunner.run(.compressVideo, inputs: [source, linked, source],
                                              destination: destination, imageSize: 0, options: options) { _ in }
        #expect(report.failures.isEmpty)
        #expect(report.outputs.count == 1)
        #expect(report.outputs.first?.lastPathComponent.hasPrefix("2 - Linked Padded") == true)
        try #require(report.videoReviews.count == 2)
        #expect(report.videoReviews.allSatisfy { $0.summary.contains("larger") })
        #expect(report.videoReviews[0].summary.hasPrefix("1 - Low bitrate.mp4"))
        #expect(report.videoReviews[1].summary.hasPrefix("3 - Low bitrate.mp4"))
        #expect(try manager.contentsOfDirectory(atPath: destination.path).filter { !$0.hasPrefix(".") }.count == 1)

        let kept = try report.videoReviews[0].keep()
        try report.videoReviews[1].discard()
        #expect(try await AVURLAsset(url: kept).load(.isPlayable))
        #expect(try Data(contentsOf: kept).count > original.count)
        #expect(try Data(contentsOf: source) == original)
        #expect(try manager.contentsOfDirectory(atPath: destination.path).count == 2)

        let changed = try await ToolRunner.run(.compressVideo, inputs: [source, linked], destination: destination,
                                               imageSize: 0, options: options) { fraction in
            if fraction == 0.5 {
                do { try original.write(to: source, options: .atomic) }
                catch { Issue.record("Could not replace the video fixture: \(error)") }
            }
        }
        #expect(changed.outputs.map(\.lastPathComponent) == ["2 - Linked Padded.mp4"])
        #expect(changed.videoReviews.isEmpty)
        #expect(changed.failures.first?.contains("The source video changed during compression") == true)

        options.reviewLargerVideos = false
        let nonInteractive = try await ToolRunner.run(.compressVideo, inputs: [source], destination: destination,
                                                       imageSize: 0, options: options) { _ in }
        #expect(nonInteractive.outputs.isEmpty && nonInteractive.videoReviews.isEmpty)
        #expect(nonInteractive.failures.count == 1)
    }
}
