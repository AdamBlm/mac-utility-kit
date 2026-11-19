import AppKit
import Foundation
import PDFKit
import Testing
import UtilityCore

@Test func thumbnailRangeSelectionPreservesExistingOrderAndExtendsWithoutDuplicates() {
    #expect(PageSelection.updating([], at: 4, extendingFrom: nil) == [4])
    #expect(PageSelection.updating([4, 2], at: 0, extendingFrom: 2) == [4, 2, 0, 1])
    #expect(PageSelection.updating([4, 2, 0, 1], at: 4, extendingFrom: 0) == [4, 2, 0, 1, 3])
    #expect(PageSelection.updating([4, 2, 0, 1], at: 0, extendingFrom: nil) == [4, 2, 1])
}

@Test func splitPDFSupportsSinglePagesFixedGroupsAndNamedOverlappingRanges() async throws {
    try await withPDFEditingFixture { source, directory in
        var options = PDFSplitOptions()
        #expect(try PDFPageEditing.splitGroups(pageCount: 5, options: options).map(\.pageNumbers) ==
                [[1], [2], [3], [4], [5]])
        options.mode = .everyN
        options.pagesPerFile = 2
        #expect(try PDFPageEditing.splitGroups(pageCount: 5, options: options).map(\.pageNumbers) ==
                [[1, 2], [3, 4], [5]])
        options.mode = .custom
        options.customRanges = "Overview: 3,1\n  \nAppendix: 1,4–5"
        options.filenamePattern = "{group}-{number}"
        let results = try await PDFPageEditing.split(source, into: directory, options: options) { _ in }

        #expect(results.map(\.lastPathComponent) == ["Overview-1.pdf", "Appendix-2.pdf"])
        #expect(try pdfPageNumbers(results[0]) == [3, 1])
        #expect(try pdfPageNumbers(results[1]) == [1, 4, 5])
        #expect(try pdfRotations(results[1]) == [0, 270, 0])
        #expect(try pdfPageNumbers(source) == [1, 2, 3, 4, 5])
    }
}

@Test func splitPDFRejectsInvalidRangesAndCollisionsBeforeWriting() async throws {
    try await withPDFEditingFixture { source, directory in
        var options = PDFSplitOptions()
        options.mode = .custom
        options.customRanges = "Out of bounds: 2-6"
        await #expect(throws: ToolError.self) {
            try await PDFPageEditing.split(source, into: directory, options: options) { _ in }
        }
        options.customRanges = "1-2\r\n  \r\nEmpty:"
        let error = await #expect(throws: ToolError.self) {
            try await PDFPageEditing.split(source, into: directory, options: options) { _ in }
        }
        #expect(error?.localizedDescription.hasPrefix("Line 3 needs") == true)
        options.customRanges = "1-2\n3-5"
        options.filenamePattern = "same-name"
        await #expect(throws: ToolError.self) {
            try await PDFPageEditing.split(source, into: directory, options: options) { _ in }
        }
        let groups = try PDFPageEditing.splitGroups(pageCount: 5, options: options)
        let maximumStem = String(repeating: "é", count: 83)
        #expect(try PDFPageEditing.splitFilenames(source, groups: Array(groups.prefix(1)), pattern: maximumStem)
                == [maximumStem + ".pdf"])
        options.filenamePattern = String(repeating: "a", count: 252)
        let longName = await #expect(throws: ToolError.self) {
            try await PDFPageEditing.split(source, into: directory, options: options) { _ in }
        }
        #expect(longName?.localizedDescription.contains("filename is too long") == true)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files == [source.lastPathComponent])
    }
}

@Test func organizePDFReordersAndRotatesWithoutChangingTheOriginal() async throws {
    try await withPDFEditingFixture { source, directory in
        let original = try Data(contentsOf: source)
        let output = directory.appendingPathComponent("Organized.pdf")
        var options = PDFOrganizeOptions()
        options.pages = [
            .init(pageNumber: 4, quarterTurns: -1),
            .init(pageNumber: 2, quarterTurns: 1),
            .init(pageNumber: 1, quarterTurns: 2)
        ]
        try await PDFPageEditing.organize(source, to: output, options: options) { _ in }

        #expect(try pdfPageNumbers(output) == [4, 2, 1])
        #expect(try pdfRotations(output) == [180, 180, 180])
        #expect(try Data(contentsOf: source) == original)
        let exported = try #require(PDFDocument(url: output))
        #expect(exported.page(at: 2)?.annotations.first?.contents == "Source annotation")
    }
}

@Test func deletePDFPagesExportsTheComplementOfAThumbnailRange() async throws {
    try await withPDFEditingFixture { source, directory in
        let marks = PageSelection.updating([], at: 3, extendingFrom: nil)
        let extended = PageSelection.updating(marks, at: 1, extendingFrom: 3)
        var options = PDFDeleteOptions()
        options.range = PageSelection.expression(for: extended.sorted())
        #expect(options.range == "2–4")
        let output = directory.appendingPathComponent("Reduced.pdf")
        try await PDFPageEditing.delete(source, to: output, options: options) { _ in }
        #expect(try pdfPageNumbers(output) == [1, 5])
        #expect(try pdfPageNumbers(source) == [1, 2, 3, 4, 5])
    }
}

