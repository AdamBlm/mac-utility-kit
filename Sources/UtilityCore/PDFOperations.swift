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
        var sourceStamps: [Int: PDFMergeSourceStamp] = [:]
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            let range = ranges.indices.contains(index) ? ranges[index] : ""
            guard range.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "none" else { continue }
            if let stamps {
                guard let reviewed = stamps[index] else {
                    throw ToolError.invalid("Refresh the preview for \(input.lastPathComponent) before merging.")
                }
                try validate(reviewed, input: input, reviewed: true)
                sourceStamps[index] = reviewed
            } else {
                sourceStamps[index] = try PDFMergeSourceStamp.read(input)
            }
        }

        var sources: [PDFDocument?] = []
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            let password = passwords.indices.contains(index) ? passwords[index] : ""
            do {
                sources.append(sourceStamps[index] == nil ? nil : try open(input, password: password).document)
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
        try validate(sourceStamps, inputs: inputs, selected: pages, reviewed: stamps != nil)
        guard result.write(to: output) else { throw ToolError.invalid("Could not write the PDF.") }
        guard let saved = PDFDocument(url: output), !saved.isLocked, saved.pageCount == pages.count else {
            throw ToolError.invalid("The merged PDF could not be reopened with the expected page count.")
        }
        await progress(1)
        try validate(sourceStamps, inputs: inputs, selected: pages, reviewed: stamps != nil)
    }

    private static func validate(
        _ stamps: [Int: PDFMergeSourceStamp], inputs: [URL], selected: [PDFMergePageReference], reviewed: Bool
    ) throws {
        for index in Set(selected.map(\.source)) {
            if let stamp = stamps[index] { try validate(stamp, input: inputs[index], reviewed: reviewed) }
        }
    }

    private static func validate(_ stamp: PDFSourceStamp, input: URL, reviewed: Bool) throws {
        guard (try? PDFSourceStamp.read(input)) == stamp else {
            let message = reviewed
                ? "\(input.lastPathComponent) changed after preview. Refresh the source previews before merging."
                : "\(input.lastPathComponent) changed during merging. Try again."
            throw ToolError.invalid(message)
        }
    }

    package static func open(_ input: URL, password: String) throws -> (document: PDFDocument, requiredPassword: Bool) {
        guard let resolved = LocalInputFile.regularFile(input) else {
            throw ToolError.invalid("Could not read \(input.lastPathComponent). Choose a local PDF or image.")
        }
        let type = try resolved.resourceValues(forKeys: [.contentTypeKey]).contentType
        if type?.conforms(to: .pdf) == true || resolved.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: resolved) else {
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
        guard let image = NSImage(contentsOf: resolved), let page = PDFPage(image: image) else {
            throw ToolError.invalid("Could not read \(input.lastPathComponent). Check whether it is damaged or locked.")
        }
        let document = PDFDocument()
        document.insert(page, at: 0)
        return (document, false)
    }
}
