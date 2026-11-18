import Foundation

public enum VideoResizeSizing: String, CaseIterable, Identifiable, Sendable {
    case preset = "Preset"
    case dimensions = "Dimensions"
    case percentage = "Percentage"
    public var id: Self { self }
}

public enum VideoResizePreset: Int, CaseIterable, Identifiable, Sendable {
    case p480 = 480
    case p720 = 720
    case p1080 = 1080
    case p1440 = 1440
    case p2160 = 2160

    public var id: Self { self }
    public var title: String { "\(rawValue)p" }
    var width: Int {
        switch self {
        case .p480: 854
        case .p720: 1280
        case .p1080: 1920
        case .p1440: 2560
        case .p2160: 3840
        }
    }
}

public enum VideoResizeFraming: String, CaseIterable, Identifiable, Sendable {
    case fit = "Fit with padding"
    case fill = "Fill by cropping"
    case stretch = "Stretch"
    public var id: Self { self }
}

public struct VideoResizeOptions: Equatable, Sendable {
    public var sizing = VideoResizeSizing.preset
    public var preset = VideoResizePreset.p1080
    public var framing = VideoResizeFraming.fit
    public var width = 1920
    public var height = 1080
    public var locksAspectRatio = true
    public var percentage = 100

    public init() {}
}

public struct VideoResizeLayout: Equatable, Sendable {
    public static let maximumDimension = 4096
    public let width: Int
    public let height: Int
    public let contentRect: CGRect

    var size: CGSize { CGSize(width: width, height: height) }

    public static func plan(sourceSize: CGSize, options: VideoResizeOptions) throws -> Self {
        guard sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0 else {
            throw ToolError.invalid("Could not determine the displayed video dimensions.")
        }
        let width: Int
        let height: Int
        let framing: VideoResizeFraming
        switch options.sizing {
        case .preset:
            width = options.preset.width
            height = options.preset.rawValue
            framing = options.framing
        case .dimensions:
            width = options.width
            height = options.locksAspectRatio
                ? try evenDimension(Double(width) * sourceSize.height / sourceSize.width)
                : options.height
            framing = options.locksAspectRatio ? .stretch : options.framing
        case .percentage:
            guard (1...400).contains(options.percentage) else {
                throw ToolError.invalid("Enter a percentage between 1 and 400.")
            }
            let scale = Double(options.percentage) / 100
            width = try evenDimension(sourceSize.width * scale)
            height = try evenDimension(sourceSize.height * scale)
            framing = .stretch
        }
        for dimension in [width, height] {
            guard (2...maximumDimension).contains(dimension), dimension.isMultiple(of: 2) else {
                throw dimensionError()
            }
        }
        let canvas = CGSize(width: width, height: height)
        let widthScale = canvas.width / sourceSize.width
        let heightScale = canvas.height / sourceSize.height
        let content: CGSize
        switch framing {
        case .fit, .fill:
            let scale = framing == .fit ? min(widthScale, heightScale) : max(widthScale, heightScale)
            content = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        case .stretch:
            content = canvas
        }
        return Self(width: width, height: height, contentRect: CGRect(
            x: (canvas.width - content.width) / 2, y: (canvas.height - content.height) / 2,
            width: content.width, height: content.height
        ))
    }

    private static func evenDimension(_ unaligned: Double) throws -> Int {
        let aligned = max(2, (unaligned / 2).rounded() * 2)
        guard unaligned.isFinite, unaligned > 0, aligned <= Double(maximumDimension) else {
            throw dimensionError()
        }
        return Int(aligned)
    }

    private static func dimensionError() -> ToolError {
        .invalid("Choose even video dimensions between 2 and \(maximumDimension) pixels per side.")
    }
}
