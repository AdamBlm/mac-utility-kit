import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageCompressionFormat: String, CaseIterable, Sendable {
    case original, jpg, png, heic, tiff, webp

    public var title: String {
        switch self {
        case .original: "Original format"
        case .jpg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .tiff: "TIFF"
        case .webp: "WebP"
        }
    }

    public var requiresImageMagick: Bool { self == .webp }
}

public enum ImageCompressionMode: String, CaseIterable, Sendable {
    case automatic, lossy, lossless

    public var title: String { rawValue.capitalized }
}

public struct ImageCompressionOptions: Sendable {
    public var format: ImageCompressionFormat = .original
    public var mode: ImageCompressionMode = .lossy
    public var quality = 0.85
    public var targetKilobytes: Int?
    public var preserveMetadata = true
    public var imageMagickExecutable: URL?

    public init() {}

    public static var recommended: Self {
        var options = Self()
        options.mode = .automatic
        return options
    }
}

public enum ImageCompression {
    public static func outputExtension(_ input: URL, options: ImageCompressionOptions) throws -> String {
        guard input.isFileURL else { throw ToolError.invalid("Choose a local image file.") }
        return try selectedFormat(for: input, options: options).rawValue
    }

    public static func compress(
        _ input: URL, to output: URL, options: ImageCompressionOptions
    ) async throws -> String {
        try Task.checkCancellation()
        guard input.isFileURL, output.isFileURL else {
            throw ToolError.invalid("Choose local image files.")
        }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: output.path) else {
            throw ToolError.invalid("The output file already exists.")
        }
        let version = try LocalInputFile.Version.read(input)
        let sourceInput = version.resolved
        let canKeepOriginal = options.mode == .automatic && options.format == .original && options.preserveMetadata
        let format = try selectedFormat(for: sourceInput, options: options)
        let target = try targetBytes(options.targetKilobytes)
        let quality = options.mode == .automatic ? ImageCompressionOptions().quality : options.quality
        guard quality.isFinite, (0...1).contains(quality) else {
            throw ToolError.invalid("Choose a quality between 0 and 100%.")
        }

        guard let source = CGImageSourceCreateWithURL(sourceInput as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ToolError.invalid("Could not open this image.")
        }
        guard CGImageSourceGetCount(source) == 1 else {
            throw ToolError.invalid("Compress Images supports single-image files. Use Convert Images to export the primary image.")
        }
        let inherentlyLossless = format == .png || format == .tiff
        let usesLosslessEncoding: Bool
        if options.mode == .automatic && format == .webp && target == nil {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let depth = properties?[kCGImagePropertyDepth] as? Int ?? 8
            usesLosslessEncoding = depth <= 8 ? try ImageConversion.hasTransparency(sourceInput) : false
        } else {
            usesLosslessEncoding = inherentlyLossless || options.mode == .lossless
        }
        if usesLosslessEncoding, format != .webp, !inherentlyLossless {
            throw ToolError.invalid("Lossless compression is available for PNG, TIFF and WebP. Choose a lossless format or switch to Lossy.")
        }
        if format == .jpg, try ImageConversion.hasTransparency(sourceInput) {
            throw ToolError.invalid("JPEG cannot preserve transparency. Choose another output format, or use Convert Images to flatten it.")
        }
        if usesLosslessEncoding, format == .webp,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let depth = properties[kCGImagePropertyDepth] as? Int, depth > 8 {
            throw ToolError.invalid("Lossless WebP supports up to 8 bits per channel. Use PNG or TIFF for this image.")
        }
        if format == .webp, options.imageMagickExecutable == nil {
            throw ToolError.invalid("Choose an ImageMagick executable to encode WebP.")
        }

        var encoding = ImageConversionOptions()
        encoding.format = format
        encoding.quality = quality
        encoding.preserveMetadata = options.preserveMetadata
        encoding.flattenTransparency = false
        encoding.imageMagickExecutable = options.imageMagickExecutable
        encoding.losslessWebP = usesLosslessEncoding && format == .webp
        if encoding.losslessWebP { encoding.quality = 1 }
        let minimumQuality = format == .webp ? Double(ImageMagickWebPEncoding.minimumLossyQuality) / 100 : 0

