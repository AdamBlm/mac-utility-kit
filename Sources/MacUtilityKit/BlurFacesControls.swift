import SwiftUI
import UtilityCore

struct BlurFacesControls: View {
    let inputs: [URL]
    @Binding var options: BlurFacesOptions
    @Environment(\.displayScale) private var displayScale

    @State private var chosenInput: URL?
    @State private var document: Document?
    @State private var loadRevision = UUID()
    @State private var selectedMask: UUID?
    @State private var drawing = false
    @State private var showsResult = false
    @State private var actualPixels = false
    @State private var detection: Detection?
    @State private var rendered: Rendered?
    @State private var failure: String?

    private struct Document: Sendable {
        let url: URL
        let source: ImageRedaction.Source
    }

    private struct OpenRequest: Equatable {
        let input: URL?
        let revision: UUID
    }

    private struct Detection: Equatable {
        let id = UUID()
        let url: URL
        let force: Bool
    }

    private struct RenderRequest: Equatable, Sendable {
        let input: URL
        let digest: String
        let masks: [ImageMaskRegion]
        let effect: ImageRedactionEffect
        let strength: Double
    }

    private struct Rendered {
        let request: RenderRequest
        let result: Result<CGImage, any Error>
    }

    private var activeInput: URL? {
        if let chosenInput, inputs.contains(chosenInput) { return chosenInput }
        return inputs.first
    }

