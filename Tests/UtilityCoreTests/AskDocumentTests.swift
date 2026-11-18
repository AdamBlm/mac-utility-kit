import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import UtilityCore

struct AskDocumentTests {
    @Test func findsExactEvidenceAndRejectsInvalidOrOutsideSourceAnswers() async throws {
        let (folder, source) = try makeSource("handbook.md")
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("""
            # Overview
            We write reports on Wednesdays.

            # Periwinkle Project
            The annual budget for Periwinkle is 42,000 dollars.
            It was renewed on September 8.
            """.utf8).write(to: source)
        let index = try await AskDocument.index(source)
        let question = "What is the annual budget for Periwinkle?"
        let expected = "The annual budget for Periwinkle is 42,000 dollars."
        let answer = try await AskDocument.answer(question, in: index, using: ExactProvider(expected))
        #expect(answer.citations.first?.quote == expected)
        #expect(answer.citations.first?.location == .section(line: 4, title: "Periwinkle Project"))
        let followup = try await AskDocument.answer("When was it renewed?", in: index,
                                                     history: [.init(question: question, answer: answer)],
                                                     using: ExactProvider("It was renewed on September 8.", previous: question))
        #expect(followup.hasEvidence)
        let fabricated = try await AskDocument.answer(question, in: index, using: WrongProvider(unknownPassage: false))
        #expect(!fabricated.hasEvidence)
        let wrongPassage = try await AskDocument.answer(question, in: index, using: WrongProvider(unknownPassage: true))
        #expect(!wrongPassage.hasEvidence)
        let outside = try await AskDocument.answer("How far away is Saturn?", in: index, using: NeverProvider())
        #expect(!outside.hasEvidence)

        try Data("Replaced source".utf8).write(to: source, options: .atomic)
        #expect(throws: ToolError.self) { try index.validateSource() }
        await #expect(throws: ToolError.self) {
            _ = try await AskDocument.answer(question, in: index, using: NeverProvider())
        }
    }

    @Test func followsCitedTopicAfterNoEvidenceAndIgnoresUnrelatedNewTopics() async throws {
        let (folder, source) = try makeSource("projects.md")
        defer { try? FileManager.default.removeItem(at: folder) }
        let decoys = (1...6).map { "# Project \($0)\nThe limit is 6 permits." }.joined(separator: "\n")
        let sourceText = """
            # Northstar
            Northstar produces antenna hardware.
            It was renewed on August 2.
            Its permit ceiling is 47.
            \(decoys)
            """
        try Data(sourceText.utf8).write(to: source)
        let index = try await AskDocument.index(source)
        let topic = "What does Northstar produce?"
        let first = try await AskDocument.answer(topic, in: index,
                                                  using: ExactProvider("Northstar produces antenna hardware."))
        let firstTurn = AskDocument.Turn(question: topic, answer: first)
        let continuation = "When was it renewed?"
        let second = try await AskDocument.answer(continuation, in: index, history: [firstTurn],
                                                   using: ExactProvider("It was renewed on August 2.", previous: topic))
        let secondTurn = AskDocument.Turn(question: continuation, answer: second)
        let unresolved = "Who is its attorney?"
        let third = try await AskDocument.answer(unresolved, in: index, history: [firstTurn, secondTurn],
                                                  using: EmptyProvider())
        #expect(!third.hasEvidence)
        let history = [firstTurn, secondTurn, .init(question: unresolved, answer: third)]
        let fourth = try await AskDocument.answer("What about its limit?", in: index, history: history,
                                                   using: ExactProvider("Its permit ceiling is 47.", previous: continuation))
        #expect(fourth.citations.first?.location == .section(line: 1, title: "Northstar"))

        let unrelated = try await AskDocument.answer("How many moons orbit Saturn?", in: index, history: history,
                                                       using: NeverProvider())
        #expect(!unrelated.hasEvidence)
        let afterNewTopic = try await AskDocument.answer("When was it promoted?", in: index,
            history: history + [.init(question: "How many moons orbit Saturn?", answer: unrelated)],
            using: NeverProvider())
        #expect(!afterNewTopic.hasEvidence)
    }

    @Test func explicitlyNamedTopicOverridesConversationalPhrasing() async throws {
        let (folder, source) = try makeSource("topics.md")
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("""
            # Northstar
            Northstar permits 47 launches.

            # Larkspur
            Larkspur permits 18 launches.
            It renews in April.
            """.utf8).write(to: source)
        let index = try await AskDocument.index(source)
        let question = "What are Northstar’s permits?"
        let first = try await AskDocument.answer(question, in: index,
                                                 using: ExactProvider("Northstar permits 47 launches."))
        let history = [AskDocument.Turn(question: question, answer: first)]
        let namedQuestion = "What about its permits for larkspur?"
        let named = try await AskDocument.answer(namedQuestion, in: index, history: history,
                                                 using: ExactProvider("Larkspur permits 18 launches."))
        #expect(named.citations.first?.location == .section(line: 4, title: "Larkspur"))
        let following = try await AskDocument.answer("And when does it renew?", in: index,
            history: history + [.init(question: namedQuestion, answer: named)],
            using: ExactProvider("It renews in April.", previous: namedQuestion))
        #expect(following.citations.first?.location == .section(line: 4, title: "Larkspur"))

        let unavailable = try await AskDocument.answer("What about Unlisted?", in: index,
                                                        history: history, using: NeverProvider())
        #expect(!unavailable.hasEvidence)

        let plain = folder.appending(path: "plain.txt")
        try Data("Northstar permits 47 launches. Eastwind was renewed in April and cost 18 dollars.".utf8).write(to: plain)
        let plainIndex = try await AskDocument.index(plain)
        let plainFirst = try await AskDocument.answer(question, in: plainIndex,
            using: ExactProvider("Northstar permits 47 launches."))
        let compound = try await AskDocument.answer("When was Eastwind renewed, and what did it cost?", in: plainIndex,
            history: [.init(question: question, answer: plainFirst)],
            using: ExactProvider("Eastwind was renewed in April and cost 18 dollars."))
        #expect(compound.hasEvidence)
    }

    @Test func explicitQuestionModeControlsAmbiguousPlainTextTurns() async throws {
        let (folder, source) = try makeSource("topics.txt")
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("""
            Northstar has annual permits for 47 launches and a separate training limit.
            Eastwind’s budget is 18 dollars. Eastwind permits 12 launches. It renews in April.
            """.utf8).write(to: source)
        let index = try await AskDocument.index(source)
        let original = "What does Northstar have?"
        let first = try await AskDocument.answer(original, in: index,
                                                 using: ExactProvider("Northstar has annual permits for 47 launches"))
        let history = [AskDocument.Turn(question: original, answer: first)]

        for (question, quote) in [("What about eastwind’s budget?", "Eastwind’s budget is 18 dollars."),
                                  ("What about its permits for Eastwind?", "Eastwind permits 12 launches.")] {
            let answer = try await AskDocument.answer(question, in: index, history: history, mode: .newTopic,
                                                       using: ExactProvider(quote))
            #expect(answer.hasEvidence)
            let following = try await AskDocument.answer("Renewal date in April?", in: index,
                history: history + [.init(question: question, answer: answer)], mode: .followUp,
                using: ExactProvider("It renews in April.", previous: question))
            #expect(following.hasEvidence)
        }
    }

    @Test func scopesAllHistoryToExactIndexAndOriginalQuestion() async throws {
        let (folder, source) = try makeSource("source.md")
        defer { try? FileManager.default.removeItem(at: folder) }
        let other = folder.appending(path: "other.md")
        let passage = "# Project\nThe project will renew in April."
        try Data(passage.utf8).write(to: source)
        try Data(passage.utf8).write(to: other)
        let foreign = try await AskDocument.index(source)
        let current = try await AskDocument.index(other)
        let prior = "What project will renew? Unshared"
        let answer = try await AskDocument.answer(prior, in: foreign,
                                                  using: ExactProvider("The project will renew in April."))
        let previous = AskDocument.Turn(question: prior, answer: answer)
        let unanswered = "Who is its attorney?"
        let empty = try await AskDocument.answer(unanswered, in: foreign, using: NeverProvider())
        #expect(!empty.hasEvidence)
        for history in [[previous], [previous, .init(question: unanswered, answer: empty)]] {
            let result = try await AskDocument.answer("When does it renew?", in: current, history: history,
                using: ExactProvider("The project will renew in April."))
            #expect(result.hasEvidence)
        }

        let forged = AskDocument.Turn(question: "What is its confidential code?", answer: answer)
        let result = try await AskDocument.answer("When does it renew?", in: foreign, history: [forged],
            using: ExactProvider("The project will renew in April."))
        #expect(result.hasEvidence)
    }

    private struct EmptyProvider: AskDocument.Provider {
        func choose(_ question: String, context: [AskDocument.Turn], passages: [AskDocument.Passage]) async throws -> [AskDocument.Evidence] {
            #expect(context.count == 2)
            return []
        }
    }

    @Test func citesActualPageNumberForCroppedRotatedScanAndReportsBlankPage() async throws {
        let (folder, source) = try makeSource("scan.pdf")
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeScan(source)
        let scan = try #require(PDFDocument(url: source))
        let page = try #require(scan.page(at: 1))
        #expect(page.rotation == 90)
        #expect(page.string?.isEmpty != false)
        let index = try await AskDocument.index(source)
        #expect(index.omittedPages == [1])
        let answer = try await AskDocument.answer("What is the permit code for Harbour?", in: index,
                                                  using: ExactProvider("Harbour permit code 7429"))
        #expect(answer.citations.first?.location == .page(2))
        #expect(answer.citations.first?.quote == "Harbour permit code 7429")
    }

    @Test func optionalAppleModelFindsEvidenceAndAbstainsForAnUnreportedProperty() async throws {
        guard ProcessInfo.processInfo.environment["MAC_UTILITY_ASK_LIVE_MODEL"] == "1" else { return }
        try #require(AppleDocumentAnswerModel.isAvailable)
        let (folder, source) = try makeSource("project.txt")
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("The Harbour project has 7429 permits available in July. Project staff review permits every Friday.".utf8).write(to: source)
        let index = try await AskDocument.index(source)
        let answered = try await AskDocument.answer("How many permits are available for the Harbour project?", in: index)
        #expect(answered.citations.first?.quote.contains("7429") == true)
        let unavailable = try await AskDocument.answer("What is the budget of the Harbour project?", in: index)
        #expect(!unavailable.hasEvidence)
    }

    private struct ExactProvider: AskDocument.Provider {
        let exact: String
        let previous: String?
        init(_ text: String, previous: String? = nil) {
            exact = text
            self.previous = previous
        }

        func choose(_ question: String, context: [AskDocument.Turn], passages: [AskDocument.Passage]) async throws -> [AskDocument.Evidence] {
            #expect(context.last?.question == previous)
            let match = try #require(passages.first { $0.text.contains(exact) })
            return [.init(passage: match.id, quote: exact)]
        }
    }

    private struct WrongProvider: AskDocument.Provider {
        let unknownPassage: Bool
        func choose(_ question: String, context: [AskDocument.Turn], passages: [AskDocument.Passage]) async throws -> [AskDocument.Evidence] {
            let match = try #require(passages.first)
            return [.init(passage: unknownPassage ? 999_999 : match.id,
                          quote: unknownPassage ? match.text : "The annual budget is 89,000 dollars.")]
        }
    }

    private struct NeverProvider: AskDocument.Provider {
        func choose(_ question: String, context: [AskDocument.Turn], passages: [AskDocument.Passage]) async throws -> [AskDocument.Evidence] {
            Issue.record("The model should not receive an ungrounded or changed-source question.")
            return []
        }
    }

    private func makeSource(_ name: String) throws -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return (folder, folder.appending(path: name))
    }

    private func makeScan(_ url: URL) throws {
        let template = try #require(PDFDocument(data: pdf { _ in }))
        let direction = try #require(template.page(at: 0))
        direction.rotation = 90
        let data = try #require(template.dataRepresentation())
        let provider = try #require(CGDataProvider(data: data as CFData))
        let ref = try #require(CGPDFDocument(provider)?.page(at: 1))
        let crop = ref.getBoxRect(.cropBox)
        let canvas = CGRect(origin: .zero, size: CGSize(width: crop.height, height: crop.width))
        let transform = ref.getDrawingTransform(.cropBox, rect: canvas, rotate: 0, preserveAspectRatio: true)
        let imageContext = try #require(CGContext(data: nil, width: Int(canvas.width) * 3, height: Int(canvas.height) * 3,
                                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        imageContext.scaleBy(x: 3, y: 3)
        imageContext.setFillColor(CGColor(gray: 1, alpha: 1))
        imageContext.fill(canvas)
        let text = "Harbour permit code 7429"
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 23, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ]))
        imageContext.textPosition = CGPoint(x: 20, y: 180)
        CTLineDraw(line, imageContext)
        let image = try #require(imageContext.makeImage())

        let imageDocument = try #require(PDFDocument(data: pdf { ctx in
            ctx.concatenate(transform.inverted())
            ctx.draw(image, in: canvas)
        }))
        let rotated = try #require(imageDocument.page(at: 0))
        rotated.rotation = 90
        let document = PDFDocument()
        let empty = try #require(PDFDocument(data: pdf { _ in }))
        document.insert(try #require(empty.page(at: 0)), at: 0)
        document.insert(rotated, at: 1)
        #expect(document.write(to: url))
    }

    private func pdf(_ draw: (CGContext) -> Void) throws -> Data {
        let bytes = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: bytes as CFMutableData))
        var media = CGRect(x: 0, y: 0, width: 440, height: 360)
        let crop = CGRect(x: 20, y: 10, width: 400, height: 340)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage([kCGPDFContextCropBox: withUnsafeBytes(of: crop) { Data($0) }] as CFDictionary)
        draw(context)
        context.endPDFPage()
        context.closePDF()
        return bytes as Data
    }
}
