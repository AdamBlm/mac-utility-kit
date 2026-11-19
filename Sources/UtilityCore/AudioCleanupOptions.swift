import Foundation

public enum AudioCleanupOutput: String, CaseIterable, Identifiable, Sendable {
    case wav, mkv
    public var id: Self { self }
    public var title: String { self == .wav ? "Audio (WAV)" : "Video (MKV)" }
}

public enum AudioCleanupProfile: String, CaseIterable, Identifiable, Sendable {
    case speech = "Speech", music = "Music"
    public var id: Self { self }
}

public enum AudioCleanupHum: Int, CaseIterable, Identifiable, Sendable {
    case off = 0, hz50 = 50, hz60 = 60
    public var id: Self { self }
    public var title: String { self == .off ? "Off" : "\(rawValue) Hz" }
}

public struct AudioCleanupOptions: Equatable, Sendable {
    public var executable: URL?
    public var trackIndex = 0
    public var output = AudioCleanupOutput.wav
    public var profile = AudioCleanupProfile.speech
    public var reductionDB = 12.0
    public var hum = AudioCleanupHum.off

    package var validationIssue: String? {
        guard executable.map(ExternalTool.isExecutable) == true else {
            return "Choose an FFmpeg executable."
        }
        guard (0...24).contains(reductionDB), trackIndex >= 0 else {
            return "Choose a valid audio track and noise reduction from 0 to 24 dB."
        }
        return nil
    }

    public init() {}
}

public struct AudioCleanupPreview: Sendable {
    public let original: Data
    public let cleaned: Data
    public let originalVolume: Float
    public let cleanedVolume: Float
    public let isNearClipping: Bool
    public let duration: Double
}
