import AVFoundation

enum VideoOperations {
    static func sample(_ input: URL, destination: URL, options: ToolOptions) async throws -> VideoSample {
        let folder = destination.appendingPathComponent("Video Sample - " + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let output = folder.appendingPathComponent("Preview." + options.videoFormat.rawValue)
        do {
            try await compress(input, output: output, options: options, sample: true) { _ in }
            let originalDuration = try await AVURLAsset(url: input).load(.duration).seconds
            let sampleDuration = if options.videoFormat == .webm {
                min(originalDuration, 5)
            } else {
                try await AVURLAsset(url: output).load(.duration).seconds
            }
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
    ) async throws {
        let asset = AVURLAsset(url: input)
        try VideoCompression.validate(options)
        if let executable = options.ffmpegExecutable {
            let source = try await VideoCompression.source(asset, options: options)
            try await FFmpegEncoding.export(input, to: output, using: executable, source: source, options: options, sample: sample)
            if options.videoFormat == .webm {
                try await FFmpegEncoding.verifyWebM(output, source: source, using: executable)
            } else {
                let outputAsset = AVURLAsset(url: output)
                guard let result = try await outputAsset.loadTracks(withMediaType: .video).first,
                      try await result.load(.naturalSize) == source.size else {
                    throw ToolError.invalid("FFmpeg did not produce the selected resolution.")
                }
                let transform = try await result.load(.preferredTransform)
                let original = source.transform
                guard [transform.a, transform.b, transform.c, transform.d] == [original.a, original.b, original.c, original.d],
                      source.size != source.naturalSize || transform == original else {
                    throw ToolError.invalid("FFmpeg could not preserve the source orientation.")
                }
            }
            await progress(1)
        } else {
            try await AVFoundationEncoding.export(asset, to: output, options: options, sample: sample, progress: progress)
        }
    }
}
