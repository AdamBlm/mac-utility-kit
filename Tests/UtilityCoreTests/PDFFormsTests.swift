import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
import UtilityCore

@MainActor
struct PDFFormsTests {
    @Test func refusesRedirectedAndNewlyOccupiedSaveDestinations() throws {
        let (source, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: source)
        let manager = FileManager.default
        let output = directory.appending(path: "Output")
        try manager.createDirectory(at: output, withIntermediateDirectories: false)
        let redirected = output.appending(path: source.lastPathComponent)
        let accepted = try PDFFormDestination(redirected, preserving: source)
        try manager.moveItem(at: output, to: directory.appending(path: "Moved"))
        try manager.createSymbolicLink(at: output, withDestinationURL: directory)
        #expect(throws: (any Error).self) { try accepted.publish(Data("replacement".utf8)) }
        #expect(try Data(contentsOf: source) == original)

        let occupied = directory.appending(path: "New export.pdf")
        let pending = try PDFFormDestination(occupied, preserving: source)
        try Data("existing".utf8).write(to: occupied)
        #expect(throws: ToolError.self) { try pending.publish(original) }
        #expect(try Data(contentsOf: occupied) == Data("existing".utf8))

        let confirmed = try PDFFormDestination(occupied, preserving: source)
        try confirmed.publish(original)
        #expect(try Data(contentsOf: occupied) == original)
    }

    @Test func placesEditsAndRemovesFieldsWithoutChangingSource() throws {
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let subject = try PDFForms(source: url)
        #expect(subject.fields(on: 0).isEmpty)
        let bounds = CGRect(x: 20, y: 40, width: 120, height: 26)
        let id = try subject.add(.text, on: 0, bounds: bounds, name: "Name")
        let note = try subject.add(.freeText, on: 0, bounds: bounds.offsetBy(dx: 0, dy: 32), name: "Notes")
        try subject.update(id, name: "Customer", value: "Mélanie", checked: false, bounds: bounds)
        #expect(subject.fields(on: 0).first?.value == "Mélanie")
        #expect(throws: ToolError.self) { try subject.add(.text, on: 0, bounds: bounds, name: "Customer") }
        #expect(throws: ToolError.self) { try subject.add(.checkbox, on: 0, bounds: bounds.offsetBy(dx: 300, dy: 0), name: "Outside") }
        try subject.remove(note)
        #expect(subject.fields(on: 0).count == 1)
        #expect(PDFDocument(url: url)?.page(at: 0)?.annotations.isEmpty == true)
    }

