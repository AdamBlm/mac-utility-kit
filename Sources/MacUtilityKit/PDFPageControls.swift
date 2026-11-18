import AppKit
import PDFKit
import SwiftUI
import UtilityCore

struct PDFPageControls: View {
    let input: URL
    @Binding var range: String
    @Binding var password: String
    @State private var document: PDFDocument?
    @State private var expanded = false
    @State private var protectedDocument = false
    @State private var unlockFailed = false

    var body: some View {
        let count = document?.pageCount ?? 0
        let selected = try? PageSelection.indices(range, pageCount: count)
        VStack(alignment: .leading, spacing: 6) {
            TextField("Pages (all, none, or e.g. 1, 3–5)", text: $range)
            if protectedDocument {
                HStack {
                    SecureField("PDF password", text: $password)
                    Button("Unlock preview") {
                        guard let fresh = PDFDocument(url: input), fresh.unlock(withPassword: password) else {
                            unlockFailed = true
                            return
                        }
                        document = fresh
                        unlockFailed = false
                    }
                }
                if unlockFailed { Text("Could not unlock PDF preview.").font(.caption) }
            }
            if count > 0 {
                if let selected {
                    Text("\(selected.count) of \(count) pages selected").font(.caption).foregroundStyle(.secondary)
                    if !selected.isEmpty, selected.count <= 40 {
                        Text("Export order: " + selected.map { String($0 + 1) }.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Check the page range. This file has \(count) pages.").font(.caption)
                }
                DisclosureGroup("Page thumbnails", isExpanded: $expanded) {
                    if expanded {
                        HStack {
                            Button("All") { range = "" }
                            Button("Clear") { range = "none" }
                        }
                        ScrollView(.horizontal) {
                            LazyHStack {
                                ForEach(0..<count, id: \.self) { index in
                                    Button {
                                        var pages = selected ?? []
                                        if let position = pages.firstIndex(of: index) {
                                            pages.remove(at: position)
                                        } else {
                                            pages.append(index)
                                        }
                                        range = pages.isEmpty ? "none" : pages.map { String($0 + 1) }.joined(separator: ", ")
                                    } label: {
                                        VStack {
                                            if let thumbnail = document?.page(at: index)?.thumbnail(
                                                of: NSSize(width: 64, height: 82), for: .cropBox
                                            ) {
                                                Image(nsImage: thumbnail)
                                            }
                                            Label("Page \(index + 1)", systemImage: selected?.contains(index) == true
                                                  ? "checkmark.circle.fill" : "circle")
                                                .font(.caption)
                                        }
                                    }
                                    .accessibilityAddTraits(selected?.contains(index) == true ? .isSelected : [])
                                }
                            }
                        }
                    }
                }
            }
        }
        .task(id: input) {
            if (try? input.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .pdf)) == true {
                document = PDFDocument(url: input)
                protectedDocument = document?.isLocked == true
                if protectedDocument, !password.isEmpty {
                    _ = document?.unlock(withPassword: password)
                }
            }
        }
    }
}
