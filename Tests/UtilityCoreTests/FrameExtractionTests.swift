import AVFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import UtilityCore

@Suite struct FrameExtractionTests {
    @Test func timestampPlanSortsAndDeduplicates() throws {
        var options = FrameExtractionOptions()
        #expect(try FrameExtraction.times(duration: 3, options: options) == [0])
        options.timestamps = [2, 0.5, 0, 0.5]
        #expect(try FrameExtraction.times(duration: 3, options: options) == [0, 0.5, 2])
        options.timestamps.append(3)
        #expect(throws: ToolError.self) { try FrameExtraction.times(duration: 3, options: options) }
        options.timestamps = [.nan]
        #expect(throws: ToolError.self) { try FrameExtraction.times(duration: 3, options: options) }
    }

    @Test func intervalPlanBoundsCountAndExcludesDuration() throws {
        var options = FrameExtractionOptions()
        options.selection = .interval
        options.interval = 0.5
        #expect(try FrameExtraction.times(duration: 1.5, options: options) == [0, 0.5, 1])
        #expect(try FrameExtraction.times(duration: 250, options: options).count == 500)
        #expect(throws: ToolError.self) { try FrameExtraction.times(duration: 250.01, options: options) }
        options.interval = 0.007
        #expect(try FrameExtraction.times(in: 0.501..<4.001, options: options).count == 500)
        options.interval = VideoTimecode.seconds(from: "00:02bad") ?? 0
        #expect(!options.intervalIsValid)
        #expect(throws: ToolError.self) { try FrameExtraction.times(duration: 3, options: options) }
    }

