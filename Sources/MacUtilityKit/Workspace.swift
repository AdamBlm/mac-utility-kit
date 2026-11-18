import AppKit
import SwiftUI
import UtilityCore

struct Workspace: View {
    let keepAwakeController: KeepAwakeController
    @State private var selection: Tool? = .resizeImages
    @State private var search = ""
    @State private var collapsedCategories: Set<ToolCategory> = []
    @FocusState private var searching: Bool
    @State private var session = WorkspaceSession()

    @Environment(\.colorScheme) private var colorScheme
    private var palette: WorkspacePalette { WorkspacePalette(dark: colorScheme == .dark) }
    private var visibleGroups: [ToolGroup] {
        let matches = Tool.allCases.filter {
            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
                || $0.category.localizedCaseInsensitiveContains(search)
        }
        let grouped = Dictionary(grouping: matches, by: \.group)
        return ToolCategory.allCases.compactMap { category in
            grouped[category].map { ToolGroup(category: category, tools: $0) }
        }
    }

    private struct ToolGroup: Identifiable {
        let category: ToolCategory
        let tools: [Tool]

        var id: ToolCategory { category }
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Find a tool", text: $search)
                        .textFieldStyle(.plain)
                        .focused($searching)
                        .onSubmit {
                            if let first = visibleGroups.first?.tools.first {
                                selection = first
                                searching = false
                            }
                        }
                    Button {
                        searching = true
                    } label: {
                        Text("⌘K").font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("k")
                    .accessibilityLabel("Focus tool search")
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))

                if visibleGroups.isEmpty {
                    Text("No matching tools")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(visibleGroups) { group in
                                VStack(alignment: .leading, spacing: 4) {
                                    categoryHeading(group.category)
                                    if !search.isEmpty || !collapsedCategories.contains(group.category) {
                                        ForEach(group.tools) { tool in
                                            toolButton(tool)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .scrollIndicators(.hidden)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .navigationSplitViewColumnWidth(min: 170, ideal: 184, max: 220)
        } detail: {
            Group {
                if let selection {
                    ToolWorkspace(
                        tool: selection,
                        draft: Binding(
                            get: { session.drafts[selection, default: ToolDraft()] },
                            set: { session.drafts[selection] = $0 }
                        ),
                        session: session,
                        keepAwakeController: keepAwakeController
                    )
                    .id(selection)
                } else {
                    ContentUnavailableView("Choose a tool", systemImage: "wrench.and.screwdriver")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let runningTool = session.runningTool {
                    HStack(spacing: 12) {
                        Text(runningTool.title)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if session.progress > 0 {
                            ProgressView(value: session.progress).frame(width: 88)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Button("Cancel") { session.cancel() }
                    }
                    .font(.callout)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(palette.surface)
                    .overlay(alignment: .bottom) { Divider() }
                }
            }
        }
        .onChange(of: session.previewURL) { _, url in
            if let url { NSWorkspace.shared.open(url) }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .tint(palette.accent)
    }

    @ViewBuilder
    private func categoryHeading(_ category: ToolCategory) -> some View {
        if search.isEmpty {
            let collapsed = collapsedCategories.contains(category)
            Button {
                if collapsed { collapsedCategories.remove(category) }
                else { collapsedCategories.insert(category) }
            } label: {
                HStack {
                    Text(category.title)
                    Spacer()
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
            .modifier(CategoryHeadingStyle())
        } else {
            Text(category.title).modifier(CategoryHeadingStyle())
        }
    }

    private func toolButton(_ tool: Tool) -> some View {
        Button {
            selection = tool
        } label: {
            Label(tool.title, systemImage: tool.symbol)
                .font(.system(size: 13, weight: selection == tool ? .semibold : .regular))
                .labelStyle(.fixedIcon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .foregroundStyle(selection == tool ? palette.accent : .primary)
                .background(selection == tool ? palette.wash : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == tool ? .isSelected : [])
    }
}


private struct CategoryHeadingStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}
