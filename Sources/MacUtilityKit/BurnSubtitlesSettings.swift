import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UtilityCore

struct BurnSubtitlesSettings: View {
    let input: URL?
    @Binding var options: BurnSubtitlesOptions
    @Environment(\.colorScheme) private var colorScheme
    @State private var duration: Double?
    @State private var loadedInput: URL?
    @State private var playhead = 0.0
    @State private var preview: CGImage?
    @State private var completedPreview: Request?
    @State private var previewError: String?
    @State private var inputError: String?
    @State private var importError: String?
    @State private var importing = false

    private struct Request: Equatable {
        let input: URL
        let playhead: Double
        let options: BurnSubtitlesOptions
    }

    private var timeFormat: FloatingPointFormatStyle<Double> {
        .number.grouping(.never).precision(.fractionLength(0...3))
    }

    var body: some View {
        let palette = WorkspacePalette(dark: colorScheme == .dark)
        HStack {
            Button("Import SRT…", systemImage: "folder", action: importSRT)
                .disabled(importing)
            if importing { ProgressView().controlSize(.small) }
        }
        .task(id: input) { await load(input) }
        TextEditor(text: $options.srt)
            .font(.body.monospaced())
            .frame(minHeight: 150)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(palette.canvas, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("SRT subtitle text and timing")
            .disabled(importing)
        if let importError { Text(importError).font(.callout).foregroundStyle(.red) }
        SettingRow("Timing offset") {
            TextField("Offset in seconds", value: $options.offset, format: timeFormat)
                .frame(width: 95)
            Text("seconds").foregroundStyle(.secondary)
        }
        SettingRow("Font size") {
            Slider(value: Binding(get: { Double(options.fontSize) }, set: { options.fontSize = Int($0) }),
                   in: 8...80, step: 1)
                .accessibilityLabel("Subtitle font size")
            Text(options.fontSize.formatted()).monospacedDigit()
        }
        SettingRow("Colors") {
            ColorPicker("Text", selection: colorBinding($options.textRGB), supportsOpacity: false)
            ColorPicker("Background", selection: colorBinding($options.backgroundRGB), supportsOpacity: false)
        }
        SettingRow("Background") {
            Picker("Background", selection: $options.background) {
                ForEach(SubtitleBackground.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
        }
        SettingRow("Position") {
            Picker("Position", selection: $options.position) {
                ForEach(SubtitlePosition.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        executablePicker("FFmpeg with libass", selection: $options.ffmpegExecutable)
        if let input, loadedInput == input, let duration {
            if !options.srt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                switch Result(catching: { try BurnSubtitles.plan(duration: duration, options: options) }) {
                case .success(let plan):
                    Text("\(plan.cues.count) cues · \(plan.clipped) clipped · \(plan.removed) outside video")
                        .foregroundStyle(.secondary).font(.callout)
                    if options.ffmpegExecutable != nil {
                        previewControls(input: input, duration: duration, palette: palette)
                    }
                case .failure(let error):
                    Text(error.localizedDescription).foregroundStyle(.red).font(.callout)
                }
            }
        } else if loadedInput == input, let inputError {
            Text(inputError).foregroundStyle(.red).font(.callout)
        }
    }

    @ViewBuilder
    private func previewControls(input: URL, duration: Double, palette: WorkspacePalette) -> some View {
        let maximum = max(duration - 0.001, duration * 0.999)
        let request = Request(input: input, playhead: min(playhead, maximum), options: options)
        VStack(alignment: .leading, spacing: 8) {
            if completedPreview == request, let preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 250)
                    .background(palette.canvas)
                    .accessibilityLabel("Rendered subtitle preview")
            } else if completedPreview == request, let previewError {
                Text(previewError).foregroundStyle(.red).font(.callout)
            } else {
                ProgressView("Rendering subtitle preview…").controlSize(.small)
            }
            Slider(value: $playhead, in: 0...maximum).accessibilityLabel("Subtitle preview playhead")
            Text("\(playhead.formatted(timeFormat)) seconds")
                .monospacedDigit().font(.callout).foregroundStyle(.secondary)
        }
        .task(id: request) { await renderPreview(request) }
    }

    private func load(_ source: URL?) async {
        duration = nil
        playhead = 0
        loadedInput = nil
        inputError = nil
        guard let source else { return }
        do {
            let result = try await TrimVideo.duration(of: source)
            guard !Task.isCancelled else { return }
            duration = result
            loadedInput = source
        } catch {
            guard !Task.isCancelled else { return }
            inputError = error.localizedDescription
            loadedInput = source
        }
    }

    private func renderPreview(_ request: Request) async {
        do {
            try await Task.sleep(for: .milliseconds(250))
            let rendered = try await BurnSubtitles.preview(request.input, at: request.playhead, options: request.options)
            guard !Task.isCancelled else { return }
            preview = rendered
            previewError = nil
            completedPreview = request
        } catch {
            guard !Task.isCancelled else { return }
            preview = nil
            previewError = error.localizedDescription
            completedPreview = request
        }
    }

    private func importSRT() {
        let filter = UTType(filenameExtension: "srt") ?? .plainText
        guard let url = DeveloperToolFiles.choose(allowedTypes: [filter]) else { return }
        importError = nil
        importing = true
        Task {
            defer { importing = false }
            do {
                let data = try await DeveloperToolFiles.read(url)
                if let utf8 = String(data: data, encoding: .utf8) {
                    options.srt = utf8
                } else if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
                          let utf16 = String(data: data, encoding: .utf16) {
                    options.srt = utf16
                } else if let legacy = String(data: data, encoding: .windowsCP1252) {
                    options.srt = legacy
                } else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func colorBinding(_ value: Binding<UInt32>) -> Binding<Color> {
        Binding {
            let rgb = value.wrappedValue
            return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                         blue: Double(rgb & 255) / 255)
        } set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            let red = UInt32((max(0, min(1, rgb.redComponent)) * 255).rounded())
            let green = UInt32((max(0, min(1, rgb.greenComponent)) * 255).rounded())
            let blue = UInt32((max(0, min(1, rgb.blueComponent)) * 255).rounded())
            value.wrappedValue = (red << 16) | (green << 8) | blue
        }
    }
}
