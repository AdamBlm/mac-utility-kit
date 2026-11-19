import AVFoundation

public enum VideoMerge {
    public static func plan(_ inputs: [URL], options: VideoMergeOptions) async throws -> VideoMergePlan {
        let prepared = try await prepare(inputs, options: options)
        var plan = prepared.plan
        if options.mode == .passthrough, let issue = plan.passthroughIssue {
            plan.exportIssue = issue
        } else {
            let timeline = try build(prepared, options: options)
            do {
                _ = try await configuredExport(timeline, options: options)
            } catch {
                try Task.checkCancellation()
                plan.exportIssue = error.localizedDescription
            }
        }
        return plan
    }

    public static func previewBoundary(
        _ inputs: [URL], before index: Int, options: VideoMergeOptions
    ) async throws -> VideoMergeBoundaryPreview {
        let prepared = try await prepare(inputs, options: options)
        guard index > 0, index < prepared.clips.count else {
            throw ToolError.invalid("Choose a boundary between two clips.")
        }
        if options.mode == .passthrough, let issue = prepared.plan.passthroughIssue {
            throw ToolError.invalid(issue)
        }
        let timeline = try build(prepared, options: options)
        let generator = AVAssetImageGenerator(asset: timeline.composition)
        generator.maximumSize = CGSize(width: 360, height: 220)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = options.mode == .passthrough
        generator.videoComposition = timeline.videoComposition

        let previous = prepared.clips[index - 1]
        let next = prepared.clips[index]
        let boundary = prepared.starts[index]
        let before = min(previous.range.duration.seconds / 2, 0.1)
        let after = min(next.range.duration.seconds / 2, 0.1)
        let left = try await generator.image(at: boundary - CMTime(seconds: before, preferredTimescale: 60_000)).image
        try Task.checkCancellation()
        let right = try await generator.image(at: boundary + CMTime(seconds: after, preferredTimescale: 60_000)).image
        return VideoMergeBoundaryPreview(before: left, after: right)
    }

    @MainActor
    package static func boundaryPlayback(
        _ inputs: [URL], before index: Int, options: VideoMergeOptions
    ) async throws -> AVPlayerItem {
        let prepared = try await prepare(inputs, options: options)
        guard index > 0, index < prepared.clips.count else {
            throw ToolError.invalid("Choose a boundary between two clips.")
        }
        if options.mode == .passthrough, let issue = prepared.plan.passthroughIssue {
            throw ToolError.invalid(issue)
        }
        let boundary = prepared.starts[index]
        let lead = min(prepared.clips[index - 1].range.duration, CMTime(value: 2, timescale: 1))
        let tail = min(prepared.clips[index].range.duration, CMTime(value: 2, timescale: 1))
        let window = CMTimeRange(start: boundary - lead, duration: lead + tail)
        let timeline = try build(prepared, options: options, window: window)
        let item = AVPlayerItem(asset: timeline.composition)
        item.videoComposition = timeline.videoComposition
        return item
    }

