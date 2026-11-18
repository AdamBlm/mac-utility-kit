import Foundation
import ImageIO
import UniformTypeIdentifiers
import UtilityCore

/// Owns the temporary image while a workspace draft or export uses it.
final class CaptureTextAttachment {
    let url: URL

    init(image: CGImage) throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("Captured Text.png")
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            try? manager.removeItem(at: directory)
            throw ToolError.invalid("The capture could not be prepared for Extract Text.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? manager.removeItem(at: directory)
            throw ToolError.invalid("The capture could not be saved for Extract Text.")
        }
        url = file
    }

    deinit {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
