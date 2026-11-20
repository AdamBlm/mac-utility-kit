import CoreGraphics
import Foundation

public enum CaptureRegionGeometry {
    package static func adjusting(
        _ region: CGRect, by delta: CGVector, resizing: Bool, displays: [CGRect]
    ) -> CGRect {
        let candidate: CGRect
        if resizing {
            // Keep the top-left corner anchored in AppKit's upward y-axis.
            candidate = CGRect(x: region.minX, y: region.minY + delta.dy,
                               width: region.width + delta.dx, height: region.height - delta.dy)
        } else {
            candidate = region.offsetBy(dx: delta.dx, dy: delta.dy)
        }
        guard candidate.size.width >= 2, candidate.size.height >= 2 else { return region }
        let desktop = displays.reduce(CGRect.null) { $0.union($1) }
        guard desktop.contains(candidate), displays.contains(where: { display in
            let overlap = candidate.intersection(display)
            return !overlap.isNull && overlap.width > 0 && overlap.height > 0
        }) else { return region }
        return candidate
    }

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
