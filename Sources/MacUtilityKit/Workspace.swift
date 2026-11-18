import AppKit
import SwiftUI
import UtilityCore

struct Workspace: View {
    @State private var selection: Tool? = .resizeImages
    @State private var search = ""
    @FocusState private var searching: Bool
    @State private var session = WorkspaceSession()

    @Environment(\.colorScheme) private var colorScheme
    private var palette: WorkspacePalette { WorkspacePalette(dark: colorScheme == .dark) }
    private var visibleTools: [Tool] {
        Tool.allCases.filter {
            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
                || $0.category.localizedCaseInsensitiveContains(search)
        }
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
                            if let first = visibleTools.first {
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

                if visibleTools.isEmpty {
                    Text("No matching tools")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(visibleTools) { tool in
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
                                    .background(selection == tool ? palette.wash : .clear,
                                                in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selection == tool ? .isSelected : [])
                        }
                    }
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
                        session: session
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
}
