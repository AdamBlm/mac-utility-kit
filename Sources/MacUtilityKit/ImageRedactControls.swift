import SwiftUI
import UtilityCore

struct ImageRedactControls: View {
    let inputs: [URL]
    @Binding var options: ImageRedactOptions

    @State private var chosen: URL?
    @State private var source: Loaded?
    @State private var drawing = false
    @State private var selection: UUID?
    @State private var showsResult = false
    @State private var actualPixels = false
    @State private var strengthDraft: Double?
    @State private var reload = UUID()
    @State private var result: Rendered?
    @State private var failure: String?

    private struct Loaded: Sendable {
        let input: URL
        let source: ImageRedaction.Source
    }

    private struct OpenRequest: Equatable {
        let input: URL?
        let revision: UUID
    }

    private struct RenderRequest: Equatable, Sendable {
        let digest: String
        let edit: ImageRedactEdit
    }

    private struct Rendered {
        let request: RenderRequest
        let result: Result<CGImage, any Error>
    }

    private var input: URL? {
        if let chosen, inputs.contains(chosen) { return chosen }
        return inputs.first
    }

    var body: some View {
        let active = source.flatMap { $0.input == input ? $0 : nil }
        let request = active.map { RenderRequest(digest: $0.source.digest, edit: edit(for: $0)) }
        VStack(alignment: .leading, spacing: 12) {
            if inputs.count > 1 {
                SettingRow("Edit image") {
                    Picker("Edit image", selection: Binding(get: { input }, set: { chosen = $0 })) {
                        ForEach(Array(inputs.enumerated()), id: \.offset) { _, file in
                            Text(file.lastPathComponent + (options.hasMasks(file) ? " ✓" : "")).tag(Optional(file))
                        }
                    }
                    .labelsHidden()
                }
            }
            if let active, let request {
                settings(for: active, edit: request.edit)
                controls(for: active, edit: request.edit)
                editor(active, request: request)
            } else if let failure {
                Text(failure).font(.callout).foregroundStyle(.secondary)
            } else if input != nil {
                ProgressView("Opening image…").controlSize(.small)
            }
        }
        .task(id: OpenRequest(input: input, revision: reload)) { await open(input) }
        .task(id: showsResult ? request : nil) {
            if showsResult, let active, let request { await render(active, request: request) }
        }
    }

