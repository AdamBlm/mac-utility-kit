import AppKit
import PDFKit
import SwiftUI
import UtilityCore

struct PDFPageNumberControls: View {
    let document: PDFDocument
    let edits: [PDFPageEdit]?
    @Binding var options: PDFPageNumberOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingRow("Output pages") {
                TextField("All pages", text: $options.range)
                    .textFieldStyle(.roundedBorder)
                    .help("Number pages in the edited order. Enter All or a range such as 2–5, 8.")
            }
            SettingRow("Start at") {
                TextField("Starting number", value: $options.startNumber, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100)
            }
            SettingRow("Position") {
                Picker("Position", selection: $options.placement) {
                    ForEach(PDFPageNumberOptions.Placement.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            numberPreview
        }
    }

    @ViewBuilder
    private var numberPreview: some View {
        let count = edits?.count ?? document.pageCount
        let result = Result { try PDFPageNumbers.labels(pageCount: count, options: options) }
        switch result {
        case .success(let labels):
            if let first = labels.keys.min(), let label = labels[first] {
                Label("\(labels.count) selected · Output page \(first + 1) starts at \(label)",
                      systemImage: "number")
                    .font(.caption).foregroundStyle(.secondary)
                if let sample = try? preview(at: first, label: label) {
                    Image(nsImage: sample)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 230, maxHeight: 180)
                        .accessibilityLabel("Page number placement preview")
                }
            }
        case .failure(let error):
            Text(error.localizedDescription)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func preview(at index: Int, label: String) throws -> NSImage {
        let edit = edits?[index] ?? PDFPageEdit(pageNumber: index + 1)
        let page = try PDFPageEditing.editedPage(edit, from: document)
        _ = try PDFPageNumbers.add(label, to: page, placement: options.placement)
        return page.thumbnail(of: CGSize(width: 230, height: 180), for: .cropBox)
    }
}
