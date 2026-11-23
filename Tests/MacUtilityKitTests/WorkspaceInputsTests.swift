import AppKit
import Foundation
import Testing
import UtilityCore
@testable import MacUtilityKit

@MainActor
struct WorkspaceInputsTests {
    @Test func clipboardBatchPreservesFileOrderAndSkipsUnsupportedEntries() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appending(path: "first.pdf")
        let second = folder.appending(path: "second.pdf")
        let text = folder.appending(path: "note.txt")
        for file in [first, second, text] { try Data().write(to: file) }

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try #require(board.writeObjects([second, text, first, folder].map { $0 as NSURL }))
        let urls = ClipboardFiles.read(from: board, allowedTypes: Tool.mergePDFs.inputTypes)
        var draft = ToolDraft()
        let addedBatch = draft.addInputs(urls, for: .mergePDFs)
        try #require(addedBatch)
        #expect(draft.inputs == [second, first])

        let addedRepeat = draft.addInputs([second], for: .mergePDFs)
        try #require(addedRepeat)
        #expect(draft.inputs == [second, first, second])
    }

    @Test func singlePDFToolsRejectAmbiguousBatchesAndResetOnReplacement() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appending(path: "first.pdf")
        let second = folder.appending(path: "second.pdf")
        let invalid = folder.appending(path: "folder.pdf", directoryHint: .isDirectory)
        for file in [first, second] { try Data().write(to: file) }
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: false)

        var draft = ToolDraft()
        let addedFirst = draft.addInputs([first], for: .splitPDF)
        try #require(addedFirst)
        draft.options.pdfSplit.password = "previous source"
        let revision = draft.pdfSourceRevision
        let acceptedAmbiguousBatch = draft.addInputs([first, second], for: .splitPDF)
        #expect(!acceptedAmbiguousBatch)
        #expect(draft.inputs == [first])
        #expect(draft.pdfSourceRevision == revision)
        let replaced = draft.addInputs([invalid, second], for: .splitPDF)
        try #require(replaced)
        #expect(draft.inputs == [second])
        #expect(draft.pdfSourceRevision != revision)
        #expect(draft.options.pdfSplit.password.isEmpty)
    }

    @Test func cropReplacementClearsThePriorPageSelectionAndOffsets() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appending(path: "first.pdf")
        let second = folder.appending(path: "second.pdf")
        for file in [first, second] { try Data("fixture".utf8).write(to: file) }

        var draft = ToolDraft()
        let addedFirst = draft.addInputs([first], for: .cropPDF)
        try #require(addedFirst)
        draft.options.pdfCrop.pages = "4–6"
        draft.options.pdfCrop.offsets.left = 120
        draft.options.pdfCrop.sourceStamp = try PDFSourceStamp.read(first)

        let acceptedAmbiguousBatch = draft.addInputs([first, second], for: .cropPDF)
        #expect(!acceptedAmbiguousBatch)
        #expect(draft.options.pdfCrop.pages == "4–6")
        #expect(draft.options.pdfCrop.offsets.left == 120)

        let replaced = draft.addInputs([second], for: .cropPDF)
        try #require(replaced)
        #expect(draft.inputs == [second])
        #expect(draft.options.pdfCrop == PDFCropOptions())
    }

    @Test func allToolsHaveSearchableTitlesAndAvailableSymbols() {
        for tool in Tool.allCases {
            #expect(tool.matchesWorkspaceSearch(tool.title), Comment(rawValue: tool.rawValue))
            #expect(tool.matchesWorkspaceSearch(tool.category), Comment(rawValue: tool.rawValue))
            #expect(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil) != nil,
                    Comment(rawValue: "\(tool.title) uses \(tool.symbol)"))
        }
        #expect(Tool.mergePDFs.matchesWorkspaceSearch("combine pdf"))
        #expect(Tool.compressPDF.matchesWorkspaceSearch("reduce pdf size"))
        #expect(Tool.rotateImages.matchesWorkspaceSearch("crop images"))
        #expect(Tool.workspaceSearchResults("  SCREENSHOT  ").first == .screenshot)
        #expect(Tool.workspaceSearchResults("combine pdf").first == .mergePDFs)
        #expect(Tool.workspaceSearchResults("reduce pdf size").first == .compressPDF)
        #expect(Tool.workspaceSearchResults("  ") == Tool.allCases)
        #expect(Tool.workspaceSearchResults("no matching tool here 12345").isEmpty)
        for category in ToolCategory.allCases {
            let results = Tool.workspaceSearchResults(category.title)
            #expect(Set(results).count == results.count)
            #expect(results.filter { $0.group == category }.count == Tool.allCases.filter { $0.group == category }.count)
        }
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }
}
