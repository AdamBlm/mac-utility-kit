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

    @Test(arguments: [0, 90, 180, 270], [false, true])
    func detectsPrintedBoxesWithoutAddingFields(rotation: Int, cropped: Bool) throws {
        let (url, directory) = try fixture(withBoxes: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input: URL
        let crop = CGRect(x: 19, y: 56, width: 190, height: 110)
        if rotation != 0 || cropped {
            let source = try #require(PDFDocument(url: url))
            let page = try #require(source.page(at: 0))
            page.rotation = rotation
            if cropped { page.setBounds(crop, for: .cropBox) }
            input = directory.appending(path: "Modified.pdf")
            try #require(source.write(to: input))
        } else {
            input = url
        }
        let reopened = try #require(PDFDocument(url: input))
        let page = try #require(reopened.page(at: 0))
        #expect(page.rotation == rotation)
        if cropped { #expect(page.bounds(for: .cropBox) == crop) }
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

    @Test(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_FORMS_PYTHON"] != nil), arguments: [0, 90])
    func editableAndFlattenedCopiesRoundTripWithVisibleValues(rotation: Int) async throws {
        let environment = ProcessInfo.processInfo.environment
        let python = URL(fileURLWithPath: try #require(environment["MAC_UTILITY_FORMS_PYTHON"]))
        let (url, directory) = try fixture(withBoxes: rotation != 0)
        defer { try? FileManager.default.removeItem(at: directory) }

        let input: URL
        if rotation == 0 {
            input = url
        } else {
            let document = try #require(PDFDocument(url: url))
            let page = try #require(document.page(at: 0))
            page.rotation = rotation
            input = directory.appending(path: "Rotated.pdf")
            try #require(document.write(to: input))
        }
        let subject = try PDFForms(source: input)
        let textBounds: CGRect
        let boxBounds: CGRect
        if rotation == 0 {
            textBounds = CGRect(x: 30, y: 155, width: 145, height: 28)
            boxBounds = CGRect(x: 30, y: 112, width: 20, height: 20)
        } else {
            let detected = try subject.candidates(on: 0)
            textBounds = try #require(detected.first { $0.kind == .text && abs($0.bounds.midX - 144) < 5 }).bounds
            boxBounds = try #require(detected.first { $0.kind == .checkbox && abs($0.bounds.midX - 42) < 5 }).bounds
        }
        let offBounds = boxBounds.offsetBy(dx: 33, dy: 0)
        let textID = try subject.add(.text, on: 0, bounds: textBounds, name: "Applicant")
        let boxID = try subject.add(.checkbox, on: 0, bounds: boxBounds, name: "Accepted")
        _ = try subject.add(.checkbox, on: 0, bounds: offBounds, name: "Declined")
        let noteBounds = try #require(subject.placementBounds(for: .freeText, on: 0, near: CGPoint(x: 218, y: 72)))
        let noteID = try subject.add(.freeText, on: 0, bounds: noteBounds, name: "Note")
        try subject.update(textID, name: "Applicant", value: "Mélanie", checked: false, bounds: textBounds)
        try subject.update(boxID, name: "Accepted", value: "", checked: true, bounds: boxBounds)
        try subject.update(noteID, name: "Note", value: "Reviewed", checked: false, bounds: noteBounds)

        let editable = try await subject.export(.editable, python: python)
        let editableDocument = try #require(PDFDocument(data: editable))
        let page = try #require(editableDocument.page(at: 0))
        #expect(page.rotation == rotation)
        let savedBounds = try #require(page.annotations.first { $0.fieldName == "Applicant" }).bounds
        #expect(abs(savedBounds.minX - textBounds.minX) < 0.02 && abs(savedBounds.minY - textBounds.minY) < 0.02)
        #expect(abs(savedBounds.width - textBounds.width) < 0.02 && abs(savedBounds.height - textBounds.height) < 0.02)
        #expect(page.annotations.first { $0.fieldName == "Applicant" }?.widgetStringValue == "Mélanie")
        #expect(page.annotations.first { $0.fieldName == "Accepted" }?.buttonWidgetState == .onState)
        #expect(page.annotations.first { $0.fieldName == "Declined" }?.buttonWidgetState == .offState)
        #expect(page.annotations.first { $0.type == "FreeText" }?.contents == "Reviewed")
        try verifyFreeTextAppearance(on: page)

        let flattened = try await subject.export(.flattened, python: python)
        let flattenedDocument = try #require(PDFDocument(data: flattened))
        let flattenedPage = try #require(flattenedDocument.page(at: 0))
        #expect(flattenedPage.rotation == rotation)
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
            let suffix = rotation == 0 ? "" : "-rotated"
            try editable.write(to: output.appendingPathComponent("editable\(suffix).pdf"))
            try flattened.write(to: output.appendingPathComponent("flattened\(suffix).pdf"))
        }
    }

    private func verifyFreeTextAppearance(on page: PDFPage) throws {
        let dictionary = try #require(page.pageRef?.dictionary)
        var annotations: CGPDFArrayRef?
        try #require(CGPDFDictionaryGetArray(dictionary, "Annots", &annotations))
        let array = try #require(annotations)
        for index in 0..<CGPDFArrayGetCount(array) {
            var annotation: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(array, index, &annotation), let annotation else { continue }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(annotation, "Subtype", &subtype),
                  let subtype, String(cString: subtype) == "FreeText" else { continue }
            var instructions: CGPDFStringRef?
            try #require(CGPDFDictionaryGetString(annotation, "DA", &instructions))
            let appearanceInstructions = try #require(instructions)
            #expect(CGPDFStringGetLength(appearanceInstructions) > 0)
            var appearances: CGPDFDictionaryRef?
            try #require(CGPDFDictionaryGetDictionary(annotation, "AP", &appearances))
            let appearanceDictionary = try #require(appearances)
            var normal: CGPDFStreamRef?
            try #require(CGPDFDictionaryGetStream(appearanceDictionary, "N", &normal))
            let stream = try #require(normal)
            var format = CGPDFDataFormat.raw
            #expect((CGPDFStreamCopyData(stream, &format) as Data?)?.isEmpty == false)
            return
        }
        Issue.record("Missing free-text annotation in the saved PDF.")
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
