import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct QRToolsDraft {
    enum Mode: String, CaseIterable { case generate = "Generate", scan = "Scan" }
    enum Kind: String, CaseIterable { case text = "Text", url = "URL", wiFi = "Wi-Fi" }

    var mode: Mode = .generate
    var kind: Kind = .text
    var text = ""
    var url = ""
    var network = ""
    var security: QRPayload.Security = .wpa
    var hiddenNetwork = false
    var options = QRCodeOptions()

    func payload(password: String) -> QRPayload {
        switch kind {
        case .text: .text(text)
        case .url: .url(url)
        case .wiFi: .wiFi(name: network, security: security, password: password, hidden: hiddenNetwork)
        }
    }
}

struct QRToolsView: View {
    @Binding var draft: QRToolsDraft
    @State private var password = ""
    @State private var previewInput: PreviewInput?
    @State private var preview: CGImage?
    @State private var detections: [QRDetection] = []
    @State private var scannedName: String?
    @State private var generationMessage: String?
    @State private var scanMessage: String?
    @State private var exportingMessage: String?
    @State private var scanTask: Task<Void, Never>?
    @State private var scanning = false
    @State private var dropping = false

    private struct PreviewInput: Equatable {
        var payload: QRPayload
        var options: QRCodeOptions

        static func == (lhs: Self, rhs: Self) -> Bool {
            guard lhs.options == rhs.options, lhs.payload == rhs.payload else { return false }
            let left = try? lhs.payload.encoded()
            let right = try? rhs.payload.encoded()
            return left.map { Data($0.utf8) } == right.map { Data($0.utf8) }
        }
    }

    var body: some View {
        let input = PreviewInput(payload: draft.payload(password: password), options: draft.options)
        InteractiveToolLayout(tool: .qrCode) { palette in
            Picker("Operation", selection: $draft.mode) {
                ForEach(QRToolsDraft.Mode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            if draft.mode == .generate {
                generationSettings(palette)
                previewSection(palette, input: input)
            } else {
                scanSection(palette)
            }
        }
        .task(id: input) {
            exportingMessage = nil
            previewInput = nil
            preview = nil
            generationMessage = nil
            guard (try? input.payload.encoded()) != nil else {
                if case .url(let url) = input.payload, !url.isEmpty {
                    previewInput = input
                    generationMessage = QRToolError.invalidURL.localizedDescription
                }
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(150))
                let generated = try await Task.detached {
                    try QRTools.generate(input.payload, options: input.options)
                }.value
                try Task.checkCancellation()
                previewInput = input
                preview = generated
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
                    previewInput = input
                    generationMessage = error.localizedDescription
                }
            }
        }
        .onDisappear {
            scanTask?.cancel()
            password = ""
        }
    }

