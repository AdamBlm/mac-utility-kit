import AVFoundation
import Foundation

public struct VideoCompressionOptions: Equatable, Sendable {
    public enum RateControl: String, CaseIterable, Sendable {
        case preset = "Preset"
        case averageBitrate = "Average Bitrate"
        case constantQuality = "Constant Quality"
    }

    public static let bitrateRange = 64...100_000
    public static let qualityRange = 12...45
    public static let resolutionRange = 128...8_192
    public static let audioBitrateRange = 32...320

    public var rateControl = RateControl.preset
    public var videoKbps = 4_000
    public var quality = 23
    public var maximumEdge: Int?
    public var audioKbps: Int?

    public init() {}

    func validate(ffmpeg: Bool) throws {
        if rateControl == .averageBitrate, !Self.bitrateRange.contains(videoKbps) {
            throw ToolError.invalid("Video bitrate must be 64–100,000 kb/s.")
        }
        if rateControl == .constantQuality {
            guard ffmpeg else { throw ToolError.invalid("Constant Quality requires FFmpeg.") }
            guard Self.qualityRange.contains(quality) else { throw ToolError.invalid("Quality must be 12–45 RF.") }
        }
        if let maximumEdge, !Self.resolutionRange.contains(maximumEdge) {
            throw ToolError.invalid("Longest-edge limit must be 128–8,192 px.")
        }
        if let audioKbps, !Self.audioBitrateRange.contains(audioKbps) {
            throw ToolError.invalid("Audio bitrate must be 32–320 kb/s per track.")
        }
    }

    func size(for source: CGSize) -> CGSize {
        guard let maximumEdge, CGFloat(maximumEdge) < max(source.width, source.height) else { return source }
        let factor = CGFloat(maximumEdge) / max(source.width, source.height)
        return CGSize(width: max(2, floor(source.width * factor / 2) * 2),
                      height: max(2, floor(source.height * factor / 2) * 2))
    }
}

public struct VideoCompressionCapabilities: Sendable {
    private let encoders: Set<String>?
    private let muxers: Set<String>?

    public static let macOS = Self(encoders: nil, muxers: nil)

    public static func ffmpeg(_ executable: URL) async throws -> Self {
        let encoders = try await FFmpegEncoding.list("-encoders", using: executable)
        let muxers = try await FFmpegEncoding.list("-muxers", using: executable)
        return Self(encoders: encoders, muxers: muxers)
    }

    public var formats: [VideoFormat] {
        VideoFormat.allCases.filter { supports($0, codec: .automatic) }
    }

    public func supports(_ format: VideoFormat, codec: VideoCodec) -> Bool {
        if codec == .automatic {
            return automaticCodec(for: format, hdr: false) != nil
        }
        if let encoders, let muxers {
            guard (format == .webm) == (codec == .vp9) else { return false }
            if format == .webm, !encoders.contains("png") || !muxers.contains("image2") { return false }
            let audio = format == .webm ? "libopus" : "aac"
            return muxers.contains(format.muxer) && encoders.contains(codec.ffmpegEncoder) && encoders.contains(audio)
        }
        return format != .webm && codec != .vp9
    }

    func automaticCodec(for format: VideoFormat, hdr: Bool) -> VideoCodec? {
        let candidates: [VideoCodec] = if format == .webm {
            [.vp9]
        } else if hdr {
            [.hevc]
        } else {
            [.h264, .hevc]
        }
        return candidates.first { supports(format, codec: $0) }
    }
}

public struct VideoCompressionPreview: Sendable {
    public let width: Int
    public let height: Int
    public let codec: VideoCodec
}

