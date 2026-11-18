import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct DocumentScannerDraft {
    var pages: [ScannedPage] = []
    var selection: UUID?
    var paper = PDFImagePaper.a4
}

struct DocumentScannerView: View {
    @Binding var draft: DocumentScannerDraft
    @State private var issue: String?
    @State private var importing = false
    @State private var exporting = false
    @State private var progress = 0.0
    @State private var exported: URL?
    @State private var correctedPreview: CGImage?
    @State private var retakePage: UUID?
    @State private var pendingRetake: (target: UUID, page: ScannedPage)?
    @State private var cameraImport: Task<Void, Never>?
    @State private var cameraRequest: UUID?

    private struct PreviewKey: Equatable {
        let id: UUID
        let corners: ScanCorners
        let rotation: Int
        let color: ScanColor
    }

    private var selectedIndex: Int? { draft.pages.firstIndex { $0.id == draft.selection } }

    var body: some View {
        InteractiveToolLayout(tool: .scanDocument) { palette in
            WorkspaceSection("Pages", palette: palette) {
                HStack {
                    Button("Import Photos or Scans…", systemImage: "photo.on.rectangle", action: { chooseImages() })
                        .disabled(importing || exporting || pendingRetake != nil)
                    ClipboardFileButton(allowedTypes: [.image, .pdf], onPasteImage: { image in
                        let attachment = try CaptureTextAttachment(image: image, filename: "Pasted Scan.png")
                        importFiles([attachment.url], attachment: attachment)
                    }) { files in importFiles(files) }
                        .disabled(importing || exporting || pendingRetake != nil)
                    if importing { ProgressView().controlSize(.small) }
                    if cameraRequest != nil {
                        Button("Cancel Camera Import", action: cancelCameraImport)
                    }
                }
                if let pendingRetake, let target = draft.pages.first(where: { $0.id == pendingRetake.target }) {
                    HStack(spacing: 12) {
                        Image(decorative: pendingRetake.page.image, scale: 1)
                            .resizable().scaledToFit().frame(width: 60, height: 72)
                            .accessibilityLabel("Replacement scan")
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Replace \(target.name) with the new camera scan?")
                                .font(.callout).foregroundStyle(.secondary)
                            HStack {
                                Button("Replace Page") { confirmRetake(pendingRetake) }
                                    .buttonStyle(.borderedProminent)
                                Button("Keep Original") { self.pendingRetake = nil }
                            }
                            .disabled(exporting)
                        }
                    }
                } else if let target = draft.pages.first(where: { $0.id == retakePage }) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Scan a replacement for \(target.name) using Scan Documents in Import from iPhone or iPad.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Cancel Retake") { retakePage = nil }
                    }
                } else {
                    Text("Use Import from iPhone or iPad in the system menu when Continuity Camera is available.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(draft.pages.enumerated()), id: \.element.id) { index, page in
                    HStack {
                        Button("\(index + 1). \(page.name)") { draft.selection = page.id }
                            .buttonStyle(.plain)
                            .font(draft.selection == page.id ? .headline : .body)
                        Spacer()
                        Button("Move up", systemImage: "arrow.up") { move(page, by: -1) }
                            .disabled(index == 0 || exporting)
                        Button("Move down", systemImage: "arrow.down") { move(page, by: 1) }
                            .disabled(index == draft.pages.count - 1 || exporting)
                        Button("Remove page", systemImage: "xmark") { remove(page) }
                            .disabled(exporting)
                    }
                    .labelStyle(.iconOnly)
                }
            }
            if let index = selectedIndex {
                let page = draft.pages[index]
                let previewKey = PreviewKey(id: page.id, corners: page.corners, rotation: page.rotation, color: page.color)
                WorkspaceSection("Correct Page", palette: palette) {
                    ScanCornerCanvas(image: draft.pages[index].image, corners: $draft.pages[index].corners)
                        .frame(height: 290)
                        .id(draft.pages[index].id)
                        .disabled(exporting)
                    HStack {
                        Button("Reset corners") { draft.pages[index].corners = .fullPage }
                        Button("Rotate", systemImage: "rotate.right") {
                            draft.pages[index].rotation = (draft.pages[index].rotation + 1) % 4
                        }
                        Menu("Replace Page") {
                            Button("Choose File…") { chooseImages(replacing: page.id) }
                            Button("Retake with iPhone or iPad") {
                                retakePage = page.id
                                issue = nil
                            }
                        }
                        .disabled(importing || pendingRetake != nil)
                    }
                    .disabled(exporting)
                    if !draft.pages[index].corners.isValid {
                        Text("Move the corners to form a non-crossing quadrilateral.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Picker("Color", selection: $draft.pages[index].color) {
                        ForEach(ScanColor.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .disabled(exporting)
                    DisclosureGroup("Corrected Page Preview") {
                        if let correctedPreview {
                            Image(decorative: correctedPreview, scale: 1)
                                .resizable().scaledToFit().frame(maxHeight: 220)
                                .accessibilityLabel("Corrected page preview")
                        }
                    }
                }
                .task(id: previewKey) {
                    correctedPreview = nil
                    guard page.corners.isValid else { return }
                    do {
                        try await Task.sleep(for: .milliseconds(200))
                        let image = try await Task.detached(priority: .userInitiated) { try DocumentScanner.corrected(page) }.value
                        guard !Task.isCancelled else { return }
                        correctedPreview = image
                    } catch { }
                }
            }
            if !draft.pages.isEmpty {
                WorkspaceSection("Export", palette: palette) {
                    Picker("Paper", selection: $draft.paper) {
                        ForEach([PDFImagePaper.a4, .letter, .original]) { Text($0.rawValue).tag($0) }
                    }
                    HStack {
                        Button("Save PDF…", systemImage: "square.and.arrow.up", action: save)
                            .buttonStyle(.borderedProminent)
                            .disabled(exporting || importing || draft.pages.contains { !$0.corners.isValid })
                        if let exported {
                            Button("Reveal PDF", systemImage: "folder") {
                                NSWorkspace.shared.activateFileViewerSelecting([exported])
                            }
                        }
                    }
                    if exporting { ProgressView(value: progress) }
                }
            }
            if let issue {
                Text(issue).font(.callout).foregroundStyle(.secondary)
            }
        }
        .importsItemProviders(importing || exporting || pendingRetake != nil ? [] : [.image, .pdf]) { providers in
            guard !providers.isEmpty, !importing, !exporting, pendingRetake == nil else { return false }
            let replacement = retakePage
            retakePage = nil
            if replacement != nil, providers.count != 1 {
                issue = "Scan a single page to replace the selected page."
                return false
            }
            let request = UUID()
            cameraRequest = request
            importing = true
            cameraImport = Task { await importContinuity(providers, replacing: replacement, request: request) }
            return true
        }
        .onDisappear {
            cancelCameraImport()
            retakePage = nil
            pendingRetake = nil
        }
    }

    private func chooseImages(replacing pageID: UUID? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = pageID == nil
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls, replacing: pageID)
    }

