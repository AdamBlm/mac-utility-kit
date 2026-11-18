import AppKit
import PDFKit
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
    var options = ToolOptions()
    var ranges: [Int: String] = [:]
    var passwords: [Int: String] = [:]
    var outputName = "Merged"
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
    @State private var sample: VideoSample?
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
                                VStack(alignment: .leading) {
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

                if tool == .resizeImages { imageControls(tool, draft: draft) }
                if tool == .compressVideo {
                    Picker("Output format", selection: option(tool, \.videoFormat)) {
                        ForEach(VideoFormat.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                    }
                    Picker("Codec", selection: option(tool, \.videoCodec)) {
                        ForEach(VideoCodec.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Compression quality", selection: option(tool, \.videoQuality)) {
                        ForEach(VideoQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    HStack {
                        if draft.options.ffmpegExecutable != nil {
                            Text("FFmpeg · Constant quality")
                            Button("Use macOS encoder") { drafts[tool, default: Draft()].options.ffmpegExecutable = nil }
                        } else {
                            Text("macOS encoder")
                        }
                        Button("Choose FFmpeg…") { chooseExecutable(tool, \.ffmpegExecutable) }
                    }
                    Text(draft.options.ffmpegExecutable == nil
                         ? "Quality sets a target bitrate. Exports keep the source resolution."
                         : "Quality sets a constant-quality target. Requires FFmpeg with libx264 or libx265.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Keep exports that are not smaller", isOn: option(tool, \.keepLargerVideos))
                    HStack {
                        Button("Create 5-second sample") { startSample(draft) }
                            .disabled(draft.inputs.isEmpty || job != nil)
                        if let sample {
                            Button("Open sample") { NSWorkspace.shared.open(sample.url) }
                            if let bytes = sample.estimatedBytes {
                                Text("Estimated full size: " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if tool == .mergePDFs {
                    TextField("Output name", text: Binding(
                        get: { drafts[tool, default: Draft()].outputName },
                        set: { drafts[tool, default: Draft()].outputName = $0 }
                    ))
                }

                HStack {
                    Button("Run") { start(tool, draft: draft) }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft.inputs.isEmpty || job != nil)
                    if tool == .mergePDFs {
                        Button("Preview merge") { start(tool, draft: draft, preview: true) }
                            .disabled(draft.inputs.isEmpty || job != nil)
                    }
                    Button("Output folder…") { chooseDestination(for: tool) }
                    Text(draft.destination.lastPathComponent).foregroundStyle(.secondary)
                }
                if let error = errors[tool] {
                    Text(error).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let report = reports[tool] {
                    ForEach(Array(report.summaries.enumerated()), id: \.offset) { _, summary in
                        Text(summary).font(.callout).textSelection(.enabled)
                    }
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
        Picker("Resize by", selection: option(tool, \.imageSizing)) {
            ForEach(ImageSizing.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        switch draft.options.imageSizing {
        case .longestEdge:
            TextField("Longest edge (pixels)", value: Binding(
                get: { drafts[tool, default: Draft()].pixels },
                set: { drafts[tool, default: Draft()].pixels = $0 }
            ), format: .number.grouping(.never))
        case .percentage:
            TextField("Percentage", value: option(tool, \.imagePercentage), format: .number)
        case .dimensions:
            HStack {
                TextField("Width", value: option(tool, \.imageWidth), format: .number)
                TextField("Height", value: option(tool, \.imageHeight), format: .number)
            }
            Picker("Aspect ratio", selection: option(tool, \.imageFit)) {
                ForEach(ImageFit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        }
        Toggle("Allow upscaling", isOn: option(tool, \.upscale))
        HStack {
            if draft.options.imageMagickExecutable != nil {
                Text("ImageMagick")
                Button("Use macOS image engine") { drafts[tool, default: Draft()].options.imageMagickExecutable = nil }
            } else {
                Text("macOS image engine")
            }
            Button("Choose ImageMagick…") { chooseExecutable(tool, \.imageMagickExecutable) }
        }
        Picker("Output format", selection: option(tool, \.imageFormat)) {
            ForEach(ImageFormat.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
        }
        if draft.options.imageFormat == .jpg || draft.options.imageFormat == .heic {
            Slider(value: option(tool, \.imageQuality), in: 0.1...1) {
                Text("Quality \(draft.options.imageQuality.formatted(.percent.precision(.fractionLength(0))))")
            }
        }
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
