import AVFoundation

public enum VideoConversion {
    public static func convert(
        _ input: URL, to output: URL, options: VideoConversionOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        try options.validate()
        guard input.isFileURL, output.isFileURL, input.standardizedFileURL != output.standardizedFileURL else {
            throw ToolError.invalid("Choose a separate local output file.")
        }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose an output file that does not already exist.")
        }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: input, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)
        ])
        let summary: String
        if let executable = options.ffmpegExecutable {
            try await FFmpegVideoConversion.export(input, to: output, options: options, executable: executable)
            if options.format == .webm {
                summary = await webMSummary(asset: asset, options: options)
            } else {
                summary = try await AVFoundationVideoConversion.summary(
                    input: asset, output: AVURLAsset(url: output), options: options
                )
            }
        } else {
            try await AVFoundationVideoConversion.export(asset, to: output, options: options, progress: progress)
            summary = try await AVFoundationVideoConversion.summary(
                input: asset, output: AVURLAsset(url: output), options: options
            )
        }
        try Task.checkCancellation()
        await progress(1)
        return "\(input.lastPathComponent) · \(summary)"
    }

    private static func webMSummary(asset: AVURLAsset, options: VideoConversionOptions) async -> String {
        let inputTypes = (try? await asset.load(.tracks).map(\.mediaType)) ?? []
        let codecs = options.mode == .transcode ? "VP9 video verified" : "Copied streams · First video frame decoded"
        var summary = "WebM · \(codecs)"
        if options.audio == .remove { summary += " · Audio excluded" }
        if options.mode == .transcode {
            if inputTypes.contains(where: { $0 != .video && $0 != .audio })
                || inputTypes.filter({ $0 == .video }).count > 1 {
                summary += " · Extra video, subtitle and data tracks excluded"
            } else if inputTypes.isEmpty {
                summary += " · Excludes additional video, subtitle and data tracks"
            }
        }
        return summary
    }
}
