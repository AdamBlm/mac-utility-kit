import AVFoundation

enum AVFoundationVideoConversion {
    static func export(
        _ input: AVURLAsset, to output: URL, options: VideoConversionOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let (export, fileType) = try await preparedExport(input, options: options)
        let states = export.states(updateInterval: 0.2)
        let monitor = Task {
            for await state in states {
                guard !Task.isCancelled else { return }
                if case .exporting(let exportProgress) = state {
                    await progress(min(0.99, exportProgress.fractionCompleted))
                }
            }
        }
        defer { monitor.cancel() }
        try await export.exportMedia(to: output, as: fileType)
    }

    static func preparedExport(
        _ input: AVURLAsset, options: VideoConversionOptions
    ) async throws -> (AVAssetExportSession, AVFileType) {
        let videoTracks = try await input.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty, let fileType = options.format.nativeFileType else {
            throw ToolError.invalid("This file or format is unavailable for native video conversion.")
        }

        let asset: AVAsset
        if options.audio == .remove {
            let composition = AVMutableComposition()
            for source in videoTracks {
                try Task.checkCancellation()
                let timeRange = try await source.load(.timeRange)
                guard let track = composition.addMutableTrack(withMediaType: .video,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw ToolError.invalid("Could not create a video-only export.")
                }
                try track.insertTimeRange(timeRange, of: source, at: timeRange.start)
                track.preferredTransform = try await source.load(.preferredTransform)
            }
            asset = composition
        } else {
            asset = input
        }

        let preset: String
        switch options.mode {
        case .passthrough: preset = AVAssetExportPresetPassthrough
        case .transcode:
            preset = options.codec == .hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        }
        guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: fileType),
              let export = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ToolError.invalid("These streams are incompatible with the selected output. Try Transcode or another container.")
        }
        return (export, fileType)
    }

    static func summary(
        input: AVURLAsset, output: AVURLAsset, options: VideoConversionOptions
    ) async throws -> String {
        let tracks = try await output.load(.tracks)
        let video = tracks.filter { $0.mediaType == .video }
        guard !video.isEmpty, try await output.load(.isPlayable) else {
            throw ToolError.invalid("The conversion did not produce a playable video.")
        }
        var codecNames: [String] = []
        for track in video {
            for format in try await track.load(.formatDescriptions) {
                let name = codecName(CMFormatDescriptionGetMediaSubType(format))
                if !codecNames.contains(name) { codecNames.append(name) }
            }
        }
        if options.mode == .transcode, codecNames != [options.codec.title] {
            let actual = codecNames.isEmpty ? "unknown codec" : codecNames.joined(separator: ", ")
            throw ToolError.invalid("The encoder produced \(actual) instead of \(options.codec.title). Try another encoder or container.")
        }
        let audio = tracks.filter { $0.mediaType == .audio }
        if options.audio == .remove, !audio.isEmpty {
            throw ToolError.invalid("The output still contains an audio track.")
        }
        let sourceTracks = (try? await input.load(.tracks)) ?? []
        var details = [options.format.title] + codecNames
        if !audio.isEmpty {
            var audioCodecs: [String] = []
            for track in audio {
                for format in try await track.load(.formatDescriptions) {
                    let name = codecName(CMFormatDescriptionGetMediaSubType(format))
                    if !audioCodecs.contains(name) { audioCodecs.append(name) }
                }
            }
            details.append(audioCodecs.isEmpty ? "\(audio.count) audio track(s)" : audioCodecs.joined(separator: ", "))
        }
        if !sourceTracks.isEmpty {
            for type in Set(sourceTracks.map(\.mediaType)).sorted(by: { $0.rawValue < $1.rawValue }) {
                let name: String
                switch type {
                case .audio: name = "audio"
                case .video: name = "video"
                case .text, .subtitle, .closedCaption: name = "subtitle or caption"
                default: name = "other"
                }
                let difference = sourceTracks.filter { $0.mediaType == type }.count
                    - tracks.filter { $0.mediaType == type }.count
                if difference > 0 {
                    details.append("\(difference) \(name) track\(difference == 1 ? "" : "s") dropped")
                }
            }
        }
        return details.joined(separator: " · ")
    }

    private static func codecName(_ value: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
        let label = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        switch label {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "mp4a", "aac": return "AAC"
        case "Opus": return "Opus"
        default: return label.isEmpty ? "Unknown codec" : label
        }
    }
}
