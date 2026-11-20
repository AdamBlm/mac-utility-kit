import Foundation

enum ImageMagickWebPEncoding {
    static let minimumLossyQuality = 1

    static func lossyQualityPercent(_ fraction: Double) -> Int {
        // ImageMagick treats zero as unspecified and encodes at its default quality.
        max(minimumLossyQuality, Int((fraction * 100).rounded()))
    }

    static func encode(
        _ input: URL, to output: URL, executable: URL, quality: Double, lossless: Bool
    ) async throws {
        var arguments = ["PNG:" + input.lastPathComponent]
        if lossless {
            arguments += ["-quality", "100", "-define", "webp:lossless=true", "-define", "webp:exact=true"]
        } else {
            arguments += ["-quality", String(lossyQualityPercent(quality)), "-define", "webp:lossless=false"]
        }
        arguments.append("WEBP:" + output.lastPathComponent)
        try await ExternalTool.run(executable, name: "ImageMagick", arguments: arguments,
                                   directory: output.deletingLastPathComponent())
    }
}
