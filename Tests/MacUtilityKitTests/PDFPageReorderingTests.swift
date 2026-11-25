import Testing
import UtilityCore
@testable import MacUtilityKit

struct PDFPageReorderingTests {
    @Test func insertsOnEitherSideInEitherDirection() {
        let pages = [1, 2, 3, 4]
        #expect(PDFPageInsertion.before.reorder(pages, moving: [4], relativeTo: 1) == [4, 1, 2, 3])
        #expect(PDFPageInsertion.after.reorder(pages, moving: [1], relativeTo: 4) == [2, 3, 4, 1])
        #expect(PDFPageInsertion.before.reorder(pages, moving: [1], relativeTo: 3) == [2, 1, 3, 4])
        #expect(PDFPageInsertion.after.reorder(pages, moving: [4], relativeTo: 2) == [1, 2, 4, 3])
    }

    @Test func movesNoncontiguousSelectionInDocumentOrderAndIgnoresNoOps() {
        let pages = [1, 2, 3, 4, 5]
        #expect(PDFPageInsertion.after.reorder(pages, moving: [4, 2], relativeTo: 5) == [1, 3, 5, 2, 4])
        #expect(PDFPageInsertion.before.reorder(pages, moving: [2, 4], relativeTo: 4) == nil)
        #expect(PDFPageInsertion.before.reorder(pages, moving: [2], relativeTo: 3) == nil)
        #expect(PDFPageInsertion.after.reorder(pages, moving: [6], relativeTo: 3) == nil)
    }

    @Test func extractionRangePreservesDraggedOrder() throws {
        var options = PDFExtractOptions()
        options.range = "5–3, 1, 2"
        options.order = .selection
        let pages = try PDFPageEditing.extractPages(pageCount: 5, options: options)
        let reordered = try #require(PDFPageInsertion.before.reorder(pages, moving: [1], relativeTo: 5))
        options.range = PageSelection.expression(for: reordered.map { $0 - 1 })
        #expect(try PDFPageEditing.extractPages(pageCount: 5, options: options) == [1, 5, 4, 3, 2])
    }
}
