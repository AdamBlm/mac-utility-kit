import AppKit
import SwiftUI
import UtilityCore

struct WorkspacePalette {
    let dark: Bool
    /// The category whose hue tints this page. `nil` uses the neutral browse hue.
    var category: ToolCategory? = nil

    /// Recessed fill for text areas, previews and wells inside translucent cards.
    /// Translucent so it takes the hue of the card and window behind it.
    var canvas: Color { insetFill }
    var insetFill: Color { dark ? Color.black.opacity(0.22) : Color.black.opacity(0.04) }
    var surface: Color { dark ? Color(red: 0.127, green: 0.136, blue: 0.158) : .white }
    /// The category's accent, or the home accent when there is no category.
    var accent: Color { tintColors.accent }
    /// Fill for system controls (`.borderedProminent`, toggles, sliders) set through `.tint`.
    /// Uses the light-mode accent in both appearances: the dark-mode accent is a pastel that puts
    /// white button text below 4.5:1, while every light accent keeps at least 6.3:1 with white.
    /// Links, stars and breadcrumbs keep `accent`.
    var controlTint: Color { tint.light.accent }
    var wash: Color { accent.opacity(dark ? 0.16 : 0.075) }
    var line: Color { Color.primary.opacity(dark ? 0.12 : 0.10) }

    var tint: WorkspaceTint { category?.workspaceTint ?? .home }
    var tintColors: WorkspaceTintColors { dark ? tint.dark : tint.light }
    /// Translucent fill for cards and panels that sit on the tinted background.
    var panelFill: Color { dark ? Color.white.opacity(0.055) : Color.white.opacity(0.72) }
    var barFill: Color { dark ? Color.white.opacity(0.07) : Color.white.opacity(0.84) }
    var hairline: Color { dark ? Color.white.opacity(0.09) : Color.black.opacity(0.08) }
    var selectionFill: Color { dark ? Color.white.opacity(0.11) : Color.black.opacity(0.065) }
    var secondaryText: Color {
        dark ? Color(red: 0.725, green: 0.714, blue: 0.769) : Color(red: 0.333, green: 0.314, blue: 0.373)
    }
    var primaryActionFill: Color {
        dark ? Color(red: 0.957, green: 0.953, blue: 0.969) : Color(red: 0.114, green: 0.102, blue: 0.141)
    }
    var primaryActionText: Color {
        dark ? Color(red: 0.114, green: 0.102, blue: 0.141) : Color(red: 0.957, green: 0.953, blue: 0.969)
    }
    var shadow: Color { Color.black.opacity(dark ? 0.26 : 0.09) }
}

struct WorkspaceTintColors {
    let backgroundTop: Color
    let backgroundBottom: Color
    let glow: Color
    let cardTop: Color
    let cardBottom: Color
    let cardLine: Color
    let accent: Color
}

/// Per-category colors, precomputed from OKLCH. Dark values follow the approved mockups;
/// light values are a restrained equivalent with an accent that keeps 4.5:1 on the light canvas.
struct WorkspaceTint {
    let tileTop: Color
    let tileBottom: Color
    let dark: WorkspaceTintColors
    let light: WorkspaceTintColors

    /// Images, hue 350.
    static var images: WorkspaceTint {
        WorkspaceTint(
            tileTop: Color(red: 0.886, green: 0.455, blue: 0.671),
            tileBottom: Color(red: 0.686, green: 0.243, blue: 0.486),
            dark: WorkspaceTintColors(
                backgroundTop: Color(red: 0.188, green: 0.098, blue: 0.141),
                backgroundBottom: Color(red: 0.078, green: 0.039, blue: 0.055),
                glow: Color(red: 0.278, green: 0.137, blue: 0.208),
                cardTop: Color(red: 0.212, green: 0.141, blue: 0.173),
                cardBottom: Color(red: 0.165, green: 0.106, blue: 0.133),
                cardLine: Color(red: 0.333, green: 0.220, blue: 0.275),
                accent: Color(red: 1.000, green: 0.725, blue: 0.851)
            ),
            light: WorkspaceTintColors(
                backgroundTop: Color(red: 0.988, green: 0.957, blue: 0.973),
                backgroundBottom: Color(red: 0.965, green: 0.922, blue: 0.941),
                glow: Color(red: 1.000, green: 0.969, blue: 0.992),
                cardTop: Color(red: 1.000, green: 0.988, blue: 0.996),
                cardBottom: Color(red: 0.988, green: 0.957, blue: 0.973),
                cardLine: Color(red: 0.898, green: 0.804, blue: 0.843),
                accent: Color(red: 0.541, green: 0.169, blue: 0.376)
            )
        )
    }

