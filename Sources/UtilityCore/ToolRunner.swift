import Foundation

public struct JobReport: Sendable {
    public package(set) var outputs: [URL]
    public let failures: [String]
    public package(set) var summaries: [String]
    public let textExtractions: [ExtractedTextFile]
    public let inspections: [MediaInspectionResult]
    public let imageComparisons: [ImageComparisonResult]
    public let metadataResults: [ImageMetadataResult]
    package var videoReviews: [VideoCompressionReview] = []
}

public struct ExtractedTextFile: Sendable {
    public let source: URL
    public let result: TextExtractionResult
    package let inputLabel: String

    package static func captured(source: URL, text: String) -> Self {
        let image = TextExtractionPage(pageNumber: nil, text: text, error: nil)
        return Self(source: source, result: TextExtractionResult(pages: [image], text: text),
                    inputLabel: source.lastPathComponent)
    }
}

public struct MediaInspectionResult: Sendable {
    public let filename: String
    package let inputLabel: String
    public let report: MediaInspectionReport
}

public struct ImageComparisonResult: Sendable {
    public let source: URL
    package let sourceVersion: LocalInputFile.Version
    package let inputLabel: String
    public let output: URL
    public let sourceBytes: Int?
    public let outputBytes: Int?
}

public struct ImageMetadataResult: Sendable {
    public let filename: String
    package let inputLabel: String
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
    package static func inputLabels(_ inputs: [URL]) -> [String] {
        let names = inputs.map(\.lastPathComponent)
        guard Set(names).count < names.count else { return names }
        return names.enumerated().map { index, name in "\(index + 1) - \(name)" }
    }

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
        try manager.createDirectory(at: staging, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        var outputs: [URL] = []
        var failures: [String] = []
        var summaries: [String] = []
        var textExtractions: [ExtractedTextFile] = []
        var inspections: [MediaInspectionResult] = []
        var comparisons: [ImageComparisonResult] = []
        var metadataResults: [ImageMetadataResult] = []
        var videoReviews: [VideoCompressionReview] = []
        var convertedDocumentNames: Set<String> = []

        if tool == .mergePDFs {
            let filename = try PDFMergePlan.outputFilename(options.pdfOutputName)
            let output = staging.appendingPathComponent(filename)
            try await PDFOperations.merge(inputs, ranges: options.pageRanges, passwords: options.pdfPasswords,
                                          order: options.pdfMergeOrder, stamps: options.pdfMergeSourceStamps,
                                          into: output, progress: progress)
            outputs.append(output)
        } else if tool == .mergeVideos {
            let output = staging.appendingPathComponent("Merged.\(options.videoMerge.format.rawValue)")
            let summary = try await VideoMerge.export(inputs, to: output, options: options.videoMerge, progress: progress)
            outputs = [output]
            summaries = [summary]
        } else if tool == .mergeAudio {
            let output = staging.appendingPathComponent("Merged.\(options.audioMerge.format.rawValue)")
            let summary = try await AudioMerge.export(inputs, to: output, options: options.audioMerge, progress: progress)
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
            let soundtrack = tool == .replaceAudio
                ? Result { try ReplaceAudio.Soundtrack(options.replaceAudio) }
                : nil
            let artwork = tool == .watermark ? Result { try WatermarkArtwork(options: options.watermark) } : nil
            let labels = inputLabels(inputs)
            for (index, input) in inputs.enumerated() {
                let label = labels[index]
                try Task.checkCancellation()
                var stagedOutput: URL?
                do {
                    if tool == .extractFrames {
                        let folder = staging.appendingPathComponent(
                            OutputFilename.numberedSource(input, position: index + 1), isDirectory: true
                        )
                        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
                        stagedOutput = folder
                        let frames = try await FrameExtraction.export(input, into: folder, options: options.frames) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        outputs.append(contentsOf: frames.outputs)
                        failures.append(contentsOf: frames.failures.map { "\(label) — \($0)" })
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
                    case .mergeAudio: options.audioMerge.format.rawValue
                    case .convertAudio: options.audioConvert.format.rawValue
                    case .cleanUpAudio: options.audioCleanup.output.rawValue
                    case .convertImages: options.imageConversion.format.rawValue
                    case .rotateImages: try ImageRotate.outputExtension(input, options: options.rotation)
                    case .beautifyScreenshot: options.beautify.format.fileExtension
                    case .blurFaces, .redactImage: "png"
                    case .removeBackground: options.removeBackground.format.fileExtension
                    case .watermark: try Watermark.outputExtension(input)
                    case .compressImages: try ImageCompression.outputExtension(input, options: options.imageCompression)
                    case .removeMetadata: try ImageMetadata.outputExtension(input)
                    case .mergePDFs, .splitPDF, .organizePDF, .deletePDFPages, .extractPDFPages, .imagesToPDF, .signPDF, .makePDFSearchable, .compressPDF, .cropPDF, .wordToPDF, .powerPointToPDF, .excelToPDF: "pdf"
                    case .convertDocuments: options.documents.target.fileExtension
                    case .pdfToWord: "docx"
                    case .extractText: "txt"
                    case .batchFindReplace, .extractSubtitles, .wordCounter, .qrCode, .batchRename, .keepAwake, .jsonFormatter, .base64, .hashGenerator, .uuidGenerator, .cleanLinks, .timestampConverter, .loremIpsum, .unicodeInspector, .diffChecker, .regexTester, .csvJSON, .coordinatePicker, .jwtDecoder, .passwordGenerator, .batteryHealth, .diskSpeedTest, .deadPixelTest, .ejectAllDisks, .presentationMode, .networkSpeedTest, .storageExplorer, .clipboardHistory, .resetPermissions, .appDamageDiagnosis, .loginBackgroundItems, .hiddenSettings, .cleanKeyboard, .wifiPasswordQR, .uninstallApp, .displayControl, .mouseFixes, .organizeDownloads, .fillFlattenForms, .scanDocument, .findDuplicates, .zipUnzip, .summarize, .caseConverter, .translate, .askDocument, .transcribe, .captureText, .textToSpeech, .recordAudio, .screenshot, .annotateScreenshot, .recordScreen, .downloadVideo, .colorPicker, .markdownToPDF, .webPageToPDF, .addPassword, .removePassword, .redactPDF:
                        throw ToolError.invalid("Open \(tool.title) to use its interactive controls.")
                    case .pdfToImages: options.pdfToImages.format.fileExtension
                    }
                    let filename: String
                    if tool == .convertDocuments {
                        let stem = try DocumentConvert.outputStem(input, position: index + 1, options: options.documents)
                        filename = "\(stem).\(ext)"
                    } else {
                        filename = OutputFilename.numberedSource(input, position: index + 1, suffix: ".\(ext)")
                    }
                    let output = staging.appendingPathComponent(filename)
                    let documentNameKey = tool == .convertDocuments ? DocumentConvert.outputFilenameKey(filename) : nil
                    guard documentNameKey.map({ !convertedDocumentNames.contains($0) }) ?? true,
                          !manager.fileExists(atPath: output.path) else {
                        throw ToolError.invalid("The output name is already in use. Add {index} to the filename template to give each file a unique name.")
                    }
                    stagedOutput = output
                    switch tool {
                    case .resizeImages:
                        let version = try LocalInputFile.Version.read(input)
                        try await ImageResizing.resize(version.resolved, output: output, imageSize: imageSize, options: options)
                        guard (try? LocalInputFile.Version.read(input)) == version else {
                            throw ToolError.invalid("The source image changed during resizing. Try again.")
                        }
                    case .compressVideo:
                        let version = try LocalInputFile.Version.read(input)
                        try await VideoOperations.compress(version.resolved, output: output, options: options) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        guard (try? LocalInputFile.Version.read(input)) == version else {
                            throw ToolError.invalid("The source video changed during compression. Try again.")
                        }
                        let sizes = try VideoCompressionSizes(inputLabel: label, sourceBytes: version.stamp.bytes, output: output)
                        if sizes.needsReview, !options.keepLargerVideos {
                            guard options.reviewLargerVideos else {
                                throw ToolError.invalid("The export is not smaller. Enable keeping larger exports to retain it.")
                            }
                            let review = try VideoCompressionReview(staged: output, destination: destination, summary: sizes.summary)
                            videoReviews.append(review)
                            await progress(Double(index + 1) / Double(inputs.count))
                            continue
                        }
                        summaries.append(sizes.summary)
                    case .convertVideo:
                        if options.videoPassthroughRecheck.contains(index) {
                            do {
                                try await VideoConversion.checkPassthrough(input, options: options.conversion)
                            } catch {
                                try Task.checkCancellation()
                                throw ToolError.invalid("Passthrough check failed: \(error.localizedDescription)")
                            }
                        }
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
                        let reviewedSource = options.trimSourceVersions?[index]
                        if options.trimSourceVersions != nil, reviewedSource == nil {
                            throw ToolError.invalid("The video was not available for review. Remove it and add it again.")
                        }
                        let summary = try await TrimVideo.export(input, to: output, options: options.trim,
                                                                 reviewedSource: reviewedSource) { fraction in
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
                        guard let soundtrack else { throw ToolError.invalid("Choose an audio file.") }
                        let summary = try await ReplaceAudio.export(input, to: output, options: options.replaceAudio,
                                                                    soundtrack: try soundtrack.get()) { fraction in
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
                        summaries.append("\(label)\n\n\(report.summary)")
                        inspections.append(MediaInspectionResult(filename: input.lastPathComponent, inputLabel: label, report: report))
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
                    case .watermark:
                        guard let artwork else { throw ToolError.invalid("Choose a watermark.") }
                        let summary = try await Watermark.export(input, to: output, mark: try artwork.get(),
                                                                 options: options.watermark) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        summaries.append(summary)
                    case .convertImages:
                        summaries.append(try await ImageConversion.convert(input, to: output, options: options.imageConversion))
                    case .compressImages:
                        let version = try LocalInputFile.Version.read(input)
                        let summary = try await ImageCompression.compress(input, to: output, options: options.imageCompression)
                        guard (try? LocalInputFile.Version.read(input)) == version else {
                            throw ToolError.invalid("The source image changed during compression. Try again.")
                        }
                        summaries.append(summary)
                        comparisons.append(ImageComparisonResult(
                            source: input, sourceVersion: version, inputLabel: label,
                            output: result.appendingPathComponent(output.lastPathComponent),
                            sourceBytes: Int(exactly: version.stamp.bytes),
                            outputBytes: try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize
                        ))
                    case .removeMetadata:
                        let removal = try await ImageMetadata.remove(input, to: output, options: options.imageMetadata)
                        metadataResults.append(ImageMetadataResult(filename: input.lastPathComponent, inputLabel: label, removal: removal))
                    case .organizePDF:
                        try await PDFPageEditing.organize(input, to: output, options: options.pdfOrganize, progress: progress)
                    case .deletePDFPages:
                        try await PDFPageEditing.delete(input, to: output, options: options.pdfDelete, progress: progress)
                    case .extractPDFPages:
                        try await PDFPageEditing.extract(input, to: output, options: options.pdfExtract, progress: progress)
                    case .signPDF:
                        try await PDFSigning.sign(input, to: output, options: options.pdfSignature, progress: progress)
                    case .wordToPDF, .powerPointToPDF, .excelToPDF:
                        guard let kind = tool.officePDFKind else { throw ToolError.invalid("Unsupported Office PDF conversion.") }
                        let summary = try await OfficePDF.export(input, to: output, kind: kind, options: options.officePDF) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        summaries.append(summary)
                    case .pdfToWord:
                        let summary = try await PDFToWord.export(input, to: output, options: options.pdfToWord) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        summaries.append(summary)
                    case .convertDocuments:
                        let summary = try await DocumentConvert.export(input, to: output, options: options.documents) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        summaries.append(summary)
                    case .cropPDF:
                        let summary = try await PDFCrop.export(input, to: output, options: options.pdfCrop) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        summaries.append(summary)
                    case .compressPDF:
                        let summary = try await PDFCompression.export(input, to: output, options: options.pdfCompression) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        summaries.append(summary)
                    case .makePDFSearchable:
                        let report = try await SearchablePDF.export(input, to: output, options: options.searchablePDF) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        summaries.append("\(label) · \(report.summary)")
                        failures.append(contentsOf: report.warnings.map { "\(label) — \($0)" })
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
                        textExtractions.append(ExtractedTextFile(source: input, result: extracted, inputLabel: label))
                        failures.append(contentsOf: pageFailures.map { "\(label) — \($0)" })
                    case .mergePDFs, .splitPDF, .imagesToPDF, .pdfToImages, .extractFrames, .mergeVideos, .mergeAudio,
                         .batchFindReplace, .extractSubtitles, .wordCounter, .qrCode, .batchRename, .keepAwake, .jsonFormatter, .base64, .hashGenerator, .uuidGenerator, .cleanLinks, .timestampConverter, .loremIpsum, .unicodeInspector, .diffChecker, .regexTester, .csvJSON, .coordinatePicker, .jwtDecoder, .passwordGenerator, .batteryHealth, .diskSpeedTest, .deadPixelTest, .ejectAllDisks, .presentationMode, .networkSpeedTest, .storageExplorer, .clipboardHistory, .resetPermissions, .appDamageDiagnosis, .loginBackgroundItems, .hiddenSettings, .cleanKeyboard, .wifiPasswordQR, .uninstallApp, .displayControl, .mouseFixes, .organizeDownloads, .fillFlattenForms, .scanDocument, .findDuplicates, .zipUnzip, .summarize, .caseConverter, .translate, .askDocument, .transcribe, .captureText, .textToSpeech, .recordAudio, .screenshot, .annotateScreenshot, .recordScreen, .downloadVideo, .colorPicker, .markdownToPDF, .webPageToPDF, .addPassword, .removePassword, .redactPDF:
                        break
                    }
                    outputs.append(output)
                    if let documentNameKey { convertedDocumentNames.insert(documentNameKey) }
                } catch {
                    try Task.checkCancellation()
                    if let stagedOutput { try? manager.removeItem(at: stagedOutput) }
                    failures.append("\(label) — \(error.localizedDescription)")
                }
                await progress(Double(index + 1) / Double(inputs.count))
            }
        }

        return JobReport(
            outputs: try publish(outputs, from: staging, to: result),
            failures: failures, summaries: summaries, textExtractions: textExtractions, inspections: inspections,
            imageComparisons: comparisons, metadataResults: metadataResults, videoReviews: videoReviews
        )
    }

    private static func publish(_ outputs: [URL], from staging: URL, to destination: URL) throws -> [URL] {
        try Task.checkCancellation()
        guard !outputs.isEmpty else { return [] }
        let manager = FileManager.default
        let publication = staging.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(at: publication, withIntermediateDirectories: false)

        var published: [URL] = []
        for output in outputs {
            try Task.checkCancellation()
            let components = output.pathComponents
            let relative = components.dropFirst(staging.pathComponents.count)
            guard components.starts(with: staging.pathComponents), !relative.isEmpty,
                  !relative.contains(".."),
                  try output.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw ToolError.invalid("Could not publish the expected output file.")
            }
            let path = relative.joined(separator: "/")
            let target = publication.appending(path: path, directoryHint: .notDirectory)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: output, to: target)
            published.append(destination.appending(path: path, directoryHint: .notDirectory))
        }
        try Task.checkCancellation()
        try manager.moveItem(at: publication, to: destination)
        return published
    }

    package static func imageResizeEngineIssue(_ options: ToolOptions) -> String? {
        ImageResizing.engineIssue(options)
    }

    public static func imagePreview(_ input: URL, longestEdge: Int, options: ToolOptions) throws -> String {
        try ImageResizing.preview(input, longestEdge: longestEdge, options: options)
    }

    public static func sampleVideo(_ input: URL, destination: URL, options: ToolOptions) async throws -> VideoSample {
        try await VideoOperations.sample(input, destination: destination, options: options)
    }
}