        let sourceSize = try byteCount(sourceInput)
        let staging = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }

        var best = try await encode(sourceInput, in: staging, options: encoding)
        if let target, best.bytes > target, !usesLosslessEncoding, best.quality > minimumQuality {
            best = try await findCandidate(sourceInput, in: staging, options: encoding, initial: best, target: target,
                                           minimumQuality: minimumQuality)
        }
        try Task.checkCancellation()
        try verifySource(input, version: version)
        if canKeepOriginal, best.bytes >= sourceSize {
            let unchanged = staging.appending(path: "Original.\(format.rawValue)")
            try copyOriginal(DuplicateFile(url: sourceInput, stamp: version.stamp), to: unchanged)
            try Task.checkCancellation()
            try verifySource(input, version: version)
            try fileManager.moveItem(at: unchanged, to: output)
            let bytes = ByteCountFormatter.string(fromByteCount: Int64(sourceSize), countStyle: .file)
            let goal = target.map { sourceSize <= $0 ? " · Size goal reached" : " · Size goal not reached" } ?? ""
            return "\(input.lastPathComponent) · Original kept at \(bytes) · No savings\(goal)"
        }
        if usesLosslessEncoding {
            try validatePrecision(of: best.url, against: source)
        }
        try verifySource(input, version: version)
        try fileManager.moveItem(at: best.url, to: output)
        return summary(input, sourceSize: sourceSize, outputSize: best.bytes, target: target,
                       format: format, lossless: usesLosslessEncoding, quality: best.quality)
    }

    private static func verifySource(_ input: URL, version: LocalInputFile.Version) throws {
        guard (try? LocalInputFile.Version.read(input)) == version else {
            throw ToolError.invalid("The source image changed during compression. Try again.")
        }
    }

    private static func copyOriginal(_ original: DuplicateFile, to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ToolError.invalid("Could not create the original image copy.")
        }
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }
        try DuplicateFileIO.forEachVerifiedChunk(original) { try writer.write(contentsOf: $0) }
        try writer.synchronize()
    }

    private struct Candidate {
        let url: URL
        let bytes: Int
        let quality: Double
    }

    private static func selectedFormat(for input: URL, options: ImageCompressionOptions) throws -> ImageConversionFormat {
        if options.format != .original,
           let explicit = ImageConversionFormat(rawValue: options.format.rawValue) { return explicit }

        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let type = CGImageSourceGetType(source) else {
            throw ToolError.invalid("Could not read this image.")
        }
        switch type as String {
        case UTType.jpeg.identifier: return .jpg
        case UTType.png.identifier: return .png
        case UTType.heic.identifier: return .heic
        case UTType.tiff.identifier: return .tiff
        case UTType.webP.identifier: return .webp
        default: throw ToolError.invalid("Choose an explicit output format to compress this image.")
        }
    }

    private static func targetBytes(_ kilobytes: Int?) throws -> Int? {
        guard let kilobytes else { return nil }
        guard (1...1_000_000).contains(kilobytes) else {
            throw ToolError.invalid("Enter a size goal between 1 and 1,000,000 KB.")
        }
        return kilobytes * 1000
    }

    private static func encode(
        _ input: URL, in directory: URL, options: ImageConversionOptions
    ) async throws -> Candidate {
        try Task.checkCancellation()
        let output = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(options.format.rawValue)
        _ = try await ImageConversion.convert(input, to: output, options: options)
        let quality = options.format == .webp && !options.losslessWebP
            ? Double(ImageMagickWebPEncoding.lossyQualityPercent(options.quality)) / 100 : options.quality
        return Candidate(url: output, bytes: try byteCount(output), quality: quality)
    }

    private static func findCandidate(
        _ input: URL, in directory: URL, options: ImageConversionOptions, initial: Candidate, target: Int,
        minimumQuality: Double
    ) async throws -> Candidate {
        var settings = options
        var best = initial
        var low = minimumQuality
        var high = initial.quality
        // Encoders approximate quality settings, so use measured file sizes and a bounded search.
        for attempt in 0..<7 {
            settings.quality = attempt == 0 ? low : (low + high) / 2
            let candidate = try await encode(input, in: directory, options: settings)
            let replace = candidate.bytes <= target || (best.bytes > target && candidate.bytes < best.bytes)
            if replace {
                try FileManager.default.removeItem(at: best.url)
                best = candidate
            } else {
                try FileManager.default.removeItem(at: candidate.url)
            }
            if candidate.bytes <= target {
                low = candidate.quality
            } else {
                high = candidate.quality
            }
            if high - low <= 0.01 + Double.ulpOfOne { break }
        }
        return best
    }

    private static func validatePrecision(of output: URL, against source: CGImageSource) throws {
        guard let result = CGImageSourceCreateWithURL(output as CFURL, nil),
              let before = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let after = CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [CFString: Any] else {
            throw ToolError.invalid("Could not verify the lossless output.")
        }
        // Palette storage depth can shrink without losing any visible color. Protect high-bit-depth samples.
        if let sourceDepth = before[kCGImagePropertyDepth] as? Int, sourceDepth > 8,
           (after[kCGImagePropertyDepth] as? Int ?? 0) < sourceDepth {
            throw ToolError.invalid("The selected lossless encoder could not preserve the source bit depth.")
        }
        if let sourceModel = before[kCGImagePropertyColorModel] as? String,
           let resultModel = after[kCGImagePropertyColorModel] as? String,
           sourceModel != resultModel,
           !(sourceModel == (kCGImagePropertyColorModelGray as String)
             && resultModel == (kCGImagePropertyColorModelRGB as String)) {
            throw ToolError.invalid("The selected lossless encoder could not preserve the source color model.")
        }
    }

    private static func byteCount(_ url: URL) throws -> Int {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw ToolError.invalid("Could not measure the image file size.")
        }
        return size
    }

    private static func summary(
        _ input: URL, sourceSize: Int, outputSize: Int, target: Int?,
        format: ImageConversionFormat, lossless: Bool, quality: Double
    ) -> String {
        let before = ByteCountFormatter.string(fromByteCount: Int64(sourceSize), countStyle: .decimal)
        let after = ByteCountFormatter.string(fromByteCount: Int64(outputSize), countStyle: .decimal)
        var result = "\(input.lastPathComponent) · \(format.title) · \(before) → \(after)"
        if lossless {
            result += " · Lossless encoding"
        } else {
            result += " · Quality " + quality.formatted(.percent.precision(.fractionLength(0)))
        }
        if sourceSize > 0, outputSize != sourceSize {
            let difference = Double(abs(sourceSize - outputSize)) / Double(sourceSize)
            let percent = difference.formatted(.percent.precision(.fractionLength(1)))
            result += outputSize > sourceSize ? " · \(percent) larger" : " · \(percent) smaller"
        } else {
            result += " · Same size"
        }
        if let target {
            result += outputSize <= target ? " · Size goal reached" : " · Size goal not reached"
        }
        return result
    }
}