    private func importFiles(_ urls: [URL], replacing pageID: UUID? = nil, attachment: CaptureTextAttachment? = nil) {
        retakePage = nil
        pendingRetake = nil
        importing = true
        issue = nil
        Task {
            defer { importing = false; withExtendedLifetime(attachment) {} }
            for url in urls {
                do {
                    let pages = try await Task.detached(priority: .userInitiated) {
                        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard bytes <= DocumentScanner.inputLimit else { throw ToolError.invalid("The file exceeds 48 MB.") }
                        return try DocumentScanner.load(Data(contentsOf: url), name: url.lastPathComponent)
                    }.value
                    try insert(pages, replacing: pageID)
                } catch {
                    issue = "\(url.lastPathComponent) · \(error.localizedDescription)"
                }
            }
        }
    }

    private func importContinuity(_ providers: [NSItemProvider], replacing pageID: UUID?, request: UUID) async {
        defer {
            if cameraRequest == request {
                cameraRequest = nil
                cameraImport = nil
                importing = false
            }
        }
        issue = nil
        for provider in providers {
            let identifier = provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
                ? UTType.pdf.identifier : UTType.image.identifier
            do {
                let data: Data = try await withCheckedThrowingContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, error in
                        if let data { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: error ?? ToolError.invalid("No scan was imported.")) }
                    }
                }
                try Task.checkCancellation()
                let name = provider.suggestedName ?? "Camera Scan"
                let pages = try await Task.detached(priority: .userInitiated) {
                    try DocumentScanner.load(data, name: name)
                }.value
                try Task.checkCancellation()
                guard cameraRequest == request else { return }
                if let pageID {
                    guard pages.count == 1, let page = pages.first, draft.pages.contains(where: { $0.id == pageID }) else {
                        throw ToolError.invalid("Choose exactly one replacement page for a scan still in the document.")
                    }
                    pendingRetake = (pageID, page)
                } else {
                    try insert(pages, replacing: nil)
                }
            } catch {
                guard !Task.isCancelled, cameraRequest == request else { return }
                issue = error.localizedDescription
            }
        }
    }

    private func cancelCameraImport() {
        guard cameraRequest != nil else { return }
        cameraRequest = nil
        cameraImport?.cancel()
        cameraImport = nil
        importing = false
    }

    private func confirmRetake(_ pending: (target: UUID, page: ScannedPage)) {
        pendingRetake = nil
        do { try insert([pending.page], replacing: pending.target) }
        catch { issue = error.localizedDescription }
    }

    private func insert(_ pages: [ScannedPage], replacing id: UUID?) throws {
        if let id {
            guard pages.count == 1, let index = draft.pages.firstIndex(where: { $0.id == id }), let first = pages.first else {
                throw ToolError.invalid("Choose exactly one replacement page.")
            }
            draft.pages[index] = first
            draft.selection = first.id
            return
        }
        guard draft.pages.count + pages.count <= DocumentScanner.pageLimit else {
            throw ToolError.invalid("A scan can contain up to \(DocumentScanner.pageLimit) pages.")
        }
        draft.pages.append(contentsOf: pages)
        if draft.selection == nil { draft.selection = pages.first?.id }
    }

    private func move(_ page: ScannedPage, by offset: Int) {
        guard let index = draft.pages.firstIndex(where: { $0.id == page.id }),
              draft.pages.indices.contains(index + offset) else { return }
        draft.pages.swapAt(index, index + offset)
    }

    private func remove(_ page: ScannedPage) {
        draft.pages.removeAll { $0.id == page.id }
        if retakePage == page.id { retakePage = nil }
        if pendingRetake?.target == page.id { pendingRetake = nil }
        if draft.selection == page.id { draft.selection = draft.pages.first?.id }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Document Scan.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let replacingConfirmedOutput = FileManager.default.fileExists(atPath: url.path)
        let pages = draft.pages
        let paper = draft.paper
        exporting = true
        progress = 0
        issue = nil
        Task {
            defer { exporting = false }
            do {
                try await DocumentScanner.export(
                    pages, to: url, paper: paper, replacingConfirmedOutput: replacingConfirmedOutput
                ) { value in
                    await MainActor.run { progress = value }
                }
                exported = url
            } catch {
                issue = error.localizedDescription
            }
        }
    }
}

