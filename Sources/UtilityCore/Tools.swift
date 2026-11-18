import AppKit
import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public enum Tool: String, CaseIterable, Identifiable, Sendable {
    case resizeImages, mergePDFs, compressVideo

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .resizeImages: "Resize Images"
        case .mergePDFs: "Merge PDFs"
        case .compressVideo: "Compress Video"
        }
    }

    public var category: String {
        switch self {
        case .resizeImages: "Images"
        case .mergePDFs: "Documents"
        case .compressVideo: "Video"
        }
    }

    public var inputTypes: [UTType] {
        switch self {
        case .resizeImages: [.image]
        case .mergePDFs: [.pdf, .image]
        case .compressVideo: [.movie]
        }
    }
}

public struct JobReport: Sendable {
    public let outputs: [URL]
    public let failures: [String]
    public let summaries: [String]
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

        if tool == .mergePDFs {
            let name = options.pdfOutputName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("/"), !name.contains(":"), name != ".", name != ".." else {
                throw ToolError.invalid("Enter a valid PDF filename.")
            }
            let output = staging.appendingPathComponent(name.lowercased().hasSuffix(".pdf") ? name : name + ".pdf")
            try await merge(inputs, ranges: options.pageRanges, passwords: options.pdfPasswords, into: output, progress: progress)
            outputs.append(output)
        } else {
            for (index, input) in inputs.enumerated() {
                try Task.checkCancellation()
                let ext = tool == .resizeImages ? options.imageFormat.rawValue : options.videoFormat.rawValue
                let output = staging.appendingPathComponent(
                    "\(index + 1) - \(input.deletingPathExtension().lastPathComponent).\(ext)"
                )
                do {
                    switch tool {
                    case .resizeImages: try resize(input, output: output, imageSize: imageSize, options: options)
                    case .compressVideo:
                        let summary = try await compress(input, output: output, options: options) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
                        summaries.append(summary)
                    case .mergePDFs: break
                    }
                    outputs.append(output)
                } catch {
                    try Task.checkCancellation()
                    try? manager.removeItem(at: output)
                    failures.append("\(input.lastPathComponent) — \(error.localizedDescription)")
                }
                await progress(Double(index + 1) / Double(inputs.count))
            }
        }

