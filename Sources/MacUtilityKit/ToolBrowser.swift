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
    private var palette: WorkspacePalette { WorkspacePalette(dark: colorScheme == .dark) }
    private let columns = [GridItem(.adaptive(minimum: 225, maximum: 420), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    if page != .overview {
                        Button {
                            navigate(.overview)
                        } label: {
                            Label("Browse Tools", systemImage: "chevron.left")
                                .font(.callout)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.accent)
                    }

                    Text(page.title)
                        .font(.system(size: 30, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)

                    if case .category(let category) = page {
                        Text(category.browseSummary).foregroundStyle(.secondary)
                    }
                }
                content
            }
            .frame(maxWidth: 940, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(palette.canvas)
        .defaultScrollAnchor(.top)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .overview:
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(ToolCategory.allCases) { category in
                    categoryCard(category)
                }
            }
        case .category(let category):
            ForEach(category.browseSections, id: \.title) { section in
                WorkspaceSection(section.title, palette: palette) {
                    toolRows(section.tools)
                }
            }
        case .favorites:
            if favorites.isEmpty {
                Text("Star a tool while browsing to keep it here.").foregroundStyle(.secondary)
            } else {
                toolRows(favorites)
            }
        case .recents:
            if recents.isEmpty {
                Text("Tools you open will appear here.").foregroundStyle(.secondary)
            } else {
                toolRows(recents)
            }
        }
    }

    private func categoryCard(_ category: ToolCategory) -> some View {
        Button {
            navigate(.category(category))
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Image(systemName: category.browseSymbol)
                        .font(.system(size: 17))
                        .foregroundStyle(palette.accent)
                        .frame(width: 32, height: 32)
                        .background(palette.wash, in: RoundedRectangle(cornerRadius: 9))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)

                Text(category.title).font(.headline)
                Text(category.browseSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .padding(13)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(palette.line).allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func toolRows(_ tools: [Tool]) -> some View {
        VStack(spacing: 2) {
            ForEach(tools) { tool in
                let isFavorite = favorites.contains(tool)
                HStack(spacing: 6) {
                    Button {
                        openTool(tool)
                    } label: {
                        HStack(spacing: 10) {
                            ToolEmblem(tool: tool, palette: palette)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tool.title).font(.callout.weight(.semibold))
                                Text(tool.subtitle).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        toggleFavorite(tool)
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .foregroundStyle(isFavorite ? palette.accent : .secondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
                    .accessibilityLabel(isFavorite ? "Remove \(tool.title) from Favorites" : "Add \(tool.title) to Favorites")
                }
            }
        }
    }
}
