import AppKit
import Testing
@testable import UtilityCore

@MainActor
struct ClipboardFilesTests {
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
