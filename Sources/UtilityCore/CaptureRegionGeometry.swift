import CoreGraphics
import Foundation

public enum CaptureRegionGeometry {
    /// Convert an AppKit desktop rectangle (y upwards) to the screen coordinate space with y downwards.
    public static func displayRect(appKit rect: CGRect, primaryScreen: CGRect) -> CGRect? {
        guard valid(rect), valid(primaryScreen) else { return nil }
        return CGRect(x: rect.minX - primaryScreen.minX, y: primaryScreen.maxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    /// A ScreenCaptureKit crop expressed in points from the top-left of its display.
    public static func croppedRect(_ region: CGRect, on display: CGRect) -> CGRect? {
        guard valid(region), valid(display) else { return nil }
        let intersection = region.intersection(display)
        guard valid(intersection) else { return nil }
        return CGRect(x: intersection.minX - display.minX, y: display.maxY - intersection.maxY,
                      width: intersection.width, height: intersection.height)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite &&
            rect.width > 0 && rect.height > 0
    }
}
