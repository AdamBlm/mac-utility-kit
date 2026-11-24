import SwiftUI

/// Gives the artwork its own aspect ratio while keeping enlarged images usable in a scrolling tool.
struct ImagePreviewViewport<Content: View>: View {
    let image: CGImage
    var maxHeight: CGFloat = 340
    var sizing: ImagePreviewViewportSizing = .fit
    var scrollPadding: CGFloat = 0
    @ViewBuilder let content: (CGSize) -> Content

    var body: some View {
        let naturalSize = CGSize(width: image.width, height: image.height)

        ImagePreviewLayout(naturalSize: naturalSize, maxHeight: maxHeight,
                           sizing: sizing, scrollPadding: scrollPadding) {
            GeometryReader { geometry in
                let size = ImagePreviewLayout.artworkSize(
                    naturalSize: naturalSize, viewport: geometry.size, sizing: sizing
                )
                switch sizing {
                case .fit:
                    artwork(size)
                case .fitWidth, .zoom:
                    if size.width + scrollPadding * 2 > geometry.size.width + 0.5
                        || size.height + scrollPadding * 2 > geometry.size.height + 0.5 {
                        ScrollView([.horizontal, .vertical]) {
                            artwork(size).padding(scrollPadding)
                        }
                    } else {
                        artwork(size).padding(scrollPadding)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func artwork(_ size: CGSize) -> some View {
        content(size).frame(width: size.width, height: size.height)
    }
}

private struct ImagePreviewLayout: Layout {
    let naturalSize: CGSize
    let maxHeight: CGFloat
    let sizing: ImagePreviewViewportSizing
    let scrollPadding: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let availableWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? naturalSize.width
        let available = CGSize(width: max(0, availableWidth), height: maxHeight)
        let artwork = Self.artworkSize(naturalSize: naturalSize, viewport: available, sizing: sizing)
        return CGSize(width: min(available.width, artwork.width + scrollPadding * 2),
                      height: min(maxHeight, artwork.height + scrollPadding * 2))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }

    static func artworkSize(naturalSize: CGSize, viewport: CGSize, sizing: ImagePreviewViewportSizing) -> CGSize {
        let scale: CGFloat
        switch sizing {
        case .fit:
            scale = min(viewport.width / naturalSize.width, viewport.height / naturalSize.height, 1)
        case .fitWidth:
            scale = min(viewport.width / naturalSize.width, 1)
        case .zoom(let zoom):
            scale = zoom
        }
        return CGSize(width: naturalSize.width * scale, height: naturalSize.height * scale)
    }
}

enum ImagePreviewViewportSizing {
    case fit
    case fitWidth
    case zoom(CGFloat)
}