    /// Documents, hue 15.
    static var documents: WorkspaceTint {
        WorkspaceTint(
            tileTop: Color(red: 0.925, green: 0.451, blue: 0.502),
            tileBottom: Color(red: 0.725, green: 0.235, blue: 0.314),
            dark: WorkspaceTintColors(
                backgroundTop: Color(red: 0.196, green: 0.098, blue: 0.106),
                backgroundBottom: Color(red: 0.082, green: 0.039, blue: 0.039),
                glow: Color(red: 0.290, green: 0.133, blue: 0.149),
                cardTop: Color(red: 0.220, green: 0.141, blue: 0.145),
                cardBottom: Color(red: 0.173, green: 0.106, blue: 0.110),
                cardLine: Color(red: 0.345, green: 0.220, blue: 0.231),
                accent: Color(red: 1.000, green: 0.725, blue: 0.745)
            ),
            light: WorkspaceTintColors(
                backgroundTop: Color(red: 0.992, green: 0.957, blue: 0.957),
                backgroundBottom: Color(red: 0.973, green: 0.922, blue: 0.922),
                glow: Color(red: 1.000, green: 0.969, blue: 0.973),
                cardTop: Color(red: 1.000, green: 0.988, blue: 0.988),
                cardBottom: Color(red: 0.992, green: 0.957, blue: 0.957),
                cardLine: Color(red: 0.906, green: 0.804, blue: 0.808),
                accent: Color(red: 0.576, green: 0.161, blue: 0.231)
            )
        )
    }

    /// Video, hue 45.
    static var video: WorkspaceTint {
        WorkspaceTint(
            tileTop: Color(red: 0.914, green: 0.486, blue: 0.282),
            tileBottom: Color(red: 0.714, green: 0.278, blue: 0.000),
            dark: WorkspaceTintColors(
                backgroundTop: Color(red: 0.192, green: 0.106, blue: 0.067),
                backgroundBottom: Color(red: 0.082, green: 0.039, blue: 0.024),
                glow: Color(red: 0.286, green: 0.145, blue: 0.082),
                cardTop: Color(red: 0.220, green: 0.145, blue: 0.114),
                cardBottom: Color(red: 0.169, green: 0.114, blue: 0.086),
                cardLine: Color(red: 0.341, green: 0.231, blue: 0.180),
                accent: Color(red: 1.000, green: 0.749, blue: 0.627)
            ),
            light: WorkspaceTintColors(
                backgroundTop: Color(red: 0.992, green: 0.961, blue: 0.945),
                backgroundBottom: Color(red: 0.969, green: 0.925, blue: 0.906),
                glow: Color(red: 1.000, green: 0.973, blue: 0.949),
                cardTop: Color(red: 1.000, green: 0.988, blue: 0.980),
                cardBottom: Color(red: 0.992, green: 0.961, blue: 0.945),
                cardLine: Color(red: 0.902, green: 0.812, blue: 0.769),
                accent: Color(red: 0.565, green: 0.200, blue: 0.000)
            )
        )
    }

    /// Audio, hue 90.
    static var audio: WorkspaceTint {
        WorkspaceTint(
            tileTop: Color(red: 0.765, green: 0.600, blue: 0.000),
            tileBottom: Color(red: 0.576, green: 0.404, blue: 0.000),
            dark: WorkspaceTintColors(
                backgroundTop: Color(red: 0.161, green: 0.129, blue: 0.035),
                backgroundBottom: Color(red: 0.067, green: 0.051, blue: 0.016),
                glow: Color(red: 0.235, green: 0.184, blue: 0.016),
                cardTop: Color(red: 0.188, green: 0.161, blue: 0.090),
                cardBottom: Color(red: 0.145, green: 0.125, blue: 0.071),
                cardLine: Color(red: 0.298, green: 0.255, blue: 0.149),
                accent: Color(red: 0.910, green: 0.812, blue: 0.549)
            ),
            light: WorkspaceTintColors(
                backgroundTop: Color(red: 0.976, green: 0.969, blue: 0.937),
                backgroundBottom: Color(red: 0.949, green: 0.933, blue: 0.894),
                glow: Color(red: 1.000, green: 0.988, blue: 0.933),
                cardTop: Color(red: 1.000, green: 0.992, blue: 0.976),
                cardBottom: Color(red: 0.976, green: 0.969, blue: 0.937),
                cardLine: Color(red: 0.863, green: 0.831, blue: 0.745),
                accent: Color(red: 0.451, green: 0.306, blue: 0.000)
            )
        )
    }

    /// Text, hue 150.
    static var text: WorkspaceTint {
        WorkspaceTint(
            tileTop: Color(red: 0.298, green: 0.722, blue: 0.416),
            tileBottom: Color(red: 0.000, green: 0.529, blue: 0.212),
            dark: WorkspaceTintColors(
                backgroundTop: Color(red: 0.075, green: 0.153, blue: 0.090),
                backgroundBottom: Color(red: 0.027, green: 0.063, blue: 0.035),
                glow: Color(red: 0.090, green: 0.224, blue: 0.122),
                cardTop: Color(red: 0.122, green: 0.184, blue: 0.133),
                cardBottom: Color(red: 0.090, green: 0.141, blue: 0.102),
                cardLine: Color(red: 0.192, green: 0.286, blue: 0.212),
                accent: Color(red: 0.655, green: 0.886, blue: 0.698)
            ),
            light: WorkspaceTintColors(
                backgroundTop: Color(red: 0.949, green: 0.976, blue: 0.953),
                backgroundBottom: Color(red: 0.910, green: 0.945, blue: 0.918),
                glow: Color(red: 0.957, green: 1.000, blue: 0.961),
                cardTop: Color(red: 0.984, green: 1.000, blue: 0.984),
                cardBottom: Color(red: 0.949, green: 0.976, blue: 0.953),
                cardLine: Color(red: 0.780, green: 0.855, blue: 0.792),
                accent: Color(red: 0.000, green: 0.412, blue: 0.145)
            )
        )
    }

