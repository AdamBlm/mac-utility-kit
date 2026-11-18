import SwiftUI

struct ImageMaskViewport<Content: View>: View {
    let image: CGImage
    let actualPixels: Bool
    @ViewBuilder let content: (CGSize) -> Content

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            let fit = min(geometry.size.width / CGFloat(image.width), geometry.size.height / CGFloat(image.height), 1)
            let scale = actualPixels ? 1 / displayScale : fit
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            if actualPixels {
                ScrollView([.horizontal, .vertical]) {
                    content(size).padding(4)
                }
            } else {
                content(size).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 340)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

func runImageMaskWork<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(priority: .userInitiated, operation: operation)
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}
