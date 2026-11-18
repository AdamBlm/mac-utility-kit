import Foundation

public struct JobReport: Sendable {
    public let outputs: [URL]
    public let failures: [String]
    public let summaries: [String]
    public let inspections: [MediaInspectionResult]
    public let imageComparisons: [ImageComparisonResult]
    public let metadataResults: [ImageMetadataResult]
}

public struct MediaInspectionResult: Sendable {
    public let filename: String
    public let report: MediaInspectionReport
}

public struct ImageComparisonResult: Sendable {
    public let source: URL
    public let output: URL
}

public struct ImageMetadataResult: Sendable {
    public let filename: String
    public let removal: ImageMetadataRemoval
}

public enum ToolError: LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

public struct VideoSample: Sendable {
    public let url: URL
    public let estimatedBytes: Int64?
}

public enum ToolRunner {
    public static func run(
        _ tool: Tool, inputs: [URL], destination: URL, imageSize: Int, options: ToolOptions = ToolOptions(),
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> JobReport {
        guard !inputs.isEmpty else { throw ToolError.invalid("Choose at least one file.") }
        if tool.requiresSinglePDF, inputs.count != 1 {
            throw ToolError.invalid("Choose one PDF for this operation.")
        }
        if tool == .resizeImages, options.imageSizing == .longestEdge, !(1...16_384).contains(imageSize) {
            throw ToolError.invalid("Enter an image size between 1 and 16,384 pixels.")
        }

        let manager = FileManager.default
        let id = UUID().uuidString
        let staging = destination.appendingPathComponent(".MacUtilityKit-" + id, isDirectory: true)
        let result = destination.appendingPathComponent(tool.title + " - " + id, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        var outputs: [URL] = []
        var failures: [String] = []
        var summaries: [String] = []
        var inspections: [MediaInspectionResult] = []
        var comparisons: [ImageComparisonResult] = []
        var metadataResults: [ImageMetadataResult] = []

        if tool == .mergePDFs {
            let name = options.pdfOutputName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("/"), !name.contains(":"), name != ".", name != ".." else {
                throw ToolError.invalid("Enter a valid PDF filename.")
            }
            let output = staging.appendingPathComponent(name.lowercased().hasSuffix(".pdf") ? name : name + ".pdf")
            try await PDFOperations.merge(inputs, ranges: options.pageRanges, passwords: options.pdfPasswords, into: output, progress: progress)
            outputs.append(output)
        } else if tool == .splitPDF {
            outputs = try await PDFPageEditing.split(inputs[0], into: staging, options: options.pdfSplit, progress: progress)
        } else if tool == .imagesToPDF {
            let output = staging.appendingPathComponent("Images.pdf")
            try await ImagesToPDF.export(inputs, to: output, options: options.imagesToPDF, progress: progress)
            outputs = [output]
        } else if tool == .pdfToImages {
            outputs = try await PDFToImages.export(inputs[0], into: staging, options: options.pdfToImages, progress: progress)
        } else {
            for (index, input) in inputs.enumerated() {
                try Task.checkCancellation()
                var stagedOutput: URL?
                do {
                    let ext = switch tool {
                    case .resizeImages: options.imageFormat.rawValue
                    case .compressVideo: options.videoFormat.rawValue
                    case .convertVideo: options.conversion.format.rawValue
                    case .mediaInfo: "json"
                    case .extractAudio: options.extraction.format.rawValue
                    case .convertImages: options.imageConversion.format.rawValue
                    case .compressImages: try ImageCompression.outputExtension(input, options: options.imageCompression)
                    case .removeMetadata: try ImageMetadata.outputExtension(input)
                    case .mergePDFs, .splitPDF, .organizePDF, .deletePDFPages, .extractPDFPages, .imagesToPDF: "pdf"
                    case .pdfToImages: options.pdfToImages.format.fileExtension
                    }
                    let output = staging.appendingPathComponent(
                        "\(index + 1) - \(input.deletingPathExtension().lastPathComponent).\(ext)"
                    )
                    stagedOutput = output
                    switch tool {
                    case .resizeImages: try await ImageResizing.resize(input, output: output, imageSize: imageSize, options: options)
                    case .compressVideo:
                        let summary = try await VideoOperations.compress(input, output: output, options: options) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        summaries.append(summary)
                    case .convertVideo:
                        let summary = try await VideoConversion.convert(input, to: output, options: options.conversion) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        summaries.append(summary)
                    case .mediaInfo:
                        let report = try await MediaInspection.inspect(input, options: options.inspection)
                        try report.json.write(to: output)
                        summaries.append("\(input.lastPathComponent)\n\n\(report.summary)")
                        inspections.append(MediaInspectionResult(filename: input.lastPathComponent, report: report))
                    case .extractAudio:
                        let summary = try await AudioExtraction.extract(input, to: output, options: options.extraction) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        summaries.append(summary)
                    case .convertImages:
                        summaries.append(try await ImageConversion.convert(input, to: output, options: options.imageConversion))
                    case .compressImages:
                        summaries.append(try await ImageCompression.compress(input, to: output, options: options.imageCompression))
                        comparisons.append(ImageComparisonResult(source: input, output: result.appendingPathComponent(output.lastPathComponent)))
                    case .removeMetadata:
                        let removal = try await ImageMetadata.remove(input, to: output, options: options.imageMetadata)
                        metadataResults.append(ImageMetadataResult(filename: input.lastPathComponent, removal: removal))
                    case .organizePDF:
                        try await PDFPageEditing.organize(input, to: output, options: options.pdfOrganize, progress: progress)
                    case .deletePDFPages:
                        try await PDFPageEditing.delete(input, to: output, options: options.pdfDelete, progress: progress)
                    case .extractPDFPages:
                        try await PDFPageEditing.extract(input, to: output, options: options.pdfExtract, progress: progress)
                    case .mergePDFs, .splitPDF, .imagesToPDF, .pdfToImages: break
                    }
                    outputs.append(output)
                } catch {
                    try Task.checkCancellation()
                    if let stagedOutput { try? manager.removeItem(at: stagedOutput) }
                    failures.append("\(input.lastPathComponent) — \(error.localizedDescription)")
                }
                await progress(Double(index + 1) / Double(inputs.count))
            }
        }

        try Task.checkCancellation()
        guard !outputs.isEmpty else { return JobReport(outputs: [], failures: failures, summaries: [], inspections: [], imageComparisons: [], metadataResults: []) }
        try manager.moveItem(at: staging, to: result)
        return JobReport(
            outputs: outputs.map { result.appendingPathComponent($0.lastPathComponent) },
            failures: failures, summaries: summaries, inspections: inspections,
            imageComparisons: comparisons, metadataResults: metadataResults
        )
    }

    public static func imagePreview(_ input: URL, longestEdge: Int, options: ToolOptions) throws -> String {
        try ImageResizing.preview(input, longestEdge: longestEdge, options: options)
    }

    public static func sampleVideo(_ input: URL, destination: URL, options: ToolOptions) async throws -> VideoSample {
        try await VideoOperations.sample(input, destination: destination, options: options)
    }
}
