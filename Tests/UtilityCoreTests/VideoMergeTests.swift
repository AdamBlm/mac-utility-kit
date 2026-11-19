import AVFoundation
import Testing
import UtilityCore

@Suite(.serialized)
struct VideoMergeTests {
    @MainActor @Test
    func normalizesMixedClipsWithSilenceAndKeepsBoundaryOrder() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let portrait = try await VideoResizeTests.makePortraitVideo(in: directory)
        var resize = VideoResizeOptions()
        resize.sizing = .dimensions
        resize.width = 128
        resize.height = 64
        resize.locksAspectRatio = false
        resize.framing = .stretch
        let wide = directory.appending(path: "wide.mp4")
        _ = try await VideoResize.export(portrait, to: wide, options: resize) { _ in }
        let withAudio = try await Self.attachAudio(to: portrait, in: directory)
        let sources = [wide, withAudio]
        let output = directory.appending(path: "joined.mp4")
        var options = VideoMergeOptions()
        options.mode = .passthrough
        let incompatible = try await VideoMerge.plan(sources, options: options)
        #expect(incompatible.passthroughIssue != nil)
        await #expect(throws: ToolError.self) {
            try await VideoMerge.export(sources, to: output, options: options) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))

        options.mode = .normalize
        let plan = try await VideoMerge.plan(sources, options: options)
        #expect(plan.clips.map(\.url) == sources)
        #expect(plan.clips.map(\.start) == [0, plan.clips[0].duration])
        #expect(plan.clips.map(\.hasAudio) == [false, true])
        #expect(plan.clips.map(\.sizesDiffer) == [false, true])

        let images = try await VideoMerge.previewBoundary(sources, before: 1, options: options)
        #expect(try Self.edgeHasColor(images.before))
        #expect(try !Self.edgeHasColor(images.after))

        let playback = try await VideoMerge.boundaryPlayback([portrait] + sources + [portrait], before: 2, options: options)
        let playbackDuration = try await playback.asset.load(.duration)
        #expect(abs(playbackDuration.seconds - plan.duration) < 0.05)
        let expectedRanges = [0.0, plan.clips[1].start]
        #expect(playback.videoComposition?.instructions.map { $0.timeRange.start.seconds } == expectedRanges)
        #expect(try await Self.audioPeak(playback.asset, startingAt: 0.2) < 100)
        #expect(try await Self.audioPeak(playback.asset, startingAt: plan.clips[1].start + 0.2) > 1_000)

        _ = try await VideoMerge.export(sources, to: output, options: options) { _ in }
        let result = AVURLAsset(url: output)
        let actual = try await result.load(.duration).seconds
        #expect(abs(actual - plan.duration) < 0.1)
        #expect(try await result.loadTracks(withMediaType: .audio).count == 1)
        #expect(try await Self.audioPeak(result, startingAt: 0.2) < 100)
        #expect(try await Self.audioPeak(result, startingAt: plan.clips[1].start + 0.2) > 1_000)
        let generator = AVAssetImageGenerator(asset: result)
        let first = try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        let last = try await generator.image(at: CMTime(seconds: plan.clips[1].start + 0.2, preferredTimescale: 600)).image
        #expect(try Self.edgeHasColor(first))
        #expect(try !Self.edgeHasColor(last))
    }

    @Test
    func passthroughRetainsCodecAndRotation() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await VideoResizeTests.makePortraitVideo(in: directory)
        let output = directory.appending(path: "joined.mov")
        var options = VideoMergeOptions()
        options.mode = .passthrough
        options.format = .mov
        options.keepsAudio = false
        let plan = try await VideoMerge.plan([source, source], options: options)
        #expect(plan.passthroughIssue == nil)
        _ = try await VideoMerge.export([source, source], to: output, options: options) { _ in }
        #expect(try await VideoResize.sourceSize(output) == CGSize(width: 64, height: 128))
        let asset = AVURLAsset(url: output)
        #expect(try await asset.load(.duration).seconds == plan.duration)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let formats = try await track.load(.formatDescriptions)
        #expect(CMFormatDescriptionGetMediaSubType(try #require(formats.first)) == kCMVideoCodecType_H264)
    }

    @Test
    func checksContainerCompatibilityForIdenticalStreamsBeforeExport() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let proRes = try await conversionFixture(in: directory)
        let inputs = [proRes, proRes]
        var options = VideoMergeOptions()
        options.mode = .passthrough
        options.keepsAudio = false
        options.format = .mp4
        let incompatible = try await VideoMerge.plan(inputs, options: options)
        #expect(incompatible.passthroughIssue == nil)
        #expect(incompatible.exportIssue?.contains("cannot be written as MP4") == true)
        let boundary = try await VideoMerge.previewBoundary(inputs, before: 1, options: options)
        #expect(boundary.before.width > 0)
        #expect(boundary.after.width > 0)
        let rejected = directory.appending(path: "unsupported.mp4")
        await #expect(throws: ToolError.self) {
            try await VideoMerge.export(inputs, to: rejected, options: options) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: rejected.path))

        options.format = .mov
        let compatible = try await VideoMerge.plan(inputs, options: options)
        #expect(compatible.exportIssue == nil)
        let output = directory.appending(path: "joined.mov")
        _ = try await VideoMerge.export(inputs, to: output, options: options) { _ in }
        let asset = AVURLAsset(url: output)
        #expect(try await asset.load(.isPlayable))
        #expect(abs(try await asset.load(.duration).seconds - compatible.duration) < 0.05)

        options.format = .mp4
        options.mode = .normalize
        let normalized = try await VideoMerge.plan(inputs, options: options)
        #expect(normalized.exportIssue == nil)
        let normalizedOutput = directory.appending(path: "normalized.mp4")
        _ = try await VideoMerge.export(inputs, to: normalizedOutput, options: options) { _ in }
        let rendered = AVURLAsset(url: normalizedOutput)
        #expect(try await rendered.load(.isPlayable))
        #expect(abs(try await rendered.load(.duration).seconds - normalized.duration) < 0.05)
    }

    @MainActor @Test
    func playbackTrimsBothSidesOfLongClips() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await VideoResizeTests.makePortraitVideo(in: directory, frameCount: 96)
        var options = VideoMergeOptions()
        options.mode = .passthrough
        options.keepsAudio = false
        let playback = try await VideoMerge.boundaryPlayback([source, source], before: 1, options: options)
        let track = try #require(try await playback.asset.loadTracks(withMediaType: .video).first)
        let segments = try await track.load(.segments).filter { !$0.isEmpty }
        #expect(segments.map { $0.timeMapping.source.start.seconds } == [2, 0])
        #expect(segments.map { $0.timeMapping.target.start.seconds } == [0, 2])
        #expect(segments.map { $0.timeMapping.target.duration.seconds } == [2, 2])
        #expect(try await playback.asset.loadTracks(withMediaType: .audio).isEmpty)
    }

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private static func attachAudio(to source: URL, in directory: URL) async throws -> URL {
        let audioFile = directory.appending(path: "tone.wav")
        do {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            let samples = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
            samples.frameLength = samples.frameCapacity
            let channel = try #require(samples.floatChannelData?.pointee)
            for index in 0..<48_000 {
                channel[index] = Float(0.4 * sin(2 * .pi * 440 * Double(index) / 48_000))
            }
            let writer = try AVAudioFile(forWriting: audioFile, settings: format.settings)
            try writer.write(from: samples)
        }
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: source)
        let audioAsset = AVURLAsset(url: audioFile)
        for (asset, type) in [(videoAsset, AVMediaType.video), (audioAsset, .audio)] {
            let sourceTrack = try #require(try await asset.loadTracks(withMediaType: type).first)
            let track = try #require(composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid))
            try await track.insertTimeRange(sourceTrack.load(.timeRange), of: sourceTrack, at: .zero)
            if type == .video { track.preferredTransform = try await sourceTrack.load(.preferredTransform) }
        }
        let destination = directory.appending(path: "withAudio.mov")
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await session.exportMedia(to: destination, as: .mov)
        return destination
    }

    private static func audioPeak(_ asset: AVAsset, startingAt seconds: Double) async throws -> Int {
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false
        ])
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 60_000),
                                       duration: CMTime(value: 1, timescale: 10))
        try #require(reader.startReading())
        var peak = 0
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var values = [Int16](repeating: 0, count: length / MemoryLayout<Int16>.size)
            let status = values.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
            }
            try #require(status == kCMBlockBufferNoErr)
            peak = max(peak, values.map { abs(Int($0)) }.max() ?? 0)
        }
        return peak
    }

    private static func edgeHasColor(_ frame: CGImage) throws -> Bool {
        let context = try #require(CGContext(data: nil, width: 16, height: 8, bitsPerComponent: 8,
                                             bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(frame, in: CGRect(x: 0, y: 0, width: 16, height: 8))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let edgeOffset = 2 * 64 + 2 * 4
        return (0..<3).contains { bytes[edgeOffset + $0] > 100 }
    }
}