private struct ScanCornerCanvas: View {
    let image: CGImage
    @Binding var corners: ScanCorners
    @FocusState private var focusedCorner: Int?

    var body: some View {
        GeometryReader { canvas in
            let scale = min(canvas.size.width / CGFloat(image.width), canvas.size.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            ZStack {
                Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                ZStack(alignment: .topLeading) {
                    Path { outline in
                        for (index, point) in corners.points.enumerated() {
                            let p = CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
                            if index == 0 { outline.move(to: p) } else { outline.addLine(to: p) }
                        }
                        outline.closeSubpath()
                    }
                    .stroke(corners.isValid ? Color.accentColor : Color.red, lineWidth: 2)
                    ForEach(corners.points.indices, id: \.self) { index in
                        let point = corners.points[index]
                        Circle()
                            .fill(.white)
                            .overlay { Circle().stroke(Color.accentColor, lineWidth: focusedCorner == index ? 4 : 2) }
                            .frame(width: 18, height: 18)
                            .focusable()
                            .focused($focusedCorner, equals: index)
                            .onMoveCommand { direction in
                                switch direction {
                                case .left: nudge(index, dx: -0.01)
                                case .right: nudge(index, dx: 0.01)
                                case .up: nudge(index, dy: 0.01)
                                case .down: nudge(index, dy: -0.01)
                                @unknown default: break
                                }
                            }
                            .position(x: point.x * size.width, y: (1 - point.y) * size.height)
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("scan-page")).onChanged { drag in
                                guard size.width > 0, size.height > 0 else { return }
                                corners.set(CGPoint(x: min(1, max(0, drag.location.x / size.width)),
                                                    y: min(1, max(0, 1 - drag.location.y / size.height))), at: index)
                            })
                            .accessibilityLabel(["Top left corner", "Top right corner", "Bottom right corner", "Bottom left corner"][index])
                            .accessibilityValue("Horizontal \(Int(point.x * 100)) percent, vertical \(Int((1 - point.y) * 100)) percent")
                            .accessibilityHint("Use the arrow keys to move this corner.")
                            .accessibilityAction(named: Text("Move Left")) { nudge(index, dx: -0.01) }
                            .accessibilityAction(named: Text("Move Right")) { nudge(index, dx: 0.01) }
                            .accessibilityAction(named: Text("Move Up")) { nudge(index, dy: 0.01) }
                            .accessibilityAction(named: Text("Move Down")) { nudge(index, dy: -0.01) }
                    }
                }
                .frame(width: size.width, height: size.height)
                .coordinateSpace(name: "scan-page")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func nudge(_ index: Int, dx: CGFloat = 0, dy: CGFloat = 0) {
        let point = corners.points[index]
        corners.set(CGPoint(x: min(1, max(0, point.x + dx)), y: min(1, max(0, point.y + dy))), at: index)
    }
}
