import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
import UtilityCore
@testable import MacUtilityKit

@MainActor
struct PDFReaderSessionTests {
    @Test func selectsSameNamedFilesAndKeepsCurrentDocumentOnFailure() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (first, second, corrupt) = try fixtures(in: folder)

        let reader = PDFReaderSession()
        try #require(reader.openFirst(in: [corrupt, first, second, first]))
        #expect(reader.queuedFiles == [corrupt, first, second])
        #expect(reader.source == first)
        #expect(reader.document?.pageCount == 2)

        reader.selectQueuedFile(second)
        #expect(reader.source == second)
        #expect(reader.document?.pageCount == 4)

        let current = try #require(reader.document)
        reader.selectQueuedFile(corrupt)
        #expect(reader.source == second)
        #expect(reader.document === current)
        #expect(reader.error != nil)
        #expect(!reader.openFirst(in: [corrupt]))
        #expect(reader.queuedFiles == [corrupt, first, second])
        #expect(reader.document === current)

        reader.selectQueuedFile(first)
        #expect(reader.source == first)
        #expect(reader.error == nil)
    }

    @Test func acceptsAnOrderedClipboardBatchWithACorruptPDF() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (first, second, corrupt) = try fixtures(in: folder)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try #require(board.writeObjects([corrupt, second, first].map { $0 as NSURL }))

        let reader = PDFReaderSession()
        let files = ClipboardFiles.read(from: board, allowedTypes: [.pdf])
        try #require(reader.openFirst(in: files))
        #expect(reader.queuedFiles == [corrupt, second, first])
        #expect(reader.source == second)
        reader.selectQueuedFile(first)
        #expect(reader.document?.pageCount == 2)
    }

    @Test func mixedPasteDeliversRawPDFAndFileURLAsOneOrderedBatch() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (first, second, _) = try fixtures(in: folder)
        let raw = NSPasteboardItem()
        try #require(raw.setData(Data(contentsOf: second), forType: .pdf))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try #require(board.writeObjects([raw, first as NSURL]))
        let workspace = try WorkspacePDFDirectory()
        let reader = PDFReaderSession()
        var deliveries = 0
        let button = ClipboardFileButton(allowedTypes: [.pdf], stagePDF: workspace.stageClipboardPDF) { urls in
            deliveries += 1
            _ = reader.openFirst(in: urls)
        }
        #expect(button.paste(from: board))
        #expect(deliveries == 1)
        #expect(reader.queuedFiles.map(\.lastPathComponent) == ["Clipboard PDF 1.pdf", first.lastPathComponent])
        #expect(reader.document?.pageCount == 4)
        reader.selectQueuedFile(first)
        #expect(reader.document?.pageCount == 2)
    }

    @Test func scanPasteDeliversImageAndPDFRepresentationsInOneBatch() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (first, second, _) = try fixtures(in: folder)
        let pdf = NSPasteboardItem()
        try #require(pdf.setData(Data(contentsOf: second), forType: .pdf))
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let image = NSPasteboardItem()
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try #require(image.setData(png, forType: .png))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try #require(board.writeObjects([image, first as NSURL, pdf]))
        let workspace = try WorkspacePDFDirectory()
        var attachment: CaptureTextAttachment?
        var batches: [[URL]] = []
        let button = ClipboardFileButton(allowedTypes: [.image, .pdf], stagePDF: workspace.stageClipboardPDF,
                                         stageImage: { image in
            let staged = try CaptureTextAttachment(image: image, filename: "Pasted Scan.png")
            attachment = staged
            return staged.url
        }) { batches.append($0) }
        #expect(button.paste(from: board))
        let staged = try #require(attachment)
        #expect(batches == [[staged.url, first, workspace.url.appending(path: "Clipboard PDF 1.pdf")]])
        let batch = try #require(batches.first)
        let inputs = try batch.map { try DocumentScanner.load($0) }
        #expect(inputs.map(\.count) == [1, 2, 4])

        var draft = DocumentScannerDraft()
        let initial = try (1...(DocumentScanner.pageLimit - 2)).flatMap {
            try DocumentScanner.load(png, name: "Existing page \($0)")
        }
        try draft.insert(initial, replacing: nil)
        do {
            try draft.insert(inputs[2], replacing: nil)
            Issue.record("The overflowing scan should have been rejected.")
        } catch let error as ToolError {
            #expect(error.localizedDescription.contains("up to 24 pages"))
        }
        #expect(draft.pages.map(\.id) == initial.map(\.id))
        #expect(draft.selection == initial.first?.id)

        try draft.insert(inputs[0], replacing: nil)
        let last = try #require(inputs[2].first)
        try draft.insert([last], replacing: initial[0].id)
        #expect(draft.pages.count == DocumentScanner.pageLimit - 1)
        #expect(draft.pages.first?.id == last.id)
        #expect(draft.selection == last.id)
    }

    @Test func stagedClipboardPDFsKeepTheirBytesAndRemainAvailableToBatchTools() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (first, second, corrupt) = try fixtures(in: folder)
        let firstData = try Data(contentsOf: first)
        let secondData = try Data(contentsOf: second)
        let corruptData = try Data(contentsOf: corrupt)
        let workspace = try WorkspacePDFDirectory()

        let stagedFirst = try workspace.stageClipboardPDF(firstData)
        #expect(throws: CocoaError.self) { try workspace.stageClipboardPDF(corruptData) }
        let stagedSecond = try workspace.stageClipboardPDF(secondData)
        #expect(stagedSecond.lastPathComponent == "Clipboard PDF 2.pdf")
        #expect(try Data(contentsOf: stagedFirst) == firstData)
        #expect(try Data(contentsOf: stagedSecond) == secondData)

        let reader = PDFReaderSession()
        try #require(reader.openFirst(in: [stagedSecond, stagedFirst]))
        #expect(reader.document?.pageCount == 4)
        let report = try await ToolRunner.run(.mergePDFs, inputs: reader.queuedFiles, destination: folder,
                                              imageSize: 1600) { _ in }
        #expect(report.failures.isEmpty)
        let output = try #require(report.outputs.first)
        #expect(PDFDocument(url: output)?.pageCount == 6)
    }

    @Test func separateOpenRequestsAccumulateAndReloadReplacedPaths() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (first, second, corrupt) = try fixtures(in: folder)
        let reader = PDFReaderSession()
        reader.openDeliveredFile(first)
        reader.openDeliveredFile(second)
        reader.openDeliveredFile(corrupt)
        #expect(reader.queuedFiles == [first, second])
        #expect(reader.source == second)
        #expect(reader.error != nil)

        let replacement = folder.appending(path: "replacement.pdf")
        try writePDF(replacement, pages: 3)
        _ = try FileManager.default.replaceItemAt(first, withItemAt: replacement)
        reader.openDeliveredFile(first)
        #expect(reader.queuedFiles == [first, second])
        #expect(reader.source == first)
        #expect(reader.document?.pageCount == 3)
        #expect(reader.error == nil)
    }

    @Test func rejectsRemoteFileAuthoritiesAndAcceptsLocalLinks() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (first, second, _) = try fixtures(in: folder)
        let link = folder.appending(path: "link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        var components = try #require(URLComponents(url: second, resolvingAgainstBaseURL: false))
        components.host = "other-machine.invalid"
        let remote = try #require(components.url)
        let reader = PDFReaderSession()

        try #require(reader.openFirst(in: [remote, link]))
        #expect(reader.source == link)
        #expect(reader.document?.pageCount == 2)
        reader.openDeliveredFile(remote)
        #expect(reader.source == link)
        #expect(reader.queuedFiles == [link])
        #expect(reader.error != nil)
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func fixtures(in folder: URL) throws -> (URL, URL, URL) {
        let nested = folder.appending(path: "Other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let first = folder.appending(path: "source.pdf")
        let second = nested.appending(path: "source.pdf")
        let corrupt = folder.appending(path: "bad.pdf")
        try writePDF(first, pages: 2)
        try writePDF(second, pages: 4)
        try Data("broken pdf".utf8).write(to: corrupt)
        return (first, second, corrupt)
    }

    private func writePDF(_ url: URL, pages: Int) throws {
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.fill(CGRect(x: 20, y: 20, width: 30, height: 40))
            context.endPDFPage()
        }
        context.closePDF()
    }
}
