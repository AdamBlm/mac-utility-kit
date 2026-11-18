import CoreGraphics
import Foundation

public enum VideoResize {
    public static func sourceSize(_ input: URL) async throws -> CGSize {
        try await VideoGeometryRenderer.sourceSize(input)
    }

    public static func preview(_ input: URL, options: VideoResizeOptions) async throws -> CGImage {
        try await VideoGeometryRenderer.preview(input) { try geometry(for: $0, options: options) }
    }

    public static func export(
        _ input: URL, to output: URL, options: VideoResizeOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        try await VideoGeometryRenderer.export(input, to: output, layout: { try geometry(for: $0, options: options) },
                                               progress: progress)
    }

    private static func geometry(for source: CGSize, options: VideoResizeOptions) throws -> VideoGeometryLayout {
        let layout = try VideoResizeLayout.plan(sourceSize: source, options: options)
        let frame = layout.contentRect
        let transform = CGAffineTransform(scaleX: frame.width / source.width, y: frame.height / source.height)
            .concatenating(CGAffineTransform(translationX: frame.minX, y: frame.minY))
        return VideoGeometryLayout(size: layout.size, displayedTransform: transform)
    }
}
