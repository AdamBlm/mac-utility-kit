import AppKit
import PDFKit
import SwiftUI
import UtilityCore

struct PDFSigningSettings: View {
    let input: URL?
    @Binding var options: PDFSignatureOptions
    @Binding var ready: Bool
    let canEdit: Bool

    @State private var document: PDFDocument?
    @State private var passwordError: String?
    @State private var sourceError: String?
    @State private var previewPage = 0

    private enum PagePlacementMode: String, CaseIterable, Identifiable {
        case shared = "Shared Placement"
        case custom = "Custom Placement"
        case excluded = "No Signature"
        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if input != nil {
                Button("Refresh PDF Preview", systemImage: "arrow.clockwise", action: load)
            }
            if let sourceError {
                Text(sourceError).font(.callout).foregroundStyle(.secondary)
            }
            if let document {
                if document.isLocked || !document.allowsCommenting {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SecureField(document.isLocked ? "PDF password" : "Owner password", text: $options.password)
                            Button("Unlock") { unlock() }
                        }
                        if let passwordError {
                            Text(passwordError).font(.caption).foregroundStyle(.secondary)
                        } else if !document.isLocked {
                            Text("This PDF restricts annotations. Enter its owner password.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    signingControls(document)
                }
            }
        }
        .disabled(!canEdit)
        .task(id: input) { load() }
        .onChange(of: canExport, initial: true) { _, valid in ready = valid }
    }