    private func generationSettings(_ palette: WorkspacePalette) -> some View {
        WorkspaceSection("Content", palette: palette) {
            SettingRow("Type") {
                Picker("Type", selection: $draft.kind) {
                    ForEach(QRToolsDraft.Kind.allCases, id: \.self) { Text($0.rawValue) }
                }
                .labelsHidden()
            }
            switch draft.kind {
            case .text:
                TextField("Text", text: $draft.text, axis: .vertical)
                    .lineLimit(3...8)
                    .textFieldStyle(.roundedBorder)
            case .url:
                TextField("https://example.com", text: $draft.url)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("URL")
            case .wiFi:
                TextField("Network name", text: $draft.network)
                    .textFieldStyle(.roundedBorder)
                SettingRow("Security") {
                    Picker("Security", selection: $draft.security) {
                        ForEach(QRPayload.Security.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .labelsHidden()
                }
                if draft.security != .open {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("Hidden network", isOn: $draft.hiddenNetwork)
            }
        }
    }

    private func previewSection(_ palette: WorkspacePalette, input: PreviewInput) -> some View {
        WorkspaceSection("Appearance", palette: palette) {
            SettingRow("Correction") {
                Picker("Error correction", selection: $draft.options.correction) {
                    ForEach(QRCodeOptions.Correction.allCases, id: \.self) { Text($0.title) }
                }
                .labelsHidden()
            }
            SettingRow("PNG size") {
                Picker("PNG size", selection: $draft.options.size) {
                    ForEach([128, 256, 512, 1024, 2048, 4096], id: \.self) { Text("\($0) × \($0) px") }
                }
                .labelsHidden()
            }
            HStack(spacing: 18) {
                ColorPicker("Foreground", selection: colorBinding($draft.options.foreground), supportsOpacity: false)
                ColorPicker("Background", selection: colorBinding($draft.options.background), supportsOpacity: false)
            }
            if draft.options.foreground.contrast(against: draft.options.background) < 4.5 {
                Label("Low contrast may make this code hard to scan.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if draft.options.foreground.isLighter(than: draft.options.background) {
                Label("Some readers require dark modules on a light background.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let preview, previewInput == input {
                Image(decorative: preview, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 210, height: 210)
                    .accessibilityLabel("Generated QR code")
                HStack {
                    Button("Copy PNG", systemImage: "doc.on.doc") { copy(preview) }
                    Button("Export PNG…", systemImage: "square.and.arrow.down") { export(preview) }
                }
            }
            if previewInput == input, let message = generationMessage ?? exportingMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func scanSection(_ palette: WorkspacePalette) -> some View {
        WorkspaceSection("Image", palette: palette) {
            HStack {
                Button("Choose Image…", systemImage: "photo") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image]
                    if panel.runModal() == .OK, let url = panel.url { scan(url) }
                }
                Text(scannedName ?? "or drop an image here")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if scanning {
                ProgressView().controlSize(.small)
            } else if let scanMessage {
                Text(scanMessage).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(detections) { detection in
                Divider()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(detection.type).font(.caption).foregroundStyle(.secondary)
                        Text(detection.payload).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(detection.payload, forType: .string)
                    }
                    if let text = try? QRPayload.url(detection.payload).encoded(), let url = URL(string: text) {
                        Button("Open URL", systemImage: "arrow.up.right.square") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12).strokeBorder(palette.accent).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first, first.isFileURL else { return false }
            scan(first)
            return true
        } isTargeted: {
            dropping = $0
        }
    }

    private func scan(_ url: URL) {
        scanTask?.cancel()
        scannedName = url.lastPathComponent
        detections = []
        scanMessage = nil
        scanning = true
        scanTask = Task {
            defer { if !Task.isCancelled { scanning = false } }
            do {
                let result = try await Task.detached { try QRTools.detect(in: url) }.value
                try Task.checkCancellation()
                detections = result
                if result.isEmpty { scanMessage = "No QR codes or barcodes found." }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { scanMessage = error.localizedDescription }
            }
        }
    }

    private func copy(_ preview: CGImage) {
        do {
            let data = try QRTools.png(preview)
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setData(data, forType: .png) {
                exportingMessage = "PNG copied."
            } else {
                exportingMessage = "Could not copy the PNG."
            }
        } catch { exportingMessage = error.localizedDescription }
    }

    private func export(_ preview: CGImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "QR Code.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try QRTools.png(preview).write(to: url, options: .atomic)
            exportingMessage = "PNG saved."
        } catch { exportingMessage = error.localizedDescription }
    }

    private func colorBinding(_ value: Binding<QRColor>) -> Binding<Color> {
        Binding {
            let color = value.wrappedValue
            return Color(red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255)
        } set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            func byte(_ unit: CGFloat) -> UInt8 { UInt8(clamping: Int((unit * 255).rounded())) }
            value.wrappedValue = QRColor(red: byte(rgb.redComponent), green: byte(rgb.greenComponent), blue: byte(rgb.blueComponent))
        }
    }
}
