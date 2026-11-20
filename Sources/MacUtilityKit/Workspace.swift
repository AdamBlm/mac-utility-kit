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
    @State private var readerSource: URL?
    @State private var captureHandoffError: String?
    @State private var search = ""
    @AppStorage("workspace.favoriteTools") private var storedFavorites = ""
    @AppStorage("workspace.recentTools") private var storedRecents = ""
    @FocusState private var searching: Bool
    @State private var session = WorkspaceSession()

    @Environment(\.colorScheme) private var colorScheme
    private var palette: WorkspacePalette { WorkspacePalette(dark: colorScheme == .dark) }
    private var searchTerm: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var favorites: [Tool] { storedFavorites.split(separator: ",").compactMap { Tool(rawValue: String($0)) } }
    private var recents: [Tool] { storedRecents.split(separator: ",").compactMap { Tool(rawValue: String($0)) } }

    private var visibleGroups: [ToolGroup] {
        let matches = Tool.allCases.filter {
            $0.title.localizedCaseInsensitiveContains(searchTerm)
                || $0.category.localizedCaseInsensitiveContains(searchTerm) || $0.matchesCapability(searchTerm)
        }
        let grouped = Dictionary(grouping: matches, by: \.group)
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
                            guard !searchTerm.isEmpty else { return }
                            if let first = visibleGroups.first?.tools.first {
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
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("k")
                    .accessibilityLabel("Focus tool search")
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))

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
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .navigationSplitViewColumnWidth(min: 170, ideal: 184, max: 220)
        } detail: {
            Group {
                switch selection {
                case .browse(let page):
                    ToolBrowser(page: page, favorites: favorites, recents: recents,
                                navigate: { selection = .browse($0) },
                                openTool: { selection = .tool($0) },
                                toggleFavorite: toggleFavorite)
                        .id(page.title)
                case .pdfReader:
                    PDFReaderView(source: $readerSource,
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
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let runningTool = session.runningTool {
                    jobBanner(runningTool.title, progress: session.progress) { session.cancel() }
                } else if let active = ExportActivityCenter.shared.active {
                    jobBanner(active.title, progress: active.progress) { ExportActivityCenter.shared.cancel(active.id) }
                }
            }
        }
        .background(LauncherWorkspaceBridge(controller: launcherController) { tool in
            selection = .tool(tool)
            search = ""
            searching = false
        })
        .onChange(of: selection) { _, destination in
            guard case .tool(let tool) = destination else { return }
            let updated = [tool] + recents.filter { $0 != tool }
            storedRecents = updated.prefix(12).map(\.rawValue).joined(separator: ",")
        }
        .onOpenURL { url in
            guard url.isFileURL, url.pathExtension.lowercased() == "pdf" else { return }
            openOutput(url)
        }
        .onChange(of: session.previewURL) { _, url in
            if let url { openOutput(url) }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .tint(palette.accent)
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
        .background(palette.surface)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var readerButton: some View {
        sidebarButton("PDF Reader", icon: "book", destination: .pdfReader)
    }

    private func openOutput(_ url: URL) {
        if url.pathExtension.lowercased() == "pdf" {
            readerSource = url
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
                    sidebarButton(category.title, icon: category.browseSymbol, destination: .browse(.category(category)))
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
                        sidebarButton(tool.title, icon: tool.symbol, destination: .tool(tool))
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

    private func sidebarButton(_ title: String, icon: String, destination: Destination) -> some View {
        let isSelected = selection == destination
        return Button {
            selection = destination
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .labelStyle(.fixedIcon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .foregroundStyle(isSelected ? palette.accent : .primary)
                .background(isSelected ? palette.wash : .clear, in: RoundedRectangle(cornerRadius: 8))
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
