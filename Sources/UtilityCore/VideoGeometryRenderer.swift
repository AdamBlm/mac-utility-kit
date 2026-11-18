import AVFoundation

struct VideoGeometryLayout: Sendable {
    let size: CGSize
    let displayedTransform: CGAffineTransform
}

enum VideoGeometryRenderer {
    static func sourceSize(_ input: URL) async throws -> CGSize {
        try await loadSource(input).bounds.size
    }

    static func preview(
        _ input: URL, layout plan: @Sendable (CGSize) throws -> VideoGeometryLayout
    ) async throws -> CGImage {
        let source = try await loadSource(input)
        let layout = try plan(source.bounds.size)
        let generator = AVAssetImageGenerator(asset: source.asset)
        let scale = min(1, 640 / layout.size.width, 360 / layout.size.height)
        generator.videoComposition = composition(for: source, layout: layout, scale: scale)
        let range = try await source.track.load(.timeRange)
        let time = range.start + CMTimeMultiplyByFloat64(range.duration, multiplier: 0.25)
        try Task.checkCancellation()
        return try await generator.image(at: time).image
    }

    static func export(
        _ input: URL, to output: URL, layout plan: @Sendable (CGSize) throws -> VideoGeometryLayout,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        guard input.isFileURL, output.isFileURL,
              input.standardizedFileURL != output.standardizedFileURL,
              !FileManager.default.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a new local output file.")
        }
        let source = try await loadSource(input)
        let layout = try plan(source.bounds.size)
        let videoComposition = composition(for: source, layout: layout)
        try Task.checkCancellation()

        let manager = FileManager.default
        let staging = output.deletingLastPathComponent().appending(path: ".video-render-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let candidate = staging.appending(path: "Rendered.mp4")
        guard let export = AVAssetExportSession(asset: source.asset, presetName: AVAssetExportPresetHighestQuality),
              export.supportedFileTypes.contains(.mp4) else {
            throw ToolError.invalid("This video cannot be rendered and exported as MP4.")
        }
        export.videoComposition = videoComposition
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
        let result = try await loadSource(candidate)
        let encoded = try await result.track.load(.naturalSize)
        let resultAudio = try await result.asset.loadTracks(withMediaType: .audio)
        guard encoded == layout.size, result.bounds.size == layout.size,
              !source.hasAudio || !resultAudio.isEmpty, try await result.asset.load(.isPlayable) else {
            throw ToolError.invalid("The exported MP4 did not match the requested dimensions or media tracks.")
        }
        try Task.checkCancellation()
        try manager.moveItem(at: candidate, to: output)
        await progress(1)
        return "\(input.lastPathComponent) · \(Int(layout.size.width)) × \(Int(layout.size.height)) · MP4"
    }

    private struct Source {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let orientation: CGAffineTransform
        let bounds: CGRect
        let duration: CMTime
        let frameDuration: CMTime
        let hasAudio: Bool
    }

    private static func loadSource(_ input: URL) async throws -> Source {
        guard input.isFileURL else { throw ToolError.invalid("Choose a local video file.") }
        let asset = AVURLAsset(url: input, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        let (duration, tracks) = try await asset.load(.duration, .tracks)
        var primaryVideo: AVAssetTrack?
        var hasAudio = false
        for track in tracks where track.mediaType == .video || track.mediaType == .audio {
            if try await track.load(.isEnabled) {
                if track.mediaType == .video, primaryVideo == nil { primaryVideo = track }
                if track.mediaType == .audio { hasAudio = true }
            }
        }
        guard let track = primaryVideo else { throw ToolError.invalid("The file has no enabled video track.") }
        let (size, orientation, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let bounds = CGRect(origin: .zero, size: size).applying(orientation).standardized
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
              duration.isNumeric, duration > .zero else {
            throw ToolError.invalid("Could not read the displayed video dimensions or duration.")
        }
        let fps = rate.isFinite && rate > 0 ? Double(rate) : 30
        return Source(asset: asset, track: track, orientation: orientation, bounds: bounds,
                      duration: duration, frameDuration: CMTime(seconds: 1 / fps, preferredTimescale: 60_000),
                      hasAudio: hasAudio)
    }

    private static func composition(
        for source: Source, layout: VideoGeometryLayout, scale: CGFloat = 1
    ) -> AVMutableVideoComposition {
        let transform = source.orientation
            .concatenating(CGAffineTransform(translationX: -source.bounds.minX, y: -source.bounds.minY))
            .concatenating(layout.displayedTransform)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: source.track)
        layer.setTransform(transform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: source.duration)
        instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: max(2, (layout.size.width * scale).rounded()),
                                        height: max(2, (layout.size.height * scale).rounded()))
        composition.frameDuration = source.frameDuration
        composition.sourceTrackIDForFrameTiming = source.track.trackID
        composition.instructions = [instruction]
        return composition
    }
}
