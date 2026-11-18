import AppKit
import ScreenCaptureKit
import UtilityCore

enum ScreenImageCapture {
    static func capture(
        region: CGRect, displays: [ScreenRegionSelector.Display], maximumEdge: CGFloat? = 4096,
        showsCursor: Bool = false, prefersNativeMultiDisplayCapture: Bool = true
    ) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else {
            throw ToolError.invalid("Allow Screen & System Audio Recording in System Settings, then try again.")
        }
        guard let primary = displays.first, let global = CaptureRegionGeometry.displayRect(appKit: region, primaryScreen: primary.frame),
              global.width >= 2, global.height >= 2 else {
            throw ToolError.invalid("Select a larger screen region.")
        }
        if #available(macOS 15.2, *), prefersNativeMultiDisplayCapture, !showsCursor {
            let image = try await SCScreenshotManager.captureImage(in: global)
            return try maximumEdge.map { try capped(image, maximumEdge: $0) } ?? image
        }
        return try await captureParts(region: region, displays: displays, maximumEdge: maximumEdge, showsCursor: showsCursor)
    }

    private static func captureParts(
        region: CGRect, displays: [ScreenRegionSelector.Display], maximumEdge: CGFloat?, showsCursor: Bool
    ) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let requested = displays.compactMap { display -> (ScreenRegionSelector.Display, CGRect)? in
            CaptureRegionGeometry.croppedRect(region, on: display.frame).map { (display, $0) }
        }
        guard !requested.isEmpty else { throw ToolError.invalid("No display contains the selected region.") }
        let backingScale = requested.map { $0.0.scale }.max() ?? 1
        let scale = maximumEdge.map { min(backingScale, $0 / max(region.width, region.height)) } ?? backingScale
        let width = max(1, Int((region.width * scale).rounded(.up)))
        let height = max(1, Int((region.height * scale).rounded(.up)))
        guard width <= 16_000, height <= 16_000, width * height <= 64_000_000 else {
            throw ToolError.invalid("Choose a smaller region to capture at full resolution.")
        }
        let canvas = try bitmap(width: width, height: height)
        canvas.setFillColor(CGColor(gray: 0, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (display, crop) in requested {
            try Task.checkCancellation()
            guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
                throw ToolError.invalid("The displays changed. Select the region again.")
            }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = crop
            configuration.width = max(1, Int((crop.width * scale).rounded(.up)))
            configuration.height = max(1, Int((crop.height * scale).rounded(.up)))
            configuration.showsCursor = showsCursor
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let destination = region.intersection(display.frame)
            canvas.draw(image, in: CGRect(x: (destination.minX - region.minX) * scale,
                                          y: (destination.minY - region.minY) * scale,
                                          width: destination.width * scale, height: destination.height * scale))
        }
        guard let image = canvas.makeImage() else { throw ToolError.invalid("Could not assemble the screen region.") }
        return image
    }

    private static func capped(_ image: CGImage, maximumEdge: CGFloat) throws -> CGImage {
        let factor = maximumEdge / CGFloat(max(image.width, image.height))
        guard factor < 1 else { return image }
        let width = max(1, Int((CGFloat(image.width) * factor).rounded(.down)))
        let height = max(1, Int((CGFloat(image.height) * factor).rounded(.down)))
        let context = try bitmap(width: width, height: height)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { throw ToolError.invalid("Could not prepare the screen region.") }
        return resized
    }

    private static func bitmap(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ToolError.invalid("Could not allocate an image for this screen region.")
        }
        return context
    }
}
