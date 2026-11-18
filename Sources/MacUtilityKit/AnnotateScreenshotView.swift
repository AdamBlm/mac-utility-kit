import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct AnnotateScreenshotDraft {
    var image: CGImage?
    var version = UUID()
    var history = ScreenshotAnnotationHistory()
    var activeTool: ScreenshotAnnotationKind? = .arrow
    var selected: UUID?
    var color: UInt32 = 0xFF595E
    var stroke = 8.0
    var fontSize = 40.0
    var text = ""
    var format = ScreenshotOutputFormat.png
    var zoom = 0.0

    mutating func setImage(_ image: CGImage) {
        self.image = image
        version = UUID()
        history = ScreenshotAnnotationHistory()
        selected = nil
        zoom = 0
    }
}

struct AnnotateScreenshotView: View {
    @Binding var draft: AnnotateScreenshotDraft
    @State private var busy: Task<Void, Never>?
    @State private var status: String?

    var body: some View {
        InteractiveToolLayout(tool: .annotateScreenshot) { palette in
            HStack {
                Button("Open Image…", systemImage: "folder") {
                    if let url = DeveloperToolFiles.choose(allowedTypes: [.image]) { load(url) }
                }
                if let image = draft.image {
                    Text("\(image.width) × \(image.height) pixels")
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                if busy != nil {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { busy?.cancel() }
                }
            }
            if let image = draft.image {
                WorkspaceSection("Annotations", palette: palette) {
                    toolbar
                    AnnotationInspector(draft: $draft)
                    ScreenshotAnnotationCanvas(image: image, draft: $draft, selectionColor: palette.accent)
                        .id(draft.version)
                }
                .disabled(busy != nil)
                if !draft.history.layers.isEmpty {
                    WorkspaceSection("Layers", palette: palette) { layerControls }
                        .disabled(busy != nil)
                }
                WorkspaceSection("Output", palette: palette) { outputControls(image) }
                    .disabled(busy != nil)
            }
            if let status {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard busy == nil, urls.count == 1, let url = urls.first, url.isFileURL else { return false }
            load(url)
            return true
        }
        .onDisappear { busy?.cancel() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Drawing tool", selection: Binding(get: { draft.activeTool }, set: { tool in
                draft.activeTool = tool
                if tool != nil { draft.selected = nil }
            })) {
                Label("Select and Move", systemImage: "cursorarrow").tag(ScreenshotAnnotationKind?.none)
                ForEach(ScreenshotAnnotationKind.allCases) { kind in
                    Label(kind.rawValue, systemImage: icon(kind)).tag(Optional(kind))
                }
            }
            .labelsHidden()
            Picker("Zoom", selection: $draft.zoom) {
                Text("Fit").tag(0.0)
                ForEach(zoomLevels, id: \.self) { zoom in
                    Text(zoom.formatted(.percent.precision(.fractionLength(0...1)))).tag(zoom)
                }
            }.labelsHidden()
            Spacer()
            Button("Undo", systemImage: "arrow.uturn.backward", action: undo)
                .disabled(!draft.history.canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward", action: redo)
                .disabled(!draft.history.canRedo)
        }
    }

    private var zoomLevels: [Double] {
        guard let image = draft.image else { return [] }
        let pixels = Double(image.width) * Double(image.height)
        let longest = Double(max(image.width, image.height))
        return [0.125, 0.25, 0.5, 1, 2].filter { pixels * $0 * $0 <= 8_000_000 && longest * $0 <= 7_000 }
    }

    private var layerControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(draft.history.layers.reversed()) { layer in
                Button {
                    draft.activeTool = nil
                    draft.selected = layer.id
                } label: {
                    HStack {
                        Label(layerLabel(layer), systemImage: icon(layer.kind))
                            .lineLimit(1)
                        Spacer()
                        if layer.id == draft.selected { Image(systemName: "checkmark") }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(layer.id == draft.selected ? .isSelected : [])
            }
            if let selected = draft.selected,
               let index = draft.history.layers.firstIndex(where: { $0.id == selected }) {
                HStack {
                    Button("Bring Forward", systemImage: "chevron.up") {
                        draft.history.move(selected, by: 1)
                    }
                    .disabled(index == draft.history.layers.count - 1)
                    Button("Send Backward", systemImage: "chevron.down") {
                        draft.history.move(selected, by: -1)
                    }
                    .disabled(index == 0)
                    Spacer()
                    Button("Delete", systemImage: "trash") {
                        draft.history.remove(selected)
                        draft.selected = nil
                    }
                }
            }
        }
    }

    private func outputControls(_ image: CGImage) -> some View {
        HStack {
            Picker("Export format", selection: $draft.format) {
                ForEach(ScreenshotOutputFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
            Button("Copy", systemImage: "doc.on.doc") { flatten(image, export: false) }
            Button("Export…", systemImage: "square.and.arrow.up") { flatten(image, export: true) }
        }
    }

    private func layerLabel(_ layer: ScreenshotAnnotation) -> String {
        switch layer.kind {
        case .text: layer.text.components(separatedBy: .newlines).first ?? "Text"
        case .number: "Callout \(layer.number)"
        default: layer.kind.rawValue
        }
    }

    private func icon(_ kind: ScreenshotAnnotationKind) -> String {
        switch kind {
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .box: "rectangle"
        case .oval: "oval"
        case .text: "textformat"
        case .number: "1.circle"
        }
    }

    private func undo() {
        draft.history.undo()
        sanitizeSelection()
    }

    private func redo() {
        draft.history.redo()
        sanitizeSelection()
    }

    private func sanitizeSelection() {
        if let selected = draft.selected, !draft.history.layers.contains(where: { $0.id == selected }) {
            draft.selected = nil
        }
    }

    private func load(_ input: URL) {
        guard busy == nil else { return }
        status = nil
        busy = Task {
            defer { busy = nil }
            do {
                let image = try await ScreenshotAnnotationRenderer.load(input)
                try Task.checkCancellation()
                draft.setImage(image)
            } catch is CancellationError {
                return
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func flatten(_ image: CGImage, export: Bool) {
        guard busy == nil else { return }
        let layers = draft.history.layers
        let format = draft.format
        status = nil
        busy = Task {
            defer { busy = nil }
            do {
                let work = Task.detached(priority: .userInitiated) {
                    let rendered = try await ScreenshotAnnotationRenderer.flatten(image, layers: layers)
                    return try ScreenshotImageOutput.encode(rendered, format: format)
                }
                let data = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                try Task.checkCancellation()
                if export {
                    try DeveloperToolFiles.save(data, as: "Annotated." + format.fileExtension)
                } else {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    let type: NSPasteboard.PasteboardType = format == .png ? .png : .init(UTType.jpeg.identifier)
                    status = pasteboard.setData(data, forType: type) ? "Copied annotated image." : "Could not copy the image."
                }
            } catch is CancellationError {
                return
            } catch {
                status = error.localizedDescription
            }
        }
    }
}
