import AppKit
import SwiftUI
import UtilityCore

struct RemoveBackgroundControls: View {
    let inputs: [URL]
    @Binding var options: RemoveBackgroundOptions
    @State private var selection: URL?
    @State private var document: Document?
    @State private var rendered: Rendered?
    @State private var issue: String?
    @State private var showsResult = true
    @State private var actualPixels = false
    @State private var drawing = false
    @State private var selectedRegion: UUID?
    @State private var drawingAction = ForegroundRefinement.Action.keep
    @State private var brushMode = true
    @State private var brushWidth = 0.04

    private struct Document {
        let input: URL
        let analysis: RemoveBackground.Analysis
    }

    private struct RenderRequest: Equatable, Sendable {
        let input: URL
        let digest: String
        let edit: RemoveBackgroundEdit
        let options: RemoveBackgroundOptions
    }

    private struct Rendered {
        let request: RenderRequest
        let result: Result<CGImage, any Error>
    }

    private var activeInput: URL? {
        if let selection, inputs.contains(selection) { return selection }
        return inputs.first
    }

    var body: some View {
        let active = document.flatMap { $0.input == activeInput ? $0 : nil }
        let request = active.map {
            let edit = options.edit(for: $0.input, analysis: $0.analysis)
            return RenderRequest(input: $0.input, digest: $0.analysis.source.digest, edit: edit, options: options)
        }
        let renderRequest = request.map { request in
            guard !showsResult else { return request }
            var overlay = request.options
            overlay.background = .transparent
            overlay.format = .png
            return RenderRequest(input: request.input, digest: request.digest, edit: request.edit, options: overlay)
        }
        VStack(alignment: .leading, spacing: 12) {
            exportSettings
            if inputs.count > 1 {
                SettingRow("Edit image") {
                    Picker("Edit image", selection: Binding(get: { activeInput }, set: { selection = $0 })) {
                        ForEach(Array(inputs.enumerated()), id: \.offset) { _, input in
                            Text(input.lastPathComponent).tag(Optional(input))
                        }
                    }
                    .labelsHidden()
                }
            }
            if let active, let request {
                subjects(active, edit: request.edit)
                editor(active, request: renderRequest ?? request)
            } else if let issue {
                Text(issue).font(.callout).foregroundStyle(.secondary)
            } else if activeInput != nil {
                ProgressView("Finding subjects…").controlSize(.small)
            }
        }
        .task(id: activeInput) { await open(activeInput) }
        .task(id: showsResult || brushMode ? renderRequest : nil) {
            if showsResult || brushMode, let active, let renderRequest { await render(active, request: renderRequest) }
        }
    }

