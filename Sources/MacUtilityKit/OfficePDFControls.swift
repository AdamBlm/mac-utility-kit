import AppKit
import SwiftUI
import UtilityCore

struct OfficePDFControls: View {
    let inputs: [URL]
    @Binding var options: OfficePDFOptions
    let kind: OfficePDFKind

    @State private var chosen: URL?
    @State private var rendering: Request?
    @State private var preview: Completed?
    @State private var page: Int = 1

    private struct Request: Equatable {
        let id = UUID()
        let input: URL
        let options: OfficePDFOptions
    }

    private struct Completed {
        let request: Request
        let result: Result<OfficePDF.Preview, any Error>
    }

    private var activeInput: URL? {
        if let chosen, inputs.contains(chosen) { return chosen }
        return inputs.first
    }

    private var unit: String {
        switch kind {
        case .word: "page"
        case .powerPoint: "slide"
        case .excel: options.singlePageSheets ? "sheet" : "page"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            chooseOffice
            SettingRow(unit.capitalized + " range") {
                TextField("All or a range", text: $options.pageRange)
                    .textFieldStyle(.roundedBorder)
                    .help("Example: 1–3, 5")
            }
            switch kind {
            case .word:
                Text("Uses the document’s page size and margins. LibreOffice may substitute missing fonts.")
                    .font(.callout).foregroundStyle(.secondary)
            case .powerPoint:
                Toggle("Include hidden slides", isOn: $options.includesHiddenSlides)
                Text("Slides export as individual static pages. LibreOffice may substitute missing fonts.")
                    .font(.callout).foregroundStyle(.secondary)
            case .excel:
                Toggle("One page per sheet", isOn: $options.singlePageSheets)
                Text(options.singlePageSheets
                     ? "Includes hidden sheets and uses each entire sheet. Saved print areas and paper sizes are ignored."
                     : "Uses saved print areas, orientation, paper size, and scaling.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            availability
            previewPanel
        }
        .task(id: rendering) {
            guard let rendering else { return }
            do {
                let result = try await OfficePDF.preview(rendering.input, kind: kind, options: rendering.options)
                try Task.checkCancellation()
                page = result.selectedPages.first ?? 1
                preview = Completed(request: rendering, result: .success(result))
            } catch {
                if !Task.isCancelled { preview = Completed(request: rendering, result: .failure(error)) }
            }
            if self.rendering == rendering { self.rendering = nil }
        }
        .onChange(of: activeInput) { rendering = nil }
        .onChange(of: options) { rendering = nil }
    }

    private var chooseOffice: some View {
        HStack {
            Button("Choose LibreOffice…", systemImage: "gearshape") {
                let panel = NSOpenPanel()
                panel.message = "Choose LibreOffice.app or the soffice executable."
                if panel.runModal() == .OK { options.libreOfficeExecutable = panel.url }
            }
            if let engine = options.libreOfficeExecutable {
                Text(engine.lastPathComponent)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).help(engine.path)
                Button("Clear LibreOffice", systemImage: "xmark.circle") { options.libreOfficeExecutable = nil }
                    .labelStyle(.iconOnly)
            }
        }
    }

    @ViewBuilder
    private var availability: some View {
        let issues = inputs.compactMap { input in OfficePDF.optionIssue(input, kind: kind, options: options).map { (input, $0) } }
        if options.libreOfficeExecutable == nil {
            Text("Choose LibreOffice to preview and export.").font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                Text(inputs.count == 1 ? issue.1 : "\(issue.0.lastPathComponent) · \(issue.1)")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var previewPanel: some View {
        if inputs.count > 1 {
            SettingRow("Preview file") {
                Picker("Preview file", selection: Binding(get: { activeInput }, set: { chosen = $0 })) {
                    ForEach(Array(inputs.enumerated()), id: \.offset) { _, input in
                        Text(input.lastPathComponent).tag(Optional(input))
                    }
                }
                .labelsHidden()
            }
        }
        HStack {
            Button("Preview PDF…", systemImage: "doc.viewfinder") {
                if let activeInput { rendering = Request(input: activeInput, options: options) }
            }
            .disabled(rendering != nil || activeInput.map { OfficePDF.optionIssue($0, kind: kind, options: options) != nil } ?? true)
            if rendering != nil {
                ProgressView().controlSize(.small)
                Button("Cancel") { rendering = nil }
            }
        }
        if let preview, preview.request.input == activeInput, preview.request.options == options, rendering == nil {
            switch preview.result {
            case .success(let document):
                rendered(document)
            case .failure(let error):
                Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func rendered(_ document: OfficePDF.Preview) -> some View {
        HStack {
            Stepper("\(unit.capitalized) \(page) of \(document.totalPages)", value: $page, in: 1...document.totalPages)
            Spacer(minLength: 10)
            if document.selectedPages.contains(page) {
                Label("Included", systemImage: "checkmark.circle")
            } else {
                Text("Outside selected range")
            }
        }
        .font(.callout)
        if let rendered = try? OfficePDF.renderedPage(document, page: page) {
            Image(decorative: rendered.image, scale: 1)
                .resizable().scaledToFit().frame(maxWidth: 420, maxHeight: 270)
                .accessibilityLabel("Preview of \(unit) \(page)")
            Text("\(Double(rendered.size.width).formatted(.number.precision(.fractionLength(0...1)))) × \(Double(rendered.size.height).formatted(.number.precision(.fractionLength(0...1)))) pt")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
