import AppKit
import PDFKit
import SwiftUI
import UtilityCore

@main
struct MacUtilityKitApp: App {
    var body: some Scene {
        WindowGroup("Mac Utility Kit") { Workspace() }
            .windowToolbarStyle(.unifiedCompact(showsTitle: false))
            .defaultSize(width: 940, height: 690)
    }
}

private struct Draft {
    var inputs: [URL] = []
    var pixels = 1600
    var options = ToolOptions()
    var ranges: [Int: String] = [:]
    var passwords: [Int: String] = [:]
    var outputName = "Merged"
    var destination = URL.downloadsDirectory
}

private struct Workspace: View {
    @State private var selection: Tool? = .resizeImages
    @State private var search = ""
    @State private var dropTarget: Tool?
    @State private var advancedTools: Set<Tool> = []
    @FocusState private var searching: Bool
    @State private var drafts: [Tool: Draft] = [:]
    @State private var job: Task<Void, Never>?
    @State private var runningTool: Tool?
    @State private var progress = 0.0
    @State private var sample: VideoSample?
    @State private var reports: [Tool: JobReport] = [:]
    @State private var errors: [Tool: String] = [:]

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
                    let draft = drafts[selection, default: Draft()]
                    if draft.inputs.isEmpty, reports[selection] == nil,
                       errors[selection] == nil, runningTool != selection {
                        emptyWorkspace(for: selection)
                    } else {
                        editor(for: selection)
                    }
                } else {
                    ContentUnavailableView("Choose a tool", systemImage: "wrench.and.screwdriver")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let runningTool {
                    HStack(spacing: 12) {
                        Text(runningTool.title)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        ProgressView(value: progress).frame(width: 88)
                        Button("Cancel") { job?.cancel() }
                    }
                    .font(.callout)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(palette.surface)
                    .overlay(alignment: .bottom) { Divider() }
                }
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .tint(palette.accent)
    }

    private func editor(for tool: Tool) -> some View {
        let draft = drafts[tool, default: Draft()]
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 15) {
                        ToolEmblem(tool: tool, palette: palette)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tool.title)
                                .font(.system(size: 29, weight: .semibold))
                                .tracking(-0.65)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(draft.inputs.isEmpty ? "Source files" : "Source files · \(draft.inputs.count)")
                                .font(.system(size: 13, weight: .semibold))
                                .accessibilityAddTraits(.isHeader)
                            Spacer()
                            if !draft.inputs.isEmpty {
                                Button("Add files…", systemImage: "plus") { chooseInputs(for: tool) }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(palette.accent)
                            }
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            if draft.inputs.isEmpty {
                                dropWell(for: tool)
                            } else {
                                ForEach(Array(draft.inputs.enumerated()), id: \.offset) { index, input in
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack(spacing: 10) {
                                            Image(systemName: tool.symbol)
                                                .foregroundStyle(palette.accent)
                                                .frame(width: 20)
                                                .accessibilityHidden(true)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(input.lastPathComponent).lineLimit(1)
                                                if tool == .resizeImages {
                                                    Text((try? ToolRunner.imagePreview(input, longestEdge: draft.pixels, options: draft.options)) ?? "Check image or sizing options")
                                                        .font(.caption).foregroundStyle(.secondary)
                                                }
                                            }
                                            Spacer()
                                            if tool == .mergePDFs {
                                                Button("Move up", systemImage: "arrow.up") {
                                                    var draft = drafts[tool, default: Draft()]
                                                    draft.inputs.swapAt(index, index - 1)
                                                    let current = draft.ranges[index]
                                                    draft.ranges[index] = draft.ranges[index - 1]
                                                    draft.ranges[index - 1] = current
                                                    let password = draft.passwords[index]
                                                    draft.passwords[index] = draft.passwords[index - 1]
                                                    draft.passwords[index - 1] = password
                                                    drafts[tool] = draft
                                                }.labelStyle(.iconOnly).disabled(index == 0)
                                            }
                                            Button("Remove", systemImage: "minus.circle") {
                                                var draft = drafts[tool, default: Draft()]
                                                draft.inputs.remove(at: index)
                                                draft.ranges = afterRemoving(index, from: draft.ranges)
                                                draft.passwords = afterRemoving(index, from: draft.passwords)
                                                drafts[tool] = draft
                                            }.labelStyle(.iconOnly)
                                        }
                                        if tool == .mergePDFs {
                                            pageControls(input, index: index, tool: tool)
                                                .padding(.leading, 30)
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    if index < draft.inputs.count - 1 { Divider().padding(.leading, 44) }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(draft.inputs.isEmpty ? palette.wash : palette.surface,
                                    in: RoundedRectangle(cornerRadius: 16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(dropTarget == tool ? palette.accent : palette.line,
                                              style: StrokeStyle(lineWidth: 1, dash: draft.inputs.isEmpty ? [5, 4] : []))
                                .allowsHitTesting(false)
                        }
                        .dropDestination(for: URL.self) { urls, _ in
                            addDroppedFiles(urls, to: tool)
                        } isTargeted: { targeted in
                            updateDropTarget(for: tool, targeted: targeted)
                        }
                    }

                    WorkspaceSection("Settings", palette: palette) {
                        switch tool {
                        case .resizeImages:
                            imageControls(tool, draft: draft)
                        case .compressVideo:
                            videoControls(tool, draft: draft)
                        case .mergePDFs:
                            SettingRow("Output filename") {
                                TextField("Output filename", text: Binding(
                                    get: { drafts[tool, default: Draft()].outputName },
                                    set: { drafts[tool, default: Draft()].outputName = $0 }
                                ))
                                .labelsHidden()
                            }
                        }
                    }
                    if let error = errors[tool] {
                        Label(error, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let report = reports[tool] {
                        WorkspaceSection("Results", palette: palette) {
                            ForEach(Array(report.summaries.enumerated()), id: \.offset) { _, summary in
                                Text(summary).font(.callout).textSelection(.enabled)
                            }
                            ForEach(report.outputs, id: \.self) { output in
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(palette.accent)
                                        .accessibilityHidden(true)
                                    Text(output.lastPathComponent).lineLimit(1)
                                    Spacer()
                                    Button("Open") { NSWorkspace.shared.open(output) }
                                    Button("Reveal") {
                                        NSWorkspace.shared.activateFileViewerSelecting([output])
                                    }
                                }
                            }
                            ForEach(Array(report.failures.enumerated()), id: \.offset) { _, failure in
                                Label(failure, systemImage: "exclamationmark.circle")
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
                .frame(maxWidth: 660, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(palette.canvas)
            Divider()
            HStack(spacing: 12) {
                Button {
                    chooseDestination(for: tool)
                } label: {
                    Label(draft.destination.lastPathComponent, systemImage: "folder")
                        .lineLimit(1)
                }
                .help("Choose output folder")
                .accessibilityLabel("Output folder: \(draft.destination.lastPathComponent)")
                Spacer()
                if tool == .mergePDFs {
                    Button("Preview") { start(tool, draft: draft, preview: true) }
                        .disabled(draft.inputs.isEmpty || job != nil)
                }
                Button(tool.title) { start(tool, draft: draft) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.inputs.isEmpty || job != nil)
            }
            .controlSize(.large)
            .frame(maxWidth: 660)
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(palette.surface)
        }
    }

    private func emptyWorkspace(for tool: Tool) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 32)
            VStack(spacing: 15) {
                ToolEmblem(tool: tool, palette: palette, large: true)
                    .padding(.bottom, 6)
                Text(tool.title)
                    .font(.system(size: 36, weight: .semibold))
                    .tracking(-1.25)
                    .accessibilityAddTraits(.isHeader)
                Text(tool.subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Choose files…") { chooseInputs(for: tool) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
                Text(dropTarget == tool ? "Release to add files" : tool.dropHint)
                    .font(.callout)
                    .foregroundStyle(dropTarget == tool ? palette.accent : .secondary)
            }
            .padding(.horizontal, 28)
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.canvas)
        .overlay {
            if dropTarget == tool {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(palette.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .padding(16)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            addDroppedFiles(urls, to: tool)
        } isTargeted: { targeted in
            updateDropTarget(for: tool, targeted: targeted)
        }
    }

    private func addDroppedFiles(_ urls: [URL], to tool: Tool) -> Bool {
        let files = urls.filter(\.isFileURL)
        drafts[tool, default: Draft()].inputs.append(contentsOf: files)
        return !files.isEmpty
    }

    private func updateDropTarget(for tool: Tool, targeted: Bool) {
        if targeted { dropTarget = tool }
        else if dropTarget == tool { dropTarget = nil }
    }

    private func dropWell(for tool: Tool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)
            Text(tool.dropTitle).font(.system(size: 14, weight: .semibold))
            Button("Choose files…") { chooseInputs(for: tool) }
                .foregroundStyle(palette.accent)
                .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 23)
        .background(dropTarget == tool ? palette.accent.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 16))
    }

    private func afterRemoving(_ index: Int, from values: [Int: String]) -> [Int: String] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            key == index ? nil : (key > index ? key - 1 : key, value)
        })
    }

    private func option<Value>(_ tool: Tool, _ path: WritableKeyPath<ToolOptions, Value>) -> Binding<Value> {
        Binding(
            get: { drafts[tool, default: Draft()].options[keyPath: path] },
            set: { drafts[tool, default: Draft()].options[keyPath: path] = $0 }
        )
    }

    private func pageControls(_ input: URL, index: Int, tool: Tool) -> some View {
        let range = Binding(
            get: { drafts[tool, default: Draft()].ranges[index, default: ""] },
            set: { drafts[tool, default: Draft()].ranges[index] = $0 }
        )
        let password = Binding(
            get: { drafts[tool, default: Draft()].passwords[index, default: ""] },
            set: { drafts[tool, default: Draft()].passwords[index] = $0 }
        )
        return PDFPageControls(input: input, range: range, password: password).id(input)
    }

    @ViewBuilder
    private func imageControls(_ tool: Tool, draft: Draft) -> some View {
        SettingRow("Resize by") {
            Picker("Resize by", selection: option(tool, \.imageSizing)) {
                ForEach(ImageSizing.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
        }

        switch draft.options.imageSizing {
        case .longestEdge:
            SettingRow("Longest edge") {
                HStack {
                    TextField("Longest edge (pixels)", value: Binding(
                        get: { drafts[tool, default: Draft()].pixels },
                        set: { drafts[tool, default: Draft()].pixels = $0 }
                    ), format: .number.grouping(.never))
                    .labelsHidden()
                    Text("px").foregroundStyle(.secondary)
                }
            }
        case .percentage:
            SettingRow("Scale") {
                HStack {
                    TextField("Percentage", value: option(tool, \.imagePercentage), format: .number)
                        .labelsHidden()
                    Text("%").foregroundStyle(.secondary)
                }
            }
        case .dimensions:
            SettingRow("Dimensions") {
                HStack {
                    TextField("Width", value: option(tool, \.imageWidth), format: .number)
                        .accessibilityLabel("Width in pixels")
                    Text("×").foregroundStyle(.secondary)
                    TextField("Height", value: option(tool, \.imageHeight), format: .number)
                        .accessibilityLabel("Height in pixels")
                    Text("px").foregroundStyle(.secondary)
                }
            }
            SettingRow("Aspect ratio") {
                Picker("Aspect ratio", selection: option(tool, \.imageFit)) {
                    ForEach(ImageFit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
        }

        SettingRow("Output format") {
            Picker("Output format", selection: option(tool, \.imageFormat)) {
                ForEach(ImageFormat.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        if draft.options.imageFormat == .jpg || draft.options.imageFormat == .heic {
            SettingRow("Quality") {
                HStack {
                    Slider(value: option(tool, \.imageQuality), in: 0.1...1) { Text("Quality") }
                        .labelsHidden()
                    Text(draft.options.imageQuality.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }

        advanced(for: tool) {
            Toggle("Allow upscaling", isOn: option(tool, \.upscale))
            engineControls(tool, path: \.imageMagickExecutable, name: "ImageMagick", current: draft.options.imageMagickExecutable)
        }
    }

    @ViewBuilder
    private func videoControls(_ tool: Tool, draft: Draft) -> some View {
        SettingRow("Output format") {
            Picker("Output format", selection: option(tool, \.videoFormat)) {
                ForEach(VideoFormat.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        SettingRow("Codec") {
            Picker("Codec", selection: option(tool, \.videoCodec)) {
                ForEach(VideoCodec.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        SettingRow("Quality") {
            Picker("Compression quality", selection: option(tool, \.videoQuality)) {
                ForEach(VideoQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        advanced(for: tool) {
            Toggle("Keep exports that are not smaller", isOn: option(tool, \.keepLargerVideos))
            engineControls(tool, path: \.ffmpegExecutable, name: "FFmpeg", current: draft.options.ffmpegExecutable)
            if draft.options.ffmpegExecutable != nil {
                Text("Constant quality requires FFmpeg with libx264 or libx265.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        HStack {
            Button("Create 5-second sample", systemImage: "play.rectangle") { startSample(draft) }
                .disabled(draft.inputs.isEmpty || job != nil)
            if let sample {
                Button("Open sample") { NSWorkspace.shared.open(sample.url) }
                if let bytes = sample.estimatedBytes {
                    Text("Estimated size: " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func advanced<Content: View>(for tool: Tool, @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup("Advanced", isExpanded: Binding(
            get: { advancedTools.contains(tool) },
            set: { expanded in
                if expanded { advancedTools.insert(tool) }
                else { advancedTools.remove(tool) }
            }
        )) {
            VStack(alignment: .leading, spacing: 10, content: content)
                .padding(.top, 10)
        }
        .font(.callout)
    }

    private func engineControls(
        _ tool: Tool, path: WritableKeyPath<ToolOptions, URL?>, name: String, current: URL?
    ) -> some View {
        HStack(spacing: 10) {
            Label(current == nil ? "macOS engine" : name, systemImage: "gearshape")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if current != nil {
                Button("Use macOS") { drafts[tool, default: Draft()].options[keyPath: path] = nil }
            }
            Button("Choose \(name)…") { chooseExecutable(tool, path) }
        }
        .font(.callout)
    }

    private func chooseExecutable(_ tool: Tool, _ path: WritableKeyPath<ToolOptions, URL?>) {
        let panel = NSOpenPanel()
        if panel.runModal() == .OK {
            drafts[tool, default: Draft()].options[keyPath: path] = panel.url
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

    private func startSample(_ draft: Draft) {
        guard let input = draft.inputs.first else { return }
        runningTool = .compressVideo
        progress = 0
        sample = nil
        errors[.compressVideo] = nil
        job = Task { @MainActor in
            defer {
                runningTool = nil
                job = nil
            }
            do {
                sample = try await ToolRunner.sampleVideo(input, destination: draft.destination, options: draft.options)
            } catch is CancellationError {
                errors[.compressVideo] = "Canceled."
            } catch {
                errors[.compressVideo] = error.localizedDescription
            }
        }
    }

    private func start(_ tool: Tool, draft: Draft, preview: Bool = false) {
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
                var options = draft.options
                options.pageRanges = draft.inputs.indices.map { draft.ranges[$0, default: ""] }
                options.pdfOutputName = draft.outputName
                options.pdfPasswords = draft.inputs.indices.map { draft.passwords[$0, default: ""] }
                let report = try await ToolRunner.run(
                    tool, inputs: draft.inputs,
                    destination: preview ? FileManager.default.temporaryDirectory : draft.destination,
                    imageSize: draft.pixels, options: options
                ) { fraction in
                    await MainActor.run { progress = max(progress, fraction) }
                }
                if preview, let output = report.outputs.first {
                    NSWorkspace.shared.open(output)
                } else {
                    reports[tool] = report
                }
            } catch is CancellationError {
                errors[tool] = "Canceled."
            } catch {
                errors[tool] = error.localizedDescription
            }
        }
    }
}


private struct PDFPageControls: View {
    let input: URL
    @Binding var range: String
    @Binding var password: String
    @State private var document: PDFDocument?
    @State private var expanded = false
    @State private var protectedDocument = false
    @State private var unlockFailed = false

    var body: some View {
        let count = document?.pageCount ?? 0
        let selected = try? PageSelection.indices(range, pageCount: count)
        VStack(alignment: .leading, spacing: 6) {
            TextField("Pages (all, none, or e.g. 1, 3–5)", text: $range)
            if protectedDocument {
                HStack {
                    SecureField("PDF password", text: $password)
                    Button("Unlock preview") {
                        guard let fresh = PDFDocument(url: input), fresh.unlock(withPassword: password) else {
                            unlockFailed = true
                            return
                        }
                        document = fresh
                        unlockFailed = false
                    }
                }
                if unlockFailed { Text("Could not unlock PDF preview.").font(.caption) }
            }
            if count > 0 {
                if let selected {
                    Text("\(selected.count) of \(count) pages selected").font(.caption).foregroundStyle(.secondary)
                    if !selected.isEmpty, selected.count <= 40 {
                        Text("Export order: " + selected.map { String($0 + 1) }.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Check the page range. This file has \(count) pages.").font(.caption)
                }
                DisclosureGroup("Page thumbnails", isExpanded: $expanded) {
                    if expanded {
                        HStack {
                            Button("All") { range = "" }
                            Button("Clear") { range = "none" }
                        }
                        ScrollView(.horizontal) {
                            LazyHStack {
                                ForEach(0..<count, id: \.self) { index in
                                    Button {
                                        var pages = selected ?? []
                                        if let position = pages.firstIndex(of: index) {
                                            pages.remove(at: position)
                                        } else {
                                            pages.append(index)
                                        }
                                        range = pages.isEmpty ? "none" : pages.map { String($0 + 1) }.joined(separator: ", ")
                                    } label: {
                                        VStack {
                                            if let thumbnail = document?.page(at: index)?.thumbnail(
                                                of: NSSize(width: 64, height: 82), for: .cropBox
                                            ) {
                                                Image(nsImage: thumbnail)
                                            }
                                            Label("Page \(index + 1)", systemImage: selected?.contains(index) == true
                                                  ? "checkmark.circle.fill" : "circle")
                                                .font(.caption)
                                        }
                                    }
                                    .accessibilityAddTraits(selected?.contains(index) == true ? .isSelected : [])
                                }
                            }
                        }
                    }
                }
            }
        }
        .task(id: input) {
            if (try? input.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .pdf)) == true {
                document = PDFDocument(url: input)
                protectedDocument = document?.isLocked == true
                if protectedDocument, !password.isEmpty {
                    _ = document?.unlock(withPassword: password)
                }
            }
        }
    }
}
