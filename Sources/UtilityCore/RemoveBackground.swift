import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

public struct ForegroundRefinement: Equatable, Identifiable, Sendable {
    public enum Action: String, CaseIterable, Identifiable, Sendable {
        case keep = "Keep"
        case remove = "Remove"

        public var id: Self { self }
    }

    public enum Shape: Equatable, Sendable {
        case rectangle(ImageMaskRegion)
        case brush(ForegroundBrushStroke)
    }

    public var id: UUID {
        switch shape {
        case .rectangle(let region): region.id
        case .brush(let stroke): stroke.id
        }
    }

    public var region: ImageMaskRegion? {
        if case .rectangle(let region) = shape { return region }
        return nil
    }

    public let shape: Shape
    public var action: Action

    public init(region: ImageMaskRegion, action: Action) {
        shape = .rectangle(region)
        self.action = action
    }

    public init(stroke: ForegroundBrushStroke, action: Action) {
        shape = .brush(stroke)
        self.action = action
    }
}

public struct RemoveBackgroundEdit: Equatable, Sendable {
    public static let maximumCorrections = 256

    /// nil keeps every automatic subject. An empty set starts with a blank mask.
    public var subjects: IndexSet?
    public var refinements: [ForegroundRefinement] = []

    public init() {}
}

public struct RemoveBackgroundOptions: Equatable, Sendable {
    public enum Format: String, CaseIterable, Identifiable, Sendable {
        case png = "PNG"
        case jpeg = "JPEG"

        public var id: Self { self }
        public var fileExtension: String { self == .png ? "png" : "jpg" }
    }

    public enum Background: String, CaseIterable, Identifiable, Sendable {
        case transparent = "Transparent"
        case solid = "Solid"

        public var id: Self { self }
    }

    private struct DocumentEdit: Equatable, Sendable {
        var digest: String
        var edit: RemoveBackgroundEdit
    }

    private var documentEdits: [URL: DocumentEdit] = [:]
    public var background = Background.transparent
    public var backgroundColor: UInt32 = 0xFFFFFF
    public var format = Format.png
    public var quality = 0.93

    public init() {}

    public func edit(for input: URL, analysis: RemoveBackground.Analysis) -> RemoveBackgroundEdit {
        guard let current = documentEdits[input], current.digest == analysis.source.digest else { return .init() }
        return current.edit
    }

    public mutating func discardIfChanged(_ input: URL, analysis: RemoveBackground.Analysis) {
        if let current = documentEdits[input], current.digest != analysis.source.digest { documentEdits[input] = nil }
    }

    public mutating func apply(_ edit: RemoveBackgroundEdit, to input: URL, analysis: RemoveBackground.Analysis) {
        documentEdits[input] = DocumentEdit(digest: analysis.source.digest, edit: edit)
    }

    func exportEdit(for input: URL, analysis: RemoveBackground.Analysis) throws -> RemoveBackgroundEdit {
        if let current = documentEdits[input], current.digest != analysis.source.digest {
            throw ToolError.invalid("The source changed. Reopen it before exporting the edited mask.")
        }
        return edit(for: input, analysis: analysis)
    }
}

public enum RemoveBackground {
    /// Vision's mutable request state stays behind the lock. Its generated mask
    /// is passed to Core Image as a read-only image and retained with its buffer.
    public final class Analysis: @unchecked Sendable {
        public let source: ImageRedaction.Source
        public let subjects: IndexSet
        public let detectionIssue: String?

        private let lock = NSLock()
        private let observation: VNInstanceMaskObservation?
        private let handler: VNImageRequestHandler
        private var previousSelection: IndexSet?
        private var previousMask: CIImage?

        fileprivate init(source: ImageRedaction.Source, observation: VNInstanceMaskObservation?, handler: VNImageRequestHandler, detectionIssue: String? = nil) {
            self.source = source
            self.observation = observation
            self.handler = handler
            self.subjects = observation?.allInstances ?? []
            self.detectionIssue = detectionIssue
        }

        fileprivate func mask(for selected: IndexSet) throws -> CIImage? {
            guard !selected.isEmpty else { return nil }
            guard selected.isSubset(of: subjects), let observation else {
                throw ToolError.invalid("The selected subjects are no longer available.")
            }
            return try lock.withLock {
                try Task.checkCancellation()
                if previousSelection == selected { return previousMask }
                let buffer = try observation.generateScaledMaskForImage(forInstances: selected, from: handler)
                let mask = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
                previousSelection = selected
                previousMask = mask
                return mask
            }
        }
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    public static func analyze(_ input: URL) throws -> Analysis {
        let source = try ImageRedaction.load(input)
        try Task.checkCancellation()
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: source.image, orientation: .up)
        do {
            try handler.perform([request])
        } catch {
            try Task.checkCancellation()
            return Analysis(source: source, observation: nil, handler: handler, detectionIssue: error.localizedDescription)
        }
        try Task.checkCancellation()
        return Analysis(source: source, observation: request.results?.first, handler: handler)
    }

    public static func preview(
        _ analysis: Analysis, edit: RemoveBackgroundEdit, options: RemoveBackgroundOptions
    ) throws -> CGImage {
        let subjects = edit.subjects ?? analysis.subjects
        guard !subjects.isEmpty || edit.refinements.contains(where: { $0.action == .keep }) else {
            throw ToolError.invalid("Select a subject or use a Keep correction.")
        }
        let mask = try analysis.mask(for: subjects)
        return try composite(analysis.source.image, mask: mask, edit: edit, options: options)
    }

