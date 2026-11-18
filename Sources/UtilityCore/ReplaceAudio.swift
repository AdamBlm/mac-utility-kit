import AVFoundation
import Foundation

public struct ReplaceAudioOptions: Equatable, Sendable {
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case replace = "Replace soundtrack", mix = "Mix with original"
        public var id: Self { self }
    }

    public enum DurationPolicy: String, CaseIterable, Identifiable, Sendable {
        case keepVideo = "Keep video duration"
        case loop = "Loop new audio"
        case shortest = "Trim video to audio"
        public var id: Self { self }
    }

    public var source: URL?
    public var sourceTrackIndex = 0
    public var originalTracks: [URL: Int] = [:]
    public var mode = Mode.replace
    public var durationPolicy = DurationPolicy.keepVideo
    public var offsetSeconds = 0.0
    public var originalVolume = 0.5
    public var newVolume = 1.0

    public init() {}
}

public enum ReplaceAudio {
    public enum Preview: String, CaseIterable, Identifiable, Sendable {
        case original = "Original", result = "Result"
        public var id: Self { self }
    }

    public struct Sample: Sendable {
        public let data: Data
        public let peak: Float
        public let startSeconds: Double

        public var isNearClipping: Bool { peak >= 0.99 }
    }

    public static func export(
        _ input: URL, to output: URL, options: ReplaceAudioOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        guard output.isFileURL, output.standardizedFileURL != input.standardizedFileURL,
              !FileManager.default.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a new local output file.")
        }
        let graph = try await makeGraph(input, options: options, preview: nil)
        let manager = FileManager.default
        let staging = output.deletingLastPathComponent().appending(path: ".audio-mix-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let candidate = staging.appending(path: "Mixed.mp4")
        guard let export = AVAssetExportSession(asset: graph.composition, presetName: AVAssetExportPresetHighestQuality),
              export.supportedFileTypes.contains(.mp4) else {
            throw ToolError.invalid("The selected tracks cannot be exported as MP4.")
        }
        export.audioMix = graph.mix
        export.shouldOptimizeForNetworkUse = true
        let states = export.states(updateInterval: 0.2)
        let monitor = Task {
            for await state in states {
                guard !Task.isCancelled else { return }
                if case .exporting(let value) = state { await progress(min(0.99, value.fractionCompleted)) }
            }
        }
        defer { monitor.cancel() }
        try await export.export(to: candidate, as: .mp4)
        let asset = try localAsset(candidate)
        let (tracks, playable, duration) = try await asset.load(.tracks, .isPlayable, .duration)
        guard playable, tracks.contains(where: { $0.mediaType == .video }),
              tracks.contains(where: { $0.mediaType == .audio }),
              abs(duration.seconds - graph.duration.seconds) < 0.12 else {
            throw ToolError.invalid("The exported file did not contain the expected video and audio duration.")
        }
        try Task.checkCancellation()
        try manager.moveItem(at: candidate, to: output)
        await progress(1)
        return "\(input.lastPathComponent) · \(options.mode.rawValue) · \(duration.seconds.formatted(.number.precision(.fractionLength(2)))) s · MP4"
    }

