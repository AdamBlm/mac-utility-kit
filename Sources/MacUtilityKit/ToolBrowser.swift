import SwiftUI
import UtilityCore

struct ToolBrowser: View {
    enum Page: Equatable {
        case overview
        case category(ToolCategory)
        case favorites
        case recents

        var title: String {
            switch self {
            case .overview: "Browse Tools"
            case .category(let category): category.title
            case .favorites: "Favorites"
            case .recents: "Recents"
            }
        }
    }

    let page: Page
    let favorites: [Tool]
    let recents: [Tool]
    let navigate: (Page) -> Void
    let openTool: (Tool) -> Void
    let toggleFavorite: (Tool) -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var palette: WorkspacePalette { WorkspacePalette(dark: colorScheme == .dark, category: pageCategory) }
    /// 150 pt lets four category cards share a row in the default 940 pt window
    /// (about 692 pt of content after the 32 pt page padding, minus three 12 pt gaps).
    @State private var categoryGridWidth: CGFloat = 692
    /// Eight categories always fill whole rows: four across, or two when the window is narrow.
    private var categoryColumnCount: Int { categoryGridWidth >= 600 ? 4 : 2 }
    private let toolColumns = [GridItem(.adaptive(minimum: 270, maximum: 520), spacing: 10, alignment: .top)]

    private var pageCategory: ToolCategory? {
        if case .category(let category) = page { return category }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                content
            }
            .frame(maxWidth: 940, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .workspaceBackground(palette)
        .defaultScrollAnchor(.top)
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            if page != .overview {
                WorkspaceBreadcrumb(crumbs: [
                    WorkspaceCrumb(title: "Browse Tools", action: { navigate(.overview) }),
                    WorkspaceCrumb(title: page.title)
                ], palette: palette)
            }

            if case .category(let category) = page {
                HStack(spacing: 16) {
                    WorkspaceTile(symbol: category.browseSymbol, tint: category.workspaceTint, size: 60)
                    VStack(alignment: .leading, spacing: 3) {
                        pageTitle
                        Text(category.browseSummary)
                            .font(.system(size: 14))
                            .foregroundStyle(palette.secondaryText)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    pageTitle
                    if page == .overview {
                        Text("\(Tool.allCases.count) tools in one app. File processing runs on your Mac.")
                            .font(.system(size: 14))
                            .foregroundStyle(palette.secondaryText)
                    }
                }
            }
        }
    }

    private var pageTitle: some View {
        Text(page.title)
            .font(.system(size: 30, weight: .bold))
            .tracking(-0.6)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .overview:
            if !favorites.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("Favorites")
                    WorkspaceFlowLayout(spacing: 8) {
                        ForEach(favorites) { tool in
                            favoriteChip(tool)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Categories")
                let categories = Array(ToolCategory.allCases)
                let perRow = categoryColumnCount
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    ForEach(Array(stride(from: 0, to: categories.count, by: perRow)), id: \.self) { start in
                        GridRow {
                            ForEach(Array(categories[start..<min(start + perRow, categories.count)])) { category in
                                categoryCard(category)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    categoryGridWidth = width
                }
            }
        case .category(let category):
            ForEach(category.browseSections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel(section.title)
                    toolRows(section.tools)
                }
            }
        case .favorites:
            if favorites.isEmpty {
                Text("Star a tool while browsing to keep it here.").foregroundStyle(palette.secondaryText)
            } else {
                toolRows(favorites)
            }
        case .recents:
            if recents.isEmpty {
                Text("Tools you open will appear here.").foregroundStyle(palette.secondaryText)
            } else {
                toolRows(recents)
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(palette.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }

    private func favoriteChip(_ tool: Tool) -> some View {
        Button {
            openTool(tool)
        } label: {
            HStack(spacing: 10) {
                ToolEmblem(tool: tool, palette: palette, size: 30)
                Text(tool.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.leading, 7)
            .padding(.trailing, 14)
            .padding(.vertical, 7)
            .background(palette.panelFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.hairline)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func categoryCard(_ category: ToolCategory) -> some View {
        let cardPalette = WorkspacePalette(dark: colorScheme == .dark, category: category)
        let colors = cardPalette.tintColors
        let toolCount = category.browseSections.reduce(0) { $0 + $1.tools.count }
        return Button {
            navigate(.category(category))
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                WorkspaceTile(symbol: category.browseSymbol, tint: category.workspaceTint, size: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(category.title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Text(category.browseSummary)
                        .font(.system(size: 12.5))
                        .foregroundStyle(cardPalette.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)

                HStack {
                    Text("\(toolCount) tools")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(cardPalette.accent)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 136, maxHeight: .infinity, alignment: .topLeading)
            .background(LinearGradient(colors: [colors.cardTop, colors.cardBottom], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(colors.cardLine)
                    .allowsHitTesting(false)
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.06), radius: 9, y: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func toolRows(_ tools: [Tool]) -> some View {
        LazyVGrid(columns: toolColumns, spacing: 10) {
            ForEach(tools) { tool in
                let isFavorite = favorites.contains(tool)
                let toolPalette = WorkspacePalette(dark: colorScheme == .dark, category: tool.group)
                HStack(alignment: .top, spacing: 4) {
                    Button {
                        openTool(tool)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            ToolEmblem(tool: tool, palette: toolPalette)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.title).font(.system(size: 14, weight: .semibold))
                                Text(tool.subtitle)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(palette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        toggleFavorite(tool)
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .foregroundStyle(isFavorite ? toolPalette.accent : palette.secondaryText)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
                    .accessibilityLabel(isFavorite ? "Remove \(tool.title) from Favorites" : "Add \(tool.title) to Favorites")
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(palette.panelFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(palette.hairline)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}