    var body: some View {
        let current = document.flatMap { $0.url == activeInput ? $0 : nil }
        let request = current.map {
            RenderRequest(input: $0.url, digest: $0.source.digest, masks: options.regions[$0.url, default: []],
                          effect: options.effect, strength: options.strength)
        }
        VStack(alignment: .leading, spacing: 12) {
            if inputs.count > 1 {
                SettingRow("Review image") {
                    Picker("Review image", selection: Binding(get: { activeInput }, set: { chosenInput = $0 })) {
                        ForEach(Array(inputs.enumerated()), id: \.offset) { _, input in
                            Text("\(input.lastPathComponent)\(options.isReviewed(input) ? " ✓" : "")").tag(Optional(input))
                        }
                    }
                    .labelsHidden()
                }
                Text("\(inputs.filter { options.isReviewed($0) }.count) of \(inputs.count) images reviewed")
                    .font(.callout).foregroundStyle(.secondary)
            }

            SettingRow("Effect") {
                Picker("Mask effect", selection: $options.effect) {
                    ForEach(ImageRedactionEffect.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            if options.effect != .solid {
                SettingRow("Strength") {
                    Slider(value: $options.strength, in: 0.1...1, step: 0.05) { Text("Strength") }.labelsHidden()
                    Text(options.strength.formatted(.percent.precision(.fractionLength(0))))
                        .font(.callout.monospacedDigit())
                }
                Text("Blur and pixelation can leave recognizable details. Use a solid cover for concealment.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if let current, let request {
                controls(for: current)
                preview(current, request: request)
                review(current, request: request)
            } else if activeInput != nil, failure == nil {
                ProgressView("Opening image…").controlSize(.small)
            }
            if let failure {
                Text(failure).font(.callout).foregroundStyle(.secondary)
            }
        }
        .task(id: OpenRequest(input: activeInput, revision: loadRevision)) { await open(activeInput) }
        .task(id: detection) {
            if let detection, let current, detection.url == current.url { await detect(detection, document: current) }
        }
        .task(id: showsResult ? request : nil) {
            if showsResult, let current, let request { await render(current, request: request) }
        }
    }

    @ViewBuilder
    private func controls(for document: Document) -> some View {
        let masks = options.regions[document.url, default: []]
        HStack(spacing: 12) {
            Button(drawing ? "Cancel Drawing" : "Draw Mask", systemImage: "rectangle.dashed") {
                showsResult = false
                drawing.toggle()
            }
            .disabled(!drawing && masks.count >= 256)
            Button("Suggest Faces", systemImage: "face.dashed") {
                detection = Detection(url: document.url, force: true)
            }
            .disabled(detection != nil || masks.count >= 256)
            if detection != nil {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button(actualPixels ? "Fit" : "Actual Pixels", systemImage: "magnifyingglass") { actualPixels.toggle() }
            Button("Reload Image", systemImage: "arrow.clockwise") { loadRevision = UUID() }
                .labelStyle(.iconOnly)
                .help("Check for changes to the source image")
        }
        if !masks.isEmpty {
            HStack {
                Picker("Selected mask", selection: $selectedMask) {
                    Text("Choose mask").tag(UUID?.none)
                    ForEach(Array(masks.enumerated()), id: \.element.id) { index, mask in
                        Text("Mask \(index + 1)").tag(Optional(mask.id))
                    }
                }
                .frame(maxWidth: 160)
                Button("Remove Mask", systemImage: "minus.circle") {
                    replaceMasks(masks.filter { $0.id != selectedMask }, for: document.url)
                    selectedMask = nil
                }
                .disabled(selectedMask == nil)
            }
        }
    }

    @ViewBuilder
    private func preview(_ document: Document, request: RenderRequest) -> some View {
        Picker("Preview", selection: $showsResult) {
            Text("Original").tag(false)
            Text("Masked").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 220)
        .onChange(of: showsResult) { if showsResult { drawing = false } }
        if showsResult {
            if let rendered, rendered.request == request {
                switch rendered.result {
                case .success(let image):
                    imageViewport(image) { size in
                        Image(decorative: image, scale: 1)
                            .resizable().interpolation(.none)
                            .frame(width: size.width, height: size.height)
                            .accessibilityLabel("Masked image preview")
                    }
                case .failure(let failure):
                    Text(failure.localizedDescription).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Rendering masked preview…").controlSize(.small)
            }
        } else {
            imageViewport(document.source.image) { size in
                ImageMaskCanvas(image: document.source.image, masks: request.masks, selected: $selectedMask,
                                drawing: $drawing) { replaceMasks($0, for: document.url) }
                    .id(document.url)
                    .frame(width: size.width, height: size.height)
            }
        }
    }

    private func imageViewport<Content: View>(_ image: CGImage, @ViewBuilder content: @escaping (CGSize) -> Content) -> some View {
        GeometryReader { geometry in
            let fit = min(geometry.size.width / CGFloat(image.width), geometry.size.height / CGFloat(image.height), 1)
            let scale = actualPixels ? 1 / displayScale : fit
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            if actualPixels {
                ScrollView([.horizontal, .vertical]) {
                    content(size).padding(4)
                }
            } else {
                content(size).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 340)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func review(_ document: Document, request: RenderRequest) -> some View {
        let hasPreview = rendered.flatMap { $0.request == request ? try? $0.result.get() : nil } != nil
        if options.isReviewed(document.url) {
            Label("Coverage reviewed", systemImage: "checkmark.circle")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Text("Face detection may miss faces. Check the entire image and add or enlarge masks as needed.")
                .font(.callout).foregroundStyle(.secondary)
            if !request.masks.isEmpty, !showsResult {
                Button("Review Masked Image", systemImage: "eye") { showsResult = true }
            }
            Button("Confirm All Faces Are Covered", systemImage: "checkmark.circle") {
                options.confirmReview(document.url, source: document.source)
            }
            .disabled(request.masks.isEmpty || !showsResult || !hasPreview)
        }
    }

    private func replaceMasks(_ masks: [ImageMaskRegion], for input: URL) {
        guard masks.count <= 256 else { return }
        if options.regions[input] != masks { options.regions[input] = masks }
    }

    private func open(_ input: URL?) async {
        document = nil
        selectedMask = nil
        showsResult = false
        drawing = false
        detection = nil
        failure = nil
        guard let input else { return }
        do {
            let source = try await work { try ImageRedaction.load(input) }
            try Task.checkCancellation()
            document = Document(url: input, source: source)
            if options.isReviewed(input), !options.reviewMatchesSource(input, source: source) {
                options.clearReview(input)
                options.regions[input] = nil
            }
            if options.regions[input] == nil {
                detection = Detection(url: input, force: false)
            }
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }

    private func detect(_ request: Detection, document: Document) async {
        failure = nil
        do {
            let suggested = try await work { try BlurFaces.suggest(in: document.source) }
            try Task.checkCancellation()
            guard detection == request else { return }
            let existing = options.regions[document.url, default: []]
            let new = suggested.filter { region in
                !existing.contains { old in
                    let overlap = old.rect.intersection(region.rect)
                    return !overlap.isNull && overlap.width * overlap.height > region.rect.width * region.rect.height * 0.75
                }
            }
            if request.force || options.regions[document.url] == nil {
                replaceMasks(Array((existing + new).prefix(256)), for: document.url)
            }
            if suggested.isEmpty && existing.isEmpty { failure = "No faces were detected. Draw masks over any faces in the image." }
            detection = nil
        } catch {
            guard !Task.isCancelled, detection == request else { return }
            failure = error.localizedDescription
            detection = nil
        }
    }

    private func render(_ document: Document, request: RenderRequest) async {
        do {
            try await Task.sleep(for: .milliseconds(150))
            let output = try await work {
                try ImageRedaction.render(document.source.image, regions: request.masks,
                                          effect: request.effect, strength: request.strength)
            }
            try Task.checkCancellation()
            rendered = Rendered(request: request, result: .success(output))
        } catch {
            if !Task.isCancelled { rendered = Rendered(request: request, result: .failure(error)) }
        }
    }

    private func work<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