    public static func sample(_ input: URL, options: ReplaceAudioOptions, preview: Preview) async throws -> Sample {
        let graph = try await makeGraph(input, options: options, preview: preview)
        let firstSound = min(max(0, options.offsetSeconds), graph.duration.seconds)
        let start = min(max(0, firstSound - 0.5), max(0, graph.duration.seconds - 1))
        let width = min(5, graph.duration.seconds - start)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000),
                                duration: CMTime(seconds: width, preferredTimescale: 48_000))
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appending(path: ".MacUtilityKit-AudioPreview-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: folder) }
        let output = folder.appending(path: "Sample.m4a")
        guard let export = AVAssetExportSession(asset: graph.composition, presetName: AVAssetExportPresetAppleM4A),
              export.supportedFileTypes.contains(.m4a) else {
            throw ToolError.invalid("These tracks cannot be previewed.")
        }
        export.audioMix = graph.mix
        export.timeRange = range
        let peak = try await samplePeak(graph, within: range)
        try Task.checkCancellation()
        try await export.export(to: output, as: .m4a)
        try Task.checkCancellation()
        return Sample(data: try Data(contentsOf: output), peak: peak, startSeconds: start)
    }

    private struct Graph {
        let composition: AVMutableComposition
        let mix: AVMutableAudioMix
        let duration: CMTime
        let audioTracks: [AVMutableCompositionTrack]
    }

    private static func makeGraph(
        _ input: URL, options: ReplaceAudioOptions, preview: Preview?
    ) async throws -> Graph {
        guard let replacement = options.source else { throw ToolError.invalid("Choose an audio file.") }
        guard options.offsetSeconds.isFinite, abs(options.offsetSeconds) <= 86_400,
              (0...1).contains(options.originalVolume), (0...1).contains(options.newVolume) else {
            throw ToolError.invalid("Choose volumes from 0% to 100% and an offset within 24 hours.")
        }
        let videoAsset = try localAsset(input)
        let soundtrack = try localAsset(replacement)
        let sourceTracks = try await soundtrack.loadTracks(withMediaType: .audio)
        guard sourceTracks.indices.contains(options.sourceTrackIndex) else {
            throw ToolError.invalid("The selected replacement track is unavailable.")
        }
        let source = sourceTracks[options.sourceTrackIndex]
        let sourceRange = try await source.load(.timeRange)
        guard let video = try await enabledVideo(in: videoAsset) else {
            throw ToolError.invalid("Choose a file with a video track.")
        }
        let videoRange = try await video.load(.timeRange)
        guard sourceRange.duration.isNumeric, sourceRange.duration > .zero,
              videoRange.duration.isNumeric, videoRange.duration > .zero else {
            throw ToolError.invalid("The track has no readable duration.")
        }
        let offset = CMTime(seconds: options.offsetSeconds, preferredTimescale: 48_000)
        let duration = options.durationPolicy == .shortest ? min(videoRange.duration, offset + sourceRange.duration) : videoRange.duration
        guard duration > .zero, offset < duration,
              options.durationPolicy == .loop || offset + sourceRange.duration > .zero else {
            throw ToolError.invalid("The new audio does not overlap the video at this offset.")
        }
        let composition = AVMutableComposition()
        if preview == nil {
            let newVideo = try addTrack(to: composition, type: .video)
            try newVideo.insertTimeRange(CMTimeRange(start: videoRange.start, duration: duration), of: video, at: .zero)
            newVideo.preferredTransform = try await video.load(.preferredTransform)
        }
        var audio: [AVMutableCompositionTrack] = []
        var parameters: [AVAudioMixInputParameters] = []
        if preview == .original || options.mode == .mix {
            let tracks = try await videoAsset.loadTracks(withMediaType: .audio)
            let selection = options.originalTracks[input, default: 0]
            guard tracks.indices.contains(selection) else {
                throw ToolError.invalid(tracks.isEmpty ? "This video has no original audio track to use." : "The selected original audio track is unavailable.")
            }
            let original = tracks[selection]
            let originalRange = try await original.load(.timeRange)
                .intersection(CMTimeRange(start: videoRange.start, duration: duration))
            guard !originalRange.isEmpty else { throw ToolError.invalid("The original audio does not overlap the video.") }
            let target = try addTrack(to: composition, type: .audio)
            try target.insertTimeRange(originalRange, of: original, at: originalRange.start - videoRange.start)
            let levels = AVMutableAudioMixInputParameters(track: target)
            levels.setVolume(preview == .original ? 1 : Float(options.originalVolume), at: .zero)
            audio.append(target)
            parameters.append(levels)
        }
        if preview != .original {
            let target = try addTrack(to: composition, type: .audio)
            try place(source, range: sourceRange, on: target, offset: offset, duration: duration,
                      repeats: options.durationPolicy == .loop)
            let levels = AVMutableAudioMixInputParameters(track: target)
            levels.setVolume(Float(options.newVolume), at: .zero)
            audio.append(target)
            parameters.append(levels)
        }
        if preview != nil, composition.duration < duration {
            let end = composition.duration
            composition.insertEmptyTimeRange(CMTimeRange(start: end, end: duration))
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return Graph(composition: composition, mix: mix, duration: duration, audioTracks: audio)
    }

    private static func place(
        _ source: AVAssetTrack, range: CMTimeRange, on target: AVMutableCompositionTrack,
        offset: CMTime, duration: CMTime, repeats: Bool
    ) throws {
        var cursor = max(.zero, offset)
        var skip = max(.zero, .zero - offset)
        if repeats, skip >= range.duration {
            skip = CMTime(seconds: skip.seconds.truncatingRemainder(dividingBy: range.duration.seconds), preferredTimescale: 48_000)
        }
        let length = range.duration - skip
        guard length > .zero, !repeats || (duration - cursor).seconds / range.duration.seconds <= 10_000 else {
            throw ToolError.invalid("The audio is too short to loop over this video.")
        }
        repeat {
            try Task.checkCancellation()
            let segment = min(duration - cursor, range.duration - skip)
            try target.insertTimeRange(CMTimeRange(start: range.start + skip, duration: segment), of: source, at: cursor)
            cursor = cursor + segment
            skip = .zero
        } while repeats && cursor < duration
    }

    private static func samplePeak(_ graph: Graph, within range: CMTimeRange) async throws -> Float {
        let reader = try AVAssetReader(asset: graph.composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: graph.audioTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = graph.mix
        guard reader.canAdd(output) else { throw ToolError.invalid("Could not measure the preview audio level.") }
        reader.add(output)
        reader.timeRange = range
        guard reader.startReading() else { throw reader.error ?? ToolError.invalid("Could not measure the preview audio level.") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var peak: Float = 0
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let data = buffer.dataBuffer else { continue }
            var samples = [Float](repeating: 0, count: CMBlockBufferGetDataLength(data) / MemoryLayout<Float>.size)
            guard !samples.isEmpty else { continue }
            let status = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw ToolError.invalid("Could not read the preview audio level.") }
            for sample in samples where sample.isFinite { peak = max(peak, abs(sample)) }
        }
        if let error = reader.error { throw error }
        return peak
    }

    private static func addTrack(to composition: AVMutableComposition, type: AVMediaType) throws -> AVMutableCompositionTrack {
        guard let track = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ToolError.invalid("Could not construct the video and audio timeline.")
        }
        return track
    }

    private static func enabledVideo(in asset: AVURLAsset) async throws -> AVAssetTrack? {
        for track in try await asset.loadTracks(withMediaType: .video) {
            if try await track.load(.isEnabled) { return track }
        }
        return nil
    }

    private static func localAsset(_ url: URL) throws -> AVURLAsset {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ToolError.invalid("Choose a readable local media file.")
        }
        return AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
    }
}
