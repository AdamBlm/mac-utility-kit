import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public struct WatermarkOptions: Equatable, Sendable {
    public enum Content: String, CaseIterable, Identifiable, Sendable {
        case text = "Text"
        case logo = "Logo"
        public var id: Self { self }
    }

    public enum Placement: String, CaseIterable, Identifiable, Sendable {
        case topLeft = "Top left", top = "Top", topRight = "Top right"
        case left = "Left", center = "Center", right = "Right"
        case bottomLeft = "Bottom left", bottom = "Bottom", bottomRight = "Bottom right"
        case tile = "Tiled"
        public var id: Self { self }
    }

    public var content = Content.text
    public var text = ""
    public var logo: URL?
    public var textColor: UInt32 = 0xFFFFFF
    public var placement = Placement.bottomRight
    public var scale = 0.24
    public var opacity = 0.6
    public var margin = 0.035
    public var rotation = 0.0
    public var pdfPages = ""
    public var videoStart = 0.0
    public var videoEnd: Double?
    public var ffmpegExecutable: URL?

    public init() {}
}

public enum Watermark {
    public enum InputKind: Sendable { case image, pdf, video }

    public struct InputInfo: Sendable {
        public let kind: InputKind
        public let pageCount: Int?
        public let duration: Double?
    }

    public static func inputKind(_ url: URL) throws -> InputKind {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else {
            throw ToolError.invalid("Choose a local image, PDF, or supported video.")
        }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        throw ToolError.invalid("Choose a local image, PDF, or supported video.")
    }

    public static func outputExtension(_ input: URL) throws -> String {
        switch try inputKind(input) {
        case .image: "png"
        case .pdf: "pdf"
        case .video: "mp4"
        }
    }

    public static func inspect(_ input: URL) async throws -> InputInfo {
        switch try inputKind(input) {
        case .image: InputInfo(kind: .image, pageCount: nil, duration: nil)
        case .pdf: InputInfo(kind: .pdf, pageCount: try PDFWatermark.open(input).pageCount, duration: nil)
        case .video: InputInfo(kind: .video, pageCount: nil, duration: try await VideoWatermark.source(input).duration)
        }
    }

    public static func preview(_ input: URL, page: Int = 1, seconds: Double = 0, options: WatermarkOptions) async throws -> CGImage {
        let mark = try WatermarkArtwork(options: options)
        switch try inputKind(input) {
        case .image:
            let source = try ImageRedaction.load(input)
            return try WatermarkCanvas.composite(source.image, mark: mark, options: options, maxEdge: 880)
        case .pdf:
            return try PDFWatermark.preview(input, page: page, mark: mark, options: options)
        case .video:
            return try await VideoWatermark.preview(input, seconds: seconds, mark: mark, options: options)
        }
    }

    public static func export(
        _ input: URL, to output: URL, options: WatermarkOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        guard input.isFileURL, output.isFileURL, input.standardizedFileURL != output.standardizedFileURL,
              !FileManager.default.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a new output file.")
        }
        try Task.checkCancellation()
        let mark = try WatermarkArtwork(options: options)
        switch try inputKind(input) {
        case .image:
            let source = try ImageRedaction.load(input)
            let rendered = try WatermarkCanvas.composite(source.image, mark: mark, options: options)
            try ImageRedaction.writePNG(rendered, to: output)
            await progress(1)
            return "\(input.lastPathComponent) · \(rendered.width) × \(rendered.height) · PNG"
        case .pdf:
            return try await PDFWatermark.export(input, to: output, mark: mark, options: options, progress: progress)
        case .video:
            return try await VideoWatermark.export(input, to: output, mark: mark, options: options, progress: progress)
        }
    }
}
