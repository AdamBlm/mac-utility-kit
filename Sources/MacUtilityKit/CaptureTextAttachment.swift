import Foundation
import ImageIO
import UniformTypeIdentifiers
import UtilityCore

/// Owns the temporary image while a workspace draft or export uses it.
final class CaptureTextAttachment {
    let url: URL
    let recognizedText: String?

    init(image: CGImage, filename: String = "Captured Text.png", recognizedText: String? = nil) throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(filename)
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            try? manager.removeItem(at: directory)
            throw ToolError.invalid("Could not prepare the image as an input file.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? manager.removeItem(at: directory)
            throw ToolError.invalid("Could not save the temporary image.")
        }
        url = file
        self.recognizedText = recognizedText
    }

    deinit {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