    public static func export(_ input: URL, to output: URL, options: RemoveBackgroundOptions) async throws -> String {
        let analysis = try analyze(input)
        let edit = try options.exportEdit(for: input, analysis: analysis)
        let result = try preview(analysis, edit: edit, options: options)
        try Task.checkCancellation()
        try publish(result, input: input, to: output, options: options)
        return "\(input.lastPathComponent) · \(result.width) × \(result.height) · \(options.format.rawValue)"
    }

    static func composite(
        _ original: CGImage, mask: CIImage?, edit: RemoveBackgroundEdit, options: RemoveBackgroundOptions
    ) throws -> CGImage {
        guard options.backgroundColor <= 0xFFFFFF, (0...1).contains(options.quality),
              options.format != .jpeg || options.background == .solid,
              edit.refinements.count <= RemoveBackgroundEdit.maximumCorrections else {
            throw ToolError.invalid("Choose valid output options. Transparent backgrounds require PNG.")
        }
        let input = CIImage(cgImage: original)
        let extent = input.extent
        var matte = CIImage(color: .black).cropped(to: extent)
        if let mask {
            guard mask.extent.size == extent.size else {
                throw ToolError.invalid("The foreground mask did not match the image dimensions.")
            }
            matte = mask.cropped(to: extent)
        }
        if !edit.refinements.isEmpty {
            matte = try correctedMatte(matte, extent: extent, refinements: edit.refinements)
        }
        let color = options.backgroundColor
        let rgb = CIColor(cgColor: CGColor(srgbRed: CGFloat((color >> 16) & 255) / 255,
                                           green: CGFloat((color >> 8) & 255) / 255,
                                           blue: CGFloat(color & 255) / 255, alpha: 1))
        let backing = CIImage(color: options.background == .solid ? rgb : .clear).cropped(to: extent)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = input
        blend.backgroundImage = CIImage(color: .clear).cropped(to: extent)
        blend.maskImage = matte
        guard let result = blend.outputImage else { throw ToolError.invalid("Could not apply the foreground mask.") }
        let composited = result.composited(over: backing).cropped(to: extent)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let destinationColorSpace = original.colorSpace?.model == .rgb ? original.colorSpace ?? srgb : srgb
        try Task.checkCancellation()
        guard let image = context.createCGImage(composited, from: extent,
                                                format: original.bitsPerComponent > 8 && options.format == .png ? .RGBA16 : .RGBA8,
                                                colorSpace: destinationColorSpace) else {
            throw ToolError.invalid("Could not render the new background.")
        }
        return image
    }

    private static func correctedMatte(
        _ matte: CIImage, extent: CGRect, refinements: [ForegroundRefinement]
    ) throws -> CIImage {
        let width = Int(extent.width)
        let height = Int(extent.height)
        let gray = CGColorSpaceCreateDeviceGray()
        // Matte samples are opacity values. A gray output profile would apply a transfer curve.
        guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = canvas.data else {
            throw ToolError.invalid("Could not prepare the foreground mask for editing.")
        }
        context.render(matte, toBitmap: data, rowBytes: canvas.bytesPerRow, bounds: extent, format: .L8, colorSpace: nil)
        for refinement in refinements {
            try Task.checkCancellation()
            switch refinement.shape {
            case .rectangle(let region):
                let pixels = try ImageRedaction.pixelBounds(region.rect, width: width, height: height)
                canvas.setFillColor(gray: refinement.action == .keep ? 1 : 0, alpha: 1)
                canvas.fill(CGRect(x: pixels.minX, y: extent.height - pixels.maxY,
                                   width: pixels.width, height: pixels.height))
            case .brush(let stroke):
                try stroke.paint(in: canvas, extent: extent, action: refinement.action)
            }
        }
        guard let mask = canvas.makeImage() else { throw ToolError.invalid("Could not render the edited foreground mask.") }
        return CIImage(cgImage: mask, options: [.colorSpace: NSNull()])
    }

    private static func publish(_ image: CGImage, input: URL, to output: URL, options: RemoveBackgroundOptions) throws {
        let manager = FileManager.default
        guard output.isFileURL, output.standardizedFileURL != input.standardizedFileURL,
              !manager.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a new local output file.")
        }
        if options.format == .png {
            try ImageRedaction.writePNG(image, to: output)
            return
        }
        let folder = output.deletingLastPathComponent().appending(path: ".background-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: folder) }
        let candidate = folder.appending(path: "Subject.jpg")
        guard let writer = CGImageDestinationCreateWithURL(candidate as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ToolError.invalid("Could not open the JPEG encoder.")
        }
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: options.quality] as CFDictionary)
        guard CGImageDestinationFinalize(writer), let source = CGImageSourceCreateWithURL(candidate as CFURL, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let stored = CGImageSourceCreateImageAtIndex(source, 0, nil),
              stored.width == image.width, stored.height == image.height else {
            throw ToolError.invalid("Could not verify the JPEG output.")
        }
        try Task.checkCancellation()
        try manager.moveItem(at: candidate, to: output)
    }
}
