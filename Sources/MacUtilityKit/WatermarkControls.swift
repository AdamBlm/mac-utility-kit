import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct WatermarkControls: View {
    let inputs: [URL]
    @Binding var options: WatermarkOptions
    @Binding var logoAttachment: CaptureTextAttachment?
    @State private var choice: URL?
    @State private var inspected: Inspected?
    @State private var inspectionError: String?
    @State private var sample: Sample?
    @State private var page = 1
    @State private var seconds = 0.0

    private struct Inspected {
        let input: URL
        let info: Watermark.InputInfo
    }

    private struct Request: Equatable {
        let input: URL?
        let page: Int
        let seconds: Double
        let options: WatermarkOptions

        static func == (lhs: Self, rhs: Self) -> Bool {
            // Invalid numeric input uses NaN to prevent exporting stale values.
            lhs.input == rhs.input && lhs.page == rhs.page && lhs.seconds == rhs.seconds
                && lhs.options.videoStart.bitPattern == rhs.options.videoStart.bitPattern
                && lhs.options.videoEnd?.bitPattern == rhs.options.videoEnd?.bitPattern
                && lhs.nonTimingOptions == rhs.nonTimingOptions
        }

        private var nonTimingOptions: WatermarkOptions {
            var copy = options
            copy.videoStart = 0
            copy.videoEnd = nil
            return copy
        }
    }

    private struct Sample {
        let request: Request
        let result: Result<CGImage, any Error>
    }

    private var activeInput: URL? { choice.flatMap { inputs.contains($0) ? $0 : nil } ?? inputs.first }
    private var hasPDF: Bool { inputs.contains { if case .pdf? = try? Watermark.inputKind($0) { true } else { false } } }
    private var hasVideo: Bool { inputs.contains { if case .video? = try? Watermark.inputKind($0) { true } else { false } } }

    var body: some View {
        let preview = Request(input: activeInput, page: page, seconds: seconds, options: options)
        VStack(alignment: .leading, spacing: 12) {
            sourceSettings
            placementSettings
            if hasPDF {
                SettingRow("PDF pages") {
                    TextField("All pages or a range", text: $options.pdfPages)
                        .textFieldStyle(.roundedBorder)
                        .help("Example: 1–3, 6")
                }
                Text("Marked pages keep their visible content, web links, and email links. Internal links, forms, and other annotations lose interactivity on those pages.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if hasVideo {
                VideoWatermarkTimestamp("Start time", value: Binding(get: { options.videoStart }, set: { options.videoStart = $0 ?? 0 }),
                                        placeholder: "0")
                VideoWatermarkTimestamp("End time", value: $options.videoEnd, placeholder: "End of clip")
                executablePicker("FFmpeg", selection: $options.ffmpegExecutable)
            }
            pageControls
            if let sample, sample.request == preview {
                switch sample.result {
                case .success(let image):
                    ImagePreviewViewport(image: image, maxHeight: 300) { _ in
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .background(.primary.opacity(0.04))
                            .clipShape(.rect(cornerRadius: 8))
                            .accessibilityLabel("Watermark preview")
                    }
                case .failure(let error):
                    Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
                }
            } else if let inspectionError {
                Text(inspectionError).font(.callout).foregroundStyle(.secondary)
            } else if activeInput != nil && hasContent {
                ProgressView("Rendering preview…").controlSize(.small)
            }
        }
        .task(id: activeInput) { await inspect(activeInput) }
        .task(id: preview) { await render(preview) }
    }

    private var hasContent: Bool {
        options.content == .logo ? options.logo != nil : !options.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sourceSettings: some View {
        VStack(alignment: .leading, spacing: 9) {
            SettingRow("Watermark") {
                Picker("Watermark type", selection: $options.content) {
                    ForEach(WatermarkOptions.Content.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            if options.content == .text {
                SettingRow("Text") {
                    TextField("Watermark text", text: $options.text).textFieldStyle(.roundedBorder)
                    ColorPicker("Text color", selection: textColor, supportsOpacity: false).labelsHidden()
                }
            } else {
                SettingRow("Logo") {
                    Button("Choose Image…", systemImage: "photo") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.image]
                        if panel.runModal() == .OK, let url = panel.url { setLogo(url) }
                    }
                    ClipboardFileButton(allowedTypes: [.image], onPasteImage: { image in
                        let attachment = try CaptureTextAttachment(image: image, filename: "Pasted Logo.png")
                        setLogo(attachment.url, attachment: attachment)
                    }, buttonOnlyTitle: "Paste Logo") { url in
                        setLogo(url)
                    }
                    if let logo = options.logo {
                        Text(logo.lastPathComponent).lineLimit(1).truncationMode(.middle).help(logo.path)
                    }
                }
            }
        }
    }

    private func setLogo(_ url: URL, attachment: CaptureTextAttachment? = nil) {
        options.logo = url
        if logoAttachment?.url != url || attachment != nil {
            logoAttachment = attachment
        }
    }

    private var placementSettings: some View {
        VStack(alignment: .leading, spacing: 9) {
            SettingRow("Placement") {
                Picker("Placement", selection: $options.placement) {
                    ForEach(WatermarkOptions.Placement.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            slider("Scale", value: $options.scale, range: 0.05...0.8, step: 0.01, style: .percent)
            slider("Opacity", value: $options.opacity, range: 0.01...1, step: 0.01, style: .percent)
            slider("Margin", value: $options.margin, range: 0...0.25, step: 0.005, style: .percent)
            SettingRow("Rotation") {
                Slider(value: $options.rotation, in: -180...180, step: 1)
                    .accessibilityLabel("Rotation")
                Text("\(Int(options.rotation))°").monospacedDigit().frame(width: 45, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var pageControls: some View {
        if inputs.count > 1 {
            SettingRow("Preview file") {
                Picker("Preview file", selection: Binding(get: { activeInput }, set: { choice = $0 })) {
                    ForEach(Array(inputs.enumerated()), id: \.offset) { _, input in
                        Text(input.lastPathComponent).tag(Optional(input))
                    }
                }
                .labelsHidden()
            }
        }
        if let inspected, inspected.input == activeInput {
            if let pages = inspected.info.pageCount {
                SettingRow("Preview page") {
                    Stepper("Page \(page) of \(pages)", value: $page, in: 1...pages)
                }
            }
            if let duration = inspected.info.duration {
                SettingRow("Preview time") {
                    Slider(value: $seconds, in: 0...max(0.0001, duration - min(0.035, duration / 2)))
                        .accessibilityLabel("Preview playhead")
                    Text(seconds.formatted(.number.precision(.fractionLength(2))) + " s")
                        .monospacedDigit().frame(width: 61, alignment: .trailing)
                }
            }
        }
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                        style: FloatingPointFormatStyle<Double>.Percent) -> some View {
        SettingRow(label) {
            Slider(value: value, in: range, step: step).accessibilityLabel(label)
            Text(value.wrappedValue.formatted(style.precision(.fractionLength(0...1))))
                .monospacedDigit().frame(width: 45, alignment: .trailing)
        }
    }

    private var textColor: Binding<Color> {
        Binding {
            let rgb = options.textColor
            return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                         blue: Double(rgb & 255) / 255)
        } set: { selection in
            guard let rgb = NSColor(selection).usingColorSpace(.sRGB) else { return }
            func byte(_ unit: CGFloat) -> UInt32 { UInt32(clamping: Int((min(1, max(0, unit)) * 255).rounded())) }
            options.textColor = byte(rgb.redComponent) << 16 | byte(rgb.greenComponent) << 8 | byte(rgb.blueComponent)
        }
    }

    private func inspect(_ input: URL?) async {
        inspected = nil
        inspectionError = nil
        page = 1
        seconds = 0
        guard let input else { return }
        do {
            let info = try await Watermark.inspect(input)
            try Task.checkCancellation()
            inspected = Inspected(input: input, info: info)
        } catch {
            if !Task.isCancelled { inspectionError = error.localizedDescription }
        }
    }

    private func render(_ request: Request) async {
        guard let input = request.input, hasContent else { return }
        do {
            try await Task.sleep(for: .milliseconds(160))
            let image = try await Watermark.preview(input, page: request.page, seconds: request.seconds, options: request.options)
            try Task.checkCancellation()
            sample = Sample(request: request, result: .success(image))
        } catch {
            if !Task.isCancelled { sample = Sample(request: request, result: .failure(error)) }
        }
    }
}

private struct VideoWatermarkTimestamp: View {
    let label: String
    @Binding var value: Double?
    let placeholder: String
    @State private var typed: String?

    init(_ label: String, value: Binding<Double?>, placeholder: String) {
        self.label = label
        _value = value
        self.placeholder = placeholder
    }

    var body: some View {
        SettingRow(label) {
            TextField(placeholder, text: Binding(get: {
                typed ?? value.map { $0.isFinite ? $0.formatted(.number.grouping(.never)) : "" } ?? ""
            }, set: { text in
                typed = text
                let cleaned = text.trimmingCharacters(in: .whitespaces)
                value = cleaned.isEmpty ? nil : Double(cleaned.replacingOccurrences(of: ",", with: ".")) ?? .nan
            }))
            .accessibilityLabel(label + " in seconds")
            .textFieldStyle(.roundedBorder)
            .frame(width: 94)
            Text("seconds").foregroundStyle(.secondary)
        }
    }
}