        try Task.checkCancellation()
        guard !outputs.isEmpty else { return JobReport(outputs: [], failures: failures, summaries: []) }
        try manager.moveItem(at: staging, to: result)
        return JobReport(
            outputs: outputs.map { result.appendingPathComponent($0.lastPathComponent) },
            failures: failures, summaries: summaries
        )
    }

    private static func resize(_ input: URL, output: URL, imageSize: Int, options: ToolOptions) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw ToolError.invalid("Could not decode the image.") }

        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let size = try imageDimensions(width: orientation >= 5 ? height : width,
                                       height: orientation >= 5 ? width : height,
                                       longestEdge: imageSize, options: options)
        let scale = options.imageSizing == .dimensions && options.imageFit == .fill
            ? max(Double(size.width) / Double(orientation >= 5 ? height : width),
                  Double(size.height) / Double(orientation >= 5 ? width : height))
            : 0
        let decodeLimit = max(size.width, size.height, Int(min(16_384, ceil(Double(max(width, height)) * scale))))
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: decodeLimit
        ] as CFDictionary),
              let writer = CGImageDestinationCreateWithURL(output as CFURL, options.imageFormat.type.identifier as CFString, 1, nil),
              let context = CGContext(
                data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw ToolError.invalid("Could not prepare the selected image output.") }

        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        if options.imageFormat == .jpg {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
        }
        var drawing = bounds
        if options.imageSizing == .dimensions, options.imageFit == .fill {
            let factor = max(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
            let drawWidth = CGFloat(image.width) * factor
            let drawHeight = CGFloat(image.height) * factor
            drawing = CGRect(x: (bounds.width - drawWidth) / 2, y: (bounds.height - drawHeight) / 2,
                             width: drawWidth, height: drawHeight)
        }
        context.interpolationQuality = .high
        context.draw(image, in: drawing)
        guard let resized = context.makeImage() else { throw ToolError.invalid("Could not resize the image.") }
        CGImageDestinationAddImage(writer, resized, [
            kCGImageDestinationLossyCompressionQuality: options.imageQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else {
            throw ToolError.invalid("Could not write the selected image format.")
        }
    }

    public static func imagePreview(_ input: URL, longestEdge: Int, options: ToolOptions) throws -> String {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { throw ToolError.invalid("Unreadable image") }
        let rotated = (props[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
        let size = try imageDimensions(width: rotated ? height : width, height: rotated ? width : height,
                                       longestEdge: longestEdge, options: options)
        return "\(size.width) × \(size.height)"
    }

    private static func imageDimensions(width: Int, height: Int, longestEdge: Int, options: ToolOptions)
        throws -> (width: Int, height: Int) {
        let limit = 16_384
        guard width > 0, height > 0 else { throw ToolError.invalid("Invalid image dimensions.") }
        let factor: Double
        switch options.imageSizing {
        case .longestEdge:
            guard (1...limit).contains(longestEdge) else { throw ToolError.invalid("Enter an edge from 1 to 16,384 pixels.") }
            factor = Double(longestEdge) / Double(max(width, height))
        case .percentage:
            guard (1...1000).contains(options.imagePercentage) else { throw ToolError.invalid("Enter a percentage from 1 to 1,000.") }
            factor = Double(options.imagePercentage) / 100
        case .dimensions:
            guard (1...limit).contains(options.imageWidth), (1...limit).contains(options.imageHeight)
            else { throw ToolError.invalid("Enter dimensions from 1 to 16,384 pixels.") }
            let x = Double(options.imageWidth) / Double(width)
            let y = Double(options.imageHeight) / Double(height)
            if options.imageFit != .fit {
                let required = max(x, y)
                guard options.upscale || required <= 1 else {
                    throw ToolError.invalid("Enable upscaling or choose smaller dimensions.")
                }
                return try boundedSize(options.imageWidth, options.imageHeight)
            }
            factor = min(x, y)
        }
        let scale = options.upscale ? factor : min(factor, 1)
        return try boundedSize(max(1, Int((Double(width) * scale).rounded())),
                               max(1, Int((Double(height) * scale).rounded())))
    }

    private static func boundedSize(_ width: Int, _ height: Int) throws -> (width: Int, height: Int) {
        guard width <= 16_384, height <= 16_384, width * height <= 64_000_000
        else { throw ToolError.invalid("Output exceeds 16,384 pixels per edge or 64 megapixels.") }
        return (width, height)
    }

    private static func merge(
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

    public static func sampleVideo(_ input: URL, destination: URL, options: ToolOptions) async throws -> VideoSample {
        let folder = destination.appendingPathComponent("Video Sample - " + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let output = folder.appendingPathComponent("Preview." + options.videoFormat.rawValue)
        do {
            _ = try await compress(input, output: output, options: options, sample: true) { _ in }
            let originalDuration = try await AVURLAsset(url: input).load(.duration).seconds
            let sampleDuration = try await AVURLAsset(url: output).load(.duration).seconds
            let bytes = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize
            let estimate = bytes.flatMap { size -> Int64? in
                guard originalDuration.isFinite, sampleDuration.isFinite, sampleDuration > 0 else { return nil }
                return Int64(exactly: (Double(size) * originalDuration / sampleDuration).rounded())
            }
            return VideoSample(url: output, estimatedBytes: estimate)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private static func compress(
        _ input: URL, output: URL, options: ToolOptions, sample: Bool = false, progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        let asset = AVURLAsset(url: input)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: options.videoCodec.preset(for: options.videoQuality)),
              exporter.supportedFileTypes.contains(options.videoFormat.fileType)
        else { throw ToolError.invalid("This video cannot be exported with the selected format and quality.") }
        if sample {
            let duration = try await asset.load(.duration)
            guard duration.seconds.isFinite, duration.seconds > 0 else {
                throw ToolError.invalid("Could not determine the video duration.")
            }
            exporter.timeRange = CMTimeRange(
                start: .zero, duration: min(duration, CMTime(seconds: 5, preferredTimescale: 600))
            )
        }
        let states = exporter.states(updateInterval: 0.2)
        let observer = Task {
            for await state in states {
                if case .exporting(let status) = state {
                    await progress(status.fractionCompleted)
                }
            }
        }
        defer { observer.cancel() }
        try await exporter.export(to: output, as: options.videoFormat.fileType)
        if sample { return output.lastPathComponent }
        let sourceSize = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let outputSize = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if let sourceSize, let outputSize, outputSize >= sourceSize, !options.keepLargerVideos {
            throw ToolError.invalid("The export is not smaller. Enable Keep exports that are not smaller to retain it.")
        }
        guard let sourceSize, let outputSize, sourceSize > 0 else { return input.lastPathComponent }
        let change = Double(sourceSize - outputSize) / Double(sourceSize)
        let description = abs(change).formatted(.percent.precision(.fractionLength(1)))
            + (change >= 0 ? " saved" : " larger")
        return "\(input.lastPathComponent) • \(ByteCountFormatter.string(fromByteCount: Int64(sourceSize), countStyle: .file)) → \(ByteCountFormatter.string(fromByteCount: Int64(outputSize), countStyle: .file)) • \(description)"
    }
}
