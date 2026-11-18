import Foundation

public enum AudioTrimFormat: String, CaseIterable, Identifiable, Sendable {
    case wav, aiff, m4a
    public var id: Self { self }
    public var title: String {
        switch self {
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .m4a: "M4A (AAC)"
        }
    }

    static func pcmContainer(for url: URL) -> Self? {
        switch url.pathExtension.lowercased() {
        case "wav", "wave": .wav
        case "aif", "aiff": .aiff
        default: nil
        }
    }
}

public enum AudioTrimMode: String, CaseIterable, Identifiable, Sendable {
    case precise = "Precise with optional fades"
    case lossless = "Lossless PCM"
    public var id: Self { self }
}

public struct AudioTrimOptions: Equatable, Sendable {
    public var format = AudioTrimFormat.wav
    public var mode = AudioTrimMode.precise
    public var start = 0.0
    public var end: Double?
    public var fadeIn = 0.0
    public var fadeOut = 0.0

    public init() {}
}

public struct AudioTrimSource: Equatable, Sendable {
    public let sampleRate: Double
    public let frameCount: Int64
    public let losslessFormat: AudioTrimFormat?
    public var duration: Double { Double(frameCount) / sampleRate }
}

public struct AudioTrimSelection: Equatable, Sendable {
    public let firstFrame: Int64
    public let endFrame: Int64
    public let fadeInFrames: Int64
    public let fadeOutFrames: Int64
    public var frameCount: Int64 { endFrame - firstFrame }

    public static func plan(_ source: AudioTrimSource, options: AudioTrimOptions) throws -> Self {
        let end = options.end ?? source.duration
        guard source.sampleRate.isFinite, source.sampleRate > 0, source.frameCount > 0,
              source.duration.isFinite, options.start.isFinite, end.isFinite,
              options.start >= 0, end > options.start, end <= source.duration else {
            throw ToolError.invalid("Set a start before the end, within the audio duration.")
        }
        let first = frame(options.start, source: source)
        let last = frame(end, source: source)
        guard last > first else { throw ToolError.invalid("Select at least one audio sample.") }
        if options.mode == .lossless {
            guard source.losslessFormat == options.format else {
                throw ToolError.invalid("Lossless mode requires PCM WAV or AIFF and its matching output format.")
            }
            guard options.fadeIn == 0, options.fadeOut == 0 else {
                throw ToolError.invalid("Fades require the precise method.")
            }
        }
        guard options.fadeIn.isFinite, options.fadeOut.isFinite, options.fadeIn >= 0, options.fadeOut >= 0,
              options.fadeIn + options.fadeOut <= Double(last - first) / source.sampleRate else {
            throw ToolError.invalid("The fades must fit within the selected audio.")
        }
        let head = frame(options.fadeIn, source: source)
        let tail = min(last - first - head, frame(options.fadeOut, source: source))
        return Self(firstFrame: first, endFrame: last, fadeInFrames: head, fadeOutFrames: tail)
    }

    private static func frame(_ seconds: Double, source: AudioTrimSource) -> Int64 {
        let frames = (seconds * source.sampleRate).rounded()
        return frames >= Double(source.frameCount) ? source.frameCount : Int64(frames)
    }
}

public struct AudioTrimWaveform: Sendable {
    public let source: AudioTrimSource
    public let peaks: [Float]
}
