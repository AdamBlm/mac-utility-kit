import AVFoundation

enum VideoOperations {
    static func sample(_ input: URL, destination: URL, options: ToolOptions) async throws -> VideoSample {
        let folder = destination.appendingPathComponent("Video Sample - " + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let output = folder.appendingPathComponent("Preview." + options.videoFormat.rawValue)
        do {
            _ = try await compress(input, output: output, options: options, sample: true) { _ in }
            let originalDuration = try await AVURLAsset(url: input).load(.duration).seconds
            let sampleDuration = try await AVURLAsset(url: output).load(.duration).seconds
            let bytes = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize
            let estimate = bytes.flatMap { size -> Int64? in
                guard originalDuration.isFinite, sampleDuration.isFinite, sampleDuration > 0 else { return nil }
                return Int64(exactly: (Double(size) * originalDuration / sampleDuration).rounded())
            }
            return VideoSample(url: output, estimatedBytes: estimate)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    static func compress(
        _ input: URL, output: URL, options: ToolOptions, sample: Bool = false, progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        let asset = AVURLAsset(url: input)
        if let executable = options.ffmpegExecutable {
            try await FFmpegEncoding.export(input, to: output, using: executable, options: options, sample: sample)
            let outputAsset = AVURLAsset(url: output)
            guard let source = try await asset.loadTracks(withMediaType: .video).first,
                  let result = try await outputAsset.loadTracks(withMediaType: .video).first,
                  try await source.load(.naturalSize) == result.load(.naturalSize),
                  try await source.load(.preferredTransform) == result.load(.preferredTransform) else {
                throw ToolError.invalid("FFmpeg could not preserve the source resolution and orientation.")
            }
            await progress(1)
        } else {
            try await AVFoundationEncoding.export(asset, to: output, options: options, sample: sample, progress: progress)
        }
        if sample { return output.lastPathComponent }
        let sourceSize = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let outputSize = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if let sourceSize, let outputSize, outputSize >= sourceSize, !options.keepLargerVideos {
            throw ToolError.invalid("The export is not smaller. Enable Keep exports that are not smaller to retain it.")
        }
        guard let sourceSize, let outputSize, sourceSize > 0 else { return input.lastPathComponent }
        let change = Double(sourceSize - outputSize) / Double(sourceSize)
        let description = abs(change).formatted(.percent.precision(.fractionLength(1)))
            + (change >= 0 ? " saved" : " larger")
        return "\(input.lastPathComponent) • \(ByteCountFormatter.string(fromByteCount: Int64(sourceSize), countStyle: .file)) → \(ByteCountFormatter.string(fromByteCount: Int64(outputSize), countStyle: .file)) • \(description)"
    }
}