    /// Files, hue 195.
    static var files: WorkspaceTint {
        WorkspaceTint(
            tileTop: Color(red: 0.000, green: 0.729, blue: 0.733),
            tileBottom: Color(red: 0.000, green: 0.533, blue: 0.545),
            dark: WorkspaceTintColors(
                backgroundTop: Color(red: 0.012, green: 0.153, blue: 0.157),
                backgroundBottom: Color(red: 0.012, green: 0.063, blue: 0.063),
                glow: Color(red: 0.000, green: 0.224, blue: 0.227),
                cardTop: Color(red: 0.082, green: 0.184, blue: 0.184),
                cardBottom: Color(red: 0.063, green: 0.141, blue: 0.141),
                cardLine: Color(red: 0.133, green: 0.290, blue: 0.290),
                accent: Color(red: 0.522, green: 0.894, blue: 0.890)
            ),
            light: WorkspaceTintColors(
                backgroundTop: Color(red: 0.941, green: 0.976, blue: 0.976),
                backgroundBottom: Color(red: 0.894, green: 0.949, blue: 0.945),
                glow: Color(red: 0.937, green: 1.000, blue: 1.000),
                cardTop: Color(red: 0.976, green: 1.000, blue: 1.000),
                cardBottom: Color(red: 0.941, green: 0.976, blue: 0.976),
                cardLine: Color(red: 0.749, green: 0.859, blue: 0.855),
                accent: Color(red: 0.000, green: 0.420, blue: 0.427)
            )
        )
    }

    /// Mac, hue 245.
    static var mac: WorkspaceTint {
        WorkspaceTint(
            tileTop: Color(red: 0.231, green: 0.651, blue: 0.961),
            tileBottom: Color(red: 0.000, green: 0.451, blue: 0.769),
            dark: WorkspaceTintColors(
                backgroundTop: Color(red: 0.063, green: 0.137, blue: 0.204),
                backgroundBottom: Color(red: 0.024, green: 0.055, blue: 0.082),
                glow: Color(red: 0.071, green: 0.200, blue: 0.298),
                cardTop: Color(red: 0.110, green: 0.173, blue: 0.224),
                cardBottom: Color(red: 0.086, green: 0.133, blue: 0.173),
                cardLine: Color(red: 0.180, green: 0.271, blue: 0.349),
                accent: Color(red: 0.624, green: 0.847, blue: 1.000)
            ),
            light: WorkspaceTintColors(
                backgroundTop: Color(red: 0.945, green: 0.973, blue: 0.992),
                backgroundBottom: Color(red: 0.906, green: 0.941, blue: 0.969),
                glow: Color(red: 0.949, green: 0.992, blue: 1.000),
                cardTop: Color(red: 0.980, green: 0.996, blue: 1.000),
                cardBottom: Color(red: 0.945, green: 0.973, blue: 0.992),
                cardLine: Color(red: 0.773, green: 0.843, blue: 0.906),
                accent: Color(red: 0.000, green: 0.349, blue: 0.612)
            )
        )
    }

    /// Developer, hue 285.
    static var developer: WorkspaceTint {
        WorkspaceTint(
            tileTop: Color(red: 0.588, green: 0.561, blue: 0.969),
            tileBottom: Color(red: 0.408, green: 0.361, blue: 0.776),
            dark: WorkspaceTintColors(
                backgroundTop: Color(red: 0.125, green: 0.122, blue: 0.204),
                backgroundBottom: Color(red: 0.047, green: 0.047, blue: 0.086),
                glow: Color(red: 0.176, green: 0.169, blue: 0.302),
                cardTop: Color(red: 0.157, green: 0.157, blue: 0.224),
                cardBottom: Color(red: 0.122, green: 0.122, blue: 0.173),
                cardLine: Color(red: 0.251, green: 0.247, blue: 0.353),
                accent: Color(red: 0.792, green: 0.788, blue: 1.000)
            ),
            light: WorkspaceTintColors(
                backgroundTop: Color(red: 0.965, green: 0.965, blue: 0.992),
                backgroundBottom: Color(red: 0.929, green: 0.929, blue: 0.973),
                glow: Color(red: 0.980, green: 0.980, blue: 1.000),
                cardTop: Color(red: 0.992, green: 0.992, blue: 1.000),
                cardBottom: Color(red: 0.965, green: 0.965, blue: 0.992),
                cardLine: Color(red: 0.824, green: 0.824, blue: 0.910),
                accent: Color(red: 0.314, green: 0.271, blue: 0.620)
            )
        )
    }

