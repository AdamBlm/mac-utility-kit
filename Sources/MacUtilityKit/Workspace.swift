import AppKit
import SwiftUI
import UtilityCore

struct Workspace: View {
    let keepAwakeController: KeepAwakeController
    let launcherController: LauncherController
    let presentationModeController: PresentationModeController
    let clipboardHistoryController: ClipboardHistoryController
    let audioRecordingController: AudioRecordingController
    let screenRecordingController: ScreenRecordingController
    @State private var selection = Destination.browse(.overview)
    @State private var pdfReader = PDFReaderSession()
    @State private var finderFavorites: FinderFileAction?
    @State private var captureHandoffError: String?
    @State private var search = ""
    @State private var sidebarVisible = true
    @AppStorage("workspace.favoriteTools") private var storedFavorites = ""
    @AppStorage("workspace.recentTools") private var storedRecents = ""
    @FocusState private var searching: Bool
    @State private var session = WorkspaceSession()

    @Environment(\.colorScheme) private var colorScheme
    /// Window palette, tinted by the selected category or the open tool's category, else home.
    private var palette: WorkspacePalette { WorkspacePalette(dark: colorScheme == .dark, category: selectedCategory) }
    private var selectedCategory: ToolCategory? {
        switch selection {
        case .browse(.category(let category)):
            return category
        case .tool(let tool):
            return tool.group
        case .pdfReader:
            return .documents
        case .browse:
            return nil
        }
    }
    private var searchTerm: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var favorites: [Tool] { storedFavorites.split(separator: ",").compactMap { Tool(rawValue: String($0)) } }
    private var recents: [Tool] { storedRecents.split(separator: ",").compactMap { Tool(rawValue: String($0)) } }

    private var searchMatches: [Tool] { Tool.workspaceSearchResults(searchTerm) }

    private var visibleGroups: [ToolGroup] {
        let grouped = Dictionary(grouping: searchMatches, by: \.group)
        return ToolCategory.allCases.compactMap { category in
            grouped[category].map { ToolGroup(category: category, tools: $0) }
        }
    }

    private enum Destination: Equatable {
        case browse(ToolBrowser.Page)
        case tool(Tool)
        case pdfReader
    }

    private var matchesReader: Bool {
        "PDF Reader".localizedCaseInsensitiveContains(searchTerm)
    }

    private struct ToolGroup: Identifiable {
        let category: ToolCategory
        let tools: [Tool]

