import AppKit
import PDFKit
import UniformTypeIdentifiers

enum PDFOperations {
    static func merge(
        _ inputs: [URL], ranges: [String], passwords: [String], into output: URL, progress: @Sendable (Double) async -> Void
    ) async throws {
        let result = PDFDocument()
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            try append(input, range: ranges.indices.contains(index) ? ranges[index] : "",
                       password: passwords.indices.contains(index) ? passwords[index] : "", to: result)
            await progress(Double(index + 1) / Double(inputs.count + 1))
        }
        guard result.pageCount > 0 else { throw ToolError.invalid("Select at least one page to merge.") }
        guard result.write(to: output) else { throw ToolError.invalid("Could not write the PDF.") }
        await progress(1)
    }

    private static func append(_ input: URL, range: String, password: String, to result: PDFDocument) throws {
        if range.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none" { return }
        let type = try input.resourceValues(forKeys: [.contentTypeKey]).contentType
        if type?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(url: input),
                  !document.isLocked || document.unlock(withPassword: password),
                  document.pageCount > 0 else {
                throw ToolError.invalid("Could not open \(input.lastPathComponent) as an unlocked PDF.")
            }
            for pageIndex in try PageSelection.indices(range, pageCount: document.pageCount) {
                try Task.checkCancellation()
                guard let page = document.page(at: pageIndex) else {
                    throw ToolError.invalid("Could not read a page in \(input.lastPathComponent).")
                }
                result.insert(page, at: result.pageCount)
            }
        } else if let image = NSImage(contentsOf: input), let page = PDFPage(image: image) {
            if try !PageSelection.indices(range, pageCount: 1).isEmpty {
                result.insert(page, at: result.pageCount)
            }
        } else {
            throw ToolError.invalid("Could not read \(input.lastPathComponent). Check whether it is damaged or locked.")
        }
    }
}
