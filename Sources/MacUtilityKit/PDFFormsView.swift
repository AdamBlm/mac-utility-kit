import AppKit
import PDFKit
import SwiftUI
import UtilityCore

struct PDFFormsDraft {
    var source: URL?
    var python: URL?
    var mode = PDFFormMode.editable
    var session: PDFForms?
    var exportTask: Task<Void, Never>?
    var exportIssue: String?
}

struct PDFFormsView: View {
    @Binding var draft: PDFFormsDraft
    @State private var page = 0
    @State private var fields: [PDFForms.Field] = []
    @State private var candidates: [PDFForms.Candidate] = []
    @State private var selected: UUID?
    @State private var edit: FieldEdit?
    @State private var originalEdit: FieldEdit?
    @State private var kind = PDFForms.Kind.text
    @State private var placing = false
    @State private var revision = 0
    private var exporting: Bool { draft.exportTask != nil }
    @State private var issue: String?

    private var session: PDFForms? { draft.session }

    private struct FieldEdit: Equatable {
        let kind: PDFForms.Kind
        var name: String
        var value: String
        var checked: Bool
        var x: String
        var y: String
        var width: String
        var height: String

        init(_ field: PDFForms.Field) {
            kind = field.kind
            name = field.name
            value = field.value
            checked = field.checked
            x = String(Double(field.bounds.origin.x))
            y = String(Double(field.bounds.origin.y))
            width = String(Double(field.bounds.width))
            height = String(Double(field.bounds.height))
        }

        var bounds: CGRect? {
            guard let x = Double(x), let y = Double(y), let width = Double(width), let height = Double(height),
                  width >= 0, height >= 0 else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.kind == rhs.kind && lhs.name.utf8.elementsEqual(rhs.name.utf8)
                && lhs.value.utf8.elementsEqual(rhs.value.utf8) && lhs.checked == rhs.checked
                && lhs.x == rhs.x && lhs.y == rhs.y && lhs.width == rhs.width && lhs.height == rhs.height
        }
    }

