import CoreGraphics

public enum ScreenRecordingResolution: Int, CaseIterable, Identifiable, Sendable {
    case source = 0, p720 = 720, p1080 = 1080, p2160 = 2160
    public var id: Self { self }
    public var title: String { self == .source ? "Source (up to 4K)" : "Up to \(rawValue)p" }
}

public struct ScreenRecordingGeometry: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(points: CGSize, scale: Double, resolution: ScreenRecordingResolution) throws {
        let width = Double(points.width) * scale
        let height = Double(points.height) * scale
        guard width.isFinite, height.isFinite, width >= 2, height >= 2,
              scale.isFinite, scale > 0 else {
            throw ToolError.invalid("Choose a screen area at least two pixels wide and high.")
        }
        let shortLimit = Double(resolution == .source ? 2160 : resolution.rawValue)
        let longLimit = resolution == .source ? 4096 : shortLimit * 16 / 9
        let fit = min(1, shortLimit / min(width, height), longLimit / max(width, height))
        self.width = max(2, Int((width * fit / 2).rounded(.down)) * 2)
        self.height = max(2, Int((height * fit / 2).rounded(.down)) * 2)
    }
}
