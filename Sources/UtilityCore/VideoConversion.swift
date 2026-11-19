import AVFoundation

public enum VideoConversion {
    public static func checkWebMPassthrough(_ input: URL, audio: VideoConversionAudio, executable: URL) async throws {
        guard input.isFileURL else { throw ToolError.invalid("Choose a local video file.") }
        try await FFmpegVideoConversion.checkWebMPassthrough(input, audio: audio, executable: executable)
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
        let asset = AVURLAsset(url: input, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)
        ])
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
