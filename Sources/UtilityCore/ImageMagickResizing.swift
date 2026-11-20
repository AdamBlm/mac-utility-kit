import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageMagickResizing {
    static func resize(
        _ input: URL, source: CGImageSource, output: URL, size: (width: Int, height: Int),
        format: ImageFormat, quality: Double, fill: Bool, executable: URL
    ) async throws {
        let coders: [String: String] = [
            UTType.png.identifier: "PNG", UTType.jpeg.identifier: "JPEG",
            UTType.heic.identifier: "HEIC", UTType.tiff.identifier: "TIFF",
            UTType.gif.identifier: "GIF", UTType.webP.identifier: "WEBP",
            UTType.bmp.identifier: "BMP"
        ]
        guard let type = CGImageSourceGetType(source), let coder = coders[type as String] else {
            throw ToolError.invalid("ImageMagick mode supports PNG, JPEG, HEIC, TIFF, GIF, WebP and BMP. Use macOS for other supported inputs.")
        }
        let directory = output.deletingLastPathComponent()
        let stagedInput = directory.appendingPathComponent(UUID().uuidString)
        let stagedOutput = directory.appendingPathComponent(UUID().uuidString + "." + format.rawValue)
        try FileManager.default.createSymbolicLink(at: stagedInput, withDestinationURL: input)
        defer {
            try? FileManager.default.removeItem(at: stagedInput)
            try? FileManager.default.removeItem(at: stagedOutput)
        }
        let geometry = "\(size.width)x\(size.height)"
        var arguments = ["\(coder):\(stagedInput.lastPathComponent)[0]", "-auto-orient"]
        if fill {
            arguments += ["-resize", geometry + "^", "-gravity", "center", "-extent", geometry]
        } else {
            arguments += ["-resize", geometry + "!"]
        }
        if format == .jpg {
            arguments += ["-background", "white", "-alpha", "remove", "-alpha", "off"]
        }
        if format == .jpg || format == .heic {
            let boundedQuality = quality.isFinite ? min(1, max(0, quality)) : 0.85
            arguments += ["-quality", String(Int((boundedQuality * 100).rounded()))]
        }
        arguments.append(stagedOutput.lastPathComponent)
        try await ExternalTool.run(executable, name: "ImageMagick", arguments: arguments, directory: directory)
        try ImageResizing.verifyOutput(stagedOutput, size: size, format: format)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: stagedOutput, to: output)
    }
}