    /// Browse pages without a category, hue 280.
    static var home: WorkspaceTint {
        WorkspaceTint(
            tileTop: Color(red: 0.553, green: 0.573, blue: 0.976),
            tileBottom: Color(red: 0.373, green: 0.373, blue: 0.784),
            dark: WorkspaceTintColors(
                backgroundTop: Color(red: 0.118, green: 0.122, blue: 0.204),
                backgroundBottom: Color(red: 0.043, green: 0.047, blue: 0.086),
                glow: Color(red: 0.169, green: 0.173, blue: 0.306),
                cardTop: Color(red: 0.153, green: 0.157, blue: 0.227),
                cardBottom: Color(red: 0.118, green: 0.122, blue: 0.176),
                cardLine: Color(red: 0.239, green: 0.251, blue: 0.353),
                accent: Color(red: 0.773, green: 0.796, blue: 1.000)
            ),
            light: WorkspaceTintColors(
                backgroundTop: Color(red: 0.961, green: 0.965, blue: 0.996),
                backgroundBottom: Color(red: 0.925, green: 0.933, blue: 0.973),
                glow: Color(red: 0.976, green: 0.984, blue: 1.000),
                cardTop: Color(red: 0.988, green: 0.992, blue: 1.000),
                cardBottom: Color(red: 0.961, green: 0.965, blue: 0.996),
                cardLine: Color(red: 0.816, green: 0.827, blue: 0.910),
                accent: Color(red: 0.286, green: 0.278, blue: 0.627)
            )
        )
    }
}

struct WorkspaceBackground: View {
    let palette: WorkspacePalette

    var body: some View {
        let colors = palette.tintColors
        ZStack {
            LinearGradient(colors: [colors.backgroundTop, colors.backgroundBottom],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [colors.glow, colors.glow.opacity(0)],
                           center: UnitPoint(x: 0.78, y: 0), startRadius: 0, endRadius: 620)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Sidebar column backdrop: the window's tinted gradient with a floating, inset translucent panel.
struct WorkspaceSidebarBackground: View {
    let palette: WorkspacePalette
    /// Distance between the panel and the column edges.
    static let inset: CGFloat = 5

    var body: some View {
        let colors = palette.tintColors
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ZStack {
            LinearGradient(colors: [colors.backgroundTop, colors.backgroundBottom],
                           startPoint: .top, endPoint: .bottom)
            shape
                .fill(palette.panelFill)
                .overlay {
                    shape.strokeBorder(palette.hairline)
                }
                .shadow(color: palette.shadow, radius: 16, y: 8)
                .padding(WorkspaceSidebarBackground.inset)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    func workspaceBackground(_ palette: WorkspacePalette) -> some View {
        background { WorkspaceBackground(palette: palette) }
    }

    /// Recessed fill plus hairline for text areas inside `WorkspaceSection` cards.
    func workspaceInset(_ palette: WorkspacePalette, cornerRadius: CGFloat = 8) -> some View {
        background(palette.insetFill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(palette.hairline)
                    .allowsHitTesting(false)
            }
    }
}

struct WorkspaceTile: View {
    let symbol: String
    let tint: WorkspaceTint
    var size: CGFloat = 38
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WorkspaceTile.cornerRadius(for: size), style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: WorkspaceTile.glyphSize(for: size), weight: .medium))
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background {
                shape.fill(LinearGradient(colors: [tint.tileTop, tint.tileBottom],
                                          startPoint: UnitPoint(x: 0.33, y: 0), endPoint: UnitPoint(x: 0.67, y: 1)))
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.3), Color.white.opacity(0)],
                                                  startPoint: .top, endPoint: .center), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.14), radius: size > 40 ? 5 : 3, y: 2)
            .accessibilityHidden(true)
    }

    static func cornerRadius(for size: CGFloat) -> CGFloat {
        if size <= 24 { return 7 }
        if size <= 30 { return 9 }
        if size <= 38 { return 11 }
        if size <= 44 { return 13 }
        if size <= 60 { return 18 }
        return (size * 0.29).rounded()
    }

    static func glyphSize(for size: CGFloat) -> CGFloat {
        if size <= 24 { return 14 }
        if size <= 30 { return 16 }
        return (size * 0.47).rounded()
    }
}

struct ToolEmblem: View {
    let tool: Tool
    let palette: WorkspacePalette

    var large = false
    /// Overrides the tile size. `large` alone keeps the 84 pt empty-state tile.
    var size: CGFloat? = nil

