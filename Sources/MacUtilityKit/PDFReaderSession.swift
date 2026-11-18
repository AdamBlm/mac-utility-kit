import AppKit
import Observation
import PDFKit

@MainActor
@Observable
final class PDFReaderSession {
    let view: PDFView
    private(set) var source: URL?
    private(set) var document: PDFDocument?
    private(set) var error: String?
    private(set) var pageNumber = 0
    private(set) var isSearching = false
    private var searchTerm: String?
    private var matches: [PDFSelection] = []
    private var matchIndex: Int?

    var hasMatches: Bool { !matches.isEmpty }

    var matchStatus: String? {
        if let matchIndex { return "\(matchIndex + 1) / \(matches.count)" }
        if searchTerm != nil, !isSearching { return "No matches" }
        return nil
    }

    init() {
        view = PDFView()
        view.displayMode = .singlePageContinuous
        view.autoScales = true
        view.backgroundColor = .windowBackgroundColor
    }

    func open(_ url: URL?) {
        resetSearch()
        source = url
        view.document = nil
        document = nil
        error = nil
        pageNumber = 0
        guard let url else { return }
        guard url.isFileURL, let pdf = PDFDocument(url: url), pdf.isLocked || pdf.pageCount > 0 else {
            error = "This PDF could not be opened."
            return
        }
        document = pdf
        if !pdf.isLocked { show(pdf) }
    }

    func unlock(_ password: String) {
        guard let document, document.isLocked else { return }
        guard document.unlock(withPassword: password) else {
            error = "The PDF password is incorrect."
            return
        }
        error = nil
        show(document)
    }

    private func show(_ document: PDFDocument) {
        view.document = document
        view.autoScales = true
        synchronizePage()
        if pageNumber == 0, document.pageCount > 0 { pageNumber = 1 }
    }

    func synchronizePage() {
        guard let current = view.currentPage, let document else { return }
        let index = document.index(for: current)
        if (0..<document.pageCount).contains(index) { pageNumber = index + 1 }
    }

    func navigatePage(by step: Int) {
        let index = pageNumber - 1 + step
        guard let document, (0..<document.pageCount).contains(index), let page = document.page(at: index) else { return }
        view.go(to: page)
    }

    func printDocument() {
        guard let document, !document.isLocked, document.allowsPrinting else { return }
        view.print(with: .shared, autoRotate: true, pageScaling: .pageScaleToFit)
    }

    func search(_ term: String) {
        guard let document, !document.isLocked, !term.isEmpty else { return }
        if term == searchTerm {
            if !isSearching { navigateMatch(by: 1) }
            return
        }
        resetSearch()
        searchTerm = term
        isSearching = true
        document.beginFindString(term, withOptions: .caseInsensitive)
    }

    func resetSearch() {
        cancelSearch()
        searchTerm = nil
        matches = []
        matchIndex = nil
        view.highlightedSelections = nil
        view.clearSelection()
    }

    func cancelSearch() {
        isSearching = false
        document?.cancelFindString()
    }

    func addSearchResult(_ notification: Notification) {
        guard isSearching, notification.object as? PDFDocument === document,
              let selection = notification.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection else { return }
        selection.color = .systemYellow.withAlphaComponent(0.35)
        matches.append(selection)
    }

    func finishSearch(_ notification: Notification) {
        guard isSearching, notification.object as? PDFDocument === document else { return }
        isSearching = false
        view.highlightedSelections = matches
        navigateMatch(by: 1)
    }

    func navigateMatch(by step: Int) {
        guard !isSearching, !matches.isEmpty else { return }
        let index = ((matchIndex ?? (step > 0 ? -1 : 0)) + step + matches.count) % matches.count
        matchIndex = index
        let selection = matches[index]
        view.setCurrentSelection(selection, animate: true)
        view.go(to: selection)
    }
}