    @Test(arguments: [0, 90, 180, 270])
    func detectsPrintedBoxesWithoutAddingFields(rotation: Int) throws {
        let (url, directory) = try fixture(withBoxes: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input: URL
        if rotation != 0 {
            let source = try #require(PDFDocument(url: url))
            let page = try #require(source.page(at: 0))
            page.rotation = rotation
            input = directory.appending(path: "Rotated.pdf")
            try #require(source.write(to: input))
        } else {
            input = url
        }
        #expect(PDFDocument(url: input)?.page(at: 0)?.rotation == rotation)
        let subject = try PDFForms(source: input)
        let candidates = try subject.candidates(on: 0)
        let checkbox = try #require(candidates.first { $0.kind == .checkbox && abs($0.bounds.midX - 42) < 5 && abs($0.bounds.midY - 117) < 5 })
        let text = try #require(candidates.first { $0.kind == .text && abs($0.bounds.midX - 144) < 5 && abs($0.bounds.midY - 117) < 5 })
        #expect(subject.fields(on: 0).isEmpty)
        _ = try subject.add(checkbox.kind, on: 0, bounds: checkbox.bounds, name: "Consent")
        _ = try subject.add(text.kind, on: 0, bounds: text.bounds, name: "Name")
        #expect(Set(subject.fields(on: 0).map(\.name)) == ["Consent", "Name"])
        #expect(PDFDocument(url: input)?.page(at: 0)?.annotations.isEmpty == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FORMS_PYTHON"] != nil))
    func editableAndFlattenedCopiesRoundTripWithVisibleValues() async throws {
        let environment = ProcessInfo.processInfo.environment
        let python = URL(fileURLWithPath: try #require(environment["MAC_UTILITY_FORMS_PYTHON"]))
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        let subject = try PDFForms(source: url)
        let textBounds = CGRect(x: 30, y: 155, width: 145, height: 28)
        let boxBounds = CGRect(x: 30, y: 112, width: 20, height: 20)
        let offBounds = boxBounds.offsetBy(dx: 45, dy: 0)
        let textID = try subject.add(.text, on: 0, bounds: textBounds, name: "Applicant")
        let boxID = try subject.add(.checkbox, on: 0, bounds: boxBounds, name: "Accepted")
        _ = try subject.add(.checkbox, on: 0, bounds: offBounds, name: "Declined")
        let noteBounds = CGRect(x: 30, y: 65, width: 155, height: 28)
        let noteID = try subject.add(.freeText, on: 0, bounds: noteBounds, name: "Note")
        try subject.update(textID, name: "Applicant", value: "Mélanie", checked: false, bounds: textBounds)
        try subject.update(boxID, name: "Accepted", value: "", checked: true, bounds: boxBounds)
        try subject.update(noteID, name: "Note", value: "Reviewed", checked: false, bounds: noteBounds)

        let editable = try await subject.export(.editable, python: python)
        let editableDocument = try #require(PDFDocument(data: editable))
        let page = try #require(editableDocument.page(at: 0))
        #expect(page.annotations.first { $0.fieldName == "Applicant" }?.widgetStringValue == "Mélanie")
        #expect(page.annotations.first { $0.fieldName == "Accepted" }?.buttonWidgetState == .onState)
        #expect(page.annotations.first { $0.fieldName == "Declined" }?.buttonWidgetState == .offState)
        #expect(page.annotations.first { $0.type == "FreeText" }?.contents == "Reviewed")

        let flattened = try await subject.export(.flattened, python: python)
        let flattenedDocument = try #require(PDFDocument(data: flattened))
        let flattenedPage = try #require(flattenedDocument.page(at: 0))
        #expect(flattenedPage.annotations.isEmpty)
        #expect(flattenedPage.string?.contains("Mélanie") == true)
        #expect(flattenedPage.string?.contains("Reviewed") == true)
        #expect(subject.fields(on: 0).count == 4)

        let existingURL = directory.appendingPathComponent("existing.pdf")
        try editable.write(to: existingURL)
        let existing = try PDFForms(source: existingURL)
        let existingField = try #require(existing.fields(on: 0).first { $0.name == "Applicant" })
        try existing.update(existingField.id, name: existingField.name, value: "Lucie", checked: false, bounds: existingField.bounds)
        let revised = try await existing.export(.editable, python: python)
        #expect(PDFDocument(data: revised)?.page(at: 0)?.annotations.first {
            $0.fieldName == "Applicant"
        }?.widgetStringValue == "Lucie")

        if let outputPath = environment["MAC_UTILITY_FORMS_FIXTURE_DIR"] {
            let output = URL(fileURLWithPath: outputPath, isDirectory: true)
            try editable.write(to: output.appendingPathComponent("editable.pdf"))
            try flattened.write(to: output.appendingPathComponent("flattened.pdf"))
        }
    }

    private func fixture(withBoxes: Bool = false) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("source.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 260, height: 240)
        let context = try #require(CGContext(url as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 30, y: 204)
        let title = NSAttributedString(string: "Application Review", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        ])
        CTLineDraw(CTLineCreateWithAttributedString(title), context)
        if withBoxes {
            context.setStrokeColor(gray: 0, alpha: 1)
            context.setLineWidth(2)
            context.stroke(CGRect(x: 30, y: 105, width: 24, height: 24))
            context.stroke(CGRect(x: 96, y: 105, width: 96, height: 24))
        }
        context.endPDFPage()
        context.closePDF()
        return (url, directory)
    }
}
