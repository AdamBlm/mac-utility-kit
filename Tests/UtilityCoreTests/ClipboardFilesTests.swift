import AppKit
import PDFKit
import Testing
@testable import UtilityCore

@MainActor
struct ClipboardFilesTests {
    @Test func mixedClipboardItemsKeepOrderAndSelectOneRepresentationEach() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Source.pdf")
        try Data().write(to: file)
        let firstPDF = Data("first PDF representation".utf8)
        let secondPDF = Data("second PDF representation".utf8)
        let fileItem = NSPasteboardItem()
        try #require(fileItem.setString(file.absoluteString, forType: .fileURL))
        try #require(fileItem.setData(firstPDF, forType: .pdf))
        let first = NSPasteboardItem()
        try #require(first.setData(firstPDF, forType: .pdf))
        let second = NSPasteboardItem()
        try #require(second.setData(secondPDF, forType: .pdf))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try #require(board.writeObjects([first, fileItem, second]))
        let contents = try #require(board.pasteboardItems).compactMap {
            try ClipboardFiles.content(from: $0, allowedTypes: [.pdf, .image], acceptsPDF: true, acceptsImage: true)
        }
        guard contents.count == 3,
              case .pdf(let firstData) = contents[0],
              case .file(let url) = contents[1],
              case .pdf(let lastData) = contents[2] else {
            Issue.record("The pasteboard item order or representation precedence changed.")
            return
        }
        #expect(firstData == firstPDF)
        #expect(url == file)
        #expect(lastData == secondPDF)
    }

    @Test func pastesLocalFilesInOrderAndFiltersUnsupportedClipboardItems() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appending(path: "Copied image.png")
        let pdf = folder.appending(path: "Copied document.pdf")
        let text = folder.appending(path: "Notes.txt")
        for file in [image, pdf, text] {
            try Data().write(to: file)
        }

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let remote = try #require(URL(string: "https://example.test/remote.pdf"))
        var fileOnServer = try #require(URLComponents(url: image, resolvingAgainstBaseURL: false))
        fileOnServer.host = "server.example.test"
        let networkFileURL = try #require(fileOnServer.url)
        #expect(board.writeObjects([image as NSURL, remote as NSURL, networkFileURL as NSURL, text as NSURL, pdf as NSURL]))
        #expect(ClipboardFiles.read(from: board, allowedTypes: [.image, .pdf]) == [image, pdf])
        #expect(ClipboardFiles.read(from: board, allowedTypes: [.pdf]) == [pdf])

        board.clearContents()
        #expect(board.setString(image.path, forType: .string))
        #expect(ClipboardFiles.read(from: board, allowedTypes: [.image]).isEmpty)
    }

    @Test func acceptsClipboardSymlinksByTheirTargetType() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = folder.appending(path: "Document.pdf")
        try Data().write(to: pdf)
        let link = folder.appending(path: "Clipboard shortcut")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: pdf)

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try #require(board.writeObjects([link as NSURL, pdf as NSURL]))
        #expect(ClipboardFiles.read(from: board, allowedTypes: [.pdf]) == [link, pdf])
    }

    @Test func mixedWorkspaceInputsKeepSupportedFilesInOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appending(path: "Picture.png")
        let pdf = folder.appending(path: "Document.pdf")
        let unrelated = folder.appending(path: "Notes.txt")
        for url in [image, pdf, unrelated] { try Data().write(to: url) }
        let directory = folder.appending(path: "Folder.pdf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let linkedPDF = folder.appending(path: "Linked document.pdf")
        try FileManager.default.createSymbolicLink(at: linkedPDF, withDestinationURL: pdf)
        let missing = folder.appending(path: "Missing.pdf")
        let remote = try #require(URL(string: "https://example.test/remote.pdf"))
        let offered = [image, directory, unrelated, linkedPDF, missing, remote, pdf]

        #expect(offered.filter { LocalInputFile.matches($0, allowedTypes: Tool.mergePDFs.inputTypes) }
                == [image, linkedPDF, pdf])
        #expect(offered.filter { LocalInputFile.matches($0, allowedTypes: Tool.splitPDF.inputTypes) }
                == [linkedPDF, pdf])
    }

    @Test func mergesCopiedPDFAndImageInClipboardOrder() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }

        let pdf = folder.appending(path: "document.pdf")
        let pdfImage = NSImage(size: NSSize(width: 100, height: 70), flipped: false) { bounds in
            NSColor.blue.setFill()
            bounds.fill()
            return true
        }
        let source = PDFDocument()
        source.insert(try #require(PDFPage(image: pdfImage)), at: 0)
        try #require(source.write(to: pdf))

        let png = folder.appending(path: "image.png")
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: png)

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try #require(board.writeObjects([pdf as NSURL, png as NSURL]))
        let inputs = ClipboardFiles.read(from: board, allowedTypes: Tool.mergePDFs.inputTypes)
        let report = try await ToolRunner.run(.mergePDFs, inputs: inputs, destination: folder, imageSize: 1600) { _ in }
        #expect(report.failures.isEmpty)
        let output = try #require(report.outputs.first)
        let merged = try #require(PDFDocument(url: output))
        #expect(merged.pageCount == 2)
        #expect(merged.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 100, height: 70))
        #expect(merged.page(at: 1)?.bounds(for: .mediaBox).size == CGSize(width: 32, height: 16))
    }

    @Test func fallsBackToSmallerClipboardImageRepresentation() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let large = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 10_000, pixelsHigh: 10_000,
            bitsPerSample: 1, samplesPerPixel: 1, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceWhite, bytesPerRow: 1250, bitsPerPixel: 1
        ))
        let buffer = try #require(large.bitmapData)
        buffer.initialize(repeating: 0, count: large.bytesPerPlane)
        let png = try #require(large.representation(using: .png, properties: [:]))
        #expect(board.setData(png, forType: .png))
        #expect(throws: ToolError.self) { try ClipboardFiles.readImage(from: board) }

        let small = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let tiff = try #require(small.representation(using: .tiff, properties: [:]))
        let item = NSPasteboardItem()
        try #require(item.setData(png, forType: .png))
        try #require(item.setData(tiff, forType: .tiff))
        board.clearContents()
        try #require(board.writeObjects([item]))
        #expect(try ClipboardFiles.readImage(from: board)?.width == 2)
    }

    @Test func decodesCopiedPNGAndTIFFWithoutAFileURL() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let representation = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        for (format, pasteType): (NSBitmapImageRep.FileType, NSPasteboard.PasteboardType) in [(.png, .png), (.tiff, .tiff)] {
            let data = try #require(representation.representation(using: format, properties: [:]))
            board.clearContents()
            #expect(board.setData(data, forType: pasteType))
            #expect(ClipboardFiles.read(from: board, allowedTypes: [.image]).isEmpty)
            let image = try #require(try ClipboardFiles.readImage(from: board))
            #expect(image.width == 64)
            #expect(image.height == 32)
        }
    }
}
