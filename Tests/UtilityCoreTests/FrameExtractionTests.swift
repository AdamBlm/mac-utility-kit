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
        options.interval = 0
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
        options.interval = 0.25
        options.selection = .interval
        let times = try FrameExtraction.times(in: bounds, options: options)
        #expect(Array(times.prefix(2)) == [offset.seconds, offset.seconds + 0.25])
        let result = try await FrameExtraction.export(input, into: folder, options: .init()) { _ in }
        #expect(result.outputs.map(\.lastPathComponent) == ["Frame-001-0.333s.png"])
        #expect(result.failures.isEmpty)
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
        let length = try await FrameExtraction.duration(of: input)
        let preview = try await FrameExtraction.preview(input, at: length * 0.51)
        #expect(preview.width == 128)
        #expect(preview.height == 96)

        var options = FrameExtractionOptions()
        options.timestamps = [length * 0.51, 0]
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
