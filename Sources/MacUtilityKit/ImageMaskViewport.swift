import SwiftUI

struct ImageMaskViewport<Content: View>: View {
    let image: CGImage
    let actualPixels: Bool
    @ViewBuilder let content: (CGSize) -> Content

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ImagePreviewViewport(image: image,
                             sizing: actualPixels ? .zoom(1 / displayScale) : .fit,
                             scrollPadding: actualPixels ? 10 : 0) { size in
            content(size)
                .background(.primary.opacity(0.035))
        }
    }
}

func runImageMaskWork<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(priority: .userInitiated, operation: operation)
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}
