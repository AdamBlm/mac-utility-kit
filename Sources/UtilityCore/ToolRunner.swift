import Foundation

public struct JobReport: Sendable {
    public let outputs: [URL]
    public let failures: [String]
    public let summaries: [String]
    public let textExtractions: [ExtractedTextFile]
    public let inspections: [MediaInspectionResult]
    public let imageComparisons: [ImageComparisonResult]
    public let metadataResults: [ImageMetadataResult]
}

public struct ExtractedTextFile: Sendable {
    public let source: URL
    public let result: TextExtractionResult
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
        guard !tool.usesInteractiveEditor else {
            throw ToolError.invalid("Open \(tool.title) to use its interactive controls.")
        }
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
        var textExtractions: [ExtractedTextFile] = []
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
        } else if tool == .mergeVideos {
            let output = staging.appendingPathComponent("Merged.\(options.videoMerge.format.rawValue)")
            let summary = try await VideoMerge.export(inputs, to: output, options: options.videoMerge, progress: progress)
            outputs = [output]
            summaries = [summary]
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
                    if tool == .extractFrames {
                        let folder = staging.appendingPathComponent(
                            "\(index + 1) - \(input.deletingPathExtension().lastPathComponent)", isDirectory: true
                        )
                        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
                        stagedOutput = folder
                        let frames = try await FrameExtraction.export(input, into: folder, options: options.frames) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        outputs.append(contentsOf: frames.outputs)
                        failures.append(contentsOf: frames.failures.map { "\(input.lastPathComponent) — \($0)" })
                        if frames.outputs.isEmpty { try manager.removeItem(at: folder) }
                        await progress(Double(index + 1) / Double(inputs.count))
                        continue
                    }
                    let ext = switch tool {
                    case .resizeImages: options.imageFormat.rawValue
                    case .compressVideo: options.videoFormat.rawValue
                    case .convertVideo: options.conversion.format.rawValue
                    case .changeSpeed, .resizeVideo, .cropRotateVideo, .replaceAudio, .burnSubtitles: "mp4"
                    case .videoToGIF: "gif"
                    case .mergeVideos: options.videoMerge.format.rawValue
                    case .trimVideo: options.trim.fileExtension
                    case .muteVideo: try MuteVideo.outputExtension(input, options: options.mute)
                    case .extractFrames: throw ToolError.invalid("Frame extraction requires an output directory.")
                    case .mediaInfo: "json"
                    case .extractAudio: options.extraction.format.rawValue
                    case .trimAudio: options.audioTrim.format.rawValue
                    case .convertAudio: options.audioConvert.format.rawValue
                    case .cleanUpAudio: options.audioCleanup.output.rawValue
                    case .convertImages: options.imageConversion.format.rawValue
                    case .rotateImages: try ImageRotate.outputExtension(input, options: options.rotation)
                    case .beautifyScreenshot: options.beautify.format.fileExtension
                    case .blurFaces, .redactImage: "png"
                    case .removeBackground: options.removeBackground.format.fileExtension
                    case .compressImages: try ImageCompression.outputExtension(input, options: options.imageCompression)
                    case .removeMetadata: try ImageMetadata.outputExtension(input)
                    case .mergePDFs, .splitPDF, .organizePDF, .deletePDFPages, .extractPDFPages, .imagesToPDF, .signPDF: "pdf"
                    case .extractText: "txt"
                    case .wordCounter, .qrCode, .batchRename, .keepAwake, .jsonFormatter, .base64, .hashGenerator, .transcribe, .captureText, .textToSpeech, .recordAudio, .screenshot, .annotateScreenshot, .recordScreen, .downloadVideo:
                        throw ToolError.invalid("Open \(tool.title) to use its interactive controls.")
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
                    case .changeSpeed:
                        let summary = try await ChangeSpeed.export(input, to: output, options: options.speed) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        summaries.append(summary)
                    case .trimVideo:
                        let summary = try await TrimVideo.export(input, to: output, options: options.trim) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        summaries.append(summary)
                    case .muteVideo:
                        let summary = try await MuteVideo.export(input, to: output, options: options.mute) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        summaries.append(summary)
                    case .resizeVideo:
                        let summary = try await VideoResize.export(input, to: output, options: options.videoResize) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        summaries.append(summary)
                    case .videoToGIF:
                        let summary = try await VideoGIF.export(input, to: output, options: options.videoGIF) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        summaries.append(summary)
                    case .cropRotateVideo:
                        let summary = try await VideoCrop.export(input, to: output, options: options.crop) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        summaries.append(summary)
                    case .replaceAudio:
                        let summary = try await ReplaceAudio.export(input, to: output, options: options.replaceAudio) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        summaries.append(summary)
                    case .burnSubtitles:
                        let summary = try await BurnSubtitles.export(input, to: output, options: options.burnSubtitles) { fraction in
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
                    case .trimAudio:
                        let summary = try await AudioTrim.export(input, to: output, options: options.audioTrim) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        summaries.append(summary)
                    case .convertAudio:
                        let summary = try await AudioConvert.export(input, to: output, options: options.audioConvert) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        summaries.append(summary)
                    case .cleanUpAudio:
                        let summary = try await AudioCleanup.export(input, to: output, options: options.audioCleanup) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        summaries.append(summary)
                    case .rotateImages:
                        summaries.append(try ImageRotate.export(input, to: output, options: options.rotation))
                    case .beautifyScreenshot:
                        let summary = try await BeautifyScreenshot.export(input, to: output, options: options.beautify) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        summaries.append(summary)
                    case .blurFaces:
                        summaries.append(try BlurFaces.export(input, to: output, options: options.blurFaces))
                    case .redactImage:
                        summaries.append(try ImageRedact.export(input, to: output, options: options.redactImage))
                    case .removeBackground:
                        summaries.append(try await RemoveBackground.export(input, to: output, options: options.removeBackground))
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
                    case .signPDF:
                        try await PDFSigning.sign(input, to: output, options: options.pdfSignature, progress: progress)
                    case .extractText:
                        let extracted = try await TextExtraction.extract(input, options: options.textExtraction) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        let pageFailures = extracted.pages.compactMap { page -> String? in
                            guard let error = page.error else { return nil }
                            let label = page.pageNumber.map { "Page \($0): " } ?? ""
                            return label + error
                        }
                        guard pageFailures.count < extracted.pages.count else {
                            throw ToolError.invalid(pageFailures.joined(separator: " · "))
                        }
                        try Data(extracted.text.utf8).write(to: output)
                        textExtractions.append(ExtractedTextFile(source: input, result: extracted))
                        failures.append(contentsOf: pageFailures.map { "\(input.lastPathComponent) — \($0)" })
                    case .mergePDFs, .splitPDF, .imagesToPDF, .pdfToImages, .extractFrames, .mergeVideos,
                         .wordCounter, .qrCode, .batchRename, .keepAwake, .jsonFormatter, .base64, .hashGenerator, .transcribe, .captureText, .textToSpeech, .recordAudio, .screenshot, .annotateScreenshot, .recordScreen, .downloadVideo:
                        break
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
        guard !outputs.isEmpty else { return JobReport(outputs: [], failures: failures, summaries: [], textExtractions: [], inspections: [], imageComparisons: [], metadataResults: []) }
        try manager.moveItem(at: staging, to: result)
        return JobReport(
            outputs: outputs.map {
                $0.pathComponents.dropFirst(staging.pathComponents.count).reduce(result) { directory, component in
                    directory.appendingPathComponent(component)
                }
            },
            failures: failures, summaries: summaries, textExtractions: textExtractions, inspections: inspections,
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
