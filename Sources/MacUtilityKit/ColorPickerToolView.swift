import AppKit
import SwiftUI
import UtilityCore

struct ColorPickerToolDraft {
    var precision = ScreenColorPrecision.whole
    var samples = ColorSampleHistory()
}

struct ColorPickerToolView: View {
    @Binding var draft: ColorPickerToolDraft
    @State private var task: Task<Void, Never>?
    @State private var status: String?

    var body: some View {
        InteractiveToolLayout(tool: .colorPicker) { palette in
            WorkspaceSection("Sample", palette: palette) {
                HStack {
                    Button("Sample Screen Color", systemImage: "eyedropper", action: sample)
                        .buttonStyle(WorkspacePrimaryButtonStyle(palette: palette))
                        .disabled(task != nil)
                    if task != nil {
                        Text("Click a color or press Esc to cancel.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                SettingRow("Precision") {
                    Picker("RGB and HSL precision", selection: $draft.precision) {
                        ForEach(ScreenColorPrecision.allCases) { precision in
                            Text(precision.rawValue == 1 ? "1 decimal" : "\(precision.rawValue) decimals")
                                .tag(precision)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
            }
            if let color = draft.samples.current {
                WorkspaceSection("Color Values", palette: palette) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(swatch(color))
                        .frame(height: 84)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8).strokeBorder(palette.line, lineWidth: 1)
                        }
                        .accessibilityLabel("Current color \(color.value(.hex)) in sRGB")
                    Text("sRGB").font(.caption).foregroundStyle(.secondary)
                    ForEach(ScreenColorFormat.allCases) { format in
                        SettingRow(format.rawValue) {
                            let string = color.value(format, precision: draft.precision)
                            Text(string).font(.body.monospaced())
                                .textSelection(.enabled)
                                .accessibilityLabel("\(format.rawValue): \(string)")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Copy \(format.rawValue)", systemImage: "doc.on.doc") {
                                DeveloperToolFiles.copy(string)
                                status = "Copied \(format.rawValue)."
                            }
                            .labelStyle(.iconOnly)
                            .help("Copy \(format.rawValue)")
                        }
                    }
                }
                WorkspaceSection("Recent Swatches", palette: palette) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 47), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(draft.samples.recent, id: \.self) { recent in
                            Button {
                                draft.samples.select(recent)
                                status = nil
                            } label: {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(swatch(recent))
                                    .frame(height: 38)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 7)
                                            .strokeBorder(recent == color ? palette.accent : palette.line,
                                                          lineWidth: recent == color ? 2 : 1)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(recent.value(.hex))
                            .accessibilityAddTraits(recent == color ? .isSelected : [])
                            .help(recent.value(.hex))
                        }
                    }
                    Button("Clear Swatches") {
                        draft.samples.clear()
                        status = nil
                    }
                }
            }
        }
        .onDisappear { task?.cancel() }
    }

    private func sample() {
        guard task == nil else { return }
        status = nil
        task = Task {
            defer { task = nil }
            // AppKit's out-of-process sampler returns only the selected color and does not need screen recording access.
            let color = await NSColorSampler().sample()
            guard !Task.isCancelled, let color else { return }
            guard let converted = color.usingColorSpace(.sRGB),
                  let value = ScreenColorValue(red: converted.redComponent,
                                               green: converted.greenComponent, blue: converted.blueComponent) else {
                status = "The sampled color could not be converted to sRGB. Try another point."
                return
            }
            draft.samples.sample(value)
        }
    }

    private func swatch(_ color: ScreenColorValue) -> Color {
        Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: 1)
    }
}
