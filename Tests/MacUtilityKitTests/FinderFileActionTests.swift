import AppKit
import Testing
import UtilityCore
@testable import MacUtilityKit

@MainActor
struct FinderFileActionTests {
    @Test func serviceReadsPDFsInSelectionOrderAndPreparesTheMatchingDraft() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appending(path: "first.pdf")
        let second = folder.appending(path: "second.pdf")
        for file in [first, second] { try Data().write(to: file) }

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try #require(board.writeObjects([second as NSURL, first as NSURL]))
        let action = try #require(FinderFileAction(serviceID: Tool.mergePDFs.rawValue, pasteboard: board))
        #expect(action.tool == .mergePDFs)
        let session = WorkspaceSession()
        #expect(session.loadFinderAction(action, with: .mergePDFs))
        #expect(session.drafts[.mergePDFs]?.inputs == [second, first])
        let favorites = try #require(FinderFileAction(serviceID: "favorites", pasteboard: board))
        #expect(favorites.compatibleFavorites([.organizePDF, .resizeImages, .compressPDF, .mergePDFs])
                == [.compressPDF, .mergePDFs])
    }

    @Test func serviceRejectsMismatchedTypesAndUnsupportedActions() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = folder.appending(path: "source.pdf")
        let image = folder.appending(path: "source.png")
        for file in [pdf, image] { try Data().write(to: file) }

        #expect(FinderFileAction(serviceID: "compressPDF", files: [pdf])?.tool == .compressPDF)
        let favorites = try #require(FinderFileAction(serviceID: "favorites", files: [image]))
        #expect(favorites.tool == nil)
        #expect(favorites.compatibleFavorites([.resizeImages, .compressPDF, .convertImages, .annotateScreenshot])
                == [.resizeImages, .convertImages])
        let session = WorkspaceSession()
        #expect(session.loadFinderAction(favorites, with: .resizeImages))
        #expect(session.drafts[.resizeImages]?.inputs == [image])
        #expect(FinderFileAction(serviceID: "compressImages", files: [image, pdf]) == nil)
        #expect(FinderFileAction(serviceID: "compressPDF", files: [image]) == nil)
        #expect(FinderFileAction(serviceID: "mergePDFs", files: [pdf]) == nil)
        #expect(FinderFileAction(serviceID: "deletePDFPages", files: [pdf]) == nil)
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