        var id: ToolCategory { category }
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(palette.secondaryText)
                        .accessibilityHidden(true)
                    // The system placeholder is too faint on the tinted panel; draw our own.
                    TextField("Find a tool", text: $search, prompt: Text(""))
                        .textFieldStyle(.plain)
                        .overlay(alignment: .leading) {
                            if search.isEmpty {
                                Text("Find a tool")
                                    .foregroundStyle(palette.secondaryText)
                                    .lineLimit(1)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .focused($searching)
                        .onSubmit {
                            guard !searchTerm.isEmpty else { return }
                            if let first = searchMatches.first {
                                selection = .tool(first)
                                searching = false
                            } else if matchesReader {
                                selection = .pdfReader
                                searching = false
                            }
                        }
                    Button {
                        searching = true
                    } label: {
                        Text("⌘K").font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(palette.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("k")
                    .accessibilityLabel("Focus tool search")
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .workspaceInset(palette, cornerRadius: 10)

                ScrollView {
                    if searchTerm.isEmpty {
                        browseSidebar
                    } else {
                        searchResults
                    }
                }
                .scrollIndicators(.hidden)
                Spacer(minLength: 0)
            }
            // Content sits inside the floating panel drawn by WorkspaceSidebarBackground.
            .padding(.horizontal, WorkspaceSidebarBackground.inset + 8)
            .padding(.top, 12)
            .padding(.bottom, WorkspaceSidebarBackground.inset + 6)
            .frame(width: 190)
            .frame(maxHeight: .infinity, alignment: .top)
            .background { WorkspaceSidebarBackground(palette: palette) }
            }
            Group {
                switch selection {
                case .browse(let page):
                    ToolBrowser(page: page, favorites: favorites, recents: recents,
                                navigate: { selection = .browse($0) },
                                openTool: { selection = .tool($0) },
                                toggleFavorite: toggleFavorite)
                        .id(page.title)
                case .pdfReader:
                    PDFReaderView(reader: pdfReader,
                                  canHandoffForms: session.drafts[.fillFlattenForms]?.pdfForms.exportTask == nil,
                                  onHandoff: handoffPDF,
                                  stageClipboardPDF: session.stageClipboardPDF)
                case .tool(let selection):
                    ToolWorkspace(
                        tool: selection,
                        draft: Binding(
                            get: { session.drafts[selection, default: ToolDraft()] },
                            set: { session.setDraft($0, for: selection) }
                        ),
                        session: session,
                        keepAwakeController: keepAwakeController,
                        presentationModeController: presentationModeController,
                        clipboardHistoryController: clipboardHistoryController,
                        audioRecordingController: audioRecordingController,
                        screenRecordingController: screenRecordingController,
                        openOutput: openOutput,
                        openTranscription: openTranscription,
                        openCaptionBurn: openCaptionBurn,
                        openCapturedText: openCapturedText,
                        openAnnotation: openAnnotation
                    )
                    .id(selection)
                    .environment(\.workspaceToolChrome, WorkspaceToolChrome(
                        isFavorite: favorites.contains(selection),
                        toggleFavorite: { toggleFavorite(selection) },
                        navigate: { self.selection = .browse($0) }
                    ))
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let runningTool = session.runningTool {
                    jobBanner(runningTool.title, progress: session.progress) { session.cancel() }
                } else if let active = ExportActivityCenter.shared.active {
                    jobBanner(active.title, progress: active.progress) { ExportActivityCenter.shared.cancel(active.id) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible.toggle() }
                } label: {
                    Label("Toggle Sidebar", systemImage: "sidebar.leading")
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
            }
        }
        .background(LauncherWorkspaceBridge(controller: launcherController, openTool: { tool in
            selection = .tool(tool)
            search = ""
            searching = false
        }, openPDFs: { urls in
            for url in urls { pdfReader.openDeliveredFile(url) }
            selection = .pdfReader
        }, openFinderAction: { action in
            if let tool = action.tool {
                finderFavorites = nil
                openFinderFiles(action, with: tool)
            } else {
                finderFavorites = action
            }
        }))
        .sheet(item: $finderFavorites) { action in
            FinderFavoritesView(tools: action.compatibleFavorites(favorites)) { tool in
                openFinderFiles(action, with: tool)
            }
        }
        .onChange(of: selection) { _, destination in
            guard case .tool(let tool) = destination else { return }
            let updated = [tool] + recents.filter { $0 != tool }
            storedRecents = updated.prefix(12).map(\.rawValue).joined(separator: ",")
        }
        .onChange(of: session.previewURL) { _, url in
            if let url { openOutput(url) }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .tint(palette.controlTint)
        .alert("Could Not Open Capture", isPresented: Binding(
            get: { captureHandoffError != nil },
            set: { if !$0 { captureHandoffError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(captureHandoffError ?? "")
        }
    }

    private func jobBanner(_ title: String, progress: Double?, cancel: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(title).lineLimit(1)
            Spacer(minLength: 8)
            if let progress, progress > 0 {
                ProgressView(value: progress).frame(width: 88)
            } else {
                ProgressView().controlSize(.small)
            }
            Button("Cancel", action: cancel)
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(palette.barFill)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)
                .allowsHitTesting(false)
        }
    }

    private var readerButton: some View {
        sidebarButton("PDF Reader", icon: "book", destination: .pdfReader)
    }

    private func openOutput(_ url: URL) {
        if url.pathExtension.lowercased() == "pdf" {
            pdfReader.open(url)
            selection = .pdfReader
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func openAnnotation(_ image: CGImage) {
        var draft = session.drafts[.annotateScreenshot, default: ToolDraft()]
        draft.annotation.setImage(image)
        session.drafts[.annotateScreenshot] = draft
        selection = .tool(.annotateScreenshot)
    }

    private func openTranscription(_ input: URL) {
        var draft = session.drafts[.transcribe, default: ToolDraft()]
        if draft.transcribe.input != input {
            draft.transcribe.task?.cancel()
            draft.transcribe.error = nil
            draft.transcribe.input = input
            draft.transcribe.cues = []
            draft.transcribe.resultInput = nil
            draft.transcribe.resultSourceStamp = nil
            draft.transcribe.resultLanguage = nil
            draft.transcribe.forcedEnglish = false
            draft.transcribe.options.start = 0
            draft.transcribe.options.end = nil
        }
        session.drafts[.transcribe] = draft
        selection = .tool(.transcribe)
    }

    private func openCaptionBurn(_ input: URL, srt: String) {
        var draft = session.drafts[.burnSubtitles, default: ToolDraft()]
        draft.inputs = [input]
        draft.options.burnSubtitles.srt = srt
        session.drafts[.burnSubtitles] = draft
        selection = .tool(.burnSubtitles)
    }

    private func openCapturedText(_ image: CGImage, text: String, language: String?) {
        do {
            let attachment = try CaptureTextAttachment(image: image, recognizedText: text)
            try session.openCapturedText(attachment, language: language)
            selection = .tool(.extractText)
        } catch {
            captureHandoffError = error.localizedDescription
        }
    }

    private func openFinderFiles(_ action: FinderFileAction, with tool: Tool) {
        guard session.loadFinderAction(action, with: tool) else { return }
        selection = .tool(tool)
        search = ""
        searching = false
    }

    private func handoffPDF(to tool: Tool, input: URL) {
        var draft = session.drafts[tool, default: ToolDraft()]
        if tool == .redactPDF {
            if draft.pdfRedaction.input != input {
                draft.pdfRedaction = PDFRedactionDraft()
                draft.pdfRedaction.input = input
            }
        } else if tool == .fillFlattenForms {
            guard draft.pdfForms.exportTask == nil else { return }
            if draft.pdfForms.source != input || draft.pdfForms.session == nil {
                draft.pdfForms.pendingSource = input
            }
        } else if tool == .addPassword || tool == .removePassword {
            draft.inputs = [input]
        } else if tool.requiresSinglePDF {
            if draft.inputs.first != input { draft.replacePDF(with: input) }
        } else if !draft.inputs.contains(input) {
            draft.inputs.append(input)
        }
        session.drafts[tool] = draft
        selection = .tool(tool)
    }

    private var browseSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 2) {
                sidebarButton("Browse Tools", icon: "square.grid.2x2", destination: .browse(.overview))
                sidebarButton("Favorites", icon: "star", destination: .browse(.favorites))
                sidebarButton("Recents", icon: "clock", destination: .browse(.recents))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Categories").modifier(CategoryHeadingStyle())
                ForEach(ToolCategory.allCases) { category in
                    sidebarButton(category.title, icon: category.browseSymbol, destination: .browse(.category(category)),
                                  tint: category.workspaceTint)
                }
            }

            Divider().padding(.horizontal, 10)
            readerButton
        }
        .padding(.bottom, 8)
    }

    private var searchResults: some View {
        let groups = visibleGroups
        return LazyVStack(alignment: .leading, spacing: 14) {
            if matchesReader { readerButton }
            if groups.isEmpty && !matchesReader {
                Text("No matching tools")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.category.title).modifier(CategoryHeadingStyle())
                    ForEach(group.tools) { tool in
                        sidebarButton(tool.title, icon: tool.symbol, destination: .tool(tool), tint: tool.group.workspaceTint)
                            .contextMenu {
                                Button(favorites.contains(tool) ? "Remove from Favorites" : "Add to Favorites") {
                                    toggleFavorite(tool)
                                }
                            }
                    }
                }
            }
        }
        .padding(.bottom, 8)
    }

    private func toggleFavorite(_ tool: Tool) {
        let updated = favorites.contains(tool) ? favorites.filter { $0 != tool } : favorites + [tool]
        storedFavorites = updated.map(\.rawValue).joined(separator: ",")
    }

    /// The selected row, plus the open tool's category row (display only; selection is unchanged).
    private func isHighlighted(_ destination: Destination) -> Bool {
        if selection == destination { return true }
        if case .tool(let tool) = selection, case .browse(.category(let category)) = destination {
            return tool.group == category
        }
        return false
    }

    private func sidebarButton(_ title: String, icon: String, destination: Destination,
                               tint: WorkspaceTint? = nil) -> some View {
        let isSelected = isHighlighted(destination)
        return Button {
            selection = destination
        } label: {
            HStack(spacing: 10) {
                if let tint {
                    WorkspaceTile(symbol: icon, tint: tint, size: 24)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .padding(.horizontal, 9)
            .foregroundStyle(.primary)
            .background(isSelected ? palette.selectionFill : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
