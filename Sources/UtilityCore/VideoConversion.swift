import AVFoundation

public enum VideoConversion {
    public static func checkPassthrough(_ input: URL, options: VideoConversionOptions) async throws {
        try options.validate()
        guard options.mode == .passthrough else { return }
        guard input.isFileURL else { throw ToolError.invalid("Choose a local video file.") }
        if let executable = options.ffmpegExecutable {
            try await FFmpegVideoConversion.checkPassthrough(input, options: options, executable: executable)
        } else {
            _ = try await AVFoundationVideoConversion.preparedExport(asset(at: input), options: options)
        }
    }

    private static func asset(at input: URL) -> AVURLAsset {
        AVURLAsset(url: input, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)
        ])
    }

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
        let asset = asset(at: input)
        let summary: String
        if let executable = options.ffmpegExecutable {
            if let report = try await FFmpegVideoConversion.export(input, to: output, options: options, executable: executable) {
                summary = report
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
}
