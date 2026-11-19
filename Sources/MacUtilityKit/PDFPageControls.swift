import AppKit
import PDFKit
import SwiftUI
import UtilityCore

struct PDFMergeInspection {
    let stamp: PDFMergeSourceStamp?
    let input: URL
    let document: PDFDocument?
    let requiresPassword: Bool
    let acceptedPassword: String?
    let issue: String?

    func count(password: String) -> Int? {
        guard !requiresPassword || acceptedPassword == password else { return nil }
        return document?.pageCount
    }

    static func load(_ input: URL, password: String) -> Self {
        guard let before = try? PDFMergeSourceStamp.read(input) else {
            return unavailable(input)
        }
        let loaded = open(input, password: password, stamp: before)
        return (try? PDFMergeSourceStamp.read(input)) == before ? loaded : unavailable(input)
    }

    private static func unavailable(_ input: URL) -> Self {
        Self(stamp: nil, input: input, document: nil, requiresPassword: false,
             acceptedPassword: nil, issue: "This source could not be verified. Refresh source previews to try again.")
    }

    private static func open(_ input: URL, password: String, stamp: PDFMergeSourceStamp) -> Self {
        do {
            let source = try PDFOperations.open(input, password: password)
            return Self(stamp: stamp, input: input, document: source.document,
                        requiresPassword: source.requiredPassword,
                        acceptedPassword: source.requiredPassword ? password : nil, issue: nil)
        } catch PDFOperations.SourceError.passwordRequired {
            return Self(stamp: stamp, input: input, document: nil, requiresPassword: true,
                        acceptedPassword: nil, issue: password.isEmpty ? nil : "Incorrect PDF password.")
        } catch {
            return Self(stamp: stamp, input: input, document: nil, requiresPassword: false,
                        acceptedPassword: nil, issue: error.localizedDescription)
        }
    }
}

struct PDFPageControls: View {
    let input: URL
    @Binding var range: String
    @Binding var password: String
    @Binding var inspection: PDFMergeInspection?
    @State private var expanded = false
    @State private var anchor: Int?

    var body: some View {
        let current = inspection?.input == input ? inspection : nil
        let count = current?.count(password: password)
        let selected = count.flatMap { try? PageSelection.indices(range, pageCount: $0) }
        let selectedIndices = Set(selected ?? [])
        let excluded = range.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none"
        VStack(alignment: .leading, spacing: 6) {
            TextField("Pages (all, none, or e.g. 1, 3–5)", text: $range)
                .accessibilityLabel("Selected pages for \(input.lastPathComponent)")
            if current?.requiresPassword == true {
                HStack {
                    SecureField("PDF password", text: $password).onSubmit(unlock)
                    Button("Unlock", action: unlock)
                }
            }
            if let issue = current?.issue, !excluded { Text(issue).font(.caption).foregroundStyle(.secondary) }
            if let count {
                if let selected {
                    Text("\(selected.count) of \(count) pages selected").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Check the page range. This file has \(count) pages.").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Page thumbnails", isExpanded: $expanded) {
                    HStack {
                        Button("All") { range = ""; anchor = nil }
                        Button("Clear") { range = "none"; anchor = nil }
                    }
                    ScrollView(.horizontal) {
                        LazyHStack {
                            ForEach(0..<count, id: \.self) { index in
                                Button {
                                    select(index, from: selected ?? [])
                                } label: {
                                    VStack {
                                        if let thumbnail = current?.document?.page(at: index)?.thumbnail(
                                            of: NSSize(width: 64, height: 82), for: .cropBox
                                        ) {
                                            Image(nsImage: thumbnail)
                                        }
                                        Label("Page \(index + 1)", systemImage: selectedIndices.contains(index)
                                              ? "checkmark.circle.fill" : "circle").font(.caption)
                                    }
                                }
                                .accessibilityAddTraits(selectedIndices.contains(index) ? .isSelected : [])
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: input) { anchor = nil }
        .onChange(of: count) { anchor = nil }
        .task(id: input) {
            if inspection?.input != input { unlock() }
        }
    }

    private func unlock() { inspection = PDFMergeInspection.load(input, password: password) }

    private func select(_ index: Int, from selected: [Int]) {
        var pages = selected
        if NSEvent.modifierFlags.contains(.shift), let anchor {
            var existing = Set(pages)
            pages += (min(anchor, index)...max(anchor, index)).filter { existing.insert($0).inserted }
        } else if let position = pages.firstIndex(of: index) {
            pages.remove(at: position)
        } else {
            pages.append(index)
        }
        anchor = index
        range = pages.isEmpty ? "none" : pages.map { String($0 + 1) }.joined(separator: ", ")
    }
}
