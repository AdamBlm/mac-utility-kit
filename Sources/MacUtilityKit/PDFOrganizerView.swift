import AppKit
import PDFKit
import SwiftUI
import UtilityCore

struct PDFOrganizerView: View {
    let document: PDFDocument
    @Binding var pages: [PDFPageEdit]?
    private let persistedHistory: Binding<PDFOrganizerHistory>?

    @State private var localHistory = PDFOrganizerHistory()
    @State private var selection: Set<Int> = []
    @State private var selectionAnchor: Int?
    @State private var showsRemoved = false
    @State private var dragScope = UUID().uuidString

    init(document: PDFDocument, pages: Binding<[PDFPageEdit]?>, history: Binding<PDFOrganizerHistory>? = nil) {
        self.document = document
        _pages = pages
        persistedHistory = history
    }

    private var history: PDFOrganizerHistory {
        get { persistedHistory?.wrappedValue ?? localHistory }
        nonmutating set {
            if let persistedHistory {
                persistedHistory.wrappedValue = newValue
            } else {
                localHistory = newValue
            }
        }
    }

    private var layout: [OrganizerPage] {
        if let current = history.current { return current }
        let original = (0..<document.pageCount).map { OrganizerPage(number: $0 + 1) }
        guard let pages else { return original }
        let retained = pages.map { OrganizerPage(number: $0.pageNumber, quarterTurns: $0.quarterTurns) }
        let numbers = Set(retained.map(\.number))
        return retained + original.filter { !numbers.contains($0.number) }.map {
            OrganizerPage(number: $0.number, removed: true)
        }
    }

