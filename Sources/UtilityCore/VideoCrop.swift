import CoreGraphics
import Foundation

public enum VideoCropAspect: String, CaseIterable, Identifiable, Sendable {
    case freeform = "Freeform"
    case landscape = "16:9"
    case portrait = "9:16"
    case standard = "4:3"
    case square = "1:1"

    public var id: Self { self }

    public var unit: CGSize? {
        switch self {
        case .freeform: nil
        case .landscape: CGSize(width: 32, height: 18)
        case .portrait: CGSize(width: 18, height: 32)
        case .standard: CGSize(width: 8, height: 6)
        case .square: CGSize(width: 2, height: 2)
        }
    }
}

public enum VideoCropRotation: Int, CaseIterable, Identifiable, Sendable {
    case none = 0, clockwise = 90, half = 180, counterclockwise = 270

    public var id: Self { self }
    public var swapsAxes: Bool { self == .clockwise || self == .counterclockwise }

    public var title: String {
        switch self {
        case .none: "None"
        case .clockwise: "90° right"
        case .half: "180°"
        case .counterclockwise: "90° left"
        }
    }

    fileprivate func transform(for size: CGSize) -> CGAffineTransform {
        switch self {
        case .none: .identity
        case .clockwise: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)
        case .half: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: size.width, ty: size.height)
        case .counterclockwise: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width)
        }
    }
}

public struct VideoCropRegion: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public struct VideoCropOptions: Equatable, Sendable {
    public var aspect = VideoCropAspect.freeform
    public var region: VideoCropRegion?
    public var rotation = VideoCropRotation.none
    public var mirrorsHorizontally = false
    public var mirrorsVertically = false

    public init() {}
}

public struct VideoCropLayout: Equatable, Sendable {
    public static let maximumDimension = 4096
    public let region: VideoCropRegion
    public let outputSize: CGSize
    public let displayedTransform: CGAffineTransform

    public static func plan(sourceSize: CGSize, options: VideoCropOptions) throws -> Self {
        guard sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width >= 2, sourceSize.height >= 2,
              sourceSize.width <= CGFloat(Int32.max), sourceSize.height <= CGFloat(Int32.max) else {
            throw ToolError.invalid("Could not read the displayed video dimensions.")
        }
        let sourceWidth = Int(sourceSize.width.rounded(.down))
        let sourceHeight = Int(sourceSize.height.rounded(.down))
        let region = options.region ?? centeredRegion(width: sourceWidth, height: sourceHeight, aspect: options.aspect)
        guard (2...maximumDimension).contains(region.width), (2...maximumDimension).contains(region.height),
              region.width.isMultiple(of: 2), region.height.isMultiple(of: 2) else {
            throw ToolError.invalid("Choose even crop dimensions between 2 and \(maximumDimension) pixels per side.")
        }
        guard region.x >= 0, region.y >= 0, region.x <= sourceWidth - region.width,
              region.y <= sourceHeight - region.height else {
            throw ToolError.invalid("The crop extends outside the displayed video frame.")
        }
        if let unit = options.aspect.unit,
           region.width * Int(unit.height) != region.height * Int(unit.width) {
            throw ToolError.invalid("The crop dimensions must match the selected \(options.aspect.rawValue) aspect ratio.")
        }
        let crop = region.rect.size
        let size = options.rotation.swapsAxes ? CGSize(width: crop.height, height: crop.width) : crop
        var transform = CGAffineTransform(translationX: -CGFloat(region.x), y: -CGFloat(region.y))
            .concatenating(options.rotation.transform(for: crop))
        if options.mirrorsHorizontally {
            transform = transform.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0))
        }
        if options.mirrorsVertically {
            transform = transform.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height))
        }
        return Self(region: region, outputSize: size, displayedTransform: transform)
    }

    private static func centeredRegion(width: Int, height: Int, aspect: VideoCropAspect) -> VideoCropRegion {
        let maxWidth = min(width, maximumDimension)
        let maxHeight = min(height, maximumDimension)
        let cropWidth: Int
        let cropHeight: Int
        if let size = aspect.unit {
            let unitWidth = Int(size.width)
            let unitHeight = Int(size.height)
            let count = min(maxWidth / unitWidth, maxHeight / unitHeight)
            cropWidth = unitWidth * count
            cropHeight = unitHeight * count
        } else {
            cropWidth = maxWidth - maxWidth % 2
            cropHeight = maxHeight - maxHeight % 2
        }
        return VideoCropRegion(x: (width - cropWidth) / 2, y: (height - cropHeight) / 2, width: cropWidth, height: cropHeight)
    }
}

public enum VideoCrop {
    public static func sourceSize(_ input: URL) async throws -> CGSize {
        try await VideoGeometryRenderer.sourceSize(input)
    }

    public static func sourcePreview(_ input: URL) async throws -> CGImage {
        try await VideoGeometryRenderer.preview(input) { size in
            VideoGeometryLayout(size: size, displayedTransform: .identity)
        }
    }

    public static func preview(_ input: URL, options: VideoCropOptions) async throws -> CGImage {
        try await VideoGeometryRenderer.preview(input) { size in
            try layout(for: size, options: options)
        }
    }

    public static func export(
        _ input: URL, to output: URL, options: VideoCropOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        try await VideoGeometryRenderer.export(input, to: output, layout: { size in
            try layout(for: size, options: options)
        }, progress: progress)
    }

    private static func layout(for size: CGSize, options: VideoCropOptions) throws -> VideoGeometryLayout {
        let layout = try VideoCropLayout.plan(sourceSize: size, options: options)
        return VideoGeometryLayout(size: layout.outputSize, displayedTransform: layout.displayedTransform)
    }
}
