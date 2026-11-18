import AppKit
import SwiftUI
import UtilityCore

struct WorkspacePalette {
    let dark: Bool

    var canvas: Color { dark ? Color(red: 0.095, green: 0.102, blue: 0.118) : Color(red: 0.975, green: 0.976, blue: 0.982) }
    var surface: Color { dark ? Color(red: 0.127, green: 0.136, blue: 0.158) : .white }
    var accent: Color { dark ? Color(red: 0.69, green: 0.72, blue: 1.0) : Color(red: 0.31, green: 0.32, blue: 0.68) }
    var wash: Color { accent.opacity(dark ? 0.16 : 0.075) }
    var line: Color { Color.primary.opacity(dark ? 0.12 : 0.10) }
}

struct ToolEmblem: View {
    let tool: Tool
    let palette: WorkspacePalette

    var large = false

    var body: some View {
        Image(systemName: tool.symbol)
            .font(.system(size: large ? 36 : 19, weight: .regular))
            .foregroundStyle(palette.accent)
            .frame(width: large ? 84 : 38, height: large ? 84 : 38)
            .background {
                RoundedRectangle(cornerRadius: large ? 23 : 11)
                    .fill(LinearGradient(
                        colors: [palette.wash, palette.accent.opacity(large ? 0.12 : 0.045)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
            }
            .overlay {
                RoundedRectangle(cornerRadius: large ? 23 : 11)
                    .strokeBorder(palette.accent.opacity(0.12))
            }
            .accessibilityHidden(true)
    }
}

struct WorkspaceSection<Content: View>: View {
    let title: String
    let palette: WorkspacePalette
    @ViewBuilder let content: Content

    init(_ title: String, palette: WorkspacePalette, @ViewBuilder content: () -> Content) {
        self.title = title
        self.palette = palette
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(palette.line.opacity(0.65))
                    .allowsHitTesting(false)
            }
        }
    }
}

extension Tool {
    var symbol: String {
        switch self {
        case .resizeImages: "photo.on.rectangle"
        case .mergePDFs: "document.on.document"
        case .compressVideo: "film"
        }
    }

    var subtitle: String {
        switch self {
        case .resizeImages: "Change the dimensions of one image or a whole batch."
        case .mergePDFs: "Choose and combine pages from PDFs and images."
        case .compressVideo: "Make videos smaller while keeping their resolution."
        }
    }

    var dropHint: String {
        switch self {
        case .resizeImages: "or drop images anywhere in this pane"
        case .mergePDFs: "or drop PDFs and images anywhere in this pane"
        case .compressVideo: "or drop videos anywhere in this pane"
        }
    }

    var dropTitle: String {
        switch self {
        case .resizeImages: "Drop images here"
        case .mergePDFs: "Drop PDFs or images here"
        case .compressVideo: "Drop videos here"
        }
    }
}

struct FixedIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 9) {
            configuration.icon.frame(width: 18)
            configuration.title
        }
    }
}

extension LabelStyle where Self == FixedIconLabelStyle {
    static var fixedIcon: Self { Self() }
}

struct SettingRow<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.callout)
                .frame(width: 110, alignment: .leading)
                .accessibilityHidden(true)
            content
                .frame(maxWidth: 310, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
}
