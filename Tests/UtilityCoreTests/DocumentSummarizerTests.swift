import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import UtilityCore

struct DocumentSummarizerTests {
    private struct RecordingProvider: DocumentSummarizer.Provider {
        let record: Calls

        func summarize(_ text: String, instruction: String, tokenLimit: Int) async throws -> String {
            await record.append(text: text, instruction: instruction)
            let facts = ["Neptune", "17 October", "62 crates"].filter { text.contains($0) }
            return facts.isEmpty ? "Other context" : facts.joined(separator: " · ")
        }
    }

    private actor Calls {
        var instructions: [String] = []
        var input: [String] = []
        func append(text: String, instruction: String) {
            instructions.append(instruction)
            input.append(text)
        }
    }

    @Test func chunksLongInputAndCarriesFactsThroughCombination() async throws {
        let filler = String(repeating: "Ordinary background details. ", count: 120)
        let source = "Neptune shipment.\n" + filler + "17 October.\n" + filler + "62 crates."
        let request = DocumentSummarizer.Request(source: .text(source), length: .detailed, format: .bullets)
        let calls = Calls()
        let result = try await DocumentSummarizer.summarize(request, using: RecordingProvider(record: calls))
        #expect(result.summary == "Neptune · 17 October · 62 crates")
        #expect(result.omittedPages.isEmpty)
        let instructions = await calls.instructions
        #expect(instructions.count > 2)
        #expect(instructions.last?.contains("six bullets") == true)
    }

    @Test func summarizesOnlySelectedPDFPages() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var bounds = CGRect(x: 0, y: 0, width: 240, height: 100)
        let context = try #require(CGContext(url as CFURL, mediaBox: &bounds, nil))
        for content in ["Ignored first page", "Neptune shipment: 62 crates due 17 October", ""] {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 20, y: 35)
            let text = NSAttributedString(string: content, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 10, nil)
            ])
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
        let request = DocumentSummarizer.Request(source: .document(url, pages: "2", password: ""), length: .brief, format: .paragraph)
        let calls = Calls()
        let result = try await DocumentSummarizer.summarize(request, using: RecordingProvider(record: calls))
        #expect(result.summary == "Neptune · 17 October · 62 crates")
        #expect(result.omittedPages.isEmpty)
        #expect(await calls.instructions.count == 1)
        #expect(await calls.input == ["Neptune shipment: 62 crates due 17 October"])

        let includesBlank = DocumentSummarizer.Request(source: .document(url, pages: "2,3", password: ""),
                                                        length: .brief, format: .paragraph)
        let partial = try await DocumentSummarizer.summarize(includesBlank, using: RecordingProvider(record: Calls()))
        #expect(partial.summary == result.summary)
        #expect(partial.omittedPages == [3])
    }

    @Test func validatesSelectedPageCountBeforeSummarizing() throws {
        try DocumentSummarizer.validatePDFSelection("1–40", pageCount: 41)
        for range in ["all", "none", "42"] {
            #expect(throws: ToolError.self) {
                try DocumentSummarizer.validatePDFSelection(range, pageCount: 41)
            }
        }
    }

    @Test func canSummarizeNativeAndScannedFactsOnTheSamePage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmap = try #require(CGContext(data: nil, width: 1200, height: 240, bitsPerComponent: 8,
                                           bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        func draw(_ value: String, size: CGFloat, at point: CGPoint, on canvas: CGContext) {
            canvas.textPosition = point
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil)
            ]))
            CTLineDraw(line, canvas)
        }
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: 1200, height: 240))
        bitmap.setFillColor(gray: 0, alpha: 1)
        draw("62 crates due 17 October", size: 56, at: CGPoint(x: 50, y: 105), on: bitmap)
        let image = try #require(bitmap.makeImage())
        var media = CGRect(x: 0, y: 0, width: 600, height: 300)
        let pdf = try #require(CGContext(url as CFURL, mediaBox: &media, nil))
        pdf.beginPDFPage(nil)
        draw("Neptune shipment", size: 28, at: CGPoint(x: 25, y: 230), on: pdf)
        pdf.draw(image, in: CGRect(x: 0, y: 40, width: 600, height: 120))
        pdf.endPDFPage()
        pdf.closePDF()

        let source = DocumentSummarizer.Source.document(url, pages: "1", password: "")
        let regular = DocumentSummarizer.Request(source: source, length: .brief, format: .paragraph)
        let scanned = DocumentSummarizer.Request(source: source, length: .brief, format: .paragraph,
                                                 recognizesMixedPDFPages: true)
        let calls = Calls()
        let provider = RecordingProvider(record: calls)
        #expect(try await DocumentSummarizer.summarize(regular, using: provider).summary == "Neptune")
        let combined = try await DocumentSummarizer.summarize(scanned, using: provider)
        #expect(combined.summary == "Neptune · 17 October · 62 crates")
        #expect(combined.omittedPages.isEmpty)
        #expect(await calls.input.last?.components(separatedBy: "Neptune").count == 2)
    }

    @Test func oversizedSourcesFailBeforeCallingProvider() async throws {
        let request = DocumentSummarizer.Request(source: .text(String(repeating: "a", count: 50_000)),
                                                 length: .brief, format: .paragraph)
        let calls = Calls()
        await #expect(throws: ToolError.self) {
            try await DocumentSummarizer.summarize(request, using: RecordingProvider(record: calls))
        }
        #expect(await calls.instructions.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_SUMMARY_TEST"] == "1"))
    func nativeProviderPreservesFixtureFacts() async throws {
        #expect(AppleSystemSummarizer.availability.isAvailable)
        let fixture = """
            The Neptune shipment arrives on 17 October. It contains 62 crates of replacement parts.
            The team approved storing the crates at the west warehouse. Delivery staff will record
            the final inventory immediately after arrival.
            """
        let request = DocumentSummarizer.Request(source: .text(fixture), length: .detailed, format: .bullets)
        let result = try await DocumentSummarizer.summarize(request)
        #expect(result.summary.contains("Neptune"))
        #expect(result.summary.contains("62"))
        #expect(result.summary.contains("17"))
        #expect(result.summary.contains("west warehouse"))
    }
}
