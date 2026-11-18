import Foundation

enum ImageMagickWebPEncoding {
    static func encode(
        _ input: URL, to output: URL, executable: URL, quality: Double, lossless: Bool
    ) async throws {
        var arguments = ["PNG:" + input.lastPathComponent]
        if lossless {
            arguments += ["-quality", "100", "-define", "webp:lossless=true", "-define", "webp:exact=true"]
        } else {
            arguments += ["-quality", String(Int((quality * 100).rounded())), "-define", "webp:lossless=false"]
        }
        arguments.append("WEBP:" + output.lastPathComponent)
        try await ExternalTool.run(executable, name: "ImageMagick", arguments: arguments,
                                   directory: output.deletingLastPathComponent())
    }
}
