import cmark_gfm
import Foundation

enum DocumentConversionEngines {
    static func pandoc(
        _ input: URL, from source: DocumentConvert.Source, to output: URL,
        target: DocumentConvertOptions.Format, executable: URL
    ) async throws {
        let reader: String
        switch source {
        case .format(.docx): reader = "docx"
        case .format(.odt): reader = "odt"
        case .format(.rtf): reader = "rtf"
        case .format(.html): reader = "html-raw_html"
        case .format(.markdown): reader = "markdown-raw_html"
        default: throw ToolError.invalid("This input is unavailable in Pandoc.")
        }
        let writer: String
        switch target {
        case .docx: writer = "docx"
        case .odt: writer = "odt"
        case .rtf: writer = "rtf"
        case .html: writer = "html5"
        case .plain: writer = "plain"
        case .markdown: writer = "gfm-raw_html"
        }
        let folder = output.deletingLastPathComponent()
        let log = folder.appending(path: UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: log) }
        var arguments = [
            "--sandbox", "--log", log.path, "--from", reader, "--to", writer, "--wrap=none", "--output", output.path
        ]
        if target == .html || target == .rtf { arguments += ["--standalone"] }
        if target == .html { arguments.append("--embed-resources") }
        arguments.append(input.path)
        try await ExternalTool.run(executable, name: "Pandoc", arguments: arguments, directory: folder)
        let diagnostics = try JSONDecoder().decode([PandocDiagnostic].self, from: Data(contentsOf: log))
        guard !diagnostics.contains(where: { $0.type == "CouldNotFetchResource" }) else {
            throw ToolError.invalid("Pandoc could not read an image or other document resource. Embed the resource in the source document before converting.")
        }
        if target == .markdown {
            try verifyMarkdownImages(output)
        }
    }

    private struct PandocDiagnostic: Decodable {
        let type: String
    }

    private static func verifyMarkdownImages(_ output: URL) throws {
        let text = try DocumentConvert.readText(output)
        guard let document = text.withCString({ cmark_parse_document($0, text.utf8.count, 0) }) else {
            throw ToolError.invalid("Could not inspect the exported Markdown.")
        }
        defer { cmark_node_free(document) }
        guard let iterator = cmark_iter_new(document) else {
            throw ToolError.invalid("Could not inspect the exported Markdown.")
        }
        defer { cmark_iter_free(iterator) }
        while cmark_iter_next(iterator) != CMARK_EVENT_DONE {
            try Task.checkCancellation()
            guard let node = cmark_iter_get_node(iterator), cmark_node_get_type(node) == CMARK_NODE_IMAGE,
                  let address = cmark_node_get_url(node) else { continue }
            let scheme = URLComponents(string: String(cString: address))?.scheme?.lowercased()
            guard scheme == "http" || scheme == "https" || scheme == "data" else {
                throw ToolError.invalid("This Markdown would require separate image files. Choose HTML to export a self-contained file.")
            }
        }
    }

    static func officeBinary(_ executable: URL) -> URL {
        LibreOfficeHeadless.binary(for: executable)
    }

    static func libreOffice(
        _ input: URL, to output: URL, target: DocumentConvertOptions.Format, executable: URL, stage: URL
    ) async throws {
        let outputFilter: String
        switch target {
        case .docx: outputFilter = "docx:Office Open XML Text"
        case .odt: outputFilter = "odt:writer8"
        case .rtf: outputFilter = "rtf:Rich Text Format"
        case .html: outputFilter = "html:XHTML Writer File:UTF8"
        case .plain: outputFilter = "txt:Text (encoded):UTF8"
        case .markdown: throw ToolError.invalid("Markdown export requires Pandoc.")
        }
        let inputFilter = input.pathExtension.lowercased() == "txt" ? "Text (encoded):UTF8,LF" : nil
        let candidate = try await LibreOfficeHeadless.convert(input, filter: outputFilter,
                                                               fileExtension: target.fileExtension,
                                                               executable: executable, in: stage, inputFilter: inputFilter)
        try verify(candidate, format: target)
        if target == .html {
            let contents = try FileManager.default.contentsOfDirectory(atPath: candidate.deletingLastPathComponent().path)
            guard contents.count == 1 else {
                throw ToolError.invalid("LibreOffice produced separate HTML media files. Choose Pandoc or another target to export a single file.")
            }
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: candidate, to: output)
    }

    static func verify(_ output: URL, format: DocumentConvertOptions.Format) throws {
        guard let info = try? output.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              info.isRegularFile == true, let size = info.fileSize, size <= 256 * 1024 * 1024 else {
            throw ToolError.invalid("The engine did not produce a readable document.")
        }
        switch format {
        case .docx, .odt, .rtf:
            let handle = try FileHandle(forReadingFrom: output)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 8) ?? Data()
            let signature: [UInt8] = format == .rtf ? Array("{\\rtf".utf8) : [0x50, 0x4B, 0x03, 0x04]
            guard prefix.starts(with: signature) else {
                throw ToolError.invalid("The output did not match \(format.rawValue).")
            }
        case .html, .markdown, .plain:
            let text = try DocumentConvert.readText(output)
            if format == .html, !text.lowercased().contains("<html") {
                throw ToolError.invalid("The output did not contain an HTML document.")
            }
        }
    }
}