@Test func deletePDFPagesPreservesOrderRotationAndExistingFiles() async throws {
    try await withPDFEditingFixture { source, directory in
        let original = try Data(contentsOf: source)
        let output = directory.appendingPathComponent("Remaining.pdf")
        var options = PDFDeleteOptions()
        options.range = "5,2-3"
        try await PDFPageEditing.delete(source, to: output, options: options) { _ in }

        #expect(try pdfPageNumbers(output) == [1, 4])
        #expect(try pdfRotations(output) == [0, 270])
        #expect(try Data(contentsOf: source) == original)
        let existing = try Data(contentsOf: output)
        await #expect(throws: ToolError.self) {
            try await PDFPageEditing.delete(source, to: output, options: options) { _ in }
        }
        #expect(try Data(contentsOf: output) == existing)
    }
}

@Test func pdfPageEditingRejectsEmptyDuplicateAndCorruptInputs() async throws {
    try await withPDFEditingFixture { source, directory in
        let output = directory.appendingPathComponent("Remaining.pdf")
        var deletion = PDFDeleteOptions()
        deletion.range = "all"
        await #expect(throws: ToolError.self) {
            try await PDFPageEditing.delete(source, to: output, options: deletion) { _ in }
        }
        var organization = PDFOrganizeOptions()
        organization.pages = []
        await #expect(throws: ToolError.self) {
            try await PDFPageEditing.organize(source, to: output, options: organization) { _ in }
        }
        organization.pages = [.init(pageNumber: 2), .init(pageNumber: 2)]
        await #expect(throws: ToolError.self) {
            try await PDFPageEditing.organize(source, to: output, options: organization) { _ in }
        }
        let broken = directory.appendingPathComponent("Broken.pdf")
        try Data("not a PDF".utf8).write(to: broken)
        #expect(throws: ToolError.self) { try PDFPageEditing.pageCount(broken) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}

@Test func splitPDFCancellationLeavesNoPublishedFiles() async throws {
    try await withPDFEditingFixture { source, directory in
        let task = Task {
            try await PDFPageEditing.split(source, into: directory, options: PDFSplitOptions()) { fraction in
                if fraction > 0 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files == [source.lastPathComponent])
    }
}

@Test func lockedPDFRequiresCorrectPassword() async throws {
    try await withPDFEditingFixture { source, directory in
        let document = try #require(PDFDocument(url: source))
        let locked = directory.appendingPathComponent("Protected.pdf")
        try #require(document.write(to: locked, withOptions: [
            .userPasswordOption: "guest",
            .ownerPasswordOption: "owner",
            .accessPermissionsOption: NSNumber(value: PDFAccessPermissions.allowsLowQualityPrinting.rawValue)
        ]))
        #expect(throws: ToolError.self) { try PDFPageEditing.pageCount(locked) }
        #expect(throws: ToolError.self) { try PDFPageEditing.pageCount(locked, password: "wrong") }
        #expect(throws: ToolError.self) { try PDFPageEditing.pageCount(locked, password: "guest") }
        #expect(try PDFPageEditing.pageCount(locked, password: "owner") == 5)
        let output = directory.appendingPathComponent("Edited.pdf")
        var options = PDFDeleteOptions()
        options.password = "owner"
        options.range = "1"
        try await PDFPageEditing.delete(locked, to: output, options: options) { _ in }
        #expect(try pdfPageNumbers(output) == [2, 3, 4, 5])
        let sourceDocument = try #require(PDFDocument(url: locked))
        #expect(sourceDocument.isLocked)
    }
}

private func withPDFEditingFixture(_ test: (URL, URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("Source.pdf")
    let document = PDFDocument()
    for (index, rotation) in [0, 90, 180, 270, 0].enumerated() {
        let size = CGSize(width: 100 + index + 1, height: 200)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let page = try #require(PDFPage(image: image))
        page.rotation = rotation
        if index == 0 {
            let annotation = PDFAnnotation(bounds: CGRect(x: 10, y: 20, width: 30, height: 20),
                                           forType: .text, withProperties: nil)
            annotation.contents = "Source annotation"
            page.addAnnotation(annotation)
        }
        document.insert(page, at: index)
    }
    try #require(document.write(to: source))
    try await test(source, directory)
}

private func pdfPageNumbers(_ url: URL) throws -> [Int] {
    let document = try #require(PDFDocument(url: url))
    return try (0..<document.pageCount).map { index in
        let page = try #require(document.page(at: index))
        let bounds = page.bounds(for: .mediaBox)
        return Int(min(bounds.width, bounds.height)) - 100
    }
}

private func pdfRotations(_ url: URL) throws -> [Int] {
    let document = try #require(PDFDocument(url: url))
    return try (0..<document.pageCount).map { index in
        try #require(document.page(at: index)).rotation
    }
}
