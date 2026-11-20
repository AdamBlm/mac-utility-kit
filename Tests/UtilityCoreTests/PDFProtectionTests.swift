import CoreGraphics
import Foundation
import PDFKit
import Testing
import UtilityCore

struct PDFProtectionTests {
    @Test func preflightDetectsUTF8ByteLimitAndCredentialRoleIssues() {
        var choices = PDFProtectionOptions()
        choices.password = String(repeating: "é", count: 63) + "a"
        choices.confirmation = choices.password
        #expect(choices.password.utf8.count == 127)
        #expect(PDFProtection.addPasswordIssue(choices) == nil)

        choices.password = String(repeating: "é", count: 64)
        choices.confirmation = choices.password
        #expect(PDFProtection.addPasswordIssue(choices)?.contains("document password of at most 127 UTF-8 bytes") == true)
        choices.password = "reader"
        #expect(PDFProtection.addPasswordIssue(choices) == "Confirm the document password.")
        choices.confirmation = choices.password
        choices.ownerPassword = "reader"
        #expect(PDFProtection.addPasswordIssue(choices) == "Choose a different owner password.")
        choices.ownerPassword = "owner\0password"
        #expect(PDFProtection.addPasswordIssue(choices)?.contains("owner password of at most 127 UTF-8 bytes") == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_UTILITY_QPDF_TEST"] != nil))
    func encryptsAndDecryptsWithVerifiedRestrictionsAndNoPartialFile() async throws {
        let executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MAC_UTILITY_QPDF_TEST"]))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = try #require(CGContext(source as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.fill(bounds.insetBy(dx: 20, dy: 20))
        context.endPDFPage()
        let secondPageBounds = CGRect(x: 0, y: 0, width: 350, height: 180)
        var mediaBox = secondPageBounds
        let pageInfo = withUnsafeBytes(of: &mediaBox) {
            [kCGPDFContextMediaBox: Data($0)] as CFDictionary
        }
        context.beginPDFPage(pageInfo)
        context.fill(secondPageBounds.insetBy(dx: 15, dy: 15))
        context.endPDFPage()
        context.closePDF()
        let original = try Data(contentsOf: source)

        var choices = PDFProtectionOptions()
        choices.executable = executable
        choices.password = String(repeating: "a", count: 127)
        choices.confirmation = choices.password
        choices.ownerPassword = "Independent owner"
        choices.allowsPrinting = false
        choices.allowsCopying = false
        let protected = folder.appendingPathComponent("protected.pdf")
        var longPassword = choices
        longPassword.password += "b"
        longPassword.confirmation = longPassword.password
        await #expect(throws: ToolError.self) { try await PDFProtection.add(source, to: protected, options: longPassword) }
        #expect(!FileManager.default.fileExists(atPath: protected.path))
        _ = try await PDFProtection.add(source, to: protected, options: choices)
        let saved = try #require(PDFDocument(url: protected))
        #expect(saved.isEncrypted && saved.isLocked)
        #expect(saved.unlock(withPassword: choices.password))
        #expect(!saved.allowsPrinting && !saved.allowsCopying)
        #expect(saved.pageCount == 2)
        #expect(saved.page(at: 1)?.bounds(for: .mediaBox) == secondPageBounds)
        var unicode = choices
        unicode.password = String(repeating: "é", count: 63) + "a"
        unicode.confirmation = unicode.password
        unicode.ownerPassword = "Owner 🔑"
        let unicodePDF = folder.appendingPathComponent("unicode.pdf")
        _ = try await PDFProtection.add(source, to: unicodePDF, options: unicode)
        let unicodePreview = try await PDFProtection.unlockedPreviewData(unicodePDF, options: unicode)
        let unicodeDocument = try #require(PDFDocument(data: unicodePreview))
        #expect(!unicodeDocument.isLocked)
        #expect(unicodeDocument.pageCount == 2)
        #expect(unicodeDocument.page(at: 1)?.bounds(for: .mediaBox) == secondPageBounds)
        var wrongUnicode = unicode
        wrongUnicode.password = "incorrect"
        await #expect(throws: ToolError.self) {
            try await PDFProtection.unlockedPreviewData(unicodePDF, options: wrongUnicode)
        }
        let unicodeDecrypted = folder.appendingPathComponent("unicode-decrypted.pdf")
        _ = try await PDFProtection.remove(unicodePDF, to: unicodeDecrypted, options: unicode)
        #expect(PDFDocument(url: unicodeDecrypted)?.pageCount == 2)
        try FileManager.default.removeItem(at: unicodeDecrypted)
        try FileManager.default.removeItem(at: unicodePDF)

        let protectedBytes = try Data(contentsOf: protected)

        let decrypted = folder.appendingPathComponent("decrypted.pdf")
        var wrong = choices
        wrong.password = "wrong password"
        await #expect(throws: ToolError.self) { try await PDFProtection.remove(protected, to: decrypted, options: wrong) }
        #expect(!FileManager.default.fileExists(atPath: decrypted.path))
        _ = try await PDFProtection.remove(protected, to: decrypted, options: choices)
        let finished = try #require(PDFDocument(url: decrypted))
        #expect(!finished.isEncrypted && !finished.isLocked)
        #expect(finished.pageCount == 2)
        #expect(finished.page(at: 0)?.bounds(for: .mediaBox) == bounds)
        #expect(finished.page(at: 1)?.bounds(for: .mediaBox) == secondPageBounds)
        #expect(try Data(contentsOf: protected) == protectedBytes)
        #expect(try Data(contentsOf: source) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            == ["decrypted.pdf", "original.pdf", "protected.pdf"])
    }
}