public enum VideoCompression {
    static func validate(_ options: ToolOptions) throws {
        try options.videoCompression.validate(ffmpeg: options.ffmpegExecutable != nil)
        guard options.videoFormat != .webm || options.ffmpegExecutable != nil else {
            throw ToolError.invalid("WebM requires FFmpeg with the VP9 and Opus encoders.")
        }
        guard options.videoCodec == .automatic || (options.videoFormat == .webm) == (options.videoCodec == .vp9) else {
            throw ToolError.invalid("Choose VP9 for WebM, or H.264 or HEVC for MP4, MOV, or M4V.")
        }
    }

    public static func preview(
        _ input: URL, options: ToolOptions, capabilities: VideoCompressionCapabilities
    ) async throws -> VideoCompressionPreview {
        let source = try await source(AVURLAsset(url: input), options: options, capabilities: capabilities)
        let display = CGRect(origin: .zero, size: source.size).applying(source.transform).standardized
        return VideoCompressionPreview(width: Int(display.width.rounded()), height: Int(display.height.rounded()), codec: source.codec)
    }

    struct Source {
        let track: AVAssetTrack
        let naturalSize: CGSize
        let size: CGSize
        let transform: CGAffineTransform
        let codec: VideoCodec
        let hdr: Bool
        let description: CMFormatDescription?
    }

    static func source(
        _ asset: AVURLAsset, options: ToolOptions, capabilities: VideoCompressionCapabilities = .macOS
    ) async throws -> Source {
        try validate(options)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw ToolError.invalid("The source has no video track macOS can inspect.")
        }
        let naturalSize = try await video.load(.naturalSize)
        guard naturalSize.width.isFinite, naturalSize.height.isFinite,
              (1...32_768).contains(naturalSize.width), (1...32_768).contains(naturalSize.height) else {
            throw ToolError.invalid("Could not read valid video dimensions.")
        }
        let description = try await video.load(.formatDescriptions).first
        let transfer = description.flatMap {
            CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        }
        let hdr = transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            || transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        let codec: VideoCodec
        if options.videoCodec == .automatic {
            guard let supported = capabilities.automaticCodec(for: options.videoFormat, hdr: hdr) else {
                if hdr {
                    throw ToolError.invalid("The selected engine cannot preserve HDR in \(options.videoFormat.rawValue.uppercased()). Choose an engine that can encode HDR for this format.")
                }
                throw ToolError.invalid("The selected engine has no supported video and audio encoders for \(options.videoFormat.rawValue.uppercased()).")
            }
            codec = supported
        } else {
            codec = options.videoCodec
            if hdr, codec == .h264 { throw ToolError.invalid("This HDR source requires HEVC or VP9 to preserve its transfer function.") }
            guard capabilities.supports(options.videoFormat, codec: codec) else {
                throw ToolError.invalid("The selected engine cannot encode \(codec.rawValue) in \(options.videoFormat.rawValue.uppercased()) with its supported audio codec.")
            }
        }
        if options.videoFormat == .webm {
            for track in try await asset.loadTracks(withMediaType: .audio) {
                for format in try await track.load(.formatDescriptions) {
                    if let channels = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mChannelsPerFrame,
                       channels > 8 {
                        throw ToolError.invalid("WebM supports up to eight audio channels per track. Choose MP4 or MOV to use another audio codec.")
                    }
                }
            }
        }
        let size = options.videoCompression.size(for: naturalSize)
        let transform = try await video.load(.preferredTransform)
        let display = CGRect(origin: .zero, size: size).applying(transform).standardized
        guard (1...65_536).contains(display.width), (1...65_536).contains(display.height) else {
            throw ToolError.invalid("Could not read valid video orientation.")
        }
        return Source(track: video, naturalSize: naturalSize, size: size,
                      transform: transform, codec: codec, hdr: hdr, description: description)
    }
}

extension VideoFormat {
    var muxer: String { self == .m4v ? "mp4" : rawValue }
}

extension VideoCodec {
    var ffmpegEncoder: String {
        switch self {
        case .automatic, .h264: "libx264"
        case .hevc: "libx265"
        case .vp9: "libvpx-vp9"
        }
    }
}
