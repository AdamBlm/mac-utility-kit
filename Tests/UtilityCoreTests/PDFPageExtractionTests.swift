import Foundation
import PDFKit
import Testing
import UtilityCore

@Test func extractPagesRespectsSelectedOrderWithoutDuplicatingPages() throws {
    var options = PDFExtractOptions()
    options.range = "3, 1–2, 3"
    options.order = .selection
    #expect(try PDFPageEditing.extractPages(pageCount: 3, options: options) == [3, 1, 2])

    options.order = .document
    #expect(try PDFPageEditing.extractPages(pageCount: 3, options: options) == [1, 2, 3])

    options.range = "4–2, 1-3, 4"
    options.order = .selection
    #expect(try PDFPageEditing.extractPages(pageCount: 4, options: options) == [4, 3, 2, 1])
    options.order = .document
    #expect(try PDFPageEditing.extractPages(pageCount: 4, options: options) == [1, 2, 3, 4])
    #expect(throws: ToolError.self) { try PageSelection.indices("4–2", pageCount: 4) }
    #expect(throws: ToolError.self) { try PageSelection.indices("1", pageCount: 0) }

    let clicked = PageSelection.updating([0], at: 6, extendingFrom: nil)
    let extended = PageSelection.updating(clicked, at: 3, extendingFrom: 6, keepsRangeDirection: true)
    options.range = PageSelection.expression(for: extended)
    options.order = .selection
    #expect(try PDFPageEditing.extractPages(pageCount: 7, options: options) == [1, 7, 6, 5, 4])
}

@Test func extractPublishesTheRequestedPDFPageSequenceAndPreservesTheOriginal() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }

    let source = directory.appendingPathComponent("Source.pdf")
    var defaultBox = CGRect(x: 0, y: 0, width: 100, height: 200)
    let context = try #require(CGContext(source as CFURL, mediaBox: &defaultBox, nil))
    for width in [100, 110, 120] {
        var box = CGRect(x: 0, y: 0, width: width, height: 200)
        let encodedBox = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox: encodedBox] as CFDictionary)
        context.endPDFPage()
    }
    context.closePDF()

    let document = try #require(PDFDocument(url: source))
    let rotated = try #require(document.page(at: 2))
    rotated.rotation = 90
    try #require(document.write(to: source))
    let originalBytes = try Data(contentsOf: source)

    let output = directory.appendingPathComponent("Selected.pdf")
    var options = PDFExtractOptions()
    options.range = "3–1, 3"
    options.order = .selection
    try await PDFPageEditing.extract(source, to: output, options: options) { _ in }

    let result = try #require(PDFDocument(url: output))
    let first = try #require(result.page(at: 0))
    let second = try #require(result.page(at: 1))
    let third = try #require(result.page(at: 2))
    #expect(result.pageCount == 3)
    #expect(first.rotation == 90)
    #expect(min(first.bounds(for: .mediaBox).width, first.bounds(for: .mediaBox).height) == 120)
    #expect(second.rotation == 0)
    #expect(second.bounds(for: .mediaBox).width == 110)
    #expect(third.bounds(for: .mediaBox).width == 100)
    #expect(try Data(contentsOf: source) == originalBytes)

    let existingBytes = try Data(contentsOf: output)
    await #expect(throws: ToolError.self) {
        try await PDFPageEditing.extract(source, to: output, options: options) { _ in }
    }
    #expect(try Data(contentsOf: output) == existingBytes)

    options.range = "9"
    let invalidOutput = directory.appendingPathComponent("Invalid.pdf")
    await #expect(throws: ToolError.self) {
        try await PDFPageEditing.extract(source, to: invalidOutput, options: options) { _ in }
    }
    #expect(!FileManager.default.fileExists(atPath: invalidOutput.path))
}

@Test func extractRejectsEmptySelectionsAndInvalidPageCounts() throws {
    var options = PDFExtractOptions()
    for invalid in ["", "  ", "none", "0", "4", "4–1", "3–0", "1, invalid"] {
        options.range = invalid
        #expect(throws: ToolError.self) {
            try PDFPageEditing.extractPages(pageCount: 3, options: options)
        }
    }
    options.range = "1"
    #expect(throws: ToolError.self) {
        try PDFPageEditing.extractPages(pageCount: 0, options: options)
    }
}

@Test func extractRejectsSamePathReplacementOfReviewedPages() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appending(path: "Source.pdf")
    let output = directory.appending(path: "Extracted.pdf")
    func fixture(width: Int) -> Data {
        pdfFixtureData(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(width) 300] /Resources <<>> >>"
        ])
    }
    try fixture(width: 220).write(to: input)
    var options = PDFExtractOptions()
    options.range = "1"
    options.reviewedSource = try PDFSourceStamp.read(input)
    let replacement = fixture(width: 240)
    try replacement.write(to: input, options: .atomic)
    #expect(try PDFPageEditing.pageCount(input) == 1)
    do {
        try await PDFPageEditing.extract(input, to: output, options: options) { _ in }
        Issue.record("Extract Pages published unreviewed PDF content.")
    } catch {
        #expect(error.localizedDescription.contains("Refresh the page preview"))
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))

    options.reviewedSource = try PDFSourceStamp.read(input)
    try await PDFPageEditing.extract(input, to: output, options: options) { _ in }
    #expect(PDFDocument(url: output)?.page(at: 0)?.bounds(for: .mediaBox).width == 240)
    #expect(try Data(contentsOf: input) == replacement)
}
