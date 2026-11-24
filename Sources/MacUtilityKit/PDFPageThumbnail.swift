import AppKit
import PDFKit
import SwiftUI

/// Keeps page controls aligned across a strip while preserving the page's orientation and proportions.
struct PDFPageThumbnail: View {
    let page: PDFPage?
    var quarterTurns = 0
    var isDimmed = false

    private let side: CGFloat = 82

    var body: some View {
        Group {
            if let page {
                Image(nsImage: page.thumbnail(of: CGSize(width: side * 2, height: side * 2), for: .cropBox))
                    .resizable()
                    .scaledToFit()
                    .rotationEffect(.degrees(Double(quarterTurns) * 90))
                    .opacity(isDimmed ? 0.5 : 1)
            } else {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

struct PDFPageCardStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let palette = WorkspacePalette(dark: colorScheme == .dark, category: .documents)
        configuration.label
            .font(.caption)
            .padding(7)
            .frame(minWidth: 98)
            .background(selected ? palette.wash : palette.insetFill, in: .rect(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? palette.accent : palette.hairline)
                    .allowsHitTesting(false)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
