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
    @State private var selection = Destination.tool(.resizeImages)
    @State private var readerSource: URL?
    @State private var captureHandoffError: String?
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

    private enum Destination: Equatable {
        case tool(Tool)
        case pdfReader
    }

    private var matchesReader: Bool {
        search.isEmpty || "PDF Reader".localizedCaseInsensitiveContains(search)
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

                if matchesReader {
                    readerButton
                }

                if visibleGroups.isEmpty && !matchesReader {
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
                switch selection {
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

    private func openCapturedText(_ image: CGImage, language: String?) {
        do {
            let attachment = try CaptureTextAttachment(image: image)
            var draft = session.drafts[.extractText, default: ToolDraft()]
            draft.inputs = [attachment.url]
            draft.captureAttachments = [attachment]
            draft.options.textExtraction.language = language
            draft.options.textExtraction.range = ""
            draft.options.textExtraction.region = nil
            session.drafts[.extractText] = draft
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
        sidebarButton(tool.title, icon: tool.symbol, destination: .tool(tool))
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
