import AVFoundation
import Foundation

public enum VideoConversionFormat: String, CaseIterable, Sendable {
    case mp4, mov, m4v, webm

    public var title: String {
        self == .webm ? "WebM" : rawValue.uppercased()
    }

    public var supportedCodecs: [VideoConversionCodec] {
        self == .webm ? [.vp9] : [.h264, .hevc]
    }

    var nativeFileType: AVFileType? {
        switch self {
        case .mp4: .mp4
        case .mov: .mov
        case .m4v: .m4v
        case .webm: nil
        }
    }

    var ffmpegMuxer: String { self == .m4v ? "mp4" : rawValue }
}

public enum VideoConversionMode: String, CaseIterable, Sendable {
    case transcode, passthrough

    public var title: String {
        self == .transcode ? "Transcode" : "Passthrough"
    }
}

public enum VideoConversionCodec: String, CaseIterable, Sendable {
    case h264, hevc, vp9

    public var title: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .vp9: "VP9"
        }
    }
}

public enum VideoConversionAudio: String, CaseIterable, Sendable {
    case keep, remove

    public var title: String { self == .keep ? "Keep audio" : "Remove audio" }
}

public struct VideoConversionOptions: Equatable, Sendable {
    public var format: VideoConversionFormat = .mp4
    public var mode: VideoConversionMode = .transcode
    public var codec: VideoConversionCodec = .h264
    public var maximumHeight: Int?
    public var frameRate: Int?
    public var audio: VideoConversionAudio = .keep
    public var ffmpegExecutable: URL?

    public init() {}

    public var requiresFFmpeg: Bool {
        format == .webm || maximumHeight != nil || frameRate != nil
    }

    func validate() throws {
        if mode == .transcode, !format.supportedCodecs.contains(codec) {
            throw ToolError.invalid("\(codec.title) video is unavailable in \(format.title) transcoding.")
        }
        if mode == .passthrough, maximumHeight != nil || frameRate != nil {
            throw ToolError.invalid("Choose Transcode to change dimensions or frame rate.")
        }
        if let maximumHeight, !(2...4320).contains(maximumHeight) || !maximumHeight.isMultiple(of: 2) {
            throw ToolError.invalid("Enter an even maximum height between 2 and 4,320 pixels.")
        }
        if let frameRate, !(1...240).contains(frameRate) {
            throw ToolError.invalid("Enter a frame rate between 1 and 240 fps.")
        }
        if requiresFFmpeg, ffmpegExecutable == nil {
            throw ToolError.invalid("Select an FFmpeg executable for WebM or custom dimensions and frame rate.")
        }
    }
}