    public static func export(
        _ inputs: [URL], to output: URL, options: VideoMergeOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        let manager = FileManager.default
        guard output.isFileURL, !manager.fileExists(atPath: output.path),
              !inputs.contains(where: { $0.standardizedFileURL == output.standardizedFileURL }) else {
            throw ToolError.invalid("Choose a new local output file.")
        }
        let prepared = try await prepare(inputs, options: options)
        if options.mode == .passthrough, let issue = prepared.plan.passthroughIssue {
            throw ToolError.invalid(issue)
        }
        let timeline = try build(prepared, options: options)
        let fileType = options.format.fileType
        let export = try await configuredExport(timeline, options: options)

        let staging = output.deletingLastPathComponent().appending(path: ".video-merge-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let candidate = staging.appending(path: "Merged.\(options.format.rawValue)")
        let states = export.states(updateInterval: 0.2)
        let monitor = Task {
            for await state in states {
                guard !Task.isCancelled else { return }
                if case .exporting(let value) = state { await progress(min(0.99, value.fractionCompleted)) }
            }
        }
        defer { monitor.cancel() }
        try Task.checkCancellation()
        try await export.exportMedia(to: candidate, as: fileType)
        try await verify(candidate, options: options, prepared: prepared)
        try Task.checkCancellation()
        try manager.moveItem(at: candidate, to: output)
        await progress(1)
        return "\(inputs.count) clips · \(options.format.title) · \(options.mode.rawValue)"
    }

    private typealias Timeline = (composition: AVMutableComposition, videoComposition: AVMutableVideoComposition?)

    private static func configuredExport(_ timeline: Timeline, options: VideoMergeOptions) async throws -> AVAssetExportSession {
        let fileType = options.format.fileType
        let preset = options.mode == .passthrough ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
        let compatible = await AVAssetExportSession.compatibility(ofExportPreset: preset, with: timeline.composition,
                                                                  outputFileType: fileType)
        try Task.checkCancellation()
        guard compatible, let export = AVAssetExportSession(asset: timeline.composition, presetName: preset),
              export.supportedFileTypes.contains(fileType) else {
            throw ToolError.invalid("These streams cannot be written as \(options.format.title) with the selected method.")
        }
        export.videoComposition = timeline.videoComposition
        export.shouldOptimizeForNetworkUse = true
        return export
    }

    private struct Clip {
        let url: URL
        let asset: AVURLAsset
        let video: AVAssetTrack
        let audio: AVAssetTrack?
        let range: CMTimeRange
        let audioRange: CMTimeRange?
        let orientation: CGAffineTransform
        let bounds: CGRect
        let videoFormats: [CMFormatDescription]
        let audioFormats: [CMFormatDescription]
    }

    private struct Prepared {
        let clips: [Clip]
        let starts: [CMTime]
        let plan: VideoMergePlan
    }

    private static func prepare(_ inputs: [URL], options: VideoMergeOptions) async throws -> sending Prepared {
        guard inputs.count >= 2 else { throw ToolError.invalid("Add two or more clips to merge.") }
        var clips: [Clip] = []
        var starts: [CMTime] = []
        var cursor = CMTime.zero
        for input in inputs {
            try Task.checkCancellation()
            let clip = try await load(input, keepsAudio: options.keepsAudio)
            starts.append(cursor)
            clips.append(clip)
            cursor = cursor + clip.range.duration
        }
        let first = clips[0]
        let size = options.mode == .passthrough ? first.bounds.size : options.resolution.size(fallback: first.bounds.size)
        if options.mode == .normalize, (size.width > 4096 || size.height > 4096) {
            throw ToolError.invalid("Choose a common resolution no larger than 4096 pixels per side.")
        }
        let issue = clips.dropFirst()
            .first { !matchesStreams($0, first) }
            .map { "\($0.url.lastPathComponent) has different video or audio settings. Select Normalize." }
        let entries = zip(clips, starts).map { clip, start in
            VideoMergePlan.Clip(url: clip.url, start: start.seconds, duration: clip.range.duration.seconds,
                                sizesDiffer: clip.bounds.size != size, hasDifferentSettings: !matchesStreams(clip, first),
                                hasAudio: clip.audio != nil)
        }
        let plan = VideoMergePlan(clips: entries, duration: cursor.seconds, size: size, passthroughIssue: issue)
        return Prepared(clips: clips, starts: starts, plan: plan)
    }

    private static func matchesStreams(_ clip: Clip, _ reference: Clip) -> Bool {
        clip.orientation == reference.orientation && clip.bounds.size == reference.bounds.size
            && clip.videoFormats == reference.videoFormats && clip.audioFormats == reference.audioFormats
    }

    private static func asset(_ url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
    }

    private static func load(_ url: URL, keepsAudio: Bool) async throws -> Clip {
        guard url.isFileURL else { throw ToolError.invalid("Choose local video files.") }
        let source = asset(url)
        var video: AVAssetTrack?
        var audio: AVAssetTrack?
        for track in try await source.load(.tracks) {
            if track.mediaType == .video, video == nil, try await track.load(.isEnabled) { video = track }
            if keepsAudio, track.mediaType == .audio, audio == nil, try await track.load(.isEnabled) { audio = track }
        }
        guard let video else { throw ToolError.invalid("\(url.lastPathComponent) has no enabled video track.") }
        let (range, naturalSize, orientation, videoFormats) = try await video.load(
            .timeRange, .naturalSize, .preferredTransform, .formatDescriptions
        )
        let bounds = CGRect(origin: .zero, size: naturalSize).applying(orientation).standardized
        guard range.duration.isNumeric, range.duration > .zero, !videoFormats.isEmpty,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw ToolError.invalid("\(url.lastPathComponent) has invalid video timing or dimensions.")
        }
        if let audio {
            let (audioRange, formats) = try await audio.load(.timeRange, .formatDescriptions)
            let overlap = audioRange.intersection(range)
            if !overlap.isEmpty, !formats.isEmpty {
                return Clip(url: url, asset: source, video: video, audio: audio, range: range, audioRange: overlap,
                            orientation: orientation, bounds: bounds, videoFormats: videoFormats, audioFormats: formats)
            }
        }
        return Clip(url: url, asset: source, video: video, audio: nil, range: range, audioRange: nil,
                    orientation: orientation, bounds: bounds, videoFormats: videoFormats, audioFormats: [])
    }