    private func signingControls(_ document: PDFDocument) -> some View {
        let pages = (try? PDFSigning.pageIndices(options.pageRange, pageCount: document.pageCount)) ?? []
        let range = options.pageRange.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentPage = pages.contains(previewPage) ? previewPage : pages.first
        return VStack(alignment: .leading, spacing: 12) {
            PDFExportPagePicker(document: document, range: $options.pageRange, startsWithAll: false)
            if range.isEmpty || range.lowercased() == "none" {
                Text("Choose at least one page to sign.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingRow("Signature") {
                Picker("Signature method", selection: $options.mode) {
                    ForEach(PDFSignatureMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            if options.mode == .typed {
                SettingRow("Name") {
                    TextField("Name on signature", text: $options.text)
                }
            } else {
                SignatureDrawingPad(strokes: $options.strokes)
            }
            SettingRow("Date (optional)") {
                HStack {
                    TextField("Optional date label", text: $options.dateLabel)
                    Button("Today") { options.dateLabel = Date().formatted(date: .abbreviated, time: .omitted) }
                }
            }
            if let currentPage, let page = document.page(at: currentPage), let pageRef = page.pageRef {
                if pages.count > 1 {
                    SettingRow("Preview page") {
                        Picker("Preview page", selection: Binding(
                            get: { currentPage },
                            set: { previewPage = $0 }
                        )) {
                            ForEach(pages, id: \.self) { index in Text("Page \(index + 1)").tag(index) }
                        }
                        .labelsHidden()
                    }
                }
                SettingRow("This page") {
                    Picker("Signature placement for page \(currentPage + 1)", selection: placementMode(for: currentPage + 1)) {
                        ForEach(PagePlacementMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                    }
                    .labelsHidden()
                }
                SignaturePlacementPreview(page: page, size: PDFSigning.visibleSize(for: pageRef), options: options,
                                          placement: placement(for: currentPage + 1),
                                          showsSignature: options.placement(forPage: currentPage + 1) != nil)
                    .id(currentPage)
                if options.pageOverrides[currentPage + 1] == nil, pages.count > 1 {
                    Text("These controls update every page using shared placement.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if (try? PDFSigning.signingPageIndices(options, pageCount: document.pageCount)) == nil {
                    Text("Include at least one page to sign.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("Adds a visible signature annotation. Certificate-based signing is unavailable.")
                .font(.caption).foregroundStyle(.secondary)
            if document.isEncrypted {
                Text("The exported copy is unencrypted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func placementMode(for page: Int) -> Binding<PagePlacementMode> {
        Binding {
            switch options.pageOverrides[page] {
            case .custom: .custom
            case .excluded: .excluded
            case nil: .shared
            }
        } set: { mode in
            switch mode {
            case .shared: options.pageOverrides[page] = nil
            case .custom: options.pageOverrides[page] = .custom(options.placement(forPage: page) ?? options.sharedPlacement)
            case .excluded: options.pageOverrides[page] = .excluded
            }
        }
    }

    private func placement(for page: Int) -> Binding<PDFSignaturePlacement> {
        Binding {
            options.placement(forPage: page) ?? options.sharedPlacement
        } set: { placement in
            switch options.pageOverrides[page] {
            case .custom: options.pageOverrides[page] = .custom(placement)
            case nil: options.sharedPlacement = placement
            case .excluded: break
            }
        }
    }

    private var canExport: Bool {
        guard let document, options.sourceStamp != nil, sourceError == nil,
              !document.isLocked, document.allowsCommenting else { return false }
        return (try? PDFSigning.validate(document: document, options: options)) != nil
    }

    private func load() {
        passwordError = nil
        sourceError = nil
        previewPage = 0
        document = nil
        options.sourceStamp = nil
        guard let input else { return }
        guard let stamp = try? PDFSignatureSourceStamp.read(input), let refreshed = PDFDocument(url: input) else {
            sourceError = "Could not open this PDF."
            return
        }
        guard (try? PDFSignatureSourceStamp.read(input)) == stamp else {
            sourceError = "This PDF changed while opening. Refresh the PDF preview to try again."
            return
        }
        document = refreshed
        options.sourceStamp = stamp
        if !options.password.isEmpty, refreshed.isEncrypted { unlock() }
    }

    private func unlock() {
        guard let input, let stamp = options.sourceStamp,
              (try? PDFSignatureSourceStamp.read(input)) == stamp else {
            sourceError = "This PDF changed after preview. Refresh the PDF preview to unlock it."
            return
        }
        guard let unlocked = PDFDocument(url: input), unlocked.unlock(withPassword: options.password) else {
            passwordError = "Could not unlock this PDF. Check the password."
            return
        }
        guard (try? PDFSignatureSourceStamp.read(input)) == stamp else {
            sourceError = "This PDF changed after preview. Refresh the PDF preview to unlock it."
            return
        }
        passwordError = unlocked.allowsCommenting ? nil : "That password does not allow annotations."
        document = unlocked
    }

}

private struct SignatureDrawingPad: View {
    @Binding var strokes: [[CGPoint]]
    @State private var current: [CGPoint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { context, size in
                for stroke in strokes + [current] where stroke.count > 1 {
                    var path = Path()
                    path.addLines(stroke.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
                    context.stroke(path, with: .color(.primary), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            .aspectRatio(3.5, contentMode: .fit)
            .overlay(alignment: .center) {
                if strokes.isEmpty, current.isEmpty {
                    Text("Draw your signature here").font(.caption).foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .overlay {
                GeometryReader { geometry in
                    let size = geometry.size
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { event in
                                guard current.count < 2_000, size.width > 0, size.height > 0 else { return }
                                let point = CGPoint(x: min(max(event.location.x / size.width, 0), 1),
                                                    y: min(max(event.location.y / size.height, 0), 1))
                                if current.last != point { current.append(point) }
                            }
                            .onEnded { _ in
                                if current.count > 1 {
                                    let available = 8_000 - strokes.reduce(0) { $0 + $1.count }
                                    if available > 1 { strokes.append(Array(current.prefix(available))) }
                                }
                                current = []
                            })
                }
            }
            .accessibilityLabel("Signature drawing area")
            HStack {
                Button("Undo stroke") { if !strokes.isEmpty { strokes.removeLast() } }
                Button("Clear drawing") { strokes.removeAll() }
            }
            .disabled(strokes.isEmpty)
        }
    }
}

private struct SignaturePlacementPreview: View {
    let page: PDFPage
    let size: CGSize
    let options: PDFSignatureOptions
    @Binding var placement: PDFSignaturePlacement
    let showsSignature: Bool
    @State private var thumbnail: NSImage?
    @State private var availableWidth: CGFloat = 440

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if size.width > 0, size.height > 0 {
                let scale = min(min(440, availableWidth) / size.width, 420 / size.height)
                let previewSize = CGSize(width: size.width * scale, height: size.height * scale)
                ZStack {
                    Color.white
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFit()
                    }
                    if showsSignature, let appearance = try? PDFSigning.appearance(on: size, options: options, placement: placement) {
                        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
                                                          tx: 0, ty: previewSize.height)
                        Path(appearance.path).applying(transform)
                            .stroke(Color(red: 0.11, green: 0.14, blue: 0.25),
                                    style: StrokeStyle(lineWidth: appearance.lineWidth * scale, lineCap: .round))
                    }
                }
                .frame(width: previewSize.width, height: previewSize.height)
                .clipShape(Rectangle())
                .overlay { Rectangle().strokeBorder(.secondary.opacity(0.26)) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    guard showsSignature else { return }
                    placement.center = CGPoint(x: min(max(event.location.x / previewSize.width, 0), 1),
                                             y: min(max(event.location.y / previewSize.height, 0), 1))
                })
                .accessibilityLabel("Signature placement preview")
                if showsSignature {
                    Text("Click or drag on the page to position the signature.")
                        .font(.caption).foregroundStyle(.secondary)
                    SettingRow("Signature width") {
                        Slider(value: $placement.width, in: 0.05...0.95) { Text("Signature width") }
                    }
                    DisclosureGroup("Precise placement") {
                        VStack(alignment: .leading, spacing: 8) {
                            SettingRow("Horizontal") {
                                Slider(value: $placement.center.x, in: 0...1) { Text("Horizontal position") }
                            }
                            SettingRow("Vertical") {
                                Slider(value: $placement.center.y, in: 0...1) { Text("Vertical position") }
                            }
                        }
                        .padding(.top, 8)
                    }
                } else {
                    Text("This page will be exported without a new signature.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if width > 0 { availableWidth = width }
        }
        .task(id: ObjectIdentifier(page)) {
            thumbnail = page.thumbnail(of: NSSize(width: 800, height: 840), for: .cropBox)
        }
    }
}
