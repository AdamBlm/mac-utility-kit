import AppKit
import SwiftUI
import UtilityCore

struct WorkspacePalette {
    let dark: Bool

    var canvas: Color { dark ? Color(red: 0.10, green: 0.12, blue: 0.115) : Color(red: 0.96, green: 0.96, blue: 0.94) }
    var surface: Color { dark ? Color(red: 0.14, green: 0.16, blue: 0.155) : Color(red: 0.995, green: 0.992, blue: 0.978) }
    var accent: Color { dark ? Color(red: 0.52, green: 0.82, blue: 0.72) : Color(red: 0.10, green: 0.37, blue: 0.30) }
    var wash: Color { accent.opacity(dark ? 0.16 : 0.075) }
    var line: Color { Color.primary.opacity(dark ? 0.12 : 0.10) }
}

struct ToolEmblem: View {
    let tool: Tool
    let palette: WorkspacePalette

    var body: some View {
        Image(systemName: tool.symbol)
            .font(.system(size: 23, weight: .medium))
            .foregroundStyle(palette.accent)
            .frame(width: 52, height: 52)
            .background(palette.wash, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(palette.accent.opacity(0.16))
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
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(palette.line)
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
