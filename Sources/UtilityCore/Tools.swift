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
}

public enum ToolError: LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

public enum ToolRunner {
    public static func run(
        _ tool: Tool, inputs: [URL], destination: URL, imageSize: Int,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> JobReport {
        guard !inputs.isEmpty else { throw ToolError.invalid("Choose at least one file.") }
        if tool == .resizeImages, !(1...16_384).contains(imageSize) {
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

        if tool == .mergePDFs {
            let output = staging.appendingPathComponent("Merged.pdf")
            try await merge(inputs, into: output, progress: progress)
            outputs.append(output)
        } else {
            for (index, input) in inputs.enumerated() {
                try Task.checkCancellation()
                let ext = tool == .resizeImages ? "png" : "mp4"
                let output = staging.appendingPathComponent(
                    "\(index + 1) - \(input.deletingPathExtension().lastPathComponent).\(ext)"
                )
                do {
                    switch tool {
                    case .resizeImages: try resize(input, output: output, imageSize: imageSize)
                    case .compressVideo:
                        try await compress(input, output: output) { fraction in
                            await progress((Double(index) + fraction) / Double(inputs.count))
                        }
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
        guard !outputs.isEmpty else { return JobReport(outputs: [], failures: failures) }
        try manager.moveItem(at: staging, to: result)
        return JobReport(
            outputs: outputs.map { result.appendingPathComponent($0.lastPathComponent) },
            failures: failures
        )
    }

    private static func resize(_ input: URL, output: URL, imageSize: Int) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: imageSize
              ] as CFDictionary),
              let writer = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ToolError.invalid("Could not decode the image.") }

        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else {
            throw ToolError.invalid("Could not write the PNG.")
        }
    }

    private static func merge(
        _ inputs: [URL], into output: URL, progress: @Sendable (Double) async -> Void
    ) async throws {
        let result = PDFDocument()
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            try append(input, to: result)
            await progress(Double(index + 1) / Double(inputs.count + 1))
        }
        guard result.write(to: output) else { throw ToolError.invalid("Could not write the PDF.") }
        await progress(1)
    }

    private static func append(_ input: URL, to result: PDFDocument) throws {
        let type = try input.resourceValues(forKeys: [.contentTypeKey]).contentType
        if type?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(url: input), !document.isLocked, document.pageCount > 0 else {
                throw ToolError.invalid("Could not open \(input.lastPathComponent) as an unlocked PDF.")
            }
            for pageIndex in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: pageIndex) else {
                    throw ToolError.invalid("Could not read a page in \(input.lastPathComponent).")
                }
                result.insert(page, at: result.pageCount)
            }
        } else if let image = NSImage(contentsOf: input), let page = PDFPage(image: image) {
            result.insert(page, at: result.pageCount)
        } else {
            throw ToolError.invalid("Could not read \(input.lastPathComponent). Check whether it is damaged or locked.")
        }
    }

    private static func compress(
        _ input: URL, output: URL, progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let asset = AVURLAsset(url: input)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality),
              exporter.supportedFileTypes.contains(.mp4)
        else { throw ToolError.invalid("This video cannot be exported as MP4.") }
        let states = exporter.states(updateInterval: 0.2)
        let observer = Task {
            for await state in states {
                if case .exporting(let status) = state {
                    await progress(status.fractionCompleted)
                }
            }
        }
        defer { observer.cancel() }
        try await exporter.export(to: output, as: .mp4)
        let sourceSize = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let outputSize = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if let sourceSize, let outputSize, outputSize >= sourceSize {
            throw ToolError.invalid("The compressed video would not be smaller than the original.")
        }
    }
}
