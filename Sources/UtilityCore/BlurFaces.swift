import Foundation
import Vision

public struct BlurFacesOptions: Equatable, Sendable {
    public var regions: [URL: [ImageMaskRegion]] = [:]
    public var effect = ImageRedactionEffect.solid
    public var strength = 0.8
    private var reviews: [URL: Review] = [:]

    private struct Review: Equatable, Sendable {
        let digest: String
        let regions: [ImageMaskRegion]
        let effect: ImageRedactionEffect
        let strength: Double
    }

    public init() {}

    public mutating func confirmReview(_ input: URL, source: ImageRedaction.Source) {
        let masks = regions[input, default: []]
        guard !masks.isEmpty else { return }
        reviews[input] = Review(digest: source.digest, regions: masks, effect: effect, strength: strength)
    }

    public mutating func clearReview(_ input: URL) { reviews[input] = nil }

    public func isReviewed(_ input: URL) -> Bool {
        guard let review = reviews[input] else { return false }
        return review.regions == regions[input] && review.effect == effect && review.strength == strength
    }

    public func reviewMatchesSource(_ input: URL, source: ImageRedaction.Source) -> Bool {
        isReviewed(input) && reviews[input]?.digest == source.digest
    }
}

public enum BlurFaces {
    public static func suggest(in source: ImageRedaction.Source) throws -> [ImageMaskRegion] {
        try Task.checkCancellation()
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: source.image, orientation: .up)
        try handler.perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).prefix(256).compactMap { observation in
            suggestedMask(for: observation.boundingBox)
        }
    }

    public static func suggestedMask(for bounds: CGRect) -> ImageMaskRegion? {
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let flipped = CGRect(x: bounds.minX, y: 1 - bounds.maxY, width: bounds.width, height: bounds.height)
        let padded = flipped.insetBy(dx: -bounds.width * 0.16, dy: -bounds.height * 0.20)
        let mask = padded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !mask.isNull, !mask.isEmpty else { return nil }
        return ImageMaskRegion(rect: mask)
    }

    public static func export(_ input: URL, to output: URL, options: BlurFacesOptions) throws -> String {
        guard options.isReviewed(input) else {
            throw ToolError.invalid("Review the image and confirm that every face is covered before exporting.")
        }
        guard output.standardizedFileURL != input.standardizedFileURL else {
            throw ToolError.invalid("Choose a separate output file.")
        }
        let source = try ImageRedaction.load(input)
        guard options.reviewMatchesSource(input, source: source) else {
            throw ToolError.invalid("This image changed since its masks were reviewed. Reopen it and review it again.")
        }
        let regions = options.regions[input, default: []]
        let masked = try ImageRedaction.render(source.image, regions: regions, effect: options.effect, strength: options.strength)
        try ImageRedaction.writePNG(masked, to: output)
        return "\(input.lastPathComponent) · \(regions.count) mask\(regions.count == 1 ? "" : "s") · Flattened PNG"
    }
}
