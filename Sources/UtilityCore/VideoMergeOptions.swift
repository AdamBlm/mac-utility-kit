import AVFoundation

public enum VideoMergeFormat: String, CaseIterable, Identifiable, Sendable {
    case mp4, mov
    public var id: Self { self }
    public var title: String { rawValue.uppercased() }
    var fileType: AVFileType { self == .mp4 ? .mp4 : .mov }
}

public enum VideoMergeMode: String, CaseIterable, Identifiable, Sendable {
    case normalize = "Normalize"
    case passthrough = "Passthrough"
    public var id: Self { self }
}

public enum VideoMergeResolution: String, CaseIterable, Identifiable, Sendable {
    case first = "Match first clip"
    case p720 = "1280 × 720"
    case p1080 = "1920 × 1080"
    case p2160 = "3840 × 2160"
    public var id: Self { self }

    func size(fallback: CGSize) -> CGSize {
        switch self {
        case .first:
            CGSize(width: max(2, (fallback.width / 2).rounded() * 2),
                   height: max(2, (fallback.height / 2).rounded() * 2))
        case .p720: CGSize(width: 1280, height: 720)
        case .p1080: CGSize(width: 1920, height: 1080)
        case .p2160: CGSize(width: 3840, height: 2160)
        }
    }
}

public struct VideoMergeOptions: Equatable, Sendable {
    public var format = VideoMergeFormat.mp4
    public var mode = VideoMergeMode.normalize
    public var resolution = VideoMergeResolution.first
    public var keepsAudio = true

    public init() {}
}

public struct VideoMergePlan: Sendable {
    public struct Clip: Sendable {
        public let url: URL
        public let start: Double
        public let duration: Double
        public let sizesDiffer: Bool
        public let hasDifferentSettings: Bool
        public let hasAudio: Bool
    }

    public let clips: [Clip]
    public let duration: Double
    public let size: CGSize
    public let passthroughIssue: String?
}

public struct VideoMergeBoundaryPreview: Sendable {
    public let before: CGImage
    public let after: CGImage
}
