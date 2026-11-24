import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Uses qpdf's object update API so the image streams change in place while
/// the document keeps its page content, bookmarks, and link destinations.
enum PDFEmbeddedImages {
    private struct Placement {
        let page: CGPDFPage
        let name: String
        var size: CGSize
    }

    static func optimize(_ input: URL, to output: URL, qpdf: URL, options: PDFCompressionOptions) async throws -> Bool {
        guard let document = CGPDFDocument(input as CFURL) else { return false }
        let directory = output.deletingLastPathComponent()
        let work = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: work) }
        let index = work.appending(path: "objects.json")
        try await ExternalTool.run(qpdf, name: "qpdf", arguments: [
            "--json=2", "--json-key=pages", "--json-key=qpdf", "--json-stream-data=none", input.path, index.path
        ], directory: work)
        let metadata = try await PlainTextDecoding.loadVerifiedBytes(index, maximumBytes: 32 * 1024 * 1024)
        guard let root = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              let qpdfObjects = root["qpdf"] as? [[String: Any]], qpdfObjects.count == 2,
              let pages = root["pages"] as? [[String: Any]], pages.count == document.numberOfPages else { return false }
        let objects = qpdfObjects[1]
        var placements: [String: Placement] = [:]
        var nested = Set<String>()
        var visited = Set<String>()
        for value in objects.values {
            guard let object = value as? [String: Any] else { continue }
            let stream = object["stream"] as? [String: Any]
            guard let dictionary = (stream?["dict"] ?? object["value"]) as? [String: Any] else { continue }
            if let mask = dictionary["/SMask"] as? String { nested.insert(mask) }
            if let mask = dictionary["/Mask"] as? String { nested.insert(mask) }
            if dictionary["/Subtype"] as? String == "/Form" || dictionary["/Subtype"] as? String == "/Type3"
                || dictionary["/PatternType"] != nil {
                guard let resources = dictionary["/Resources"] else { return false }
                guard collectImages(in: resources, objects: objects, visited: &visited, images: &nested, depth: 0)
                else { return false }
            }
        }
        for (offset, entry) in pages.enumerated() {
            try Task.checkCancellation()
            guard let page = document.page(at: offset + 1), let images = entry["images"] as? [[String: Any]] else {
                return false
            }
            guard !images.isEmpty else { continue }
            let sizes = PDFImagePlacements.measure(page)
            for image in images {
                guard let reference = image["object"] as? String, let name = image["name"] as? String else { continue }
                guard let size = sizes[name], size.width > 0, size.height > 0 else {
                    nested.insert(reference)
                    continue
                }
                if var previous = placements[reference] {
                    previous.size = CGSize(width: max(previous.size.width, size.width),
                                           height: max(previous.size.height, size.height))
                    placements[reference] = previous
                } else {
                    placements[reference] = Placement(page: page, name: name, size: size)
                }
            }
        }

        let dpi = CGFloat(options.imageDPI ?? options.defaultDPI)
        let quality = Double(options.imageQuality ?? options.defaultEmbeddedImageQuality) / 100
        var replacements: [String: Any] = [:]
        for reference in placements.keys.sorted() where !nested.contains(reference) {
            try Task.checkCancellation()
            let key = "obj:" + reference
            guard let placement = placements[reference],
                  let dictionary = streamDictionary(objects[key]),
                  dictionary["/Subtype"] as? String == "/Image",
                  let stream = PDFImagePlacements.image(named: placement.name, on: placement.page),
                  let updated = try rewrite(stream, dictionary: dictionary, dimensions: placement.size,
                                            dpi: dpi, quality: quality, work: work) else { continue }
            replacements[key] = ["stream": updated]
        }
        guard !replacements.isEmpty else { return false }
        let patch = work.appending(path: "update.json")
        let payload = try JSONSerialization.data(withJSONObject: ["qpdf": [["jsonversion": 2], replacements]])
        try payload.write(to: patch)
        try await ExternalTool.run(qpdf, name: "qpdf", arguments: [
            "--update-from-json=\(patch.path)", "--object-streams=generate", input.path, output.path
        ], directory: work)
        return true
    }

    private static func streamDictionary(_ object: Any?) -> [String: Any]? {
        let entry = object as? [String: Any]
        let stream = entry?["stream"] as? [String: Any]
        return stream?["dict"] as? [String: Any]
    }

    private static func collectImages(in value: Any, objects: [String: Any], visited: inout Set<String>,
                                      images: inout Set<String>, depth: Int) -> Bool {
        guard depth < 80 else { return false }
        if let reference = value as? String, let object = objects["obj:" + reference],
           visited.insert(reference).inserted {
            if streamDictionary(object)?["/Subtype"] as? String == "/Image" {
                images.insert(reference)
            } else {
                return collectImages(in: object, objects: objects, visited: &visited, images: &images, depth: depth + 1)
            }
        } else if let dictionary = value as? [String: Any] {
            return dictionary.values.allSatisfy {
                collectImages(in: $0, objects: objects, visited: &visited, images: &images, depth: depth + 1)
            }
        } else if let array = value as? [Any] {
            return array.allSatisfy {
                collectImages(in: $0, objects: objects, visited: &visited, images: &images, depth: depth + 1)
            }
        }
        return true
    }

    private static func rewrite(_ stream: CGPDFStreamRef, dictionary: [String: Any], dimensions: CGSize,
                                dpi: CGFloat, quality: Double, work: URL) throws -> [String: Any]? {
        guard let width = dictionary["/Width"] as? Int, let height = dictionary["/Height"] as? Int,
              (1...16_384).contains(width), (1...16_384).contains(height), width * height <= 20_000_000,
              dictionary["/Mask"] == nil, dictionary["/SMaskInData"] == nil,
              dictionary["/F"] == nil, dictionary["/ImageMask"] == nil, dictionary["/Alternates"] == nil,
              let sourceDictionary = CGPDFStreamGetDictionary(stream) else { return nil }
        var updated = dictionary
        if dictionary["/SMask"] != nil {
            guard hasOpaqueMask(sourceDictionary, width: width, height: height) else { return nil }
            updated.removeValue(forKey: "/SMask")
        }
        let removedMask = dictionary["/SMask"] != nil
        // qpdf preserves the existing bytes when the patch only changes the dictionary.
        let unchangedPixels: [String: Any]? = removedMask ? ["dict": updated] : nil
        let scale = max(dimensions.width * dpi / (72 * CGFloat(width)), dimensions.height * dpi / (72 * CGFloat(height)))
        guard scale.isFinite, scale > 0, scale < 0.99,
              dictionary["/BitsPerComponent"] as? Int == 8,
              dictionary["/Decode"] == nil,
              let color = dictionary["/ColorSpace"] as? String,
              color == "/DeviceRGB" || color == "/DeviceGray" else { return unchangedPixels }
        let components = color == "/DeviceRGB" ? 3 : 1
        let space = components == 3 ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray()
        var format = CGPDFDataFormat.raw
        guard let bytes = CGPDFStreamCopyData(stream, &format) else { return unchangedPixels }
        let source: CGImage?
        switch format {
        case .raw:
            guard CFDataGetLength(bytes) == width * height * components,
                  let provider = CGDataProvider(data: bytes) else { return unchangedPixels }
            source = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: components * 8,
                             bytesPerRow: width * components, space: space, bitmapInfo: [],
                             provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        case .jpegEncoded:
            source = CGImageSourceCreateWithData(bytes, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        default:
            return unchangedPixels
        }
        let newWidth = max(1, Int((CGFloat(width) * scale).rounded(.up)))
        let newHeight = max(1, Int((CGFloat(height) * scale).rounded(.up)))
        let layout = components == 3 ? CGImageAlphaInfo.noneSkipLast : .none
        guard let source, source.width == width, source.height == height,
              let canvas = CGContext(data: nil, width: newWidth, height: newHeight, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: space, bitmapInfo: layout.rawValue) else { return unchangedPixels }
        canvas.interpolationQuality = .high
        canvas.draw(source, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        guard let resized = canvas.makeImage() else { return unchangedPixels }
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil)
        else { return unchangedPixels }
        CGImageDestinationAddImage(destination, resized, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              jpeg.length < (dictionary["/Length"] as? Int ?? Int.max) else { return unchangedPixels }
        let file = work.appending(path: UUID().uuidString + ".jpeg")
        try (jpeg as Data).write(to: file)
        updated["/Width"] = newWidth
        updated["/Height"] = newHeight
        updated["/Filter"] = "/DCTDecode"
        updated.removeValue(forKey: "/DecodeParms")
        updated.removeValue(forKey: "/Length")
        return ["dict": updated, "datafile": file.path]
    }

    private static func hasOpaqueMask(_ dictionary: CGPDFDictionaryRef, width: Int, height: Int) -> Bool {
        var mask: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(dictionary, "SMask", &mask), let mask,
              let properties = CGPDFStreamGetDictionary(mask) else { return false }
        var maskWidth: CGPDFInteger = 0
        var maskHeight: CGPDFInteger = 0
        var bits: CGPDFInteger = 0
        var space: UnsafePointer<CChar>?
        var entry: CGPDFObjectRef?
        guard CGPDFDictionaryGetInteger(properties, "Width", &maskWidth), maskWidth == width,
              CGPDFDictionaryGetInteger(properties, "Height", &maskHeight), maskHeight == height,
              CGPDFDictionaryGetInteger(properties, "BitsPerComponent", &bits), bits == 8,
              CGPDFDictionaryGetName(properties, "ColorSpace", &space), let space, String(cString: space) == "DeviceGray",
              !CGPDFDictionaryGetObject(properties, "Decode", &entry),
              !CGPDFDictionaryGetObject(properties, "Matte", &entry) else { return false }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(mask, &format), format == .raw,
              CFDataGetLength(data) == width * height else { return false }
        return data as Data == Data(repeating: 255, count: width * height)
    }
}