    var body: some View {
        WorkspaceTile(symbol: tool.symbol, tint: tool.group.workspaceTint, size: size ?? (large ? 84 : 38))
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
                .foregroundStyle(palette.secondaryText)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(palette.panelFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(palette.hairline)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension Tool {
    var symbol: String {
        switch self {
        case .resizeImages: "photo.on.rectangle"
        case .convertImages: "photo.badge.arrow.down"
        case .rotateImages: "rotate.right"
        case .beautifyScreenshot: "photo.artframe"
        case .blurFaces: "person.crop.rectangle"
        case .redactImage: "eye.slash.fill"
        case .removeBackground: "person.crop.square"
        case .colorPicker: "eyedropper"
        case .watermark: "seal"
        case .screenshot: "camera.viewfinder"
        case .annotateScreenshot: "pencil.tip.crop.circle"
        case .compressImages: "arrow.down.right.and.arrow.up.left"
        case .removeMetadata: "eye.slash"
        case .mergePDFs: "document.on.document"
        case .splitPDF: "scissors"
        case .organizePDF: "square.grid.2x2"
        case .deletePDFPages: "rectangle.badge.minus"
        case .extractPDFPages: "doc.on.doc"
        case .imagesToPDF: "photo.on.rectangle.angled"
        case .pdfToImages: "photo.stack"
        case .signPDF: "signature"
        case .makePDFSearchable: "doc.text.magnifyingglass"
        case .compressPDF: "doc.zipper"
        case .cropPDF: "crop"
        case .convertDocuments: "arrow.left.arrow.right.square"
        case .wordToPDF: "doc.richtext"
        case .powerPointToPDF: "rectangle.on.rectangle"
        case .excelToPDF: "tablecells"
        case .redactPDF: "rectangle.inset.filled"
        case .markdownToPDF: "text.document"
        case .webPageToPDF: "safari"
        case .addPassword: "lock.doc"
        case .removePassword: "lock.open"
        case .extractText: "text.viewfinder"
        case .wordCounter: "number"
        case .transcribe: "waveform.badge.mic"
        case .captureText: "viewfinder"
        case .textToSpeech: "speaker.wave.2"
        case .recordAudio: "mic"
        case .recordScreen: "record.circle"
        case .downloadVideo: "arrow.down.circle"
        case .qrCode: "qrcode"
        case .batchRename: "rectangle.and.pencil.and.ellipsis"
        case .keepAwake: "moon.zzz"
        case .jsonFormatter: "curlybraces"
        case .base64: "arrow.left.arrow.right"
        case .hashGenerator: "number.square"
        case .uuidGenerator: "number"
        case .cleanLinks: "link"
        case .timestampConverter: "clock"
        case .loremIpsum: "text.alignleft"
        case .unicodeInspector: "character.magnify"
        case .diffChecker: "doc.badge.plus"
        case .regexTester: "asterisk"
        case .csvJSON: "tablecells"
        case .coordinatePicker: "mappin.and.ellipse"
        case .jwtDecoder: "person.text.rectangle"
        case .summarize: "text.alignleft"
        case .caseConverter: "textformat"
        case .batchFindReplace: "text.magnifyingglass"
        case .translate: "character.bubble"
        case .askDocument: "doc.text.magnifyingglass"
        case .passwordGenerator: "key"
        case .batteryHealth: "battery.75percent"
        case .diskSpeedTest: "gauge.with.dots.needle.50percent"
        case .networkSpeedTest: "speedometer"
        case .storageExplorer: "externaldrive"
        case .clipboardHistory: "clipboard"
        case .resetPermissions: "lock.rotation"
        case .appDamageDiagnosis: "checkmark.shield"
        case .loginBackgroundItems: "list.bullet.rectangle"
        case .scanDocument: "doc.viewfinder"
        case .fillFlattenForms: "checklist"
        case .pdfToWord: "doc.plaintext"
        case .hiddenSettings: "slider.horizontal.3"
        case .cleanKeyboard: "keyboard"
        case .wifiPasswordQR: "wifi"
        case .uninstallApp: "app.badge.checkmark"
        case .displayControl: "display.2"
        case .mouseFixes: "computermouse"
        case .organizeDownloads: "folder.badge.gearshape"
        case .deadPixelTest: "display"
        case .ejectAllDisks: "eject"
        case .presentationMode: "play.rectangle"
        case .zipUnzip: "archivebox"
        case .findDuplicates: "doc.on.doc"
        case .changeSpeed: "speedometer"
        case .extractFrames: "rectangle.on.rectangle"
        case .trimVideo: "scissors"
        case .muteVideo: "speaker.slash"
        case .resizeVideo: "arrow.up.left.and.arrow.down.right"
        case .videoToGIF: "photo.stack"
        case .cropRotateVideo: "crop.rotate"
        case .mergeVideos: "film.stack"
        case .replaceAudio: "waveform.badge.plus"
        case .burnSubtitles: "captions.bubble"
        case .extractSubtitles: "captions.bubble.fill"
        case .compressVideo: "film"
        case .convertVideo: "arrow.triangle.2.circlepath"
        case .mediaInfo: "info.circle"
        case .extractAudio: "waveform"
        case .trimAudio: "waveform.path"
        case .mergeAudio: "waveform.path.badge.plus"
        case .convertAudio: "arrow.triangle.2.circlepath"
        case .cleanUpAudio: "waveform.badge.minus"
        }
    }

    var subtitle: String {
        switch self {
        case .resizeImages: "Change the dimensions of one image or a whole batch."
        case .convertImages: "Change image formats and control transparency."
        case .rotateImages: "Crop, rotate, and flip images with a before-and-after preview."
        case .beautifyScreenshot: "Frame an image with a background, padding, and shadow."
        case .blurFaces: "Suggest face masks and review coverage before exporting."
        case .redactImage: "Hide selected areas and export a flattened image."
        case .removeBackground: "Isolate a subject and refine which parts of the image to keep."
        case .colorPicker: "Sample screen colors and copy HEX, RGB, or HSL."
        case .watermark: "Place a text or logo watermark on images, PDFs, or videos."
        case .screenshot: "Capture a display, window, region, or scrolling sequence."
        case .annotateScreenshot: "Mark up an image with arrows, shapes, text, and callouts."
        case .compressImages: "Reduce image file size and compare the result."
        case .removeMetadata: "Inspect and remove private details from image copies."
        case .mergePDFs: "Choose and combine pages from PDFs and images."
        case .splitPDF: "Save pages or page groups as separate PDFs."
        case .organizePDF: "Reorder, rotate, remove, and number pages in a PDF copy."
        case .deletePDFPages: "Mark the pages to remove and save a new PDF."
        case .extractPDFPages: "Save only the pages you select in a new PDF."
        case .imagesToPDF: "Arrange images and save them as a PDF."
        case .pdfToImages: "Render selected PDF pages as separate images."
        case .signPDF: "Place a visible signature on a PDF copy."
        case .makePDFSearchable: "Add selectable text to scanned PDF pages."
        case .compressPDF: "Estimate savings and make a smaller PDF copy."
        case .cropPDF: "Adjust the visible area of selected PDF pages."
        case .convertDocuments: "Convert Word, OpenDocument, rich text, HTML, plain text, and Markdown files."
        case .wordToPDF: "Preview Word documents and export selected pages to PDF."
        case .powerPointToPDF: "Preview and export slides or handouts as PDFs."
        case .excelToPDF: "Preview and export spreadsheets with configurable print settings."
        case .redactPDF: "Permanently remove marked content from a sanitized copy."
        case .markdownToPDF: "Preview and export Markdown as a paginated PDF."
        case .webPageToPDF: "Preview a webpage and export it as a PDF."
        case .addPassword: "Encrypt a PDF copy and choose viewer permissions."
        case .removePassword: "Unlock a PDF with its password and export a decrypted copy."
        case .extractText: "Turn text in images and PDFs into editable text."
        case .wordCounter: "Count words, characters, and reading time as you type."
        case .transcribe: "Create and edit a timestamped transcript with a local Whisper model."
        case .captureText: "Recognize text from a selected part of the screen."
        case .textToSpeech: "Listen to text with a local voice and export the audio."
        case .recordAudio: "Record a selected microphone and send the result to Transcribe."
        case .recordScreen: "Record a selected screen, window, or region."
        case .downloadVideo: "Inspect a link and download a selected video or audio stream."
        case .qrCode: "Generate and scan QR codes."
        case .batchRename: "Preview and apply filename rules in batches."
        case .keepAwake: "Keep your Mac awake for a session."
        case .jsonFormatter: "Validate, format, or minify JSON."
        case .base64: "Encode and decode text and binary files."
        case .hashGenerator: "Generate and verify local checksums."
        case .uuidGenerator: "Generate UUIDs or inspect their version and timestamp."
        case .cleanLinks: "Remove tracking parameters and preview supported redirect destinations."
        case .timestampConverter: "Convert between Unix timestamps and local dates."
        case .loremIpsum: "Generate placeholder words, sentences, and paragraphs."
        case .unicodeInspector: "Inspect code points, invisible characters, and Unicode normalization."
        case .diffChecker: "Compare text or files and navigate changes."
        case .regexTester: "Test regular expressions, inspect captures, and preview replacements."
        case .csvJSON: "Convert CSV to JSON or Markdown, and JSON to CSV."
        case .coordinatePicker: "Pick points on a map, copy coordinates, and measure distances."
        case .jwtDecoder: "Inspect token claims and optionally verify an HMAC signature."
        case .summarize: "Summarize text and selected document pages on your Mac."
        case .caseConverter: "Convert prose and identifiers between text cases."
        case .batchFindReplace: "Review and replace text across multiple files."
        case .translate: "Translate text or subtitles and review the result."
        case .askDocument: "Ask questions and inspect the cited source passages."
        case .passwordGenerator: "Generate random passwords and passphrases."
        case .batteryHealth: "Check battery charge, cycles, and capacity."
        case .diskSpeedTest: "Measure sequential write and read speeds on a selected volume."
        case .networkSpeedTest: "Test download, upload, and network responsiveness."
        case .storageExplorer: "Explore folder sizes and review files before moving them to Trash."
        case .clipboardHistory: "Keep and reuse selected clipboard entries during this session."
        case .resetPermissions: "Reset a specific privacy decision for one selected app."
        case .appDamageDiagnosis: "Inspect an app’s signature and macOS execution policy."
        case .loginBackgroundItems: "Review login and background items and manage them in System Settings."
        case .scanDocument: "Straighten document photos and save a multipage scan."
        case .fillFlattenForms: "Edit PDF form fields and save an editable or flattened copy."
        case .pdfToWord: "Export selected PDF pages as editable Word documents."
        case .hiddenSettings: "Review and update selected Finder and Dock preferences."
        case .cleanKeyboard: "Temporarily pause keyboard input while you clean."
        case .wifiPasswordQR: "Share a supported Wi-Fi connection as a QR code."
        case .uninstallApp: "Review an app and its identified files before moving them to Trash."
        case .displayControl: "Adjust supported external monitor settings."
        case .mouseFixes: "Set separate mouse and trackpad scrolling policies."
        case .organizeDownloads: "Review and organize downloaded images by recorded origin."
        case .deadPixelTest: "Inspect a display with full-screen solid colors."
        case .ejectAllDisks: "Review and eject eligible external drives and disk images."
        case .presentationMode: "Keep your display ready and hide distractions while presenting."
        case .zipUnzip: "Create ZIP archives and extract selected files."
        case .findDuplicates: "Find identical files and review which copies to keep."
        case .changeSpeed: "Adjust playback speed with optional pitch preservation."
        case .extractFrames: "Save selected moments from videos as images."
        case .trimVideo: "Save a selected section of a video."
        case .muteVideo: "Remove all audio or selected tracks from a video."
        case .resizeVideo: "Resize a video and preview how it fits the new frame."
        case .videoToGIF: "Turn a selected video segment into an animated GIF."
        case .cropRotateVideo: "Crop, rotate, and mirror video with a framing preview."
        case .mergeVideos: "Join video clips in the order you choose."
        case .replaceAudio: "Replace or mix the audio in a video."
        case .burnSubtitles: "Render subtitles directly onto the video."
        case .extractSubtitles: "Export a subtitle track as SRT or WebVTT."
        case .compressVideo: "Make videos smaller while keeping their resolution."
        case .convertVideo: "Save a video in another format."
        case .mediaInfo: "Inspect the streams and properties of a media file."
        case .extractAudio: "Save a selected audio track from a video."
        case .trimAudio: "Trim an audio selection, preview it on a loop, and add fades."
        case .mergeAudio: "Join audio clips with optional gaps or crossfades."
        case .convertAudio: "Convert audio files and choose their sample rate and channels."
        case .cleanUpAudio: "Reduce noise and hum in an audio file or video track."
        }
    }

    var dropHint: String {
        switch self {
        case .resizeImages, .convertImages, .compressImages, .removeMetadata, .rotateImages, .beautifyScreenshot, .blurFaces, .redactImage, .removeBackground: "or drop images anywhere in this pane"
        case .mergePDFs: "or drop PDFs and images anywhere in this pane"
        case .makePDFSearchable, .compressPDF, .cropPDF, .pdfToWord: "or drop PDFs anywhere in this pane"
        case .watermark: "or drop images, PDFs, and videos anywhere in this pane"
        case .splitPDF, .organizePDF, .deletePDFPages, .extractPDFPages, .pdfToImages, .signPDF: "or drop one PDF anywhere in this pane"
        case .imagesToPDF: "or drop images anywhere in this pane"
        case .extractText: "or drop images and PDFs anywhere in this pane"
        case .wordCounter: "or drop a text file anywhere in this pane"
        case .convertDocuments, .wordToPDF, .powerPointToPDF, .excelToPDF: "or drop documents anywhere in this pane"
        case .batchFindReplace, .extractSubtitles, .qrCode, .batchRename, .keepAwake, .jsonFormatter, .base64, .hashGenerator, .uuidGenerator, .cleanLinks, .timestampConverter, .loremIpsum, .unicodeInspector, .diffChecker, .regexTester, .csvJSON, .coordinatePicker, .jwtDecoder, .passwordGenerator, .batteryHealth, .diskSpeedTest, .deadPixelTest, .ejectAllDisks, .presentationMode, .networkSpeedTest, .storageExplorer, .clipboardHistory, .resetPermissions, .appDamageDiagnosis, .loginBackgroundItems, .hiddenSettings, .cleanKeyboard, .wifiPasswordQR, .uninstallApp, .displayControl, .mouseFixes, .organizeDownloads, .fillFlattenForms, .scanDocument, .findDuplicates, .zipUnzip, .summarize, .caseConverter, .translate, .askDocument, .transcribe, .captureText, .textToSpeech, .recordAudio, .screenshot, .annotateScreenshot, .recordScreen, .downloadVideo, .colorPicker, .markdownToPDF, .webPageToPDF, .addPassword, .removePassword, .redactPDF: ""
        case .compressVideo, .changeSpeed, .extractFrames, .trimVideo, .muteVideo, .resizeVideo, .videoToGIF, .cropRotateVideo, .mergeVideos, .replaceAudio, .burnSubtitles: "or drop videos anywhere in this pane"
        case .convertVideo, .extractAudio: "or drop videos anywhere in this pane"
        case .mediaInfo, .cleanUpAudio: "or drop audio or video anywhere in this pane"
        case .mergeAudio, .trimAudio, .convertAudio: "or drop audio files anywhere in this pane"
        }
    }

    var dropTitle: String {
        switch self {
        case .resizeImages, .convertImages, .compressImages, .removeMetadata, .rotateImages, .beautifyScreenshot, .blurFaces, .redactImage, .removeBackground: "Drop images here"
        case .mergePDFs: "Drop PDFs or images here"
        case .makePDFSearchable, .compressPDF, .cropPDF, .pdfToWord: "Drop PDFs here"
        case .watermark: "Drop images, PDFs, or videos here"
        case .splitPDF, .organizePDF, .deletePDFPages, .extractPDFPages, .pdfToImages, .signPDF: "Drop one PDF here"
        case .imagesToPDF: "Drop images here"
        case .extractText: "Drop images or PDFs here"
        case .wordCounter: "Drop a text file here"
        case .convertDocuments, .wordToPDF, .powerPointToPDF, .excelToPDF: "Drop documents here"
        case .batchFindReplace, .extractSubtitles, .qrCode, .batchRename, .keepAwake, .jsonFormatter, .base64, .hashGenerator, .uuidGenerator, .cleanLinks, .timestampConverter, .loremIpsum, .unicodeInspector, .diffChecker, .regexTester, .csvJSON, .coordinatePicker, .jwtDecoder, .passwordGenerator, .batteryHealth, .diskSpeedTest, .deadPixelTest, .ejectAllDisks, .presentationMode, .networkSpeedTest, .storageExplorer, .clipboardHistory, .resetPermissions, .appDamageDiagnosis, .loginBackgroundItems, .hiddenSettings, .cleanKeyboard, .wifiPasswordQR, .uninstallApp, .displayControl, .mouseFixes, .organizeDownloads, .fillFlattenForms, .scanDocument, .findDuplicates, .zipUnzip, .summarize, .caseConverter, .translate, .askDocument, .transcribe, .captureText, .textToSpeech, .recordAudio, .screenshot, .annotateScreenshot, .recordScreen, .downloadVideo, .colorPicker, .markdownToPDF, .webPageToPDF, .addPassword, .removePassword, .redactPDF: ""
        case .compressVideo, .changeSpeed, .extractFrames, .trimVideo, .muteVideo, .resizeVideo, .videoToGIF, .cropRotateVideo, .mergeVideos, .replaceAudio, .burnSubtitles: "Drop videos here"
        case .convertVideo, .extractAudio: "Drop videos here"
        case .mediaInfo, .cleanUpAudio: "Drop media files here"
        case .mergeAudio, .trimAudio, .convertAudio: "Drop audio files here"
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

struct InteractiveToolLayout<Content: View>: View {
    let tool: Tool
    let content: (WorkspacePalette) -> Content
    @Environment(\.colorScheme) private var colorScheme

    init(tool: Tool, @ViewBuilder content: @escaping (WorkspacePalette) -> Content) {
        self.tool = tool
        self.content = content
    }

    var body: some View {
        let palette = WorkspacePalette(dark: colorScheme == .dark, category: tool.group)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                WorkspaceToolHeader(tool: tool, palette: palette)
                content(palette)
            }
            .frame(maxWidth: 660, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .workspaceBackground(palette)
    }
}

/// Navigation and favorite state the window hands to the shared tool header.
struct WorkspaceToolChrome {
    let isFavorite: Bool
    let toggleFavorite: () -> Void
    let navigate: (ToolBrowser.Page) -> Void

    /// Browse Tools > Category > Tool, shared by the tool header and the empty state.
    func crumbs(for tool: Tool) -> [WorkspaceCrumb] {
        [
            WorkspaceCrumb(title: "Browse Tools", action: { navigate(.overview) }),
            WorkspaceCrumb(title: tool.group.title, action: { navigate(.category(tool.group)) }),
            WorkspaceCrumb(title: tool.title)
        ]
    }
}

private struct WorkspaceToolChromeKey: EnvironmentKey {
    static var defaultValue: WorkspaceToolChrome? { nil }
}

extension EnvironmentValues {
    var workspaceToolChrome: WorkspaceToolChrome? {
        get { self[WorkspaceToolChromeKey.self] }
        set { self[WorkspaceToolChromeKey.self] = newValue }
    }
}

struct WorkspaceCrumb {
    let title: String
    var action: (() -> Void)? = nil
}

struct WorkspaceBreadcrumb: View {
    let crumbs: [WorkspaceCrumb]
    let palette: WorkspacePalette

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                        .accessibilityHidden(true)
                }
                if let action = crumb.action {
                    Button(crumb.title, action: action)
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.accent)
                } else {
                    Text(crumb.title)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct WorkspaceToolHeader: View {
    let tool: Tool
    let palette: WorkspacePalette
    @Environment(\.workspaceToolChrome) private var chrome

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let chrome {
                WorkspaceBreadcrumb(crumbs: chrome.crumbs(for: tool), palette: palette)
            }
            HStack(spacing: 16) {
                ToolEmblem(tool: tool, palette: palette, size: 60)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.title)
                        .font(.system(size: 28, weight: .bold))
                        .tracking(-0.5)
                        .accessibilityAddTraits(.isHeader)
                    Text(tool.subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let chrome {
                    Button {
                        chrome.toggleFavorite()
                    } label: {
                        Image(systemName: chrome.isFavorite ? "star.fill" : "star")
                            .font(.system(size: 16))
                            .foregroundStyle(chrome.isFavorite ? palette.accent : palette.secondaryText)
                            .frame(width: 36, height: 36)
                            .background(palette.panelFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(palette.hairline)
                                    .allowsHitTesting(false)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(chrome.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                    .accessibilityLabel(chrome.isFavorite ? "Remove \(tool.title) from Favorites" : "Add \(tool.title) to Favorites")
                }
            }
        }
    }
}

/// Capsule used for a page's primary action: near-white on dark, near-black on light.
struct WorkspacePrimaryButtonStyle: ButtonStyle {
    let palette: WorkspacePalette
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(palette.primaryActionText)
            .padding(.horizontal, 20)
            .frame(minHeight: 38)
            .background(palette.primaryActionFill, in: Capsule())
            .shadow(color: palette.shadow, radius: 5, y: 2)
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.42)
            .contentShape(Capsule())
    }
}

/// Places subviews left to right and wraps them onto new rows.
struct WorkspaceFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (index, frame) in frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width {
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, CGSize(width: usedWidth, height: y + rowHeight))
    }
}
