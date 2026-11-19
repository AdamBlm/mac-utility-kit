import AppKit
import PDFKit
import SwiftUI
import UtilityCore

struct PDFMergeOrderView: View {
    @Binding var draft: ToolDraft
    @State private var storyboard = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Refresh Source Previews", systemImage: "arrow.clockwise", action: refresh)
            if let pages = draft.mergePages {
                if pages.isEmpty {
                    Text("Choose at least one page.").font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("\(pages.count) page\(pages.count == 1 ? "" : "s") in merge order")
                            .font(.callout).accessibilityAddTraits(.isHeader)
                        Spacer()
                        if draft.mergeOrder != nil {
                            Button("Reset to Source Order") { draft.mergeOrder = nil }
                        }
                    }
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 9) {
                            ForEach(Array(pages.enumerated()), id: \.element) { index, reference in
                                pageCard(reference, position: index, pages: pages)
                            }
                        }
                    }
                }
            } else {
                Text("Check source files, page ranges, and PDF passwords to preview the merge order.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .onChange(of: draft.inputs) { storyboard = UUID() }
    }

    private func refresh() {
        storyboard = UUID()
        draft.mergeInspections = Dictionary(uniqueKeysWithValues: draft.inputs.enumerated().map { index, file in
            (index, PDFMergeInspection.load(file, password: draft.passwords[index, default: ""]))
        })
    }

    private func pageCard(_ reference: PDFMergePageReference, position: Int, pages: [PDFMergePageReference]) -> some View {
        let file = draft.inputs[reference.source]
        return VStack(spacing: 6) {
            if let image = draft.mergeInspections[reference.source]?.document?.page(at: reference.page)?
                .thumbnail(of: NSSize(width: 76, height: 90), for: .cropBox) {
                Image(nsImage: image).frame(height: 90)
            }
            Text("\(position + 1). \(file.lastPathComponent)").font(.caption).lineLimit(1).truncationMode(.middle)
            Text("Page \(reference.page + 1)").font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("Move earlier", systemImage: "chevron.left") { move(position, to: position - 1, in: pages) }
                    .accessibilityLabel("Move \(file.lastPathComponent), page \(reference.page + 1), earlier")
                    .disabled(position == 0)
                Button("Move later", systemImage: "chevron.right") { move(position, to: position + 1, in: pages) }
                    .accessibilityLabel("Move \(file.lastPathComponent), page \(reference.page + 1), later")
                    .disabled(position + 1 == pages.count)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .frame(width: 101)
        .padding(6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .help("\(file.path), source page \(reference.page + 1), output page \(position + 1)")
        .draggable(payload(reference))
        .dropDestination(for: String.self) { incoming, _ in
            guard incoming.count == 1, let value = incoming.first,
                  let current = draft.mergePages,
                  let start = current.firstIndex(where: { payload($0) == value }),
                  let target = current.firstIndex(of: reference), start != target else { return false }
            move(start, to: target, in: current)
            return true
        }
    }

    private func payload(_ page: PDFMergePageReference) -> String {
        "mac-utility-merge/\(storyboard)/\(draft.mergeSourceRevision)/\(page.source)/\(page.page)"
    }

    private func move(_ source: Int, to destination: Int, in pages: [PDFMergePageReference]) {
        guard pages.indices.contains(source), pages.indices.contains(destination) else { return }
        var ordered = pages
        let reference = ordered.remove(at: source)
        ordered.insert(reference, at: destination)
        draft.mergeOrder = ordered
    }
}
