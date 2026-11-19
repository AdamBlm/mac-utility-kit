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

    public var audioBitrateRange: ClosedRange<Int> {
        // libopus caps mono streams at 256 kb/s. A batch target must also work for mono.
        self == .webm ? 32...256 : VideoCompressionOptions.audioBitrateRange
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
    public var audioKbps: Int?
    public var ffmpegExecutable: URL?

    public init() {}

    public var requiresFFmpeg: Bool {
        format == .webm || maximumHeight != nil || frameRate != nil || audioKbps != nil
    }

    package var validationIssue: String? {
        do {
            try validate()
            return nil
        } catch {
            return error.localizedDescription
        }
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
        if let audioKbps {
            guard mode == .transcode, audio == .keep else {
                throw ToolError.invalid("Audio bitrate requires transcoding with audio kept.")
            }
            guard format.audioBitrateRange.contains(audioKbps) else {
                let range = format.audioBitrateRange
                throw ToolError.invalid("Audio bitrate for \(format.title) must be \(range.lowerBound)–\(range.upperBound) kb/s per track.")
            }
            guard ffmpegExecutable != nil else {
                throw ToolError.invalid("Select an FFmpeg executable to set the audio bitrate, or choose Automatic.")
            }
        }
        if let ffmpegExecutable, !ExternalTool.isExecutable(ffmpegExecutable) {
            throw ToolError.invalid("Choose an executable FFmpeg binary or clear the custom selection.")
        }
        if requiresFFmpeg, ffmpegExecutable == nil {
            throw ToolError.invalid("Select an FFmpeg executable for WebM or custom dimensions and frame rate.")
        }
    }
}
