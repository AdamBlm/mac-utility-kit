import AppKit
import SwiftUI
import UtilityCore

@main
struct MacUtilityKitApp: App {
    var body: some Scene {
        WindowGroup { Workspace() }
            .defaultSize(width: 860, height: 600)
    }
}

private struct Draft {
    var inputs: [URL] = []
    var pixels = 1600
    var destination = URL.downloadsDirectory
}

private struct Workspace: View {
    @State private var selection: Tool? = .resizeImages
    @State private var search = ""
    @FocusState private var searching: Bool
    @State private var drafts: [Tool: Draft] = [:]
    @State private var job: Task<Void, Never>?
    @State private var runningTool: Tool?
    @State private var progress = 0.0
    @State private var reports: [Tool: JobReport] = [:]
    @State private var errors: [Tool: String] = [:]

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading) {
                HStack {
                    TextField("Search tools", text: $search)
                        .focused($searching)
                    Button { searching = true } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .keyboardShortcut("k")
                    .help("Search tools")
                }
                .padding(12)
                List(selection: $selection) {
                    ForEach(Tool.allCases.filter {
                        search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
                    }) { tool in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tool.title)
                            Text(tool.category).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(tool)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            if let selection {
                editor(for: selection)
            } else {
                ContentUnavailableView("Choose a tool", systemImage: "wrench.and.screwdriver")
            }
        }
        .toolbar {
            if let runningTool {
                ToolbarItem {
                    HStack {
                        Text(runningTool.title)
                        ProgressView(value: progress).frame(width: 90)
                        Button("Cancel") { job?.cancel() }
                    }
                }
            }
        }
    }

    private func editor(for tool: Tool) -> some View {
        let draft = drafts[tool, default: Draft()]
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(tool.title).font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 12) {
                    Button("Choose files…") { chooseInputs(for: tool) }
                    if draft.inputs.isEmpty {
                        Label("Drop files here to get started", systemImage: "tray.and.arrow.down")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(draft.inputs.enumerated()), id: \.offset) { index, input in
                            HStack {
                                Text(input.lastPathComponent).lineLimit(1)
                                Spacer()
                                if tool == .mergePDFs {
                                    Button("Move up", systemImage: "arrow.up") {
                                        drafts[tool, default: Draft()].inputs.swapAt(index, index - 1)
                                    }.labelStyle(.iconOnly).disabled(index == 0)
                                }
                                Button("Remove", systemImage: "minus.circle") {
                                    drafts[tool, default: Draft()].inputs.remove(at: index)
                                }.labelStyle(.iconOnly)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter(\.isFileURL)
                    drafts[tool, default: Draft()].inputs.append(contentsOf: files)
                    return !files.isEmpty
                }

                if tool == .resizeImages {
                    TextField("Longest edge (pixels)", value: Binding(
                        get: { drafts[tool, default: Draft()].pixels },
                        set: { drafts[tool, default: Draft()].pixels = $0 }
                    ), format: .number.grouping(.never))
                    .frame(maxWidth: 300)
                    Text("Exports a PNG within this size.").font(.caption).foregroundStyle(.secondary)
                }
                if tool == .compressVideo {
                    Text("Exports a smaller MP4 using the system’s medium-quality preset.")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Run") { start(tool, draft: draft) }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft.inputs.isEmpty || job != nil)
                    Button("Output folder…") { chooseDestination(for: tool) }
                    Text(draft.destination.lastPathComponent).foregroundStyle(.secondary)
                }
                if let error = errors[tool] {
                    Text(error).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let report = reports[tool] {
                    ForEach(report.outputs, id: \.self) { output in
                        HStack {
                            Text(output.lastPathComponent)
                            Spacer()
                            Button("Open") { NSWorkspace.shared.open(output) }
                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([output])
                            }
                        }
                    }
                    ForEach(Array(report.failures.enumerated()), id: \.offset) { _, failure in
                        Text(failure).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: 740, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func chooseInputs(for tool: Tool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = tool.inputTypes
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            drafts[tool, default: Draft()].inputs.append(contentsOf: panel.urls)
        }
    }

    private func chooseDestination(for tool: Tool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = drafts[tool, default: Draft()].destination
        if panel.runModal() == .OK, let folder = panel.url {
            drafts[tool, default: Draft()].destination = folder
        }
    }

    private func start(_ tool: Tool, draft: Draft) {
        runningTool = tool
        progress = 0
        reports[tool] = nil
        errors[tool] = nil
        job = Task { @MainActor in
            defer {
                job = nil
                runningTool = nil
            }
            do {
                reports[tool] = try await ToolRunner.run(
                    tool, inputs: draft.inputs, destination: draft.destination, imageSize: draft.pixels
                ) { fraction in
                    await MainActor.run { progress = max(progress, fraction) }
                }
            } catch is CancellationError {
                errors[tool] = "Canceled."
            } catch {
                errors[tool] = error.localizedDescription
            }
        }
    }
}