    @Test func startsExtractionAtTheFirstFrameOfADelayedTrack() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }

        let original = AVURLAsset(url: try await conversionFixture(in: folder))
        let source = try #require(try await original.loadTracks(withMediaType: .video).first)
        let composition = AVMutableComposition()
        let track = try #require(composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        let offset = CMTime(value: 1, timescale: 3)
        try await track.insertTimeRange(source.load(.timeRange), of: source, at: offset)
        let input = folder.appending(path: "Delayed.mov")
        let exporter = try #require(AVAssetExportSession(asset: composition,
                                                        presetName: AVAssetExportPresetPassthrough))
        try await exporter.exportMedia(to: input, as: .mov)

        let bounds = try await FrameExtraction.timeBounds(of: input)
        #expect(bounds.lowerBound == offset.seconds)
        await #expect(throws: ToolError.self) { _ = try await FrameExtraction.preview(input, at: 0) }
        let first = try await FrameExtraction.preview(input, at: bounds.lowerBound)
        #expect(first.width == 128 && first.height == 96)

        var options = FrameExtractionOptions()
        options.interval = try #require(VideoTimecode.seconds(from: "00:00:00.25"))
        options.selection = .interval
        let times = try FrameExtraction.times(in: bounds, options: options)
        #expect(Array(times.prefix(2)) == [offset.seconds, offset.seconds + 0.25])
        let result = try await FrameExtraction.export(input, into: folder, options: .init()) { _ in }
        #expect(result.outputs.map(\.lastPathComponent) == ["Frame-001-0.333s.png"])
        #expect(result.failures.isEmpty)
    }

    @Test(arguments: [false, true])
    func batchPublishesOnlyDecodableFramesFromUnchangedSources(replaceFirst: Bool) async throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appending(path: UUID().uuidString)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: folder) }

        let first = try await conversionFixture(in: folder)
        let otherFolder = folder.appending(path: "Other", directoryHint: .isDirectory)
        try manager.createDirectory(at: otherFolder, withIntermediateDirectories: false)
        let second = otherFolder.appending(path: first.lastPathComponent)
        try manager.copyItem(at: first, to: second)
        let corrupt = folder.appending(path: "Corrupt.mov")
        try Data("Not a video".utf8).write(to: corrupt)
        let destination = folder.appending(path: "Results", directoryHint: .isDirectory)
        try manager.createDirectory(at: destination, withIntermediateDirectories: false)
        let original = try Data(contentsOf: first)

        var options = ToolOptions()
        options.frames.timestamps = [0, 0.125, 100]
        options.frames.naming = .sequence
        let report = try await ToolRunner.run(
            .extractFrames, inputs: [first, corrupt, second], destination: destination,
            imageSize: 0, options: options
        ) { fraction in
            if replaceFirst, fraction == (1.0 / 3) / 3 {
                do { try original.write(to: first, options: .atomic) }
                catch { Issue.record("Could not replace the video fixture: \(error)") }
            }
        }

        #expect(report.failures.count == 3)
        let firstIssue = replaceFirst ? "The video changed during frame extraction" : "100.000s: This timestamp is outside"
        #expect(report.failures.first?.contains(firstIssue) == true)
        #expect(report.failures.dropFirst().first?.hasPrefix("2 - Corrupt.mov — ") == true)
        #expect(report.failures.last?.contains("100.000s: This timestamp is outside") == true)
        let stem = first.deletingPathExtension().lastPathComponent
        let expectedFolders = replaceFirst ? ["3 - " + stem] : ["1 - " + stem, "3 - " + stem]
        #expect(report.outputs.map { $0.deletingLastPathComponent().lastPathComponent }
                == expectedFolders.flatMap { [$0, $0] })
        #expect(report.outputs.map(\.lastPathComponent)
                == expectedFolders.flatMap { _ in ["Frame-001.png", "Frame-002.png"] })

        let results = try manager.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        #expect(results.count == 1)
        let result = try #require(results.first)
        #expect(Set(try manager.contentsOfDirectory(atPath: result.path)) == Set(expectedFolders))
        for output in report.outputs {
            let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 128 && image.height == 96)
        }
        #expect(try Data(contentsOf: first) == original)
        #expect(try Data(contentsOf: second) == original)
    }

    @Test func anExistingFrameIsPreservedWhileLaterFramesStillExport() async throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appending(path: UUID().uuidString)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: folder) }
        let input = try await conversionFixture(in: folder)
        let destination = folder.appending(path: "Frames", directoryHint: .isDirectory)
        try manager.createDirectory(at: destination, withIntermediateDirectories: false)
        let existing = destination.appending(path: "Frame-001.png")
        let original = Data("Existing file".utf8)
        try original.write(to: existing)

        var options = FrameExtractionOptions()
        options.timestamps = [0, 0.125]
        options.naming = .sequence
        let result = try await FrameExtraction.export(input, into: destination, options: options) { _ in }
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.hasPrefix("0.000s: ") == true)
        #expect(result.outputs.map(\.lastPathComponent) == ["Frame-002.png"])
        #expect(try Data(contentsOf: existing) == original)
        let output = try #require(result.outputs.first)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
        #expect(try manager.contentsOfDirectory(atPath: destination.path).sorted() == ["Frame-001.png", "Frame-002.png"])
    }

    @Test(arguments: FrameImageFormat.allCases)
    func exportsDecodableFramesInOrder(_ format: FrameImageFormat) async throws {
        guard (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(format.contentType.identifier) == true else {
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = try await conversionFixture(in: folder)
        let timestamp = try #require(VideoTimecode.seconds(from: "00:00:00.125"))
        let preview = try await FrameExtraction.preview(input, at: timestamp)
        #expect(preview.width == 128)
        #expect(preview.height == 96)

        var options = FrameExtractionOptions()
        options.timestamps = [timestamp, 0]
        options.format = format
        options.naming = .sequence
        let result = try await FrameExtraction.export(input, into: folder, options: options) { _ in }

        #expect(result.outputs.map(\.lastPathComponent) == ["Frame-001.\(format.fileExtension)", "Frame-002.\(format.fileExtension)"])
        #expect(result.failures.isEmpty)
        for url in result.outputs {
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let type = try #require(CGImageSourceGetType(source))
            #expect(type as String == format.contentType.identifier)
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 128)
            #expect(image.height == 96)
        }
    }
}