    @ViewBuilder
    private func settings(for image: Loaded, edit: ImageRedactEdit) -> some View {
        SettingRow("Effect") {
            Picker("Mask effect", selection: Binding(get: { edit.effect }, set: { effect in
                mutate(image) { $0.effect = effect }
            })) {
                ForEach(ImageRedactionEffect.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
        }
        if edit.effect != .solid {
            SettingRow("Strength") {
                Slider(value: Binding(get: { strengthDraft ?? edit.strength }, set: { value in
                    if strengthDraft != nil { strengthDraft = value }
                    else { mutate(image) { $0.strength = value } }
                }), in: 0.1...1, step: 0.05, onEditingChanged: { editing in
                    if editing {
                        strengthDraft = edit.strength
                    } else if let strengthDraft {
                        mutate(image) { $0.strength = strengthDraft }
                        self.strengthDraft = nil
                    }
                }) { Text("Strength") }
                .labelsHidden()
                Text(edit.strength.formatted(.percent.precision(.fractionLength(0)))).font(.callout.monospacedDigit())
            }
            Text("Blur and pixelation can leave recognizable details. Use a solid cover for concealment.")
                .font(.callout).foregroundStyle(.secondary)
        }
        Toggle("Remove source metadata", isOn: Binding(get: { edit.removesMetadata }, set: { remove in
            mutate(image) { $0.removesMetadata = remove }
        }))
        if !edit.removesMetadata {
            Text("PNG can retain a title, author, and copyright. Location and embedded images are removed.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func controls(for image: Loaded, edit: ImageRedactEdit) -> some View {
        HStack(spacing: 11) {
            Button(drawing ? "Cancel Drawing" : "Draw Mask", systemImage: "rectangle.dashed") {
                showsResult = false
                drawing.toggle()
            }
            .disabled(!drawing && edit.regions.count >= 256)
            Button("Undo Mask Edit", systemImage: "arrow.uturn.backward") {
                drawing = false
                options.undo(image.input)
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("z")
            .disabled(!options.canUndo(image.input))
            Button("Redo Mask Edit", systemImage: "arrow.uturn.forward") {
                drawing = false
                options.redo(image.input)
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!options.canRedo(image.input))
            Spacer()
            Button(actualPixels ? "Fit" : "Actual Pixels", systemImage: "magnifyingglass") { actualPixels.toggle() }
            Button("Reload Image", systemImage: "arrow.clockwise") { reload = UUID() }
                .labelStyle(.iconOnly)
                .help("Check for changes to the source image")
        }
        if !edit.regions.isEmpty {
            HStack {
                Picker("Selected mask", selection: Binding(get: {
                    edit.regions.contains { $0.id == selection } ? selection : nil
                }, set: { selection = $0 })) {
                    Text("Choose mask").tag(UUID?.none)
                    ForEach(Array(edit.regions.enumerated()), id: \.element.id) { index, mask in
                        Text("Mask \(index + 1)").tag(Optional(mask.id))
                    }
                }
                .frame(maxWidth: 160)
                Button("Remove Mask", systemImage: "minus.circle") {
                    mutate(image) { $0.regions.removeAll { $0.id == selection } }
                    selection = nil
                }
                .disabled(!edit.regions.contains { $0.id == selection })
            }
        }
    }

    @ViewBuilder
    private func editor(_ image: Loaded, request: RenderRequest) -> some View {
        Picker("Preview", selection: $showsResult) {
            Text("Original").tag(false)
            Text("Redacted").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 230)
        .onChange(of: showsResult) { if showsResult { drawing = false } }

        if showsResult {
            if let result, result.request == request {
                switch result.result {
                case .success(let output):
                    ImageMaskViewport(image: output, actualPixels: actualPixels) { size in
                        Image(decorative: output, scale: 1)
                            .resizable().interpolation(.none)
                            .frame(width: size.width, height: size.height)
                            .accessibilityLabel("Redacted image preview")
                    }
                case .failure(let error):
                    Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Rendering image…").controlSize(.small)
            }
        } else {
            ImageMaskViewport(image: image.source.image, actualPixels: actualPixels) { size in
                ImageMaskCanvas(image: image.source.image, masks: request.edit.regions,
                                selected: $selection, drawing: $drawing) { masks in
                    mutate(image) { $0.regions = Array(masks.prefix(256)) }
                }
                .id(image.input)
                .frame(width: size.width, height: size.height)
            }
        }
    }

    private func edit(for image: Loaded) -> ImageRedactEdit {
        var edit = options.edit(for: image.input)
        if let strengthDraft { edit.strength = strengthDraft }
        return edit
    }

    private func mutate(_ image: Loaded, update: (inout ImageRedactEdit) -> Void) {
        var copy = options.edit(for: image.input)
        update(&copy)
        options.apply(copy, to: image.input, source: image.source)
    }

    private func open(_ input: URL?) async {
        source = nil
        selection = nil
        drawing = false
        showsResult = false
        strengthDraft = nil
        failure = nil
        guard let input else { return }
        do {
            let loaded = try await runImageMaskWork { try ImageRedaction.load(input) }
            try Task.checkCancellation()
            options.discardIfChanged(input, source: loaded)
            source = Loaded(input: input, source: loaded)
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }

    private func render(_ image: Loaded, request: RenderRequest) async {
        do {
            try await Task.sleep(for: .milliseconds(150))
            let rendered = try await runImageMaskWork {
                try ImageRedaction.render(image.source.image, regions: request.edit.regions,
                                          effect: request.edit.effect, strength: request.edit.strength)
            }
            try Task.checkCancellation()
            result = Rendered(request: request, result: .success(rendered))
        } catch {
            if !Task.isCancelled { result = Rendered(request: request, result: .failure(error)) }
        }
    }
}