    var body: some View {
        InteractiveToolLayout(tool: .fillFlattenForms) { palette in
            WorkspaceSection("Source", palette: palette) {
                HStack {
                    Button("Open PDF…", systemImage: "folder", action: open)
                        .disabled(exporting)
                    ClipboardFileButton(allowedTypes: [.pdf], onPasteFile: load)
                        .disabled(exporting)
                    if let source = draft.source { Text(source.lastPathComponent).font(.callout).lineLimit(1) }
                }
            }
            if let session {
                WorkspaceSection("Page", palette: palette) {
                    HStack {
                        Button("Previous Page", systemImage: "chevron.left") { changePage(-1) }
                            .labelStyle(.iconOnly).disabled(page <= 0 || edit != originalEdit)
                        Text("\(page + 1) of \(session.document.pageCount)").monospacedDigit().font(.callout)
                        Button("Next Page", systemImage: "chevron.right") { changePage(1) }
                            .labelStyle(.iconOnly).disabled(page + 1 >= session.document.pageCount || edit != originalEdit)
                        Spacer()
                        Button("Detect Boxes", systemImage: "rectangle.dashed", action: detect)
                    }
                    PDFFormsPreview(document: session.document, page: page, revision: revision,
                                    candidates: candidates.map(\.bounds),
                                    selection: fields.first { $0.id == selected }?.bounds, onClick: picked)
                        .frame(minHeight: 270, maxHeight: 350)
                    HStack {
                        Picker("Field type", selection: $kind) {
                            ForEach(PDFForms.Kind.addable) { Text($0.rawValue).tag($0) }
                        }
                        Button(placing ? "Cancel Placement" : "Place Field", systemImage: "plus.square") {
                            placing.toggle()
                        }
                        .disabled(edit != originalEdit)
                        if placing { Text("Click the page to place the field.").font(.callout).foregroundStyle(.secondary) }
                    }
                }
                .disabled(exporting)
                if !candidates.isEmpty {
                    WorkspaceSection("Review Detected Boxes", palette: palette) {
                        Text("Review the position before adding a suggested field. Coordinates are in PDF points from the page’s lower-left origin.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(candidates) { candidate in
                            HStack {
                                Text("\(candidate.kind.rawValue) · x \(Int(candidate.bounds.minX)), y \(Int(candidate.bounds.minY))")
                                    .font(.callout)
                                Spacer()
                                Button("Add") { add(candidate.kind, bounds: candidate.bounds) }
                                    .disabled(edit != originalEdit)
                            }
                        }
                    }
                    .disabled(exporting)
                }
                WorkspaceSection("Fields", palette: palette) {
                    if fields.isEmpty {
                        Text("No fields on this page.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(fields) { field in
                        Button {
                            select(field)
                        } label: {
                            HStack {
                                Image(systemName: selected == field.id ? "largecircle.fill.circle" : "circle")
                                Text(field.name.isEmpty ? field.kind.rawValue : field.name)
                                if field.isReadOnly { Text("Read-only").foregroundStyle(.secondary) }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(edit != originalEdit)
                    }
                    if let binding = Binding($edit), let field = fields.first(where: { $0.id == selected }), !field.isReadOnly {
                        editor(binding)
                    }
                }
                .disabled(exporting)
                WorkspaceSection("Export", palette: palette) {
                    SettingRow("Format") {
                        Picker("Export format", selection: $draft.mode) {
                            ForEach(PDFFormMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                    }
                    if draft.mode == .flattened {
                        Text("Flattened export burns all page annotations into the PDF.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Choose Python with pypdf…", action: choosePython)
                        if let python = draft.python { Text(python.path).font(.caption).lineLimit(1) }
                    }
                    Button("Export PDF…", systemImage: "square.and.arrow.up", action: export)
                        .disabled(draft.python == nil || edit != originalEdit)
                    if edit != originalEdit {
                        Text("Apply field changes before exporting.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(exporting)
                if exporting {
                    ProgressView("Verifying PDF…").controlSize(.small)
                    Button("Cancel Export") { draft.exportTask?.cancel() }
                }
                if let exportIssue = draft.exportIssue {
                    Text(exportIssue).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let issue { Label(issue, systemImage: "exclamationmark.circle").font(.callout) }
        }
        .onAppear {
            if session != nil { refresh() }
            else if let source = draft.source { load(source) }
        }
    }

    private func editor(_ edit: Binding<FieldEdit>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Field label", text: edit.name)
            if edit.wrappedValue.kind == .checkbox {
                Toggle("Checked", isOn: edit.checked)
            } else {
                TextField("Field value", text: edit.value, axis: .vertical)
                    .lineLimit(1...3)
            }
            HStack {
                TextField("X", text: edit.x, prompt: Text("X"))
                    .accessibilityLabel("Horizontal position")
                TextField("Y", text: edit.y, prompt: Text("Y"))
                    .accessibilityLabel("Vertical position")
                TextField("Width", text: edit.width, prompt: Text("Width"))
                TextField("Height", text: edit.height, prompt: Text("Height"))
            }
            .textFieldStyle(.roundedBorder)
            Text("Position and size in PDF points · X, Y, Width, Height").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Apply Changes", action: apply).disabled(edit.wrappedValue == originalEdit)
                Button("Discard Edits") { self.edit = originalEdit }
                    .disabled(edit.wrappedValue == originalEdit)
                Button("Remove Field", role: .destructive, action: remove)
            }
        }
    }

    private func open() {
        if let url = DeveloperToolFiles.choose(allowedTypes: [.pdf]) { load(url) }
    }

    private func load(_ source: URL) {
        do {
            draft.session = try PDFForms(source: source)
            draft.source = source
            page = 0
            placing = false
            candidates = []
            refresh()
            select(nil)
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    private func changePage(_ delta: Int) {
        page += delta
        candidates = []
        placing = false
        refresh()
        select(nil)
    }

    private func refresh() {
        fields = session?.fields(on: page) ?? []
        revision += 1
    }

    private func select(_ field: PDFForms.Field?) {
        selected = field?.id
        edit = field.map(FieldEdit.init)
        originalEdit = edit
    }

    private func detectedPage() -> PDFPage? { session?.document.page(at: page) }

    private func picked(_ location: CGPoint) {
        guard !exporting else { return }
        guard edit == originalEdit else { return }
        if !placing {
            if let field = fields.last(where: { $0.bounds.contains(location) }) { select(field) }
            return
        }
        guard let pageBounds = detectedPage()?.bounds(for: .cropBox) else { return }
        let size = kind == .checkbox ? CGSize(width: 17, height: 17) : CGSize(width: 112, height: 24)
        let width = min(size.width, pageBounds.width)
        let height = min(size.height, pageBounds.height)
        let x = min(max(location.x - width / 2, pageBounds.minX), pageBounds.maxX - width)
        let y = min(max(location.y - height / 2, pageBounds.minY), pageBounds.maxY - height)
        add(kind, bounds: CGRect(x: x, y: y, width: width, height: height))
        placing = false
    }

    private func detect() {
        do {
            candidates = try session?.candidates(on: page) ?? []
            issue = candidates.isEmpty ? "No box candidates were detected." : nil
        } catch {
            issue = error.localizedDescription
        }
    }

    private func add(_ kind: PDFForms.Kind, bounds: CGRect) {
        do {
            let id = try session?.add(kind, on: page, bounds: bounds, name: kind.rawValue + "-" + UUID().uuidString.prefix(8))
            refresh()
            select(fields.first { $0.id == id })
            candidates.removeAll { $0.bounds.intersects(bounds) }
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    private func apply() {
        guard let selected, let edit else { return }
        do {
            guard let bounds = edit.bounds else { throw ToolError.invalid("Enter valid position and size values.") }
            try session?.update(selected, name: edit.name, value: edit.value, checked: edit.checked, bounds: bounds)
            refresh()
            select(fields.first { $0.id == selected })
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    private func remove() {
        guard let selected else { return }
        do {
            try session?.remove(selected)
            refresh()
            select(nil)
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    private func choosePython() {
        if let url = DeveloperToolFiles.choose() { draft.python = url }
    }

    private func export() {
        guard let session, let python = draft.python, edit == originalEdit else { return }
        let mode = draft.mode
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let suffix = mode == .editable ? "-editable.pdf" : "-flattened.pdf"
        panel.nameFieldStringValue = session.source.deletingPathExtension().lastPathComponent + suffix
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard !exporting else { return }
        let output: PDFFormDestination
        do {
            output = try PDFFormDestination(destination, preserving: session.source)
        } catch {
            issue = error.localizedDescription
            return
        }
        issue = nil
        draft.exportIssue = nil
        let center = ExportActivityCenter.shared
        let job = center.start(.fillFlattenForms) { draft.exportTask?.cancel() }
        draft.exportTask = Task {
            defer {
                center.finish(job)
                draft.exportTask = nil
            }
            do {
                let data = try await session.export(mode, python: python)
                try Task.checkCancellation()
                try output.publish(data)
                center.postCompletion(.fillFlattenForms, outputs: 1)
            } catch is CancellationError {
                draft.exportIssue = "Export canceled."
            } catch {
                draft.exportIssue = error.localizedDescription
            }
        }
    }
}

private struct PDFFormsPreview: NSViewRepresentable {
    let document: PDFDocument
    let page: Int
    let revision: Int
    let candidates: [CGRect]
    let selection: CGRect?
    let onClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> PlacementView {
        let view = PlacementView()
        view.displayMode = .singlePage
        view.autoScales = true
        view.setUpOverlay()
        return view
    }

    func updateNSView(_ view: PlacementView, context: Context) {
        if view.document !== document { view.document = document }
        if let target = document.page(at: page) {
            if view.currentPage !== target { view.go(to: target) }
            if view.revision != revision {
                view.revision = revision
                view.annotationsChanged(on: target)
            }
        }
        view.onClick = onClick
        view.candidates = candidates
        view.selection = selection
        view.overlay.needsDisplay = true
    }

    final class PlacementView: PDFView {
        var revision = -1
        var onClick: ((CGPoint) -> Void)?
        var candidates: [CGRect] = []
        var selection: CGRect?
        let overlay = OverlayView()

        func setUpOverlay() {
            overlay.frame = bounds
            overlay.autoresizingMask = [.width, .height]
            overlay.drawBoxes = { [weak self] in
                guard let self, let page = currentPage else { return }
                for candidate in candidates {
                    let path = NSBezierPath(rect: convert(candidate, from: page))
                    path.lineWidth = 2
                    path.setLineDash([4, 3], count: 2, phase: 0)
                    NSColor.systemOrange.setStroke()
                    path.stroke()
                }
                if let selection {
                    let path = NSBezierPath(rect: convert(selection, from: page).insetBy(dx: -2, dy: -2))
                    path.lineWidth = 2
                    NSColor.controlAccentColor.setStroke()
                    path.stroke()
                }
            }
            addSubview(overlay, positioned: .above, relativeTo: nil)
        }

        override func layout() {
            super.layout()
            overlay.needsDisplay = true
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard let page = page(for: point, nearest: false) else { return }
            onClick?(convert(point, to: page))
        }
    }

    final class OverlayView: NSView {
        var drawBoxes: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) { drawBoxes?() }
    }
}