    private var exportSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingRow("Format") {
                Picker("Output format", selection: Binding(get: { options.format }, set: { format in
                    options.format = format
                    if format == .jpeg { options.background = .solid }
                })) {
                    ForEach(RemoveBackgroundOptions.Format.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            SettingRow("Background") {
                Picker("Background", selection: $options.background) {
                    ForEach(RemoveBackgroundOptions.Background.allCases.filter { options.format == .png || $0 != .transparent }) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .labelsHidden()
                if options.background == .solid {
                    ColorPicker("Background color", selection: color, supportsOpacity: false).labelsHidden()
                }
            }
            if options.format == .jpeg {
                SettingRow("Quality") {
                    Slider(value: $options.quality, in: 0...1, step: 0.01)
                        .accessibilityLabel("JPEG quality")
                    Text(options.quality.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                        .frame(width: 43, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private func subjects(_ document: Document, edit: RemoveBackgroundEdit) -> some View {
        let all = document.analysis.subjects
        if all.isEmpty {
            Text(document.analysis.detectionIssue == nil
                 ? "No clear subject found. Use a Keep correction to retain part of the image."
                 : "Automatic segmentation was unavailable. You can still use a Keep correction.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Subjects").font(.callout.weight(.medium))
                    Button("Keep All") { update(document) { $0.subjects = nil } }
                        .disabled(edit.subjects == nil)
                }
                ForEach(Array(all), id: \.self) { subject in
                    Toggle("Subject \(subject)", isOn: Binding(get: {
                        (edit.subjects ?? all).contains(subject)
                    }, set: { enabled in
                        update(document) { updated in
                            var chosen = updated.subjects ?? all
                            if enabled { chosen.insert(subject) }
                            else { chosen.remove(subject) }
                            updated.subjects = chosen == all ? nil : chosen
                        }
                    }))
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    @ViewBuilder
    private func editor(_ document: Document, request: RenderRequest) -> some View {
        HStack {
            Picker("Preview", selection: $showsResult) {
                Text("Refine Mask").tag(false)
                Text("Result").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 235)
            .onChange(of: showsResult) { if showsResult { drawing = false } }
            Spacer(minLength: 0)
            Button(actualPixels ? "Fit" : "Actual Pixels", systemImage: "magnifyingglass") { actualPixels.toggle() }
        }
        if showsResult {
            if let rendered, rendered.request == request {
                switch rendered.result {
                case .success(let image):
                    ImageMaskViewport(image: image, actualPixels: actualPixels) { size in
                        Image(decorative: image, scale: 1)
                            .resizable().interpolation(.none)
                            .frame(width: size.width, height: size.height)
                            .background {
                                if options.background == .transparent { BackgroundTransparencyGrid() }
                            }
                            .accessibilityLabel("Foreground cutout preview")
                    }
                case .failure(let error):
                    Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Rendering subject…").controlSize(.small)
            }
        } else {
            Picker("Correction tool", selection: $brushMode) {
                Text("Brush").tag(true)
                Text("Rectangle").tag(false)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)
            .onChange(of: brushMode) { drawing = false }
            let original = document.analysis.source.image
            if brushMode {
                brushControls(document, edit: request.edit)
                ImageMaskViewport(image: original, actualPixels: actualPixels) { size in
                    ForegroundBrushCanvas(image: original, overlay: liveOverlay(for: request),
                                          refinements: request.edit.refinements, action: drawingAction, width: brushWidth,
                                          enabled: request.edit.refinements.count < RemoveBackgroundEdit.maximumCorrections) { stroke, action in
                        update(document) { edit in
                            guard edit.refinements.count < RemoveBackgroundEdit.maximumCorrections else { return }
                            edit.refinements.append(ForegroundRefinement(stroke: stroke, action: action))
                        }
                    }
                    .id(document.input)
                    .frame(width: size.width, height: size.height)
                }
                .overlay(alignment: .topTrailing) {
                    if liveOverlay(for: request) != nil, rendered?.request != request {
                        ProgressView("Updating mask…")
                            .controlSize(.small)
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
            } else {
                refinementControls(document, edit: request.edit)
                ImageMaskViewport(image: original, actualPixels: actualPixels) { size in
                    ImageMaskCanvas(image: original, masks: request.edit.refinements.compactMap(\.region),
                                    selected: $selectedRegion, drawing: $drawing, tint: { region in
                        request.edit.refinements.first { $0.id == region.id }?.action == .remove ? .orange : .green
                    }) { regions in
                        update(document) { edit in
                            let updated = Dictionary(uniqueKeysWithValues: regions.map { ($0.id, $0) })
                            let previous = Set(edit.refinements.map(\.id))
                            edit.refinements = edit.refinements.compactMap { item in
                                guard item.region != nil else { return item }
                                return updated[item.id].map { ForegroundRefinement(region: $0, action: item.action) }
                            }
                            for region in regions where !previous.contains(region.id)
                                && edit.refinements.count < RemoveBackgroundEdit.maximumCorrections {
                                edit.refinements.append(ForegroundRefinement(region: region, action: drawingAction))
                            }
                        }
                    }
                    .id(document.input)
                    .frame(width: size.width, height: size.height)
                }
            }
            if request.edit.refinements.count >= RemoveBackgroundEdit.maximumCorrections {
                Text("This image has \(RemoveBackgroundEdit.maximumCorrections) corrections. Remove a correction before drawing another.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func liveOverlay(for request: RenderRequest) -> CGImage? {
        guard let rendered, rendered.request.input == request.input,
              rendered.request.digest == request.digest, rendered.request.options.background == .transparent,
              case .success(let image) = rendered.result else { return nil }
        return image
    }

    private func brushControls(_ document: Document, edit: RemoveBackgroundEdit) -> some View {
        HStack {
            Picker("Brush action", selection: $drawingAction) {
                ForEach(ForegroundRefinement.Action.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 95)
            Slider(value: $brushWidth, in: ForegroundBrushStroke.widths)
                .accessibilityLabel("Brush width")
            let pixels = Int((brushWidth * Double(min(document.analysis.source.image.width,
                                                       document.analysis.source.image.height))).rounded())
            Text("\(max(1, pixels)) px").font(.caption.monospacedDigit())
            let lastBrush = edit.refinements.last { $0.region == nil }?.id
            Button("Undo Brush Stroke", systemImage: "arrow.uturn.backward") {
                update(document) { $0.refinements.removeAll { $0.id == lastBrush } }
            }
            .labelStyle(.iconOnly)
            .help("Undo Brush Stroke")
            .disabled(lastBrush == nil)
        }
    }

    @ViewBuilder
    private func refinementControls(_ document: Document, edit: RemoveBackgroundEdit) -> some View {
        HStack {
            Picker("New refinement action", selection: $drawingAction) {
                ForEach(ForegroundRefinement.Action.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 95)
            Button(drawing ? "Cancel Drawing" : "Draw Region", systemImage: "rectangle.dashed") { drawing.toggle() }
                .disabled(!drawing && edit.refinements.count >= RemoveBackgroundEdit.maximumCorrections)
        }
        let rectangles = edit.refinements.filter { $0.region != nil }
        if !rectangles.isEmpty {
            HStack {
                Picker("Selected region", selection: $selectedRegion) {
                    Text("Choose Region").tag(UUID?.none)
                    ForEach(Array(rectangles.enumerated()), id: \.element.id) { index, refinement in
                        Text("\(refinement.action.rawValue) \(index + 1)").tag(Optional(refinement.id))
                    }
                }
                .frame(maxWidth: 160)
                Button("Delete Region", systemImage: "minus.circle") {
                    update(document) { $0.refinements.removeAll { $0.id == selectedRegion } }
                    selectedRegion = nil
                }
                .disabled(selectedRegion == nil)
            }
        }
    }

    private var color: Binding<Color> {
        Binding {
            let rgb = options.backgroundColor
            return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                         blue: Double(rgb & 255) / 255)
        } set: { value in
            guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
            func byte(_ unit: CGFloat) -> UInt32 { UInt32(clamping: Int((min(1, max(0, unit)) * 255).rounded())) }
            options.backgroundColor = byte(rgb.redComponent) << 16 | byte(rgb.greenComponent) << 8 | byte(rgb.blueComponent)
        }
    }

    private func update(_ document: Document, edit update: (inout RemoveBackgroundEdit) -> Void) {
        var edit = options.edit(for: document.input, analysis: document.analysis)
        update(&edit)
        options.apply(edit, to: document.input, analysis: document.analysis)
    }

    private func open(_ input: URL?) async {
        document = nil
        issue = nil
        drawing = false
        selectedRegion = nil
        showsResult = true
        guard let input else { return }
        do {
            let analysis = try await runImageMaskWork { try RemoveBackground.analyze(input) }
            try Task.checkCancellation()
            options.discardIfChanged(input, analysis: analysis)
            document = Document(input: input, analysis: analysis)
            if analysis.subjects.isEmpty { showsResult = false }
        } catch {
            if !Task.isCancelled { issue = error.localizedDescription }
        }
    }

    private func render(_ document: Document, request: RenderRequest) async {
        do {
            try await Task.sleep(for: .milliseconds(150))
            let image = try await runImageMaskWork {
                try RemoveBackground.preview(document.analysis, edit: request.edit, options: request.options)
            }
            try Task.checkCancellation()
            rendered = Rendered(request: request, result: .success(image))
        } catch {
            if !Task.isCancelled { rendered = Rendered(request: request, result: .failure(error)) }
        }
    }
}

@MainActor
private struct BackgroundTransparencyGrid: View {
    private static let tile = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
        NSColor.gray.withAlphaComponent(0.18).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 12, height: 12)).fill()
        NSBezierPath(rect: NSRect(x: 12, y: 12, width: 12, height: 12)).fill()
        return true
    }

    var body: some View {
        Rectangle().fill(ImagePaint(image: Image(nsImage: Self.tile)))
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}
