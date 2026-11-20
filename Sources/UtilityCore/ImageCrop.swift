import CoreGraphics
import Foundation

public struct ImageCropOptions: Equatable, Sendable {
    public enum Ratio: String, CaseIterable, Identifiable, Sendable {
        case freeform = "Freeform"
        case square = "1:1"
        case landscape = "4:3"
        case portrait = "3:4"
        case wide = "16:9"
        case vertical = "9:16"

        public var id: Self { self }

        var dimensions: (width: Int, height: Int)? {
            switch self {
            case .freeform: nil
            case .square: (1, 1)
            case .landscape: (4, 3)
            case .portrait: (3, 4)
            case .wide: (16, 9)
            case .vertical: (9, 16)
            }
        }
    }

    public var ratio: Ratio = .freeform
    public var width = 0.8
    public var height = 0.8
    public var scale = 1.0
    public var horizontalPosition = 0.5
    public var verticalPosition = 0.5

    public init() {}

    func pixelRect(width sourceWidth: Int, height sourceHeight: Int) throws -> CGRect {
        guard sourceWidth > 0, sourceHeight > 0,
              [width, height, scale].allSatisfy({ $0.isFinite && (0.01...1).contains($0) }),
              [horizontalPosition, verticalPosition].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw ToolError.invalid("Choose a valid crop size and position.")
        }

        let cropWidth: Int
        let cropHeight: Int
        if let ratio = ratio.dimensions {
            let maximum = min(sourceWidth / ratio.width, sourceHeight / ratio.height)
            guard maximum > 0 else {
                throw ToolError.invalid("The image is too small for this crop ratio.")
            }
            let units = max(1, Int((Double(maximum) * scale).rounded()))
            cropWidth = units * ratio.width
            cropHeight = units * ratio.height
        } else {
            cropWidth = max(1, Int((Double(sourceWidth) * width).rounded()))
            cropHeight = max(1, Int((Double(sourceHeight) * height).rounded()))
        }

        return CGRect(x: Int((Double(sourceWidth - cropWidth) * horizontalPosition).rounded()),
                      y: Int((Double(sourceHeight - cropHeight) * verticalPosition).rounded()),
                      width: cropWidth, height: cropHeight)
    }

    func crop(_ image: CGImage, sourceWidth: Int, sourceHeight: Int) throws -> CGImage {
        let rectangle = try pixelRect(width: sourceWidth, height: sourceHeight)
        let mapped = rectangle.applying(CGAffineTransform(scaleX: CGFloat(image.width) / CGFloat(sourceWidth),
                                                         y: CGFloat(image.height) / CGFloat(sourceHeight)))
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let cropped = image.cropping(to: mapped) else {
            throw ToolError.invalid("Could not crop the selected area.")
        }
        return cropped
    }
}
