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
        #expect(board.writeObjects([image as NSURL, remote as NSURL, text as NSURL, pdf as NSURL]))
        #expect(ClipboardFiles.read(from: board, allowedTypes: [.image, .pdf]) == [image, pdf])
        #expect(ClipboardFiles.read(from: board, allowedTypes: [.pdf]) == [pdf])

        board.clearContents()
        #expect(board.setString(image.path, forType: .string))
        #expect(ClipboardFiles.read(from: board, allowedTypes: [.image]).isEmpty)
    }
}
