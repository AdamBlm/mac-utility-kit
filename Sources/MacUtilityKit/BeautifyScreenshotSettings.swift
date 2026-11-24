import AppKit
import SwiftUI
import UtilityCore

struct BeautifyScreenshotSettings: View {
    let inputs: [URL]
    @Binding var options: BeautifyScreenshotOptions
    @Environment(\.colorScheme) private var colorScheme
    @State private var selected: URL?
    @State private var image: CGImage?
    @State private var complete: Request?
    @State private var error: String?

    private struct Request: Equatable {
        let input: URL?
        let options: BeautifyScreenshotOptions
    }

    private var previewInputs: [URL] {
        var seen = Set<URL>()
        return inputs.filter { seen.insert($0).inserted }
    }

    var body: some View {
        let previews = previewInputs
        let input = selected.flatMap { previews.contains($0) ? $0 : nil } ?? previews.first
        let request = Request(input: input, options: options)
        let palette = WorkspacePalette(dark: colorScheme == .dark, category: .images)
        SettingRow("Background") {
            Picker("Background", selection: $options.background) {
                ForEach(ScreenshotBackground.allCases.filter { options.format == .png || $0 != .transparent }) {
                    Text($0.rawValue).tag($0)
                }
            }
            .labelsHidden()
        }
        .task(id: request) { await updatePreview(for: request) }
        if options.background != .transparent {
            SettingRow(options.background == .gradient ? "Gradient colors" : "Color") {
                ColorPicker("First color", selection: colorBinding($options.firstColor), supportsOpacity: false)
                    .labelsHidden()
                    .accessibilityLabel(options.background == .gradient ? "First gradient color" : "Background color")
                if options.background == .gradient {
                    ColorPicker("Second color", selection: colorBinding($options.secondColor), supportsOpacity: false)
                        .labelsHidden()
                        .accessibilityLabel("Second gradient color")
                }
            }
        }
        if options.background == .gradient {
            SettingRow("Gradient angle") {
                Slider(value: $options.gradientAngle, in: 0...360, step: 1)
                    .accessibilityLabel("Gradient angle")
                Text("\(Int(options.gradientAngle))°").monospacedDigit().frame(width: 52)
            }
        }
        SettingRow("Aspect ratio") {
            Picker("Aspect ratio", selection: $options.aspect) {
                ForEach(ScreenshotAspect.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
        }
        ScreenshotPixelField("Longest edge", value: $options.longestEdge)
        ScreenshotPixelField("Padding", value: $options.padding)
        ScreenshotPixelField("Corner radius", value: $options.radius)
        SettingRow("Shadow opacity") {
            Slider(value: $options.shadowOpacity, in: 0...1, step: 0.01)
                .accessibilityLabel("Shadow opacity")
            Text(options.shadowOpacity.formatted(.percent.precision(.fractionLength(0))))
                .monospacedDigit().frame(width: 52)
        }
        if options.shadowOpacity > 0 { ScreenshotPixelField("Shadow blur", value: $options.shadowBlur) }
        SettingRow("Format") {
            Picker("Output format", selection: Binding(get: { options.format }, set: { format in
                options.format = format
                if format == .jpeg, options.background == .transparent { options.background = .solid }
            })) {
                ForEach(ScreenshotOutputFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        if options.format == .jpeg {
            SettingRow("JPEG quality") {
                Slider(value: $options.jpegQuality, in: 0...1, step: 0.01)
                    .accessibilityLabel("JPEG quality")
                Text(options.jpegQuality.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit().frame(width: 52)
            }
        }
        if previews.count > 1 {
            SettingRow("Preview file") {
                Picker("Preview file", selection: Binding(get: { input }, set: { selected = $0 })) {
                    ForEach(previews, id: \.self) { url in
                        let name = url.lastPathComponent
                        let duplicateName = previews.contains { $0 != url && $0.lastPathComponent == name }
                        Text(duplicateName ? url.path : name).tag(Optional(url))
                    }
                }
                .labelsHidden()
                .help(input?.path ?? "")
            }
        }
        if complete == request, let image {
            ImagePreviewViewport(image: image) { _ in
                Image(decorative: image, scale: 1)
                    .resizable()
                    .background {
                        if options.background == .transparent { TransparencyGrid(palette: palette) }
                    }
                    .accessibilityLabel("Composed screenshot preview")
            }
            Text("\(image.width) × \(image.height) pixels")
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
        } else if complete == request, let error {
            Text(error).font(.callout).foregroundStyle(.red)
        } else if input != nil {
            ProgressView("Composing preview…").controlSize(.small)
        }
    }

    private func colorBinding(_ color: Binding<UInt32>) -> Binding<Color> {
        Binding {
            let rgb = color.wrappedValue
            return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                         blue: Double(rgb & 255) / 255)
        } set: { selection in
            if let rgb = NSColor(selection).usingColorSpace(.sRGB) {
                color.wrappedValue = UInt32((clamp(rgb.redComponent) * 255).rounded()) << 16
                    | UInt32((clamp(rgb.greenComponent) * 255).rounded()) << 8
                    | UInt32((clamp(rgb.blueComponent) * 255).rounded())
            }
        }
    }

    private func clamp(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }

    private func updatePreview(for request: Request) async {
        guard !Task.isCancelled else { return }
        image = nil
        error = nil
        guard let input = request.input else { return }
        do {
            try await Task.sleep(for: .milliseconds(170))
            let rendered = try await BeautifyScreenshot.preview(input, options: request.options)
            guard !Task.isCancelled else { return }
            image = rendered
            complete = request
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            complete = request
        }
    }
}

private struct ScreenshotPixelField: View {
    let label: String
    @Binding var value: Int
    @State private var entered: String?

    init(_ label: String, value: Binding<Int>) {
        self.label = label
        self._value = value
    }

    var body: some View {
        SettingRow(label) {
            TextField(label, text: Binding(get: {
                entered ?? (value < 0 ? "" : String(value))
            }, set: { text in
                entered = text
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                value = trimmed.utf8.allSatisfy { (48...57).contains($0) } ? (Int(trimmed) ?? -1) : -1
            }))
            .frame(width: 75)
            Text("px").foregroundStyle(.secondary)
        }
    }
}

private struct TransparencyGrid: View {
    let palette: WorkspacePalette

    var body: some View {
        Canvas { context, size in
            let tile = 10.0
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.canvas))
            for row in 0..<Int(ceil(size.height / tile)) {
                for column in 0..<Int(ceil(size.width / tile)) where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: Double(column) * tile, y: Double(row) * tile, width: tile, height: tile)
                    context.fill(Path(rect), with: .color(.primary.opacity(0.08)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
