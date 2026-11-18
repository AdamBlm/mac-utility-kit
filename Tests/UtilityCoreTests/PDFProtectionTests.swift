import CoreGraphics
import Foundation
import PDFKit
import Testing
import UtilityCore

struct PDFProtectionTests {
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
        context.closePDF()
        let original = try Data(contentsOf: source)

        var choices = PDFProtectionOptions()
        choices.executable = executable
        choices.password = "Review 2026"
        choices.confirmation = choices.password
        choices.ownerPassword = "Independent owner"
        choices.allowsPrinting = false
        choices.allowsCopying = false
        let protected = folder.appendingPathComponent("protected.pdf")
        _ = try await PDFProtection.add(source, to: protected, options: choices)
        let saved = try #require(PDFDocument(url: protected))
        #expect(saved.isEncrypted && saved.isLocked)
        #expect(saved.unlock(withPassword: choices.password))
        #expect(!saved.allowsPrinting && !saved.allowsCopying)

        let decrypted = folder.appendingPathComponent("decrypted.pdf")
        var wrong = choices
        wrong.password = "wrong password"
        await #expect(throws: ToolError.self) { try await PDFProtection.remove(protected, to: decrypted, options: wrong) }
        #expect(!FileManager.default.fileExists(atPath: decrypted.path))
        _ = try await PDFProtection.remove(protected, to: decrypted, options: choices)
        let finished = try #require(PDFDocument(url: decrypted))
        #expect(!finished.isEncrypted && !finished.isLocked)
        #expect(finished.pageCount == 1)
        #expect(finished.page(at: 0)?.bounds(for: .mediaBox) == bounds)
        #expect(try Data(contentsOf: source) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            == ["decrypted.pdf", "original.pdf", "protected.pdf"])
    }
}
