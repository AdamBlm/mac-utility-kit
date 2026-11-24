import AppKit
import SwiftUI
import UtilityCore

extension ToolWorkspace {
    @ViewBuilder
    func imageConversionControls() -> some View {
        let options = draft.options.imageConversion
        SettingRow("Output format") {
            Picker("Output format", selection: $draft.options.imageConversion.format) {
                ForEach(ImageConversionFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        if options.format == .webp {
            Toggle("Lossless encoding", isOn: $draft.options.imageConversion.losslessWebP)
            if options.losslessWebP {
                Text("Lossless WebP supports up to 8 bits per channel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if options.format == .jpg || options.format == .heic || (options.format == .webp && !options.losslessWebP) {
            imageQualitySetting($draft.options.imageConversion.quality)
        }
        Toggle("Preserve metadata where supported", isOn: $draft.options.imageConversion.preserveMetadata)
        if options.format != .jpg {
            Toggle("Flatten transparency", isOn: $draft.options.imageConversion.flattenTransparency)
        }
        if options.format == .jpg || options.flattenTransparency {
            SettingRow("Background") {
                ColorPicker("Transparency background", selection: Binding(
                    get: { color(rgb: draft.options.imageConversion.backgroundRGB) },
                    set: {
                        if let rgb = rgb(for: $0) { draft.options.imageConversion.backgroundRGB = rgb }
                    }
                ), supportsOpacity: false)
                .labelsHidden()
            }
        }
        Text("Exports the primary image from multi-image files.")
            .font(.caption).foregroundStyle(.secondary)
        if options.format.requiresImageMagick {
            executablePicker("ImageMagick", selection: $draft.options.imageConversion.imageMagickExecutable)
        }
        if let issue = ImageConversion.optionIssue(options) {
            Text(issue).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    func imageCompressionControls() -> some View {
        let options = draft.options.imageCompression
        SettingRow("Output format") {
            Picker("Output format", selection: $draft.options.imageCompression.format) {
                ForEach(ImageCompressionFormat.allCases.filter {
                    options.mode != .lossless || ![.jpg, .heic].contains($0)
                }, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
        }
        if options.mode == .automatic {
            Text(options.format == .original && options.preserveMetadata
                 ? "Keeps the original image if compression saves no space."
                 : "Chooses compression for the output format. PNG and TIFF stay lossless.")
                .font(.callout).foregroundStyle(.secondary)
        }
        Toggle("Set a best-effort size goal", isOn: Binding(
            get: { draft.options.imageCompression.targetKilobytes != nil },
            set: { draft.options.imageCompression.targetKilobytes = $0 ? 250 : nil }
        ))
        if options.targetKilobytes != nil {
            SettingRow("Size goal") {
                HStack {
                    TextField("Target size in kilobytes", value: Binding(
                        get: { draft.options.imageCompression.targetKilobytes ?? 250 },
                        set: { draft.options.imageCompression.targetKilobytes = $0 }
                    ), format: .number.grouping(.never))
                    Text("KB").foregroundStyle(.secondary)
                }
            }
        }
        DisclosureGroup("Advanced", isExpanded: $draft.showsAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow("Compression") {
                    Picker("Compression", selection: Binding(
                        get: { draft.options.imageCompression.mode },
                        set: { mode in
                            draft.options.imageCompression.mode = mode
                            if mode == .lossless, [.jpg, .heic].contains(draft.options.imageCompression.format) {
                                draft.options.imageCompression.format = .png
                            }
                        }
                    )) {
                        ForEach(ImageCompressionMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                if options.mode == .lossy, options.format != .png, options.format != .tiff {
                    imageQualitySetting($draft.options.imageCompression.quality)
                }
                Toggle("Preserve metadata where supported", isOn: $draft.options.imageCompression.preserveMetadata)
                if options.format == .original {
                    executablePicker("ImageMagick", selection: $draft.options.imageCompression.imageMagickExecutable)
                }
            }
            .padding(.top, 8)
        }
        if options.format.requiresImageMagick {
            if options.imageMagickExecutable == nil {
                Text("WebP export requires ImageMagick.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            executablePicker("ImageMagick", selection: $draft.options.imageCompression.imageMagickExecutable)
        }
    }

    func metadataControls() -> some View {
        ImageMetadataControls(inputs: draft.inputs, options: $draft.options.imageMetadata)
    }

    private func imageQualitySetting(_ quality: Binding<Double>) -> some View {
        SettingRow("Quality") {
            HStack {
                Slider(value: quality, in: 0.05...1) { Text("Quality") }.labelsHidden()
                Text(quality.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func color(rgb: UInt32) -> Color {
        Color(
            red: Double((rgb >> 16) & 255) / 255,
            green: Double((rgb >> 8) & 255) / 255,
            blue: Double(rgb & 255) / 255
        )
    }

    private func rgb(for color: Color) -> UInt32? {
        guard let value = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let channels = [value.redComponent, value.greenComponent, value.blueComponent]
        return channels.reduce(UInt32(0)) { result, channel in
            (result << 8) | UInt32((min(1, max(0, channel)) * 255).rounded())
        }
    }
}

private struct ImageMetadataControls: View {
    let inputs: [URL]
    @Binding var options: ImageMetadataOptions
    @State private var selectedInput: URL?
    @State private var inspection: Inspection?

    private struct Request: Equatable {
        let input: URL
        let executable: URL?
    }

    private struct Inspection {
        let request: Request
        let result: Result<ImageMetadataSnapshot, any Error>
    }

    private var activeInput: URL? {
        if let selectedInput, inputs.contains(selectedInput) { return selectedInput }
        return inputs.first
    }

    var body: some View {
        let request = activeInput.map { Request(input: $0, executable: options.exifToolExecutable) }
        VStack(alignment: .leading, spacing: 12) {
            ForEach(ImageMetadataGroup.allCases) { group in
                Toggle(group.title, isOn: Binding(
                    get: { options.groups.contains(group) },
                    set: { enabled in
                        if enabled { options.groups.insert(group) }
                        else { options.groups.remove(group) }
                    }
                ))
            }
            if options.exifToolExecutable == nil {
                Text("The macOS engine removes supported GPS fields. Use ExifTool for other groups or location fields the macOS engine cannot remove.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            executablePicker("ExifTool", selection: $options.exifToolExecutable)
            if let request {
                Divider()
                if inputs.count > 1 {
                    SettingRow("Inspect file") {
                        Picker("Inspect file", selection: Binding(get: { activeInput }, set: { selectedInput = $0 })) {
                            ForEach(Array(inputs.enumerated()), id: \.offset) { index, input in
                                Text("\(index + 1). \(input.lastPathComponent)").tag(Optional(input))
                            }
                        }
                        .labelsHidden()
                    }
                }
                if let inspection, inspection.request == request {
                    switch inspection.result {
                    case .success(let snapshot):
                        DisclosureGroup("Metadata in \(request.input.lastPathComponent)") {
                            MetadataSnapshotView(snapshot: snapshot)
                        }
                    case .failure(let error):
                        Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("Inspecting metadata…").controlSize(.small)
                }
            }
        }
        .task(id: request) {
            inspection = nil
            guard let request else { return }
            var inspectionOptions = ImageMetadataOptions()
            inspectionOptions.exifToolExecutable = request.executable
            let result: Result<ImageMetadataSnapshot, any Error>
            do {
                result = .success(try await ImageMetadata.inspect(request.input, options: inspectionOptions))
            } catch {
                result = .failure(error)
            }
            if !Task.isCancelled { inspection = Inspection(request: request, result: result) }
        }
    }
}

struct MetadataSnapshotView: View {
    let snapshot: ImageMetadataSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if snapshot.groups.values.allSatisfy(\.isEmpty) {
                Text("No fields found in the supported groups.")
                    .foregroundStyle(.secondary)
            }
            ForEach(ImageMetadataGroup.allCases) { group in
                if let fields = snapshot.groups[group], !fields.isEmpty {
                    Text(group.title).fontWeight(.semibold)
                    Text(fields.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .font(.callout)
        .padding(.vertical, 8)
    }
}

struct MetadataRemovalResultView: View {
    let item: ImageMetadataResult

    var body: some View {
        DisclosureGroup(item.inputLabel) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.removal.summary).font(.callout).textSelection(.enabled)
                DisclosureGroup("Before") { MetadataSnapshotView(snapshot: item.removal.before) }
                DisclosureGroup("After") { MetadataSnapshotView(snapshot: item.removal.after) }
            }
            .padding(.top, 7)
        }
    }
}
