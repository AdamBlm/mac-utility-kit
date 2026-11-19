import AppKit
import PDFKit
import UniformTypeIdentifiers

package enum PDFOperations {
    package enum SourceError: LocalizedError {
        case passwordRequired(String)

        package var errorDescription: String? {
            switch self {
            case .passwordRequired(let filename): "Enter the correct PDF password for \(filename)."
            }
        }
    }

    static func merge(
        _ inputs: [URL], ranges: [String], passwords: [String], order: [PDFMergePageReference]? = nil,
        stamps: [Int: PDFMergeSourceStamp]? = nil, into output: URL, progress: @Sendable (Double) async -> Void
    ) async throws {
        var sources: [PDFDocument?] = []
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            let range = ranges.indices.contains(index) ? ranges[index] : ""
            let password = passwords.indices.contains(index) ? passwords[index] : ""
            let excluded = range.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none"
            if !excluded, let stamps {
                guard let reviewed = stamps[index] else {
                    throw ToolError.invalid("Refresh the preview for \(input.lastPathComponent) before merging.")
                }
                try validate(reviewed, input: input)
            }
            do {
                sources.append(excluded ? nil : try open(input, password: password).document)
            } catch let error as SourceError {
                throw ToolError.invalid(error.localizedDescription)
            }
            await progress(0.25 * Double(index + 1) / Double(inputs.count))
        }
        let counts = sources.map { $0?.pageCount ?? 0 }
        let selected = try PDFMergePlan.selectedPages(counts: counts, ranges: ranges)
        let pages = try PDFMergePlan.validate(order, against: selected)
        let result = PDFDocument()
        for (index, reference) in pages.enumerated() {
            try Task.checkCancellation()
            guard let page = sources[reference.source]?.page(at: reference.page)?.copy() as? PDFPage else {
                throw ToolError.invalid("Could not read a page in \(inputs[reference.source].lastPathComponent).")
            }
            result.insert(page, at: result.pageCount)
            await progress(0.25 + 0.65 * Double(index + 1) / Double(pages.count))
        }
        try Task.checkCancellation()
        try validate(stamps, inputs: inputs, selected: pages)
        guard result.write(to: output) else { throw ToolError.invalid("Could not write the PDF.") }
        guard let saved = PDFDocument(url: output), !saved.isLocked, saved.pageCount == pages.count else {
            throw ToolError.invalid("The merged PDF could not be reopened with the expected page count.")
        }
        try validate(stamps, inputs: inputs, selected: pages)
        await progress(1)
    }

    private static func validate(
        _ stamps: [Int: PDFMergeSourceStamp]?, inputs: [URL], selected: [PDFMergePageReference]
    ) throws {
        guard let stamps else { return }
        for index in Set(selected.map(\.source)) {
            if let stamp = stamps[index] { try validate(stamp, input: inputs[index]) }
        }
    }

    private static func validate(_ stamp: PDFSourceStamp, input: URL) throws {
        guard (try? PDFSourceStamp.read(input)) == stamp else {
            throw ToolError.invalid("\(input.lastPathComponent) changed after preview. Refresh the source previews before merging.")
        }
    }

    package static func open(_ input: URL, password: String) throws -> (document: PDFDocument, requiredPassword: Bool) {
        let type = try input.resourceValues(forKeys: [.contentTypeKey]).contentType
        if type?.conforms(to: .pdf) == true || input.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: input) else {
                throw ToolError.invalid("Could not open \(input.lastPathComponent) as a PDF.")
            }
            let locked = document.isLocked
            if locked && !document.unlock(withPassword: password) {
                throw SourceError.passwordRequired(input.lastPathComponent)
            }
            guard document.pageCount > 0 else {
                throw ToolError.invalid("\(input.lastPathComponent) has no pages.")
            }
            return (document, locked)
        }
        guard let image = NSImage(contentsOf: input), let page = PDFPage(image: image) else {
            throw ToolError.invalid("Could not read \(input.lastPathComponent). Check whether it is damaged or locked.")
        }
        let document = PDFDocument()
        document.insert(page, at: 0)
        return (document, false)
    }
}
