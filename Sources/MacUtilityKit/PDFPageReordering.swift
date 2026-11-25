import SwiftUI
import UniformTypeIdentifiers

enum PDFPageInsertion {
    case before, after

    func reorder<Page: Hashable>(_ pages: [Page], moving source: [Page], relativeTo target: Page) -> [Page]? {
        guard !source.isEmpty, !source.contains(target) else { return nil }
        let selected = Set(source)
        let moving = pages.filter(selected.contains)
        var remaining = pages.filter { !selected.contains($0) }
        guard !moving.isEmpty, let index = remaining.firstIndex(of: target) else { return nil }
        remaining.insert(contentsOf: moving, at: index + (self == .after ? 1 : 0))
        return remaining == pages ? nil : remaining
    }
}

extension View {
    func pdfPageReordering(payload: String, width: CGFloat,
                           move: @escaping @MainActor (String, PDFPageInsertion) -> Bool) -> some View {
        modifier(PDFPageReordering(payload: payload, width: width, move: move))
    }
}

private struct PDFPageReordering: ViewModifier {
    static let type = UTType(exportedAs: "app.macutilitykit.pdf-page-reorder", conformingTo: .data)
    let payload: String
    let width: CGFloat
    let move: @MainActor (String, PDFPageInsertion) -> Bool
    @State private var insertion: PDFPageInsertion?

    func body(content: Content) -> some View {
        content
            .frame(width: width)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onDrag {
                let provider = NSItemProvider()
                let data = Data(payload.utf8)
                provider.registerDataRepresentation(forTypeIdentifier: Self.type.identifier, visibility: .ownProcess) {
                    completion in
                    completion(data, nil)
                    return nil
                }
                return provider
            }
            .onDrop(of: [Self.type], delegate: PageDrop(width: width + 8, insertion: $insertion, move: move))
            .overlay(alignment: insertion == .before ? .leading : .trailing) {
                if insertion != nil {
                    Capsule().fill(Color.accentColor)
                        .frame(width: 3)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 1)
                        .allowsHitTesting(false)
                }
            }
    }

    private struct PageDrop: DropDelegate {
        let width: CGFloat
        @Binding var insertion: PDFPageInsertion?
        let move: @MainActor (String, PDFPageInsertion) -> Bool

        func dropEntered(info: DropInfo) {
            insertion = edge(at: info.location)
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            insertion = edge(at: info.location)
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) { insertion = nil }

        func performDrop(info: DropInfo) -> Bool {
            insertion = nil
            let side = edge(at: info.location)
            let providers = info.itemProviders(for: [PDFPageReordering.type])
            guard providers.count == 1, let provider = providers.first else { return false }
            let apply = move
            provider.loadDataRepresentation(forTypeIdentifier: PDFPageReordering.type.identifier) { data, _ in
                guard let data, let payload = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in _ = apply(payload, side) }
            }
            return true
        }

        private func edge(at point: CGPoint) -> PDFPageInsertion {
            point.x < width / 2 ? .before : .after
        }
    }
}
