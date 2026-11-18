import AppKit
import SwiftUI
import UtilityCore

extension ToolWorkspace {
    @ViewBuilder
    func imageControls() -> some View {
        SettingRow("Resize by") {
            Picker("Resize by", selection: option(\.imageSizing)) {
                ForEach(ImageSizing.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
        }

        switch draft.options.imageSizing {
        case .longestEdge:
            SettingRow("Longest edge") {
                HStack {
                    TextField("Longest edge (pixels)", value: Binding(
                        get: { draft.pixels },
                        set: { draft.pixels = $0 }
                    ), format: .number.grouping(.never))
                    .labelsHidden()
                    Text("px").foregroundStyle(.secondary)
                }
            }
        case .percentage:
            SettingRow("Scale") {
                HStack {
                    TextField("Percentage", value: option(\.imagePercentage), format: .number)
                        .labelsHidden()
                    Text("%").foregroundStyle(.secondary)
                }
            }
        case .dimensions:
            SettingRow("Dimensions") {
                HStack {
                    TextField("Width", value: option(\.imageWidth), format: .number)
                        .accessibilityLabel("Width in pixels")
                    Text("×").foregroundStyle(.secondary)
                    TextField("Height", value: option(\.imageHeight), format: .number)
                        .accessibilityLabel("Height in pixels")
                    Text("px").foregroundStyle(.secondary)
                }
            }
            SettingRow("Aspect ratio") {
                Picker("Aspect ratio", selection: option(\.imageFit)) {
                    ForEach(ImageFit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
        }

        SettingRow("Output format") {
            Picker("Output format", selection: option(\.imageFormat)) {
                ForEach(ImageFormat.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        if draft.options.imageFormat == .jpg || draft.options.imageFormat == .heic {
            SettingRow("Quality") {
                HStack {
                    Slider(value: option(\.imageQuality), in: 0.1...1) { Text("Quality") }
                        .labelsHidden()
                    Text(draft.options.imageQuality.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }

        advanced() {
            Toggle("Allow upscaling", isOn: option(\.upscale))
            engineControls(path: \.imageMagickExecutable, name: "ImageMagick", current: draft.options.imageMagickExecutable)
        }
    }

    @ViewBuilder
    func videoControls() -> some View {
        SettingRow("Output format") {
            Picker("Output format", selection: option(\.videoFormat)) {
                ForEach(VideoFormat.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        SettingRow("Codec") {
            Picker("Codec", selection: option(\.videoCodec)) {
                ForEach(VideoCodec.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        SettingRow("Quality") {
            Picker("Compression quality", selection: option(\.videoQuality)) {
                ForEach(VideoQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        advanced() {
            Toggle("Keep exports that are not smaller", isOn: option(\.keepLargerVideos))
            engineControls(path: \.ffmpegExecutable, name: "FFmpeg", current: draft.options.ffmpegExecutable)
            if draft.options.ffmpegExecutable != nil {
                Text("Constant quality requires FFmpeg with libx264 or libx265.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        HStack {
            Button("Create 5-second sample", systemImage: "play.rectangle") { session.startSample(draft) }
                .disabled(draft.inputs.isEmpty || session.isRunning)
            if let sample = session.sample {
                Button("Open sample") { NSWorkspace.shared.open(sample.url) }
                if let bytes = sample.estimatedBytes {
                    Text("Estimated size: " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func advanced<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup("Advanced", isExpanded: $draft.showsAdvanced) {
            VStack(alignment: .leading, spacing: 10, content: content)
                .padding(.top, 10)
        }
        .font(.callout)
    }

    private func engineControls(
        path: WritableKeyPath<ToolOptions, URL?>, name: String, current: URL?
    ) -> some View {
        HStack(spacing: 10) {
            Label(current == nil ? "macOS engine" : name, systemImage: "gearshape")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if current != nil {
                Button("Use macOS") { draft.options[keyPath: path] = nil }
            }
            Button("Choose \(name)…") { chooseExecutable(path) }
        }
        .font(.callout)
    }

    private func chooseExecutable(_ path: WritableKeyPath<ToolOptions, URL?>) {
        let panel = NSOpenPanel()
        if panel.runModal() == .OK {
            draft.options[keyPath: path] = panel.url
        }
    }
}