    var body: some View {
        let retained = layout.filter { !$0.removed }
        let removed = layout.filter(\.removed)
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    historyButtons
                    Spacer(minLength: 8)
                    editButtons(retained: retained)
                }
                VStack(alignment: .leading, spacing: 6) {
                    historyButtons
                    editButtons(retained: retained)
                }
            }
            if retained.isEmpty {
                Text("Restore at least one page to export.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                pageStrip(retained, acceptsReordering: true)
            }
            if !removed.isEmpty {
                DisclosureGroup("\(removed.count) removed", isExpanded: $showsRemoved) {
                    pageStrip(removed, acceptsReordering: false)
                        .padding(.top, 6)
                }
            }
            Text("\(retained.count) of \(document.pageCount) pages in output")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: ObjectIdentifier(document)) { _, _ in
            selection = []
            selectionAnchor = nil
            showsRemoved = false
            dragScope = UUID().uuidString
        }
    }

    private var historyButtons: some View {
        HStack(spacing: 6) {
            Button("Undo", systemImage: "arrow.uturn.backward", action: undo)
                .disabled(history.undo.isEmpty)
            Button("Redo", systemImage: "arrow.uturn.forward", action: redo)
                .disabled(history.redo.isEmpty)
        }
        .controlSize(.small)
    }

    private func editButtons(retained: [OrganizerPage]) -> some View {
        let selectedIndex = selection.count == 1
            ? retained.firstIndex { selection.contains($0.number) } : nil
        let hasSelectedRetained = retained.contains { selection.contains($0.number) }
        let hasSelectedRemoved = layout.contains { $0.removed && selection.contains($0.number) }

        return HStack(spacing: 6) {
            Button("Move earlier", systemImage: "arrow.left") {
                moveSelection(by: -1)
            }
            .labelStyle(.iconOnly)
            .help("Move selected page earlier")
            .disabled(selectedIndex.map { $0 == 0 } ?? true)

            Button("Move later", systemImage: "arrow.right") {
                moveSelection(by: 1)
            }
            .labelStyle(.iconOnly)
            .help("Move selected page later")
            .disabled(selectedIndex.map { $0 == retained.count - 1 } ?? true)

            Button("Rotate left", systemImage: "rotate.left") { rotate(by: -1) }
                .labelStyle(.iconOnly)
                .help("Rotate selected pages left")
                .disabled(!hasSelectedRetained)

            Button("Rotate right", systemImage: "rotate.right") { rotate(by: 1) }
                .labelStyle(.iconOnly)
                .help("Rotate selected pages right")
                .disabled(!hasSelectedRetained)

            if hasSelectedRemoved {
                Button("Restore") { setRemoved(false) }
            } else {
                Button("Remove") { setRemoved(true) }
                    .disabled(!hasSelectedRetained)
            }
        }
        .controlSize(.small)
    }

    private func pageStrip(_ strip: [OrganizerPage], acceptsReordering: Bool) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: acceptsReordering ? 0 : 8) {
                ForEach(strip) { page in
                    if acceptsReordering {
                        thumbnail(page, in: strip)
                            .pdfPageReordering(payload: "\(dragScope):\(page.number)", width: 98) { value, edge in
                                guard value.hasPrefix(dragScope + ":"),
                                      let number = Int(value.dropFirst(dragScope.count + 1)) else { return false }
                                let retained = layout.filter { !$0.removed }
                                let group = selection.contains(number)
                                    ? retained.filter { selection.contains($0.number) }
                                    : retained.filter { $0.number == number }
                                guard let target = retained.first(where: { $0.number == page.number }),
                                      let ordered = edge.reorder(retained, moving: group, relativeTo: target) else { return false }
                                var remaining = ordered.makeIterator()
                                apply(layout.map { $0.removed ? $0 : remaining.next() ?? $0 })
                                return true
                            }
                    } else {
                        thumbnail(page, in: strip)
                    }
                }
            }
            .padding(3)
        }
    }

    private func thumbnail(_ page: OrganizerPage, in strip: [OrganizerPage]) -> some View {
        let selected = selection.contains(page.number)

        return Button {
            select(page.number, in: strip, modifiers: NSEvent.modifierFlags)
        } label: {
            VStack(spacing: 4) {
                PDFPageThumbnail(page: document.page(at: page.number - 1),
                                 quarterTurns: page.quarterTurns, isDimmed: page.removed)
                Text("Page \(page.number)")
            }
        }
        .buttonStyle(PDFPageCardStyle(selected: selected))
        .pdfPagePreview(document.page(at: page.number - 1), number: page.number, quarterTurns: page.quarterTurns)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            // Arrow events can carry the numeric-pad flag.
            let modifiers = press.modifiers.intersection([.option, .shift, .control, .command])
            guard !page.removed, modifiers == .option,
                  let index = strip.firstIndex(where: { $0.number == page.number }) else { return .ignored }
            let target = index + (press.key == .leftArrow ? -1 : 1)
            if strip.indices.contains(target) { _ = move(page.number, to: strip[target].number) }
            return .handled
        }
        .accessibilityLabel("Page \(page.number)\(page.removed ? ", removed" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(page.removed
              ? "Shift-click to select a range. Command-click to toggle a page."
              : "Shift-click for a range. Command-click to toggle. Option–Left or Option–Right Arrow moves the focused page.")
    }

    private func select(_ number: Int, in strip: [OrganizerPage], modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let selectionAnchor,
           let start = strip.firstIndex(where: { $0.number == selectionAnchor }),
           let end = strip.firstIndex(where: { $0.number == number }) {
            let range = Set(strip[min(start, end)...max(start, end)].map(\.number))
            selection = modifiers.contains(.command) ? selection.union(range) : range
            return
        }
        if modifiers.contains(.command) {
            if selection.contains(number), !modifiers.contains(.shift) {
                selection.remove(number)
                if selectionAnchor == number {
                    selectionAnchor = strip.first { selection.contains($0.number) }?.number
                }
            } else {
                selection.insert(number)
                selectionAnchor = number
            }
            return
        }
        selection = selection == [number] ? [] : [number]
        selectionAnchor = selection.contains(number) ? number : nil
    }

    private func moveSelection(by step: Int) {
        guard selection.count == 1, let number = selection.first else { return }
        let retained = layout.filter { !$0.removed }
        guard let index = retained.firstIndex(where: { $0.number == number }),
              retained.indices.contains(index + step) else { return }
        _ = move(number, to: retained[index + step].number)
    }

    private func move(_ number: Int, to target: Int) -> Bool {
        var next = layout
        guard let from = next.firstIndex(where: { $0.number == number && !$0.removed }),
              let to = next.firstIndex(where: { $0.number == target && !$0.removed }),
              from != to else { return false }
        next.insert(next.remove(at: from), at: to)
        apply(next)
        return true
    }

    private func rotate(by turns: Int) {
        apply(layout.map { page in
            var next = page
            if !page.removed && selection.contains(page.number) {
                next.quarterTurns = ((page.quarterTurns + turns) % 4 + 4) % 4
            }
            return next
        })
    }

    private func setRemoved(_ removed: Bool) {
        apply(layout.map { page in
            var next = page
            if selection.contains(page.number) { next.removed = removed }
            return next
        })
        if removed { showsRemoved = true }
    }

    private func apply(_ next: [OrganizerPage]) {
        let previous = layout
        guard next != previous else { return }
        var updated = history
        updated.undo.append(previous)
        updated.redo.removeAll()
        publish(next, history: updated)
    }

    private func undo() {
        let previous = layout
        var updated = history
        guard let next = updated.undo.popLast() else { return }
        updated.redo.append(previous)
        publish(next, history: updated)
    }

    private func redo() {
        let previous = layout
        var updated = history
        guard let next = updated.redo.popLast() else { return }
        updated.undo.append(previous)
        publish(next, history: updated)
    }

    private func publish(_ next: [OrganizerPage], history updated: PDFOrganizerHistory) {
        var updated = updated
        updated.current = next
        history = updated
        pages = next.filter { !$0.removed }.map {
            PDFPageEdit(pageNumber: $0.number, quarterTurns: $0.quarterTurns)
        }
    }
}

struct PDFOrganizerHistory {
    fileprivate var current: [OrganizerPage]?
    fileprivate var undo: [[OrganizerPage]] = []
    fileprivate var redo: [[OrganizerPage]] = []

    init() {}
}

private struct OrganizerPage: Hashable, Identifiable {
    let number: Int
    var quarterTurns = 0
    var removed = false
    var id: Int { number }
}