    private static func build(
        _ prepared: Prepared, options: VideoMergeOptions, window: CMTimeRange? = nil
    ) throws -> Timeline {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ToolError.invalid("Could not create the merged video track.")
        }
        let first = prepared.clips[0]
        var audio: AVMutableCompositionTrack?

        let canvas = prepared.plan.size
        var instructions: [AVMutableVideoCompositionInstruction] = []
        for (clip, start) in zip(prepared.clips, prepared.starts) {
            try Task.checkCancellation()
            let position = CMTimeRange(start: start, duration: clip.range.duration)
            let visible = window.map { position.intersection($0) } ?? position
            guard !visible.isEmpty else { continue }
            let destination = visible.start - (window?.start ?? .zero)
            let sourceRange = CMTimeRange(start: clip.range.start + (visible.start - start), duration: visible.duration)
            try video.insertTimeRange(sourceRange, of: clip.video, at: destination)
            if let source = clip.audio, let original = clip.audioRange {
                let range = original.intersection(sourceRange)
                if !range.isEmpty {
                    if audio == nil {
                        audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    }
                    guard let audio else { throw ToolError.invalid("Could not create the merged audio track.") }
                    try audio.insertTimeRange(range, of: source, at: destination + (range.start - sourceRange.start))
                }
            }
            if options.mode == .normalize {
                let range = CMTimeRange(start: destination, duration: visible.duration)
                instructions.append(instruction(for: clip, canvas: canvas, video: video, range: range))
            }
        }
        if options.mode == .passthrough {
            video.preferredTransform = first.orientation
            return (composition, nil)
        }
        let render = AVMutableVideoComposition()
        render.frameDuration = CMTime(value: 1, timescale: 30)
        render.sourceTrackIDForFrameTiming = video.trackID
        render.renderSize = canvas
        render.instructions = instructions
        return (composition, render)
    }

    private static func instruction(
        for clip: Clip, canvas: CGSize, video: AVMutableCompositionTrack, range: CMTimeRange
    ) -> AVMutableVideoCompositionInstruction {
        let fit = min(canvas.width / clip.bounds.width, canvas.height / clip.bounds.height)
        let x = (canvas.width - clip.bounds.width * fit) / 2
        let y = (canvas.height - clip.bounds.height * fit) / 2
        let transform = clip.orientation
            .concatenating(CGAffineTransform(translationX: -clip.bounds.minX, y: -clip.bounds.minY))
            .concatenating(CGAffineTransform(scaleX: fit, y: fit))
            .concatenating(CGAffineTransform(translationX: x, y: y))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
        layer.setTransform(transform, at: range.start)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = range
        instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
        instruction.layerInstructions = [layer]
        return instruction
    }

    private static func verify(_ url: URL, options: VideoMergeOptions, prepared: Prepared) async throws {
        let output = asset(url)
        let clip = try await load(url, keepsAudio: true)
        let expectsAudio = prepared.clips.contains { $0.audio != nil }
        let videoDuration = clip.range.duration.seconds
        guard try await output.load(.isPlayable),
              abs(videoDuration - prepared.plan.duration) <= 0.15,
              clip.bounds.size == prepared.plan.size,
              (clip.audio != nil) == expectsAudio else {
            throw ToolError.invalid("The merged file did not match the selected duration, dimensions or audio policy.")
        }
        if options.mode == .passthrough {
            let first = prepared.clips[0]
            guard clip.videoFormats.first?.mediaSubType == first.videoFormats.first?.mediaSubType,
                  clip.audioFormats.first?.mediaSubType == first.audioFormats.first?.mediaSubType else {
                throw ToolError.invalid("The merged file did not retain the source codecs.")
            }
        }
    }
}
