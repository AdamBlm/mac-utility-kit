import CoreGraphics
import Foundation
import ImageIO

public enum ScreenshotImageOutput {
    public static func encode(_ image: CGImage, format: ScreenshotOutputFormat) throws -> Data {
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data as CFMutableData,
                     format.contentType.identifier as CFString, 1, nil) else {
            throw ToolError.invalid("Could not prepare the screenshot encoder.")
        }
        let options: [CFString: Any] = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: 0.92, kCGImageDestinationBackgroundColor: CGColor(gray: 1, alpha: 1)]
            : [:]
        CGImageDestinationAddImage(writer, image, options as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw ToolError.invalid("Could not encode the screenshot.") }
        return data as Data
    }
}
